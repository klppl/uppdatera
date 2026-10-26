import AppKit
import Observation
import ServiceManagement
import UppdateraCore
import UserNotifications

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case updates, history, applications, packages, noSource, pinned, ignored
    var id: String { rawValue }

    var title: String {
        switch self {
        case .updates: "Updates"
        case .history: "Recently Updated"
        case .applications: "Applications"
        case .packages: "Packages"
        case .noSource: "No Update Source"
        case .pinned: "Pinned & Held"
        case .ignored: "Ignored"
        }
    }

    var symbol: String {
        switch self {
        case .updates: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .applications: "square.grid.2x2"
        case .packages: "shippingbox"
        case .noSource: "questionmark.circle"
        case .pinned: "pin"
        case .ignored: "bell.slash"
        }
    }
}

/// Last check's results, so a relaunch shows them instead of an empty list.
struct SavedResults: Codable {
    struct Entry: Codable {
        var version: String
        var status: AppStatus
        var trace: [String]
    }
    var apps: [String: Entry]
    var packages: [PackageUpdate]
}

enum UpdateAllScope: String, CaseIterable, Identifiable {
    case everything, applications, packages
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everything: "Applications and packages"
        case .applications: "Applications only"
        case .packages: "Packages only"
        }
    }
}

struct AppRow: Identifiable, Hashable {
    let app: InstalledApp
    var status: AppStatus = .pending
    var trace: [String] = []
    var id: String { app.id }
}

struct InstallState: Hashable {
    var stage: String
    var fraction: Double?
}

struct Failure: Hashable {
    var message: String
    var remedy: InstallError.Remedy?
    /// The install step that was running, e.g. "Checking signature".
    var stage: String?
}

@MainActor
@Observable
final class AppModel {
    var rows: [AppRow] = []
    var packages: [PackageUpdate] = []
    var packageManagers: [PackageManager] = []
    var packageProblems: [PackageManager: String] = [:]

    var isChecking = false
    var checked = 0 { didSet { updateDock() } }
    var toCheck = 0
    var lastCheck: Date?
    var rulesProblem: String?

    var preferences: [String: UpdatePreference] = [:]
    var history: [HistoryEntry] = []
    var installing: [String: InstallState] = [:] { didSet { updateDock() } }
    var failures: [String: Failure] = [:]
    var notices: [String: String] = [:]
    /// The app whose check log is open in a sheet.
    var checkLogFor: String?
    /// The app the Uninstall sheet is open for. Held whole, so the sheet outlives its row.
    var uninstallFor: AppRow?
    var queue: [String] = []

