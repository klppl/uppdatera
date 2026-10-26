# Uppdatera

A free macOS updater for every app in `/Applications`, and for the packages your command-line tools installed.

![Uppdatera showing available updates](docs/screenshot.png)

**[Download the latest version](https://github.com/klppl/uppdatera/releases/latest/download/Uppdatera.dmg)** · macOS 14 or later · [All releases](https://github.com/klppl/uppdatera/releases)

## What it does

- Finds updates through each app's own feed, the vendor's site, GitHub, the App Store or Homebrew, and keeps a check log of how it decided.
- Installs them safely: the download must be notarized by Apple and signed by the same developer as the installed app. The old copy goes to the Trash.
- Updates Homebrew, npm, pnpm, bun, Go, Cargo, uv, pipx and RubyGems packages too.
- Can check in the background, even while it's closed, and notifies you once per update.
- Lets you skip a version, pin an app, hold it at its major version, or ignore it.
- Uninstalls apps too, with the caches and settings they left behind if you tick them. Everything goes to the Trash.

## Good to know

- **App Store apps** are updated with [mas](https://github.com/mas-cli/mas) when it's installed (`brew install mas`); otherwise the App Store opens.
- **Apps installed with Homebrew** are updated with `brew upgrade --cask`, so Homebrew stays in step.
- **Apps owned by another account** ask once for an administrator password. Nothing runs as root in the background.
- **GitHub limits** anonymous lookups to 60 an hour. Add a token (no scopes needed) in Settings → GitHub for 5,000; `GITHUB_TOKEN` or a `gh` login also work.
- **Uppdatera updates itself** from these releases: Uppdatera menu → Check for Uppdatera Updates….
- **No account and no analytics.** It contacts the update sources it checks, and GitHub for community rules and its own updates.

## Rules

Apps that need help are covered by [`rules/rules.json`](rules/rules.json), which every copy fetches, so a fix reaches everyone without a new release. Apps nothing can check are listed under **No Update Source** in the sidebar. Your own rules go in Settings → Your Rules → Edit My Rules…; see [CONTRIBUTING.md](CONTRIBUTING.md) to write one or share it.

## Build from source

Needs macOS 14 and a current Xcode.

```bash
./scripts/build-app.sh && open build/Uppdatera.app
```

It also runs without the window, for example `swift run Uppdatera --check --verbose` or
`swift run Uppdatera --test-rule com.vendor.App 1.0`. Tests: `swift test`.

## License

[The Lagom License](LICENSE). Not too much, not too little.
