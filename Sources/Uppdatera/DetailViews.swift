import SwiftUI
import UppdateraCore
import WebKit

struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let row: AppRow
    @State private var showTrace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            if let failure = model.failures[row.id] { FailureBanner(failure: failure, rowID: row.id) }
            if let notice = model.notices[row.id] {
                Label(notice, systemImage: "info.circle").padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            notes
            Divider()
            DisclosureGroup("How Uppdatera decided", isExpanded: $showTrace) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(row.trace.enumerated()), id: \.offset) { _, line in
                        Text("· " + line).font(.caption).fontDesign(.monospaced).textSelection(.enabled)
                    }
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnostics(for: row), forType: .string)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path.path)).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.app.name).font(.title2.bold())
                Text(row.app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let update = row.status.update {
                    HStack(spacing: 6) {
                        Text(row.app.displayVersion).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text(update.version).fontWeight(.semibold)
                        SourceBadge(text: update.caskToken != nil ? "Homebrew" : update.source.label)
                        if let date = update.published {
                            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Version \(row.app.displayVersion)").foregroundStyle(.secondary)
                }
                if let reason = model.suppression(for: row) {
                    Label(reason, systemImage: "bell.slash").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if let state = model.installing[row.id] {
                    InstallProgress(state: state)
                } else if let update = row.status.update {
                    Button(update.source == .appStore ? "Open in App Store" : "Update") { model.install(row) }
                        .buttonStyle(.borderedProminent)
                }
                Menu("More") { AppActions(row: row) }.fixedSize()
            }
        }
    }

    @ViewBuilder private var notes: some View {
        switch row.status.update?.notes {
        case let .html(html)?: WebView(content: .html(html))
        case let .url(url)?: WebView(content: .url(url))
        case let .markdown(text)?:
            ScrollView {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case let .plain(text)?:
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        case nil:
            ContentUnavailableView {
                Label("No release notes", systemImage: "doc.text")
            } description: {
                switch row.status {
                case .updateAvailable: Text("The source didn't include any.")
                case let .unknown(why), let .excluded(why), let .failed(why): Text(why)
                case .pending: Text("Checking…")
                case .upToDate: Text("This app is up to date.")
                }
            } actions: {
                if let page = row.status.update?.pageURL { Button("Open Release Page") { NSWorkspace.shared.open(page) } }
            }
        }
    }
}

struct SourceBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

struct FailureBanner: View {
    @Environment(AppModel.self) private var model
    let failure: Failure
    let rowID: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(failure.message).textSelection(.enabled)
            Spacer()
            switch failure.remedy {
            case .openAppManagementSettings?:
                Button("Open App Management") { NSWorkspace.shared.open(SystemSettings.appManagement) }
            case let .openPage(url)?:
                Button("Open Download Page") { NSWorkspace.shared.open(url) }
            case nil: EmptyView()
            }
            Button("Dismiss") { model.failures[rowID] = nil }
        }
        .padding(12)
        .background(.red.opacity(0.08))
    }
}

struct WebView: NSViewRepresentable {
    enum Content: Equatable { case html(String), url(URL) }
    let content: Content

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != content else { return }
        context.coordinator.loaded = content
        switch content {
        case let .html(html):
            let page = """
            <html><head><meta name="color-scheme" content="light dark"><style>
            body { font: 13px -apple-system, sans-serif; padding: 8px 16px; line-height: 1.45; }
            a { color: -apple-system-control-accent; } img { max-width: 100%; }
            </style></head><body>\(html)</body></html>
            """
            view.loadHTMLString(page, baseURL: nil)
        case let .url(url):
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Content?
        // Links in release notes open in the browser, not inside the pane.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Checking") {
                Picker("Check for updates", selection: $model.frequency) {
                    ForEach(CheckFrequency.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Check command-line packages (Homebrew, npm, Cargo, uv, pipx, gems)", isOn: $model.checkPackages)
                Toggle("Notify me about new updates, once each", isOn: $model.notificationsEnabled)
                Toggle("Check in the background while Uppdatera is closed", isOn: Binding(get: { model.backgroundChecks }, set: { model.backgroundChecks = $0 }))
                if let note = model.notices["backgroundChecks"] {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Open at login (stays in the menu bar)", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if let problem = model.notices["launchAtLogin"] {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Installing") {
                Picker("Update All installs", selection: $model.updateAllScope) {
                    ForEach(UpdateAllScope.allCases) { Text($0.label).tag($0) }
                }
                Text("Uppdatera installs a download only when Apple has notarized it and it's signed by the same developer as the installed copy. The replaced version goes to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open App Management Settings") { NSWorkspace.shared.open(SystemSettings.appManagement) }
            }
            GitHubTokenSection()
            CommunityRulesSection()
            Section("Your Rules") {
                Text("Rules tell Uppdatera where to look for apps it can't find on its own. Yours override the built-in ones and are read on every check.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Edit My Rules…") {
                        if let url = try? RulesStore.createUserFileIfMissing() { NSWorkspace.shared.open(url) }
                    }
                    Button("Show Data Folder") { NSWorkspace.shared.open(Storage.directory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
