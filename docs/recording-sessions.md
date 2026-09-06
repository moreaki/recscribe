# Recording sessions, settings and local processing

## Implemented boundaries

Capture always writes native 64-bit-process PCM16 WAV, regardless of archival
preferences. RIFF itself still has 32-bit sizes; `SessionWAVWriter` caps each file
at **3.5 GiB including its header**, or a smaller user-selected size. It splits
at whole interleaved frames, finalizes the old header, then exclusively creates
`Name-Part2.wav`, `Name-Part3.wav`, etc. An exact-cap stop creates no empty next
part. A colliding base/part/manifest chooses another session name; an unexpected
collision during capture stops safely without replacing the colliding file.

The existing 256-buffer / 4-MiB bounded admission queue remains authoritative.
Rollover does not allocate another audio buffer. Header finalization and the small
atomic journal update run on the serial encoding queue; expensive hashing and
conversion are deliberately deferred until capture ends. This conservative
scheduling protects capture ahead of faster background completion. Free-space
checks run before opening and at most one second of accepted audio apart.

`Name.recscribe.json` follows `schemas/recording-session.schema.json`. Paths are
local filenames, not arbitrary traversal/URLs. Parts contain absolute sample
offsets, frames, format inherited from the session, timestamp, status and (after
verification) SHA-256. A stable, exclusive sidecar lease prevents simultaneous
writing, recovery and archival despite atomic manifest replacement. Part intent
is journaled before opening the next file. Crash recovery stream-copies a part
in 1-MiB blocks, fixes RIFF sizes, discards incomplete frames and marks recovery
for review. Missing or changed parts never become silently successful audio.
Interrupted repair also requires the recorded file identity; an unconfirmed
opening intent or replacement file is left untouched rather than risking an
unrelated file. A late filename collision is removed from the recovery inventory.

Settings → Storage configures cap, archive format, bitrate/compression and save
location. WAV originals are **always retained** in this version. FLAC, Opus and
M4A are optional FFmpeg post-processing; no encoder runs on the capture callback.
FLAC must decode to the exact concatenated original PCM SHA-256. Lossy output
must fully decode and retain channel count and duration (150-ms codec allowance).
Sources are rehashed before/after conversion. Exclusive same-volume publication
prevents archive overwrites. No physical giant joined WAV is created.

File → Recordings & Import groups parts into one session, offers verification /
recovery, AVFoundation composition playback on absolute sample positions, export
of the complete manifest/parts/archives, and opt-in transcription. Export verifies
copied hashes before publishing its manifest. Incomplete exports retain their
files without a success manifest for inspection.

## Settings and local intelligence

The separate native settings window uses compact section navigation and grouped
cards, following Quantivane's hierarchy while keeping RecScribe's existing theme:
Storage, Transcription, Models, AI and Diagnostics. The recorder remains independent
of all optional dependencies. Settings are captured at job/capture start.

- Whisper detection checks explicit paths and Homebrew locations. Metal device
  availability and CLI backend detection are reported separately from evidence of
  actual inference acceleration; inspect each ASR log for the latter.
- Homebrew installation is an explicit confirmed action, without a shell command
  assembled from arbitrary input. It does not implicitly install models or start
  an Ollama service.
- Four official multilingual ggml models can be downloaded explicitly with displayed
  sizes, progress and cancellation. Exact size and published SHA-256 must match
  before selection. Custom local model selection is also supported. The model
  catalogue was checked against Hugging Face LFS metadata on 2026-09-06.
- The signed app bundles **source only**, not a Python runtime, environment or model.
  Explicit runtime setup creates an isolated environment using installed Python
  3.12+, then installs dependencies. The local checkout's existing environment can
  be used during development. No dependencies are downloaded on app launch.
- AI detection queries Ollama on numeric loopback only; no proxies/redirects or
  configurable remote URL. Models advertising a remote host/model, cloud-named
  models and unverifiable model metadata are rejected before transcript submission.
  No model is pulled implicitly.

The CLI accepts either WAV or a finalized/verified session manifest. It inspects
and hashes each part, processes valid parts separately, shifts segments/word times
to the whole-session timeline, and flags cut/duplicate risk near boundaries.
Missing/corrupt parts produce review reasons and gaps, never fabricated segments.
Stereo channels are compared for bit identity during streaming inspection but are
still processed independently: there is **no automatic mono downmix or speaker
identity inference**.

`--ollama-model NAME` explicitly enables local text processing. `verbatim` keeps
raw ASR, `normalize` derives standardized text (including de-CH → de), and
`translate` derives target-language text. `--summarize` generates bounded,
source-referenced summary notes in canonical JSON and Markdown. All generated
text remains unverified; source IDs, input/response files and hashes, model metadata,
token counts and elapsed time are retained. Invalid/missing references fail the
job. With no processor, normalize/translate remain visibly pending rather than
pretending the ASR output is an authoritative conversion.

