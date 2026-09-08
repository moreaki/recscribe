# Source-linked transcript and intelligence workflow (0.2.4)

## What the tabs mean

Live is a bounded, provisional chunk preview. It is never silently promoted to
the final transcript. Each pane identifies its source recording/session, duration
and available engine/language evidence, with playback and Finder actions. Starting
a new live session clears the previous selection; an unrelated old job is not
presented as the transcript of that new recording.

Transcript offers **Create final transcript / Transcribe again**, followed by
**Improve text**. Improve uses normalize by default, or translate when that mode
is explicitly selected in Settings. Summary offers **Generate summary**. Both text
actions create a new job from the selected canonical JSON without rerunning ASR.
Generating summary notes retains an existing normalized/translated rendition.
The last completed or explicitly opened transcript is remembered across launches.
Failures show the actual error and allow reopening the previous transcript.

Recording remains independent of intelligence. Starting recording cancels owned
background processing; neither credentials nor model availability can block
capture. Automatic final recognition cannot trigger a cloud text upload.

## Recognition failure and quality

Whisper recognition models and Silero VAD models both start with GGML magic, but
their layouts differ. Passing a recognition model to whisper.cpp's VAD loader
caused a native allocation assertion. The UI and CLI now check the bounded Silero
16-kHz header before starting native inference. The expected family/window/context/
encoder layout comes from [whisper.cpp's converter](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/models/convert-silero-vad-to-ggml.py),
not the filename. This is a family preflight, **not** tensor/checksum verification.
VAD can be explicitly cleared in Settings; no model is downloaded automatically.

Full-file inspection compares all channel samples. Bit-identical channels share
one ASR pass with explicit entries in the raw index; different channels remain
separate. Audio bytes, channel structure, hashes and original ASR text are kept.
Knowing the source language can help; larger models and full-recording context do
not guarantee correctness. Uncertain names/dialect words must be checked against
audio, not guessed into a fluent but unsupported reading rendition.

## Local and cloud providers

Audio recognition still requires pipeline 0.2.0 or newer. An existing isolated
Python environment does not change when the app updates. Set up the bundled
pipeline again in Settings → Transcription if the recognition preflight requests
it; old environments remain intact. AI discovery, connection testing, text
improvement/translation and summaries now run natively without Python. See the
[Swift-first migration](swift-first-migration.md) for the shared core and CLI.

- **Ollama** is the default provider. Explicit local model selection is required;
  loopback-only HTTP and remote-model refusal remain unchanged.
- **OpenAI** is opt-in. Settings holds provider/model preferences, not secrets.
  The app-private Data Protection Keychain service is
  `com.moreaki.recscribe.openai`, account `api-key`, non-synchronizing and
  `AfterFirstUnlockThisDeviceOnly`. Its access group is derived from the signed
  app identifier. Quantivane's credentials are neither read nor copied.
- **Test connection & load models** uses `GET /v1/models`. It sends credentials,
  not transcript data; model visibility alone does not prove Structured Outputs
  compatibility. Users choose a compatible text model or enter its ID. There is
  no hard-coded model recommendation, automatic install or billed inference test.
- Every cloud processing action snapshots source/model/mode and asks for explicit
  text-transfer consent. Only segment IDs, source text, uncertainty flags and
  language/mode instructions are sent. No audio, local paths, tools or attachments.
- Requests use the fixed TLS origin `api.openai.com`, Responses API Structured
  Outputs and `store:false`. No environment proxies, redirects, automatic retries
  or provider fallback. Refusal, incomplete output, invalid segment references,
  missing notes and HTTP errors fail visibly. Cancellation closes the connection;
  already submitted requests may still incur charges.
- `store:false` is **not** a zero-retention guarantee. OpenAI abuse-monitoring
  retention may apply. See [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
  and [API data controls](https://developers.openai.com/api/docs/guides/your-data).

## Evidence and boundaries

Native `TextJob` (or the reference Python `--derive`) creates an exclusive new job. `input-transcript.json` preserves the
parent canonical document; the manifest and raw index link its path/hash.
Existing raw ASR evidence stays in its parent job, avoiding copies of large audio
work files. Retain parent job directories when archiving/exporting derivatives.
Checksums, bounded inputs/responses, output-token limits, temperature policy,
request timeout and cancellation are defined at the adapter boundary.

Language derivations and summary notes retain source segment IDs, input/raw
hashes, processor/model identity, token counts where reported and elapsed time.
AI responses and prompts are private local artifacts; do not commit them.
The app passes its Keychain credential directly to the native client in memory;
the standalone text CLI reads an explicitly provided bounded stdin pipe. Keys
never enter CLI arguments, environment variables, manifests or diagnostic records. Unified logging retains
operation IDs/outcomes/timings, not transcript content or credentials.

`processing.local_only` describes the current job. Earlier cloud-derived text
can remain in a locally summarized document; the UI also inspects retained
language/summary provenance before labeling a result local. All generated text
remains unverified. Segment references show provenance, not proof that a summary
claim is correct. Large recordings produce bounded per-batch summary notes, not
a recursively synthesized global narrative. Persistent Whisper residency,
learned live VAD, word-level alignment and human quality scoring remain separate
follow-ups.

## Historical 0.2.2 acceptance, 2026-09-09

Current migration acceptance is recorded in [Swift-first migration](swift-first-migration.md).

- Synthetic Python suite: 46 tests, including model-family rejection, channel
  sharing, provider consent, fixed TLS origin, no retries/fallback, structured
  payloads, refusals/incomplete output, cancellation, bounded key input, raw
  immutability, source-linked derivations and retention of normalized text when
  summarizing. HTTP is mocked; no private data is sent to OpenAI.
- Real on-device test: a 28.1-second, 48-kHz stereo PCM recording with bit-identical
  channels; existing `large-v3-turbo`, explicit `de-CH`, no VAD model. One ASR pass
  took 6.11 seconds; job stages 7.62 seconds; whole CLI 8.13 seconds on the M1
  MacBook Air. Peak child RSS reported by `/usr/bin/time -l`: about 1.95 GB.
  Seven final segments, `completed_with_review`, all render formats emitted.
  This is a particular warm-machine timing, not a quality score or comparison
  against the M2 Ultra. Audio, transcript and logs remain outside version control.
- Native Release tests: **378 passed / 410 executions**, zero failures or skips,
  including the real, opt-in Data Protection Keychain save/read/update/remove
  test using a unique synthetic entry. Existing credentials were not touched.
  `Build/TestDerivedData/Logs/Test/Test-RecScribe-2026.09.09_00-13-08-+0200.xcresult`.
- Repeated all **46 Python tests against the newly installed, non-editable
  pipeline 0.2.0** as well as the checkout. No model download or cloud text
  inference was needed. The installed runtime can import the OpenAI adapter.
- `./scripts/build-app.sh`, signed Release **0.2.2 (202)**, native **arm64 / 64-bit**,
  bundle `com.moreaki.recscribe`, team `CDS4KLP8GT`, Swift 6 / complete concurrency
  checking, Hardened Runtime, strict codesign verification successful. With user
  approval Xcode provisioned RecScribe's own app identifier and Keychain group;
  the final entitlement is `CDS4KLP8GT.com.moreaki.recscribe`. No `get-task-allow`.
  Authority remains **Apple Development**, not Developer ID: this is the signed
  local build, **not a notarized public distribution**. The Developer-ID audit
  helper correctly rejects that authority; direct local integrity checks pass.
- Opened `Build/Products/Release/RecScribe.app` without Xcode. Verified actual WAV
  filename/duration/model/language, source playback and stop without a crash,
  populated Transcript, Generate summary, missing-AI configuration feedback,
  provider settings and restoration of the selected transcript after restart.
  The wrong optional VAD setting was explicitly cleared; its Whisper model file
  and the user's other settings remain intact. The user-installed new pipeline
  environment was retained and verified rather than replaced.
- Previous working app retained at
  `Build/PreviousRelease/RecScribe-0.2.1-before-intelligence-20260909.app`.
  Existing git stash and previous Python environments remain intact. No private
  recording, transcript, API key or model has been committed.
