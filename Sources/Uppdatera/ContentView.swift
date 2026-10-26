import SwiftUI
import UppdateraCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var section: SidebarSection? = .updates
    @State private var selection: String?
    @State private var showInspector = false
    @State private var search = ""
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                SidebarRow(item: .updates)
                SidebarRow(item: .history)
                Section("Library") {
                    SidebarRow(item: .applications)
                    SidebarRow(item: .packages)
                    SidebarRow(item: .noSource)
                }
                Section("Silenced") {
                    SidebarRow(item: .pinned)
                    SidebarRow(item: .ignored)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 230)
        } detail: {
            MainList(section: section ?? .updates, selection: $selection, search: search)
                .frame(minWidth: 380)
                .navigationTitle((section ?? .updates).title)
                .navigationSubtitle(model.summary)
                .inspector(isPresented: $showInspector) {
                    Group {
                        if let id = selection, let row = model.rows.first(where: { $0.id == id }) {
                            AppDetail(row: row)
                        } else {
                            ContentUnavailableView("Select an application", systemImage: "app.dashed",
                                                   description: Text("See what's in its update and how Uppdatera found it."))
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
                }
        }
        .searchable(text: $search, placement: .toolbar)
        .onChange(of: selection) { _, id in
            if let id, model.rows.contains(where: { $0.id == id }) { showInspector = true }
        }
        .onChange(of: section) { _, _ in selection = nil }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .sheet(item: Binding(get: { model.checkLogFor.flatMap { id in model.rows.first { $0.id == id } } },
                             set: { model.checkLogFor = $0?.id })) { row in
            CheckLog(row: row)
        }
        .toolbar {
            ToolbarItemGroup {
                if !model.queue.isEmpty {
                    Button("Cancel Update All", systemImage: "xmark.circle") { model.cancelQueue() }
                }
                Button("Update All", systemImage: "arrow.down.circle.fill") { model.updateAll() }
                    .disabled(model.badgeCount == 0 || !model.queue.isEmpty)
                    .help("Install every update (\(model.updateAllScope.label.lowercased()))")
                Button("Check for Updates", systemImage: "arrow.clockwise") { model.checkNow() }
                    .disabled(model.isChecking)
                    .help("Check for updates now")
                Button("Details", systemImage: "sidebar.right") { showInspector.toggle() }
                    .help("Show or hide the details pane")
            }
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let item: SidebarSection

    var body: some View {
        Label(item.title, systemImage: item.symbol)
            .badge(model.count(for: item))
            .tag(item)
    }
}

// MARK: - Main list

struct MainList: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection
    @Binding var selection: String?
    let search: String

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        switch section {
        case .updates: updatesList
        case .packages: packagesList
        case .history: HistoryList()
        case .applications, .noSource, .pinned, .ignored: appsList
        }
    }

    private var updatesList: some View {
        let apps = model.updates.filter { matches($0.app.name) }
        let packages = model.checkPackages ? model.visiblePackages.filter { matches($0.name) } : []
        return Group {
            if apps.isEmpty && packages.isEmpty {
                if model.isChecking {
                    ContentUnavailableView {
                        Label("Checking for updates", systemImage: "arrow.triangle.2.circlepath")
                    } description: {
                        ProgressView(value: Double(model.checked), total: Double(max(model.toCheck, 1))).frame(width: 200)
                    }
                } else {
                    ContentUnavailableView("Everything is up to date", systemImage: "checkmark.circle")
                }
            } else {
                List(selection: $selection) {
                    if let problem = model.rulesProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if !apps.isEmpty {
                        Section {
                            ForEach(apps) { row in
                                AppRowView(row: row).tag(row.id).contextMenu { AppActions(row: row) }
                            }
                        } header: {
                            SectionHeader(title: "Applications", action: "Update All Apps") { model.updateAll(.applications) }
                        }
                    }
                    if !packages.isEmpty {
                        Section {
                            ForEach(packages) { PackageRowView(package: $0).tag($0.id) }
                        } header: {
                            SectionHeader(title: "Packages", action: "Update All Packages") { model.updateAll(.packages) }
                        }
                    }
                }
            }
        }
    }

    private var appsList: some View {
        let rows = model.rows(for: section).filter { matches($0.app.name) || matches($0.app.bundleID) }
        return Group {
            if rows.isEmpty {
                switch section {
                case .pinned: ContentUnavailableView("No applications are pinned or held", systemImage: "pin.slash")
                case .ignored: ContentUnavailableView("No applications are ignored", systemImage: "bell")
                case .noSource: ContentUnavailableView("Every application has an update source", systemImage: "checkmark.circle")
                default: ContentUnavailableView.search
                }
            } else {
                List(selection: $selection) {
                    if section == .noSource {
                        Label("Uppdatera doesn't know where these apps publish new versions. A rule fixes that: right-click an app and choose Report a Problem to ask for one.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        AppRowView(row: row, showsStatus: true).tag(row.id).contextMenu { AppActions(row: row) }
                    }
                }
            }
        }
    }

    private var packagesList: some View {
        let packages = model.visiblePackages.filter { matches($0.name) }
        return Group {
            if !model.checkPackages {
                ContentUnavailableView("Package checks are off", systemImage: "shippingbox", description: Text("Turn them on in Settings."))
            } else if packages.isEmpty && model.packageProblems.isEmpty {
                ContentUnavailableView(model.isChecking ? "Checking packages" : "All packages are up to date", systemImage: "shippingbox",
                                       description: Text(model.packageManagers.isEmpty ? "" : "Checked " + model.packageManagers.map(\.label).joined(separator: ", ")))
            } else {
                List(selection: $selection) {
                    ForEach(PackageManager.allCases) { manager in
                        let items = packages.filter { $0.manager == manager }
                        if !items.isEmpty || model.packageProblems[manager] != nil {
                            Section {
                                if let problem = model.packageProblems[manager] {
                                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                                }
                                ForEach(items) { PackageRowView(package: $0).tag($0.id) }
                            } header: {
                                SectionHeader(title: manager.label, action: nil) {}
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rows

struct AppIcon: View {
    let url: URL
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: 36, height: 36)
    }
}

/// "26.9.1 → **26.10.0**", never cut: in a tight row the name and badges give way first,
/// and a pair too long for one line puts the new version on a second.
func versionLine(_ from: String, _ to: String?) -> some View {
    let installed = Text(from).foregroundStyle(.secondary)
    let offered = to.map { Text("→  ").foregroundStyle(.tertiary) + Text($0).fontWeight(.semibold) }
    return ViewThatFits(in: .horizontal) {
        HStack(spacing: 0) {
            installed
            if let offered { Text("  ") + offered }
        }
        .fixedSize()
        VStack(alignment: .leading, spacing: 1) {
            installed
            if let offered { offered }
        }
        .fixedSize()
    }
    .lineLimit(1)
}

struct UpdatePill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(Capsule().fill(.tint))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

struct SourcePill: View {
    let text: String
    let symbol: String
    var body: some View {
        // Just the symbol when the row is narrow, never the word broken over several lines.
        ViewThatFits(in: .horizontal) {
            pill(Label(text, systemImage: symbol))
            pill(Label(text, systemImage: symbol).labelStyle(.iconOnly)).help(text)
        }
    }

    private func pill(_ label: some View) -> some View {
        label
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary))
            .fixedSize()
    }
}

struct AppRowView: View {
    @Environment(AppModel.self) private var model
    let row: AppRow
    var showsStatus = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: row.app.path)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                versionLine(row.app.displayVersion, row.status.update?.version).font(.system(size: 12)).monospacedDigit()
                    .help(row.status.update.map { "\(row.app.displayVersion) → \($0.version)" } ?? row.app.displayVersion)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var trailing: some View {
        if let state = model.installing[row.id] {
            InstallProgress(state: state)
        } else if model.failures[row.id] != nil {
            Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                .help("The update failed. Select the app to see why.")
        } else if let reason = model.suppression(for: row) {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        } else if let update = row.status.update {
            HStack(spacing: 8) {
                if update.source == .appStore || row.app.isAppStore {
                    SourcePill(text: "App Store", symbol: "apple.logo")
                } else if update.caskToken != nil {
                    SourcePill(text: "Homebrew", symbol: "mug")
                }
                if model.queue.contains(row.id) {
                    Text("Queued").font(.caption).foregroundStyle(.secondary)
                } else {
                    UpdatePill(title: "Update") { model.install(row) }
                }
            }
        } else if showsStatus {
            statusText.font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch row.status {
        case .pending: Text("Checking…")
        case .upToDate: Text("Up to date")
        case let .unknown(why), let .excluded(why), let .failed(why): Text(why).help(why)
        case .updateAvailable: EmptyView()
        }
    }
}

struct InstallProgress: View {
    let state: InstallState
    var body: some View {
        HStack(spacing: 6) {
            if let f = state.fraction, f > 0 {
                ProgressView(value: f).frame(width: 60)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(state.stage).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AppActions: View {
    @Environment(AppModel.self) private var model
    let row: AppRow

    var body: some View {
        let id = row.app.bundleID
        let pref = model.preferences[id] ?? UpdatePreference()
        if let update = row.status.update {
            Button("Update to \(update.version)") { model.install(row) }
            Button("Ignore This Version") { model.updatePreference(id) { $0.skippedVersion = update.version } }
        }
        Divider()
        Button(pref.pinned ? "Unpin" : "Pin at Current Version") { model.updatePreference(id) { $0.pinned.toggle() } }
        if let major = AppVersion(row.app.displayVersion)?.major {
            Button(pref.heldMajor != nil ? "Release Major Version Hold" : "Hold at Current Major Version (\(major).x)") {
                model.updatePreference(id) { $0.heldMajor = $0.heldMajor == nil ? major : nil }
            }
        }
        Button(pref.ignored ? "Stop Ignoring" : "Ignore App") { model.updatePreference(id) { $0.ignored.toggle() } }
        if !pref.isEmpty {
            Button("Reset Preferences") { model.resetPreference(id) }
        }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.app.path]) }
        if let page = row.status.update?.pageURL {
            Button("Open Release Notes Page") { NSWorkspace.shared.open(page) }
        }
        Button("Show Check Log…") { model.checkLogFor = row.id }
        Button("Copy Diagnostics") { model.copyDiagnostics(for: row) }
        if let url = ProjectLinks.reportProblem(app: row.app, diagnostics: model.diagnostics(for: row)) {
            Button("Report a Problem…") { NSWorkspace.shared.open(url) }
        }
    }
}

/// Links into the project's GitHub repository, set at build time with REPO=owner/name.
enum ProjectLinks {
    static var repo: String? {
        (Bundle.main.object(forInfoDictionaryKey: "UppdateraRepo") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Opens the "An app is wrong" issue form with the app and its diagnostics filled in.
    /// Nothing is sent until the user submits the form on GitHub.
    static func reportProblem(app: InstalledApp, diagnostics: String) -> URL? {
        issue(template: "app-wrong.yml", title: "\(app.name): ", fields: [
            "app": "\(app.name) (\(app.bundleID))",
            "diagnostics": diagnostics,
        ])
    }

    /// Opens the "An update fails to install" form with the step, the error and diagnostics filled in.
    static func reportInstallFailure(row: AppRow, failure: Failure, diagnostics: String) -> URL? {
        let offered = row.status.update?.version
        let step = failure.stage.map { " while \($0.lowercased())" } ?? ""
        return issue(template: "install-failed.yml",
                     title: "\(row.app.name): update\(offered.map { " to \($0)" } ?? "") failed\(step)",
                     fields: [
                         "app": "\(row.app.name) (\(row.app.bundleID))",
                         "update": "\(row.app.displayVersion) → \(offered ?? "?")",
                         "error": (failure.stage.map { "\($0): " } ?? "") + failure.message,
                         "diagnostics": diagnostics,
                     ])
    }

    private static func issue(template: String, title: String, fields: [String: String]) -> URL? {
        guard let repo, var components = URLComponents(string: "https://github.com/\(repo)/issues/new") else { return nil }
        components.queryItems = [URLQueryItem(name: "template", value: template), URLQueryItem(name: "title", value: title)]
            // GitHub refuses very long addresses; the trace is the useful part.
            + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: String($0.value.prefix(5000))) }
        return components.url
    }

    static var reportMissingApp: URL? {
        repo.flatMap { URL(string: "https://github.com/\($0)/issues/new?template=missing-app.yml") }
    }
}

struct PackageRowView: View {
    @Environment(AppModel.self) private var model
    let package: PackageUpdate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            VStack(alignment: .leading, spacing: 3) {
                Text(package.name).font(.system(size: 14, weight: .medium, design: .monospaced))
                versionLine(package.installed, package.latest).font(.system(size: 12)).monospacedDigit()
                if let failure = model.failures[package.id] {
                    Text(failure.message).font(.caption2).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            if let state = model.installing[package.id] {
                InstallProgress(state: state)
            } else {
                SourcePill(text: package.manager.label, symbol: "terminal")
                if model.queue.contains(package.id) {
                    Text("Queued").font(.caption).foregroundStyle(.secondary)
                } else {
                    UpdatePill(title: "Update") { model.upgrade(package) }
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Ignore This Version") { model.updatePreference(package.id) { $0.skippedVersion = package.latest } }
            Button("Ignore \(package.name)") { model.updatePreference(package.id) { $0.ignored = true } }
            Button("Copy Upgrade Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.manager.upgradeCommand(package.name), forType: .string)
            }
        }
    }
}

// MARK: - History

struct HistoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("Nothing has been updated yet", systemImage: "clock")
        } else {
            List(model.history) { entry in
                HStack(spacing: 12) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.identifier) {
                        AppIcon(url: url)
                    } else {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.secondary).frame(width: 36, height: 36)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 14, weight: .medium))
                        versionLine(entry.from, entry.to).font(.system(size: 12))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(entry.via).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}
