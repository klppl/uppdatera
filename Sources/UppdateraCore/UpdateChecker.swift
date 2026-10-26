import Foundation

/// Works out whether one app has an update, trying sources from most to least trustworthy:
/// a rule for the app, the app's own Sparkle feed, then the Homebrew cask catalogue.
/// App Store apps are only ever checked against the App Store.
public struct UpdateChecker: Sendable {
    public let rules: [String: AppRule]
    public let ownBundleID: String?

    public init(rules: [String: AppRule], ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.rules = rules
        self.ownBundleID = ownBundleID
    }

    enum Comparison { case newer, same, older, incomparable }

    public func check(_ app: InstalledApp) async -> CheckResult {
        var trace: [String] = []
        let rule = rules[app.bundleID]

        if let reason = exclusion(for: app, rule: rule) {
            return CheckResult(status: .excluded(reason), trace: [reason])
        }
        guard app.shortVersion != nil || app.buildVersion != nil else {
            return CheckResult(status: .unknown("The app declares no version."), trace: ["No CFBundleShortVersionString or CFBundleVersion"])
        }

        var info: UpdateInfo?
        var latestSeen: String?
        var decided = false

        func consider(_ candidate: UpdateInfo?, comparison: Comparison, from label: String) {
            guard let candidate else { return }
            switch comparison {
            case .newer:
                trace.append("\(label): \(candidate.version) is newer than \(app.displayVersion) → update")
                info = candidate
                decided = true
            case .same, .older:
                trace.append("\(label): \(candidate.version), installed \(app.displayVersion) → up to date")
                latestSeen = candidate.version
                decided = true
            case .incomparable:
                trace.append("\(label): \(candidate.version) can't be compared with \(app.displayVersion); trying the next source")
            }
        }

        let source = Self.ruleSource(for: app, rule: rule)
        if let skipped = rule?.source, source == nil {
            trace.append("Installed from the App Store, so only the App Store can update it; the rule's \(skipped.kind.rawValue) source is skipped")
        }
        if let source, source.kind != .none {
            do {
                let (candidate, comparison) = try await fromRule(source, app: app, rule: rule!, trace: &trace)
                consider(candidate, comparison: comparison, from: "Rule (\(source.kind.rawValue))")
                if candidate == nil { trace.append("Rule (\(source.kind.rawValue)): no version found") }
            } catch {
                trace.append("Rule (\(source.kind.rawValue)) failed: \(error.localizedDescription)")
            }
        } else if source?.kind == AppRule.Source.Kind.none {
            let page = rule?.downloadPage.map { " Download page: \($0)" } ?? ""
            return CheckResult(status: .unknown("No source can be checked automatically.\(page)"), trace: ["Rule says no source." + page])
        }

        if !decided && app.isAppStore {
            do {
                if let result = try await AppStoreLookup.lookup(bundleID: app.bundleID) {
                    let candidate = UpdateInfo(version: result.version, pageURL: result.storeURL,
                                               notes: result.notes.map(ReleaseNotes.plain), source: .appStore,
                                               published: result.released, storeID: result.trackID)
                    consider(candidate, comparison: compare(app, short: result.version, build: nil, basis: rule?.compare), from: "App Store")
                } else {
                    trace.append("App Store: no listing for \(app.bundleID) in this country")
                }
            } catch {
                trace.append("App Store lookup failed: \(error.localizedDescription)")
            }
            if !decided {
                return finish(.unknown("The App Store has no listing Uppdatera can read."), trace: trace)
            }
        }

        if !decided, let feed = app.sparkleFeedURL {
            do {
                let (data, _) = try await HTTP.data(feed)
                let items = AppcastParser.parse(data)
                if let item = AppcastParser.newestEligible(items) {
                    let candidate = UpdateInfo(
                        version: item.displayVersion ?? "?", build: item.version,
                        downloadURL: item.downloadURL, pageURL: item.releaseNotesURL,
                        notes: item.descriptionHTML.map(ReleaseNotes.html) ?? item.releaseNotesURL.map(ReleaseNotes.url),
                        source: .sparkle, published: item.published)
                    consider(candidate, comparison: compare(app, short: item.shortVersion, build: item.version, basis: rule?.compare ?? .buildVersion),
                             from: "Sparkle feed")
                } else {
                    trace.append("Sparkle feed: \(items.count) items, none eligible for this Mac")
                }
            } catch {
                trace.append("Sparkle feed \(feed.host ?? "") failed: \(error.localizedDescription)")
            }
        }

        let cask: CaskEntry?
        if let token = rule?.source?.cask {
            cask = await CaskCatalogue.shared.entry(token: token)
        } else {
            cask = await CaskCatalogue.shared.entry(forAppNamed: app.fileName)
        }
        let installedByBrew = cask.map { CaskCatalogue.installedToken($0.token) } ?? false

        if !decided, let cask {
            if cask.version == "latest" {
                trace.append("Homebrew cask \(cask.token): version is \"latest\", nothing to compare")
            } else {
                let candidate = UpdateInfo(version: cask.marketingVersion, downloadURL: cask.url, pageURL: cask.homepage,
                                           source: .homebrew)
                let parts = cask.version.split(separator: ",")
                let build = parts.count > 1 ? String(parts[1]) : nil
                if installedByBrew, CaskCatalogue.caskroomVersion(cask.token) == cask.version {
                    // The app's own plist can disagree (helpers, pkg installs); Homebrew's record is the truth here.
                    consider(candidate, comparison: .same, from: "Homebrew cask \(cask.token) (installed by Homebrew)")
                } else {
                    consider(candidate, comparison: compare(app, short: cask.marketingVersion, build: build, basis: rule?.compare),
                             from: "Homebrew cask \(cask.token)")
                }
            }
        } else if !decided {
            trace.append("Homebrew: no cask installs \(app.fileName)")
        }

        if var found = info {
            if let override = rule?.downloadTemplate() {
                found.downloadURL = URL(string: AppRule.fill(override, version: found.version))
            }
            if installedByBrew, let cask {
                found.caskToken = cask.token
                trace.append("Installed with Homebrew, so it will be updated with `brew upgrade --cask \(cask.token)`")
            }
            if found.pageURL == nil, let page = rule?.downloadPage { found.pageURL = URL(string: page) }
            if rule?.notes != nil || found.notes == nil, let notes = await notes(for: found, rule: rule) {
                found.notes = notes
                trace.append("Release notes from \(rule?.notes?.url ?? "GitHub")")
            }
            return finish(.updateAvailable(found), trace: trace)
        }
        if decided { return finish(.upToDate(latest: latestSeen), trace: trace) }
        return finish(.unknown("No source knows about this app. Add a rule for \(app.bundleID)."), trace: trace)
    }