Every job emits manifest, audio report, raw index, canonical JSON, verbatim TXT,
cleaned Markdown, SRT, VTT and review Markdown. Session jobs also retain child-job
evidence. Capture startup cancels background processing; automatic session work
requeues after capture, manual interrupted transcription retains its partial job.

## Timings and validation

Recorder bounded-buffer metrics/signposts remain unchanged. `SessionProcessing`
and `Runtime` unified logs add monotonic operation durations. Pipeline manifest
history contains elapsed stage times, while ASR and AI provenance record durations
and model identities. Never compare total job wall time with ASR-only timing.
No claim of MacStudio-equivalent performance is made for this M1 MacBook Air.
The size check uses conservative `statfs` available blocks rather than the slower
capacity-for-important-usage service. Synthetic paired benchmarks retain both
implementations as test-only options to make this overhead directly comparable.
The paired 2026-09-06 M1 Release run measured warm means of 87.99 ms with the
old capacity probe and 6.75 ms with `statfs` for a 10-second synthetic burst with
two 1-MiB-capped WAV parts (about 13× less orchestration time in this test).
Plain WAV without session bookkeeping measured 3.81 ms. All 100 buffers were
written without rejection. Raw samples are committed in
`benchmarks/recorder/session-rollover-m1.json`; full logs remain in
`Build/RecorderBenchmarks/sessions-paired-20260906`. These are not live capture
latencies and RSS values include the complete test host.

Tests use generated PCM only: tiny-cap rollover, exact byte sequence, headers,
part naming/collisions, low disk, leases, interrupted repair, missing parts,
all three real FFmpeg archives, continuous subtitle timing, local AI provenance,
cloud refusal and invalid source references. Model/network installation UI is
implemented but large downloads and real LLM semantic quality are not exercised
without a separately authorized local model.

### Local verification, 2026-09-06

- Release suite: 308 tests, 672 executions across two repetitions, zero failures
  (`Build/session-stable-tests.xcresult`). Test-only semaphore holds now outlast
  unrelated synchronous framework tests; production queue limits/timeouts did not
  change. Python: 36 tests passed (`Build/session-final-python.log`).
- `./scripts/build-app.sh` succeeded (`Build/session-delivery-release.log`).
  Native arm64/64-bit executable; Swift 6.0, strict concurrency complete,
  MainActor default isolation; Hardened Runtime present. Bundle
  `com.moreaki.recscribe`, team `CDS4KLP8GT`, valid Apple Development signature.
  Release no longer injects `get-task-allow`; the audio-input entitlement remains.
  This is a local development-signed Release, **not a notarized distribution**.
- Standalone launch, settings layout, Whisper/Metal detection and the recordings
  window were checked without Xcode. A 2-second generated tone was imported using
  the actual app. The local job completed with review, produced all required
  artifacts, and logged `whisper_backend_init_gpu: using MTL0 backend`. Total job
  wall time was 2.81 seconds with the pre-existing converted small model; this tiny
  smoke test is not an ASR accuracy or long-recording performance benchmark.
- No model weights were downloaded. Download publication was tested with tiny
  synthetic bytes for checksum, size, cancellation and collision protection.
  The real Ollama service is unavailable here; AI semantics remain unverified,
  while synthetic adapter/provenance tests pass. No cloud fallback was used.
- Existing private recordings and the pre-existing signing stash were retained.
  An existing unfinalized session was displayed for explicit recovery and was not
  modified during UI verification.

## Deliberately open

- Time-based splitting is reserved for later; size is authoritative now.
- No automatic deletion policy. Original removal requires a separate design and
  explicit consent even after archive verification.
- True per-language VAD segmentation, persistent concurrent transcriber workers,
  Swift-native normalization, WhisperKit and MLX adapters are not implemented by
  this slice. Auto language detection currently applies per part/channel ASR pass;
  it is not verified code-switch detection. No near-real-time claim is made.
- Summaries are bounded source-linked notes, not an independently fact-checked
  editorial document. No cloud provider integration is enabled.
- Active-capture multi-source routing remains tracked in GitHub issue #1.
- Power-loss durability depends on filesystem/hardware; atomic replacement and
  exclusive leases are not a guarantee against every disk failure. Validate long
  live recordings and unplug/ENOSPC fault injection before production rollout.

Sources: [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[official models](https://huggingface.co/ggerganov/whisper.cpp),
[Ollama API](https://docs.ollama.com/api/generate),
[Ollama remote-model fields](https://github.com/ollama/ollama/blob/main/api/types.go).
