import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { path.path }
    public let path: URL
    public let name: String
    public let bundleID: String
    public let shortVersion: String?
    public let buildVersion: String?
    public let sparkleFeedURL: URL?
    public let isAppStore: Bool
    public let isSetapp: Bool

    public init(path: URL, name: String, bundleID: String, shortVersion: String?, buildVersion: String?,
                sparkleFeedURL: URL?, isAppStore: Bool, isSetapp: Bool) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.sparkleFeedURL = sparkleFeedURL
        self.isAppStore = isAppStore
        self.isSetapp = isSetapp
    }

    public var displayVersion: String { shortVersion ?? buildVersion ?? "?" }
    public var isAppleFirstParty: Bool { bundleID.hasPrefix("com.apple.") }
    public var fileName: String { path.lastPathComponent }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case rule, sparkle, homebrew, appStore, github, json, vendor

    public var label: String {
        switch self {
        case .rule: "Rule"
        case .sparkle: "Sparkle"
        case .homebrew: "Homebrew"
        case .appStore: "App Store"
        case .github: "GitHub"
        case .json: "Vendor JSON"
        case .vendor: "Vendor site"
        }
    }
}

public enum ReleaseNotes: Hashable, Sendable, Codable {
    case html(String)
    case markdown(String)
    case plain(String)
    case url(URL)
}

public struct UpdateInfo: Hashable, Sendable, Codable {
    public var version: String
    public var build: String?
    public var downloadURL: URL?
    public var pageURL: URL?
    public var notes: ReleaseNotes?
    public var source: SourceKind
    public var published: Date?
    /// Set when the app was installed by Homebrew; installing then runs `brew upgrade --cask`.
    public var caskToken: String?
    /// App Store item id, for opening the store page.
    public var storeID: Int?

    public init(version: String, build: String? = nil, downloadURL: URL? = nil, pageURL: URL? = nil,
                notes: ReleaseNotes? = nil, source: SourceKind, published: Date? = nil,
                caskToken: String? = nil, storeID: Int? = nil) {
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.pageURL = pageURL
        self.notes = notes
        self.source = source
        self.published = published
        self.caskToken = caskToken
        self.storeID = storeID
    }
}

public enum AppStatus: Hashable, Sendable, Codable {
    case pending
    case upToDate(latest: String?)
    case updateAvailable(UpdateInfo)
    case unknown(String)
    case excluded(String)
    case failed(String)

    public var update: UpdateInfo? {
        if case let .updateAvailable(info) = self { return info }
        return nil
    }
}

public struct CheckResult: Sendable {
    public var status: AppStatus
    /// Each source tried and what it said, shown in the detail pane.
    public var trace: [String]

    public init(status: AppStatus, trace: [String]) {
        self.status = status
        self.trace = trace
    }
}
