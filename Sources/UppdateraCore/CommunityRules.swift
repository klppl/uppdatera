import Foundation

/// Rules shared through the project's repository (`rules/rules.json`), so a fix one person
/// makes reaches everyone on their next check. Fetched at most every six hours, and only
/// downloaded again when the file changed (ETag). Rules can't weaken the installer: a
/// download must still be notarized and signed by the installed app's developer.
public enum CommunityRules {
    public struct Status: Codable, Sendable {
        public var url: String
        public var fetchedAt: Date
        public var etag: String?
        public var count: Int
        public var skipped: [String]
        public var problem: String?
    }

    private static let defaultsKey = "communityRulesURL"
    private static var cacheURL: URL { Storage.caches.appendingPathComponent("community-rules.json") }
    private static var statusURL: URL { Storage.caches.appendingPathComponent("community-rules-status.json") }
    private static let maxAge: TimeInterval = 6 * 3600

    /// Settings can switch community rules off.
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "communityRules") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "communityRules") }
    }

    /// Set at build time (RULES_URL, or derived from REPO) and overridable in Settings.
    public static var defaultURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "UppdateraRulesURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    public static var url: URL? {
        if let custom = UserDefaults.standard.string(forKey: defaultsKey), !custom.isEmpty { return URL(string: custom) }
        return defaultURL
    }

    public static func setCustomURL(_ value: String?) {
        UserDefaults.standard.set(value?.trimmingCharacters(in: .whitespaces), forKey: defaultsKey)
        try? FileManager.default.removeItem(at: statusURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    public static var status: Status? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Status.self, from: data)
    }

    public static func cached() -> DecodedRules? {
        // Only the copy fetched from the address in use counts.
        guard let url, status?.url == url.absoluteString,
              let data = try? Data(contentsOf: cacheURL), let rules = try? RulesStore.decode(data),
              rules.schemaVersion <= RulesDocument.currentSchema else { return nil }
        return rules
    }

    /// Brings the cached copy up to date. Returns a problem to show, or nil.
    @discardableResult
    public static func refresh(force: Bool = false) async -> String? {
        guard enabled, let url else { return nil }
        let previous = status.flatMap { $0.url == url.absoluteString ? $0 : nil }
        if !force, let previous, previous.problem == nil, Date().timeIntervalSince(previous.fetchedAt) < maxAge { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = previous?.etag, cached() != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        var next = previous ?? Status(url: url.absoluteString, fetchedAt: Date(), etag: nil, count: 0, skipped: [], problem: nil)
        next.fetchedAt = Date()
        defer { save(next) }
        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 304 {
                next.problem = nil
                return nil
            }
            guard (200..<300).contains(code) else { throw HTTP.Failure(message: "The rules server answered \(code)") }
            let rules = try RulesStore.decode(data)
            guard rules.schemaVersion <= RulesDocument.currentSchema else {
                throw HTTP.Failure(message: "The community rules need a newer Uppdatera; the copy you have is still used.")
            }
            try data.write(to: cacheURL, options: .atomic)
            next.etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            next.count = rules.apps.count
            next.skipped = rules.skipped.keys.sorted()
            next.problem = nil
            return nil
        } catch {
            next.problem = error.localizedDescription
            return "Community rules couldn't be updated: \(error.localizedDescription)"
        }
    }

    private static func save(_ status: Status) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) { try? data.write(to: statusURL, options: .atomic) }
    }
}
