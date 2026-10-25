import AppKit
import Foundation

public enum InstallStage: String, Sendable {
    case downloading = "Downloading"
    case unpacking = "Unpacking"
    case verifying = "Checking signature"
    case quitting = "Quitting the app"
    case replacing = "Replacing"
    case relaunching = "Reopening"
    case brew = "Running Homebrew"
    case appStore = "Updating from the App Store"
}

public struct InstallError: LocalizedError, Sendable {
    public enum Remedy: Sendable, Hashable {
        case openAppManagementSettings
        case openPage(URL)
    }
    public let message: String
    public let remedy: Remedy?

    public init(_ message: String, remedy: Remedy? = nil) {
        self.message = message
        self.remedy = remedy
    }
    public var errorDescription: String? { message }
}

public enum InstallOutcome: Sendable {
    case installed(version: String)
    case handedOff(String)
}

/// Replaces an installed app with a downloaded one, refusing anything that isn't notarized and
/// signed by the same developer team as the installed copy. The old copy goes to the Trash.
public enum Installer {
    public typealias Progress = @Sendable (InstallStage, Double?) -> Void

    public static func install(_ app: InstalledApp, update: UpdateInfo, forceQuit: Bool = false,
                               progress: @escaping Progress) async throws -> InstallOutcome {
        if update.source == .appStore || app.isAppStore {
            return try await appStoreUpdate(app, update: update, progress: progress)
        }
        if let token = update.caskToken {
            progress(.quitting, nil)
            let wasRunning = try await quit(app, force: forceQuit)
            let outcome = try await brewUpgradeCask(token, app: app, progress: progress)
            if wasRunning {
                progress(.relaunching, nil)
                await relaunch(app.path)
            }
            return outcome
        }
        guard let downloadURL = update.downloadURL else {
            throw InstallError("There is no download address for this update.", remedy: update.pageURL.map(InstallError.Remedy.openPage))
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("uppdatera-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading, 0)
        let file = try await download(downloadURL, into: work) { progress(.downloading, $0) }

        progress(.unpacking, nil)
        let (candidate, cleanup) = try await unpack(file, in: work, lookingFor: app)
        defer { cleanup() }
        guard let candidate else {
            if isPackage(file) {
                // Keep the package around for Installer.app; the temp folder would delete it.
                let kept = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/\(file.lastPathComponent)")
                try? FileManager.default.copyItem(at: file, to: kept)
                _ = await MainActor.run { NSWorkspace.shared.open(kept) }
                return .handedOff("This update is an installer package. It's open in Installer.")
            }
            throw InstallError("The download didn't contain \(app.fileName).", remedy: update.pageURL.map(InstallError.Remedy.openPage))
        }

        progress(.verifying, nil)
        try await verify(candidate, replacing: app)

        // Stage beside the app, so the swap is on one volume and atomic.
        let parent = app.path.deletingLastPathComponent()
        removeStaleStaging(in: parent)
        let stagingDir = parent.appendingPathComponent(".uppdatera-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var staged = candidate
        var stagedBeside = false
        if (try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: false)) != nil {
            let dest = stagingDir.appendingPathComponent(app.fileName)
            let r = try await Command.run("/usr/bin/ditto", [candidate.path, dest.path])
            if r.succeeded { staged = dest; stagedBeside = true }
        }
        defer { if stagedBeside { try? FileManager.default.removeItem(at: stagingDir) } }

        progress(.quitting, nil)
        let wasRunning = try await quit(app, force: forceQuit)

        progress(.replacing, nil)
        if stagedBeside {
            try await swap(staged, into: app)
        } else {
            try await privilegedReplace(app.path, with: staged)
        }
        let installed = AppScanner.read(app.path)?.displayVersion ?? update.version

        if wasRunning {
            progress(.relaunching, nil)
            await relaunch(app.path)
        }
        return .installed(version: installed)
    }

    /// Staging folders left by an install that was killed part-way. Only ours, and only old ones.
    static func removeStaleStaging(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".uppdatera-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: entry) }
        }
    }

    // MARK: Self-update

    /// Replaces the running Uppdatera. A running app's bundle can be swapped safely (its code is
    /// already loaded), so this skips the quit step; the caller relaunches afterwards.
    public static func installSelf(_ update: UpdateInfo, progress: @escaping Progress) async throws {
        guard let me = AppScanner.read(Bundle.main.bundleURL), let downloadURL = update.downloadURL else {
            throw InstallError("Uppdatera can't find itself or the download.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("uppdatera-self-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        progress(.downloading, 0)
        let file = try await download(downloadURL, into: work) { progress(.downloading, $0) }
        progress(.unpacking, nil)
        let (candidate, cleanup) = try await unpack(file, in: work, lookingFor: me)
        defer { cleanup() }
        guard let candidate else { throw InstallError("The download didn't contain Uppdatera.") }
        progress(.verifying, nil)
        try await verify(candidate, replacing: me)
        let stagingDir = me.path.deletingLastPathComponent().appendingPathComponent(".uppdatera-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let staged = stagingDir.appendingPathComponent(me.fileName)
        guard try await Command.run("/usr/bin/ditto", [candidate.path, staged.path]).succeeded else {
            throw InstallError("The new version couldn't be copied beside the old one.")
        }
        progress(.replacing, nil)
        try await swap(staged, into: me)
    }

    // MARK: Download

    final class DownloadDelegate: NSObject, URLSessionTaskDelegate {
        let onProgress: @Sendable (Double) -> Void
        var observation: NSKeyValueObservation?
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in onProgress(p.fractionCompleted) }
        }
    }

    static func download(_ url: URL, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: progress)
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError("The download failed: the server answered \(http.statusCode).")
        }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let dest = dir.appendingPathComponent(name.isEmpty ? "download" : name)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // MARK: Unpack

    enum Archive { case dmg, zip, pkg, tar, unknown }

    static func kind(of file: URL) -> Archive {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        // The disk image trailer goes first: a compressed image's first bytes look like gzip or bzip2.
        if let size = try? handle.seekToEnd(), size > 512 {
            try? handle.seek(toOffset: size - 512)
            if let tail = try? handle.read(upToCount: 4), tail == Data("koly".utf8) { return .dmg }
        }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.starts(with: Array("xar!".utf8)) { return .pkg }
        if head.starts(with: [0x1F, 0x8B]) || head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A]) || head.starts(with: Array("BZh".utf8)) {
            return .tar
        }
        switch file.pathExtension.lowercased() {
        case "dmg": return .dmg
        case "zip": return .zip
        case "pkg", "mpkg": return .pkg
        default: return .unknown
        }
    }

    static func isPackage(_ file: URL) -> Bool { kind(of: file) == .pkg }

    static func unpack(_ file: URL, in work: URL, lookingFor app: InstalledApp) async throws -> (URL?, () -> Void) {
        let out = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        switch kind(of: file) {
        case .zip:
            let r = try await Command.run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
            guard r.succeeded else { throw InstallError("The zip archive could not be opened: \(r.stderr)") }
            return (findApp(in: out, matching: app), {})
        case .tar:
            let r = try await Command.run("/usr/bin/tar", ["-xf", file.path, "-C", out.path])
            guard r.succeeded else { throw InstallError("The archive could not be opened: \(r.stderr)") }
            return (findApp(in: out, matching: app), {})
        case .dmg, .unknown:
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            // "Y" answers the licence agreement some disk images show.
            let r = try await Command.run("/usr/bin/hdiutil",
                                          ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path],
                                          input: "Y\n", timeout: 180)
            guard r.succeeded else {
                throw InstallError("The disk image could not be opened: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let detach: () -> Void = {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["detach", mount.path, "-force", "-quiet"]
                try? p.run()
                p.waitUntilExit()
            }
            return (findApp(in: mount, matching: app), detach)
        case .pkg:
            return (nil, {})
        }
    }

    static func findApp(in dir: URL, matching app: InstalledApp) -> URL? {
        var candidates: [URL] = []
        let fm = FileManager.default
        func walk(_ url: URL, depth: Int) {
            guard depth <= 3, let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
            for entry in entries {
                // Skip symlinks such as the "Applications" shortcut in disk images.
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                if entry.pathExtension == "app" { candidates.append(entry) } else { walk(entry, depth: depth + 1) }
            }
        }
        walk(dir, depth: 0)
        if let exact = candidates.first(where: { AppScanner.read($0)?.bundleID == app.bundleID }) { return exact }
        return nil
    }

    // MARK: Verify

    static func teamID(of url: URL) async -> String? {
        guard let r = try? await Command.run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path]) else { return nil }
        let text = r.stderr + r.stdout
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        return team == "not set" ? nil : team
    }

    static func verify(_ candidate: URL, replacing app: InstalledApp) async throws {
        guard let new = AppScanner.read(candidate), new.bundleID == app.bundleID else {
            throw InstallError("The downloaded app has a different identity than the installed one. Nothing was changed.")
        }
        if let installed = AppVersion(app.displayVersion), let offered = AppVersion(new.displayVersion), offered < installed {
            throw InstallError("The download is version \(new.displayVersion), older than the installed \(app.displayVersion). Nothing was changed.")
        }

        let sig = try await Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        guard sig.succeeded else {
            throw InstallError("The download's signature isn't valid, so it may be damaged or tampered with. Nothing was changed.")
        }
        let assess = try await Command.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", candidate.path])
        let verdict = assess.stderr + assess.stdout
        guard assess.succeeded, verdict.contains("Notarized") || verdict.contains("Mac App Store") || verdict.contains("Apple System") else {
            throw InstallError("Apple hasn't notarized the download, so Uppdatera won't install it.")
        }
        let installedTeam = await teamID(of: app.path)
        let newTeam = await teamID(of: candidate)
        guard let installedTeam else {
            throw InstallError("The installed copy isn't signed by an identified developer, so there's nothing to check the download against. Update it by hand.")
        }
        guard newTeam == installedTeam else {
            throw InstallError("The download is signed by team \(newTeam ?? "unknown"), but the installed app is signed by \(installedTeam). Uppdatera won't install it.")
        }
    }

    // MARK: Quit / relaunch

    @MainActor
    static func runningCopies(of app: InstalledApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { $0.bundleURL?.standardizedFileURL == app.path.standardizedFileURL }
    }

    static func quit(_ app: InstalledApp, force: Bool) async throws -> Bool {
        let running = await MainActor.run { runningCopies(of: app) }
        guard !running.isEmpty else { return false }
        await MainActor.run {
            for copy in running {
                if force { copy.forceTerminate() } else { copy.terminate() }
            }
        }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if await MainActor.run(body: { runningCopies(of: app).isEmpty }) { return true }
        }
        throw InstallError("\(app.name) didn't quit. Save your work, quit it, and try again.")
    }

    static func relaunch(_ url: URL) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Replace

    static func swap(_ staged: URL, into app: InstalledApp) async throws {
        let rc = renamex_np(staged.path, app.path.path, UInt32(RENAME_SWAP))
        if rc != 0 {
            let code = errno
            if code == EPERM {
                throw InstallError("macOS blocked the change. Turn Uppdatera on under Privacy & Security → App Management, then try again. Nothing was changed.",
                                   remedy: .openAppManagementSettings)
            }
            if code == EACCES {
                try await privilegedReplace(app.path, with: staged)
                return
            }
            throw InstallError("The app couldn't be replaced (\(String(cString: strerror(code)))). Nothing was changed.")
        }
        // `staged` now holds the old version. Trash it so it can be put back.
        let old = staged.deletingLastPathComponent().appendingPathComponent("\(app.name) \(app.displayVersion).app")
        try? FileManager.default.moveItem(at: staged, to: old)
        if (try? FileManager.default.trashItem(at: old, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: old)
        }
        _ = try? await Command.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                   ["-f", app.path.path])
    }

    /// For apps owned by another account: one admin prompt, no resident root helper.
    static func privilegedReplace(_ target: URL, with staged: URL) async throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let oldName = target.deletingPathExtension().lastPathComponent + " (replaced by Uppdatera \(Int(Date().timeIntervalSince1970))).app"
        let owner = (try? FileManager.default.attributesOfItem(atPath: target.path)[.ownerAccountName] as? String) ?? "root"
        let q = Command.quote
        let script = [
            "/bin/mv -f \(q(target.path)) \(q(trash.appendingPathComponent(oldName).path))",
            "/usr/bin/ditto \(q(staged.path)) \(q(target.path))",
            "/usr/sbin/chown -R \(q(owner)) \(q(target.path))",
        ].joined(separator: " && ")
        let source = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let error: String? = await MainActor.run {
            var info: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&info)
            return info.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Unknown error" }
        }
        if let error { throw InstallError("The app couldn't be replaced with administrator rights: \(error)") }
    }

    // MARK: App Store

    /// Installs through `mas` (github.com/mas-cli/mas) when it's installed; otherwise, or when
    /// it fails, opens the app's store page so the user can click Update there.
    static func appStoreUpdate(_ app: InstalledApp, update: UpdateInfo, progress: @escaping Progress) async throws -> InstallOutcome {
        let storePage = update.storeID.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") } ?? update.pageURL
        var why = "Install mas (brew install mas) to let Uppdatera install App Store updates itself."
        if let id = update.storeID, await Command.which("mas") != nil {
            progress(.appStore, nil)
            let r = try await Command.shell("mas upgrade \(id)", timeout: 1800)
            let installed = AppScanner.read(app.path)?.displayVersion
            if r.succeeded, let installed, let now = AppVersion(installed), let old = AppVersion(app.displayVersion), old < now {
                return .installed(version: installed)
            }
            let detail = (r.stderr + r.stdout).split(separator: "\n").last.map(String.init) ?? ""
            why = "mas couldn't install it\(detail.isEmpty ? "" : ": \(detail)")."
        }
        if let storePage { _ = await MainActor.run { NSWorkspace.shared.open(storePage) } }
        return .handedOff("Opened in the App Store; click Update there. \(why)")
    }

    // MARK: Homebrew casks

    static func brewUpgradeCask(_ token: String, app: InstalledApp, progress: @escaping Progress) async throws -> InstallOutcome {
        progress(.brew, nil)
        let r = try await Command.shell("brew upgrade --cask --greedy \(Command.quote(token))", timeout: 1800)
        guard r.succeeded else {
            let detail = r.stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw InstallError("Homebrew couldn't upgrade \(token):\n\(detail)")
        }
        return .installed(version: AppScanner.read(app.path)?.displayVersion ?? "")
    }
}

public enum SystemSettings {
    public static let appManagement = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
}
