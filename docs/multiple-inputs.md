# Multiple input devices with playback

Choose **Capture inputs → Use multiple inputs + playback** in Studio or the
menu-bar popover, or **Multiple inputs + playback…** in the capture menu. The same
picker is in Settings → Storage. Select devices individually or use **Select all
available inputs**. That action snapshots the eligible devices currently connected;
new or reconnected devices are never added to a running take. **Deselect all**
records playback alone. The explicit policy limit is eight inputs plus one playback
source, with 1–32 native channels per input.

Playback defaults to all system audio. To capture one app instead, select it in the
capture menu before choosing multiple-input mode. System and per-app playback are
mutually exclusive, avoiding duplicate playback capture. RecScribe's own output is
excluded from ScreenCaptureKit system/app capture. The app never changes macOS's
default input/output, installs a loopback driver or creates a permanent aggregate.

For each device, **Mix channels** chooses channels for the derived stereo mix and
places them left, center or right. Mono is centered. New multichannel selections
initially route only channels 1–2; additional channels require explicit inclusion
because interfaces may expose playback loopback there. **Every native input channel
is saved in the separate source session**, including channels unchecked in the mix.
A source with no mix channels is still recorded separately. Source and channel names
are retained with the source's UID identity; device identity does not identify a
speaker. The picker shows native channel counts, labels, nominal rates and
hardware/virtual/aggregate classification when available.

Possible virtual/loopback routes, named loopback channels, aggregate/member overlap,
overlapping aggregates and unknown aggregate membership require review. Recording
is refused until overlapping choices are removed or **Include these possible
duplicate / loopback routes** is explicitly enabled. Select-all does not bypass
this check. Hardware drivers do not always expose semantic channel identities, so
unknown hardware loopback cannot be inferred reliably from a channel number. Check
the interface's routing. Use headphones to avoid acoustic recapture of speakers.

Expand **Audio levels** for a separate fader/mute and channel trims for every chosen
input, plus playback gain and the recording master. Gains persist by device UID,
shared with previous single-input choices. Mute affects the mix, not source files.
Channels routed to each side are averaged on that side; source contributions are
then averaged across the selected source count. This supplies fixed headroom and
keeps surviving sources at the same gain when another source fails. The master can
raise the resulting mix, with explicit hard-clipping detection. Source tracks remain
unity-gain 48-kHz PCM16, resampled/time-aligned rather than bit-exact native copies.

## Timing, capture and failure policy

System/app playback continues to use ScreenCaptureKit. Multiple-device inputs use
independent input-only AVAudioEngine instances, each bound to the explicitly chosen
Core Audio UID with `kAudioOutputUnitProperty_CurrentDevice`. Each input node has a
recording tap and no listening/output connection. This avoids the old monitoring
prototype's second input stream and avoids aggregate-device lifecycle/default-device
side effects. Drivers that cannot be opened independently fail explicitly at start;
no microphone is substituted. Ordinary system/app/one-microphone capture remains on
its existing ScreenCaptureKit path.

Taps transfer bounded copied Float32 PCM with AVAudioTime's host time. Missing host
time, changed formats and oversized packets fail the affected source; timestamps
are not invented. ScreenCaptureKit PTS and input host time share the host-clock
epoch created before input startup. Independent stateful converters produce a common
48-kHz timeline, and one-buffer lookahead maps small sample-clock differences to
successive timestamps (up to 2% correction). Start offsets and real gaps remain
silence. There is no assumed sample-clock lock between devices and no speculative
fixed latency offset. Physical hardware/driver timestamp accuracy and end-to-end
latency compensation remain subject to measurement; host alignment does not promise
phase coherence between different microphones.

An unavailable input at start fails preflight. A disconnected input, tap failure or
midstream format/timestamp failure is disabled for the take, marked failed in live
health and journaled as incomplete. Previously admitted buffers drain before the
failure marker. Other selected inputs and playback continue; a reconnected device
requires a new take. The failed source's existing audio is preserved and its tail
padded with silence. A device delivering no data has explicit no-data/stall status;
a quiet signal is distinguished from missing callbacks. Stop reports incomplete
coverage instead of presenting success. System capture/permission failure, disk
failure or shared admission overload remains fatal to the take and preserves
recoverable partials.

## Storage and resource bounds

