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

## Open at login

On every launch the app registers itself with macOS as a Login Item through
`SMAppService`, so it returns after a reboot or crash whichever way it was
installed. The menu shows the current state ("Opens at login", "needs
approval", or "off") and clicking it repairs the registration or opens System
Settings › Login Items. Earlier installers wrote a user LaunchAgent; the app
removes that duplicate once macOS owns the login item.

## Live transcription

Version 1.4.1 streams PCM audio continuously through Voice Feed and BrightWrapper
using gpt-live-transcribe. Text arrives during speech; stop and quit drain the
pending final result before releasing the microphone lease. No local recordings
are created. A bounded queue, connection/send/heartbeat deadlines, and explicit
failure status prevent silent audio loss during a stalled connection. Sessions
rotate after 19 minutes through the same drain path.

Provider price: $0.017 per audio minute ($1.02/hour), including submitted silence.
BrightWrapper meters cumulative PCM duration with whole-cent rounding per session.

Version 1.4.0 was withdrawn because its AppKit bootstrap was missing. Version
1.4.1 restores the application lifecycle and tests that both native executables
stay running after launch. An affected installation must be replaced and opened
once because an exited helper cannot run its updater.

The 1.4.2 helper streams through short pauses and suspends audio uploads after 10 seconds of quiet. The microphone stays active locally; a rolling one-second pre-roll preserves speech onset when streaming resumes. Idle heartbeats contain no audio.

### Crash diagnostics (1.4.6)

The menu's **Open diagnostic logs…** opens `~/Library/Logs/Voice Feed`.
`events.jsonl` and four rotated copies (512 KiB each) retain launch, audio format,
capture, reconnect, update and quit events, with 30-second main-loop heartbeats.
Writes are synchronized to disk. Error records include domain/code, not payloads;
no microphone audio, transcript text, credentials or provider responses are logged.
A remaining session marker produces `previous_unclean_exit` on the next launch.
That means the previous run did not complete normal termination; a crash, force
quit, power loss or shutdown interruption can all cause it. It is not a diagnosis.

**Open macOS crash reports…** opens Apple's DiagnosticReports directory. A
VoiceFeedMac `.ips`/`.crash` report there supplies the exception and crashing
thread; the app log supplies the preceding lifecycle. While paired, version
1.4.6 automatically syncs structured journal events and summaries of this app's
recent `.ips` reports at launch and every 30 seconds. It backfills earlier runs,
prioritizes recent evidence, retries failed uploads, and acknowledges records only
after the server stores them. The menu shows sync success, failure or timeout.

The authenticated [Capture history](https://voice-feed.aisloppy.com/#capture-history)
combines server and Mac evidence. Crash summaries contain exception, signal,
termination and faulting-thread symbols/image identities; full dumps, paths,
registers, audio, transcripts and credentials are excluded. Storage is scoped to
the paired owner and bounded to 30 days / 1,000 Mac events. A truncated journal
record or malformed report is reported explicitly without blocking readable rows.
No custom fatal-signal handler interferes with Apple's crash reporter. Local
log-write failures are also reported to macOS unified logs. Logs can sync only
while the helper is running and can reach Voice Feed.

### Sleep and hardware changes (1.4.7)

Capture pauses when the workspace sleeps and reacquires the microphone after
wake without changing the saved enabled preference. Audio taps use the device's
negotiated format; conversion follows the actual incoming buffers. A native
AVFAudio exception becomes a recoverable capture error instead of terminating
the helper. Old network and capture callbacks cannot restart a stopped generation.
A microphone that produces no buffers for 30 seconds fails visibly and retries;
backoff resets only after microphone initialization succeeds.

This release also replays retained diagnostics once after the server's retention
repair, so historical heartbeat uploads cannot evict newer crash evidence.

Mac 1.4.8 retains bounded, redacted Objective-C exception names, reasons and
throw stacks in automatic diagnostics. Apple crash reports also retain available
application-specific messages and exception backtraces; missing messages are
explicit. Existing incidents are enriched rather than duplicated. Signed release
source: 3e4ce635a93022f23d864d901ff90fac034937fb (CI 34398296964).
