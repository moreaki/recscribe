# Native WAV/session transcription

The original v0.1 Python slice has been retired after freezing synthetic reference
outputs as Swift test fixtures. The app and native CLI use [RecScribeCore](swift-first-migration.md) for final
audio; local/cloud text post-processing remains a separate action.

Implemented locally on the MacBook Air, starting from `4d695ed`.
The native capture implementation remains unchanged. The pipeline starts from a
finalized WAV or a file selected for import; it does not attach to live capture.

## Run

Build the Swift CLI and supply a local whisper.cpp binary and model. No Python
or FFmpeg is needed for recognition; FFmpeg is optional for archive compression.

```sh
swift build --package-path core -c release
core/.build/release/recscribe-text transcribe recording.wav \
  --whisper-cli /absolute/path/to/whisper-cli \
  --model /absolute/path/to/ggml-model.bin \
  --source-language de-CH --target-language de --mode normalize \
  --profile fast --diarize auto --formats json,md,txt,srt,vtt \
  --local-only --output "$HOME/Library/Application Support/RecScribe/Jobs/example"
```

The output directory must be new. Its mode is 0700; CLI-created files are private
to the current account. Jobs and model files must remain outside version control.
The CLI does not install engines, fetch models, use a cloud provider or retry on
another service. `--local-only` is always true. The user supplies trusted local
executables. `.recscribe.json` input processes session parts without joining WAVs.

The command above performs ASR, but normalization remains **pending** until a
separate native `derive` action or the configured app text processor runs. It emits `completed_with_review`, with
null derived fields and a prominent notice in Markdown. The original ASR text is
never described as normalized or translated. `verbatim` preserves what the engine
recognized; Whisper may itself output Standard German for Swiss German, which
is flagged for dialect review. `translate` is a separate pending operation.

When the source language is known, specify it. whisper.cpp auto-detection can pick
the wrong language from a quiet/non-speech opening and then decode the rest under
that choice. Auto-detection is explicitly marked unverified; no automatic switch
or additional inference is silently performed. Repeated same-channel ASR phrases
and non-speech markers are review signals, never deleted or treated as confident
speech. The private full-file test exposed this limit: an explicit German language
request recognized speech where automatic detection had selected English.
The reference adapter disables previous-text context (`-mc 0`) to limit repetition
loops after silent openings. It retains upstream's local temperature fallback;
this is decoding within the same local model, not a network/provider fallback.
All exact options are recorded. ASR itself need not be byte-deterministic; exports
from one canonical result are.

`fast` and `accurate` each use the explicitly supplied model for one pass. They
do not infer quality from a filename, download a recommended model or guarantee
accuracy. `verified` requires `--verify-model /path/to/different-model.bin` and
runs a second complete pass per channel. Any text disagreement marks that
channel for review; neither pass overwrites the other. Selective segment retries
are future work. `--vad-model` enables whisper.cpp VAD using an existing model.
Without it only exact digital silence is skipped; noise is never assumed to be
speech or silence by the orchestrator. `--diarize auto` records that diarization
is unavailable and requires review; it does not invent speaker labels.

## Contract and artifacts

Each successful job emits the nine required files:

- `manifest.json`: lifecycle, configuration, normalizer identity, file hashes;
- `audio-report.json`: SHA-256, WAV facts and per-channel peak/RMS/clipping;
- `transcript.raw.json`: index of immutable, per-channel engine JSON files;
- `transcript.json`: validated canonical transcript, schema version 1.0;
- `transcript.verbatim.txt`: unchanged source text in canonical segment order;
- `transcript.cleaned.md`: reading view, with pending-processing/review markers;
- `transcript.srt` and `transcript.vtt`: deterministic millisecond cues;
- `review.md`: job and segment concerns with source text and timestamps.

Additional `asr-channel-N.json` and `verify-channel-N.json` files preserve exact
backend bytes. The raw index references them with SHA-256 and engine/model
provenance. Disposable working/channel-region WAVs are deleted on success, failure
or cancellation; preparation hashes and source mappings remain in manifests/raw
indexes. Local version/process logs stay in the job directory.
Logs may contain transcript content and local paths; do not commit or share them
without reviewing them. The manifest hashes all artifacts except itself and the
cancellation request, avoiding a circular self-hash.

`schemas/transcript.schema.json` is the source contract. The identical packaged
copy is included in the Swift core; tests enforce equality.
Runtime validation checks the JSON Schema plus unique IDs, chronological order,
channel bounds and timestamps within the source. Unsupported or malformed engine
output fails visibly rather than being silently repaired. One documented boundary
adjustment is allowed: a final cue whose start lies inside the source and whose
end extends at most one Whisper window (30 seconds) beyond it is trimmed to the
source duration. `timing_adjustment.original_end_ms` preserves the engine time;
the segment is flagged for review and exact raw JSON remains unchanged. Larger
overruns and wholly out-of-range cues fail validation.