Variable groups use **manifest version 3**, with ordered source descriptors, stable
filename-safe hashed track IDs derived from UIDs, channel routing and source failure
metadata. Source sessions remain ordinary version-1 WAV manifests with parent/epoch
and source identity/channel labels; legacy two-role groups retain version 2. Existing
version-1/2 recordings and source preferences stay readable. Recovery, verification,
export, source playback/transcription and grouped Trash traverse all linked sources.
The parent WAV contains the derived stereo mix.

Gain automation records `gainTracks` in slot order. Each source has 32 amplitude
slots; the final slot is the master. Ten-ms ramps retain the existing semantics.
The event budget is `min(2048, 131072 / amplitudeCount)`, bounding metadata even with
nine sources. Old 65-amplitude automation stays readable.

The writer's shared admission limit remains **256 buffers / 4 MiB of owned PCM**
including in-flight work, across all selected sources. The mixer has one second of
stereo reordering state (384 KiB), plus one normalized pending packet per source:
up to 250 ms × 48 kHz × 32 channels × 4 bytes (about 1.46 MiB per input; playback is
stereo). At the eight-input maximum this pending PCM is about 11.9 MiB including
playback. Native tap copies individually reject packets over 250 ms or 4 MiB, and
release the producer's borrowed buffers immediately; simultaneous tap copies and
framework/converter/engine buffers are additional to writer admission. At most one
callback per input can hold its transfer lock. These are app-owned payload limits,
not a bound on total process RSS or framework allocation. Queue overload fails
explicitly. No ASR, network or model work runs in a tap or writer callback.

Optional headphone monitoring consumes the captured mix through the existing
output-only monitor queue. It does not open another microphone, and monitor failure
cannot stop capture. Monitoring is disabled for selected virtual/aggregate inputs
even when their inclusion in recording was acknowledged.

The bundled Python pipeline is **0.2.3**, reading manifest versions 1–3 and retaining
source identity in inspection reports. Existing installed Python environments need
explicit **Set up isolated pipeline runtime** again to receive this update before
transcribing version-3 groups. Capture does not depend on the Python runtime.

## Verification and remaining hardware checks

Synthetic decoded-audio tests cover three independent sources, 44.1/48-kHz inputs,
clock drift, startup offsets, native channel retention, higher-channel mix routing,
per-UID gain, tap copy/host-time ownership, late callback sealing, per-source failure
during drain, preservation of accepted tails, microphone permission gating, legacy
preferences/manifests and three-source recovery/export/Trash. Release benchmarks
exercise 2/4/8 inputs plus playback with synthetic signals and label whole-process
RSS separately from owned PCM. They measure file/DSP throughput, not live latency.

Physical acceptance is still required for Studio Display plus a USB/interface,
Bluetooth sample-rate/route changes, aggregate/virtual drivers, device removal,
per-route distinguishable saved signals and concurrent CPU/latency/queue behavior.
A discovered device or successful synthetic test is not a hardware compatibility
claim. No private microphone audio is recorded or uploaded by the automated tests.

API references: [Apple input node](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode),
[recording taps](https://developer.apple.com/documentation/avfaudio/avaudionode),
[aggregate members](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicepropertyactivesubdevicelist).

Recorded checks on M2 Ultra / macOS 26.6.2 / Xcode 27.0: full Release app suite
**439 passed, 2 skipped**; focused Thread Sanitizer suite **31 passed**, no reported
races; Python pipeline **54 passed**; shared Swift core **31 passed**. A further
focused Release run passed **43** tests covering final picker/preflight and
legacy-pair naming changes. The final native tap/background-queue and lifecycle/
reliability Thread Sanitizer run passed **24** tests without reported races. The
running signed app’s picker was checked with Studio Display Microphone and
Microsoft Teams Audio discovery; no private audio was captured for this UI check. The
signed Release app includes pipeline 0.2.3.

Synthetic 10-second throughput samples alongside the full suite were 96–100 ms
for two inputs plus playback, 141–155 ms for four inputs plus playback, and
241–265 ms for eight inputs plus playback. No physical capture/latency or CPU
claim follows from these numbers. Raw samples and process-lifetime RSS are in
[`benchmarks/recorder/multiple-inputs-20261015.json`](../benchmarks/recorder/multiple-inputs-20261015.json).
