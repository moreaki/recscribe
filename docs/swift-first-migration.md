# Swift-first migration

Tracking: [issue #10](https://github.com/moreaki/recscribe/issues/10).
Phases 1–2: 2026-09-09. Phase 3: 2026-11-02. Phase 4 is explicitly deferred
outside #10 closure; no custom signed XPC helper is introduced.

## Implemented: native final audio and Python-free shipping app

- `AudioJob`, `WAVAudio`, `NativeAudioPreparer` and `NativeWhisperEngine` now live
  in `RecScribeCore`. The app and `recscribe-text transcribe` share these exact
  implementations. WAV/session recognition needs only the app/Swift CLI,
  whisper-cli and selected local models. FFmpeg is optional for archive export.
- Inspection streams integer 8/16/24/32-bit PCM, exact channel metrics/equality,
  SHA-256 and bounded 30-second channel windows. More than 16,384 analysis windows
  fall back to full-channel recognition instead of retaining unbounded window
  metadata. Distinct channels are never deduplicated by text or correlation.
- AVAudioConverter prepares bounded 16-kHz mono channels, flushes its tail, checks
  working-WAV RIFF capacity/free space, and is also used by existing live drafts.
  whisper.cpp remains an isolated child process; configured thread count is passed
  to both primary and verification models. No engine weights are loaded in-app.
- Native jobs preserve canonical v1.0, nine output artifacts, exact raw JSON/logs,
  verified distinct-model comparison, decoder-padding provenance, channel-window
  indexes, session v1–v3 identities, part ordering and continuous timestamps.
  Missing/corrupt parts remain reviewable gaps. Untimed speech fails explicitly
  with raw words retained; canonical intervals are never fabricated.
- Job manifests are atomic and directories exclusive/private. Cancellation,
  source-mutation checks, failure evidence, priority/preemption and separate native
  AI text derivatives remain in place. CLI SIGINT/SIGTERM and `cancel.request`
  stop the owned process; process output and conversion buffers are bounded.
- Working-channel and region WAVs are disposable on **all terminal paths**.
  Preparation hashes/timings and region mappings remain in manifests/indexes;
  raw ASR JSON, version/process logs and canonical exports remain on disk.
  A failed cleanup is reported, rather than silently labelled successful.
- Python setup/detection/installer UI, `PipelineRuntime` and app-bundle
  `pipeline.tar.gz` packaging are removed. Legacy Python-path preferences are
  decoded for compatibility but never executed. No venv or pip setup ships.
- On 2026-11-03 the Python implementation/package/tests were retired after a
  successful independent reference capture. Sixteen synthetic cases are frozen
  in `core/Tests/RecScribeCoreTests/Fixtures/PythonReference`, with provenance and
  checksums. Every Swift test run compares inspection/canonical semantics and
  all five export bytes, without an optional interpreter environment variable.
  AVFoundation and FFmpeg resampling are not claimed byte-identical.
- The corpus runner/scorer is native (`recscribe-text benchmark`), retaining local
  readiness checks, hashes, WER/CER and per-case wall/RTF/RSS measurements. The
  Python-versus-Swift render benchmark was removed after the comparison ended.
  `scripts/benchmark-recorder.sh` remains native. The separate optional
  `scripts/verify-mic-rate.sh` keeps its standard-library Python tone diagnostic;
  it has no pipeline/package dependency and is not used by the app or tests.

```sh
swift build --package-path core -c release
core/.build/release/recscribe-text transcribe recording.wav \
  --output NEW_JOB --whisper-cli /path/to/whisper-cli --model /path/to/model.bin \
  --source-language de-CH --threads 2 --local-only
```

`--profile verified --verify-model /path/to/second.bin` enables the second pass.
Normalize/translate remain pending until a separate native text derivation runs;
they are not recognition-model translation flags. Diarization is still unavailable.

### Phase 3 acceptance — 2026-11-03

- Native core/CLI: 44 tests passed, with the optional Python reference enabled.
  Differential coverage includes 8/16/24/32-bit inspection, exact channel windows,
  distinct/silent channels, verified disagreement, session v1–v3 source identity,
  part boundaries, schema semantics and byte-identical text/subtitle exports.
  Missing parts, source changes, unsafe paths and cancellation are covered.
- Full Release app suite: 488 tests / 75 suites; 487 passed and the opt-in signed
  Keychain round-trip skipped. Python reference: 54 tests passed. Total: 585 passed,
  one skipped. Existing app/Core tests were retained; a wall-clock-dependent text
  test now gates first-batch completion on a real later result to avoid scheduling
  flakes under parallel audio/reference load.
- CLI integration executes native WAV and verified multipart jobs with a synthetic
  whisper executable, checks `--threads 3`, and verifies cleanup on success and
  cancellation. The app integration uses missing Python/FFmpeg paths deliberately.
- A real standalone native CLI/Base smoke test on generated speech completed in
  1.111 seconds of job time, retained four segments and all raw logs, removed every
  disposable WAV, preserved the source SHA-256, and produced byte-identical exports
  when re-rendered. The app's real native/Base smoke also passed. These are local
  functional checks, not recognition-quality or comparative speed benchmarks.
- Signed Release 0.3.0 (300): arm64/64-bit, Swift 6/complete checking, bundle
  `com.moreaki.recscribe`, team `CDS4KLP8GT`, Hardened Runtime and unchanged Keychain
  entitlements, without `get-task-allow`. Strict/deep codesign verification passed;
  `pipeline.tar.gz` is absent. Authority remains Apple Development, not a notarized
  Developer ID distribution. No model download or cloud inference was performed.
- Logs: `Build/swift-audio-{core,app,python}-tests.log`,
  `Build/swift-audio-release.log`. The real CLI fixture/artifacts are private local
  generated test data under `Build/NativeAudioSmoke-20261102-ASX57p`.

### Reference retirement acceptance — 2026-11-03

- Independent capture: 44 native tests passed against the then-present Python
  implementation before removal (`Build/python-reference-capture.log`). The 80
  frozen files retain their captured SHA-256 values, verified by a mandatory test.
- With the pipeline directory and obsolete reference venv removed: all 51
  core/CLI tests passed in both Debug and Release. Coverage includes all frozen semantic/export cases,
  benchmark edit counts/Unicode/noise, readiness without invented scores, native
  subprocess timing/RSS, checksum failure, exclusive output and cancellation
  without leaving the child alive (`Build/native-only-core-tests.log` and
  `Build/native-only-core-debug-tests.log`).
- Full Release app suite: 488 passed, zero failures, two signed-host checks skipped
  in the unsigned test configuration (microphone entitlement and the opt-in
  Keychain round trip). The initial hardened Release test-host invocation did not
  load XCTest and was stopped; the corrected unsigned test run passed. Result:
  `Build/python-removal-app-tests-retry.log` and its xcresult in `Build/DerivedData`.
- Signed incremental Release build passed in the isolated existing build-script
  check directory (`Build/python-removal-release.log`). Strict/deep codesign,
  arm64/64-bit, `com.moreaki.recscribe`, team `CDS4KLP8GT`, Hardened Runtime,
  microphone/Keychain entitlements and absence of `get-task-allow` verified.
  No Python archive or test fixtures are bundled. Apple Development signing is
  unchanged; this is not a notarized distribution. The running app was retained.
- Native corpus-template dry-run reports five `pending_corpus` entries, no scores;
  script syntax checks passed. Recorder baselines remain unchanged. No private
  source audio/results were modified, no model was downloaded and no inference
  request was sent to a provider. Obsolete ignored pipeline build/cache files and
  the no-longer-needed reference venv were moved to Trash rather than left as an
  accidentally usable second implementation in the checkout.

## Assessment and boundaries

Swift-first removes duplicated application orchestration and the separately
installed Python environment from native text actions. It does **not** make a
Whisper model's GPU inference faster merely by changing the calling language.
Keep proven engines/codecs behind adapters; do not write a new ASR engine.

Capture, WAV rollover/recovery and live recognition are unchanged. Post-processing
still runs outside capture callbacks, and starting recording or live work cancels
background text processing. Cloud text is a per-action, explicit choice, never a
fallback. This change does not introduce cloud audio or download models.

## Implemented: native intelligence and the shared text core

- `core/` is a dependency-free Swift 6.2 package shared by the SwiftUI app and
  `recscribe-text`. UI owns presentation/consent; the core owns networking, bounded
  batches, validation, immutable job artifacts and deterministic rendering.
- Native Ollama discovery verifies model metadata on numeric loopback and rejects
  remote models. Native OpenAI discovery uses the app-owned Keychain credential;
  known audio, realtime, embedding and image model families are excluded from text
  candidates. Model listing alone does not prove Structured Outputs support.
- OpenAI generation uses Responses with strict JSON Schema and `store:false`.
  Incomplete/refused responses fail visibly. This is not a zero-retention claim;
  provider abuse-monitoring retention can still apply.
- Connections use ephemeral URLSession instances without cookies/cache, proxy
  configuration or redirects. No application-level retry or fallback is added.
  Streaming response reads are bounded; cancellation interrupts URLSession work.
- User-selected models/languages stay in settings. Resource limits live in
  `IntelligencePolicy`; fixed service origins and allowed routes are explicit
  privacy boundaries. No personal model paths, API keys or endpoint overrides are
  embedded in the shared core.
- Both manual text actions and automatic local post-ASR processing use `TextJob`.
  The latter creates a separate derivative after the native ASR job completes.
- Canonical v1 validation covers the checked-in schema vocabulary **and** semantic
  invariants: chronology, channel bounds, review flags, explicit cloud consent,
  source-linked derived fields, summary references and repaired boundary timing.
  JSON extension data is retained, and integer/sample counters remain Int64.
- The bundled schema is a packaging copy of `schemas/transcript.schema.json`;
  a test requires byte equality. Unsupported schema vocabulary fails closed.
- Each new, exclusively created private job retains the parent transcript snapshot
  and hash, a raw-ASR parent reference, audio report, model metadata, batch inputs,
  raw provider responses, canonical JSON, TXT/Markdown/SRT/VTT and review notes.
  Original/parent files are never rewritten. Summary-only keeps the existing text
  rendition and resolves its provenance back to the parent job.
- Manifest history records stage timings; per-batch provenance records duration,
  token counts when supplied and hashes of prompt, model metadata and raw result.
  Unified logs record request/job IDs and elapsed time, not credentials or content.
  These elapsed times are diagnostic measurements, not ASR speedup claims.

The Swift export bytes are compatible with the frozen Python renderer outputs, including
its escaping and review markers. JSON serialization whitespace is not required to
match, but canonical semantics and evidence hashes must remain valid.

## Native text CLI

Build with `swift build --package-path core -c release`. Run `--help` for all options.
The same companion now supports `transcribe` for native WAV/session jobs as well
as `render` and `derive` for existing canonical JSON.

```sh
swift run --package-path core recscribe-text render transcript.json --output new-exports
swift run --package-path core recscribe-text derive transcript.json \
  --output new-job --provider ollama --model YOUR_INSTALLED_MODEL \
  --mode normalize --target-language de --summarize
```

Cloud jobs additionally require `--allow-cloud-text --key-stdin`. Supply the key
through stdin from a secure local source, never a command argument or checked-in
file. No cloud call is made merely by selecting a tab or building/testing.
Ctrl-C cancels processing and leaves a terminal job manifest plus partial evidence.

## Verification

```sh
swift test --package-path core -c release
xcodebuild test -project RecScribe/RecScribe.xcodeproj -scheme RecScribe -destination 'platform=macOS' -only-testing:RecScribeTests -parallel-testing-enabled NO
```

Reference tests are mandatory bundled fixtures, not a second implementation.
Their README records the original commit, synthetic inputs, normalization and
limitations. Missing files fail tests. Do not regenerate expected outputs with
the Swift implementation under test. Native schema/semantic corruption tests
remain independent of the golden comparisons. CI runs these alongside the
native audio/text/CLI tests, separately from app tests.

Local acceptance on the MacBook Air (M1):

- 382 app tests passed, including the signed Data Protection Keychain round trip
  and native connection/cancellation without Python.
- 17 native core tests passed in Release, with reference validation/export parity
  for normalization, translation, summary-only retention and approved mock cloud jobs.
- 46 Python reference tests passed.
- Native tests cover schema/semantic rejection, 64-bit JSON, original immutability,
  exclusive job creation, local-model verification, explicit consent, Responses
  payloads, malformed results, source references, URLSession size/status errors,
  cancellation, terminal manifests, artifact hashes and export parity.
- The pre-existing 200-segment transcript was read successfully by the native CLI;
  all five rendered files matched the reference byte-for-byte. No source content
  was sent to a provider and no private fixture was checked in.
- No live provider inference/quality comparison was run: contract tests use
  synthetic responses, not the user's OpenAI key or a newly downloaded model.
- Signed local Release 0.2.4 (204), arm64/64-bit, bundle `com.moreaki.recscribe`,
  team `CDS4KLP8GT`, Swift 6/complete checking and Hardened Runtime verified.
  Strict/deep codesign passed; Keychain entitlement remained unchanged and
  `get-task-allow` is absent. Authority is Apple Development, **not** Developer ID;
  the distribution audit correctly rejects it as a public release. No notarization
  or public upload was performed.
- Restarted `Build/Products/Release/RecScribe.app` after checking recording and
  processing were idle. Existing transcript selection and settings were retained;
  the Intelligence panel shows the native connection/text actions. No key was
  loaded and no provider request was triggered during the UI check. Previous app:
  `Build/PreviousRelease/RecScribe-0.2.3-before-swift-core-20260909.app`.

## Deferred work (outside #10 closure)

1. **Evaluate residency only if measured live latency warrants it.** Start with
   whisper.cpp's existing out-of-process `whisper-server` in a separate optional
   spike. A custom XPC daemon, idle-unloading manager and resident benchmark matrix
   are not prerequisites for Python removal. Keep the recorder isolated from ASR.
2. **Decide from evidence.** The previous 346.2-second run for 643.74 seconds of
   stereo audio included two model passes per independently retained channel and
   concurrent builds/tests. It is not a clean benchmark or proof of a Swift speedup.
   Do not compare it directly with the separately reported M2 Ultra run.

No resident model/worker is enabled by this change. Avoid permanently spending
RAM before cold/warm measurements justify it; concurrency limits and unloading
policy must be explicit and yield to recording.

The now-retired Python/Swift comparison alternated validated renders of the same
canonical JSON, checked byte equality, and measured process wall time/child peak
RSS. Its historical measurements below exclude inference and provide no evidence
for a resident ASR worker. Future corpus measurements use the native runner
documented in `benchmarks/README.md`.

Measured after builds/tests finished, on the M1 Air with the existing 200-segment
transcript: median process wall time **52.5 ms Swift / 182.2 ms Python**; maximum
reported peak child RSS **11.4 MB / 44.1 MB** (decimal). Five alternating runs,
byte-identical exports. This includes startup, validation and disk writes, but
**no ASR or AI inference**. The content-free per-run report is retained locally at
`Build/swift-core-render-benchmark.json`; private transcript/export data is not
part of the repository.
