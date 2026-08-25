#!/bin/bash
# Build and install Voice Feed from inspectable source. Nothing is downloaded
# or executed with elevated privileges.
set -euo pipefail

# Work in a disposable directory and remove it on success or failure.
# Pin all build inputs to one reviewed client release. The outer installer may
# be fetched from `main`, but the executable source cannot drift mid-install.
BASE="https://raw.githubusercontent.com/QualityCopperShovel/voice-feed-mac/9644dd522ec2e958a7b307aadba987f60c1d5491"
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

# Assemble a standard user-owned .app bundle and ad-hoc sign this local build.
APP_DIR="$HOME/Applications/Voice Feed.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$HOME/Library/LaunchAgents"
install -m 755 "$BIN_DIR/VoiceFeedMac" "$APP_DIR/Contents/MacOS/VoiceFeedMac"
install -m 644 "$BUILD_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

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
