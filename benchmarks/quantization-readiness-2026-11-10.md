# Quantization readiness — 10 November 2026

Ordinary quantization clears the requested **30% same-model file-size gate** for
Small, large-v3-turbo and full large-v3. All eleven artifacts also completed a
22-call native compatibility check on one development clip in known/auto modes.
Quality preservation and controlled latency/memory acceptance remain **pending**.
These results do not recommend changing a shipped model or default.

| Model | Original F16 bytes | Q5_1 bytes | Reduction | Q4_0 bytes | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small | 487,601,967 | 190,085,487 | 61.02% | 145,458,015 | 70.17% |
| large-v3-turbo | 1,624,555,275 | 624,065,675 | 61.59% | 473,992,235 | 70.82% |
| large-v3 | 3,095,033,483 | 1,177,039,883 | 61.97% | 889,340,843 | 71.27% |

The [machine-readable evidence](quantization-readiness-2026-11-10.json) contains
exact hashes, parent lineage, all five unchanged multilingual F16 controls,
measured file lengths and six separate threshold decisions. Every artifact was
stream-hashed and checked for identity changes during the audit. Architecture
headers match their respective parents; that check does not prove tensor validity
or native compatibility. The quantizer was whisper.cpp 1.9.5, binary SHA-256
`2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd`.

Small/Turbo Q4 artifacts are reused read-only from the retained round-5 ordinary
compression controls. Q5 artifacts and full large-v3 Q4 were exported into new
protected locations. Original F16 files were hashed before/after export. The
interrupted first full-large Q5 export and all failed/deferred attempts remain
retained separately. Fixed Q4/Q5 recipes were not changed in response to outcomes.
Export wall times are not inference performance evidence. Background CPU limits
were explicitly amended for deterministic file export only; timed ASR retains
the stricter quiet-host and recording-priority admission policy.

## Corpus preparation

The source plan attempted two public YouTube sources per requested language:
Swiss German, German, French, Italian, English, Arabic, Chinese, Spanish and
Portuguese. Seventeen audio-only originals and seventeen 60-second mono views
were prepared. The Swiss held-out source exceeded the 1,200-second source bound
and was rejected. Nine sources are marked development and eight held-out;
these partition labels do not establish independent speakers or sessions.

The initial exact base-language lookup downloaded no manual VTT tracks. A later
inventory found an uploaded `en-US` track for the English development source,
missed by the requested exact `en` lookup. The earlier assertion that none of
the sources exposed a manual same-language track was too broad; this corrects it.
The raw regional track is now retained separately (8,202 bytes, SHA-256
`5b7ff207383dca5f6984879d604f28b4e2b0fb690cf37a4d0210ae8eedd1c555`),
with a pending review packet of 24 original cues intersecting the clip, including
two partial boundary cues. Uploaded captions are still unreviewed; no model
hypotheses were read to prepare that packet. Automatic captions were not accepted
as references; burned-in subtitles were not converted into gold text.
**Zero references are approved**, and no scored
quality evaluation has been performed. Original audio, metadata, logs, source
intervals and hashes remain protected externally. A subsequent preservation
audit rechecked all 121 retained source-package files unchanged. Its source
preparation receipt SHA-256 is
`562e0462a949b4c99650aa233a818987b20f6b00fc8719db00393ba16c9402a6`.
Those packages used preparer v1; the subsequent v1.1 helper adds continuous
recording-priority checks and verified descendant cleanup. It was validated
offline, without rewriting the retained v1 source packages.

Twenty-seven development derivatives add exact 1/8 attenuation, 30-second digital
silence prefixes and fixed 10 dB synthetic white noise. These share their parents'
source groups. They do not provide natural adverse-condition coverage or additional
independent speakers. The nine noisy views retain the original frame counts and
achieve 9.9941–10.0068 dB post-clipping SNR, with 28 clipped samples in total.
Seeds are fixed from each parent hash and the recipe identifier. The combined
pending manifest has 44 views of 17 original sources. The first noise preparation
hit its time bound before producing audio; that attempt and its seal remain
retained separately. The successful preparation cached the completed recording
probe for one second, with the same recipe, seeds and time/byte limits.

Actual language, regional variety, script, word boundaries, subtitle correctness,
code switches and permitted-use review remain unadjudicated. Planning tags from
search cannot establish coverage of Arabic dialects/MSA, Chinese scripts/regions,
Brazilian/European Portuguese or any other regional distinction. Swiss speech
targets written Standard German, with optional dialect spelling kept separate.
The consented recording and review checklist is tracked in #122 and
[real-world-recording-scenarios.md](real-world-recording-scenarios.md).

## Validation and remaining gates

The benchmark host is an Apple M2 Ultra Mac Studio with 24 CPU cores and 64 GB
memory, running macOS 26.6.2. Local compatibility validation used Xcode 27.1 /
Swift 6.4. The repository's pinned Xcode 27.2 hosted validation remains required.

- Full native suite: **92 tests in 16 suites passed**, including mandatory frozen
  reference contracts and a non-silent resource-only matrix using a synthetic
  ASR helper. This tests orchestration, not real-model compatibility or accuracy.