    var frequency: CheckFrequency {
        didSet { UserDefaults.standard.set(frequency.rawValue, forKey: "frequency") }
    }
    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { requestNotificationPermission() }
        }
    }
    var checkPackages: Bool {
        didSet { UserDefaults.standard.set(checkPackages, forKey: "checkPackages") }
    }
    var updateAllScope: UpdateAllScope {
        didSet { UserDefaults.standard.set(updateAllScope.rawValue, forKey: "updateAllScope") }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                notices["launchAtLogin"] = error.localizedDescription
            }
        }
    }

    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        frequency = CheckFrequency(rawValue: defaults.string(forKey: "frequency") ?? "") ?? .sixHours
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        checkPackages = defaults.object(forKey: "checkPackages") as? Bool ?? true
        updateAllScope = UpdateAllScope(rawValue: defaults.string(forKey: "updateAllScope") ?? "") ?? .everything
        preferences = Storage.load([String: UpdatePreference].self, from: "preferences.json") ?? [:]
        history = Storage.load([HistoryEntry].self, from: "history.json") ?? []
        lastCheck = defaults.object(forKey: "lastCheck") as? Date

        let saved = Storage.load(SavedResults.self, from: "results.json")
        rows = AppScanner.scan().map { app in
            guard let entry = saved?.apps[app.id], entry.version == app.displayVersion else { return AppRow(app: app) }
            return AppRow(app: app, status: entry.status, trace: entry.trace)
        }
        packages = saved?.packages ?? []
    }

    private func saveResults() {
        let apps = Dictionary(rows.map { ($0.id, SavedResults.Entry(version: $0.app.displayVersion, status: $0.status, trace: $0.trace)) },
                              uniquingKeysWith: { a, _ in a })
        Storage.save(SavedResults(apps: apps, packages: packages), to: "results.json")
    }

    func start() {
        guard timer == nil else { return }
        if notificationsEnabled { requestNotificationPermission() }
        let due = lastCheck.map { Date().timeIntervalSince($0) > (frequency.interval ?? .infinity) } ?? true
        let nothingToShow = rows.allSatisfy { $0.status == .pending }
        if due || nothingToShow { checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduledTick() }
        }
        // Coming back from the App Store or an Installer is when an update has usually just finished.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshInstalledVersions() }
        }
    }

    private func scheduledTick() {
        guard !isChecking else { return }
        if let interval = frequency.interval, Date().timeIntervalSince(lastCheck ?? .distantPast) >= interval {
            checkNow()
        } else {
            refreshInstalledVersions()
        }
    }

    // MARK: Installed versions

    /// Re-reads the installed apps and checks again the ones whose version changed on disk, so an
    /// update finished in the App Store, an Installer or by the app itself drops off the list
    /// without waiting for the next full check. Reading versions needs no network.
    func refreshInstalledVersions() {
        guard !isChecking else { return }
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: [InstalledApp] = []
        let scanned = AppScanner.scan()
        rows = scanned.map { app in
            guard let old = previous[app.id] else {
                changed.append(app)
                return AppRow(app: app)
            }
            // Uppdatera's own installs update their row when they finish.
            guard installing[app.id] == nil,
                  app.displayVersion != old.app.displayVersion || app.buildVersion != old.app.buildVersion else { return old }
            if let update = old.status.update {
                record(HistoryEntry(name: app.name, identifier: app.bundleID, from: old.app.displayVersion, to: app.displayVersion, via: update.source.label))
            }
            notices[app.id] = nil
            changed.append(app)
            return AppRow(app: app, trace: ["Now \(app.displayVersion) on disk (was \(old.app.displayVersion)), so checked again"])
        }
        guard !changed.isEmpty || scanned.count != previous.count else { return }
        saveResults()
        refreshBadge()
        Task { await recheck(changed) }
    }

    private func recheck(_ apps: [InstalledApp]) async {
        guard !apps.isEmpty else { return }
        let checker = UpdateChecker(rules: RulesStore.load().rules)
        let results = await boundedMap(apps, limit: 4) { app in (app.id, await checker.check(app)) }
        for (id, result) in results {
            guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].status == .pending else { continue }
            rows[i].status = result.status
            rows[i].trace += result.trace
        }
        saveResults()
        refreshBadge()
    }

    /// An update handed to the App Store or an Installer finishes outside Uppdatera. Watch for the
    /// new version on disk for up to an hour, so the row goes away even if the window stays open.
    private func watchForOutsideInstall(of app: InstalledApp) {
        Task {
            for _ in 0..<720 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // Missing for a moment is normal while an installer swaps the app.
                guard let now = AppScanner.read(app.path) else { continue }
                if now.displayVersion != app.displayVersion || now.buildVersion != app.buildVersion {
                    refreshInstalledVersions()
                    return
                }
            }
        }
    }

    // MARK: Derived lists

    func suppression(for row: AppRow) -> String? {
        let pref = preferences[row.app.bundleID] ?? UpdatePreference()
        if pref.ignored { return "Ignored" }
        guard let update = row.status.update else { return nil }
        return pref.suppression(of: update.version)
    }

    var updates: [AppRow] {
        rows.filter { $0.status.update != nil && suppression(for: $0) == nil }
    }

    var visiblePackages: [PackageUpdate] {
        packages.filter { !$0.pinned && (preferences[$0.id] ?? UpdatePreference()).suppression(of: $0.latest) == nil }
    }

    var pinnedOrHeld: [AppRow] {
        rows.filter { row in
            guard let pref = preferences[row.app.bundleID], !pref.ignored else { return false }
            return pref.pinned || pref.heldMajor != nil || pref.skippedVersion != nil
        }
    }

    var ignored: [AppRow] {
        rows.filter { preferences[$0.app.bundleID]?.ignored == true }
    }

    /// Apps no source could check, so a missing or broken rule doesn't go unnoticed. Ignored apps stay in Ignored.
    var noSource: [AppRow] {
        rows.filter { row in
            guard case .unknown = row.status else { return false }
            return preferences[row.app.bundleID]?.ignored != true
        }
    }

    var badgeCount: Int { updates.count + (checkPackages ? visiblePackages.count : 0) }

    func rows(for section: SidebarSection) -> [AppRow] {
        switch section {
        case .updates: updates
        case .applications: rows
        case .pinned: pinnedOrHeld
        case .ignored: ignored
        case .noSource: noSource
        case .packages, .history: []
        }
    }

    func count(for section: SidebarSection) -> Int {
        switch section {
        case .updates: badgeCount
        case .history: history.filter { Date().timeIntervalSince($0.date) < 30 * 24 * 3600 }.count
        case .applications: rows.count
        case .packages: checkPackages ? visiblePackages.count : 0
        case .pinned: pinnedOrHeld.count
        case .ignored: ignored.count
        case .noSource: noSource.count
        }
    }

    /// "12 of 61 apps and 7 packages have updates · Checked 1 hour ago"
    var summary: String {
        var parts: [String] = []
        if isChecking {
            parts.append("Checking \(checked) of \(toCheck)…")
        } else {
            var line = "\(updates.count) of \(rows.count) apps"
            if checkPackages { line += " and \(visiblePackages.count) packages" }
            line += updates.count + visiblePackages.count == 1 ? " has updates" : " have updates"
            parts.append(line)
        }
        if let lastCheck {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            parts.append("Checked " + f.localizedString(for: lastCheck, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Checking

    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        let scanned = AppScanner.scan()
        let previous = Dictionary(rows.map { ($0.app.id, $0) }, uniquingKeysWith: { a, _ in a })
        rows = scanned.map { app in
            var row = previous[app.id].map { AppRow(app: app, status: $0.status, trace: $0.trace) } ?? AppRow(app: app)
            if row.app.displayVersion != previous[app.id]?.app.displayVersion { row.status = .pending }
            return row
        }
        checked = 0
        toCheck = scanned.count

        Task {
            let communityProblem = await CommunityRules.refresh()
            let (rules, problem) = RulesStore.load()
            rulesProblem = [communityProblem, problem].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
            let checker = UpdateChecker(rules: rules)
            async let packageSurvey: PackageSurvey? = checkPackages ? PackageScanner.survey() : nil
            await withTaskGroup(of: (String, CheckResult).self) { group in
                var pending = scanned[...]
                while group.isEmpty || pending.count > scanned.count - 8, let app = pending.popFirst() {
                    group.addTask { (app.id, await checker.check(app)) }
                }
                while let (id, result) = await group.next() {
                    if let i = rows.firstIndex(where: { $0.id == id }) {
                        rows[i].status = result.status
                        rows[i].trace = result.trace
                    }
                    checked += 1
                    if let app = pending.popFirst() {
                        group.addTask { (app.id, await checker.check(app)) }
                    }
                }
            }
            if let survey = await packageSurvey {
                packages = survey.updates
                packageManagers = survey.available
                packageProblems = survey.problems
            } else {
                packages = []
            }
            isChecking = false
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastCheck")
            saveResults()
            refreshBadge()
            announceNewUpdates()
        }
    }

    /// Install progress wins over check progress; nothing running hides the bar.
    private func updateDock() {
        if let fraction = installing.values.compactMap(\.fraction).first(where: { $0 > 0 && $0 < 1 }) {
            DockProgress.show(fraction)
        } else if isChecking, toCheck > 0 {
            DockProgress.show(Double(checked) / Double(toCheck))
        } else {
            DockProgress.show(nil)
        }
    }

    func refreshBadge() {
        updateDock()
        NSApp.dockTile.badgeLabel = badgeCount > 0 ? "\(badgeCount)" : nil
    }

    // MARK: Preferences

    func updatePreference(_ key: String, _ change: (inout UpdatePreference) -> Void) {
        var pref = preferences[key] ?? UpdatePreference()
        change(&pref)
        preferences[key] = pref.isEmpty ? nil : pref
        Storage.save(preferences, to: "preferences.json")
        refreshBadge()
    }

    func resetPreference(_ key: String) {
        preferences[key] = nil
        Storage.save(preferences, to: "preferences.json")
        refreshBadge()
    }

    // MARK: Installing

    func install(_ row: AppRow) {
        guard let update = row.status.update, installing[row.id] == nil else { return }
        failures[row.id] = nil
        notices[row.id] = nil
        installing[row.id] = InstallState(stage: "Waiting", fraction: nil)
        let app = row.app
        let force = RulesStore.load().rules[app.bundleID]?.quit == "force"
        Task {
            do {
                let outcome = try await Installer.install(app, update: update, forceQuit: force) { stage, fraction in
                    Task { @MainActor in self.installing[app.id] = InstallState(stage: stage.rawValue, fraction: fraction) }
                }
                installing[app.id] = nil
                switch outcome {
                case let .installed(version):
                    record(HistoryEntry(name: app.name, identifier: app.bundleID, from: app.displayVersion, to: version, via: update.source.label))
                    if let fresh = AppScanner.read(app.path), let i = rows.firstIndex(where: { $0.id == app.id }) {
                        rows[i] = AppRow(app: fresh, status: .upToDate(latest: version), trace: rows[i].trace + ["Installed \(version)"])
                    }
                    saveResults()
                case let .handedOff(message):
                    notices[app.id] = message
                    watchForOutsideInstall(of: app)
                }
            } catch {
                let stage = installing[app.id]?.stage
                installing[app.id] = nil
                let known = error as? InstallError
                failures[app.id] = Failure(message: known?.message ?? error.localizedDescription, remedy: known?.remedy, stage: stage)
            }
            refreshBadge()
        }
    }

    func upgrade(_ package: PackageUpdate) {
        guard installing[package.id] == nil else { return }
        failures[package.id] = nil
        installing[package.id] = InstallState(stage: "Upgrading", fraction: nil)
        Task {
            do {
                try await PackageScanner.upgrade(package)
                packages.removeAll { $0.id == package.id }
                saveResults()
                record(HistoryEntry(name: package.name, identifier: package.id, from: package.installed, to: package.latest, via: package.manager.label))
            } catch {
                failures[package.id] = Failure(message: error.localizedDescription)
            }
            installing[package.id] = nil
            refreshBadge()
        }
    }

    /// Installs one at a time: parallel swaps and package managers sharing locks don't mix.
    func updateAll(_ scope: UpdateAllScope? = nil) {
        let scope = scope ?? updateAllScope
        let apps = scope == .packages ? [] : updates.filter { installing[$0.id] == nil }
        let pkgs = scope == .applications || !checkPackages ? [] : visiblePackages.filter { installing[$0.id] == nil }
        queue = apps.map(\.id) + pkgs.map(\.id)
        Task {
            for row in apps {
                guard queue.contains(row.id) else { continue }
                install(row)
                while installing[row.id] != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
                queue.removeAll { $0 == row.id }
            }
            for package in pkgs {
                guard queue.contains(package.id) else { continue }
                upgrade(package)
                while installing[package.id] != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
                queue.removeAll { $0 == package.id }
            }
            queue = []
        }
    }

    func cancelQueue() { queue = [] }

    private func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        history.removeAll { $0.date < cutoff }
        Storage.save(history, to: "history.json")
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Each update is mentioned once; silenced apps never.
    private func announceNewUpdates() {
        guard notificationsEnabled else { return }
        let items = Announcer.items(apps: rows.map { ($0.app, $0.status) }, packages: packages, preferences: preferences)
        Task { await Announcer.announce(items) }
    }

    // MARK: Background agent

    var backgroundChecks: Bool {
        get { SMAppService.agent(plistName: BackgroundCheck.agentPlist).status == .enabled }
        set {
            let service = SMAppService.agent(plistName: BackgroundCheck.agentPlist)
            do {
                if newValue { try service.register() } else { try service.unregister() }
                notices["backgroundChecks"] = service.status == .requiresApproval
                    ? "Allow Uppdatera in System Settings → General → Login Items & Extensions." : nil
            } catch {
                notices["backgroundChecks"] = error.localizedDescription
            }
        }
    }

    // MARK: Uninstall

    /// Moves the app and the chosen leftovers to the Trash, then drops it from the lists.
    func uninstall(_ row: AppRow, leftovers: [URL]) async throws -> [String] {
        var caskToken: String?
        if let cask = await CaskCatalogue.shared.entry(forAppNamed: row.app.fileName), CaskCatalogue.installedToken(cask.token) {
            caskToken = cask.token
        }
        let result = try await Uninstaller.uninstall(row.app, leftovers: leftovers, caskToken: caskToken)
        rows.removeAll { $0.id == row.id }
        failures[row.id] = nil
        notices[row.id] = nil
        queue.removeAll { $0 == row.id }
        saveResults()
        refreshBadge()
        return result.problems
    }

    // MARK: Diagnostics

    func copyDiagnostics(for row: AppRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(for: row), forType: .string)
    }

    func diagnostics(for row: AppRow) -> String {
        let me = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var lines = [
            "Uppdatera diagnostics",
            "Uppdatera \(me) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(MachineArch.current)",
            "App: \(row.app.name) (\(row.app.bundleID))",
            "Path: \(row.app.path.path)",
            "Installed: \(row.app.shortVersion ?? "-") (build \(row.app.buildVersion ?? "-"))",
            "Sparkle feed: \(row.app.sparkleFeedURL?.absoluteString ?? "none")",
            "App Store: \(row.app.isAppStore)",
            "Status: \(row.status)",
        ]
        if let update = row.status.update {
            lines.append("Offered: \(update.version) from \(update.source.label), download \(update.downloadURL?.absoluteString ?? "none")")
        }
        if let failure = failures[row.id] {
            lines.append("Install failed\(failure.stage.map { " while \($0.lowercased())" } ?? ""): \(failure.message)")
        }
        lines.append("Trace:")
        lines += row.trace.map { "  - \($0)" }
        return lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
