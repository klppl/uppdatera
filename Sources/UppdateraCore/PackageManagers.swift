import Foundation

public enum PackageManager: String, CaseIterable, Codable, Sendable, Identifiable {
    case homebrew, npm, pnpm, bun, cargo, go, uv, pipx, gem
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm (global)"
        case .pnpm: "pnpm (global)"
        case .bun: "bun (global)"
        case .cargo: "Cargo"
        case .go: "Go"
        case .uv: "uv tools"
        case .pipx: "pipx"
        case .gem: "RubyGems"
        }
    }

    var tool: String {
        switch self {
        case .homebrew: "brew"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .bun: "bun"
        case .cargo: "cargo"
        case .go: "go"
        case .uv: "uv"
        case .pipx: "pipx"
        case .gem: "gem"
        }
    }

    public func upgradeCommand(_ name: String) -> String {
        let n = Command.quote(name)
        switch self {
        case .homebrew: return "brew upgrade \(n)"
        case .npm: return "npm install -g \(Command.quote(name + "@latest"))"
        case .pnpm: return "pnpm add -g \(Command.quote(name + "@latest"))"
        case .bun: return "bun add -g \(Command.quote(name + "@latest"))"
        case .cargo: return "cargo install \(n)"
        case .go: return "go install \(Command.quote(name + "@latest"))"
        case .uv: return "uv tool upgrade \(n)"
        case .pipx: return "pipx upgrade \(n)"
        case .gem: return "gem update \(n)"
        }
    }
}

public struct PackageUpdate: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(manager.rawValue):\(name)" }
    public let manager: PackageManager
    public let name: String
    public let installed: String
    public let latest: String
    public let pinned: Bool
}

public struct PackageSurvey: Sendable {
    public var updates: [PackageUpdate] = []
    public var available: [PackageManager] = []
    public var problems: [PackageManager: String] = [:]
}

public enum PackageScanner {
    /// What one package manager answered. A struct, not a tuple: optimised builds mangled a
    /// generic tuple holding `Result<_, Error>` here (seen with Swift 6.4).
    struct ManagerOutcome: Sendable {
        var manager: PackageManager
        var present: Bool
        var updates: [PackageUpdate] = []
        var problem: String?
    }

    public static func survey(_ managers: [PackageManager] = PackageManager.allCases) async -> PackageSurvey {
        let outcomes = await boundedMap(managers, limit: 3) { manager -> ManagerOutcome in
            guard let path = await Command.which(manager.tool) else { return ManagerOutcome(manager: manager, present: false) }
            // macOS's own Ruby: its gems belong to the system.
            if manager == .gem && path == "/usr/bin/gem" { return ManagerOutcome(manager: manager, present: false) }
            do {
                return ManagerOutcome(manager: manager, present: true, updates: try await outdated(manager))
            } catch {
                return ManagerOutcome(manager: manager, present: true, problem: error.localizedDescription)
            }
        }
        var survey = PackageSurvey()
        for outcome in outcomes where outcome.present {
            survey.available.append(outcome.manager)
            survey.updates += outcome.updates
            if let problem = outcome.problem { survey.problems[outcome.manager] = problem }
        }
        survey.updates.sort { ($0.manager.rawValue, $0.name) < ($1.manager.rawValue, $1.name) }
        return survey
    }

    public static func upgrade(_ package: PackageUpdate) async throws {
        let r = try await Command.shell(package.manager.upgradeCommand(package.name), timeout: 1800)
        guard r.succeeded else {
            let tail = (r.stderr.isEmpty ? r.stdout : r.stderr).split(separator: "\n").suffix(5).joined(separator: "\n")
            throw CommandError(message: "\(package.manager.label) couldn't upgrade \(package.name):\n\(tail)")
        }
    }

    static func outdated(_ manager: PackageManager) async throws -> [PackageUpdate] {
        switch manager {
        case .homebrew:
            let r = try await Command.shell("brew outdated --formula --json=v2", timeout: 120)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
                  let formulae = obj["formulae"] as? [[String: Any]] else {
                throw CommandError(message: r.stderr.isEmpty ? "brew gave no answer" : r.stderr)
            }
            return formulae.compactMap { f in
                guard let name = f["name"] as? String, let latest = f["current_version"] as? String else { return nil }
                let installed = (f["installed_versions"] as? [String])?.last ?? "?"
                return PackageUpdate(manager: .homebrew, name: name, installed: installed, latest: latest,
                                     pinned: f["pinned"] as? Bool ?? false)
            }

        case .npm:
            // npm exits 1 when something is outdated, so read stdout whatever the status.
            let r = try await Command.shell("npm outdated -g --json", timeout: 120)
            let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]] else {
                throw CommandError(message: "npm's answer couldn't be read")
            }
            return obj.compactMap { name, info in
                guard let current = info["current"] as? String, let latest = info["latest"] as? String, current != latest else { return nil }
                return PackageUpdate(manager: .npm, name: name, installed: current, latest: latest, pinned: false)
            }