- Offline script suite: **153 tests passed**, including source preparation,
  cancellation/owned-helper cleanup, scoring separation and exact size gates.
- Source-boundary self-test and repository check passed; the PCM ownership probe
  processed 20,000 buffers with zero owner overlap or corruption. This probe is
  not a full app Thread Sanitizer pass.
- Release CLI compilation passed from source `517d3440975bd6837c409e6a70c3a23081f947c6`;
  binary SHA-256 is
  `b082ca6dddb9fc1d315d95cb4a9bcc5c06f1b49f94dc9b06b5ec5c32d897eaec`.
  The build receipt also hashes the actual whisper binary and 12 library paths.
- The real CLI dry run reports **594/594 resource-panel cells ready**: 11 models,
  nine planned language slices, known/automatic modes and three repeats. No ASR
  was executed. A prospective candidate/input seal retains all identities;
  fresh native idle/live-off and quiet-workload admission are still required.
  The workload probe observed `fileproviderd` at 99.1% CPU, exceeding the unchanged
  50% foreign-process limit for timed ASR, so no timing claim was produced.
- Nine critical archived receipts/binaries (51,590,311 bytes) and four frozen
  remote refs were reverified unchanged, alongside all 11 model hashes.
- The later 22-call native compatibility check completed with valid canonical
  output and review flags. Broader source coverage, controlled three-repeat
  resource comparisons and reviewed nine-language quality remain pending.
  Full hosted functional/Thread Sanitizer checks are required on each publication
  head; previous verified passes are recorded below. The complete PR diff selects
  full CI, including the existing sanitizer evidence gate.

The existing runner's explicit `resources_only` mode permits resource work before
references are ready. It retains raw transcripts and timing without reading or
scoring references; exact output-hash agreement cannot prove accuracy. Fresh
held-out quality remains unopened until reviewed references, independence and
prospective quality/runtime budgets satisfy the freeze contract. No model is
promoted from a file-size result.

## Execution follow-up

PR #125 head `c2ec357becb2d8384b083d220d713bd96c8e67fc` passed both required
checks in [full CI run 42849327884](https://github.com/moreaki/recscribe/actions/runs/42849327884).
Hosted native/frozen validation passed 92 tests. Complete functional and TSan
runs each recorded 461 tests: 458 passed, the same three existing opt-in skips,
zero failures/runtime warnings/diagnostics and no unexpected test-host restart.
Independent verification passed the complete matching-count sanitizer gate and
the provider artifact SHA-256
`1ac289d8bb26cb85848bb0a9fd9bb1863173b43aebca2aa7f7c330e753b157e2`.
This evidence authenticates that head; later publication heads require their own
applicable checks.

After the user confirmed a quiet Mac/no recording, a native Live check verified
idle/00:00/live-off. The first launch cancelled during model hashing because
Codex Renderer exceeded the unchanged 50% foreign-process CPU guard. The next
launch attempted five Tiny cells before macOS Contacts synchronization exceeded
that limit: four failed and one was cancelled. All five raw ASR JSON files are
retained, with zero canonical transcripts or completed pipeline measurements.
Three Swiss calls failed the unchanged zero-duration-speech contract. A German
call exposed an omitted SwiftPM schema resource bundle in the staged CLI.

The corrected staged product retains the identical executable/hash and the three
required resource-bundle files. Schema bytes match the source revision; a
model-free check matches all five frozen renderer export hashes. The original
incomplete staging, raw jobs, failures/cancellation and seals remain unchanged.
The [experiment contract](experiment-contract.md) now documents complete CLI
staging and resource verification.

A separate complete-product pilot is prospectively sealed with the same eleven
models, source inputs, decoding settings, three repeats, two threads and CPU
guard. Repeating the fixed panel after correcting packaging is an explicit
protocol amendment; original failed calls are never replaced or promoted to
passes. Zero-duration speech remains a failure. This is development resource
work, with no scored quality or held-out outcomes used to select the correction.
The strict panel's next launch was deferred before inference by `fileproviderd`.
Controlled three-repeat measurements remain pending under the original 50%
foreign-process policy. A separately frozen native compatibility check then
completed **22/22 calls** on one development source, both known/automatic modes,
covering all five F16 and six Q5/Q4 artifacts. All produced valid canonical output
with review flags; the guard shut down cleanly. Its 1000% foreign-process limit
was declared prospectively for compatibility only, so retained timings/RSS are
**UNCONTROLLED / NOT EVALUATED** for resource acceptance. No size, quality or
timed-ASR gate was changed. All twelve parent output-hash comparisons differ;
that does not quantify accuracy. See the
[compatibility report](quantization-compatibility-2026-11-10.md).

Postflight verification rehashed all eleven models, all 121 original source-package
files, six original freeze inputs and nine critical archived files unchanged.
It verified all 22 row identities, twelve parent comparisons and 359 retained
output files. All inference workers have exited; no recording or app/default
was changed. Reporter 1.3 explicitly describes resource-only reports as unscored
and avoids claiming CER or language-ID accuracy when references were not read.
