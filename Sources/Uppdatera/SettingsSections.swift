import SwiftUI
import UppdateraCore

/// Settings section for the GitHub token: shows which token is in use and the hourly allowance.
struct GitHubTokenSection: View {
    @State private var draft = ""
    @State private var hasSaved = GitHubAuth.savedToken() != nil
    @State private var origin: GitHubAuth.Origin?
    @State private var limit: (remaining: Int, limit: Int)?
    @State private var problem: String?

    var body: some View {
        Section("GitHub") {
            Text("Uppdatera reads GitHub releases for many apps. Without a token GitHub allows 60 requests an hour; with one, 5,000. A token with no scopes is enough.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("In use") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(origin?.rawValue ?? "…")
                    if let limit { Text("\(limit.remaining) of \(limit.limit) requests left this hour").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                SecureField(hasSaved ? "Replace your saved token" : "Paste a personal access token", text: $draft)
                Button("Save") { Task { await save(draft) } }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasSaved { Button("Remove") { Task { await save(nil) } } }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/tokens/new?description=Uppdatera")!)
                .font(.caption)
        }
        .task { await refresh() }
    }

    private func save(_ token: String?) async {
        do {
            try await GitHubAuth.save(token)
            draft = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        hasSaved = GitHubAuth.savedToken() != nil
        await refresh()
        if token != nil, origin == .settings, limit == nil {
            problem = "GitHub didn't accept that token."
        }
    }

    private func refresh() async {
        origin = await GitHubAuth.current().origin
        limit = await GitHubAuth.rateLimit()
    }
}

/// Settings section for the shared rules from the project's repository.
struct CommunityRulesSection: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = CommunityRules.enabled
    @State private var status = CommunityRules.status
    @State private var customURL = UserDefaults.standard.string(forKey: "communityRulesURL") ?? ""
    @State private var updating = false
    @State private var problem: String?

    var body: some View {
        Section("Community Rules") {
            Text("Rules people share in Uppdatera's repository, so a fix for one app reaches everyone. They override the built-in rules; your own rules override both. Downloads are still only installed when notarized and signed by the app's developer.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use community rules", isOn: $enabled)
                .onChange(of: enabled) { _, on in CommunityRules.enabled = on }
            if enabled {
                LabeledContent("Status") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(statusLine)
                        if let skipped = status?.skipped, !skipped.isEmpty {
                            Text("\(skipped.count) need a newer Uppdatera").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("Rules address", text: $customURL, prompt: Text(CommunityRules.defaultURL?.absoluteString ?? "https://…/rules.json"))
                    Button("Use") {
                        CommunityRules.setCustomURL(customURL)
                        Task { await update() }
                    }
                }
                Button(updating ? "Updating…" : "Update Now") { Task { await update() } }
                    .disabled(updating || CommunityRules.url == nil)
                if let problem = problem ?? status?.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var statusLine: String {
        guard CommunityRules.url != nil else { return "Not set up in this build" }
        guard let status else { return "Not downloaded yet" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "\(status.count) apps · updated \(f.localizedString(for: status.fetchedAt, relativeTo: Date()))"
    }

    private func update() async {
        updating = true
        problem = await CommunityRules.refresh(force: true)
        status = CommunityRules.status
        updating = false
    }
}
