# Bounded offline LayerNorm activation probe

This diagnostic supports the round-3 weight-only quantization experiment. It
does not change RecScribe, its installed whisper-cli, original models or the
upstream source checkout. It is not a transcription-quality or performance
benchmark, and it never generates a transcript.

Both build routes require the exact clean whisper.cpp v1.9.5 source commit
`d1be6fde11ac6e0407606b4e42fe72d34add8037` and installed GGML 0.27.0. Its C++
translation unit includes that unmodified upstream implementation to access the
private decoder scheduler; it does not link a second libwhisper or change its
public API. The caller must retain the source/header, executable and resolved
native-library hashes, host/toolchain, commands and input identities. A version
string is not a replacement for these hashes. The calibration executable is
distinct from the frozen CLI used for quality comparisons.

The executable calls the official CLI's `ggml_backend_load_all()` initializer
before any model load. A missing CPU or selected Metal GPU device fails clearly
before the library's device assertion. The actual context must select Metal;
requested GPU mode alone cannot pass. Loaded devices, selected backend names,
registry/device types and every observed LayerNorm site's actual backend are
retained as additional `backend_evidence`/target metadata. Legitimate pinned CPU
node fallback is recorded and allowed; there is no all-GPU placement requirement.
These fields augment the statistics schema and are bound by each output hash.
The pinned GGML registry API names its Metal plugin `MTL`; retain that exact
identifier instead of substituting the display/technology name `Metal`.

## Fixed observation

For each predeclared **original development** clip, the helper:

1. Reads a separate prepared PCM16 mono 16 kHz WAV of at most 30 seconds and a
   published UTF-8 reference of at most 16 KiB. It does no resampling, cropping,
   filtering, mixing, reference correction or case selection.
2. Encodes the audio once. It constructs one teacher-forced prefix:
   start-of-transcript, explicit base language, transcription, no timestamps,
   then the first `min(60, reference_token_count)` published reference tokens.
   It never uses recognizer output or a fresh held-out reference. Swiss uses
   `de`; that argument does not establish dialect identity or semantic fidelity.
3. Evaluates the same prefix twice, resetting self-attention KV entries: first
   without the observer and then with it. Every prefix position explicitly
   requests logits. **All logits must match bit for bit.** A difference produces
   `identity_failed` evidence and nonzero exit; it cannot be calibrated away or
   made acceptable by relaxing the threshold after observing it.
4. On the observed pass, captures only the post-gamma-and-beta LayerNorm ADD
   outputs for decoder `attn_ln`, `cross_attn_ln` and `mlp_ln`. Selection matches
   the exact original bias pointer and checks the multiplication's gamma
   pointer, F32 type, contiguous layout and dimensions. Every one of the three
   sites per layer must appear exactly once with the full prefix count.
5. Retains per-channel count, sum of absolute values, sum of squares, maximum
   absolute value, mean absolute value and RMS. Raw activation vectors, token
   IDs, reference text, logits and audio are absent from the output JSON.

Only original multilingual Tiny, Base and Small geometries are accepted. One
invocation is bounded to 64 prefix positions, one encoder pass, two decoder
passes, one or two threads and 120 seconds. SIGINT/SIGTERM or the required
cancellation marker stop owned work. The external experiment guard must still
check capture priority, contention, model/source hashes and process ownership;
this helper does not inspect RecScribe or replace that guard.

Teacher-forced calibration observes the specified published-reference context,
not free-running errors, causal importance, native reference approval or
independent speakers. The consumer averages within each case before combining
the fixed 27 cases equally (three per each of nine languages); it must not pool
longer token sequences into a larger implicit language weight. All candidates
and all non-calibration controls are evaluated by the separately frozen runner.

## Build and run

On the benchmark Mac, use the bounded direct builder with already installed
Apple `xcrun clang++` and GGML; it does not require CMake or install packages.
Run it under `scripts/quality/run-guard.py` inside the managed artifact wrapper.
The guard and builder must receive the same **new** `--output` receipt path:

