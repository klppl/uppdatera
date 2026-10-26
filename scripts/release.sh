#!/bin/zsh
# Builds, signs, notarizes and publishes a release from this Mac:
#   ./scripts/release.sh 1.2.0
# It tags v1.2.0 and attaches Uppdatera.dmg, which releases/latest/download/Uppdatera.dmg serves.
#
# Needs, once:
#   - a "Developer ID Application" certificate in your keychain (or SIGN_IDENTITY="…")
#   - notarization credentials saved in your keychain:
#       xcrun notarytool store-credentials uppdatera --apple-id you@example.com --team-id TEAMID
#     (it asks for an app-specific password; set NOTARY_PROFILE to use another profile name)
#   - gh, signed in with access to the repository
set -euo pipefail
cd "${0:A:h}/.."

fail() { print -u2 "release: $1"; exit 1; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "usage: ./scripts/release.sh 1.2.0"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-uppdatera}"
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# Everything that can fail is checked before anything is built, tagged or uploaded.
[[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
[[ "$(git branch --show-current)" == main ]] || fail "release from main"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't the same as origin/main; push or pull first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "a $TAG release already exists on GitHub"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')"
  [[ -n "$SIGN_IDENTITY" ]] || fail "no Developer ID Application certificate in your keychain"
fi
export SIGN_IDENTITY
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "no working notarization profile \"$NOTARY_PROFILE\"; see the top of this script"

print "Releasing Uppdatera $VERSION to $REPO, signed by $SIGN_IDENTITY"
swift test
REPO="$REPO" VERSION="$VERSION" BUILD="$(git rev-list --count HEAD)" ./scripts/build-app.sh
./scripts/build-dmg.sh

print "Notarizing (usually a few minutes)…"
xcrun notarytool submit build/Uppdatera.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Uppdatera.dmg
spctl --assess --type open --context context:primary-signature -v build/Uppdatera.dmg 2>&1 | grep -q "Notarized Developer ID" \
  || fail "Gatekeeper doesn't accept the notarized image; nothing was published"

git tag -a "$TAG" -m "Uppdatera $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" build/Uppdatera.dmg --repo "$REPO" --verify-tag --title "Uppdatera $VERSION" --generate-notes
print "Published https://github.com/$REPO/releases/tag/$TAG"
