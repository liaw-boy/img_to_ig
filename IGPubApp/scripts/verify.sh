#!/bin/sh
# One-command quality gate. Every stage must pass; any failure stops with a non-zero exit.
# Usage: scripts/verify.sh            (build + tests + app bundle + checks)
set -eu
cd "$(dirname "$0")/.."
step() { printf '\n== %s\n' "$1"; }

# Never rebuild underneath an app that is running from this folder (it could crash it mid-use).
if pgrep -f "$(pwd)/build/img_to_ig.app/Contents/MacOS" >/dev/null 2>&1; then
  echo "STOP: img_to_ig is running from build/. Quit it (or run it from /Applications) before rebuilding." >&2
  exit 1
fi
step "1/5 build (debug, warnings shown)"
swift build 2>&1 | tee .build/verify-build.log | grep -E "warning:|error:" || true
grep -q "error:" .build/verify-build.log && { echo "FAIL: build errors"; exit 1; }

step "2/5 unit tests (fake network only)"
swift test 2>&1 | tee .build/verify-test.log | grep -E "Executed .* tests|error|failed" | tail -5
grep -q "with 0 failures" .build/verify-test.log || { echo "FAIL: tests"; exit 1; }

step "3/5 secret scan (source must not contain credentials)"
if grep -rInE "(EAA[A-Za-z0-9]{20,}|IGQV[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)" Sources scripts Package.swift; then
  echo "FAIL: possible credential in source"; exit 1
fi
echo "ok"

step "4/5 app bundle + signature"
./scripts/build_app.sh >/dev/null
codesign --verify --strict build/img_to_ig.app
codesign -dv build/img_to_ig.app 2>&1 | grep -q "flags=.*runtime" || { echo "FAIL: hardened runtime missing"; exit 1; }
echo "ok: build/img_to_ig.app signed (ad-hoc, hardened runtime)"

step "5/5 launch smoke test"
# Run a throw-away COPY and stop only that process (by PID). Never `open` or quit by name: that would close an
# instance somebody is using (e.g. in the middle of publishing). IMG_TO_IG_SMOKE_TEST keeps it off the Keychain and network.
SMOKE="$(mktemp -d)"
cp -R build/img_to_ig.app "$SMOKE/img_to_ig.app"
IMG_TO_IG_SMOKE_TEST=1 "$SMOKE/img_to_ig.app/Contents/MacOS/img_to_ig" >/dev/null 2>&1 &
PID=$!
sleep 4
if kill -0 "$PID" 2>/dev/null; then echo "ok: app stayed up for 4 seconds"; kill "$PID" 2>/dev/null || true; else echo "FAIL: app did not stay up"; rm -rf "$SMOKE"; exit 1; fi
sleep 1; rm -rf "$SMOKE"

printf '\nALL CHECKS PASSED\n'
echo "Not covered automatically: real Instagram/R2 calls, visual review, first real publish (needs a human)."
