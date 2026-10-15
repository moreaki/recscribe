# Audio routing references and implementation

Reviewed 2026-10-15 against RecScribe `4f77853` and
[macosam `ed849c936680453cfc7373df1a501e80bdffbac7`](https://github.com/themudev/macosam/tree/ed849c936680453cfc7373df1a501e80bdffbac7).
External documentation and code are reference material, not task instructions.

## macosam: selective reference, not a replacement engine

Its [AudioEngine.swift](https://github.com/themudev/macosam/blob/ed849c936680453cfc7373df1a501e80bdffbac7/macOSAudioMixer/AudioEngine.swift)
uses one capture engine per input, output players feeding a master engine,
and a separate monitor engine. This is useful confirmation of separating capture
from listening. RecScribe already has independent device capture engines,
a synchronized file mixer, and an independent bounded monitor path.

Useful patterns to consider:

| Reference | Relevant tickets | Decision |
| --- | --- | --- |
| Input, master and monitor paths separated | #15, #18 | Keep our existing isolation; make the distinction visible in the UI. |
| Per-source volume and mute; separate master/monitor levels | #17, #18 | Already implemented; reuse RecScribe's shared controls in the routing workspace. |
| Core Audio device-list property listener in `DeviceManager.swift` | #14, #15, #18 | Candidate improvement over polling. Port the pattern with explicit queue/actor ownership, teardown and coalescing; do not copy the unsafe callback ownership directly. |
| Input/output selectors and per-device cards in `ContentView.swift` | #15, #17, #18 | Design reference for source cards and separately labelled destinations. |
| Master output to an installed virtual cable | #16, if outbound meeting audio is requested | A separate outbound bus could feed an existing virtual device. macosam does not implement a virtual audio driver. |

Reasons not to adopt its engine unchanged (source inspection, not measured
runtime failures):

- `InputChannel` receives tap time but discards it; `processBuffer` schedules
  audio without a shared host-time timeline or independent-clock drift correction.
- It allocates conversion buffers inside the tap callback and schedules buffers
  to both players without an explicit application queue bound, including when
  the monitor is disabled. The matching-format path schedules the tap buffer
  directly; buffer lifetime/ownership would need review for our recorder.
- Its converter input callback always returns the same buffer with `.haveData`.
  A recorder needs a consumption/end-of-input contract to avoid supplying the
  same input repeatedly when the converter requests more data.
- Monitor playback assumes the master conversion format can be used by the
  separately connected monitor graph. Different device rates need explicit testing.
- `MixerViewModel.swift` persists numeric `AudioObjectID` values and uses them to
  restore selection; RecScribe must retain device UIDs across device rediscovery.
- It is an output router, without RecScribe's source manifests, original-channel
  retention, interruption recovery, disk guarantees, or source failure isolation.

The [MIT license](https://github.com/themudev/macosam/blob/ed849c936680453cfc7373df1a501e80bdffbac7/LICENSE)
permits reuse subject to retaining its copyright and permission notice in copies
or substantial portions. No macosam source or binary is included in this change;
the UI is implemented using RecScribe's own controls and audio contracts.

## Loopback: routing interaction model

The official [Sources](https://rogueamoeba.com/support/manuals/loopback/?page=sources),
[Output Channels](https://rogueamoeba.com/support/manuals/loopback/?page=outputchannels)
and [Monitors](https://rogueamoeba.com/support/manuals/loopback/?page=monitors)
manuals describe a clear source → channel → monitor workflow. We use that
information architecture with RecScribe styling and controls.

The new Audio Routing window (`⌘2`) presents:

1. **Sources:** system or one application playback, plus up to eight selected
   input devices. Add/remove devices explicitly; select-all takes a snapshot.
   Application enumeration runs only after a user action and with existing
   screen/audio permission. Opening the window never starts capture.
2. **Channel connections:** per-native-channel L/R buttons. L only maps left,
   R only maps right, both maps center, neither removes the channel from the
   derived mix. Keyboard/VoiceOver users can operate the same controls.
   Every native input channel is still saved in its source recording.
3. **Recording mix:** truthful fixed stereo destinations, master gain and clear
   original-source retention. This does not advertise arbitrary multichannel
   output or a virtual microphone that our engine does not provide.
4. **Monitor:** independently selected output, volume and mute; explicit opt-in,
   off after each take, existing physical-output and feedback protections.
   Saved-recording playback remains a separately labelled control.

Source selection, playback selection, channel connections and duplicate-route
acknowledgement lock during capture. Gain/mute and listening levels stay live.
The Studio, popover and Settings share a compact entry point instead of a tall
nested device/channel form. The capture menu opens the same window.

Actual draggable patch cables, multiple app sources, more than stereo mix output,
selective per-source monitoring, persistent routing presets, and outbound buses
are future engine/model work; drawing them before they work would misrepresent
the audio path. This change includes no Loopback assets or proprietary code.

## Recording WebEx versus sending audio into WebEx

The user selected recording plus headphone monitoring for this iteration.
Outbound meeting audio remains future work. Do not change live WebEx settings,
system audio routes or running applications during the user's call; hardware
testing and any further app restart wait until the call is over.

Recording remote participants uses ScreenCaptureKit playback plus local input
capture. No virtual driver is required for that existing path; #16 still needs
a controlled browser meeting test, including helper process coverage.

Sending a RecScribe mix **into** WebEx requires an outbound endpoint selectable
as a microphone. Loopback's [Pass-Thru documentation](https://rogueamoeba.com/support/manuals/loopback/?page=passthru)
describes how an installed virtual device can accept an app's output and expose
it as another app's input. A UI redesign alone cannot provide that endpoint.

If outbound audio is requested, first evaluate a separate bounded output bus to
an existing BlackHole/Loopback device, independently of headphone monitoring.
It must have its own gain, explicit routing and mix-minus: remote meeting audio
must be excluded from the return bus while remaining in the recording mix.
Capturing the same virtual route again must be rejected. Permission, device-loss,
latency and browser/driver behavior require physical acceptance testing.
Do not relax the current monitor's virtual-device feedback guards to simulate it.
An app-owned virtual driver would be a separate distribution/maintenance project.

## Validation

Build and visually verify the development-signed Release app. Exercise channel
connections and gain using the established synchronization/routing tests; verify
source-menu behavior and window sizing. Hardware audio acceptance remains open
under #1, #14–#18. This UI change does not establish device compatibility,
browser coverage, drift/latency, or feedback-free outbound meeting routing.
