import Foundation
import Security

/// Where GitHub requests get their token. Without one GitHub allows 60 requests an hour;
/// with one, 5,000. In order: the token saved in Settings (Keychain), `GITHUB_TOKEN`,
/// then the GitHub CLI's login (`gh auth token`).
public enum GitHubAuth {
    public enum Origin: String, Sendable {
        case settings = "Your token in Settings"
        case environment = "GITHUB_TOKEN"
        case githubCLI = "GitHub CLI login (gh)"
        case none = "No token (60 requests an hour)"
    }

    private static let service = "app.uppdatera.Uppdatera.github"

    public static func savedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    /// Saves (or with nil or "", removes) the Settings token.
    public static func save(_ token: String?) async throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrLabel as String] = "Uppdatera GitHub token"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw HTTP.Failure(message: "The Keychain refused the token (\(status)).")
            }
        }
        await Cache.shared.reset()
    }

    public static func current() async -> (token: String?, origin: Origin) {
        await Cache.shared.resolve()
    }

    /// Requests left this hour and the hourly limit, as GitHub reports them for the current token.
    public static func rateLimit() async -> (remaining: Int, limit: Int)? {
        var headers = ["Accept": "application/vnd.github+json"]
        if let token = await current().token { headers["Authorization"] = "Bearer \(token)" }
        guard let json = try? await HTTP.json(URL(string: "https://api.github.com/rate_limit")!, headers: headers),
              let remaining = valueAt(path: "resources.core.remaining", in: json) as? Int,
              let limit = valueAt(path: "resources.core.limit", in: json) as? Int else { return nil }
        return (remaining, limit)
    }

    actor Cache {
        static let shared = Cache()
        private var resolved: (String?, Origin)?

        func reset() { resolved = nil }

        func resolve() async -> (token: String?, origin: Origin) {
            if let resolved { return resolved }
            var answer: (String?, Origin) = (nil, .none)
            if let t = GitHubAuth.savedToken() {
                answer = (t, .settings)
            } else if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !t.isEmpty {
                answer = (t, .environment)
            } else if let r = try? await Command.shell("command -v gh >/dev/null && gh auth token", timeout: 10), r.succeeded {
                let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { answer = (t, .githubCLI) }
            }
            resolved = answer
            return answer
        }
    }
}
