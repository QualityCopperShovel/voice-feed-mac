#!/bin/bash
# Build one Developer ID signed and Apple-notarized Voice Feed release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IDENTITY="Developer ID Application: jesse Aldridge (7ZPTPEXGRC)"
NOTARY_PROFILE="${VOICE_FEED_NOTARY_PROFILE:-voice-feed-notary}"
BUILD_DIR="$(mktemp -d -t voice-feed-release.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

run_with_timeout() {
  local seconds="$1"
  shift
  /usr/bin/python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

seconds = int(sys.argv[1])
try:
    raise SystemExit(subprocess.run(sys.argv[2:], timeout=seconds).returncode)
except subprocess.TimeoutExpired:
    print(f"Timed out after {seconds}s: {sys.argv[2]}", file=sys.stderr)
    raise SystemExit(124)
PY
}

[[ "$(uname -s)" == "Darwin" ]] || { echo "Run this release on macOS." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Install Apple's command-line tools first." >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\"" || {
  echo "Developer ID identity is missing from the login Keychain: $IDENTITY" >&2
  exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
APP="$BUILD_DIR/Voice Feed.app"
UPLOAD="$BUILD_DIR/Voice-Feed-$VERSION-notarization.zip"
DIST="$ROOT/dist"
ARTIFACT="$DIST/Voice-Feed-$VERSION.zip"

xcrun swift build -c release --package-path "$ROOT"
BIN_DIR="$(xcrun swift build -c release --show-bin-path --package-path "$ROOT")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
install -m 755 "$BIN_DIR/VoiceFeedMac" "$APP/Contents/MacOS/VoiceFeedMac"
install -m 644 "$ROOT/Info.plist" "$APP/Contents/Info.plist"

run_with_timeout 180 codesign --force --deep --options runtime --timestamp \
  --entitlements "$ROOT/Entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$UPLOAD"

run_with_timeout 1000 xcrun notarytool submit "$UPLOAD" \
  --keychain-profile "$NOTARY_PROFILE" --wait --timeout 15m
run_with_timeout 180 xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
run_with_timeout 180 spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ARTIFACT"
ditto -c -k --keepParent "$APP" "$ARTIFACT"
shasum -a 256 "$ARTIFACT"
echo "Signed and notarized release: $ARTIFACT"
