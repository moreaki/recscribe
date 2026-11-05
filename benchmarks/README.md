# Local engine benchmarks

The checked-in corpus manifest is a preparation template, not measured accuracy.
It covers Swiss German, German, French, Italian, English, Arabic, Chinese, Spanish
and Portuguese, plus pending adverse-condition/non-speech cases. Swiss German
speech targets faithful written Standard German; optional dialect spelling is a
separate task. Fill a private
copy with local WAV/reference paths, both SHA-256s, reviewed license/consent and
coverage/grouping metadata. Paths resolve relative to the
manifest. Nothing is downloaded. Keep actual recordings, references and results
outside the checkout, for example under `~/Library/Application Support/RecScribe/Benchmarks/`.
These are preserved evaluation evidence, not disposable developer output.
Synthetic unit tests need no licensed audio download and are not an ASR benchmark.

```sh
python3 scripts/work-artifacts.py run --label corpus-build test -- \
  swift build --package-path core -c release
core/.build/release/recscribe-text benchmark \
  benchmarks/manifests/corpus.template.json --dry-run \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/readiness"

core/.build/release/recscribe-text benchmark /path/to/private-corpus.json \
  --whisper-cli /path/to/whisper-cli --model /path/to/ggml-model.bin \
  --threads 2 --output "$HOME/Library/Application Support/RecScribe/Benchmarks/whisper-small-run-1"
```

Missing corpus entries are `pending_corpus`, never zero error. The runner produces
canonical jobs and records WER, CER, wall time, real-time factor and peak RSS bytes
using macOS `/usr/bin/time -l`. RSS is a maximum process high-water mark including
child accounting, not the sum of simultaneous Swift/whisper.cpp/Metal allocations.
Unified GPU memory and first-result latency remain unmeasured. Supported upstream
model-load timers are reported separately with their scope and retained logs.
Wall time includes inspection, model load, inference, validation and rendering.
Engine-pass duration is also recorded. Run each case in a fresh subprocess.

Legacy WER/CER normalization remains versioned in results as
`swift-nfc-casefold-alphanumeric-v1`: Unicode NFC, Foundation case folding with
POSIX locale, non-alphanumeric characters (except underscore) converted to spaces,
repeated whitespace collapsed. CER counts Unicode scalars and omits spaces.
Do not mix scores from different normalization versions without recomputing them.
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

The runner currently invokes whisper.cpp only. `TranscriptAccuracy` in the Swift core scores
canonical source text independently of the engine; future runners must retain the
same metrics and fixture IDs. No implementation of either planned engine is
claimed. Adapters are wrappers around upstream engines, never a new ASR engine.

Each output directory must be new. IDs must be unique safe path components.
Checksum mismatches and failed cases are recorded and exit nonzero. Missing or
unlicensed corpus entries remain pending. Ctrl-C or `cancel.request` in the
benchmark directory requests cancellation of the active native job; partial
results and raw evidence remain. There are no automatic retries or cloud calls.

The retired `compare-text-core.py` measured Python/Swift render startup, not ASR.
Frozen outputs now enforce parity in every native test run, so that runner and
the Python pipeline are removed. Historical measurements remain in
`docs/swift-first-migration.md`. `scripts/benchmark-recorder.sh` and the recorded
recorder baselines remain useful and unchanged. The separate optional
`scripts/verify-mic-rate.sh` uses FFmpeg/ffprobe and standard-library Python for
reference-tone diagnostics; it does not depend on the retired pipeline and is
not part of app runtime, core tests or corpus benchmarks.

## Nine-language quality work

The v2 preparation manifest extends coverage to nine priority languages with
explicit varieties, output tasks, development/held-out grouping and reference
hashes. All checked-in recordings remain pending. See the versioned
[corpus/scoring contract](corpus-contract.md) and the
[serial matrix, immutable control and freeze contract](experiment-contract.md).
Legacy corpus schema/scoring v1 remains readable for compatibility. Use v2 for
new quality comparisons; do not pool it with historical normalization scores.

The [2026-11-05 measured pilot baseline](pilot-baseline-2026-11-05.md) records
810 completed inference cells on 27 published-reference development utterances,
including all five untouched models and all nine languages. It is exploratory
legacy coverage, with reviewed v2 grouping/native/condition acceptance still
pending. Accuracy uses repeat 1 only; inference repeats measure variability and
do not multiply the number of independent speech samples. Chinese whitespace WER
is not reported. No default model is selected by this pilot.

Generate a text-free summary from a retained matrix into a new protected external
directory:

```sh
python3 scripts/work-artifacts.py run --label quality-report logs -- \
  python3 scripts/quality/report-pilot.py /path/to/retained/matrix \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/NEW-REPORT"
```

The reporter verifies retained corpus/configuration snapshot hashes and reads
structured metrics only, without raw reference/hypothesis text, audio or model
loading. It preserves incomplete/failed denominators and refuses held-out
reporting by default. `--allow-held-out` requires a matching retained freeze,
bound snapshots and the predeclared review/budget evidence after candidate
selection is frozen. See the experiment contract before using that path.

For the protected synthetic Q30/attenuation preparation, `derive-sensitivity.py`
usage and the staged VAD/language/padding design, see
[speech and language experiments](speech-language-experiments.md#prepared-synthetic-development-inputs).
The [2026-11-05 runtime sensitivity pilot](runtime-sensitivity-pilot-2026-11-05.md)
records the completed Tiny diagnostic; defaults remain unchanged and resource
comparisons remain uncontrolled/not evaluated.
