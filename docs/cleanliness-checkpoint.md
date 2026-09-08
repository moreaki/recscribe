# Cleanliness checkpoint — 2026-09-07

Historical checkpoint. The follow-up work below was completed on 2026-09-08;
see [completion and measured verification](cleanliness-completion.md).

Scope: the remaining cleanliness tickets and menu access. Simultaneous system
audio + microphone capture (#1) is explicitly out of this batch. Work stopped at
the user's requested checkpoint; remaining acceptance work is listed below.

## Implemented

- #8: WAV and multipart jobs use one cancellable completion flow for language
  processing, review, schema validation, rendering, inventory and terminal state.
  Review thresholds live in `ReviewPolicy`; progress values are stage milestones,
  not wall-clock predictions. Raw evidence remains separate and unchanged.
- #4: `PCM16WAV` owns the canonical fixed-layout PCM16 RIFF contract. Writer,
  legacy recovery and multipart recovery share it. Recovery copies bounded blocks
  through a private temporary file, syncs and atomically replaces, checking
  cancellation before publication. Wide size arithmetic guards the RIFF limit.
- #7: `LocalProcessRunner` owns execution, bounded output draining, cancellation,
  timeout, elapsed time and correlation IDs. Only the owned child PID is stopped.
  At most 20 private JSON diagnostic tails (128 KiB of output per run before JSON
  escaping) are retained under Application Support/RecScribe/Diagnostics/Processes.
  Files are mode 0600, directory 0700. Output and command arguments never enter
  unified logging. Private tails can contain tool output; review before sharing.
- #2/#6: an app composition root passes settings, runtime and session dependencies
  explicitly. Injecting an audio writer no longer changes recording coordination.
  Typed session, part, job, language-mode and profile values preserve wire names;
  unknown manifest states are rejected and surfaced. Manifest enumeration and
  decoding run in a background actor, with cancellable refresh and generation IDs.
- #3: playback loading and timeline assembly are outside the view. An owned load
  task and generation ID prevent playback after stop, window close or a newer
  selection. Active capture stops playback. Parts are checked before assembly.
- #9: release defaults no longer embed developer checkout/model paths. Explicit
  paths are retained; tool discovery and applying discovered paths are separate
  actions. WAV cap input rejects non-finite/out-of-range numbers. Storage bounds
  are shared with processing, and settings cards use the existing Glass tokens.
- Menubar overflow now exposes Settings and Recordings, Transcription & Summary.
  The recorder and recording library also provide direct navigation.

## Verification at this checkpoint

- Python: 38 tests pass, including common WAV/session phases and cancellation
  during completion, deterministic rendering, source-linked AI output and raw
  evidence preservation. No model download or external AI request was made.
- Swift: full Release unit-test target passes, including new PCM recovery,
  process runner and feature lifecycle regression tests.
- Build and test logs remain local under `Build/cleanup-*.log`.

## Remaining follow-up (keep tickets open unless explicitly completed)

- #4: add a sparse multi-GiB recovery fixture and real disk-exhaustion integration
  coverage; current tests inject copy failure and verify the original survives.
- #7: validate descendant-process behaviour for each installer and diagnose launch
  failures/log-retention failure paths; the runner deliberately never kills
  arbitrary descendants or unrelated processes.
- #2/#6: expand restart/archive-cancellation aggregate-state tests and controlled
  stale-read/large-library tests. Review the remaining installer filesystem I/O.
- #3: expand delayed multiple-selection, missing-part and continuous-timeline
  playback integration coverage; the stop-during-load regression is covered.
- #9: expand nested per-field storage preference migration (a malformed nested
  object currently falls back as a unit), invalid enum messaging and manual
  settings accessibility/layout coverage. Installation remains explicit opt-in.

No original recording, existing stash, signing identity or Apple account resource
was deleted or replaced. This checkpoint is not a claim that every acceptance
criterion of every open ticket has been completed.
