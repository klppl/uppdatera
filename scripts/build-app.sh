#!/bin/zsh
# Builds a universal, ad-hoc signed Uppdatera.app into ./build.
# Set SIGN_IDENTITY="Developer ID Application: …" to sign for distribution.
set -euo pipefail
cd "${0:A:h}/.."

# REPO=owner/name (once published) sets the issue links, community rules and self-update source.
REPO="${REPO:-}"
RELEASES_REPO="${RELEASES_REPO:-$REPO}"
RULES_URL="${RULES_URL:-${REPO:+https://raw.githubusercontent.com/$REPO/main/rules/rules.json}}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="build/Uppdatera.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Uppdatera"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Uppdatera"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>app.uppdatera.Uppdatera</string>
	<key>CFBundleName</key><string>Uppdatera</string>
	<key>CFBundleDisplayName</key><string>Uppdatera</string>
	<key>CFBundleExecutable</key><string>Uppdatera</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>UppdateraRepo</key><string>${REPO}</string>
	<key>UppdateraReleasesRepo</key><string>${RELEASES_REPO}</string>
	<key>UppdateraRulesURL</key><string>${RULES_URL}</string>
	<key>NSAppleEventsUsageDescription</key><string>Uppdatera asks for an administrator password when an app belongs to another account.</string>
</dict>
</plist>
PLIST

if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/app.uppdatera.Uppdatera.agent.plist "$APP/Contents/Library/LaunchAgents/"

codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
