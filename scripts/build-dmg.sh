#!/bin/zsh
# Packs build/Uppdatera.app (from build-app.sh) into build/Uppdatera.dmg, with an Applications
# shortcut to drag it onto. Signs the image too when SIGN_IDENTITY is set.
# The name has no version in it, so releases/latest/download/Uppdatera.dmg always works.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/Uppdatera.app"
DMG="build/Uppdatera.dmg"
[[ -d "$APP" ]] || { echo "Run ./scripts/build-app.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Uppdatera.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Uppdatera -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" ]]; then codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"; fi
echo "Built $DMG"
