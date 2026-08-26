# Voice Feed for Mac

A small, inspectable macOS menu-bar client for [Voice Feed](https://voice-feed.aisloppy.com/). It records short speech windows locally, skips silence, and sends audio to your private Voice Feed account for transcription. Connected apps receive transcript text, not microphone access.

## Install

Download the signed and Apple-notarized universal app from
[Voice Feed](https://voice-feed.aisloppy.com/), unzip it, and move it to
`~/Applications`. The same notarized release works on Apple silicon and Intel
Macs. Future updates are downloaded from Voice Feed, checksum-verified, checked
with macOS code-signing and Gatekeeper, and installed with rollback.

## Security boundary

- Device approval happens in your signed-in Voice Feed account.
- The capture-only token is stored in macOS Keychain.
- The client can upload audio for transcription but cannot read transcript history.
- Devices can be revoked from the Voice Feed landing page.
- Network requests have explicit deadlines; audio is not retained by Voice Feed.

## Build manually

```bash
xcrun swift build -c release
```

Requires macOS 13 or later and Apple’s Swift command-line tools.

## Signed release

The Account Holder first stores Apple notarization credentials in the login
Keychain under the profile `voice-feed-notary`:

```bash
xcrun notarytool store-credentials voice-feed-notary \
  --apple-id YOUR_APPLE_ACCOUNT_EMAIL \
  --team-id 7ZPTPEXGRC
```

Enter an app-specific Apple Account password when prompted. Then produce the
portable release without exporting the Developer ID private key:

```bash
./release.sh
```

The script signs with hardened runtime, submits with a 15-minute deadline,
staples Apple's notarization ticket, verifies Gatekeeper acceptance, and writes
the distributable ZIP plus its SHA-256 digest under `dist/`.
