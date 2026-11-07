# Round 3: activation-aware channel balancing — measured report, 2026-11-06

**Reject this fixed adaptation family for promotion.** All three balanced-Q5
candidates failed the frozen quality gates in both known and automatic modes.
Against ordinary Q5, Tiny's relative CER gains were 1.764% / 1.902%; Base CER
worsened 2.322% / 3.087%; Small gained 1.850% CER but worsened WER by 5.734%.
None meets the required 10% CER and 5% WER improvements. Ordinary quantization
supplies the 58.6–61.0% model-file savings; AI balancing supplies no additional
size reduction. No model/default, distribution or installed-app change follows.

All **5,796 planned runner cells were terminally attempted: 5,793 measured
successes and three unscored development failures**. All **4,032 held-out cells
succeeded**, covering 144 sources, sixteen per language. Native comparisons are
**3,720 paired + six pending = 3,726 planned**; all **1,242 Q5 contrasts** are
complete. The 828 legacy reference placeholders remain separate, unpaired
evidence. Failed cells were never repaired, omitted or retried; full development
metrics requiring their missing data remain unknown.

All five held-out plans were sealed together under
`ccc920c498ee85b1b4e8c8a4b72f54b82284d0cc63bcbff9f1ddbb92d08e1de5`, created at **15:08:07.849369 UTC** and accepted at
**15:08:11.154654 UTC**. The first held-out command started at
**15:08:11.169709 UTC**, after all ten panel/development assessments, and the
serial study finished at **18:17:51.352485 UTC**. Held-out reference text was
semantically uninspected before the freeze. All artifacts/settings advanced
regardless of development direction. The [execution amendments](weight-space-round3-execution-amendments-2026-11-06.md)
retain every earlier stop and metadata correction.

The [measurement appendix](weight-space-round3-measurements-2026-11-06.md)
contains every held-out artifact/mode/language rate, denominator, timing and
process-RSS observation. Protected CSV exports also retain panel/development
cohorts, missing values and upstream model-load timers; their identities are
listed below. Independent audits reconciled 630 language/resource cohorts,
70 macro rows and all 453 gates. Resource acceptance remains
**UNCONTROLLED / NOT EVALUATED**; native approval and broader product coverage
remain pending.

