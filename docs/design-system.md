# Interface components

RecScribe composes workspace screens with `WorkspaceStyle` and native Studio
controls in `RecScribe/RecScribe/UI/Controls/`. The control library implements
transport actions, status indicators, brand rendering, typography, theme adaptation
and a Canvas waveform. Text uses the macOS system families, including monospaced
timers; no external font files are bundled.

Buttons use native focus and keyboard behavior. Layout supports accessible labels,
enlarged text, adequate hit regions and reduced motion. Theme colors resolve from
macOS semantic colors, with the recording accent following the current app icon.
The live waveform observes its telemetry independently of transcript and workspace
chrome so frequent sample updates remain local to the capture display.

Check presentation directly in the running app. Behavioral tests protect recording,
cancellation, state transitions and storage; optional visual artifacts support
human review without comparing screenshots or relying on private view hierarchies.

The [component assessment](provenance/recording-foundation.md) records the completed
control replacement, compatibility measurements and notice disposition.
