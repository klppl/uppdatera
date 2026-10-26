# Contributing

The most useful contribution is a **rule**: one entry in [`rules/rules.json`](rules/rules.json)
that tells Uppdatera where an app publishes its versions. When it's merged, every copy of
Uppdatera picks it up on its next check. Nobody has to wait for a new release.

## When an app needs a rule

Uppdatera checks apps without rules in this order: the App Store, the app's own Sparkle feed,
and then Homebrew's cask catalogue. An app needs a rule when:

- it's under **Can't be checked** ("No source knows about this app"),
- it offers the **wrong version** (a beta, a different numbering scheme, a stale Homebrew cask), or
- it **updates itself** and shouldn't be touched (use `exclude`).

Right-click the app in Uppdatera → **Copy Diagnostics** to see what every source said.

## Writing one

Rules are keyed by bundle id. Each app's details pane shows its bundle id.

| `source.kind` | Needs | Reads the version from |
|---|---|---|
| `sparkle` | `url` | A Sparkle appcast (beta channels skipped) |
| `github` | `repo` (`owner/name`), optional `assetPattern`, `prerelease` | The latest GitHub release |
| `json` | `url`, `versionPath`, optional `downloadPath` | A JSON document (`a.b.0.c` paths) |
| `page` | `url`, `versionPattern`, optional `downloadPattern` | A regex over a web page (first capture group) |
| `redirect` | `url`, `versionPattern` | A regex over where a "latest" link lands |
| `artifact` | `url` | The app inside the download itself (cached until the file changes) |
| `homebrew` | `cask` | A specific Homebrew cask |
| `appStore` | | The App Store listing |
| `none` | `downloadPage` at the top level | Nothing. Says plainly that the app can't be checked |

Other fields:

- `{arch}` in a URL becomes `arm64` or `x86_64`.
- `urlIntel` (inside `source`) is read instead of `url` on Intel Macs, for vendors that spell the
  chip some other way (`amd64`, `x64`, `intel64`, or nothing at all).
- `download` sets a fixed download address. `{version}`, `{major}`, `{minor}` and `{arch}` are filled in.
- `downloadIntel` is used instead of `download` on Intel Macs.
- `downloadPage` is shown when there's nothing to download automatically.
- `compare` is `"buildVersion"` when the source's numbers match the app's `CFBundleVersion`.
- `notes` scrapes release notes: `{ "url": "…/v{major}_{minor}", "start": "<main", "end": "</main>" }`.
- `quit` set to `"force"` is for apps that ignore a polite quit.
- `exclude` takes a reason, for apps that update themselves.
- `note` is free text for the next person: what you checked, and when.

A rule replaces the whole entry for that app. Your local `rules.json` overrides community rules,
and community rules override the built-in ones.

## Testing

```bash
# Run your rule as if an older version were installed:
swift run Uppdatera --rules rules/rules.json --test-rule com.vendor.App 1.0

# Check the whole file, then run every rule against its real source:
swift run Uppdatera --validate-rules rules/rules.json
swift run Uppdatera --validate-rules rules/rules.json --live

# Regenerate the copy built into the app (CI fails if you forget):
./scripts/sync-rules.sh
```

Paste the `--test-rule` output into your pull request.

## Safety

A rule only says where to look. Before installing anything, Uppdatera still requires the
download to be notarized by Apple and signed by the same developer team as the installed app.
So a bad rule can make it miss an update, but it can't make it install someone else's software.

## Code

`swift build`, `swift test`, and `./scripts/build-app.sh` for the app bundle.
`UppdateraCore` holds everything that isn't UI (scanning, sources, versions, installing), so
most changes come with a unit test in `Tests/`.

## Releasing

Releases are built on the maintainer's Mac, where the Developer ID certificate lives:

```bash
./scripts/release.sh 1.2.0
```

It checks that `main` is clean and pushed, runs the tests, builds a universal app and
`Uppdatera.dmg` signed with the keychain's Developer ID, notarizes and staples the image, then
tags `v1.2.0` and publishes the release. The file name never changes, so
`releases/latest/download/Uppdatera.dmg` always points at the newest one.

Once per Mac, save the notarization login (it asks for an app-specific password from
account.apple.com):

```bash
xcrun notarytool store-credentials uppdatera --apple-id you@example.com --team-id TEAMID
```

An unsigned build for trying things out: `./scripts/build-app.sh && ./scripts/build-dmg.sh`.
