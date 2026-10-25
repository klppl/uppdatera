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
