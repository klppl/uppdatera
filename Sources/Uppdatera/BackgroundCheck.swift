import AppKit
import UppdateraCore
import UserNotifications

/// Posts "update available" notifications, once per app and version. The ledger is a file, so
/// the window and the background agent never announce the same update twice.
enum Announcer {
    static func announce(_ items: [(key: String, label: String)]) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        var announced = Set(Storage.load([String].self, from: "announced.json") ?? [])
        let fresh = items.filter { !announced.contains($0.key) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { announced.insert($0.key) }
        Storage.save(Array(announced), to: "announced.json")

        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "Update available" : "\(fresh.count) updates available"
        content.body = fresh.prefix(4).map(\.label).joined(separator: ", ") + (fresh.count > 4 ? ", and more" : "")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Items worth announcing: updates the user hasn't silenced.
    static func items(apps: [(InstalledApp, AppStatus)], packages: [PackageUpdate],
                      preferences: [String: UpdatePreference]) -> [(key: String, label: String)] {
        let appItems = apps.compactMap { app, status -> (key: String, label: String)? in
            guard let v = status.update?.version,
                  (preferences[app.bundleID] ?? UpdatePreference()).suppression(of: v) == nil else { return nil }
            return ("\(app.bundleID)@\(v)", "\(app.name) \(v)")
        }
        let packageItems = packages.compactMap { p -> (key: String, label: String)? in
            guard !p.pinned, (preferences[p.id] ?? UpdatePreference()).suppression(of: p.latest) == nil else { return nil }
            return ("\(p.id)@\(p.latest)", "\(p.name) \(p.latest)")
        }
        return appItems + packageItems
    }
}

/// What the launchd agent runs: `Uppdatera --background-check`.
enum BackgroundCheck {
    static let agentPlist = "app.uppdatera.Uppdatera.agent.plist"

    /// One app's result. A struct rather than a tuple, for the reason ManagerOutcome gives.
    struct Checked: Sendable {
        let app: InstalledApp
        let result: CheckResult
    }

    static func run() async {
        let defaults = UserDefaults.standard
        let me = getpid()
        let windowOpen = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me }
        if windowOpen { print("Uppdatera is open and checks on its own; nothing to do."); return }

        let frequency = CheckFrequency(rawValue: defaults.string(forKey: "frequency") ?? "") ?? .sixHours
        guard let interval = frequency.interval else { print("Checking is set to manual."); return }
        if let last = defaults.object(forKey: "lastCheck") as? Date, Date().timeIntervalSince(last) < interval - 120 {
            print("Not due yet (last check \(last)).")
            return
        }

        await CommunityRules.refresh()
        let checker = UpdateChecker(rules: RulesStore.load().rules)
        let checked = await boundedMap(AppScanner.scan(), limit: 6) { app in Checked(app: app, result: await checker.check(app)) }
        let checkPackages = defaults.object(forKey: "checkPackages") as? Bool ?? true
        let packages = checkPackages ? await PackageScanner.survey().updates : []

        let entries = Dictionary(checked.map { ($0.app.id, SavedResults.Entry(version: $0.app.displayVersion, status: $0.result.status, trace: $0.result.trace)) },
                                 uniquingKeysWith: { a, _ in a })
        Storage.save(SavedResults(apps: entries, packages: packages), to: "results.json")
        defaults.set(Date(), forKey: "lastCheck")

        if defaults.object(forKey: "notifications") as? Bool ?? true {
            let preferences = Storage.load([String: UpdatePreference].self, from: "preferences.json") ?? [:]
            await Announcer.announce(Announcer.items(apps: checked.map { ($0.app, $0.result.status) }, packages: packages,
                                                     preferences: preferences))
        }
        let count = checked.filter { $0.result.status.update != nil }.count
        print("Checked \(checked.count) apps: \(count) updates, \(packages.count) package updates.")
    }
}
