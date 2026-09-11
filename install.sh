#!/bin/bash
# Build and install Voice Feed from inspectable source. Nothing is downloaded
# or executed with elevated privileges.
set -euo pipefail

# Work in a disposable directory and remove it on success or failure.
# Pin all build inputs to one reviewed client release. The outer installer may
# be fetched from `main`, but the executable source cannot drift mid-install.
BASE="https://raw.githubusercontent.com/QualityCopperShovel/voice-feed-mac/309477ad8b1dbc124b148878b04260bc8b093258"
BUILD_DIR="$(mktemp -d -t voice-feed-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Fetch the exact Swift package, app metadata, and client source with bounded
# connection and overall deadlines.
mkdir -p "$BUILD_DIR/Sources/VoiceFeedMac" "$BUILD_DIR/Sources/CaptureCore" "$BUILD_DIR/Tests/CaptureCoreTests" "$BUILD_DIR/Sources/AudioSafety/include" "$BUILD_DIR/Sources/CaptureAudio" "$BUILD_DIR/Tests/CaptureAudioTests"
for FILE in Package.swift Info.plist; do curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "$BASE/$FILE" -o "$BUILD_DIR/$FILE"; done
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "$BASE/Sources/VoiceFeedMac/main.swift" -o "$BUILD_DIR/Sources/VoiceFeedMac/main.swift"

for FILE in Sources/AudioSafety/AudioSafety.m Sources/AudioSafety/include/AudioSafety.h Sources/CaptureAudio/MicrophoneConverter.swift Sources/CaptureAudio/SystemMicrophoneDevice.swift Tests/CaptureAudioTests/MicrophoneRecoveryTests.swift Sources/CaptureCore/CaptureRecovery.swift Sources/CaptureCore/MicrophoneReadiness.swift Sources/CaptureCore/RotationBuffer.swift Sources/CaptureCore/RecoveryAudio.swift Tests/CaptureCoreTests/RecoveryAudioTests.swift Tests/CaptureCoreTests/RotationBufferTests.swift Tests/CaptureCoreTests/MicrophoneReadinessTests.swift Tests/CaptureCoreTests/CaptureRecoveryTests.swift Sources/VoiceFeedMac/LiveCapture.swift Sources/VoiceFeedMac/Diagnostics.swift Sources/CaptureCore/DiagnosticJournal.swift Sources/CaptureCore/DiagnosticEvidence.swift Sources/CaptureCore/DiagnosticUploadAttempt.swift Sources/CaptureCore/UpdateAdmission.swift Tests/CaptureCoreTests/UpdateAdmissionTests.swift Tests/CaptureCoreTests/DiagnosticEvidenceTests.swift Sources/CaptureCore/SpeechGate.swift Tests/CaptureCoreTests/SpeechGateTests.swift Tests/CaptureCoreTests/DiagnosticJournalTests.swift; do
  curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "$BASE/$FILE" -o "$BUILD_DIR/$FILE"
done

# Compile locally with Apple's Swift toolchain; fail visibly if it is missing.
command -v xcrun >/dev/null || { echo "Install Xcode Command Line Tools first: xcode-select --install" >&2; exit 1; }
xcrun swift build -c release --package-path "$BUILD_DIR"
BIN_DIR="$(xcrun swift build -c release --show-bin-path --package-path "$BUILD_DIR")"

# Assemble a standard user-owned .app bundle.
APP_DIR="$HOME/Applications/Voice Feed.app"
STAGED_APP="$BUILD_DIR/Voice Feed.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
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

# The app registers itself as a macOS Login Item on every launch, so the
# LaunchAgent written by earlier installers is retired here.
PLIST="$HOME/Library/LaunchAgents/com.aisloppy.voice-feed.plist"
if [[ -f "$PLIST" ]]; then launchctl bootout "gui/$(id -u)/com.aisloppy.voice-feed" 2>/dev/null || true; rm -f "$PLIST"; fi

# Manual installs launch immediately. The in-app updater relaunches only after
# this process exits, so macOS cannot reuse the old running executable.
if [[ "${VOICE_FEED_AUTO_UPDATE:-0}" != "1" ]]; then open "$APP_DIR"; fi
echo "Voice Feed is installed. Use its waveform icon in the menu bar to connect this Mac."
