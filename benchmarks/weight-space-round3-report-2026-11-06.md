# Round 3: activation-aware channel balancing — preparation report, 2026-11-06

**Preliminary preparation snapshot; quality results pending.** Activation calibration completed
81/81 fixed model/source diagnostics and all 14 model artifacts have recorded
byte counts and SHA-256 identities. **Quality, decoding controls, native artifact
compatibility, latency and memory outcomes remain PENDING.** Fresh held-out
reference text remains opaque. Quality execution has been launched under the
pre-inference family seal; no quality outcomes are incorporated here. No default, packaging or distribution change is
authorized; these preparation checks do not establish a useful Whisper gain.

This report follows the [prospective protocol](weight-space-round3-protocol.md).
The negative [round-1](weight-space-pilot-report-2026-11-05.md) and
[round-2](weight-space-round2-report-2026-11-06.md) results remain unchanged.
The proposed mechanism is inspired by
[AWQ's activation-aware weight scaling](https://arxiv.org/abs/2306.00978v6),
with a fixed analytic rule instead of scale search. The
[weight-space programming article](https://rikiyat.github.io/blog/weight-space-programming/)
motivates AI-authored direct weight reasoning; neither source establishes an
accuracy or speed improvement for this Whisper experiment.

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
equivalence; the actual balanced-F16 controls remain pending.

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
parameter geometry. Ordinary quantization supplies this size reduction; only
the forthcoming balanced-Q5 versus ordinary-Q5 comparison can measure an
additional adaptation benefit. Download containers, installed/bundled increments
and runtime memory are separate, currently unmeasured quantities.

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

| Language/task | Recorded regional/script scope | New dev / held-out quality |
| --- | --- | --- |
| Swiss German → written Standard German | Published Swiss canton metadata; Latin script; native wording/rendering approval pending | PENDING / PENDING |
| German | `de_de`, Germany; Latin | PENDING / PENDING |
| French | `fr_fr`, France; Latin | PENDING / PENDING |
| Italian | `it_it`, Italy; Latin | PENDING / PENDING |
| English | `en_us`, US; Latin | PENDING / PENDING |
| Arabic | `ar_eg` locale; Arabic script; no adjudicated MSA/dialect breadth claim | PENDING / PENDING |
| Chinese | `cmn_hans_cn`, Mandarin; Simplified Han only | PENDING / PENDING |
| Spanish | `es_419`, Latin America; Latin | PENDING / PENDING |
| Portuguese | `pt_br`, Brazil; Latin | PENDING / PENDING |

Swiss published canton counts are dev AG2/BE2/BL1/SG1/UR1/ZH1 and held-out
AG2/BE4/LU1/SG3/VS1/ZG1/ZH4, with 8 and 16 known speakers. Canton metadata is
not native dialect adjudication. The 192 new FLEURS cases have unknown individual
speaker IDs; all 216 sessions remain unknown. Broader dialects/scripts, natural
long-form/adverse/overlapping speech, silence, language switches, live operation,
multilingual fallback and independent-channel acceptance remain pending.
Swiss dialect spelling is a separate output task; this study scores its
published written-German rendering.

Planned scoring remains exploratory `swift-nfc-casefold-alphanumeric-v1`:
count errors/reference units within each language, then equal means over nine
CER languages and eight meaningful WER languages. Chinese whitespace WER is
unreported. Only successful repeat 1 supplies quality, with no later fallback
or selective retry. Native-approved v2/strict Arabic scoring and critical-content
adjudication remain pending; unreviewed corpus entries are not native approval.

## Frozen comparison plan and pending outcomes

All four arms of all three families and both larger references proceed regardless
of development direction. Five partitions run per stage, serially: Tiny, Base,
Small, Turbo, full Large. All 15 configurations, source/runtime/model identities
and assessment preplans are bound before quality inference. After all ten panel
and development partitions complete, all five held-out freezes and final plans
must be sealed together before the first held-out outcome. Final plans may add
only the freeze SHA and two links back to the retained preplan/family seal.

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

| Model | Balanced-F16 decoding control | Dev known CER/WER | Held-out known CER/WER | Held-out auto CER/WER | Latency/RSS/RTF | Native artifact compatibility |
| --- | --- | --- | --- | --- | --- | --- |
| Tiny | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Base | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Small | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| large-v3-turbo | PENDING reference observation | PENDING | PENDING | PENDING | PENDING | PENDING round-3 invocation |
| large-v3 | PENDING reference observation | PENDING | PENDING | PENDING | PENDING | PENDING round-3 invocation |

Material gates remain prospective and separate for each small model/mode:
balanced Q5 must reduce macro CER by at least 10% and macro WER by at least 5%
against ordinary Q5, save at least 50% model bytes, and stay within original-F16
macro increases of 0.0025 CER/0.005 WER. Every language, including Swiss, has
CER increase ≤0.01 and meaningful WER increase ≤0.02 against both original and
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

Each guarded native launch is capped at 3,600 seconds, two threads, serial nice10
utility work, with a cancel marker and owned-session shutdown/reaping. Fresh
native idle/live-off inspection is required before inference. Active/uncertain
capture or known competing ASR/build/test/VM work stops owned research. The
prospective 1,000% raw per-process foreign CPU stop is an extreme-contention
guard on this 24-core shared desktop. Descriptor polling retains a capture-intent
race and does not prove real-time recording scheduling. No capture or foreign
application is stopped to run this study.

Resource acceptance remains **UNCONTROLLED / NOT EVALUATED**. Planned per-language
wall/load/RSS/outer-CLI RTF observations will retain measured counts and units;
no speed/memory improvement has been measured. First-result latency, total GPU
memory, energy, bundle increments and controlled thermals/load remain unmeasured.
Original audio/references, raw transcripts when produced, timings, models,
manifests and provenance stay protected externally, outside disposable retention.
The installed app, language switches, uncertainty and channel state are unchanged.

## Evidence identities

Protected receipts use `R3 = ~/Library/Application Support/RecScribe/Benchmarks/Research/112/round-3`;
raw corpus/model payloads are not included in this public report. Report drafting
read metadata and source only; it did not follow audio/reference/model/native-log
paths, execute recognition or inspect fresh held-out text. All hashes are SHA-256.

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
| All-five-held-out receipt | **PENDING** |
| Panel/development/held-out matrices, reports, assessments | **PENDING** |

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
| Public reporter / channel assessor | `121b097f00eff413a47b940ef71a91db55270a42e545ebdd919f97de3e169059` / `b2943432a35e6dd35365fd87cc8093d1e9ba52c5f2589b43b36adcfa9a6e9206` |
| Guard | `66ccbc45bd70ae9abee2b3fc6f796109e7f5b1c99fdeb91c1ae4f956b2a79f69` |
| Private coordinator / all-held-out sealer | `fd16363b1e5b9bebc0d0a68937d718d0297b050218252c2d9703292a25d1efa8` / `b9dad655a7026ecc4323eeab905e540d97879574be7273df8d68fa7c7d43f457` |

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

All quality decisions, per-language error counts, automatic-label outcomes,
balanced-F16 decoding identities and resource observations must be filled from
completed frozen evidence. Missing data or unexecuted checks remain pending.