    /// The rule's source, unless the app came from the App Store: only the App Store can update
    /// that copy, so a vendor's site or GitHub would offer something it can't install.
    static func ruleSource(for app: InstalledApp, rule: AppRule?) -> AppRule.Source? {
        guard let source = rule?.source else { return nil }
        return app.isAppStore && source.kind != .appStore ? nil : source
    }

    private func finish(_ status: AppStatus, trace: [String]) -> CheckResult {
        CheckResult(status: status, trace: trace)
    }

    private func exclusion(for app: InstalledApp, rule: AppRule?) -> String? {
        if let reason = rule?.exclude { return reason }
        if app.bundleID == ownBundleID { return "This is Uppdatera." }
        if app.isAppleFirstParty { return "Apple app. macOS updates it." }
        if app.isSetapp { return "Setapp manages this app." }
        // Chromium "Install as app" shims: <browser id>.app.<32-letter extension id>.
        if app.bundleID.range(of: #"\.app\.[a-p]{32}$"#, options: .regularExpression) != nil {
            return "Web app shortcut. Its browser keeps it current."
        }
        if app.bundleID.hasPrefix("com.google.drivefs.shortcuts.") { return "Google Drive shortcut. Google Drive keeps it current." }
        return nil
    }

    private func fromRule(_ source: AppRule.Source, app: InstalledApp, rule: AppRule, trace: inout [String]) async throws -> (UpdateInfo?, Comparison) {
        func expand(_ s: String) -> URL? {
            URL(string: s.replacingOccurrences(of: "{arch}", with: MachineArch.current))
        }
        switch source.kind {
        case .github:
            guard let repo = source.repo else { throw HTTP.Failure(message: "Rule has no repo") }
            let release = try await GitHubReleases.latest(repo: repo, assetPattern: source.assetPattern,
                                                          allowPrerelease: source.prerelease ?? false)
            if release.limited { trace.append("GitHub API refused (hourly limit?); read the tag from the release page, so no download link or notes") }
            let candidate = UpdateInfo(version: release.tag.versionFromTag, downloadURL: release.assetURL,
                                       pageURL: release.pageURL, notes: release.body.map(ReleaseNotes.markdown),
                                       source: .github, published: release.published)
            return (candidate, compare(app, short: candidate.version, build: nil, basis: rule.compare))
        case .sparkle:
            guard let url = source.address().flatMap(expand) else { throw HTTP.Failure(message: "Rule has no url") }
            let (data, _) = try await HTTP.data(url)
            guard let item = AppcastParser.newestEligible(AppcastParser.parse(data)) else { return (nil, .incomparable) }
            let candidate = UpdateInfo(version: item.displayVersion ?? "?", build: item.version, downloadURL: item.downloadURL,
                                       pageURL: item.releaseNotesURL,
                                       notes: item.descriptionHTML.map(ReleaseNotes.html) ?? item.releaseNotesURL.map(ReleaseNotes.url),
                                       source: .rule, published: item.published)
            return (candidate, compare(app, short: item.shortVersion, build: item.version, basis: rule.compare ?? .buildVersion))
        case .json:
            guard let url = source.address().flatMap(expand), let path = source.versionPath else {
                throw HTTP.Failure(message: "Rule needs url and versionPath")
            }
            let json = try await HTTP.json(url)
            guard let version = valueAt(path: path, in: json).map({ "\($0)" }) else { return (nil, .incomparable) }
            let download = source.downloadPath.flatMap { valueAt(path: $0, in: json) as? String }.flatMap(URL.init(string:))
            let candidate = UpdateInfo(version: version, downloadURL: download, source: .json)
            return (candidate, compare(app, short: version, build: nil, basis: rule.compare))
        case .homebrew:
            guard let token = source.cask, let cask = await CaskCatalogue.shared.entry(token: token) else { return (nil, .incomparable) }
            let candidate = UpdateInfo(version: cask.marketingVersion, downloadURL: cask.url, pageURL: cask.homepage, source: .homebrew)
            return (candidate, compare(app, short: cask.marketingVersion, build: nil, basis: rule.compare))
        case .appStore:
            guard let result = try await AppStoreLookup.lookup(bundleID: app.bundleID) else { return (nil, .incomparable) }
            let candidate = UpdateInfo(version: result.version, pageURL: result.storeURL, notes: result.notes.map(ReleaseNotes.plain),
                                       source: .appStore, storeID: result.trackID)
            return (candidate, compare(app, short: result.version, build: nil, basis: rule.compare))
        case .page:
            guard let url = source.address().flatMap(expand), let pattern = source.versionPattern else {
                throw HTTP.Failure(message: "Rule needs url and versionPattern")
            }
            let text = try await HTTP.text(url)
            guard let version = firstMatch(pattern, in: text) else { throw HTTP.Failure(message: "The pattern found no version on the page") }
            // downloadPattern: a regex for the download link on the same page, relative links allowed.
            let download = source.downloadPattern.flatMap { firstMatch($0, in: text) }.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            let candidate = UpdateInfo(version: version, downloadURL: download, pageURL: rule.downloadPage.flatMap(URL.init(string:)) ?? url,
                                       source: .vendor)
            return (candidate, compare(app, short: version, build: nil, basis: rule.compare))
        case .redirect:
            guard let url = source.address().flatMap(expand), let pattern = source.versionPattern else {
                throw HTTP.Failure(message: "Rule needs url and versionPattern")
            }
            let final = try await HTTP.finalURL(url)
            guard let version = firstMatch(pattern, in: final.absoluteString.removingPercentEncoding ?? final.absoluteString) else {
                throw HTTP.Failure(message: "The link led to \(final.absoluteString), which names no version")
            }
            let candidate = UpdateInfo(version: version, downloadURL: final, pageURL: rule.downloadPage.flatMap(URL.init(string:)), source: .vendor)
            return (candidate, compare(app, short: version, build: nil, basis: rule.compare))
        case .artifact:
            guard let url = source.address().flatMap(expand) else { throw HTTP.Failure(message: "Rule needs url") }
            let (short, build) = try await ArtifactVersions.read(url, bundleID: app.bundleID)
            let candidate = UpdateInfo(version: short ?? build ?? "?", build: build, downloadURL: url, source: .vendor)
            return (candidate, compare(app, short: short, build: build, basis: rule.compare))
        case .none:
            return (nil, .incomparable)
        }
    }

