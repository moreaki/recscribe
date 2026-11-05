# Interface components

RecScribe uses `WorkspaceStyle` for workspace chrome and retained `Glass*` controls
for transport buttons, brand lockups, waveform bars and shared metrics. The latter
remain part of the source replacement inventory in #51; their current presence is
not a claim that the migration is complete.

The components live under `RecScribe/RecScribe/DesignSystem/`, and application
composition lives under `UI/`. Text uses native San Francisco and SF Mono. No
external font files are bundled.

Replacement components must preserve keyboard navigation, accessible labels,
contrast adaptation, minimum hit regions and reduced-motion behavior. The app's
recording indicator, source controls and permission actions must remain clear at
compact window sizes and with enlarged text. Validate presentation directly in the
running app and use behavioral tests for capture, cancellation and state changes.

See the [replacement inventory](provenance/recording-foundation.md) for remaining
components and source-notice decisions.
