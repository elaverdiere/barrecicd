#!/usr/bin/env bash
#
# Build barrecicd and wrap it into a real .app bundle.
#
# SwiftPM produces a bare executable, and a bare executable cannot be a menu-bar agent: without a
# bundle there is no Info.plist, so `LSUIElement` cannot be declared (the app would take a Dock icon
# and a main menu), and `SMAppService.mainApp` has nothing to register for launch-at-login. The
# bundle is not packaging polish — two acceptance criteria depend on it.
#
#   ./scripts/make-app.sh              build + bundle, signed ad-hoc (this machine only)
#   ./scripts/make-app.sh --sign       sign with a Developer ID Application identity, if one exists
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="barrecicd"
BUNDLE_ID="ca.digitaltango.barrecicd"
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
OUT="build/${APP_NAME}.app"

echo "── building release"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "── assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key>           <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- The whole product: an agent that lives in the menu bar, with no Dock icon and no window. -->
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# SIGNING.
#
# An ad-hoc signature (`-`) is enough to run on the machine that built it, and is what you get with
# no certificate. It is NOT enough to hand to someone else: a bundle that arrives over the network
# carries a quarantine attribute, and Gatekeeper refuses an ad-hoc bundle with "the developer cannot
# be verified". Distribution needs a `Developer ID Application` certificate AND notarisation —
# see scripts/make-dmg.sh, which refuses to pretend otherwise.
IDENTITY="-"
if [ "${1:-}" = "--sign" ]; then
  FOUND="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
  if [ -n "$FOUND" ]; then
    IDENTITY="$FOUND"
    echo "── signing as: $IDENTITY"
  else
    echo "── no 'Developer ID Application' identity in the keychain; falling back to ad-hoc."
    echo "   Create one in Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application."
  fi
fi

codesign --force --options runtime --timestamp${IDENTITY:+} --sign "$IDENTITY" "$OUT" 2>/dev/null \
  || codesign --force --sign "$IDENTITY" "$OUT"

echo "── verifying"
codesign --verify --verbose=2 "$OUT" 2>&1 | sed 's/^/   /'
echo
echo "built: $OUT"
echo "run:   open $OUT"
