import AppKit
import SwiftUI
import UppdateraCore

// MARK: - Dock progress

/// A progress bar drawn over the Dock icon while checking or installing.
@MainActor
enum DockProgress {
    private static let view = ProgressTile()

    static func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        if let fraction {
            view.fraction = max(0, min(1, fraction))
            if tile.contentView !== view { tile.contentView = view }
        } else if tile.contentView != nil {
            tile.contentView = nil
        }
        tile.display()
    }

    final class ProgressTile: NSView {
        var fraction: Double = 0

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.11)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            let inset = bar.insetBy(dx: 2, dy: 2)
            let filled = NSRect(x: inset.minX, y: inset.minY, width: max(inset.height, inset.width * fraction), height: inset.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2).fill()
        }
    }
}

// MARK: - Self-update

/// Uppdatera updates itself from GitHub releases. The repository comes from the
/// `UppdateraReleasesRepo` Info.plist key, set at build time (`RELEASES_REPO=owner/repo`).
@MainActor
enum SelfUpdate {
    static var repo: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "UppdateraReleasesRepo") as? String
        return value?.isEmpty == false ? value : nil
    }

    static func check(interactive: Bool) {
        Task {
            guard let repo else {
                if interactive {
                    alert("Self-update isn't set up", "This copy was built without a releases repository. Publish Uppdatera releases on GitHub and build with RELEASES_REPO=owner/repo.")
                }
                return
            }
            do {
                let release = try await GitHubReleases.latest(repo: repo, assetPattern: #"Uppdatera.*\.(zip|dmg)$"#, allowPrerelease: false)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let latest = String(release.tag.drop { !$0.isNumber })
                guard let a = AppVersion(current), let b = AppVersion(latest), a < b else {
                    if interactive { alert("Uppdatera is up to date", "You have version \(current), the newest.") }
                    return
                }
                let answer = NSAlert()
                answer.messageText = "Uppdatera \(latest) is available"
                answer.informativeText = "You have \(current). Install it and restart Uppdatera?"
                answer.addButton(withTitle: "Install and Restart")
                answer.addButton(withTitle: "Later")
                guard answer.runModal() == .alertFirstButtonReturn else { return }
                let update = UpdateInfo(version: latest, downloadURL: release.assetURL, pageURL: release.pageURL, source: .github)
                try await Installer.installSelf(update) { stage, fraction in
                    Task { @MainActor in DockProgress.show(stage == .downloading ? fraction : nil) }
                }
                relaunch()
            } catch {
                DockProgress.show(nil)
                if interactive { alert("Uppdatera couldn't update itself", error.localizedDescription) }
            }
        }
    }

    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \(Command.quote(path))"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    page("arrow.down.circle.fill", "Welcome to Uppdatera",
                         "Uppdatera keeps the apps in your Applications folder and the tools from Homebrew, npm, Go and other package managers up to date.\n\nIt only installs a download when Apple has notarized it and it's signed by the same developer as the copy you have. The old version goes to the Trash, so you can always go back.")
                case 1:
                    page("clock", "How often should it look?", "You can change this at any time in Settings.") {
                        Picker("Check for updates", selection: $model.frequency) {
                            ForEach(CheckFrequency.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 320)
                        Toggle("Also check while Uppdatera is closed", isOn: Binding(get: { model.backgroundChecks }, set: { model.backgroundChecks = $0 }))
                        if let note = model.notices["backgroundChecks"] { Text(note).font(.caption).foregroundStyle(.orange) }
                    }
                case 2:
                    page("bell.badge", "Hear about updates once",
                         "Uppdatera tells you about each update a single time. Apps you ignore, pin or hold are never mentioned.") {
                        Toggle("Send notifications", isOn: $model.notificationsEnabled)
                    }
                default:
                    page("lock.shield", "One permission to install",
                         "macOS asks before one app replaces another. If an update is refused, turn Uppdatera on under Privacy & Security → App Management. You can do it now or when it first comes up.") {
                        Button("Open App Management Settings") { NSWorkspace.shared.open(SystemSettings.appManagement) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                ForEach(0..<4) { i in
                    Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 3 ? "Start Using Uppdatera" : "Continue") {
                    if step == 3 {
                        UserDefaults.standard.set(true, forKey: "onboarded")
                        dismiss()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 540, height: 420)
    }

    private func page<Extra: View>(_ symbol: String, _ title: String, _ text: String,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            extra()
        }
        .padding(30)
    }
}
