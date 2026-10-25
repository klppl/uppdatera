import Foundation

/// A version number that can be ordered.
///
/// Vendors write versions in many shapes, so the parser normalises before comparing:
/// leading words or a `v` (`Version 1.2`, `v1.2`), build metadata (`0.4.23+1`),
/// Homebrew's comma builds (`1.2.3,4567`), parenthesised builds (`1.2 (345)`) and a bare
/// trailing letter (`1.21.16b`) are all dropped. Real pre-release tags (`-beta.2`, `rc1`,
/// `1.0b5`) are kept and sort before the final release.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public let numbers: [Int]
    /// Empty for a final release; otherwise a rank and a number, e.g. beta 2 → [2, 2].
    public let prerelease: [Int]

    public var description: String { raw }
    public var major: Int { numbers.first ?? 0 }
    public var isPrerelease: Bool { !prerelease.isEmpty }

    private static let preRanks: [(String, Int)] = [
        ("nightly", 0), ("canary", 0), ("snapshot", 0), ("dev", 0),
        ("alpha", 1), ("a", 1),
        ("beta", 2), ("b", 2),
        ("preview", 3), ("pre", 3),
        ("rc", 4),
    ]

    public init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = trimmed
        var s = Substring(trimmed)
        guard let firstDigit = s.firstIndex(where: \.isNumber) else { return nil }
        s = s[firstDigit...]
        for cut in ["+", ",", " ", "("] {
            if let i = s.firstIndex(of: Character(cut)) { s = s[..<i] }
        }

        var numbers: [Int] = []
        var current = ""
        var index = s.startIndex
        while index < s.endIndex {
            let c = s[index]
            if c.isNumber {
                current.append(c)
            } else if c == "." && !current.isEmpty {
                numbers.append(Int(current.prefix(18)) ?? 0)
                current = ""
            } else {
                break
            }
            index = s.index(after: index)
        }
        if !current.isEmpty { numbers.append(Int(current.prefix(18)) ?? 0) }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers

        let rest = s[index...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        self.prerelease = AppVersion.parsePrerelease(rest)
    }

    private static func parsePrerelease(_ rest: String) -> [Int] {
        guard !rest.isEmpty else { return [] }
        // A lone letter with nothing after it is part of the name (Zen's "1.21.16b"), not a beta.
        if rest.count == 1 { return [] }
        for (word, rank) in preRanks where rest.hasPrefix(word) {
            let tail = rest.dropFirst(word.count).drop { "-._".contains($0) }
            if tail.isEmpty { return [rank, 0] }
            let digits = tail.prefix { $0.isNumber }
            // "beta" must be followed by a number or nothing; "build12" isn't a pre-release.
            guard !digits.isEmpty else { continue }
            return [rank, Int(digits.prefix(18)) ?? 0]
        }
        return []
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<count {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b }
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        return lhs.prerelease.lexicographicallyPrecedes(rhs.prerelease)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    /// True when two versions look like they use different numbering schemes,
    /// e.g. `2024.10` against `3.2`. Comparing those would produce nonsense.
    public func looksIncomparable(with other: AppVersion) -> Bool {
        let a = major, b = other.major
        if (a >= 1990) != (b >= 1990) { return true }
        if a < 1990 && b < 1990 && abs(a - b) > 20 { return true }
        return false
    }
}
