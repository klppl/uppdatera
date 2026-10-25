# Uppdatera

A free macOS updater for every app in `/Applications` and the packages your command-line
tools installed.

## Build & run

```bash
./scripts/build-app.sh && open build/Uppdatera.app
```

Build settings (environment variables):

- `REPO=owner/name`: the project's GitHub repository. It turns on community rules
  (`rules/rules.json` on `main`), self-update from its releases, and the Report a Problem links.
- `SIGN_IDENTITY="Developer ID Application: …"`: signs the app for distribution.
- `RELEASES_REPO` and `RULES_URL`: override the two addresses derived from `REPO`.

Without the UI:

```bash
swift run Uppdatera --check --verbose --packages   # everything, with each app's trace
swift run Uppdatera --test-rule com.vendor.App 1.0 # one rule, pretending 1.0 is installed
swift run Uppdatera --install com.vendor.App       # install one update
swift run Uppdatera --validate-rules rules/rules.json --live  # check a rules file
swift run Uppdatera --github-status                # which GitHub token is used, requests left
```

Tests: `swift test` (outside `~/Documents`, add `--scratch-path` if signing the test bundle fails).

## How it finds updates

For each app, in this order. The first source that gives a comparable answer wins, and
every step is written to the app's trace ("How Uppdatera decided").

1. **Your rule or a built-in rule**: `github`, `sparkle`, `json`, `homebrew`, `appStore`, `page`
   (regex over a web page), `redirect` (version from where a "latest" link lands), `artifact`
   (read the app inside the download; re-downloaded only when the server says it changed),
   or `exclude`
2. **App Store** lookup (only for apps that have an App Store receipt)
3. The app's own **Sparkle feed** (`SUFeedURL`). Sparkle builds are compared, beta channels are
   skipped, and the minimum macOS version is respected.
4. The **Homebrew cask catalogue** (`formulae.brew.sh`), cached for 6 hours. Casks that install a
   `.pkg` are matched by name. For casks Homebrew installed, its Caskroom record is used.

Packages: Homebrew formulae, global npm, pnpm and bun, Go binaries (proxy.golang.org),
Cargo (crates.io), uv tools and pipx (PyPI), RubyGems.

GitHub lookups use a token when there is one, which raises the hourly limit from 60 to 5,000.
The order is: the token saved in Settings → GitHub (kept in the Keychain), then `GITHUB_TOKEN`,
then your GitHub CLI login (`gh auth token`).

**Release notes** come from the update source, from a rule's `notes` page (vendor release-notes
pages, trimmed between two markers), or from the matching GitHub release.

## How it installs

- **Homebrew-installed apps:** quit, `brew upgrade --cask`, reopen.
- **App Store apps:** `mas upgrade` when [mas](https://github.com/mas-cli/mas) is installed
  (`brew install mas`); otherwise the App Store page opens.
- **Everything else:**
  1. Download it (DMG, ZIP, tar, or PKG; a PKG opens in Installer).
  2. Check that the bundle id matches and that the new version isn't older.
  3. Run `codesign --verify --deep --strict`.
  4. Check that Apple notarized it (`spctl`).
  5. Check that it's signed by the **same Team ID** as the installed copy.
  6. Quit the app.
  7. Swap old and new atomically (`renamex_np RENAME_SWAP`).
  8. Move the **old copy to the Trash** and reopen the app.
- **Apps owned by another account:** a single admin prompt, with no resident root helper.

## Checking in the background

Settings → **Check in the background while Uppdatera is closed** registers a launchd agent
(`Contents/Library/LaunchAgents`) that wakes hourly, skips the run when the window is open or a
check isn't due, and otherwise checks, saves the results and sends the once-per-update
notification. Run it by hand with `Uppdatera --background-check`.

## Community rules

[`rules/rules.json`](rules/rules.json) is shared. Every copy of Uppdatera downloads it (at most
every 6 hours, and only when it changed), so a merged fix reaches everyone without a release.
Entries a copy doesn't understand are skipped, not fatal. See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to write and test a rule. The built-in copy is generated from the same file by
`scripts/sync-rules.sh`.

## Your rules

Settings → **Edit My Rules…** opens `~/Library/Application Support/Uppdatera/rules.json`:

```json
{
  "schemaVersion": 1,
  "apps": {
    "com.vendor.App": { "source": { "kind": "github", "repo": "vendor/app", "assetPattern": "arm64\\.dmg$" } },
    "com.vendor.Other": { "source": { "kind": "json", "url": "https://vendor.com/latest.json", "versionPath": "mac.version", "downloadPath": "mac.url" } },
    "com.vendor.Paged": { "source": { "kind": "page", "url": "https://vendor.com/download", "versionPattern": "Version ([0-9.]+)" },
                          "notes": { "url": "https://vendor.com/notes/{version}", "start": "<main", "end": "</main>" } },
    "com.vendor.Noisy": { "exclude": "Updates itself." }
  }
}
```

The bundle id is shown in each app's detail pane. Rules are read again on every check.

## Per-app controls

Skip this version · Ignore app · Pin at current version · Hold at major version · Copy diagnostics

## Publishing checklist

1. Choose a license and add `LICENSE`.
2. Push to GitHub. CI (`.github/workflows/ci.yml`) runs the tests and validates the rules.
3. Build with `REPO=owner/name SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`,
   notarize the result, zip it as `Uppdatera-<version>.zip`, and attach it to a GitHub release
   tagged `v<version>`. Self-update looks for that asset name.
4. Copies built before that, without `REPO`, can be pointed at the rules in
   Settings → Community Rules → Rules address.

## Roadmap ideas

- More built-in rules (99 today, each checked with `--validate-rules --live`)
- Signed community rules, so a compromised repository couldn't redirect checks
