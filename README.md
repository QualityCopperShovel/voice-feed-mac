# Voice Feed for Mac

A small, inspectable macOS menu-bar client for [Voice Feed](https://voice-feed.aisloppy.com/). It records short speech windows locally, skips silence, and sends audio to your private Voice Feed account for transcription. Connected apps receive transcript text, not microphone access.

## Install

Download the signed and Apple-notarized universal app from
[Voice Feed](https://voice-feed.aisloppy.com/), unzip it, and move it to
`~/Applications`. The same notarized release works on Apple silicon and Intel
Macs. Future updates are downloaded from Voice Feed, checksum-verified, checked
with macOS code-signing and Gatekeeper, and installed with rollback. Version 1.5.1 automatically drains pending words,
releases the capture lease, and relaunches after installation. A failed or timed-out
activation leaves the current process open and resumes capture, with a retry in
the menu. Earlier clients need one manual relaunch to activate this behavior.

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

Mac 1.4.9 stages verified updates on disk without quitting the running app.
They take effect on the next operator-controlled launch. Repeated checks cannot
start concurrent installs or repeatedly install an already staged version.
The legacy 1.4.8 updater still relaunches immediately; the automatic channel stays
on 1.4.8 during this migration to avoid imposing another interruption.


## Capture measurements (1.4.10)

Every 30 seconds and at capture end the existing diagnostic uploader retains
numeric gate input/output/discard/buffer counts, gate transitions, RMS peaks,
callback/send delays and queue peaks. A per-capture identifier correlates with
Voice Feed server delivery measurements. No audio or transcripts are logged.
Gate thresholds, pre-roll, idle uploads and metering are unchanged.
Capture history explains the values at https://voice-feed.aisloppy.com/#capture-history.
The helper must be running 1.4.10; downloading alone does not activate measurements.
The legacy automatic channel stays at 1.4.8 to avoid interrupting active capture.

Signed universal build: CI 34430175490, source 71862ff2231b4da077eb19e4fe706b22c68fa718.

## Current input recovery (1.4.12)

Each attempt explicitly binds the engine to macOS's current default input before
checking its hardware format. A removed headset is not reused implicitly. The
helper reports listening only after a converted microphone buffer arrives;
initialization without a buffer fails within ten seconds. Format failures retain
the capture ID, numeric device ID, sample rate and channels in diagnostics.
Native capture failures send a bounded, allowlisted reason to Voice Feed before
closing, so the web status preserves the concrete failure. No device name, audio
or arbitrary error text is uploaded. Updates remain staged until the next launch.


## Continuous microphone and recovery audio (1.5.0)

Scheduled network renewal keeps the same microphone engine and buffers up to 50
seconds of ordered PCM during the bounded drain/reconnect operation. The old
stream finishes before buffered audio enters the new stream; network callbacks
from an old connection cannot fail its successor. A 45-second overall renewal
deadline fails visibly rather than buffering indefinitely.

Ten seconds of exact digital zeros is reported as an unavailable/muted input,
not healthy listening. Quiet nonzero audio remains valid. Capture failures change
the menu-bar icon to a crossed-out microphone and sound a rate-limited alert.

The helper now keeps private one-minute WAV recovery files under
`~/Library/Application Support/Voice Feed/Recovery Audio`, capped at 30 files
(about 30 captured minutes). Files older than 30 minutes are removed during
capture/startup; a stopped app cannot run expiry cleanup. The folder is 0700 and
files are 0600. Audio is saved before speech gating or network transmission;
valid WAV headers are updated on each write. The menu opens these recordings.
This is a local recovery copy, not an automatic re-transcription or cloud backup.
The server still does not retain audio. Old releases did not make these files,
so this feature cannot recover speech lost before installation or absent from
the microphone signal.

Staged updates remain labeled **Restart to use Voice Feed <version>** until
activation. Selecting that action drains owned audio, releases the capture lease,
and reopens the installed bundle. Update messages no longer replace microphone
status, and clicking a capture failure cannot turn it into a false Listening label.

## App icon

The native bundle includes `Resources/AppIcon.icns` at standard and Retina sizes
from 16 to 1024 pixels. The editable source is `Resources/AppIcon.svg`; regenerate
the committed PNG and ICNS with `python3 scripts/build_icon.py` (CairoSVG required
only for artwork development). All installation and signing paths package the
same icon before signing.

### Recovery alarms (1.5.3)

Repeated microphone failures retain exponential backoff (up to 30 seconds)
through brief successful buffers. One alarm marks a capture interruption; another
is armed only after at least 60 seconds of uninterrupted confirmed capture. Sleep
and stopped capture do not sound an alarm. Recovery stays automatic.

A closed lid disconnects built-in microphones on Apple silicon and T2 MacBooks
in hardware: https://support.apple.com/en-euro/guide/security/secbbd20b00b/web .
The helper cannot recover audio the microphone never supplied. Opening the lid
or selecting an available external microphone lets subsequent attempts recover.

### Audio configuration changes (1.5.4)

Hardware configuration changes rebuild the microphone tap on the audio queue
while retaining the transcription socket, queued audio and local recovery writer.
Audio must return within ten seconds; notifications cannot extend that deadline.
Three local rebuilds are allowed until input remains stable for one minute.
Stop, stale callbacks and network drain cannot resurrect the microphone. Exhausted
recovery reports the existing native audio_1 failure before releasing the stream.
Apple's lifecycle contract: https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange .

### Readable capture details (1.5.5)

Show capture details opens a selectable, wrapped snapshot of the full current
status and most recent failure, with its timestamp and a Copy button. Capture
continues while the dialog is open; background status changes cannot overwrite
its text selection. The compact menu summary remains bounded.

1.5.5 also separates callback liveness from signal level. Continuous zero-valued
buffers keep capture alive with a visible waiting-for-sound status. Speech can
resume through the same gate/connection; silence alone cannot cause an alarm or
restart. Missing callbacks, network loss and unstable configuration retain their
existing deadlines. Zero input still warrants checking mute/input/lid if speaking.

### Backend deployment handoff (1.5.6)

The ready event identifies the backend attached to the audio socket. Successful
20-second capture lease renewals identify the backend currently serving new
connections. A changed revision triggers the existing 45-second bounded rotation:
the microphone and local recovery writer stay alive, new frames enter the ordered
rotation buffer, the old connection drains, and buffered frames go to its successor.
No silence boundary is required. Text may briefly lag and a word spanning the
provider boundary may transcribe differently. Duplicate and stale lease replies
cannot restart a completed handoff. Stop, sleep, transport failure and buffer
limits retain their explicit terminal behavior. A legacy backend without revision
metadata continues scheduled renewal; invalid metadata is a visible error.

Diagnostics retain `capture_rotation` stages `backend_deployed`, `scheduled`, and
`completed` with the same capture ID. This client update itself still uses the
existing verified application relaunch; subsequent backend updates do not restart
the audio engine.
