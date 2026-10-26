import XCTest
@testable import UppdateraCore

final class AppVersionTests: XCTestCase {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testOrdering() {
        XCTAssertLessThan(v("1.2"), v("1.10"))
        XCTAssertLessThan(v("1.9.9"), v("2"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertLessThan(v("2.0-beta.2"), v("2.0"))
        XCTAssertLessThan(v("2.0-beta.2"), v("2.0-rc1"))
        XCTAssertLessThan(v("1.0b5"), v("1.0"))
        XCTAssertLessThan(v("1.0a1"), v("1.0b1"))
    }

    func testNormalisation() {
        XCTAssertEqual(v("v4.3.3"), v("4.3.3"))
        XCTAssertEqual(v("0.4.23+1"), v("0.4.23"))          // build metadata
        XCTAssertEqual(v("1.21.16b"), v("1.21.16"))         // Zen's trailing letter
        XCTAssertFalse(v("1.21.16b").isPrerelease)
        XCTAssertEqual(v("1.2.3,4567"), v("1.2.3"))         // Homebrew cask build
        XCTAssertEqual(v("Version 7.1 (2245)"), v("7.1"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testSchemeMismatch() {
        XCTAssertTrue(v("2024.10").looksIncomparable(with: v("3.2")))
        XCTAssertFalse(v("3.2").looksIncomparable(with: v("4.0")))
    }
}

final class AppcastTests: XCTestCase {
    let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version 2.1</title>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
          <description><![CDATA[<p>Fixes</p>]]></description>
          <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-2.1.zip" length="1"/>
        </item>
        <item>
          <title>Version 2.2 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/App-2.2b.zip" sparkle:version="220" sparkle:shortVersionString="2.2b1"/>
        </item>
        <item>
          <title>Version 3.0</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-3.zip" sparkle:version="300" sparkle:shortVersionString="3.0"/>
        </item>
        <item>
          <title>Version 2.0</title>
          <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/>
        </item>
      </channel>
    </rss>
    """

    func testPicksNewestStableEligible() {
        let items = AppcastParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.count, 4)
        let best = AppcastParser.newestEligible(items)
        XCTAssertEqual(best?.shortVersion, "2.1")
        XCTAssertEqual(best?.version, "210")
        XCTAssertEqual(best?.descriptionHTML, "<p>Fixes</p>")
        XCTAssertEqual(best?.downloadURL?.absoluteString, "https://example.com/App-2.1.zip")
    }
}

final class CompareTests: XCTestCase {
    func app(short: String?, build: String?) -> InstalledApp {
        InstalledApp(path: URL(fileURLWithPath: "/Applications/X.app"), name: "X", bundleID: "x", shortVersion: short,
                     buildVersion: build, sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
    }

    func testSparkleUsesBuilds() {
        let checker = UpdateChecker(rules: [:])
        XCTAssertEqual(checker.compare(app(short: "2.1", build: "210"), short: "2.1", build: "211", basis: .buildVersion), .newer)
        XCTAssertEqual(checker.compare(app(short: "2.1", build: "210"), short: "2.1", build: "210", basis: .buildVersion), .same)
        // Feed that writes the marketing version into sparkle:version.
        XCTAssertEqual(checker.compare(app(short: "2.1", build: "4501"), short: "2.1", build: "2.1", basis: .buildVersion), .same)
    }

    /// Bitwarden's case: an App Store copy can only be updated by the App Store, so a rule that
    /// reads the vendor's site must not be used for it.
    func testAppStoreCopiesSkipVendorRules() throws {
        let rules = try RulesStore.decode(Data(#"{"schemaVersion":1,"apps":{"a.b":{"source":{"kind":"page","url":"https://e/latest-mac.yml","versionPattern":"v([0-9.]+)"}},"c.d":{"source":{"kind":"appStore"}}}}"#.utf8)).apps
        func app(_ id: String, store: Bool) -> InstalledApp {
            InstalledApp(path: URL(fileURLWithPath: "/Applications/X.app"), name: "X", bundleID: id, shortVersion: "1.0",
                         buildVersion: nil, sparkleFeedURL: nil, isAppStore: store, isSetapp: false)
        }
        XCTAssertNil(UpdateChecker.ruleSource(for: app("a.b", store: true), rule: rules["a.b"]))
        XCTAssertEqual(UpdateChecker.ruleSource(for: app("a.b", store: false), rule: rules["a.b"])?.kind, .page)
        XCTAssertEqual(UpdateChecker.ruleSource(for: app("c.d", store: true), rule: rules["c.d"])?.kind, .appStore)
    }

    func testShortVersionDefault() {
        let checker = UpdateChecker(rules: [:])
        XCTAssertEqual(checker.compare(app(short: "1.4.2", build: "29"), short: "1.5.0", build: nil, basis: nil), .newer)
        XCTAssertEqual(checker.compare(app(short: "2024.1", build: nil), short: "3.0", build: nil, basis: nil), .incomparable)
    }

    func testPreferences() {
        var p = UpdatePreference()
        XCTAssertNil(p.suppression(of: "2.0"))
        p.heldMajor = 1
        XCTAssertNotNil(p.suppression(of: "2.0"))
        XCTAssertNil(p.suppression(of: "1.9"))
        p = UpdatePreference()
        p.skippedVersion = "2.0"
        XCTAssertNotNil(p.suppression(of: "2.0"))
        XCTAssertNil(p.suppression(of: "2.0.1"))
    }

    func testAssetPicking() {
        let assets = [
            ("App-1.0-x64.dmg", URL(string: "https://e/x64.dmg")!),
            ("App-1.0-arm64.dmg", URL(string: "https://e/arm.dmg")!),
            ("App-1.0.exe", URL(string: "https://e/win.exe")!),
            ("App-1.0-arm64.dmg.blockmap", URL(string: "https://e/bm")!),
        ]
        let picked = GitHubReleases.pickAsset(assets, pattern: nil)
        XCTAssertEqual(picked?.lastPathComponent, MachineArch.current == "arm64" ? "arm.dmg" : "x64.dmg")
    }
}

final class DetritusTests: XCTestCase {
    /// Brave's case: a validly signed bundle with FinderInfo on a file fails `codesign --strict`
    /// until that attribute is gone, and the original is left as it was.
    func testStrippingDetritusPassesStrictCheck() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("uppdatera-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let app = work.appendingPathComponent("X.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/X").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.x", "CFBundleExecutable": "X", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("hi".utf8).write(to: resources.appendingPathComponent("a.txt"))
        let signed = try await Command.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        XCTAssertTrue(signed.succeeded, signed.stderr)

        // The bytes Brave's Sparkle.framework folders carry (an all-zero FinderInfo isn't stored at all).
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let file = resources.appendingPathComponent("a.txt")
        XCTAssertEqual(setxattr(file.path, "com.apple.FinderInfo", finderInfo, finderInfo.count, 0, XATTR_NOFOLLOW), 0)
        let before = try await Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertFalse(before.succeeded)
        XCTAssertTrue(before.stderr.contains("detritus"), before.stderr)

        let checked = try await Installer.strippingDetritus(app, in: work)
        XCTAssertNotEqual(checked, app)
        XCTAssertEqual(Installer.filesWithDetritus(in: checked), [])
        XCTAssertEqual(Installer.filesWithDetritus(in: app).map(\.lastPathComponent), ["a.txt"])
        let after = try await Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", checked.path])
        XCTAssertTrue(after.succeeded, after.stderr)

        // A clean bundle is used as it is, with no copy.
        let clean = try await Installer.strippingDetritus(checked, in: work.appendingPathComponent("again"))
        XCTAssertEqual(clean, checked)
    }
}

final class UninstallerTests: XCTestCase {
    func testLeftoversMatchOnlyTheApp() throws {
        let fm = FileManager.default
        let library = fm.temporaryDirectory.appendingPathComponent("uppdatera-library-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: library) }
        func make(_ path: String, file: Bool = false) throws {
            let url = library.appendingPathComponent(path)
            try fm.createDirectory(at: file ? url.deletingLastPathComponent() : url, withIntermediateDirectories: true)
            if file { try Data(repeating: 1, count: 4096).write(to: url) }
        }
        try make("Caches/com.vendor.Tool/data.bin", file: true)
        try make("Preferences/com.vendor.Tool.plist", file: true)
        try make("Application Support/com.vendor.Tool")
        try make("Application Support/Tool")
        try make("Containers/com.vendor.Tool")
        try make("Caches/com.vendor.ToolHelper")        // another app with a longer id
        try make("Preferences/com.vendor.Other.plist", file: true)
        try make("Elsewhere/real")
        try make("Logs")
        try fm.createSymbolicLink(at: library.appendingPathComponent("Logs/com.vendor.Tool"),
                                  withDestinationURL: library.appendingPathComponent("Elsewhere/real"))

        let app = InstalledApp(path: URL(fileURLWithPath: "/Applications/Tool.app"), name: "Tool", bundleID: "com.vendor.Tool",
                               shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
        let found = Dictionary(uniqueKeysWithValues: Uninstaller.leftovers(for: app, library: library)
            .map { ($0.place + "/" + $0.url.lastPathComponent, $0) })

        XCTAssertEqual(Set(found.keys), ["Caches/com.vendor.Tool", "Preferences/com.vendor.Tool.plist",
                                          "Application Support/com.vendor.Tool", "Application Support/Tool",
                                          "Containers/com.vendor.Tool"])
        XCTAssertEqual(found["Caches/com.vendor.Tool"]?.suggested, true)
        XCTAssertGreaterThanOrEqual(found["Caches/com.vendor.Tool"]?.size ?? 0, 4096)
        // Places that can hold the user's own data, and name matches, start unticked.
        XCTAssertEqual(found["Application Support/com.vendor.Tool"]?.suggested, false)
        XCTAssertEqual(found["Containers/com.vendor.Tool"]?.suggested, false)
        XCTAssertEqual(found["Application Support/Tool"]?.suggested, false)

        let apple = InstalledApp(path: URL(fileURLWithPath: "/Applications/Notes.app"), name: "Notes", bundleID: "com.apple.Notes",
                                 shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isAppStore: false, isSetapp: false)
        XCTAssertFalse(Uninstaller.canUninstall(apple))
        XCTAssertEqual(Uninstaller.leftovers(for: apple, library: library), [])
    }
}

final class PackageParsingTests: XCTestCase {
    func testGoVersionOutput() {
        let out = """
        /Users/x/go/bin/govulncheck: go1.27.3
        \tpath\tgolang.org/x/vuln/cmd/govulncheck
        \tmod\tgolang.org/x/vuln\tv1.9.0\th1:abc=
        """
        let b = GoBinary(versionOutput: out)
        XCTAssertEqual(b?.path, "golang.org/x/vuln/cmd/govulncheck")
        XCTAssertEqual(b?.module, "golang.org/x/vuln")
        XCTAssertEqual(b?.version, "v1.9.0")
        XCTAssertNil(GoBinary(versionOutput: "x: go1\n\tpath\ta/b\n\tmod\ta/b\t(devel)\t\n"))
        XCTAssertEqual(GoBinary.escape("github.com/BurntSushi/toml"), "github.com/!burnt!sushi/toml")
    }

    func testFirstMatch() {
        XCTAssertEqual(firstMatch("/([0-9]+\\.[0-9]+\\.[0-9]+)-[0-9]+/", in: "https://x/darwin/arm64/0.4.26-4/LM.dmg"), "0.4.26")
        XCTAssertEqual("desktop-v2026.10.1".versionFromTag, "2026.10.1")
    }

    func testBuiltInRulesDecode() {
        XCTAssertGreaterThan(RulesStore.builtIn.count, 30)
        XCTAssertEqual(RulesStore.builtIn["com.microsoft.VSCode"]?.notes?.end, "</main>")
    }
}

final class RulesFileTests: XCTestCase {
    /// rules/rules.json is what people edit; the built-in copy must match it (scripts/sync-rules.sh).
    func testBuiltInMatchesRulesFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../rules/rules.json").standardized
        let shared = try RulesStore.decode(Data(contentsOf: file))
        XCTAssertEqual(shared.apps, RulesStore.builtIn, "Run ./scripts/sync-rules.sh")
        XCTAssertEqual(RulesStore.validate(shared), [])
    }

    func testLenientDecodingSkipsUnknownKinds() throws {
        let json = #"{"schemaVersion":1,"apps":{"a.b":{"source":{"kind":"github","repo":"o/r"}},"c.d":{"source":{"kind":"future-kind"}}}}"#
        let rules = try RulesStore.decode(Data(json.utf8))
        XCTAssertEqual(rules.apps.keys.sorted(), ["a.b"])
        XCTAssertEqual(rules.skipped.keys.sorted(), ["c.d"])
    }

    func testIntelAddresses() throws {
        let json = #"{"schemaVersion":1,"apps":{"a.b":{"source":{"kind":"sparkle","url":"https://e/arm64.xml","urlIntel":"https://e/intel64.xml"},"download":"https://e/{major}.{minor}/App-{version}-aarch64.dmg","downloadIntel":"https://e/App-{version}.dmg"},"c.d":{"source":{"kind":"sparkle","url":"https://e/{arch}.xml"},"download":"https://e/App-{arch}.dmg"}}}"#
        let rules = try RulesStore.decode(Data(json.utf8)).apps
        let split = try XCTUnwrap(rules["a.b"]), plain = try XCTUnwrap(rules["c.d"])
        XCTAssertEqual(split.source?.address(arch: "arm64"), "https://e/arm64.xml")
        XCTAssertEqual(split.source?.address(arch: "x86_64"), "https://e/intel64.xml")
        XCTAssertEqual(split.downloadTemplate(arch: "arm64").map { AppRule.fill($0, version: "3.2.1") }, "https://e/3.2/App-3.2.1-aarch64.dmg")
        XCTAssertEqual(split.downloadTemplate(arch: "x86_64").map { AppRule.fill($0, version: "3.2.1") }, "https://e/App-3.2.1.dmg")
        // Without Intel fields, both chips share the one address and {arch} tells them apart.
        XCTAssertEqual(plain.source?.address(arch: "x86_64"), "https://e/{arch}.xml")
        XCTAssertEqual(plain.downloadTemplate(arch: "x86_64").map { AppRule.fill($0, version: "1", arch: "x86_64") }, "https://e/App-x86_64.dmg")
    }

    func testValidationCatchesMistakes() throws {
        let json = #"{"schemaVersion":1,"apps":{"x.y":{"source":{"kind":"page","url":"https://e.com"}},"p.q":{"source":{"kind":"github","repo":"r","assetPattern":"(["}}}}"#
        let issues = RulesStore.validate(try RulesStore.decode(Data(json.utf8)))
        XCTAssertTrue(issues.contains { $0.contains("x.y") && $0.contains("versionPattern") })
        XCTAssertTrue(issues.contains { $0.contains("p.q") && $0.contains("owner/name") })
        XCTAssertTrue(issues.contains { $0.contains("p.q") && $0.contains("regular expression") })
    }
}
