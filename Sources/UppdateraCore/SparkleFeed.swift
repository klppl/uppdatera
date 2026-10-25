import Foundation

public struct AppcastItem: Sendable, Hashable {
    public var title: String?
    /// `sparkle:version` — compared with `CFBundleVersion`, as Sparkle itself does.
    public var version: String?
    /// `sparkle:shortVersionString` — the version people see.
    public var shortVersion: String?
    public var downloadURL: URL?
    public var releaseNotesURL: URL?
    public var descriptionHTML: String?
    public var minimumSystemVersion: String?
    public var channel: String?
    public var os: String?
    public var published: Date?
    public var isCritical = false

    public var displayVersion: String? { shortVersion ?? version }
}

public enum AppcastParser {
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// The newest item a stable user on this Mac should get: no beta channel, macOS only,
    /// and a minimum system version this Mac meets.
    public static func newestEligible(_ items: [AppcastItem], channel: String? = nil,
                                      osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> AppcastItem? {
        let current = AppVersion("\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")!
        let eligible = items.filter { item in
            if let c = item.channel, !c.isEmpty, c != channel { return false }
            if let os = item.os, !os.lowercased().hasPrefix("mac") { return false }
            if let min = item.minimumSystemVersion.flatMap(AppVersion.init), current < min { return false }
            return item.downloadURL != nil || item.releaseNotesURL != nil
        }
        return eligible.max { a, b in
            guard let va = (a.version ?? a.shortVersion).flatMap(AppVersion.init) else { return true }
            guard let vb = (b.version ?? b.shortVersion).flatMap(AppVersion.init) else { return false }
            return va < vb
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private static let dateFormats: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = AppcastItem(); return }
            guard current != nil else { return }
            if name == "enclosure" {
                if let url = attributes["url"].flatMap({ URL(string: $0) }) {
                    // Some feeds carry several enclosures (delta, other OS); keep the first macOS one.
                    let os = attributes["sparkle:os"]
                    if current!.downloadURL == nil || (os?.hasPrefix("mac") ?? false) {
                        current!.downloadURL = url
                        current!.os = os
                    }
                }
                if let v = attributes["sparkle:version"], current!.version == nil { current!.version = v }
                if let v = attributes["sparkle:shortVersionString"], current!.shortVersion == nil { current!.shortVersion = v }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard current != nil else { return }
            switch name {
            case "item":
                items.append(current!)
                current = nil
            case "title": current!.title = value
            case "sparkle:version": current!.version = value
            case "sparkle:shortVersionString": current!.shortVersion = value
            case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink":
                if current!.releaseNotesURL == nil { current!.releaseNotesURL = URL(string: value) }
            case "description": if !value.isEmpty { current!.descriptionHTML = value }
            case "sparkle:minimumSystemVersion": current!.minimumSystemVersion = value
            case "sparkle:channel": current!.channel = value
            case "sparkle:criticalUpdate": current!.isCritical = true
            case "pubDate":
                current!.published = Self.dateFormats.lazy.compactMap { $0.date(from: value) }.first
            default: break
            }
        }
    }
}
