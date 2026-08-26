#!/bin/bash
# Build and install Voice Feed from inspectable source. Nothing is downloaded
# or executed with elevated privileges.
set -euo pipefail

# Work in a disposable directory and remove it on success or failure.
# Pin all build inputs to one reviewed client release. The outer installer may
# be fetched from `main`, but the executable source cannot drift mid-install.
BASE="https://raw.githubusercontent.com/QualityCopperShovel/voice-feed-mac/fa9af73f1a9547431b1dd9e8fc6e959e6d1844a1"
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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$HOME/Library/LaunchAgents"
install -m 755 "$BIN_DIR/VoiceFeedMac" "$APP_DIR/Contents/MacOS/VoiceFeedMac"
install -m 644 "$BUILD_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Create one local code-signing identity on the first signed release and keep
# its private key in the login keychain. Reusing this identity gives every
# later build the same designated requirement, which is how macOS recognizes
# an update as the same app for microphone and Keychain authorization.
SIGNING_NAME="Voice Feed Local Update Identity"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | awk -v name="$SIGNING_NAME" 'index($0, "\"" name "\"") {print $2; exit}')"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  command -v openssl >/dev/null || { echo "OpenSSL is required to create the persistent Voice Feed signing identity." >&2; exit 1; }
  cat >"$BUILD_DIR/codesign.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = Voice Feed Local Update Identity
O = Voice Feed Local
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$BUILD_DIR/codesign.cnf" -keyout "$BUILD_DIR/codesign.key" \
    -out "$BUILD_DIR/codesign.crt" >/dev/null 2>&1
  IMPORT_PASSWORD="$(openssl rand -hex 24)"
  openssl pkcs12 -export -name "$SIGNING_NAME" \
    -inkey "$BUILD_DIR/codesign.key" -in "$BUILD_DIR/codesign.crt" \
    -out "$BUILD_DIR/codesign.p12" -passout "pass:$IMPORT_PASSWORD"
  security import "$BUILD_DIR/codesign.p12" -k "$LOGIN_KEYCHAIN" \
    -P "$IMPORT_PASSWORD" -T /usr/bin/codesign >/dev/null
  unset IMPORT_PASSWORD
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | awk -v name="$SIGNING_NAME" 'index($0, "\"" name "\"") {print $2; exit}')"
fi
[[ -n "$SIGNING_IDENTITY" ]] || { echo "Voice Feed signing identity is unavailable." >&2; exit 1; }
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

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
