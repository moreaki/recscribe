# Verification model preflight (0.2.3)

## Cause

The completed-recording pipeline was configured for two-model comparison with
the same primary and verification model. Its CLI correctly rejected the request
with exit code 2, but the app launched it without validation. The resulting
argparse usage text displaced the transcript and hid the useful error.

## Fix

- One shared Swift validation rule is used in Settings and immediately before
  transcription, including automatic post-recording jobs.
- A verified job needs a readable, regular verification-model file distinct from
  the primary file. Equivalent paths, symbolic links and hard links are rejected.
  The pipeline's existing checksum comparison remains responsible for detecting
  separate files containing identical model data; large files are not hashed on
  the UI thread.
- Invalid configuration does not replace the previous transcript/job selection
  and never silently falls back to a single recognition pass.
- Settings shows an actionable warning beside both model selections. Changing
  the profile to Single pass remains an explicit user choice.
- CLI usage failures show their actual error and diagnostic ID. Full bounded
  process output, duration, exit code and operation ID remain in private local
  diagnostics.
- During job startup, the progress monitor tolerates both Foundation missing-file
  error variants until the first manifest is published. A manifest disappearing
  after publication, malformed JSON and other failures remain visible.

No recording, live transcription, Python runtime, AI consent or canonical JSON
contracts change. No models are downloaded and no audio/text is uploaded.

## Regression checks

Swift tests cover duplicate/missing/directory model paths, symbolic links, hard
links, distinct model selection, explicit single-pass behavior, preservation of
the previous transcript on rejection, concise CLI errors with retained full
diagnostics, and missing-manifest handling before/after publication.

The local release retains the existing Apple Development identity, bundle ID
`com.moreaki.recscribe`, team `CDS4KLP8GT`, Data Protection Keychain group,
Swift 6 configuration and hardened runtime. It is a local development-signed
release, not a notarized Developer ID distribution.

## Local acceptance — 2026-09-09

- 380 Swift tests passed, including the signed Data Protection Keychain test;
  46 Python tests passed. Signed Release build and strict codesign verification
  passed; the resulting executable is arm64/64-bit.
- The installed app displayed the concise preflight warning without losing the
  previous transcript. Selecting the already-installed `ggml-small.bin` as the
  verifier cleared the Settings warning; `ggml-large-v3-turbo.bin` remained the
  primary model and the profile remained two-model comparison.
- Retrying the affected 643.74-second session from the app completed with review
  and no pipeline error. Both non-identical channels were preserved, producing
  four Metal-accelerated recognition passes and 200 canonical segments.
- Schema/semantic validation and every inventoried artifact checksum passed.
  The original WAV SHA-256 was unchanged. Transcript selection survived restart
  and the final app displayed it without the stale startup error.
- Total job time was 346.2 seconds on this MacBook Air. Builds/tests ran
  concurrently for part of that time, so this is functional acceptance evidence,
  not a clean performance benchmark.

Review still flags cross-channel duplicate speech, model disagreements, automatic
language detection and absent learned VAD. Normalization remains pending because
AI processing is disabled. This fix does not merge near-identical channels or
enable AI/cloud processing on the user's behalf.
