import Foundation

public enum Storage {
    public static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uppdatera", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var caches: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uppdatera", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

/// What the user told Uppdatera about one app or package.
public struct UpdatePreference: Codable, Sendable, Hashable {
    public var ignored = false
    /// "Skip this version": hide this exact offer, but show the next one.
    public var skippedVersion: String?
    /// Never offer anything newer than what is installed.
    public var pinned = false
    /// Only offer updates within this major version.
    public var heldMajor: Int?

    public init() {}

    public var isEmpty: Bool { !ignored && skippedVersion == nil && !pinned && heldMajor == nil }

    /// Why an offer should be hidden, or nil when it should be shown.
    public func suppression(of offered: String) -> String? {
        if ignored { return "Ignored" }
        if pinned { return "Pinned at the installed version" }
        if let skippedVersion, skippedVersion == offered { return "You skipped \(offered)" }
        if let heldMajor, let v = AppVersion(offered), v.major > heldMajor { return "Held at version \(heldMajor).x" }
        return nil
    }
}

public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var identifier: String
    public var from: String
    public var to: String
    public var date: Date
    public var via: String

    public init(name: String, identifier: String, from: String, to: String, date: Date = Date(), via: String) {
        self.name = name
        self.identifier = identifier
        self.from = from
        self.to = to
        self.date = date
        self.via = via
    }
}

public enum CheckFrequency: String, Codable, CaseIterable, Sendable, Identifiable {
    case manual, hourly, sixHours, daily, weekly
    public var id: String { rawValue }

    public var interval: TimeInterval? {
        switch self {
        case .manual: nil
        case .hourly: 3600
        case .sixHours: 6 * 3600
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }

    public var label: String {
        switch self {
        case .manual: "Only when I ask"
        case .hourly: "Every hour"
        case .sixHours: "Every six hours"
        case .daily: "Once a day"
        case .weekly: "Once a week"
        }
    }
}
