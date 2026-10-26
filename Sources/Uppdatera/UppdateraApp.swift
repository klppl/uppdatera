import AppKit
import SwiftUI
import UppdateraCore

@main
enum Entry {
    static func main() {
        let cliFlags: Set = ["--check", "--test-rule", "--install", "--uninstall", "--packages", "--background-check", "--github-status", "--validate-rules"]
        if CommandLine.arguments.contains(where: cliFlags.contains) {
            CLI.run()
        } else {
            UppdateraApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window leaves Uppdatera in the menu bar, checking on schedule.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct UppdateraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Uppdatera", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 540)
                .task {
                    model.start()
                    SelfUpdate.check(interactive: false)
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Uppdatera Updates…") { SelfUpdate.check(interactive: true) }
                Button("Check for Updates") { model.checkNow() }
                    .keyboardShortcut("r")
                    .disabled(model.isChecking)
            }
            CommandGroup(replacing: .help) {
                if let url = ProjectLinks.reportMissingApp {
                    Button("Report a Missing App…") { NSWorkspace.shared.open(url) }
                }
                if let repo = ProjectLinks.repo, let url = URL(string: "https://github.com/\(repo)") {
                    Button("Uppdatera on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Update All") { model.updateAll() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.badgeCount == 0)
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.badgeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            if model.badgeCount > 0 { Text("\(model.badgeCount)") }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isChecking {
            Text("Checking… \(model.checked) of \(model.toCheck)")
        } else if model.badgeCount == 0 {
            Text("Everything is up to date")
        }
        ForEach(model.updates.prefix(12)) { row in
            Button("\(row.app.name)  \(row.app.displayVersion) → \(row.status.update?.version ?? "")") { model.install(row) }
        }
        if model.checkPackages && !model.visiblePackages.isEmpty {
            Text("\(model.visiblePackages.count) package updates")
        }
        Divider()
        Button("Update All") { model.updateAll() }.disabled(model.badgeCount == 0)
        Button("Check Now") { model.checkNow() }.disabled(model.isChecking)
        Button("Open Uppdatera") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Uppdatera") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// `Uppdatera --check` prints what it finds, for scripts and for testing rules.
enum CLI {
    /// Keeps the main queue running (installing needs the main actor) and exits when done.
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            if CommandLine.arguments.contains("--background-check") {
                await BackgroundCheck.run()
                exit(0)
            }
            if CommandLine.arguments.contains("--github-status") {
                let (_, origin) = await GitHubAuth.current()
                let limit = await GitHubAuth.rateLimit()
                print("Token: \(origin.rawValue)")
                print("Requests left: \(limit.map { "\($0.remaining) of \($0.limit) this hour" } ?? "GitHub didn't answer")")
                exit(0)
            }
            // `--validate-rules <file> [--live]`: checks a rules file before it's shared. With --live,
            // every rule with a source is run against the real source too.
            if let i = CommandLine.arguments.firstIndex(of: "--validate-rules"), i + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[i + 1]
                guard let data = FileManager.default.contents(atPath: path), let doc = try? RulesStore.decode(data) else {
                    print("\(path) isn't a readable rules file."); exit(2)
                }
                var issues = RulesStore.validate(doc)
                if CommandLine.arguments.contains("--live") {
                    let checker = UpdateChecker(rules: doc.apps, ownBundleID: nil)
                    let live = doc.apps.filter { $0.value.source != nil && $0.value.source?.kind != AppRule.Source.Kind.none }
                        .keys.sorted()
                    let results = await boundedMap(live, limit: 4) { id -> String? in
                        let app = InstalledApp(path: URL(fileURLWithPath: "/Applications/\(id).app"), name: id, bundleID: id,
                                               shortVersion: "0.0.1", buildVersion: "1", sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
                        let result = await checker.check(app)
                        if let update = result.status.update {
                            print("  ok    \(id) → \(update.version)\(update.downloadURL == nil ? " (no download link)" : "")")
                            return nil
                        }
                        // The made-up installed version can look like another numbering scheme;
                        // what matters here is that the rule found a version at all.
                        if let line = result.trace.first(where: { $0.hasPrefix("Rule (") }), !line.contains("failed"), !line.contains("no version") {
                            print("  ok    \(id): \(line)")
                            return nil
                        }
                        return "\(id): live check found no version (\(result.trace.last ?? "no trace"))"
                    }
                    issues += results.compactMap { $0 }
                }
                if issues.isEmpty {
                    print("\(doc.apps.count) rules, no problems.")
                    exit(0)
                }
                issues.forEach { print("  ✗ \($0)") }
                print("\(issues.count) problem\(issues.count == 1 ? "" : "s") in \(path).")
                exit(1)
            }
            if let problem = await CommunityRules.refresh() { print("warning: \(problem)") }
            var (rules, problem) = RulesStore.load()
            if let problem { print("warning: \(problem)") }
            // `--rules <file>`: try rules from a file (a pull request's, say) on top of the rest.
            if let i = CommandLine.arguments.firstIndex(of: "--rules"), i + 1 < CommandLine.arguments.count {
                do {
                    let extra = try JSONDecoder().decode(RulesDocument.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])))
                    rules.merge(extra.apps) { _, new in new }
                } catch {
                    print("Couldn't read \(CommandLine.arguments[i + 1]): \(error)")
                    exit(2)
                }
            }
            let checker = UpdateChecker(rules: rules, ownBundleID: "app.uppdatera.Uppdatera")
            let apps = AppScanner.scan()
            // `--test-rule <bundle id> [installed version]`: runs one rule as if that version were installed.
            if let i = CommandLine.arguments.firstIndex(of: "--test-rule"), i + 1 < CommandLine.arguments.count {
                let id = CommandLine.arguments[i + 1]
                let version = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : "0.0.1"
                let pretend = i + 2 < CommandLine.arguments.count
                let app = apps.first(where: { $0.bundleID == id && !pretend }) ?? InstalledApp(
                    path: URL(fileURLWithPath: "/Applications/\(id).app"), name: id, bundleID: id, shortVersion: version,
                    buildVersion: version, sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
                let result = await checker.check(app)
                print("\(id): \(result.status.update.map { "latest \($0.version) [\($0.source.label)] download \($0.downloadURL?.absoluteString ?? "-") notes \($0.notes != nil)" } ?? "\(result.status)")")
                result.trace.forEach { print("  · \($0)") }
                exit(result.status.update == nil ? 1 : 0)
            }
            if let i = CommandLine.arguments.firstIndex(of: "--install"), i + 1 < CommandLine.arguments.count {
                let id = CommandLine.arguments[i + 1]
                guard let app = apps.first(where: { $0.bundleID == id || $0.name == id }) else {
                    print("No installed app matches \(id)"); exit(1)
                }
                let result = await checker.check(app)
                result.trace.forEach { print("· \($0)") }
                guard let update = result.status.update else { print("No update for \(app.name): \(result.status)"); exit(0) }
                print("Installing \(app.name) \(app.displayVersion) → \(update.version) from \(update.downloadURL?.absoluteString ?? update.caskToken ?? "?")")
                do {
                    let outcome = try await Installer.install(app, update: update) { stage, fraction in
                        if fraction == nil || fraction == 0 { print("  \(stage.rawValue)…") }
                    }
                    print("Done: \(outcome)")
                    exit(0)
                } catch {
                    print("Failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            // `--uninstall <bundle id> [--dry-run]`: the app and its usual leftovers (the ones the
            // Uninstall sheet ticks) go to the Trash. --dry-run only lists them.
            if let i = CommandLine.arguments.firstIndex(of: "--uninstall"), i + 1 < CommandLine.arguments.count {
                let id = CommandLine.arguments[i + 1]
                guard let app = apps.first(where: { $0.bundleID == id || $0.name == id }) else {
                    print("No installed app matches \(id)"); exit(1)
                }
                guard Uninstaller.canUninstall(app) else { print("\(app.name) can't be uninstalled here."); exit(1) }
                let found = Uninstaller.leftovers(for: app)
                print("\(app.path.path)  (\(ByteCountFormatter.string(fromByteCount: Uninstaller.size(of: app.path), countStyle: .file)))")
                for leftover in found {
                    print("\(leftover.suggested ? "remove" : "keep  ")  \(leftover.url.path)  (\(ByteCountFormatter.string(fromByteCount: leftover.size, countStyle: .file)))")
                }
                if CommandLine.arguments.contains("--dry-run") { exit(0) }
                var cask: String?
                if let entry = await CaskCatalogue.shared.entry(forAppNamed: app.fileName), CaskCatalogue.installedToken(entry.token) { cask = entry.token }
                do {
                    let result = try await Uninstaller.uninstall(app, leftovers: found.filter(\.suggested).map(\.url), caskToken: cask)
                    result.problems.forEach { print("Problem: \($0)") }
                    print("Moved to the Trash.")
                    exit(0)
                } catch {
                    print("Failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            let verbose = CommandLine.arguments.contains("--verbose")
            let results = await boundedMap(apps, limit: 8) { app in (app, await checker.check(app)) }
            for (app, result) in results {
                let line: String
                switch result.status {
                case let .updateAvailable(u): line = "UPDATE   \(app.name): \(app.displayVersion) → \(u.version) [\(u.source.label)]\(u.caskToken.map { " (brew cask \($0))" } ?? "")"
                case let .upToDate(latest): line = "ok       \(app.name) \(app.displayVersion)\(latest.map { " (latest \($0))" } ?? "")"
                case let .unknown(why): line = "unknown  \(app.name): \(why)"
                case let .excluded(why): line = "skip     \(app.name): \(why)"
                case let .failed(why): line = "error    \(app.name): \(why)"
                case .pending: line = "pending  \(app.name)"
                }
                print(line)
                if verbose { result.trace.forEach { print("           · \($0)") } }
            }
            if CommandLine.arguments.contains("--packages") {
                let survey = await PackageScanner.survey()
                print("\nPackage managers: \(survey.available.map(\.label).joined(separator: ", "))")
                for p in survey.updates { print("PACKAGE  [\(p.manager.label)] \(p.name): \(p.installed) → \(p.latest)") }
                for (m, problem) in survey.problems { print("error    [\(m.label)] \(problem)") }
            }
            exit(0)
        }
        dispatchMain()
    }
}