        case .pnpm:
            // Like npm, pnpm exits non-zero when something is outdated.
            let r = try await Command.shell("pnpm outdated -g --format json", timeout: 120)
            let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]] else {
                throw CommandError(message: "pnpm's answer couldn't be read")
            }
            return obj.compactMap { name, info in
                guard let current = info["current"] as? String, let latest = info["latest"] as? String, current != latest else { return nil }
                return PackageUpdate(manager: .pnpm, name: name, installed: current, latest: latest, pinned: false)
            }

        case .bun:
            // "├── typescript@5.4.5", "└── @scope/tool@1.0.0"
            let r = try await Command.shell("bun pm ls -g", timeout: 60)
            let installed = r.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let start = line.firstIndex(where: { $0.isLetter || $0 == "@" }) else { return nil }
                let entry = line[start...].trimmingCharacters(in: .whitespaces)
                guard let at = entry.lastIndex(of: "@"), at != entry.startIndex else { return nil }
                let version = String(entry[entry.index(after: at)...])
                guard version.first?.isNumber == true else { return nil }
                return (String(entry[..<at]), version)
            }
            return await registryCompare(installed, manager: .bun) { name in
                let escaped = name.replacingOccurrences(of: "/", with: "%2F")
                let json = try await HTTP.json(URL(string: "https://registry.npmjs.org/\(escaped)/latest")!)
                return valueAt(path: "version", in: json) as? String
            }

        case .go:
            // Each binary in GOBIN records the package it was built from and its module version.
            let dir = try await Command.shell(#"d=$(go env GOBIN); [ -n "$d" ] || d="$(go env GOPATH)/bin"; echo "$d""#, timeout: 30)
            let bin = dir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: bin)) ?? []
            let built = await boundedMap(names, limit: 4) { name -> GoBinary? in
                guard let r = try? await Command.run("/bin/zsh", ["-lc", "export PATH=\(Command.quote(Command.searchPath)):\"$PATH\"; go version -m \(Command.quote(bin + "/" + name))"], timeout: 30),
                      r.succeeded else { return nil }
                return GoBinary(versionOutput: r.stdout)
            }
            let binaries = built.compactMap { $0 }
            let latest = await boundedMap(binaries, limit: 6) { binary -> PackageUpdate? in
                guard let url = URL(string: "https://proxy.golang.org/\(GoBinary.escape(binary.module))/@latest"),
                      let json = try? await HTTP.json(url), let newest = valueAt(path: "Version", in: json) as? String,
                      let a = AppVersion(binary.version), let b = AppVersion(newest), a < b else { return nil }
                return PackageUpdate(manager: .go, name: binary.path, installed: binary.version, latest: newest, pinned: false)
            }
            return latest.compactMap { $0 }

        case .cargo:
            let r = try await Command.shell("cargo install --list", timeout: 60)
            let installed = r.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
                guard !line.hasPrefix(" "), line.hasSuffix(":") else { return nil }
                let parts = line.dropLast().split(separator: " ")
                guard parts.count >= 2, parts[1].hasPrefix("v") else { return nil }
                // Path or git installs show "(…)" after the version; registries can't speak for those.
                if parts.count > 2 { return nil }
                return (String(parts[0]), String(parts[1].dropFirst()))
            }
            return await registryCompare(installed, manager: .cargo) { name in
                let json = try await HTTP.json(URL(string: "https://crates.io/api/v1/crates/\(name)")!)
                return valueAt(path: "crate.max_stable_version", in: json) as? String
            }

        case .uv, .pipx:
            let r = try await Command.shell(manager == .uv ? "uv tool list" : "pipx list --short", timeout: 60)
            let installed = r.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
                guard !line.hasPrefix("-"), !line.hasPrefix(" ") else { return nil }
                let parts = line.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                return (String(parts[0]), String(parts[1]).strippingLeadingV)
            }
            return await registryCompare(installed, manager: manager) { name in
                let json = try await HTTP.json(URL(string: "https://pypi.org/pypi/\(name)/json")!)
                return valueAt(path: "info.version", in: json) as? String
            }

        case .gem:
            let r = try await Command.shell("gem outdated", timeout: 120)
            // "rake (13.0.6 < 13.2.1)"
            return r.stdout.split(separator: "\n").compactMap { line in
                guard let open = line.firstIndex(of: "("), let lt = line.range(of: " < "), let close = line.lastIndex(of: ")") else { return nil }
                let name = line[..<open].trimmingCharacters(in: .whitespaces)
                let current = line[line.index(after: open)..<lt.lowerBound].split(separator: ",").last.map(String.init) ?? ""
                let latest = String(line[lt.upperBound..<close])
                return PackageUpdate(manager: .gem, name: name, installed: current.trimmingCharacters(in: .whitespaces),
                                     latest: latest, pinned: false)
            }
        }
    }

    static func registryCompare(_ installed: [(String, String)], manager: PackageManager,
                                latest: @escaping @Sendable (String) async throws -> String?) async -> [PackageUpdate] {
        let found = await boundedMap(installed, limit: 6) { name, version -> PackageUpdate? in
            guard let newest = try? await latest(name),
                  let a = AppVersion(version), let b = AppVersion(newest), a < b else { return nil }
            return PackageUpdate(manager: manager, name: name, installed: version, latest: newest, pinned: false)
        }
        return found.compactMap { $0 }
    }
}

/// What `go version -m` says about one installed binary.
struct GoBinary: Sendable {
    let path: String
    let module: String
    let version: String

    init?(versionOutput: String) {
        var path: String?, module: String?, version: String?
        for line in versionOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if fields.first == "path", fields.count >= 2 { path = String(fields[1]) }
            if fields.first == "mod", fields.count >= 3 { module = String(fields[1]); version = String(fields[2]) }
        }
        // "(devel)" means built from a checkout; the proxy can't speak for it.
        guard let path, let module, let version, version.hasPrefix("v") else { return nil }
        self.path = path
        self.module = module
        self.version = version
    }

    /// The module proxy wants capitals written as "!" plus the lower-case letter.
    static func escape(_ module: String) -> String {
        module.map { $0.isUppercase ? "!" + $0.lowercased() : String($0) }.joined()
    }
}
