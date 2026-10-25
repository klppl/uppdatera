import Foundation

/// A per-app instruction. Built-in rules ship with Uppdatera; the user's
/// `~/Library/Application Support/Uppdatera/rules.json` overrides them key by key.
public struct AppRule: Codable, Sendable, Hashable {
    public struct Source: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case sparkle, github, json, homebrew, appStore, page, redirect, artifact, none
        }
        public var kind: Kind
        /// Feed or JSON URL. `{arch}` becomes `arm64` or `x86_64`.
        public var url: String?
        /// Used instead of `url` on Intel Macs, for vendors that spell the chip some other way.
        public var urlIntel: String?
        /// GitHub `owner/repo`.
        public var repo: String?
        /// Dotted path to the version in a JSON document.
        public var versionPath: String?
        /// Dotted path to the download URL in a JSON document.
        public var downloadPath: String?
        /// Regex picking the GitHub asset; defaults to the best macOS disk image or zip.
        public var assetPattern: String?
        /// Homebrew cask token, when the app's file name doesn't match the cask.
        public var cask: String?
        /// Allow GitHub releases marked pre-release.
        public var prerelease: Bool?
        /// `page`: regex over the page text; `redirect`: regex over the final URL.
        /// The first capture group is the version.
        public var versionPattern: String?
        /// `page`: regex for the download link on the same page (first capture group).
        public var downloadPattern: String?
    }

    /// Where to read release notes when the version source has none.
    /// `{version}`, `{major}` and `{minor}` are filled in from the offered version.
    public struct Notes: Codable, Sendable, Hashable {
        public var url: String
        /// Keep only the HTML between these markers (both optional).
        public var start: String?
        public var end: String?
    }

    public enum Compare: String, Codable, Sendable { case shortVersion, buildVersion }

    public var source: Source?
    public var compare: Compare?
    /// Fixed download address, overriding whatever the source offers.
    /// `{version}`, `{major}`, `{minor}` and `{arch}` are filled in.
    public var download: String?
    /// Used instead of `download` on Intel Macs.
    public var downloadIntel: String?
    public var downloadPage: String?
    /// When set, the app is never checked, and this explains why.
    public var exclude: String?
    /// `force` kills the app instead of asking it to quit.
    public var quit: String?
    public var notes: Notes?
    public var note: String?
}

extension AppRule.Source {
    /// The address to read on this Mac: `urlIntel` on Intel when there is one.
    public func address(arch: String = MachineArch.current) -> String? {
        arch == "x86_64" ? (urlIntel ?? url) : url
    }
}

extension AppRule {
    /// The download template for this Mac: `downloadIntel` on Intel when there is one.
    public func downloadTemplate(arch: String = MachineArch.current) -> String? {
        arch == "x86_64" ? (downloadIntel ?? download) : download
    }

    /// Fills `{version}`, `{major}`, `{minor}` and `{arch}` into a download or notes address.
    public static func fill(_ template: String, version: String, arch: String = MachineArch.current) -> String {
        let v = AppVersion(version)
        return template.replacingOccurrences(of: "{version}", with: version)
            .replacingOccurrences(of: "{major}", with: "\(v?.major ?? 0)")
            .replacingOccurrences(of: "{minor}", with: "\(v.map { $0.numbers.count > 1 ? $0.numbers[1] : 0 } ?? 0)")
            .replacingOccurrences(of: "{arch}", with: arch)
    }
}

public struct RulesDocument: Codable, Sendable {
    /// The newest format this build understands. Bump it only for changes old builds would misread.
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var apps: [String: AppRule]
}

/// A rules file read one entry at a time, so an entry this build can't follow (a source kind
/// added later, a typo) is skipped instead of throwing the whole file away.
public struct DecodedRules: Sendable {
    public var schemaVersion: Int
    public var apps: [String: AppRule]
    /// Bundle id → why it was skipped.
    public var skipped: [String: String]
}

public enum RulesStore {
    public static var userRulesURL: URL { Storage.directory.appendingPathComponent("rules.json") }

