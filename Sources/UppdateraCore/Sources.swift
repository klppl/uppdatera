import Foundation

// MARK: - Homebrew casks

public struct CaskEntry: Sendable, Hashable {
    public let token: String
    public let version: String
    public let url: URL?
    public let homepage: URL?
    public let autoUpdates: Bool
    public let appNames: [String]

    /// Cask versions are often "1.2.3,4567"; the part before the comma is the app's version.
    public var marketingVersion: String { String(version.split(separator: ",").first ?? Substring(version)) }
}

public actor CaskCatalogue {
    public static let shared = CaskCatalogue()
    private static let apiURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    private static let maxAge: TimeInterval = 6 * 3600

    private var byAppName: [String: CaskEntry] = [:]
    private var byToken: [String: CaskEntry] = [:]
    private var loadedAt: Date?

    public func entry(forAppNamed fileName: String) async -> CaskEntry? {
        await loadIfNeeded()
        return byAppName[fileName.lowercased()]
    }

    public func entry(token: String) async -> CaskEntry? {
        await loadIfNeeded()
        return byToken[token]
    }

    /// The token, when Homebrew installed this app (its Caskroom folder exists).
    public nonisolated static func installedToken(_ token: String) -> Bool {
        caskroomVersion(token) != nil
    }

    /// The version Homebrew recorded when it installed the cask (the Caskroom folder name).
    public nonisolated static func caskroomVersion(_ token: String) -> String? {
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            let dir = "\(root)/\(token)"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            return entries.filter { !$0.hasPrefix(".") }.sorted().last ?? ""
        }
        return nil
    }

    private func loadIfNeeded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge { return }
        let cacheURL = Storage.caches.appendingPathComponent("cask.json")
        var data: Data?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < Self.maxAge {
            data = try? Data(contentsOf: cacheURL)
        }
        if data == nil {
            if let (fresh, _) = try? await HTTP.data(Self.apiURL) {
                data = fresh
                try? fresh.write(to: cacheURL, options: .atomic)
            } else {
                data = try? Data(contentsOf: cacheURL) // stale is better than nothing
            }
        }
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var byApp: [String: CaskEntry] = [:]
        var pkgByName: [String: CaskEntry] = [:]
        var tokens: [String: CaskEntry] = [:]
        for raw in list {
            guard let token = raw["token"] as? String, let version = raw["version"] as? String else { continue }
            let apps = Self.appNames(in: raw["artifacts"])
            let entry = CaskEntry(
                token: token, version: version,
                url: (raw["url"] as? String).flatMap(URL.init(string:)),
                homepage: (raw["homepage"] as? String).flatMap(URL.init(string:)),
                autoUpdates: raw["auto_updates"] as? Bool ?? false,
                appNames: apps
            )
            tokens[token] = entry
            // Casks that install a .pkg name no app; match those by their display name instead.
            if apps.isEmpty, Self.installsPackage(raw["artifacts"]) {
                for name in raw["name"] as? [String] ?? [] where byApp["\(name).app".lowercased()] == nil {
                    pkgByName["\(name).app".lowercased()] = entry
                }
            }
            for app in apps {
                let key = app.lowercased()
                // Prefer the plain cask over variants like "-beta" or "@nightly".
                if let existing = byApp[key], existing.token.count <= token.count { continue }
                byApp[key] = entry
            }
        }
        byAppName = pkgByName.merging(byApp) { _, app in app }
        byToken = tokens
        loadedAt = Date()
    }

    private static func installsPackage(_ artifacts: Any?) -> Bool {
        (artifacts as? [Any])?.contains { ($0 as? [String: Any])?["pkg"] != nil } ?? false
    }

    private static func appNames(in artifacts: Any?) -> [String] {
        guard let artifacts = artifacts as? [Any] else { return [] }
        var names: [String] = []
        for artifact in artifacts {
            guard let dict = artifact as? [String: Any], let app = dict["app"] as? [Any] else { continue }
            for item in app {
                if let s = item as? String {
                    names.append((s as NSString).lastPathComponent)
                } else if let pair = item as? [Any] {
                    // ["Source.app", {"target": "Target.app"}]
                    if let target = (pair.last as? [String: Any])?["target"] as? String {
                        names.append((target as NSString).lastPathComponent)
                    } else if let s = pair.first as? String {
                        names.append((s as NSString).lastPathComponent)
                    }
                }
            }
        }
        return names
    }
}

// MARK: - App Store

public enum AppStoreLookup {
    public struct Result: Sendable {
        public let version: String
        public let notes: String?
        public let storeURL: URL?
        public let trackID: Int?
        public let released: Date?
    }

    public static func lookup(bundleID: String) async throws -> Result? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "desktopSoftware"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "us"),
        ]
        let json = try await HTTP.json(components.url!)
        guard let first = (json as? [String: Any])?["results"] as? [[String: Any]],
              let item = first.first, let version = item["version"] as? String else { return nil }
        let date = (item["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Result(
            version: version,
            notes: item["releaseNotes"] as? String,
            storeURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)),
            trackID: item["trackId"] as? Int,
            released: date
        )
    }
}

// MARK: - GitHub

public enum GitHubReleases {
    public struct Release: Sendable {
        public let tag: String
        public let body: String?
        public let pageURL: URL?
        public let assetURL: URL?
        public let published: Date?
        /// True when the API refused (usually the hourly limit) and only the tag was read.
        public var limited = false
    }

