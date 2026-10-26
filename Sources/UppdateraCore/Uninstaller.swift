import AppKit
import Foundation

/// Removes an app and, when asked, the files it left in the user's Library.
/// Everything goes to the Trash, so an uninstall can always be put back.
public enum Uninstaller {
    public struct Leftover: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public let url: URL
        /// The Library folder it's in, e.g. "Caches", for the list.
        public let place: String
        public let size: Int64
        /// Ticked to start with. Off for folders that can hold the user's own data, and for name matches.
        public let suggested: Bool
    }

    public struct Result: Sendable {
        /// What couldn't be done; the app itself is gone when this is returned.
        public var problems: [String] = []
    }

    /// Where apps keep files named after their bundle id, the endings they use, and whether
    /// removing them is the usual choice. Application Support and Containers can hold documents.
    static let places: [(folder: String, endings: [String], suggested: Bool)] = [
        ("Caches", [""], true),
        ("Preferences", [".plist"], true),
        ("Saved Application State", [".savedState"], true),
        ("HTTPStorages", ["", ".binarycookies"], true),
        ("WebKit", [""], true),
        ("Logs", [""], true),
        ("Cookies", [".binarycookies"], true),
        ("Application Scripts", [""], true),
        ("Application Support", [""], false),
        ("Containers", [""], false),
    ]
    /// Folders some apps name after themselves instead of their bundle id. Listed, never ticked.
    static let namedPlaces = ["Application Support", "Caches", "Logs"]

    public static var userLibrary: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library") }

    /// Apple's apps belong to macOS, and Uppdatera can't remove itself while it runs.
    public static func canUninstall(_ app: InstalledApp) -> Bool {
        !app.isAppleFirstParty && app.bundleID != Bundle.main.bundleIdentifier && !app.path.path.hasPrefix("/System/")
    }

    /// Files the app left in `library`, matched by its exact bundle id (and, unticked, its name).
    /// Symbolic links are skipped, and nothing outside `library` is ever returned.
    public static func leftovers(for app: InstalledApp, library: URL = userLibrary) -> [Leftover] {
        guard canUninstall(app), app.bundleID.contains("."), !app.bundleID.contains("/") else { return [] }
        let fm = FileManager.default
        var found: [Leftover] = []
        var seen = Set<String>()
        func add(_ folder: String, _ name: String, suggested: Bool) {
            guard !name.isEmpty, !name.contains("/"), name != "." && name != ".." else { return }
            let url = library.appendingPathComponent(folder).appendingPathComponent(name)
            guard seen.insert(url.path).inserted, fm.fileExists(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            found.append(Leftover(url: url, place: folder, size: size(of: url), suggested: suggested))
        }
        for (folder, endings, suggested) in places {
            for ending in endings { add(folder, app.bundleID + ending, suggested: suggested) }
        }
        for folder in namedPlaces { add(folder, app.name, suggested: false) }
        return found
    }

    /// Bytes on disk, counting everything inside a folder.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let item = items?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Quits the app, moves it and the chosen leftovers to the Trash, and has Homebrew forget it
    /// when Homebrew installed it. Homebrew runs after the app is in the Trash, because on its
    /// own it would delete the app for good.
    public static func uninstall(_ app: InstalledApp, leftovers: [URL], caskToken: String?) async throws -> Result {
        guard canUninstall(app) else { throw InstallError("\(app.name) is part of macOS or is Uppdatera itself, so it can't be uninstalled here.") }
        _ = try await Installer.quit(app, force: false)
        try await trash(app.path)

        var result = Result()
        for url in leftovers where url.path.hasPrefix(userLibrary.path + "/") {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                result.problems.append("\(url.lastPathComponent) stayed in \(url.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let caskToken {
            let r = try? await Command.shell("brew uninstall --cask \(Command.quote(caskToken))", timeout: 600)
            if r?.succeeded != true {
                result.problems.append("Homebrew still lists \(caskToken). Run `brew uninstall --cask \(caskToken)` to tidy that up.")
            }
        }
        return result
    }

    /// The Trash, asking for an administrator password when another account owns the app.
    static func trash(_ url: URL) async throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            if posix == Int(EPERM) {
                throw InstallError("macOS blocked the change. Turn Uppdatera on under Privacy & Security → App Management, then try again. Nothing was changed.",
                                   remedy: .openAppManagementSettings)
            }
            guard posix == Int(EACCES) || error.code == NSFileWriteNoPermissionError else {
                throw InstallError("\(url.lastPathComponent) couldn't be moved to the Trash: \(error.localizedDescription)")
            }
            try await privilegedTrash(url)
        }
    }

    /// One admin prompt, like updates of apps owned by another account.
    static func privilegedTrash(_ url: URL) async throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let name = url.deletingPathExtension().lastPathComponent + " (removed by Uppdatera \(Int(Date().timeIntervalSince1970))).app"
        let script = "/bin/mv -f \(Command.quote(url.path)) \(Command.quote(trash.appendingPathComponent(name).path))"
        let source = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let error: String? = await MainActor.run {
            var info: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&info)
            return info.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Unknown error" }
        }
        if let error { throw InstallError("\(url.lastPathComponent) couldn't be moved to the Trash with administrator rights: \(error)") }
    }
}
