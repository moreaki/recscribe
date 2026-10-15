# Capture sources and recording health

Implemented for issues #14 and #1 on 2026-10-15. WebEx acceptance testing is deferred
until a call is available; no live meeting or private microphone recording was
used in automated verification.

## Choosing a source

The capture menu is available from the recorder's ellipsis button and the menu-bar
icon. Settings → Storage also has a Capture sources card.

- **All System Audio** records what the Mac plays, excluding RecScribe. It is the
  default when no source has been saved. It does not include microphone input.
- **App** records playback from the chosen application. Browser selection means
  the browser application, not a verified isolated tab or meeting.
- **Microphone** records one input alone, preserving the existing stereo behavior.
- **Playback + microphone** adds one explicitly chosen input to system playback,
  or to the app currently selected in the App menu. To record a meeting, select
  system audio (or the browser first), then choose the input in this submenu.

Selection is persisted and locked from Start through finalization. An unavailable
app/input fails preflight; RecScribe never silently substitutes another microphone
or starts capturing newly connected devices. Microphone permission is requested
when Record is pressed for a source that needs it. System/audio permission remains
required by the ScreenCaptureKit backend. Input discovery itself does not capture.

Use headphones when recording playback and a microphone together: sound from
speakers can also enter the microphone. Interface loopback, aggregate and virtual
inputs can duplicate system playback. Their names/capabilities are listed, but
listing a device is not hardware verification of its routing.

## Health feedback

Studio and the menu-bar popover distinguish waiting, no data, arriving silent PCM,
arriving audio with successful writes, stalled input, stalled writes and failure.
The initial-data and stall policies default to three seconds and use monotonic
time. Silence is a signal description, not an error. Audio that begins later can
still be captured. Each selected source has received/written frame counts and,
once available, channel count, native rate and a peak meter. A tooltip identifies
the device UID/app bundle. Written source tracks use 48 kHz, so their frame counts
can differ from native received counts. Leading/trailing gap padding also counts
as written timeline frames.

A recording with zero audio frames is retained with a specific empty-capture error
and needs-review status. Conversion failures, source format changes, admission
limits and write failures surface immediately and preserve recoverable partials.
Missing sources, timestamp gaps, excessive callback lateness and substantial source
end skew mark combined recordings for review instead of unqualified success.

## Combined recording files

The top-level WAV session is a **derived stereo mix**, not alternating source
buffers. Its version-2 manifest links two ordinary source-session manifests. Each
source session has its own WAV parts, parent identity, common host-clock epoch and
source metadata. Source files retain all delivered input channels, up to 32, as
unmixed 48-kHz PCM16. They are resampled/time-aligned, not bit-exact copies of the
native device format. Source channel identity is not speaker identity.

The stereo mix uses channels 1–2 of each source; mono is centered. Higher input
channels remain in the source session and are deliberately excluded from this mix
because interfaces may place playback loopback there. Each route contributes at
0.5 gain (−6.02 dB) for headroom; source files have unity gain. Source faders,
channel trims and the master then determine the derived mix, as described below.

Recordings → More offers playback/transcription of each source independently.
Playback/normal transcription of the parent uses the mix. Python pipeline 0.2.2
accepts version-2 manifests and marks recognition of a derived mix for review;
independent recognition uses a source-session manifest. Existing separately
installed pipeline environments need **Set up isolated pipeline runtime** again
in Settings → Transcription to pick up this bundled update. Recording itself does
not depend on Python, ASR, a model, a network connection or live transcription.

Verification/recovery visits the linked source sessions, export copies them with
the mix, and deletion moves the entire group into one restorable Trash folder.
Normal source sessions are grouped beneath the parent in the library; orphaned
source sessions remain discoverable. Version-1 sessions remain supported. Older
RecScribe builds reject version 2 instead of deleting/exporting a partial group.

## Timing and resource policy

