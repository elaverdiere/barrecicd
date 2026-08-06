#!/usr/bin/env bash
#
# Package barrecicd.app into a .dmg for someone else's Mac.
#
# THIS SCRIPT REFUSES TO BUILD A DISK IMAGE THAT WILL NOT OPEN ON ARRIVAL, unless you insist.
#
# The reason is worth stating plainly, because it is the single most common way a hand-built Mac app
# wastes the recipient's afternoon: a bundle that crosses a network gets the `com.apple.quarantine`
# attribute, and Gatekeeper then requires it to be signed with a **Developer ID Application**
# certificate AND notarised by Apple. An ad-hoc or development-signed app fails that check with
# "«barrecicd» cannot be opened because the developer cannot be verified" — and the workaround
# (right-click → Open, or stripping the attribute by hand) teaches the recipient to bypass Gatekeeper,
# which is a bad thing to teach for the sake of a status indicator.
#
# So: a DMG whose payload is not notarised is a DMG you can only give to yourself.
#
#   ./scripts/make-dmg.sh              refuse unless the app is signed for distribution
#   ./scripts/make-dmg.sh --unsigned   build it anyway, for your own machines
#
# TO MAKE A DISTRIBUTABLE ONE, in order:
#   1. Xcode → Settings → Accounts → your Apple ID → Manage Certificates → + Developer ID Application
#   2. xcrun notarytool store-credentials notary --apple-id <you> --team-id <TEAM> --password <app-specific>
#      (the app-specific password comes from appleid.apple.com → Sign-In and Security)
#   3. ./scripts/make-app.sh --sign && ./scripts/make-dmg.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/barrecicd.app"
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
DMG="build/barrecicd-${VERSION}.dmg"
ALLOW_UNSIGNED="${1:-}"

[ -d "$APP" ] || { echo "no $APP — run ./scripts/make-app.sh first"; exit 1; }

# Is the payload actually distributable? Ask the system, do not assume: `spctl` answers the same
# question Gatekeeper will ask on the recipient's machine, which is the only opinion that matters.
echo "── what Gatekeeper will say about this bundle:"
if spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/   /' | grep -q 'accepted'; then
  DISTRIBUTABLE=1
else
  DISTRIBUTABLE=0
fi

if [ "$DISTRIBUTABLE" -ne 1 ] && [ "$ALLOW_UNSIGNED" != "--unsigned" ]; then
  cat <<'WHY'

REFUSING to build a disk image that would not open on another Mac.

This bundle is not signed with a Developer ID Application certificate, so on any machine it did
not build on it will be refused with "the developer cannot be verified". Shipping it would hand
the recipient a broken artefact plus instructions to bypass Gatekeeper.

  · to distribute  — read the header of this script; it takes two account steps and one rebuild
  · to use it on your OWN machines — re-run with:  ./scripts/make-dmg.sh --unsigned

WHY
  exit 2
fi

echo "── staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # the drag-to-install gesture everyone already knows

echo "── creating $DMG"
rm -f "$DMG"
mkdir -p build
hdiutil create -volname "barrecicd" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ "$DISTRIBUTABLE" -eq 1 ]; then
  echo "── notarising (this takes a few minutes)"
  if xcrun notarytool submit "$DMG" --keychain-profile notary --wait; then
    xcrun stapler staple "$DMG"
    echo "── stapled: the recipient can open it offline"
  else
    echo "── notarisation failed — the DMG exists but WILL be refused on another Mac."
    echo "   Store credentials first: xcrun notarytool store-credentials notary …"
  fi
else
  echo
  echo "NOTE: built unsigned at your request. This opens on machines that built it, and nowhere else."
fi

echo
ls -lh "$DMG" | awk '{print "  " $9 "  " $5}'
