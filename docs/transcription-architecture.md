# RecScribe architecture

RecScribe records local audio into recoverable sessions and transforms finalized
recordings into versioned transcripts and derived text. The SwiftUI application
and native command-line tool share the Swift processing implementation in `core/`.

The recording foundation uses RecScribe's replacement implementations. The
[component assessment](provenance/recording-foundation.md) records their behavior
contracts, provenance review, notice disposition and historical-audit limitations.

## Recording

`Capture/` discovers and configures playback and input sources. System-wide and
per-application playback use ScreenCaptureKit; selected input devices have separate
capture lifecycles. Input enumeration does not itself start capture. Permission
requests originate from user actions, and passive observation shares the current
request result rather than issuing repeated prompting calls.

Capture callbacks transfer owned PCM into bounded serial writer pipelines. Multiple
sources retain separate original tracks and a derived stereo mix. Source identity,
clock alignment, channel selection, gain automation and capture health are recorded
with the session. Device loss or writer failure must remain visible without
silently substituting an unrelated source.

The PCM decoder accepts supported integer and floating-point representations and
checks source-plane bounds before reading. The streaming normalizer retains its
resampler across callbacks, passes canonical buffers through unchanged, and
selects the first source channels when a discrete input needs reduction.

The WAV sink owns its descriptor throughout capture and finalization. It writes
payloads and header checkpoints at independent offsets, respects RIFF size bounds,
and retains the established signed-PCM16 quantization. Session splitting, recovery,
checksums and export remain responsibilities of the session layer.

See [capture sources](capture-sources.md), [recording studio](recording-studio.md)
and [recording sessions](recording-sessions.md) for detailed source/storage behavior.

## Sessions and preservation

`Sessions/` owns manifests, recording libraries, playback, verification, recovery
and export. Original audio and raw transcripts are evidence, not disposable working
files. Recovery copies complete frames and replaces an interrupted file only after
checking the original identity and synchronizing the replacement. Active capture
is excluded from destructive or recovery operations.

Session formats remain readable across implementation changes. Source replacement
must not reset user preferences, change the installed signing requirement or clear
macOS recording permissions. Errors and cancellation must preserve accepted audio
and expose incomplete or failed work explicitly.

## Audio and text jobs

`RecScribeCore` inspects WAV/session input, prepares temporary analysis audio,
invokes the configured whisper.cpp adapter, validates canonical transcripts and
renders deterministic exports. The app and `recscribe-text transcribe` use the same
native implementation. Recognition requires neither Python nor FFmpeg. FFmpeg is
optional for compressed archive export.

Each job has bounded work, cancellation and a terminal state. Immutable recognizer
output, model/configuration identity, hashes and mapping to source audio remain
available for review. Disposable audio is removed on terminal completion; retained
raw evidence is not silently deleted with it. Verified recognition uses a distinct
second model. Unsupported language or speaker stages remain explicit pending or
review states.

Text normalization, translation and source-linked summaries use native text jobs.
Local processing is the default. Cloud text processing requires explicit approval
and configured credentials; the interface must identify what leaves the Mac.

See [Swift implementation](swift-first-migration.md), [WAV workflow](wav-vertical-slice.md),
[transcript contracts](../schemas/transcript-v1.1.schema.json) and [benchmarks](../benchmarks/README.md).

## Live drafts and interface

Optional live transcription reads only complete PCM already written by capture.
Its worker never performs recognition inside a capture callback and never changes
original recordings. Live drafts are visibly unverified and remain separate from
the canonical finalized transcript.

`App/` composes services, permissions, launch/menu/window lifecycles and diagnostics.
`UI/` presents Studio, Routing, Recordings and Settings. Observation is localized to
state owners and telemetry leaves. Device controls, mix controls, playback volume
and headphone monitoring have distinct scopes.

See [interface components](design-system.md), [live transcription](live-transcription-reliability.md)
and [distribution](distribution.md).

## Validation

Existing recording and session tests define the compatibility contract during
replacement. Run native core tests, including frozen references, and app tests for
changed capture, permission and writer paths. Do not regenerate reference fixtures
from replacement output to obtain a pass. Release builds are a separate gate from
Debug tests; concurrency changes require appropriate sanitizer checks.

The owner manually tests the signed application before merge. Unit tests establish
behavior on their exercised inputs; provenance review separately establishes that
inherited implementations and assets have actually been replaced.
