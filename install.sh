#!/bin/bash
# Build and install Voice Feed from inspectable source. Nothing is downloaded
# or executed with elevated privileges.
set -euo pipefail

# Work in a disposable directory and remove it on success or failure.
# Pin all build inputs to one reviewed client release. The outer installer may
# be fetched from `main`, but the executable source cannot drift mid-install.
BASE="https://raw.githubusercontent.com/QualityCopperShovel/voice-feed-mac/6a899c7a409746b521a8d79f744c58475475cee6"
BUILD_DIR="$(mktemp -d -t voice-feed-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Fetch the exact Swift package, app metadata, and client source with bounded
# connection and overall deadlines.
mkdir -p "$BUILD_DIR/Sources/VoiceFeedMac"
for FILE in Package.swift Info.plist; do curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "$BASE/$FILE" -o "$BUILD_DIR/$FILE"; done
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "$BASE/Sources/VoiceFeedMac/main.swift" -o "$BUILD_DIR/Sources/VoiceFeedMac/main.swift"

# Compile locally with Apple's Swift toolchain; fail visibly if it is missing.
command -v xcrun >/dev/null || { echo "Install Xcode Command Line Tools first: xcode-select --install" >&2; exit 1; }
xcrun swift build -c release --package-path "$BUILD_DIR"
BIN_DIR="$(xcrun swift build -c release --show-bin-path --package-path "$BUILD_DIR")"

# Assemble a standard user-owned .app bundle.
APP_DIR="$HOME/Applications/Voice Feed.app"
STAGED_APP="$BUILD_DIR/Voice Feed.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$HOME/Library/LaunchAgents"
install -m 755 "$BIN_DIR/VoiceFeedMac" "$STAGED_APP/Contents/MacOS/VoiceFeedMac"
install -m 644 "$BUILD_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"

# Preserve macOS privacy grants when the owner's Developer ID is available.
# Other source-build users retain the explicit ad-hoc fallback.
DEVELOPER_IDENTITY="Developer ID Application: jesse Aldridge (7ZPTPEXGRC)"
if security find-identity -v -p codesigning | grep -Fq "\"$DEVELOPER_IDENTITY\""; then
  echo "Signing Voice Feed with Developer ID."
  codesign --force --deep --sign "$DEVELOPER_IDENTITY" "$STAGED_APP"
else
  echo "Developer ID unavailable; using an ad-hoc signature for this local build."
  codesign --force --deep --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

# Do not touch the running installation until the replacement has compiled,
# signed, and verified. Restore the prior bundle if the final move fails.
PREVIOUS_APP="$BUILD_DIR/Voice Feed.previous.app"
if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "$PREVIOUS_APP"; fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
  [[ ! -d "$PREVIOUS_APP" ]] || mv "$PREVIOUS_APP" "$APP_DIR"
  echo "The verified Voice Feed app could not replace the previous installation." >&2
  exit 1
fi

# Start the app at future logins by asking macOS to open the bundle normally,
# preserving its app identity for microphone permission and Keychain access.
PLIST="$HOME/Library/LaunchAgents/com.aisloppy.voice-feed.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Label string com.aisloppy.voice-feed" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/open" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string -a" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $APP_DIR" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool false" "$PLIST"
chmod 644 "$PLIST"

# Manual installs launch immediately. The in-app updater relaunches only after
# this process exits, so macOS cannot reuse the old running executable.
if [[ "${VOICE_FEED_AUTO_UPDATE:-0}" != "1" ]]; then open "$APP_DIR"; fi
echo "Voice Feed is installed. Use its waveform icon in the menu bar to connect this Mac."