The inspector streams integer PCM WAVs (8, 16, 24, 32 bit; 1–32 channels). Float
WAV, RF64 and compressed containers are currently unsupported and fail explicitly.
AVAudioConverter prepares a separate 16-kHz mono PCM16 working file for each recognized
channel. This preserves channel provenance, even for two independently captured
speakers. Sample-identical channels share recognition; differing stereo windows
are recognized with context. Text similarity/correlation never establishes
channel equality. Diarization remains unavailable. Simultaneous
channels can produce overlapping subtitle cues and are marked for review.
The source is hashed before inspection and again after inference; a changing
recording fails the job. Original audio is never written by the pipeline.

Exports are pure functions of canonical JSON. They escape Markdown/subtitle
markup and visibly mark reviewed cues. Text and segments in canonical/raw JSON
remain untouched. JSON provenance contains timestamps and measured runtimes, so
independent runs are not expected to produce byte-identical manifests.

## Lifecycle and cancellation

`queued → inspecting → preparing → transcribing → post-processing → validating
→ rendering → completed | completed_with_review`.

SIGINT, SIGTERM or a `cancel.request` file inside a running job requests
cancellation. The CLI exits 130, stops its owned ASR child and writes
the terminal manifest. Failures and invalid arguments exit 1. Reviewable
results exit 0 and explicitly report `completed_with_review`. The atomic JSON
manifest carries progress/history; unified logs contain operation IDs and timings,
and a final result locator goes to stdout.

Artifacts are atomically published. Failed/cancelled jobs retain already completed
artifacts, a terminal manifest and `review.md`; they cannot promise a full set of
transcript files. The manifest's state is authoritative even if cancellation
happens after some transcript views have been written. Never treat file existence
alone as successful completion. There is no automatic resume in v0.1: retry in a
new job directory. After SIGKILL/power loss, a nonterminal manifest means interrupted
work, not success. Future JobStore recovery must reconcile it.

Native CLI jobs run on utility workers and launch utility-priority child processes.
This does not limit Metal GPU usage or guarantee recording priority. UI integration must defer inference
while recording and cancel/requeue processing when capture starts (see integration
plan). Progress is stage-level, not a predicted percent of wall-clock time.

## Adapter boundary

`TranscriptEngine.transcribe` receives a local mono WAV, an exclusive output
prefix, ASR language and cancellation token. It returns unmodified raw-file
location, provenance, and segments with integer millisecond offsets. Missing
confidence, words or speaker attribution stays null/empty and is reviewable.
The canonical contract and benchmark scorer do not depend on whisper.cpp.

whisper.cpp is implemented against the upstream CLI's `-ojf`, `-of`, `-l`,
`--version`, `--vad` and `-vm` contract:
[upstream CLI](https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/cli.cpp).
The binary checksum, version output, exact arguments, model checksum and VAD
model checksum are recorded per pass. Swiss German maps to ASR code `de`, while
the requested source remains `de-CH`. The adapter never invokes `-tr`.

WhisperKit and MLX-Whisper are pending adapters, not aliases for whisper.cpp. Each
must pass the same output/cancellation/local-only contract tests before inclusion.
The benchmark metric layer accepts canonical JSON from any of these adapters.
No custom ASR model, decoder or engine is part of this project.

## Verification and remaining work

```sh
swift test --package-path core -c release
./scripts/build-app.sh
xcodebuild -project RecScribe/RecScribe.xcodeproj -scheme RecScribe \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build/TestDerivedData -only-testing:RecScribeTests test
```

Tests synthesize tones/silence in temporary directories; no private audio is
included. Frozen synthetic Python reference outputs check canonical semantics and
all five exports without Python or FFmpeg. Test-only adapters are clearly labeled and not exposed in the CLI.
Their transcripts validate orchestration, not speech-recognition accuracy.
The signed local build uses Apple Development, team `CDS4KLP8GT`, Swift 6 with
complete strict concurrency and Hardened Runtime. It is not a notarized Developer
ID distribution. No signing settings were changed for the pipeline.

Open work: real local-model accuracy smoke test; curated licensed benchmark audio;
learned VAD evaluation; segment retries/alignment; diarization and overlap handling;
robust restart recovery; processing resource limits; engine distribution.
Native normalization/translation with source-linked derivations is available as
a separate text action.