    static func authHeaders() async -> [String: String] {
        var headers = ["Accept": "application/vnd.github+json"]
        if let token = await GitHubAuth.current().token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    public static func latest(repo: String, assetPattern: String?, allowPrerelease: Bool) async throws -> Release {
        let headers = await authHeaders()
        let endpoint = allowPrerelease
            ? URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=5")!
            : URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        do {
            let json = try await HTTP.json(endpoint, headers: headers)
            let object: [String: Any]?
            if let list = json as? [[String: Any]] {
                object = list.first { ($0["draft"] as? Bool) != true }
            } else {
                object = json as? [String: Any]
            }
            guard let object, let tag = object["tag_name"] as? String else {
                throw HTTP.Failure(message: "GitHub returned no release for \(repo)")
            }
            let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL)? in
                guard let name = asset["name"] as? String,
                      let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return (name, url)
            }
            return Release(
                tag: tag,
                body: object["body"] as? String,
                pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
                assetURL: pickAsset(assets, pattern: assetPattern),
                published: (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        } catch {
            // Rate limited or API down: the web redirect still names the tag.
            let final = try await HTTP.finalURL(URL(string: "https://github.com/\(repo)/releases/latest")!)
            guard final.path.contains("/releases/tag/") else { throw error }
            let tag = final.lastPathComponent.removingPercentEncoding ?? final.lastPathComponent
            return Release(tag: tag, body: nil, pageURL: final, assetURL: nil, published: nil, limited: true)
        }
    }

    /// The body of the release tagged `v1.2.3` or `1.2.3`, if there is one.
    public static func body(repo: String, version: String) async -> String? {
        let headers = await authHeaders()
        for tag in ["v\(version)", version] {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)"),
                  let json = try? await HTTP.json(url, headers: headers) as? [String: Any] else { continue }
            if let body = json["body"] as? String, !body.isEmpty { return body }
        }
        return nil
    }

    /// Picks the asset most likely to be the Mac app for this machine.
    static func pickAsset(_ assets: [(String, URL)], pattern: String?) -> URL? {
        if let pattern, let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return assets.first { name, _ in
                regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }?.1
        }
        let arm = MachineArch.current == "arm64"
        func score(_ name: String) -> Int {
            let n = name.lowercased()
            guard n.hasSuffix(".dmg") || n.hasSuffix(".zip") || n.hasSuffix(".pkg") else { return -1 }
            if n.contains("blockmap") || n.contains(".sig") || n.contains("sha256") { return -1 }
            if ["linux", "windows", "win32", "win64", ".exe", "appimage"].contains(where: n.contains) { return -1 }
            var s = 1
            if n.hasSuffix(".dmg") { s += 3 } else if n.hasSuffix(".zip") { s += 2 }
            if n.contains("mac") || n.contains("darwin") || n.contains("osx") { s += 4 }
            if n.contains("universal") { s += 3 }
            if arm && (n.contains("arm64") || n.contains("aarch64") || n.contains("apple-silicon")) { s += 5 }
            if !arm && (n.contains("x64") || n.contains("x86_64") || n.contains("intel")) { s += 5 }
            if arm && (n.contains("x64") || n.contains("x86_64") || n.contains("intel")) && !n.contains("universal") { s -= 6 }
            if !arm && (n.contains("arm64") || n.contains("aarch64")) && !n.contains("universal") { s -= 6 }
            return s
        }
        return assets.map { ($0, score($0.0)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0.1
    }
}

public enum MachineArch {
    public static let current: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("arm") ? "arm64" : "x86_64"
    }()
}

// MARK: - Artifacts

/// Reads the version straight out of a vendor's download, for vendors that publish nothing else.
/// The answer is cached against the server's ETag / Last-Modified / size, so the file is only
/// downloaded again when it changes.
public enum ArtifactVersions {
    struct Cached: Codable {
        var signature: String
        var short: String?
        var build: String?
    }

    public static func read(_ url: URL, bundleID: String) async throws -> (String?, String?) {
        let cacheURL = Storage.caches.appendingPathComponent("artifact-versions.json")
        var cache = (try? JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: cacheURL))) ?? [:]
        let head = try await HTTP.head(url)
        let signature = ["ETag", "Last-Modified", "Content-Length"]
            .compactMap { head.value(forHTTPHeaderField: $0) }.joined(separator: "|")
        if !signature.isEmpty, let hit = cache[url.absoluteString], hit.signature == signature {
            return (hit.short, hit.build)
        }
        let probe = InstalledApp(path: URL(fileURLWithPath: "/"), name: "", bundleID: bundleID, shortVersion: nil,
                                 buildVersion: nil, sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("uppdatera-artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = try await Installer.download(url, into: work) { _ in }
        let (found, cleanup) = try await Installer.unpack(file, in: work, lookingFor: probe)
        defer { cleanup() }
        guard let found, let app = AppScanner.read(found) else {
            throw HTTP.Failure(message: "The download holds no app with id \(bundleID)")
        }
        cache[url.absoluteString] = Cached(signature: signature, short: app.shortVersion, build: app.buildVersion)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        return (app.shortVersion, app.buildVersion)
    }
}
