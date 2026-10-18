#!/bin/sh
# Packages a release: dist/img_to_ig-<VERSION>.zip + .sha256. It does NOT upload anything.
# Needs the "img_to_ig Release Signing" certificate: in-app updates only install builds signed by the same identity.
set -eu
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
./scripts/verify.sh
APP="build/img_to_ig.app"
codesign -dr - "$APP" 2>&1 | grep -q 'certificate leaf' || { echo "FAIL: the build is ad-hoc signed; create/import the release certificate first" >&2; exit 1; }
mkdir -p dist
ZIP="dist/img_to_ig-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"

# What people download must carry nothing about whoever built it: no home paths, user name or terms from the
# local personal-data list (see verify.sh). Scans every file in the zip, binary included; prints counts only.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK" "$CHECK.txt"' EXIT
ditto -x -k "$ZIP" "$CHECK"
find "$CHECK" -type f -exec strings -a {} \; > "$CHECK.txt"
HITS="$(grep -c -i -F -e "/Users/" -e "$(id -un)" "$CHECK.txt" || true)"
TERMS="$(cd "$(git rev-parse --git-common-dir)" && pwd)/info/personal-terms"
[ -s "$TERMS" ] && HITS=$((HITS + $(grep -c -i -F -f "$TERMS" "$CHECK.txt" || true)))
if [ "$HITS" -gt 0 ]; then
  rm -f "$ZIP"
  echo "FAIL: the package contains personal data ($HITS line(s)); zip deleted, nothing to upload" >&2; exit 1
fi
echo "ok: package has no personal data"

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
cat <<MSG

Packaged $ZIP
To publish (this is public and cannot be fully undone; do it deliberately):
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --repo liaw-boy/img_to_ig --title "img_to_ig $VERSION" --notes "<what changed>"
The release must be public for the app to see it. Never commit dist/ or the signing key.
MSG