    /// Release notes from the rule's notes page, or the GitHub release matching the version.
    func notes(for update: UpdateInfo, rule: AppRule?) async -> ReleaseNotes? {
        if let spec = rule?.notes {
            guard let url = URL(string: AppRule.fill(spec.url, version: update.version)) else { return nil }
            guard var html = try? await HTTP.text(url) else { return .url(url) }
            if let start = spec.start, let r = html.range(of: start) { html = String(html[r.lowerBound...]) }
            if let end = spec.end, let r = html.range(of: end) { html = String(html[..<r.upperBound]) }
            // Scripts and styles from the vendor's page have no business in the pane.
            html = html.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: "", options: .regularExpression)
            return .html("<base href=\"\(url.absoluteString)\">" + html)
        }
        if let page = update.pageURL, page.host == "github.com" {
            let parts = page.path.split(separator: "/")
            if parts.count >= 2, let body = await GitHubReleases.body(repo: "\(parts[0])/\(parts[1])", version: update.version) {
                return .markdown(body)
            }
        }
        return nil
    }

    /// Compares the offer with the installed app. Build numbers are used when the source
    /// gives one and the rule (or Sparkle convention) says builds are what counts.
    func compare(_ app: InstalledApp, short: String?, build: String?, basis: AppRule.Compare?) -> Comparison {
        func rank(_ a: AppVersion, _ b: AppVersion) -> Comparison {
            a < b ? .newer : (b < a ? .older : .same)
        }
        func order(_ installed: String?, _ offered: String?) -> Comparison? {
            guard let a = installed.flatMap(AppVersion.init), let b = offered.flatMap(AppVersion.init) else { return nil }
            if a.looksIncomparable(with: b) {
                // Brave-style "155.1.97.59": a Chromium major in front of the vendor's own version.
                if a.numbers.count > 2,
                   let dropped = AppVersion(a.numbers.dropFirst().map(String.init).joined(separator: ".")),
                   !dropped.looksIncomparable(with: b) {
                    return rank(dropped, b)
                }
                return .incomparable
            }
            // "1.115.0" against "1.115.0.426": the fourth part is a build number, not a new release.
            if a.numbers.count == 3, b.numbers.count == 4, Array(b.numbers.prefix(3)) == a.numbers { return .same }
            return rank(a, b)
        }
        let byBuild = order(app.buildVersion, build)
        let byShort = order(app.shortVersion, short)
        switch basis {
        case .buildVersion:
            if let byBuild, byBuild != .incomparable {
                // Some feeds put the marketing version in sparkle:version; if builds say "newer"
                // but the marketing versions are equal, believe the marketing versions.
                if byBuild == .newer, byShort == .same, build == short { return .same }
                return byBuild
            }
            return byShort ?? order(app.buildVersion, short) ?? .incomparable
        case .shortVersion, nil:
            if let byShort, byShort != .incomparable { return byShort }
            return byBuild ?? order(app.buildVersion, short) ?? .incomparable
        }
    }
}

extension String {
    /// "desktop-v2026.10.1" → "2026.10.1", "v1.2" → "1.2".
    var versionFromTag: String {
        guard let first = firstIndex(where: \.isNumber) else { return self }
        return String(self[first...])
    }

    var strippingLeadingV: String {
        (hasPrefix("v") || hasPrefix("V")) && dropFirst().first?.isNumber == true ? String(dropFirst()) : self
    }
}
