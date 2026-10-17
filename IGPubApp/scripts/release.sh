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
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
cat <<MSG

Packaged $ZIP
To publish (this is public and cannot be fully undone; do it deliberately):
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --repo liaw-boy/img_to_ig --title "img_to_ig $VERSION" --notes "<what changed>"
The release must be public for the app to see it. Never commit dist/ or the signing key.
MSG
