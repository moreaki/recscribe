# Optional cloud live transcription

Tracking: [#11](https://github.com/moreaki/recscribe/issues/11). Swift-first migration: [#10](https://github.com/moreaki/recscribe/issues/10).

## Responsibilities and explicit choices

Recording, admission limits, PCM/WAV writing, rollover, recovery and playback remain local. The recorder does not call a network API. A separate utility-priority worker reads complete frames already written to disk, using the same validated part reader as local live recognition.

Settings → Transcription offers:

| Location | Speech recognition | Optional text processing |
| --- | --- | --- |
| Local (default) | Local whisper.cpp | Local Ollama only |
| Hybrid | Local whisper.cpp | Ollama, or separately approved OpenAI text |
| Cloud | Separately approved OpenAI live audio | Ollama, or separately approved OpenAI text |

Existing explicit OpenAI text preferences migrate to Hybrid. Invalid location preferences fall back to Local with a migration warning. Selecting Cloud, saving a key, or arming the live switch does **not** upload audio. A recording must be active and the user must approve the source and model. Each activation samples a new complete-frame boundary; previously written audio is not replayed. Deactivation, changing location/model, a new recording, cancellation or failure invalidates this approval. Capture continues independently. The key is read from RecScribe's own Data Protection Keychain only after approval and is never persisted in job artifacts, command arguments, or logs.

This first implementation supports live session audio, not automatic uploads of completed recordings or imports. In Cloud mode, automatic local re-transcription is suppressed; explicit full-recording local recognition requires selecting Local or Hybrid. There is no fallback in either direction.

## Native adapter and latency tradeoff

`RealtimeTranscriber` in RecScribeCore owns the injectable transport contract. `CloudTranscriptionWorker` owns native preparation and source boundaries; `LiveTranscription` owns UI state/consent/cancellation; SwiftUI presents settings and actions only.

The requested model is `gpt-realtime-whisper`, separate from the summary/text model. The adapter uses a transcription session, 24-kHz mono signed little-endian PCM16, manual turn commits, and bounded append packets. It waits for the server to confirm the model, transcription session, format and manual-commit configuration before sending audio. No redirects, stored cookies, proxy credentials, automatic retries or reconnect replay are allowed.

For a deliberately bounded first version, **each channel/window uses a separate connection**. User-selected windows are 10, 20 or 30 seconds. Conversion reads limited buffers; at most one mono window and one channel request are in flight. Distinct channels are never mixed; identical channels also remain separate (and can therefore incur additional usage charges). The UI displays deltas while the provider handles the window; the completed item replaces them. Commit acknowledgements and completion events are correlated by item ID even when their arrival order differs. Duplicate event IDs do not duplicate text. Raw events, including duplicates/failures, remain private local evidence.

This is chunk-delayed live transcription, **not sample-by-sample streaming**. First text latency includes waiting for a window, conversion, connection setup and provider latency. It has no cross-window language/context continuity or verified word alignment. The model runs in the cloud, so no local model weights are loaded. A future persistent connection/continuous converter should be justified by latency/RAM measurements, not assumed faster. No claim of improved accuracy or comparative ASR speed has been made from mocked tests.

`RealtimePolicy` and `LiveTranscriptionPolicy` centralize wire/resource limits. A bounded event count, response bytes, preview characters, timeout and maximum lag prevent unbounded buffering. Excessive lag stops optional cloud work instead of replaying a large backlog. Audio shorter than the API's minimum turn is not fabricated or padded into speech; it is explicitly reviewable in turn metrics. Frame windows are disjoint; resampling happens independently per window and may affect boundary recognition.

## Artifacts, traceability and compatibility

A new private `Live/<UUID>` job is created per activation. Successful finalization produces:

- `manifest.json`, `consent.json`, `source-session.snapshot.json`, `audio-report.json`;
- per-turn `result.json`, per-channel immutable raw `.events.jsonl`, `timings.json`;
- `transcript.raw.json` linking raw turn evidence;
- canonical `transcript.json`, deterministic TXT, Markdown, SRT, VTT and `review.md`.

Canonical **1.0 remains unchanged** for existing local/Python jobs. **1.1** adds explicit cloud-audio consent and truthful engine provenance: `local_only: false`, no invented model-weight digest (`model_sha256: null`), and source-linked absolute session times. The source digest is explicitly the saved session snapshot digest, not a made-up aggregate WAV hash; each part has its own SHA-256. Acoustic metrics are absent, not zero-filled. Source audio and the recording manifest are never modified by cloud transcription.

Turn bounds are **estimated transcript timestamps**, not aligned word timestamps. Speaker identity, language detection, dialect fidelity and confidence are not inferred from the channel or input-language hint. Every cloud result requires review. Audio before approval is an explicit uncovered interval. Empty responses, short tails, silence, boundary words and interruptions require review; no missing speech is synthesized. Interrupted jobs retain raw evidence and completed turns with a terminal state, rather than publishing an apparently complete transcript.

The Swift reader, validator, renderer and native text jobs support both versions. Later Ollama/OpenAI text derivatives retain the original cloud-audio provenance even if the text step itself runs locally. Python remains the reference for 1.0 local audio jobs and deliberately does not accept 1.1 cloud input. A successful cloud job appears directly in Transcript; Improve text and Generate summary remain independent actions with their existing source-linked derivations and separate cloud-text consent.

## Measurements and validation

Per turn: source start/end/available frames, model, channels, total preparation/request duration; per channel: uploaded PCM bytes, request duration and first-delta latency. Unified logs contain operation IDs, numeric boundaries/counts and elapsed time, never transcript content, raw provider bodies or keys. Raw local artifacts are sensitive user data, not telemetry uploads.

Automated tests use synthetic PCM and scripted sockets only: consent/model/format preflight, preference migration, cancellation, timeout, malformed/oversized responses, duplicate and out-of-order events, channel preservation, sample boundaries across WAV rollover, canonical validation and deterministic exports. Existing recorder, native text and Python reference tests are regression gates.

An actual paid account/network smoke test and speech-quality/latency comparison remain opt-in. Do not upload a user's private recording merely to validate this adapter. Before recommending cloud operation, verify account model access, expected usage charges, network behavior and source/recognition quality with an explicitly approved fixture. Prices and retention periods are not baked into app code.

## Official references (checked 2026-09-09)

- [Requested model](https://developers.openai.com/api/docs/models/gpt-realtime-whisper)
- [Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [Legacy-model migration example](https://developers.openai.com/cookbook/examples/migrating_from_whisper_to_gpt_transcribe#5-migrate-continuous-live-transcription)
- [WebSocket transport](https://developers.openai.com/api/docs/guides/realtime-websocket)
- [Commit acknowledgement and item IDs](https://developers.openai.com/api/reference/resources/realtime/server-events#input_audio_buffer.committed)
- [Pricing](https://developers.openai.com/api/docs/pricing) and [data controls](https://developers.openai.com/api/docs/guides/your-data)

Current documentation also recommends newer transcription models. This implementation deliberately does not silently substitute one for the requested model.

## Local validation, 2026-09-09

- Release Swift Core: 23 tests passed, including unchanged Python 1.0 schema/semantic validation and byte-for-byte export parity, plus native text derivation of a 1.1 cloud source.
- Release app: 387 tests in 56 suites passed. Synthetic network failure leaves the recorder writable/finalizable; the cloud worker never retries or invokes local ASR.
- Python reference: 46 tests passed.
- `scripts/build-app.sh`: signed local version 0.2.5 (205); Mach-O 64-bit arm64; Swift 6 / complete strict concurrency; hardened runtime; bundle `com.moreaki.recscribe`; team `CDS4KLP8GT`; own Keychain access group; no `get-task-allow`.
- Signing uses the existing **Apple Development** identity. Signature verification passes. This is a local development release, **not a notarized Developer ID distribution**; the distribution audit correctly rejects that identity.
- No real paid OpenAI audio request, private recording upload, new model download, or account mutation was performed for testing. Account acceptance and acoustic quality/performance remain unverified.
