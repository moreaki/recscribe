# Local engine benchmarks

The checked-in corpus manifest is a preparation template, not measured accuracy.
It covers Swiss German, Standard German, English, noise-only audio and multiple
speakers. Fill a private copy with local WAV paths, reference TXT paths, audio
SHA-256, license/consent evidence and speaker count. Paths resolve relative to the
manifest. Nothing is downloaded. Keep actual recordings, references and results
under ignored `benchmarks/audio/`, `benchmarks/results/` or outside the repository.
Synthetic unit tests need no licensed audio download and are not an ASR benchmark.

```sh
pipeline/.venv/bin/python -m recscribe.benchmark \
  benchmarks/manifests/corpus.template.json --dry-run \
  --output benchmarks/results/readiness

pipeline/.venv/bin/python -m recscribe.benchmark /path/to/private-corpus.json \
  --whisper-cli /path/to/whisper-cli --model /path/to/ggml-model.bin \
  --output benchmarks/results/whisper-small-run-1
```

Missing corpus entries are `pending_corpus`, never zero error. The runner produces
canonical jobs and records WER, CER, wall time, real-time factor and peak RSS bytes
using macOS `/usr/bin/time -l`. RSS is a maximum process high-water mark including
child accounting, not the sum of simultaneous Python/FFmpeg/Metal allocations.
Unified GPU memory and model-load phase require separate instrumentation later.
Wall time includes inspection, model load, inference, validation and rendering.
Engine-pass duration is also recorded. Run each case in a fresh subprocess.

WER/CER normalization is explicitly versioned in results: Unicode NFC, casefold,
punctuation converted to spaces, repeated whitespace collapsed. CER omits spaces.
Preserve original references, including dialect spelling. For empty references,
WER/CER are null and false-speech word count measures hallucination on silence or
noise. Rates may exceed 1 for many insertions. Do not compare a Standard German
reference to Swiss German verbatim ASR and call the difference a recognition error.
Have a human score normalization/translation for names, numbers, negation and
semantic preservation independently from ASR WER.

Use a manually corrected, single interleaved reference for mixed-speaker audio.
Independent channel capture needs channel-specific references and overlap-aware
evaluation before reporting speaker accuracy. The current scorer does not compute
DER, timestamp deviation or semantic accuracy; these remain null/unmeasured, not
implied by transcript WER. Add ground-truth word times and anonymous speaker turns
before implementing those metrics.

Compare three repeats, report median and range, and separate cold model load from
warm runs. Record Mac model, memory, power mode, OS, engine version, model checksum,
quantization and decoding options. Do not benchmark during active recording or
while other heavy jobs compete for memory. Keep exact source files and mode the
same across adapters. Require human review before drawing quality conclusions.

| Engine | Execution integration | Comparable output contract |
| --- | --- | --- |
| whisper.cpp | Implemented local CLI reference adapter | Canonical schema 1.0, raw bytes and provenance |
| WhisperKit | Planned Swift/Core ML adapter | Same TranscriptEngine times, cancellation, raw evidence and canonical schema |
| MLX-Whisper | Planned local Python worker adapter | Same contract; explicit local model path and no hub fallback |

The runner currently invokes whisper.cpp only. `recscribe.benchmark.accuracy` scores
canonical source text independently of the engine; future runners must retain the
same metrics and fixture IDs. No implementation of either planned engine is
claimed. Adapters are wrappers around upstream engines, never a new ASR engine.
