# Live transcription reliability — retained local changes

## Scope and review (2026-10-15)

Reviewed both preserved stashes against `5564d1e` on `main`. Neither stash was
applied wholesale or deleted. Original recordings, saved ASR output and previous
transcripts are read-only diagnostic inputs, not test fixtures or repository data.

| Stashed change | Decision |
| --- | --- |
| Non-speech marker parsing and regression fixtures | Integrate with strict speech/timestamp validation. |
| Retry every local failure once | Narrow to explicitly classified malformed Whisper output. Never retry cancellation, disk/source/tool/configuration errors or cloud requests. |
| Trim and normalize explicit live language arguments | Integrate; test regional, uppercase, whitespace and automatic choices. |
| Freeze automatic language after three agreeing chunks | Do not integrate: it would suppress later language switches and apply one channel's language to another. |
| Ban Tiny through catalog, Swift preflight and Python CLI | Do not integrate: model name/file size is not a reliable model identity or quality assessment. Existing model choices remain usable. |
| Related Tiny-ban tests and documentation | Omit with the ban; keep existing model verification and dependency detection intact. |
| Old Xcode signing stash | Already represented by the current team/bundle settings; no rollback or signing-account changes. |

## Parser and error policy

- Only complete known markers (`[BLANK_AUDIO]`, `[SILENCE]`, `[NO_SPEECH]`,
  case-insensitive) and whitespace-only output are skipped. A marker embedded in
  speech is not removed. Marker-only chunks are successful empty results, not
  proof of digital silence; `asrRuns` continues to distinguish those cases.
- Negative or reversed offsets fail even on markers. Zero-duration speech,
  speech whose start moves backwards, and speech beginning beyond the audio
  window fail explicitly. Context-only speech is still excluded, and straddling
  segments retain the existing clipping/review semantics. No times are invented.
- Malformed JSON and invalid speech timestamps use a dedicated error type. Only
  this type permits one local retry (`maximumLocalChunkAttempts = 2`).
- Each attempt retains any raw output it produced. A failed chunk cannot move the
  committed cursor or replace earlier successful preview text. A successful
  retry writes the usual checkpoint; another failure stops optional live work
  visibly, without advancing past a missing interval. Re-enabling retries from
  that same cursor. Recording is independent and continues.
- Retry and stop logs include operation ID, cursor and attempt count; retry logs
  include elapsed time. Existing process/chunk logs retain inference timings.
  No recognized speech is added to application logs.

## Read-only historical evidence

The reported recording's saved outputs contain two zero-duration `[BLANK_AUDIO]`
markers and no zero-duration speech. Language labels across the raw files are
50 German, 14 English, 2 Japanese and 2 Korean. Those are recognizer guesses,
not established spoken-language ground truth.

Streaming analysis of that recording (25 min 41.6 s, 48 kHz stereo PCM16) found
23.72% sample-exact equality and whole-file Pearson correlation of 0.96515. Of
155 ten-second windows (including the final partial window), only 5 are exactly
identical. Strong correlation does **not** prove interchangeable channels or
distinguish shared content from crosstalk. No approximate channel merge is added;
the existing sample-exact optimization stays conservative. Equal transcript text
does not cause channel deletion.

## Language and model decisions

Explicit selection is forwarded as a base language code to whisper.cpp. `auto`
continues detecting separately for each chunk/channel, preserving potential
language switches. Settings clarify where an explicit source language is chosen.
No majority-vote lock or quality guarantee is introduced without language-labelled
evaluation audio. The saved Tiny results motivate investigation, not a filename-
or byte-count-based prohibition of a model family.

## Regression coverage

Synthetic tests cover valid speech plus the exact terminal marker shape, marker-
only results, empty text, malformed JSON, negative/reversed/zero/out-of-window
speech times, backwards speech order, unknown markers, whitespace/region language
arguments, mixed-language chunks, sample-distinct stereo, and equal text on
different channels. Worker tests cover bounded retries, unchanged committed
cursor and earlier text, manual resumption, recovered empty chunks, cancellation,
and immediate stop for non-retryable source errors. Existing capture, cloud,
pipeline, export and core tests remain part of the verification run.

No private audio is sent to any service, no models are downloaded, and no
historical transcripts are rewritten. Real multilingual/dialect accuracy and
crosstalk attribution remain unverified; these changes fix control-flow and
parsing correctness rather than claim recognition-quality improvements.

## Verification

- Targeted live suite: 24 tests passed, including parameterized invalid-output
  and language cases (`Build/live-fix-targeted-tests.log`).
- Full macOS app suite: successful run of 468 tests / 71 suites in 61.606 seconds;
  the opt-in signed Keychain round-trip was skipped (467 passed, 1 skipped;
  `Build/live-fix-all-app-tests.log`).
- Native core: 31 tests / 5 suites passed, including Python-reference schema and
  byte-for-byte export parity (`Build/live-fix-core-tests.log`).
- Python pipeline: 54 tests passed (`Build/live-fix-python-tests.log`).
- Real local whisper.cpp/Base smoke test used only synthesized speech and the
  already installed model. The first 10-second chunk took 12.54 seconds; the
  subsequent tail took 0.96 seconds. These are smoke-test measurements on this
  machine during the test run, not a benchmark improvement or real-time promise.

The installed release is version 0.2.9 (209). Signing team, bundle ID and Keychain
group are unchanged. The local development-signed release is not notarized;
previous app bundles and both original stashes remain recoverable.

`codesign --verify --deep --strict` passes. The arm64 executable uses hardened
runtime, team `CDS4KLP8GT`, bundle `com.moreaki.recscribe`, and the unchanged
`CDS4KLP8GT.com.moreaki.recscribe` Keychain group without `get-task-allow`.
The Developer ID distribution audit correctly rejects the existing Apple
Development authority; this is a local build, not a notarized distribution.
Executable SHA-256: `90925e2a49aef19dbd87b3a3397801450b3354c84470d2f0e23dc9de31ebd458`.
