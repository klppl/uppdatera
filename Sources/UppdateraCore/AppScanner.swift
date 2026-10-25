import Foundation

public enum AppScanner {
    public static var defaultRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// Finds application bundles in the roots and in folders one level down
    /// (e.g. `/Applications/Utilities/Foo.app`, `/Applications/Vendor/Foo.app`).
    public static func scan(roots: [URL] = defaultRoots) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        func visit(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                if entry.pathExtension == "app" {
                    if let app = read(entry), seen.insert(app.path.resolvingSymlinksInPath().path).inserted {
                        apps.append(app)
                    }
                } else if depth < 1, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func read(_ url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        let feed = (info["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let isSetapp = url.path.contains("/Setapp/") || bundleID.hasSuffix("-setapp")
        return InstalledApp(
            path: url,
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            buildVersion: info["CFBundleVersion"] as? String,
            sparkleFeedURL: feed,
            isAppStore: FileManager.default.fileExists(atPath: receipt.path),
            isSetapp: isSetapp
        )
    }
}
