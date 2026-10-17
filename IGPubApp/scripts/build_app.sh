#!/bin/sh
# Builds build/img_to_ig.app. Signed with the "img_to_ig Release Signing" certificate from your login Keychain when it
# exists (a stable identity: Keychain permissions and in-app updates survive new builds); otherwise ad-hoc.
set -eu
cd "$(dirname "$0")/.."
# Never rebuild underneath an app that is running from this folder (it could crash it mid-use).
if pgrep -f "$(pwd)/build/img_to_ig.app/Contents/MacOS" >/dev/null 2>&1; then
  echo "STOP: img_to_ig is running from build/. Quit it (or run it from /Applications) before rebuilding." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad VERSION: $VERSION" >&2; exit 1 ;; esac
swift build -c release
BIN="$(swift build -c release --show-bin-path)/IGPubApp"
APP="build/img_to_ig.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/img_to_ig"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>img_to_ig</string>
<key>CFBundleDisplayName</key><string>img_to_ig</string>
<key>CFBundleIdentifier</key><string>app.imgtoig.mac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>img_to_ig</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -p codesigning | awk '/"img_to_ig Release Signing"/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"; echo "signed with img_to_ig Release Signing"
else
  codesign --force --options runtime --sign - "$APP"; echo "signed ad-hoc (no release certificate found)"
fi
shasum -a 256 "$APP/Contents/MacOS/img_to_ig"
echo "built $APP"