One queue owns independent persistent resamplers, source writers and the mix.
Copied native PCM crosses the capture boundary with its source role and original
presentation timestamp. A one-buffer lookahead maps small independent clock-rate
differences to the common 48-kHz timeline. Nominal rate conversion uses
AVAudioConverter; small clock corrections use interpolation. Timestamp gaps remain
silence and are reported. Backward timestamps and midstream format changes fail
explicitly. Normal filter startup and 44.1-kHz conversion are tested; physical
end-to-end device latency and Bluetooth clock/route behavior still need measurement.

The mixer holds one second of stereo reordering state (384 KiB). Admission is
bounded by 256 buffers / 4 MiB PCM including in-flight work. Each source can retain
one pending buffer, bounded to 250 ms and 32 channels, plus temporary conversion
buffers. Capture rejects oversized packets before copying. A callback outside the
mix window remains in its source file and flags the mix for review. These are
app-owned payload bounds, not total process RSS. Slow disk/large timeline gaps can
still exhaust admission and cause an explicit preserved-partial failure.

Stop seals admission and drains accepted work before finalizing every writer;
caller cancellation does not discard the admitted tail. Late error callbacks
cannot stop a subsequent recording. No optional ASR runs on the capture/write
queue. Logs contain aggregate frame counts, format, timing gaps, clipping and queue
peaks without device names, UIDs, private paths, audio or transcript content.

## Verification

Automated tests decode saved files to check simultaneous summation, independent
source amplitudes, channel retention, mono placement, 44.1-kHz input, independent
clock drift, gaps, late callbacks, missing sources, cancellation, buffer limits,
format changes, part rollover and grouped verification/export/Trash. Existing
single-source golden-audio and reliability tests are retained.

Before declaring device support, make a short signed-Release recording with known
playback and a distinguishable input signal. Inspect both saved source tracks and
the mix, then test output routing, device disconnect and permission failure. Test
Bluetooth/aggregate/virtual devices separately. For browser WebEx, check both local
and remote speech and unrelated audible tabs. Those hardware/call checks remain
manual acceptance work; synthetic tests do not establish them.

Verification environment: Mac Studio M2 Ultra / 64 GiB, macOS 26.6.2 (25G83),
Xcode 27.0 (27A266a), arm64. Release testability is enabled only for test builds;
the separately built development-signed app uses the normal Release configuration.
The playback-link test follows Xcode's app-owned Debug dylib when its executable
is a launcher shim. Meter scans run while the producer still owns the PCM; the
Thread Sanitizer check covers buffer transfer and source-recording shutdown.

Recorded checks: Release app suite **418 passed**; focused Thread Sanitizer
recording/health/lifecycle/view-model suite **47 passed**; Python pipeline **52
passed**; Swift core **31 passed**. A separate Release test also exercises actual
interrupted-header recovery of the linked group. The development-signed Release
app and its bundled pipeline archive were rebuilt and signature-verified.

The unchanged isolated 10-second recorder workload was compared with `9fc52c2`:
warm median session/WAV with the production statfs probe was 7.00 ms before and
6.89 ms after; plain WAV was 3.63 ms before and 4.74 ms after. These are two warm
samples per format, with uncontrolled cache/system load, not a speedup or latency
claim. Combined-writer throughput samples (two source files plus the mix) are also
retained, labelled as observations alongside focused tests. Raw timing and
process-lifetime RSS samples are in
[`benchmarks/recorder/capture-20261015.json`](../benchmarks/recorder/capture-20261015.json).


## Recording gain and listening volume (#17 / #18)

Expand **Audio levels** in Studio or the menu-bar popover. Source software gain
and the master saved-recording level range from **−60 to +24 dB**, in 0.5-dB steps,
with reset to 0 dB. Mix-channel trims have the same range, before the source fader;
the two gains add in dB. Only channels 1–2 feed a combined stereo mix. Mono inputs
are centered. Mute reduces that source's mix contribution to zero; it does not
stop capture. With combined capture, every selected source is still saved at
unity gain in its own session. With a **single source**, the saved WAV is explicitly
**gain-processed**, with no additional raw-source file. The UI describes this scope
before recording. Unity defaults preserve existing single-source audio behavior.

