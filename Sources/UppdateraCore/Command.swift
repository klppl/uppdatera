import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
}

public struct CommandError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum Command {
    /// The user's tools live outside the GUI app's PATH, so add the usual places.
    public static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/go/bin", "\(home)/Library/pnpm",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (extra + [existing]).joined(separator: ":")
    }()

    public static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                           timeout: TimeInterval = 600) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"] = "1"
                env["NO_COLOR"] = "1"
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let inPipe = Pipe()
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

                do { try process.run() } catch {
                    continuation.resume(throwing: CommandError(message: "Could not run \(executable): \(error.localizedDescription)"))
                    return
                }
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }

                // Drain both pipes concurrently, or a chatty process fills one and blocks.
                let lock = NSLock()
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = d; lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    let d = err.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = d; lock.unlock()
                    group.leave()
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                group.wait()
                killer.cancel()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Runs through a login shell so the user's PATH and tool managers (nvm, asdf…) apply.
    public static func shell(_ script: String, timeout: TimeInterval = 600) async throws -> CommandResult {
        // /etc/zprofile's path_helper rebuilds PATH, so put the tool folders back afterwards.
        try await run("/bin/zsh", ["-lc", "export PATH=\(quote(searchPath)):\"$PATH\"; \(script)"], timeout: timeout)
    }

    /// Absolute path of a tool, or nil when it isn't installed.
    public static func which(_ tool: String) async -> String? {
        guard let result = try? await shell("command -v \(tool)", timeout: 15), result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
