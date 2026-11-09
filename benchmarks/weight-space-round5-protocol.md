# Round 5: MLP neuron ordering before Q4 quantization

Prospective protocol, 2026-11-09. All four previous weight-edit families remain
rejected, with their artifacts, scores and consumed datasets unchanged. This is
one new no-training experiment under #112. A material gain is required; an
implementation, smaller Q4 file or lower reconstruction error is not success.

## Question and development rationale

Can a function-preserving permutation of Whisper's MLP hidden neurons improve
the grouping of weights in official Q4_0 blocks enough to retain original-F16
quality with the required improvement over ordinary Q4?

Earlier development studies did not establish a useful scalar/affine edit or
channel-balancing gain. Round 4 development rejected its attention-rotation
families; the fixed rotation left the MLPs untouched. Q4 groups 32 contiguous
input-axis values per output row. Reordering MLP output rows alone would not
change those groups, whereas a paired hidden-neuron permutation changes the
input-block geometry of the MLP down projection. This is a testable mechanism,
not a proven explanation of previous transcription errors. Consumed held-out
language errors do not select the order, layers, norm or recipe.

The [weight-space programming article](https://rikiyat.github.io/blog/weight-space-programming/)
motivates AI-authored reasoning and direct weight edits. Channel reordering has
primary research precedent in [RPTQ](https://arxiv.org/html/2304.01089v3), which
uses calibrated activation clustering and LayerNorm/weight fusion for LLMs.
This study instead uses a fixed weight-only ordering, with no activation
calibration, clustering, fitting or claim to reproduce RPTQ's results. Pinned
[whisper.cpp v1.9.5 quantization source](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/ggml/src/ggml-quants.c)
defines the actual Q4_0 encoding. Neither reference establishes Whisper gains.

## Fixed operator

For every encoder and decoder MLP in multilingual Small and large-v3-turbo,
write the original MLP as `W2 GELU(W1 x + b1) + b2`, with stored matrices viewed
as output-by-input. Compute one score per hidden neuron: the maximum absolute
value of its original W2 column, evaluated in F64 from the original stored
values. Sort ascending by `(score, original_neuron_index)`. There is no
configurable norm, reverse order, subset, seed or alternative candidate.

Let P map the new hidden ordering to those original indices. Apply:

```
W1' = P W1
b1' = P b1
W2' = W2 P-transpose
b2' = b2
```

Elementwise GELU commutes with a permutation, preserving the MLP in real
arithmetic. Move original F16/F32 scalar bytes without arithmetic or storage
conversion. This preserves signed zero and original scalar bits, but changed
reduction order in the native W2 product can change finite/logit/transcript
results. Actual numerical controls remain mandatory.

Only `.mlp.0.weight`, `.mlp.0.bias` and `.mlp.2.weight` participate, across all
declared blocks: 24 MLPs in Small and 36 in Turbo. GGML records input axis first:
W1 shape `(state, 4*state)`, W2 `(4*state, state)`, and b1 `(4*state)`.
State/layer/mel/vocabulary/context dimensions and dtypes must be validated from
the actual original file. LayerNorm, residuals, attention, convolution,
embeddings, vocabulary and all other byte regions remain unchanged. No runtime
operator, decoder policy, model dimension or parameter count changes.

The operator records every permutation, score definition, selected range,
original/output hash, actual changed scalar count and inverse-byte proof. It
uses the existing bounded GGML inspector with an explicit 4 GiB model limit,
one numeric worker, at most 8 MiB numeric workspace and 128 MiB process-RSS
admission limit. Each edit/export has a finite 600-second limit. Originals are
read-only, outputs are exclusive protected external directories, cancellation
is cooperative and partial/failure records remain retained.

## Arms and attribution

Each adapted family has four independently hashed arms:

1. Original multilingual F16, never modified in place.
2. Permuted F16, the numerical/control export.
3. Original-to-Q4_0, conventional compression control.
4. Permuted-F16-to-Q4_0, the combined candidate.

Untouched multilingual Tiny, Base and full Large-v3 remain references: eleven
artifacts total. All fixed artifacts advance regardless of development or static
diagnostic direction, unless a structural/hash/operational failure stops work.
There are no gradients, training, distillation, learned rotations, least-squares
reconstruction fitting, seed/layer/order sweeps or outcome-based replacements.

Use the same pinned official quantizer, Q4_0 only: file ftype 2002, tensor type 2,
32 values/18 bytes per block. The independent container audit verifies every
shape/order/type/offset, finite signed half scale, architecture/mel/vocabulary
prefix and official passthrough rule. Plain/permuted Q4 must have equal byte
lengths and layout. Quantization alone supplies file compression; permutation
adds neither parameter reduction, extra file saving nor a kernel-speed claim.

Before quality inference, independently verify:

- MLP first-projection Q4 rows and first biases equal the corresponding
  permutations of ordinary-Q4 rows and original bias bytes.
- Every unselected quantized tensor payload matches the ordinary control.
- Inverse-permuted dequantized MLP second projections can be compared to original
  F16 weights. Record per-layer and summed squared reconstruction error and
  relative Frobenius error for both Q4 arms, using the actual official bytes.

These diagnostics test packing geometry, not speech accuracy or importance.
They cannot choose a different norm/order/layer, veto a valid fixed arm based on
direction, or replace held-out quality. A Python quantizer is not substituted
for the official executable. Q3_K is outside this fixed experiment.

## Fresh data and isolation

Target 72 fresh development-validation and 144 fresh held-out sources: eight and
sixteen per priority language. Swiss German speech targets faithful written
Standard German, with the same per-language floors as German, French, Italian,
English, Arabic, Chinese, Spanish and Portuguese. Dialect spelling is separate.

Exclude all nine consumed manifests: original development, runtime sensitivity,
round-1 held-out, round-2 development/held-out and both round-3 and round-4
manifests. Exclude recorded IDs, original/prepared audio/reference hashes and
known speaker/session overlaps. Reserve new Swiss speakers globally across
both splits, excluding all 70 previously recorded IDs. Unknown FLEURS speakers
and sessions remain unknown; source split names do not prove independence.

Before network access, freeze the acquisition helper/wrapper, all exclusion
hashes, output and exact command. The fixed prospective bounds are 64 MiB per
FLEURS archive stream and Swiss prefix, at most 512 MiB aggregate network/output,
600 seconds and eight/sixteen sources per language. A CLI preflight must validate
the actual guard/worker `--output` contract without network or creating corpus
output. Failed packaging/admission records stay separate. No dynamic growth,
replacement or reduced count is silently substituted after a shortfall; any
completion requires a new prospective record preserving the original attempt.

The initial 512 MiB attempt stopped naturally at its exact network budget after
accepting all 192 FLEURS cases and zero Swiss cases. Its source, freeze, partial
manifests and failure remain immutable. A separately frozen Swiss-only completion
may fetch a fixed 64 MiB prefix with at most 96 MiB additional network, 128 MiB
new output and 600 seconds, for exactly eight development and sixteen held-out
cases. This makes the total campaign network ceiling 608 MiB. It excludes the
nine consumed manifests plus both partial manifests and the same 70 Swiss
speakers. It may neither refetch FLEURS nor replace those accepted cases. Final
manifests assemble their unchanged case objects with the 24 new Swiss cases;
any further shortfall remains pending rather than expanding these bounds.

Keep original and prepared audio, reference bytes, manifests, source archive/member
identities, timings and provenance externally protected. Opaque integrity and
leakage checks must pass all planned counts before held-out release. New held-out
reference content remains semantically uninspected during candidate preparation.
No pretraining exclusion, human/native approval or representative natural-condition
claim follows from hash separation or public short read speech.

Document Swiss canton metadata and actual FLEURS locale/script coverage:
de_DE/fr_FR/it_IT/en_US/ar_EG/cmn_hans_CN/es_419/pt_BR. Arabic locale is not dialect
adjudication; Chinese here means Mandarin/Simplified. Other scripts/regions,
critical-content fidelity, long-form/adverse/non-speech/overlap, switches and true
independent-channel/live coverage remain pending where absent. References are
never rewritten to obtain a better score.

## Fixed grid and quality bar

Use the unchanged comparison CLI and current-default runtime profile, recording
actual source/model/binary/library hashes and host/software fingerprints. Keep
two threads, no VAD, no prompt or cross-source text state, inherited beam/best-of
5 and temperature fallback increment 0.2, native Flash Attention and F16 caches.
Known mode uses the source base language (`de` for Swiss); auto is unrestricted.
The original c214a8e control source/CLI/models remain recoverable and unchanged.

| Stage | Sources | Modes | Repeats | Native calls | Parent pairs | Derived Q4 contrasts |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Original-development numerical/timing panel | 9 | known + auto | 3 | 594 | 324 | 108 |
| Fresh development validation | 72 | known | 1 | 792 | 432 | 144 |
| Fresh held-out | 144 | known + auto | 1 | 3,168 | 1,728 | 576 |
| Total | | | | **4,554** | **2,484** | **828** |

The 1,242 reference-only placeholders remain separately unpaired. Sibling Q4
contrasts reuse canonical rows and add no calls or independent speech. Quality
uses successful repeat 1 only, never a later-repeat fallback. Panel repetitions
measure numerical variation, not additional independent utterances.

Freeze operator, artifacts, settings, scoring, budgets and all fifteen preplans
before quality inference. All ten panel/development grids must be terminally
attempted and assessed before all five held-out final plans seal together.
No measured cell is retried. Known finite native-format failures remain raw and
unscored under the unchanged forensic contract; unknown/setup/hash/capture/
timeout/cancellation failures stop owned work. A complete attempt count is not
complete quality coverage.

Independently for Small and Turbo in known/auto modes, retain the previous bar:

- At least 10% relative macro CER and 5% relative macro WER gain versus plain Q4.
- Versus original F16, macro CER increase at most 0.0025 and WER at most 0.005
  (absolute 0.25/0.50 percentage points).
- Every language versus both controls: CER increase at most 0.01 and meaningful
  WER at most 0.02 (one/two points). No extra Swiss veto.
- Zero newly wrong coarse automatic base-language labels against either control;
  unknown language evidence cannot pass or prove switching/fallback.
- At least 65% actual model-file saving versus original F16, attributed to Q4.
- Permuted F16 must match original hypothesis hashes and auto labels in all
  three numerical-panel repetitions. Do not relax this after observations.

Use unchanged explicit legacy-v1 normalization: per-language summed errors/units,
equal nine-language CER/eight-language WER means, Chinese whitespace WER omitted.
Missing planned coverage keeps full rates/macros/gates unknown and partial
observations separate. A known failed gate rejects despite other unknowns.
These are practical material-effect thresholds, not statistical-significance
claims; numerical success alone does not promote a model or default.

## Operation, validation and reporting

Run serially at nice 10 with capture taking priority, under the unchanged inspected
owned-session guard. A fresh native RecScribe idle/live-off check admits this
fixed campaign before actual model initialization or ASR; per-stage capture,
uncertainty and competing-work probes continue. A later lock alone does not
create another admission request for the unchanged campaign. No installed-app
replacement, privacy/signing change or active-capture interruption is included.
Retain finite 3,600-second non-held/10,800-second held stage bounds, 60-second
supervisor grace, one-second polling and the explicitly inherited extreme-CPU
policy. Descriptor polling is not a hard real-time scheduling guarantee.

Before inference, run meaningful algebra/byte/shape/source/cancellation/owned-
publication contracts; official-export/dequantization/row-equivariance negatives;
actual model-free packaged assessor/failure/reference/terminal/sealer CLI writes;
static/native loading checks; mandatory native/frozen-reference checks and full
complete-PR CI. Preserve original and failed evidence; never rebaseline fixtures
or weaken acceptance to get a pass. Reuse build caches/Build/Products and managed
temporary work under work-artifacts.py; protected corpora/models/raw results
remain outside disposable retention. Reserve at least 10 GiB external free space.

Reports retain all per-language rates, denominators, nulls and gate observations;
actual bytes, wall/load/RSS distributions and proper observation counts; and
pooled workload RTF rather than medians of language medians. Shared-desktop
resources remain UNCONTROLLED / NOT EVALUATED. Full initialization/first result,
total unified GPU memory, energy and actual download/bundle increments remain
unmeasured until separately executed. Native/v2/product and broader natural,
switch/live/independent-channel acceptance stay pending. No automatic merge,
default selection or distribution change.