```sh
python3 scripts/work-artifacts.py run --label issue-112-round3-probe-build test -- \
  python3 scripts/quality/run-guard.py --output /absolute/protected/probe-build-v2.json \
  --timeout 300 --foreign-cpu-limit 1000 -- /absolute/python3 scripts/quality/activation-probe/build.py \
  --upstream-root /absolute/protected/whisper.cpp \
  --ggml-root /opt/homebrew/Cellar/ggml/0.27.0 \
  --output /absolute/protected/probe-build-v2.json
```

The direct builder validates the exact clean upstream commit and installed
GGML version/dynamic-backend configuration, records compiler/SDK/OS and source,
header, native-library and binary hashes, verifies inputs unchanged after the
240-second-bounded compilation, and creates the product exclusively under the
calling checkout's stable `Build/Products/WhisperActivationProbe-v2` directory.
Staging and compiler output remain in the managed run. Existing binaries and
receipts are never replaced. Its receipt records build evidence only; it does
not claim a real activation/ASR check. Dynamically loaded backend plugins and
their non-system dependency hashes are retained alongside link metadata.

Before publishing, the builder invokes the staged executable's bounded
`--inspect-backends` mode with a 15-second timeout and retains stdout/stderr and
their hashes in the receipt. This exercises actual registration/availability
with no model, audio, reference, encoder or decoder. Actual selected Metal and
site placement still require the real diagnostic and exact logit check. The v1
executable and failed diagnostic evidence remain recoverable.

Where CMake is already available, an alternative uses the existing
`Build/DerivedData` location for the stable CMake cache and puts
the executable under `Build/Products/WhisperActivationProbe-v2`. Do not build a
fresh cache for another invocation or replace the installed app. For example,
with an already retained pinned upstream checkout and installed GGML root:

```sh
python3 scripts/work-artifacts.py run --label issue-112-round3-probe-build test -- \
  cmake -S scripts/quality/activation-probe \
  -B Build/DerivedData/WhisperActivationProbe \
  -DRECSCRIBE_WHISPER_ROOT=/absolute/protected/whisper.cpp \
  -DRECSCRIBE_GGML_ROOT=/opt/homebrew/Cellar/ggml/0.27.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_RUNTIME_OUTPUT_DIRECTORY=/absolute/recscribe/Build/Products/WhisperActivationProbe-v2
python3 scripts/work-artifacts.py run --label issue-112-round3-probe-build test -- \
  cmake --build Build/DerivedData/WhisperActivationProbe --target recscribe-activation-probe --parallel 2
```

Only after recording/capture guards, input/selection freezes and binary hashes
are established, run the binary through the owned experiment guard and managed
artifact wrapper. Required arguments are `--model`, `--wav`, `--reference`,
`--language`, `--output` and `--cancel`, all paths absolute and nonsymlink. Optional
arguments are `--threads 1|2` (default 2) and `--cpu` (default GPU enabled with
flash attention off). The new output is created exclusively with mode 0600;
existing evidence and all inputs are never overwritten. A partial write remains
partial evidence and must not be consumed as a complete calibration.

The root wrapper must bind each output SHA-256 to its exact model, prepared
audio, raw reference, language, development-case identity, probe executable and
source/native inventory. The JSON's `source_commit` and `native_version` describe
the required build, not a claimed independent verification of those bindings.

`conditioning.prefix_sha256` hashes the actual fixed four-token prefix plus
the selected reference token IDs serialized as little-endian unsigned 32-bit
integers (`prefix_hash_encoding=u32-le-token-ids-v1`). The bounded raw reference
bytes are separately hashed in `reference_input_sha256`; IDs and text are not
emitted. The root wrapper must reconcile the latter with the immutable raw-input
hash. Token counts alone do not establish which prefix was evaluated.

The dependency-free native contracts are run by
`scripts/tests/test_quality_activation_probe.py`. They compile and execute the
statistics, Unicode and bounded WAV parser checks only, with no GGML/model/ASR.
The real full-prefix callback identity control remains a separate mandatory
execution check; passing accumulator contracts cannot establish it.
