# Swift-first migration

Tracking: [issue #10](https://github.com/moreaki/recscribe/issues/10).
Implementation date: 2026-09-09. The umbrella remains open until all four phases pass their acceptance gates.

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
  The latter creates a separate derivative after the reference ASR job completes.
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

The Swift export bytes are compatible with the current Python renderer, including
its escaping and review markers. JSON serialization whitespace is not required to
match, but canonical semantics and evidence hashes must remain valid.

## Native text CLI

Build with `swift build --package-path core -c release`. Run `--help` for all options.
This companion processes existing canonical JSON; the WAV command still belongs
to the reference pipeline until the audio migration passes parity.

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
RECSCRIBE_REFERENCE_PYTHON="$PWD/pipeline/.venv/bin/python" swift test --package-path core
pipeline/.venv/bin/python -m unittest discover -s pipeline/tests -q
```

The optional reference interpreter is used **only by tests** to run Python schema
and semantic validation on native synthetic jobs and compare all five exports
byte-for-byte. Normal `swift test` has no Python dependency. CI runs the native
core tests separately from app tests.

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

## Remaining gates (not claimed complete)

1. **Complete the common audio-job core.** Reuse the native WAV/channel inspection
   and conversion foundation for final processing; port adapter/job orchestration
   without changing capture. Compare synthetic PCM widths/rates, independent
   channels, split manifests, missing/corrupt parts, cancellation and timestamps
   against Python before switching the final-audio path. Keep Python available
   until the complete WAV pipeline has demonstrated parity, not just text jobs.
2. **Benchmark a persistent isolated ASR worker.** Compare current per-chunk CLI
   versus a resident helper on identical model/audio/settings. Measure cold load,
   warm latency p50/p95, real-time factor, peak/resident RAM, backlog, cancellation
   and recording queue metrics. Actors provide scheduling, not crash isolation;
   a native model assertion must not terminate recording.
3. **Decide from evidence.** The previous 346.2-second run for 643.74 seconds of
   stereo audio included two model passes per independently retained channel and
   concurrent builds/tests. It is not a clean benchmark or proof of a Swift speedup.
   Do not compare it directly with the separately reported M2 Ultra run.

No resident model/worker is enabled by this change. Avoid permanently spending
RAM before cold/warm measurements justify it; concurrency limits and unloading
policy must be explicit and yield to recording.

For a narrowly scoped text-core comparison, `benchmarks/compare-text-core.py`
alternates native/reference validated renders of the same canonical JSON,
checks byte equality, and reports per-run wall time and child peak RSS without
including transcript content or its file path. Build in Release and run on an
idle machine; these numbers exclude inference and are not evidence for a resident
ASR worker:

```sh
pipeline/.venv/bin/python benchmarks/compare-text-core.py transcript.json \
  --native core/.build/release/recscribe-text --runs 5
```

Measured after builds/tests finished, on the M1 Air with the existing 200-segment
transcript: median process wall time **52.5 ms Swift / 182.2 ms Python**; maximum
reported peak child RSS **11.4 MB / 44.1 MB** (decimal). Five alternating runs,
byte-identical exports. This includes startup, validation and disk writes, but
**no ASR or AI inference**. The content-free per-run report is retained locally at
`Build/swift-core-render-benchmark.json`; private transcript/export data is not
part of the repository.