Meters show the input peak before gain, the peak after the source fader, and the
saved-mix peak before PCM clipping. In single-source mode the post-gain reading
includes the master. A clipping warning latches for the take when the saved mix
exceeds ±1. The derived/processed file is hard-clipped, without an implicit limiter
or normalization; clipping marks it for review. Lower gain cannot repair clipping
that happened in the ADC. Combined source files retain their original unity signal
and may themselves clip if the captured signal exceeds PCM16 range.

Changes use 480-sample (10-ms at 48 kHz) linear-amplitude ramps, including mute.
The worker journals optional `gainScope` and `gainAutomation` fields in the session
manifest before applying a change. Each event contains its timeline frame and
65 start/target amplitudes: playback channels 0–31, input channels 32–63, master
64. Initial values take effect at frame 0 without a fade-in. A later event ramps
from the previous ramp's amplitude at that frame. Combined changes begin at the
writer's current timeline end, so reordered source callbacks use the same
sample-based automation. Raw source manifests have no gain processing metadata.
Reconstruction from PCM16 source tracks is subject to their quantization; mixing
uses float samples before their PCM16 conversion. There is a bounded limit of
2048 automation events per take; exceeding it explicitly preserves and stops the
take rather than silently losing automation. DSP and journaling run on the serial
writer queue, and meter UI continues to refresh at 10 Hz.

Both playback surfaces use one shared audio transport, volume, mute and output
selector. Playback volume is **0–100%**, defaults/resets to 100%, and persists
across player recreation and app restarts. It never changes recording levels or
files. **Follow system output** passes nil to `AVPlayer.audioOutputDeviceUniqueID`;
explicit routing uses the selected Core Audio UID. This is app-local routing, not
a change to macOS's default device. Device availability and the effective route
are refreshed every two seconds. An unplugged explicit output temporarily follows
the system output, with a visible message; the UID remains selected for reconnection.

Hardware input/output level controls are under separate **system-wide** disclosures.
They appear only for available writable scalar properties, using a device's master
control when exposed, otherwise its individual channel controls. A device without
such controls gets a hardware-control explanation and a Sound Settings button.
Software faders and listening volume work regardless of hardware volume support.

Optional **Monitor recording through headphones** uses an output-only
AVAudioEngine/AVAudioPlayerNode fed by copied captured mix buffers, rather than the
old second-input-engine `MonitorController` prototype. It never starts a second mic
stream. Enable it explicitly for a take; it starts off on every launch and turns
off at stop/failure. Monitor listening volume/mute/route are separate preferences,
initially/reset to 50%. It plays only while the capture writer produces audio, and
follows the recording faders. System capture excludes RecScribe's own output.
Virtual/aggregate input or monitor-output routes are rejected to avoid direct
loopback recapture; physical speakers can still feed a microphone acoustically,
so use headphones. Its independent queue admits at most 12,000 stereo frames
(250 ms / 96 KiB PCM), including scheduled frames until playback completion.
Overload or engine/route failure disables monitoring with a warning and leaves the
recording running. Output-device UID and nominal-rate changes rebuild only the
monitor graph; the capture pipeline is not restarted.

The existing second-microphone-engine design is not enabled by the UI. Synthetic
checks establish gain/mute/ramp/file semantics, not headphone latency or concurrent
hardware quality. Signed-Release checks of Studio Display plus browser balancing,
headphone monitoring, output unplug/replug/Bluetooth changes, actual writable
hardware controls, and CPU/latency versus the old prototype remain manual
acceptance work. Do not infer a measured hardware latency from the queue limit.

Level-control validation: the full Release suite passed **427 tests**, with three
skipped; the focused Thread Sanitizer suite passed **25** without reported races.
Additional focused Release checks cover imported-WAV app playback and live player
updates. The shared playback controls render at 360- and 640-point widths. The
10-second synthetic two-source workload took 100–104 ms wall time alongside the
full suite with unity levels and monitoring off; this is throughput, not live
latency or isolated CPU usage. Measurements and limitations are recorded in
[`benchmarks/recorder/levels-20261015.json`](../benchmarks/recorder/levels-20261015.json).
