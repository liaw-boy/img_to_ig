#!/bin/sh
# Builds dist/img_to_ig-<VERSION>.dmg from the release zip, so the disk image holds exactly the app that was
# zipped (in-app updates keep using the zip). A compact window: the app, an arrow, the Applications shortcut.
# usage: scripts/make_dmg.sh dist/img_to_ig-X.Y.Z.zip
set -eu
cd "$(dirname "$0")/.."
ZIP="$1"
case "$ZIP" in dist/img_to_ig-[0-9]*.[0-9]*.[0-9]*.zip) ;; *) echo "usage: $0 dist/img_to_ig-X.Y.Z.zip" >&2; exit 1 ;; esac
DMG="${ZIP%.zip}.dmg"
WORK="$(mktemp -d)"
MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach -quiet "$MNT" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir "$WORK/root"
ditto -x -k "$ZIP" "$WORK/root"
[ -d "$WORK/root/img_to_ig.app" ] || { echo "FAIL: no img_to_ig.app in $ZIP" >&2; exit 1; }
codesign --verify --strict "$WORK/root/img_to_ig.app"
mkdir "$WORK/bg"
swift scripts/make_dmg_background.swift "$WORK/bg"
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$WORK/bg/background.tiff" 2>/dev/null

# dmgbuild writes the window layout (.DS_Store) itself, so Finder is never asked. Build-time tool only,
# pinned with hashes in scripts/dmg-requirements.txt and kept in its own venv.
VENV=".build/dmgbuild-venv"
if ! "$VENV/bin/python" -c "import dmgbuild" 2>/dev/null; then
  /opt/homebrew/bin/python3.12 -m venv "$VENV" 2>/dev/null || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --require-hashes --no-deps --only-binary=:all: -r scripts/dmg-requirements.txt
fi
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg_settings.py -D app="$WORK/root/img_to_ig.app" -D background="$WORK/bg/background.tiff" \
  img_to_ig "$DMG" >/dev/null

# Same identity as the app, so the image itself can be checked too.
IDENTITY="$(security find-identity -p codesigning | awk '/"img_to_ig Release Signing"/ {print $2; exit}')"
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG"

# Mount it read-only and check what people will get: the same signed app, and nothing about whoever built it.
MNT="$WORK/mnt"; mkdir "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
codesign --verify --strict "$MNT/img_to_ig.app"
cmp -s "$MNT/img_to_ig.app/Contents/MacOS/img_to_ig" "$WORK/root/img_to_ig.app/Contents/MacOS/img_to_ig" \
  || { rm -f "$DMG"; echo "FAIL: the app in the image differs from the zip" >&2; exit 1; }
# The app and the window layout file (.DS_Store can carry paths).
{ find "$MNT/img_to_ig.app" -type f -exec strings -a {} \; ; [ -f "$MNT/.DS_Store" ] && strings -a "$MNT/.DS_Store"; true; } > "$WORK/strings.txt"
HITS="$(grep -c -i -F -e "/Users/" -e "$(id -un)" "$WORK/strings.txt" || true)"
TERMS="$(cd "$(git rev-parse --git-common-dir)" && pwd)/info/personal-terms"
[ -s "$TERMS" ] && HITS=$((HITS + $(grep -c -i -F -f "$TERMS" "$WORK/strings.txt" || true)))
if [ "$HITS" -gt 0 ]; then
  rm -f "$DMG"; echo "FAIL: the image contains personal data ($HITS line(s)); dmg deleted" >&2; exit 1
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "ok: $DMG (same app as the zip, no personal data)"