    /// Built-in rules, then community rules, then yours; each layer overrides the one before.
    public static func load() -> (rules: [String: AppRule], problem: String?) {
        var rules = builtIn
        var problems: [String] = []
        if CommunityRules.enabled, let community = CommunityRules.cached() {
            rules.merge(community.apps) { _, theirs in theirs }
        }
        if FileManager.default.fileExists(atPath: userRulesURL.path) {
            do {
                let user = try decode(Data(contentsOf: userRulesURL))
                rules.merge(user.apps) { _, mine in mine }
                if !user.skipped.isEmpty {
                    problems.append("Your rules.json has entries Uppdatera can't follow: " + user.skipped.keys.sorted().joined(separator: ", "))
                }
            } catch {
                problems.append("Your rules.json could not be read, so it was left out: \(error.localizedDescription)")
            }
        }
        return (rules, problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }

    public static func decode(_ data: Data) throws -> DecodedRules {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? Int,
              let apps = object["apps"] as? [String: Any] else {
            throw HTTP.Failure(message: "This isn't a rules file: it needs \"schemaVersion\" and \"apps\".")
        }
        var decoded = DecodedRules(schemaVersion: schema, apps: [:], skipped: [:])
        for (id, raw) in apps {
            do {
                let entry = try JSONSerialization.data(withJSONObject: raw)
                decoded.apps[id] = try JSONDecoder().decode(AppRule.self, from: entry)
            } catch let DecodingError.dataCorrupted(context) {
                decoded.skipped[id] = context.debugDescription
            } catch let DecodingError.keyNotFound(key, _) {
                decoded.skipped[id] = "missing \"\(key.stringValue)\""
            } catch let DecodingError.typeMismatch(_, context) {
                decoded.skipped[id] = "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch {
                decoded.skipped[id] = error.localizedDescription
            }
        }
        return decoded
    }

    /// Problems a rule would hit at check time, found ahead of it. Empty means the file is sound.
    public static func validate(_ rules: DecodedRules) -> [String] {
        var issues = rules.skipped.map { "\($0.key): can't be read (\($0.value))" }
        if rules.schemaVersion > RulesDocument.currentSchema {
            issues.append("schemaVersion \(rules.schemaVersion) is newer than this build understands (\(RulesDocument.currentSchema))")
        }
        func regexOK(_ pattern: String?) -> Bool {
            pattern.map { (try? NSRegularExpression(pattern: $0)) != nil } ?? true
        }
        for (id, rule) in rules.apps {
            if !id.contains(".") { issues.append("\(id): doesn't look like a bundle id") }
            if rule.exclude != nil && rule.source != nil { issues.append("\(id): has both exclude and source") }
            guard let source = rule.source else { continue }
            let need: [(Bool, String)]
            switch source.kind {
            case .github: need = [(source.repo?.contains("/") == true, "repo as owner/name")]
            case .sparkle, .artifact: need = [(source.url != nil, "url")]
            case .json: need = [(source.url != nil, "url"), (source.versionPath != nil, "versionPath")]
            case .page, .redirect: need = [(source.url != nil, "url"), (source.versionPattern != nil, "versionPattern")]
            case .homebrew: need = [(source.cask != nil, "cask")]
            case .appStore: need = []
            case .none: need = [(rule.downloadPage != nil, "downloadPage, so people know where to go")]
            }
            for (ok, what) in need where !ok { issues.append("\(id): \(source.kind.rawValue) needs \(what)") }
            for pattern in [source.versionPattern, source.downloadPattern, source.assetPattern] where !regexOK(pattern) {
                issues.append("\(id): \(pattern ?? "") isn't a valid regular expression")
            }
            for (key, value) in [("url", source.url), ("urlIntel", source.urlIntel)] {
                if let value, URL(string: value.replacingOccurrences(of: "{arch}", with: "arm64")) == nil {
                    issues.append("\(id): \(key) isn't a valid address")
                }
            }        }
        return issues.sorted()
    }

    /// Writes a starter file the user can edit.
    public static func createUserFileIfMissing() throws -> URL {
        let url = userRulesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let sample = """
            {
              "schemaVersion": 1,
              "apps": {
                "com.example.SomeApp": {
                  "note": "Example. Replace with a real bundle id (see the app's details in Uppdatera).",
                  "source": { "kind": "github", "repo": "owner/repo" }
                }
              }
            }
            """
            try Data(sample.utf8).write(to: url)
        }
        return url
    }

    static let builtIn: [String: AppRule] = {
        do {
            return try decode(Data(builtInJSON.utf8)).apps
        } catch {
            assertionFailure("Built-in rules do not decode: \(error)")
            return [:]
        }
    }()
}
