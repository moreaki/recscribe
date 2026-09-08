# RecScribe: Architecture Notes

Status: Architecture and staged implementation; see [WAV slice](wav-vertical-slice.md) for implemented capabilities
Date: 2026-09-05  
Base project: [Home Rec](https://github.com/melissa-pereira-deel/home-rec)

## 1. Purpose

RecScribe extends Home Rec from a reliable macOS recorder into a
local-first recording and transcription system. It should turn an audio file into
an auditable, high-quality transcript that can be read by people and processed by
other software.

The first supported input is WAV. The architecture must allow additional formats
through FFmpeg without changing the transcription core.

The intended workflow is:

```text
capture or import
  -> inspect
  -> normalize
  -> detect speech
  -> transcribe
  -> align and identify speakers
  -> normalize or translate language
  -> validate
  -> render outputs
```

## 2. Product principles

1. **Local first.** Audio and transcripts stay on the Mac by default. Network
   access is limited to explicit dependency and model downloads unless the user
   selects a cloud-backed post-processing provider.
2. **Preserve evidence.** Raw ASR output is immutable. Cleaned and translated
   variants are derived artifacts and remain traceable to source segments.
3. **Do not invent speech.** Silence, low-confidence decoding and disagreement
   between passes must produce review markers, not plausible filler.
4. **Optimize for Apple Silicon.** Metal, Core ML and MLX implementations are
   benchmark candidates. Engine selection is an implementation detail behind a
   stable interface.
5. **Structured before pretty.** Versioned JSON is the canonical result. Text,
   Markdown, SRT and VTT are deterministic renderings of that result.
6. **Capture must remain reliable.** Transcription work must never block,
   destabilize or corrupt an active recording.

## 3. Why Home Rec is the foundation

Home Rec already solves the most fragile macOS concerns:

- native system-audio and microphone capture with ScreenCaptureKit;
- a canonical audio format and lossless WAV output;
- crash- and quit-safe WAV finalization and recovery;
- stream-failure recovery, permissions and disk-space guardrails;
- a SwiftUI application, menu-bar workflow, diagnostics and tests.

These behaviours are retained. The authoritative verification, transformation
and summary pipeline begins after finalization or import. As of the opt-in live
extension (2026-09-08), a separate utility worker can read complete, already
written PCM chunks during capture and display an explicitly unverified draft.
It never runs in the capture callback or alters originals. See
[Recording Studio and live drafts](recording-studio.md) for lifecycle, limits
and the distinction between preview evidence and canonical transcripts.

Home Rec is licensed under Apache License 2.0. Its copyright and NOTICE content
must be retained. Modified upstream files must carry appropriate change notices.

## 4. Proposed system boundary

```text
+------------------- Capture plane: existing RecScribe -------------------+
| SwiftUI UI -> RecordingController -> AudioRecorder -> PCM/WAV parts    |
+----------------------------------+---------------------------------------+
                                   | finalized-file event / import
                                   v
+----------------------- Processing control plane ------------------------+
| JobStore -> PipelineCoordinator -> progress/cancellation -> diagnostics |
+------------------+----------------+------------------+------------------+
                   |                |                  |
                   v                v                  v
            AudioInspector    TranscriptEngine   LanguageProcessor
            FFmpeg/VAD        adapter            adapter
                   |                |                  |
                   +----------------+------------------+
                                    v
                           Canonical transcript JSON
                                    |
                    +---------------+---------------+
                    v               v               v
                 Markdown        SRT/VTT          plain text
```

Capture and processing are separate failure domains. A failed or cancelled
transcription must leave the original recording and any completed artifacts
intact.

## 5. Repository evolution

The first iterations should preserve the existing application and add a
standalone pipeline before integrating it into the UI:

```text
RecScribe/                       existing native recorder
pipeline/
  pyproject.toml                 Python orchestration package
  src/recscribe/
    audio/                       inspection, conversion and VAD
    engines/                     ASR backend adapters
    language/                    cleanup and translation adapters
    quality/                     disagreement and review logic
    renderers/                   JSON, Markdown, TXT, SRT and VTT
    cli.py                       stable command-line interface
schemas/
  transcript.schema.json         canonical output contract
benchmarks/
  README.md                      reproducible benchmark protocol
  manifests/                     fixture metadata; no private audio committed
skills/
  recscribe/                     thin Codex skill invoking the CLI
docs/
  transcription-architecture.md  this document
```

Python is proposed for the orchestration layer because it makes backend
experimentation and structured output easy. The stable boundary is the JSON
schema and CLI, not the Python implementation. A later native worker can replace
it without changing callers.

## 6. Engine strategy

Do not implement speech recognition. Provide a `TranscriptEngine` adapter and
benchmark existing implementations on the target Mac Studio and representative
Swiss German recordings.

### Initial candidates

| Engine | Intended role | Notes |
| --- | --- | --- |
| `whisper.cpp` | Initial default and reference backend | Proven locally on Apple M2 Ultra; Metal acceleration; simple CLI; VAD support |
| WhisperKit | Native macOS candidate | Swift/Core ML integration; attractive for future in-app processing |
| `mlx-whisper` / `whispermlx` | Apple Silicon experiment | MLX acceleration; useful path to word alignment and diarization |
| WhisperX / `faster-whisper` | Future CUDA backend | Strong batching, alignment and diarization on Linux/NVIDIA |

No engine becomes the long-term default until it passes the benchmark and output
contract tests.

### Quality profiles

- `fast`: one `large-v3-turbo` pass, VAD enabled.
- `accurate`: one `large-v3` pass with conservative decoding.
- `verified`: fast pass plus accurate pass; retry only segments with low
  confidence, suspicious silence behaviour or material disagreement.

The verified profile avoids paying the cost of repeated decoding for segments
where both passes agree.

## 7. Audio handling

`AudioInspector` records source facts before any conversion:

- file hash, container, codec, duration and file size;
- sample rate, bit depth, channel count and channel layout;
- per-channel peak/RMS levels, clipping and long silences;
- whether stereo channels are independent, duplicated or near-duplicated.

The source file is never modified. A normalized working copy is generated as
16 kHz mono PCM only when required by the selected engine. Independent channels
must be preserved because they may represent local and remote speakers. Blindly
downmixing them would destroy useful speaker information.

VAD is used to reduce silence hallucinations and unnecessary inference. Segment
boundaries include configurable padding and overlap so words are not cut off.

## 8. Language model

The pipeline distinguishes three operations:

1. `verbatim`: retain the spoken language or dialect as recognized;
2. `normalize`: convert dialect or informal speech into a requested standard
   language without changing meaning;
3. `translate`: render the content in another target language.

Whisper transcription and arbitrary target-language translation are separate
stages. Whisper's translation task is not treated as a general translation
engine. For example, Swiss German to Standard German is a normalization stage,
not ASR language selection.

Each segment may therefore contain `source_text`, `normalized_text` and
`translated_text`. Derived text never replaces source text. A language processor
must preserve names, numbers, negation, commitments and uncertainty markers.

The first implementation may support a manually selected local or cloud text
processor. Provider use must be explicit in the job manifest so local-only jobs
cannot silently fall back to a network service.

## 9. Canonical result

The canonical JSON document is versioned and contains:

```json
{
  "schema_version": "1.0",
  "source": {
    "path": "recording.wav",
    "sha256": "...",
    "duration_ms": 1883200,
    "channels": 2
  },
  "processing": {
    "profile": "verified",
    "engine": "whisper.cpp",
    "model": "large-v3",
    "source_language": "de-CH",
    "target_language": "de",
    "local_only": true,
    "started_at": "...",
    "duration_ms": 95000
  },
  "segments": [
    {
      "id": "seg-000001",
      "start_ms": 0,
      "end_ms": 8140,
      "speaker": "SPEAKER_01",
      "source_text": "...",
      "normalized_text": "...",
      "translated_text": null,
      "confidence": 0.91,
      "needs_review": false,
      "review_reasons": [],
      "words": []
    }
  ]
}
```

The schema must additionally capture engine versions, model checksums, command
options and artifact hashes so a result can be reproduced and audited.

## 10. Rendered artifacts

Every job has its own output directory and may contain:

```text
manifest.json                 input and processing provenance
audio-report.json             technical audio analysis
transcript.raw.json           immutable engine output
transcript.json               canonical enriched transcript
transcript.verbatim.txt       source-language reading copy
transcript.cleaned.md         normalized reading copy with timestamps
transcript.srt                subtitle rendering
transcript.vtt                web subtitle rendering
review.md                     uncertain passages and nearby context
meeting-summary.md            optional topics, decisions and actions
```

Meeting summaries are downstream artifacts. They must reference segment IDs or
timestamps for decisions, commitments and action items.

## 11. Speaker handling

Speaker handling has three levels:

1. use independent capture channels when available;
2. optionally run diarization for mixed speech;
3. let a user assign real names to anonymous speaker labels after processing.

Diarization is probabilistic. Overlapping speech and poor recordings remain
reviewable conditions. Speaker names are never inferred from content unless the
user confirms them.

## 12. Reliability and job lifecycle

A transcription job moves through explicit states:

```text
queued -> inspecting -> preparing -> transcribing -> post-processing
       -> validating -> rendering -> completed
```

Terminal alternatives are `cancelled`, `failed` and `completed_with_review`.
Each stage writes atomically and can be resumed. Jobs retain logs but redact
audio content and secrets. Model downloads are checksummed and isolated from job
outputs.

The RecScribe UI receives progress and cancellation events. It must remain usable
while transcription runs, and active recording always has priority over model
inference.

## 13. CLI contract

Proposed initial command:

```bash
recscribe recording.wav \
  --source-language de-CH \
  --target-language de \
  --mode normalize \
  --profile verified \
  --diarize auto \
  --formats json,md,txt,srt,vtt \
  --local-only
```

Exit status is non-zero for processing failure, but reviewable uncertainty is a
successful `completed_with_review` result. Human-readable progress is written to
stderr; machine-readable results go to files or stdout when requested.

## 14. Benchmark and acceptance strategy

Performance without quality is not success. Establish a small, consented corpus
covering:

- Swiss German meetings;
- Standard German and English;
- quiet and noisy rooms;
- one and multiple speakers;
- duplicated stereo and independently captured channels;
- domain terms, names, numbers and acronyms.

Create manually corrected reference excerpts. Measure:

- word/character error rate on verbatim reference material;
- semantic preservation for dialect normalization and translation;
- timestamp deviation and speaker-attribution error;
- real-time factor, peak memory and model-load time;
- false speech emitted during known silence;
- number of segments requiring human review.

Baseline observed on an Apple M2 Ultra for a 31:23 WAV meeting:

| Profile pass | Wall time | Approximate throughput |
| --- | ---: | ---: |
| `large-v3-turbo` via `whisper.cpp`/Metal | 60 s | 31x real time |
| `large-v3` via `whisper.cpp`/Metal | 95 s | 20x real time |

These are provisional measurements from one recording, not general guarantees.

## 15. Security and privacy

- Default to `local_only: true`.
- Never include recordings, transcripts, prompts or model caches in Git.
- Record every network-capable provider in the manifest.
- Require an explicit provider selection before audio or transcript content can
  leave the machine.
- Store credentials only through macOS Keychain or process environment; never in
  project files, manifests or diagnostics.
- Preserve Home Rec's secret-scanning Git hook and diagnostics discipline.

## 16. Delivery plan

### Milestone 1: reproducible WAV CLI

- Inspect and normalize WAV without modifying the source.
- Run `whisper.cpp` with `fast`, `accurate` and `verified` profiles.
- Emit canonical JSON, raw text, Markdown, SRT and VTT.
- Produce audio and performance reports.
- Add deterministic tests for schemas, renderers and failure cases.

### Milestone 2: quality and language processing

- Add VAD-aware selective retries and review reasons.
- Add dialect normalization and arbitrary target-language translation.
- Add glossary and initial-prompt support.
- Create the benchmark corpus manifest and comparison runner.

### Milestone 3: speakers and RecScribe integration

- Benchmark WhisperKit, MLX and diarization options.
- Add anonymous speaker labels and post-hoc naming.
- Enqueue finalized RecScribe recordings and display job progress.
- Add import, transcript and review views to the native app.

### Milestone 4: reusable Codex skill

- Add a thin `recscribe` skill that checks dependencies, selects an
  appropriate profile and invokes the stable CLI.
- Keep transcription logic and output schemas in the application project.
- Validate the skill against representative user requests.

## 17. Open decisions

1. Resolved: the application is RecScribe (`com.moreaki.recscribe`);
   Home Rec remains the upstream attribution, not a product name or path.
2. Should the first release remain CLI-only for transcription, or expose an
   experimental UI immediately?
3. Which text processor is acceptable for local normalization and translation?
4. Is speaker diarization required for the first usable release?
5. Should model files be managed by the app, Homebrew or a dedicated installer?
6. Which recording and transcript data-retention policy should be the default?

## 18. Initial architecture decision

Proceed with RecScribe's capture foundation and implement an external,
schema-first transcription pipeline with `whisper.cpp` as the initial backend.
Keep the backend replaceable and select the long-term Apple Silicon engine only
after reproducible benchmarks. Integrate the pipeline into the native app after
the CLI, job lifecycle and canonical output contract are stable.