This report follows the [prospective protocol](weight-space-round3-protocol.md).
The negative [round-1](weight-space-pilot-report-2026-11-05.md) and
[round-2](weight-space-round2-report-2026-11-06.md) results remain unchanged.
The proposed mechanism is inspired by
[AWQ's activation-aware weight scaling](https://arxiv.org/abs/2306.00978v6),
with a fixed analytic rule instead of scale search. The
[weight-space programming article](https://rikiyat.github.io/blog/weight-space-programming/)
motivates AI-authored direct weight reasoning; neither source establishes an
accuracy or speed improvement for this Whisper experiment.

## Held-out adaptation effect

These are equal-language macro rates: nine CER languages and eight meaningful
whitespace-WER languages. Positive relative gain means lower error. Each mode
has the same 144 sources; modes are conditions, not additional independent speech.
All rates below have complete held-out coverage. The unchanged gate targets are
10% relative CER and 5% relative WER gain over ordinary Q5, plus the separate
original-F16 and per-language floors.

| Family | Mode | Ordinary Q5 → balanced Q5 CER | Ordinary Q5 → balanced Q5 WER | Relative CER gain | Relative WER gain | Frozen decision |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| tiny | known | 16.923% → 16.624% | 36.915% → 36.218% | +1.764% | +1.888% | Reject |
| tiny | auto | 17.469% → 17.136% | 37.971% → 37.536% | +1.902% | +1.144% | Reject |
| base | known | 12.867% → 13.165% | 27.188% → 27.099% | -2.322% | +0.328% | Reject |
| base | auto | 12.900% → 13.298% | 27.264% → 27.251% | -3.087% | +0.049% | Reject |
| small | known | 7.316% → 7.180% | 14.237% → 15.053% | +1.850% | -5.734% | Reject |
| small | auto | 7.316% → 7.180% | 14.237% → 15.053% | +1.850% | -5.734% | Reject |

The independent audit agrees with all stored mode/partition/family decisions:
359 true, 84 false and ten unknown gate observations. The ten unknowns belong
to development coverage affected by the three failed cells; none is a held-out
gate. A known failed gate still rejects, without converting an unknown into a
pass. Tiny also breaches original-F16 quality floors and introduces a new coarse
automatic-label error against that control. Base has French/Chinese regressions
against ordinary Q5 and original-F16 regressions. Small's WER regression and
German/Swiss comparison caps also fail. The full gate evidence is retained.

The three numerical panels passed their required three-repeat identity checks.
Fresh balanced-F16 controls have slightly different rates from their original
F16 controls: real-arithmetic compensation and a nine-source panel do not prove
globally identical finite-precision decoding. Their complete results remain in
the appendix. This finding does not introduce an additional post-hoc gate.

The untouched larger references reach about 3.8% macro CER on this read-speech
set. Full Large-v3 has slightly lower CER than Turbo, while Turbo has lower WER;
neither is universally better across these metrics. Their much larger files,
process memory and observed latency are reported separately below. This does
not demonstrate a Shannon capacity limit for the smaller models or validate
a larger-model adaptation.

## Fixed experiment and completed preparation

Each multilingual Tiny/Base/Small family has four actual artifacts: unchanged
original F16, balanced F16, ordinary original-to-Q5 compression, and
balanced-F16-to-Q5 combined adaptation. Untouched large-v3-turbo and full
large-v3 provide larger-model references. No gradients, optimizer, reconstruction
fitting, training, fine-tuning, distillation or candidate/scale search is used.
Smaller parameter counts do not establish an information-theoretic optimum.

Calibration uses only the original 27 development sources, three per language.
For each model/source, the probe encodes once and decodes the same teacher-forced
prefix twice with KV state reset, callback off/on: four fixed special tokens
plus at most 60 published-reference tokens, at most 64 valid positions. It records
prefix-token SHA-256 using u32-LE encoding and input reference-byte SHA-256,
without publishing tokens, text, logits or individual activation vectors.
All **81** accepted model/source pairs passed the unchanged requirement of
bitwise-identical prefix logits; the fixed budget is **81 encodes and 162
decoder-prefix batches**. This checks observation instrumentation, not the
balanced model's decoding or quality.

Per-channel mean absolute activation is measured after each decoder LayerNorm's
gamma/beta affine operation: self-attention LN feeds all Q/K/V, cross-attention
LN feeds Q only, and MLP LN feeds its first linear layer. Equal recording means
give equal language weighting. With positive-channel geometric mean G, the
single fixed rule is `s = clamp(sqrt(A / G), 0.25, 4)`; exact-zero channels use
one and an all-zero site fails. Gamma/beta are divided by s and every receiving
input-channel weight is multiplied by s with the stored F32/F16 rounding.
Encoder, tied embeddings, cross-attention K/V, GELU and output layers are
excluded. Real-arithmetic equivalence does not establish numerical decoding
equivalence. The three-repeat nine-source balanced-F16 panels now match their
originals in all 54 hypothesis pairs and 27 automatic-label pairs per family;
this is numerical-control evidence, not a quantized-model accuracy gain.

The independent static audit records all three balanced-F16 mappings and all
six Q5 containers passing their declared byte/finite/layout checks. It verifies
4,727,808 / 12,601,344 / 56,678,400 selected elements for Tiny/Base/Small and
unchanged unselected regions. Q5 metadata is `ftype=2009` (q5_1, quantization
version 2), with architecture, mel filters, vocabulary and required passthrough
payload preserved. These structural checks do not establish native model-load
compatibility. The separate pre-execution inventory records full rehashes of
all 14 model files and 11 native files; the artifact-family assembly receipt
itself explicitly did not rehash model payloads.

Ordinary and balanced Q5 have identical byte counts but distinct hashes. Their
recorded model-file savings against their own F16 originals are **58.615% Tiny,
59.644% Base and 61.016% Small**. Balancing alone retains the F16 byte count and
parameter geometry. Ordinary quantization supplies this size reduction; the measured balanced-Q5 versus ordinary-Q5 contrast above isolates the
additional adaptation effect, which failed the frozen gain targets. Process RSS
is observed separately below. Download containers, installed/bundled increments,
total unified GPU allocation and controlled memory acceptance remain unmeasured.

## Artifact identities and lineage

All hashes below are SHA-256, taken from retained metadata receipts. Every
derived artifact retains its own family's original F16 parent and hash.
Balanced Q5 additionally retains the exact balanced-F16 intermediate, scale
file, calibration and audit hashes. Original controls retain their pretrained
identity; ordinary Q5 is a compression control, never an untouched model.

| Artifact | Role | Actual model bytes | SHA-256 |
| --- | --- | ---: | --- |
| tiny | original | 77,691,713 | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| tiny-balanced-f16 | conversion control | 77,691,713 | `ee5e4126f50f521035cd96d4f07468d3b1eeddd87c461eca196685392ba68c10` |
| tiny-plain-q5 | compression | 32,152,673 | `798b1aa609b93763b7bcffec46b1ecad4fb87a0bcc2a4f0934554476b9207d9e` |
| tiny-balanced-q5 | combined candidate | 32,152,673 | `653b99c1feef97af0c3223204a2e086d8b16ce3c6f8010c47a0f1bcfd1361718` |
| base | original | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| base-balanced-f16 | conversion control | 147,951,465 | `bb7614f7bee68ccb1603064010c429272d0649ceaae50c83fc0227807d846683` |
| base-plain-q5 | compression | 59,707,625 | `80147c665f9ac54ab8c3c7f55da90ac030ea40610495ba4dd0aa6304fd49d731` |
| base-balanced-q5 | combined candidate | 59,707,625 | `b857f8db6785d7e58fc7bb13b90ff3af8dcbde9a0309faf7e18d5e0364da3f6c` |
| small | original | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| small-balanced-f16 | conversion control | 487,601,967 | `102a619a3ba6f8b6e1599548aa9555a5c83f463800e8e08d2b29e0f8bf4e19a4` |
| small-plain-q5 | compression | 190,085,487 | `52914f6730a59593fd6108d21dcac060a35ce569d9d70eec431e5623f387c82f` |
| small-balanced-q5 | combined candidate | 190,085,487 | `d7fec26d37aaad9cb57eb5790d170ab0a251fb9d709b81748f9e4e8b4c2e2898` |
| large-v3-turbo | untouched larger reference | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| large-v3 | untouched larger reference | 3,095,033,483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

## Data, scoring and coverage limits

New development-validation contains **72 sources, eight per language**; fresh
held-out contains **144, sixteen per language**. The metadata integrity receipt
records 216 unique original source IDs and references, 216 originals plus 216
prepared audio files, and zero integrity failures. Prior manifests include the
original development, runtime-sensitivity data, both consumed held-outs and
round-2 development. Exclusions cover prior IDs, original/prepared audio hashes,
reference hashes and all 22 known prior Swiss speakers. New splits and known
Swiss speakers are disjoint; this does not establish unknown speaker/session
independence or exclusion from model pretraining.

Sources remain [FLEURS at its pinned release](https://huggingface.co/datasets/google/fleurs/tree/b4a42ed06e12025c42f3b4eff6338ace2fe2447a)
(CC BY 4.0) and [FHNW All Swiss German Dialects Test Set](https://www.cs.technik.fhnw.ch/i4ds-datasets),
v1, 2021-03-10 (MIT). FLEURS dev/test and FHNW public/private source partitions
supply new development/held-out respectively. Original audio, published
references, cards, source/archive/member identities, timings and provenance
remain preserved externally. Acquisition was prospectively bounded to 512 MiB
network and 512 MiB protected output, with 32 MiB archive/source prefixes and
explicit duration/cancellation limits; no silent count reduction or expansion.

| Language/task | Recorded regional/script scope | Measured v1 evidence / native approval |
| --- | --- | --- |
| Swiss German → written Standard German | Published Swiss canton metadata; Latin script; native wording/rendering approval pending | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| German | `de_de`, Germany; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| French | `fr_fr`, France; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| Italian | `it_it`, Italy; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| English | `en_us`, US; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| Arabic | `ar_eg` locale; Arabic script; no adjudicated MSA/dialect breadth claim | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| Chinese | `cmn_hans_cn`, Mandarin; Simplified Han only | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| Spanish | `es_419`, Latin America; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |
| Portuguese | `pt_br`, Brazil; Latin | [Rates and counts](weight-space-round3-measurements-2026-11-06.md); native/v2 review pending |

Swiss published canton counts are dev AG2/BE2/BL1/SG1/UR1/ZH1 and held-out
AG2/BE4/LU1/SG3/VS1/ZG1/ZH4, with 8 and 16 known speakers. Canton metadata is
not native dialect adjudication. The 192 new FLEURS cases have unknown individual
speaker IDs; all 216 sessions remain unknown. Broader dialects/scripts, natural
long-form/adverse/overlapping speech, silence, language switches, live operation,
multilingual fallback and independent-channel acceptance remain pending.
Swiss dialect spelling is a separate output task; this study scores its
published written-German rendering.

Scoring used exploratory `swift-nfc-casefold-alphanumeric-v1`:
count errors/reference units within each language, then equal means over nine
CER languages and eight meaningful WER languages. Chinese whitespace WER is
unreported. Only successful repeat 1 supplies quality, with no later fallback
or selective retry. Native-approved v2/strict Arabic scoring and critical-content
adjudication remain pending; unreviewed corpus entries are not native approval.

## Frozen comparison plan and measured coverage

All four arms of all three families and both larger references proceeded regardless
of development direction. Five partitions ran per stage, serially: Tiny, Base,
Small, Turbo, full Large. All 15 configurations, source/runtime/model identities
and assessment preplans were bound before quality inference. All ten panel and
development grids were terminal and assessed before all five held-out freezes
and final plans were sealed together. Final plans added only the freeze SHA and
two links back to the retained preplan/family seal.

| Stage | Unique sources | Language modes | Repeats | Planned inference cells | Native original-parent pairs | Derived Q5 contrasts |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Original-development numerical/timing panel | 9 | known + auto | 3 | 756 | 486 | 162 |
| New development validation | 72 | known | 1 | 1,008 | 648 | 216 |
| Fresh held-out | 144 | known + auto | 1 | 4,032 | 2,592 | 864 |
| Total | | | | **5,796** | **3,726** | **1,242** |

Derived balanced-Q5 versus ordinary-Q5 contrasts reuse canonical rows; they add
neither native parent pairs nor independent speech. Three panel repeats test
balanced-F16 hypothesis/automatic-label identity and describe variation. They
do not multiply independent sources; one-repeat quality matrices do not
establish repeat stability.

| Model | Three-repeat F16 panel | Development | Original F16 held-out known CER / WER | Balanced Q5 known CER / WER | Balanced Q5 auto CER / WER | Held-out decision |
| --- | --- | --- | ---: | ---: | ---: | --- |
| tiny | 54 hypothesis / 27 label pairs match | Reject | 15.699% / 34.720% | 16.624% / 36.218% | 17.136% / 37.536% | Reject both modes |
| base | 54 hypothesis / 27 label pairs match | Reject | 12.201% / 25.958% | 13.165% / 27.099% | 13.298% / 27.251% | Reject both modes |
| small | 54 hypothesis / 27 label pairs match | Reject | 6.909% / 14.459% | 7.180% / 15.053% | 7.180% / 15.053% | Reject both modes |
| large-v3-turbo | Untouched reference | Reference observed | 3.816% / 7.215% | N/A | N/A | Reference only |
| large-v3 | Untouched reference | Reference observed | 3.787% / 7.427% | N/A | N/A | Reference only |

The two larger references have identical known/auto aggregate rates in this run;
all per-language values and both modes remain in the appendix. Development has
1,005 measured cells of 1,008 attempts: original Tiny Chinese is unscored once,
and original/balanced-F16 Base German are unscored once each. Their five affected
full metric aggregates remain null; observed partial counts are retained
separately. No later repeat or different case supplies the missing score.

The following gates were frozen before inference, separately for each small model/mode:
balanced Q5 must reduce macro CER by at least 10% and macro WER by at least 5%
against ordinary Q5, save at least 50% model bytes, and stay within original-F16
macro increases of 0.0025 CER/0.005 WER: absolute 0.25/0.50 percentage points.
Every language, including Swiss, has CER increase ≤0.01 and meaningful WER
increase ≤0.02: absolute one/two percentage points against both original and
ordinary Q5. Swiss has the same caps in this prospective round; earlier rounds'
stricter Swiss decisions are retained. Require zero newly wrong coarse automatic
base labels against either control; unknown evidence cannot pass. Balanced-F16
controls require equal canonical hypothesis hashes/observed automatic labels in
all three panel repeats. No numerical pass alone authorizes promotion.

## Runtime, reproducibility and retained failures

The recorded host is Mac Studio `Mac14,14`, Apple M2 Ultra, 24 CPU/60 GPU cores,
68,719,476,736 bytes unified memory, macOS 26.6.2 `25G83`, Xcode 27.1 `27A9275`,
Swift 6.4 `swiftlang-6.4.0.34.1`. Artifact tooling records Python 3.15.0 and
NumPy 2.5.4 with one numeric worker. The inventory hash below binds the host,
power, toolchain, binary/library and model records; it is not a hardware attestation.

Quality uses the same pinned whisper.cpp 1.9.5 backend and unchanged profile:
two threads, `-tp 0 -mc 0`, VAD off, no terminology prompt, no cross-source text
conditioning, inherited beam/search/temperature fallback. Temperature zero is
not a claim of greedy or deterministic decoding. Known mode passes each source's
base language (`de` for Swiss); automatic mode passes unrestricted `auto`.
Actual commands/effective settings and detected output labels remain distinct
evidence. The original baseline revision/CLI remain recoverable and unchanged;
the new runner supports this prospectively declared one-repeat quality matrix.

The isolated diagnostic probe pins whisper.cpp v1.9.5 commit
`d1be6fde11ac6e0407606b4e42fe72d34add8037` and installed GGML 0.27.0. Its build
receipt binds 29 source/header files, compiler and native dependencies. Apple
clang 21.0.0 `clang-2100.3.34.2`, the recorded macOS SDK and existing dynamic
GGML libraries build the standalone helper without installing another dependency.
Model-free staged backend inspection passed before publication: `MTL0`/`MTL`
GPU, CPU and BLAS registered. Actual selected Metal state and per-site CPU/Metal
placement are recorded; legitimate scheduler CPU fallback is retained.

Earlier failed/unexecuted build and calibration attempts are preserved. The
first diagnostic execution aborted during model initialization because caller
backend registration was missing: **zero completed diagnostics/encodes/statistics
or candidate quality outcomes**. Backend initialization/actual-device checks
were corrected and the registry name `MTL` was verified by model-free inspection
before the successful frozen 81-pair run. The original failed seal/output and
binary remain retained. Prefix/logit gates, original 27 inputs, scale rule and
81/162 budget were unchanged; no failure was converted into a passing baseline.

Private orchestration contracts passed **13 tests in 1.890 seconds**. They cover
the complete 15-stage preflight, source/model mutation and actual config lineage,
all-ten-before-all-five seal barrier, unchanged preplans/only three final links,
retained partial cancellation, prior-held-out-output rejection, the post-Popen
cancellation window, owned-child reaping, no guard killing and source gates under
Python `-O`. A synthetic seal test exposed a comparison-ID/stage-ID shadowing bug;
the failed log remains pinned, and the corrected all-15 lookup has a regression
contract. This is private harness evidence, not full application/TSan validation.
The runner build receipt separately records 87 native/frozen Debug tests and
Release signal contracts; required current-PR full CI remains a separate gate.

The first stage-preparation attempt failed validation before writing outputs or
starting quality inference: the schema-1 nine-source panel manifest retained
stale per-case v2 labels although its schema-1 runner always uses legacy-v1
scoring. A derived metadata view now explicitly records unreviewed legacy
scoring and preserves the original labels as provenance. The original manifest,
source IDs/audio/references/tasks/channels, scorer, selection and gates remain
unchanged. The corrected preparation completed before the initial family seal
and guarded quality launch; the failed attempt is retained.

At 12:21 UTC the serial coordinator stopped safely after 702 completed panel
cells (Tiny/Base/Small 216 each; Turbo 54). The unchanged native runner emits
legacy `pending_pair` runtime placeholders for reference-only plans with no
explicit comparison and no baseline profile. The initial assessor rejected
their null comparison IDs as if they were real parent comparisons. Inference
and retained reporting had completed; no fresh development or held-out inference
had started. The correction validates the exact placeholder fields and full
canonical-row grid, retains them separately and still counts zero actual
parent/Q5 comparisons for references. Family metrics, gates and result fields
are unchanged. All 702 cells, original seals, tools, journal and assessments
are retained. The canonical postprocessing-only continuation reproduced the first three
numeric/gate bodies before launching the then-untouched 11 partitions. This is
retained history; no completed inference was repeated.

After this correction, **138 offline quality and 12 tensor contracts passed**,
including 28 channel-assessment contracts and strict all-missing/malformed/
duplicate/foreign/real-pair rejection. The complete local native/frozen suite
also passed **87 tests in 15 suites**, including the event-driven synthetic
batch-order fixture and both sleeping/parked cancellation paths. An inherited
five-second fixture polling deadline had failed under CI scheduling delay; its
replacement waits for actual later completion while preserving all ordering,
concurrency and canonical-evidence assertions, with a separate one-minute
deadlock bound. Earlier CI failure/timeout evidence remains retained. Source head
**1c3c277** passed full hosted functional and TSan validation: **461 tests / 86
matching suites each**, no failures, sanitizer diagnostics or unexpected host
restart, and a passing mandatory evidence gate. Release, native/frozen 87 tests,
offline quality 138 and tensor 12 also passed. The decoded CI log and independent
audit remain protected; receipt SHA is
`3af64b607506a868cd6e88604c1c0701a82788c0b12aa9700653c378eaac823b`.
Later documentation/report heads require their own applicable CI; earlier green
evidence does not pass a later head. No frozen capture was rebaselined.

The first attempted-grid continuation historically preserved 1,044 terminal runner attempts:
1,043 successful and one failed, with 699 paired / 3 pending native comparisons
and 234 Q5 contrasts. Its initial six reassessments succeeded under seal
`7a60e45cc03a1dd0b33bbd606384aab2e7ef2a3bb5d01b4c49f4a7c040e9e04e`.
All five prior assessment bodies remain exactly equal except timestamp/source
evidence. At that historical boundary, nine untouched grids / 4,752 cells remained.
The malformed recognized-text bytes stay preserved, with no repair, guessed
score, selective retry or missing-coverage pass. The unchanged analyzer retains
Tiny development's reject decision and unknown original-CER floor. The terminal
attempt barrier and distinct successful-coverage requirements are documented in
the linked amendment, not hidden by overwriting the original protocol.

Base development subsequently completed 286 of 288 attempts; original Base and
balanced F16 each produced nonblank speech with zero duration on the same German
source. The native reader correctly rejected both. A separately frozen finite
structural-output classifier extended failure accounting before held-out work,
without changing the reader, scorer, models or settings. Continuation seal
`80db4a50db73891c570d0330811812f764c100f16fbb9cf80874fca4986f4d37`
retains all earlier sources/seals/refusals and the three raw failed outputs.
All six prior assessment bodies rebuilt identically apart from timestamp/evidence.
The final study reached all 15 terminal grids without a repeated inference.

Development launches remain capped at 3,600 seconds; the prospective held-out
operational cap is 10,800 seconds. Every launch keeps two threads, serial nice10
utility work, with a cancel marker and owned-session shutdown/reaping. Fresh
native idle/live-off inspection is required before inference. Active/uncertain
capture or known competing ASR/build/test/VM work stops owned research. The
prospective 1,000% raw per-process foreign CPU stop is an extreme-contention
guard on this 24-core shared desktop. Descriptor polling retains a capture-intent
race and does not prove real-time recording scheduling. No capture or foreign
application is stopped to run this study.

Resource acceptance remains **UNCONTROLLED / NOT EVALUATED**. The following
known-mode overview uses medians of the **144 underlying successful invocation
measurements per artifact**, not averages of language medians. Wall time is the
outer invocation latency; RSS is peak process-resident memory and excludes an
accounting of total unified GPU allocation. Load is the upstream reported
model-load timer, not complete initialization or first-result latency.
Workload RTF is sum(invocation wall)/sum(source audio): one aggregate observation.
The source audio total is 1,718.49 s in each row. Known and auto reuse the same
sources as different conditions. Full distributions/counts, both modes and all
languages are retained in the appendix and protected exports.

| Artifact | File MiB | Wall median s [min..max], n=144 | Peak process RSS median MiB, n=144 | Upstream load median ms, n=144 | Whole-workload RTF, n=1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| tiny | 74.093 | 1.247 [0.951..3.452] | 274.13 | 45.91 | 0.147 |
| tiny-balanced-f16 | 74.093 | 1.148 [0.888..1.836] | 273.98 | 43.62 | 0.097 |
| tiny-plain-q5 | 30.663 | 2.677 [2.130..3.298] | 207.48 | 153.02 | 0.225 |
| tiny-balanced-q5 | 30.663 | 2.692 [2.235..3.622] | 207.16 | 178.22 | 0.226 |
| base | 141.098 | 2.570 [0.976..3.091] | 383.30 | 144.04 | 0.185 |
| base-balanced-f16 | 141.098 | 2.775 [2.118..3.459] | 383.61 | 199.05 | 0.231 |
| base-plain-q5 | 56.942 | 2.724 [1.671..3.233] | 267.59 | 169.30 | 0.226 |
| base-balanced-q5 | 56.942 | 2.708 [2.037..3.191] | 267.70 | 181.37 | 0.226 |
| small | 465.013 | 1.606 [1.306..2.158] | 857.42 | 157.06 | 0.135 |
| small-balanced-f16 | 465.013 | 1.600 [1.357..2.167] | 857.18 | 157.75 | 0.135 |
| small-plain-q5 | 181.280 | 1.404 [1.127..2.183] | 526.06 | 74.28 | 0.120 |
| small-balanced-q5 | 181.280 | 1.399 [1.108..1.995] | 526.20 | 74.46 | 0.119 |
| large-v3-turbo | 1549.297 | 2.512 [2.289..3.041] | 1928.26 | 480.58 | 0.212 |
| large-v3 | 2951.654 | 5.580 [4.699..7.126] | 4034.71 | 1055.24 | 0.471 |

There is no consistent balancing-only latency/RSS improvement. Ordinary Q5
reduces model-file bytes and observed process RSS; it is sometimes slower than
F16 in this shared-desktop sequence. Small Q5 is faster in these observations,
while Turbo uses much less memory and lower latency than full Large-v3.
These are descriptive measurements, not controlled speed or memory acceptance.
Per-language held-out wall/RSS/load each have n=16; each language's workload RTF
has n=1 aggregate computed from those 16 invocations. No sixteen-sample RTF
distribution or pooled median-of-medians is claimed.

First-result latency, complete initialization, total GPU memory, energy, bundle
increments and controlled thermals/load remain unmeasured. Original audio,
references, raw transcripts, timings, models, manifests and provenance remain
protected externally, outside disposable retention. No installed app, saved
language policy, independent-channel state or default was changed.

## Evidence identities

Protected receipts use `R3 = ~/Library/Application Support/RecScribe/Benchmarks/Research/112/round-3`;
raw corpus/model payloads and CSV exports are not copied into the checkout.
Report curation and numeric audits use retained measurements and metadata,
without raw audio/reference inspection, recognition or rescoring. The separate
post-run provenance audit rehashed the 14 models, 11 native files and both CLI
binaries: all 27 payload identities matched. Its capture-priority guard exited
cleanly with no live owned session or cancellation. All hashes are SHA-256.

| Receipt/metadata | SHA-256 |
| --- | --- |
| Acquisition freeze | `9457ce2b75089c084d5360273afe2457abb9beb7a83ee1141d983cf6b9fe9ca4` |
| New development manifest | `5d1f1ab4d0e59664d5ca40d97701068072edaab5dfec1209b904191383296f8d` |
| New held-out manifest | `aa5603c23bedbbc01bd9bdfeb0f4e94fd417b965695955f25e6dd8242bd8ea34` |
| Opaque corpus integrity receipt | `65b0286c28ba12cfb2532253825da6315a20ca898b405b3a4d9e1084d8816c05` |
| Calibration freeze v3 | `90ae17fae647dca00a7b39f4312621d25a50fdbb132ead525a64a6e4e6777f90` |
| Calibration execution v2 COMPLETE | `b9a9b13cd232d8627e6b5e67dc69036a2a630b1fab0c98238c07690a47eeb9e6` |
| Tiny / Base / Small calibration | `cb88b1af6713c562210a2704bf6cf84d1fade4378c03ba88649be1fc187cb928` / `4a29a38ea1019d2196947d593d4fcdcc269e81faaf27217b5335a68cd1724f6f` / `7d78dad320fa16b298563b76cae230cfce40f234c7c047ed0e306d596b88bee1` |
| Probe build v6 | `035d3780bc1ba5fb014977024446d93b0f28138eb5cecc0525062cacd1508c8f` |
| Artifact-generation freeze | `fc0df4d8986a020f4302da45dc7e5638d44b5e96e9b5e5384853bc8913d0cd4a` |
| Ordinary-Q5 controls receipt v2 | `3309d514f9e3346c66a636b52413dd6909266081c16a3b95fb4f8e3623054020` |
| Artifact-family receipt | `adb2bab6673d35d8fc37786501e57b0d998ac1445c1b806a77e877eaf1506c66` |
| Independent static audit | `14468c2a6bf8791a3c89c4b106177276f700f6cbc45b302820428bdbc4da447a` |
| Independent static source review | `d064cbcff48e0a499cdf8cd3d74730ad7f87944bdf1d0f391c093b437571f83a` |
| Pre-execution host/software/all-14-model inventory | `bbd513043266bed91e55870dd3e0d628f6f21db826f755e75ce1943af71ea4e0` |
| Runner build receipt | `80365554c266678ce87e6009df1b4598e73fc9c64b28c8279276d1208a590d3a` |
| Private orchestration validation | `da76b4fdff460be6e209b4266bab290ad66e025b08fdc7cab7e3dd19b3b0e1d2` |
| Full pre-inference family seal | `0f0371e506720dff1eed7238780b1fdcad7efb1a55fc6bd6496469dc35785635` |
| Reference-placeholder repair validation | `18d0e09e62a922c15e9170d08affdbc38ce558071a70a2d462222e67fddb8a84` |
| Canonical-packaging continuation seal | `55af321be03c42e13394c8986a984af38ad148f1d8cc2ceb6dc4650b246a0b2c` |
| Actual Tiny/Turbo CLI-write smoke | `52d70a009be5fde9be7b072e22a2eb43e7d96cfbba33aee7ed5e48d3b365e932` |
| Terminal-attempt continuation seal | `7a60e45cc03a1dd0b33bbd606384aab2e7ef2a3bb5d01b4c49f4a7c040e9e04e` |
| Failed-cell opaque classification | `3ab1af270c06bd621252bcb73de4f06d0c123696d2ce4dd1951641670d017677` |
| Guard maximum-duration equivalence | `f032e72acaf5fe67b3a34b741e21a4869b625adaf5ad6827adc28038d2f0950c` |
| All-five-held-out receipt | `ccc920c498ee85b1b4e8c8a4b72f54b82284d0cc63bcbff9f1ddbb92d08e1de5` |
| Final serial journal binding all 15 matrices/reports/assessments | `528d05b1b936d7e1d5242965549b059df5a72fe336811724640ad82d65550232` |
| Structural-output continuation seal | `80db4a50db73891c570d0330811812f764c100f16fbb9cf80874fca4986f4d37` |
| Final metadata summary.json | `0b2beb08cc5be91eaac03a50f540cc85ef0b9f7808f162807b51e539adafbea8` |
| Unedited generated summary.md | `deb4666cf2ecf0a3d838a06c3d06cab87a877664aad7422273df8837f0654806` |
| Projection audit | `5d8166539f33a51c8a066fa4be678fc07d09dd3c7917efcd6afa79965d7afa90` |
| Independent numeric/resource audit | `d8693125d5078cfd81cb59b4cd7f5128bf0141258c83dc6acc6219075a7bba7e` |
| Independent 453-gate audit | `d202e1118dc47a99c3a54168a5996e7a9df8003619c81decd820edd3d1395b50` |
| Post-run model/native/runner hashes | `f90cc14be17437fcb4de6b334fcfce7f4af930b529052bf5dcbcff1b4b32b872` |
| Post-run clean guard execution receipt | `12b3dbcc5719d007163fbe13d9bf324fa21a7f7004b5c294b6099f0238bda95c` |
| Current implementation 7cc0a62 full CI evidence | `7564734d13e6b8fa15f7cc44a03aad0ba77b981bf4a79f5490ac1c4543f58098` |
| Published measurement appendix | `93fe7e8f1d96c923f5b9cb6b55e83a8e7ba769149c09fa495384afa40ddb5251` |

| Source/tool identity | SHA-256 or Git revision |
| --- | --- |
| Original control revision / CLI | `c214a8ed03f972a5a9cab64105145a67371b97b4` / `9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6` |
| Round-3 runner revision / CLI | `a55b9ef1c3a5ab4ede43659e8c35c89001d0fc0f` / `5190e4d3849b8f5aa37ef7031d9557d6ebd17866c798b9c6412cba64b587c1c4` |
| Diagnostic probe binary / source | `53caf6cda0641e490a3a8163c345e58c84fe8f7695be3523e878ea994a3a2877` / `318a30c22242859088c8c8e4f6bfb289be963aefbd2774c7e1bc88386d82a40a` |
| Probe compiler | `ee029330bf58ab6e481385f4237cc54602eaa8b81526242e5c5ab5b76e8c5a7e` |
| Balancer / GGML parser | `8693cceeb152f84aaeb249ae1da579cb1bc3cb4653853e13fcf20c3a06849713` / `11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3` |
| Ordinary / balanced Q5 wrappers | `a96a7d61e15edeb813e50b347e5b8ab493e4b454491b625cef741eaa6d6425eb` / `68e2c049e41c5defa8a3aeb39078497a73427c664adaba55dbaf7e9587d07171` |
| Official whisper-quantize binary | `2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd` |
| Profile file / effective settings | `4fde2c62eaeb82fe10581324384d0af72f965f0cc1d8375b234453bbd24c1857` / `cdd7cdc0076480723ee4be3cf4d5d2f417ffb7c6ce44fcaeaed517c164048169` |
| Public reporter / original historical assessor | `121b097f00eff413a47b940ef71a91db55270a42e545ebdd919f97de3e169059` / `b2943432a35e6dd35365fd87cc8093d1e9ba52c5f2589b43b36adcfa9a6e9206` |
| Corrected reference-placeholder assessor | `78b9715dfbf0016d57421b9a04347b9b78e84ed6f6bd4b8c1dba284569a3e0be` |
| Original historical guard | `66ccbc45bd70ae9abee2b3fc6f796109e7f5b1c99fdeb91c1ae4f956b2a79f69` |
| Attempted-v1 guard / historical failure classifier | `7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c` / `7fabce50796cd4e638b140b932d4295b6d36ecc7e962ed44099bbcbb18383f4b` |
| Original historical coordinator / all-held-out sealer | `fd16363b1e5b9bebc0d0a68937d718d0297b050218252c2d9703292a25d1efa8` / `b9dad655a7026ecc4323eeab905e540d97879574be7273df8d68fa7c7d43f457` |
| Current v2 coordinator / sealer | `bb7e516fd199242122d19502575dbc967fcc7b31a87d14eba16d5ab5c3e7ec1d` / `bf1d48747cfcb4fed93d232307b818e885921227f90e34addaaa3b27d2458fd5` |
| Current finite native-output classifier | `b5fa141cab70dce2401d095aacc3f4d192b92e157878afddfb72a4a4608bc353` |
| Frozen final formatter / projection adapter | `b07bf7baac7486152fb0290a0e623252fc1351f56c74e4711de5db90b9d23bed` / `667edef309fdcb2491f104b6675c632f411829620b42e8ba8e35cccc63b02113` |
| Independent gate audit / provenance audit | `eae2453a7ea880f64ac577c3133088ba67275a888958f46eb3997ae69cac835d` / `f8bf80d175509138f8577c89c08d13cef7a71971e1e13bee947fe1edbf1235da` |

| Native runtime file (recorded inventory) | SHA-256 |
| --- | --- |
| whisper.cpp 1.9.5 whisper-cli | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| GGML 0.27.0 libggml-base | `4b83a188ddd93a32003edbe342aeae7e3726b7aed2c2e7774642f80fb4855d7f` |
| libomp 23.1.4 | `432b8d15fc1b2431f937bba89796a32daaa2dd464eda12a744d9cb2818842477` |
| GGML 0.27.0 libggml | `eea477583ec2610f261a08e80f07593d6fceaa30418d7ae95e385e2cda5d9b74` |
| GGML BLAS backend | `bc7cdf71b25a4ef01387c2a0f218fe995d2c70869df03ae8921e6bde3da57214` |
| GGML CPU apple_m1 backend | `3146b7ad6d6602df9c6b05407b1b30479cea77383be9dbf72a2865841d28a05c` |
| GGML CPU apple_m2_m3 backend | `dc13929118733f01625f7ea1beec95b43ff3143a87a44cd0b16824cf08cdff7e` |
| GGML CPU apple_m4 backend | `d90161124de31c08897872eafa7e3ddc3b43a713e184cef59c8af002bf2161bf` |
| GGML Metal backend | `0e7f450879c116699bee6c3bbc3a8630d01d6e4e74e9f918af6dd6b1c7facffa` |
| whisper.cpp 1.9.5 libparakeet | `16ed9f49842cde9371fc605e0d6a7ad1dae5b8d8df9c97c72bce2f3c663ca0e6` |
| whisper.cpp 1.9.5 libwhisper | `a2972b454e49de7c83036eed4adbd06d8271f6f7c87b14e679d035d898d3ed4d` |

The final formatter requires all 15 terminal attempts and all frozen links.
Its exit 0 means evidence processing succeeded, not that model quality passed:
the study status is COMPLETE_TERMINAL_ATTEMPTS_QUALITY_INCOMPLETE_NO_PROMOTION.
The independent gate audit agrees with all 453 observations and stored decisions;
the independent numeric audit checks 9,991 count/rate relations across 630
language/resource cohorts and 70 macro rows. Post-run hashes cover 6,722,090,842
bytes across 27 payloads. No inference was repeated; the three failed raw outputs
remain unscored and all original data stays retained.

## Protected numerical exports

These are external data under R3, not new CLI job/results folders in the checkout.
The published appendix reproduces the projection's numerical tables; the
following exact exports support all phases and retain missing observations.

| Protected export relative to R3 | SHA-256 |
| --- | --- |
| `final-attempted-v2-projection-v1/quality.csv` | `3677e07e04efccdb4469f2349e7a661818acb18d071519574ee228ed85743f75` |
| `final-attempted-v2-projection-v1/resources.csv` | `8f44a702d9ef29b2adbf7a6eaf267928a700dc673848bf6d96a4813b0c580d80` |
| `final-attempted-v2-projection-v1/macros.csv` | `48610dfe952accc9573f3f65da4830e5768051bf59aa0e50702d47bbf18b4c1c` |
| `final-attempted-v2-projection-v1/report.md` | `beccb09de7b53dc15f77747454b5fda23d645f734a04f6c5209603be6088c122` |
| `final-numeric-projection-audit-v1/native-load-observations.csv` | `1b724bb833d47291e6ad435186f25bfdcc71263b3237b0ef8cd245b4ae37c131` |
| `final-numeric-projection-audit-v1/heldout-resource-headlines.csv` | `5fe95dc422fe93757eec8e486a37d80702c6c7c5d4ff10e21d8da0da3b42b041` |

## Validation and remaining acceptance

Implementation head 7cc0a62 passed full CI:
[run 42238195724](https://github.com/moreaki/recscribe/actions/runs/42238195724).
Functional and Thread Sanitizer each report 461 tests in 86 matching suites:
458 passed, three matching existing opt-in skips and zero failures. Exact test
name/count evidence and the mandatory sanitizer gate passed, with no runtime
diagnostics or unexpected host restart. Release, native/frozen 87 tests in 15
suites, offline quality 138, GGML 12, supervisor contracts 12 and boundary/PCM
checks passed. Frozen reference captures were never rebaselined. Earlier hang
logs remain retained: the healthy new native run did not reproduce the hang;
its cause remains unresolved and actual stall sampling was unexecuted.

This final documentation update requires applicable checks on its own PR head;
the earlier implementation pass does not pass a later commit. No automatic
merge, bundled-default recommendation, installed-app or distribution change.

Native reference/critical-content approval, reviewed-v2 eligibility, complete
speaker/session independence, broader regional/script/natural/switch/live/channel
coverage and controlled resource acceptance remain pending. Signed-product
audio, signed Keychain and opt-in local synthetic speech checks were the three
matching CI skips, not newly disabled tests. First-result latency, complete
initialization, total GPU allocation, energy and assembled bundle costs remain
unmeasured. Nothing here establishes a capacity ceiling for Tiny/Base/Small.

The fresh development and held-out sets are now consumed research evidence.
Do not retune on them and call a later evaluation fresh. Further work needs a
new development-only mechanism, preserved controls and fresh predeclared
held-out data. The larger references can inform that hypothesis without
promoting a model or claiming weight-space programming cannot work.
Missing data or unexecuted checks remain pending.
