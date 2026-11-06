# Round 2: localized affine-bias adaptation of smaller Whisper models

Research issue: #112, under #103–#108. Authored 2026-11-06 before any round-2
candidate inference. This is a bounded no-training experiment, with a genuinely
new utterance holdout and an explicit negative-result path. It changes no app
default, installed model, audio, reference or UI.

## What round 1 taught us

The round-1 development macro-CER gain hid word-level regressions; the selected
candidate subsequently failed its sealed evaluation. That consumed heldout is
excluded from development and from the new evaluation set. Its transcripts and
references do not select the new tensor/head/gain. Original development failures
and the public decision identify the need for smaller, localized interventions,
explicit WER gates, more utterances and a numerical mechanism control. A negative
result for one blanket-gain recipe does not establish that all weight edits fail.

## Fixed hypothesis and architecture evidence

Test whether reducing one decoder cross-attention head's **input-independent
value-projection offset** by 10% improves transcription. In a softmax attention
head, the weights sum to one: the value bias contributes a constant offset
through that head's output-projection columns. This affine term can be isolated
algebraically. It is distinct from scaling the audio-dependent output matrix.
The implementation mapping follows the pinned
[whisper.cpp v1.9.5 attention path](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp)
and [GGML exporter](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/models/convert-pt-to-ggml.py):
stored dimensions are reversed from the original output-by-input matrices.

For each original multilingual tiny, base and small model, inspect all decoder
cross-attention heads. Select exactly one by the largest static ratio
`||O_h bV_h||_2 / ||O_h V_h||_F`, breaking ties by lower layer then lower head.
The ratio is an affine-weight proxy, under no measured activation distribution;
it is not attention saliency or proof of a hallucination mechanism. No pruning,
language-token masking, alignment-head exclusion or language-specific edit is
performed. Published DTW head lists do not establish causal safety.
Redistributing constant terms between value/output biases can leave the same
function with a different ratio, so it is also not an invariant importance score.

Frozen original-weight inspection selected:

| Model | Layer / head, zero based | Value-bias start / count | Ratio |
| --- | --- | --- | --- |
| Tiny | 0 / 3 | 192 / 64 | 0.5686863248 |
| Base | 0 / 2 | 128 / 64 | 0.7713859626 |
| Small | 5 / 3 | 192 / 64 | 0.3586331067 |

One candidate per model scales only that 64-element F32 value-bias range by
**0.90**, with original F32 rounding. No parameter search, further head choice,
gain sweep, gradients, optimizer, fine-tuning, distillation or training is used.
The operator and all three model applications are fixed before outcomes.
Original shapes, vocabulary, other weights and model size remain unchanged.

For each model retain a separate compensated control: apply the same rounded
bias change and subtract its projected delta from the matching output bias,
`bO' = F32(bO - O_h (bV' - bV))`. This restores the real-arithmetic affine
function, subject to F32 arithmetic/order differences. It is a numerical/layout
control, not an exact bitwise equivalence claim. The selected compensation
requires at most 769 explicit edit operations and 832 selected scalars. The
existing byte-audited GGML tool remains the artifact writer.
Verify compensation residuals from final stored F32 bias values and record the
GGML-to-matrix orientation: V head output rows and O head input columns.
The pinned runtime can cast cross-attention values into its KV cache and use
fused/reordered arithmetic. Those operations can introduce input-dependent
rounding even when the weight-level affine residual is tiny. Only the actual
paired control inference can assess transcript stability; the static residual
must not be presented as proof of runtime equivalence.

## Sources, exclusions and two new splits

The 27 original development utterances may inform hypothesis design. The
original nine-source development diagnostic, selected before round-1 outcomes,
provides a fixed small numerical-control check only.

Acquire **eight new development-validation utterances and eight fresh heldout
utterances per language**: 72 + 72 sources across Swiss German, German, French,
Italian, English, Arabic, Mandarin/Simplified Chinese, Spanish and Portuguese.
Use the pinned public source releases and documented deterministic member order.
Before retention, exclude every previous source ID, original/prepared audio hash,
reference hash and all known prior Swiss speaker IDs, including the consumed
round-1 heldout. Also exclude overlap between the two new splits. Retain the
selection rule, source/archive/range metadata, exclusion ledger and hash audit.

Original audio, raw published references, prepared PCM, source timings and
provenance remain protected externally. The new heldout references and recognizer
outcomes stay opaque to candidate development. Metadata/hashes may be inspected
to validate freshness; do not display or interpret reference text. Missing data
is pending, not silently replaced with used data or invented groups.

FLEURS individual speakers and all sessions remain incompletely known. New
utterances are not proof of new independent speakers or absence from pretrained
data. Swiss speech targets published written Standard German, with native
rendering review still unresolved. Arabic ar_eg read speech does not establish
Egyptian dialect coverage; Chinese is Mandarin/Simplified, Spanish es_419 and
Portuguese pt_BR. Natural adverse/long-form/non-speech/switch/overlap and broader
regional/script coverage remain pending.

## Finite run plan

Use the retained, hashed release CLI from source
`4b71f4da65d23cab1538c6f3d0a2fa9bd2d1daf2` for both parent and variants.
Retain the unchanged source `c214a8ed03f972a5a9cab64105145a67371b97b4`,
original CLI and all five required multilingual controls separately.
Record native runtime/library/model/recipe/tool hashes before execution.

1. Numerical controls: nine original development sources × three models ×
   parent/compensated control × known/auto × three repeats = **324 cells**.
   Require finite/layout/unchanged-byte checks, compensated affine residual
   L2 ≤1e-6, and identical repeat-1 canonical hypothesis hashes/coarse automatic
   labels on each planned matched case. Missing/failed comparisons are
   inconclusive. A differing transcript makes that model's mechanism-control
   gate inconclusive; retain it and do not attribute a subsequent gain to a
   proven-isolated mechanism.
2. New development-validation: 72 sources × three models × parent/candidate ×
   known mode × three repeats = **1,296 cells**. This set assesses the fixed
   family; it does not optimize gains, heads, references or another recipe.
   An execution-only amendment before any development-validation inference
   partitions this into three **432-cell model matrices** under the unchanged
   3,600-second launch limit. The original unexecuted aggregate configuration
   remains preserved as superseded. Sources, artifact hashes, settings, repeats,
   gates and the 4,212-cell total are unchanged; no partial run is retried.
3. Freeze all three candidates, settings, scoring, source/hash identities,
   control status, budgets and selection history before opening heldout outcomes.
   The fixed family is independently evaluated regardless of development
   direction, with each model's development status retained. This is a
   predeclared replication experiment, not selection of a posthoc best model.
4. Fresh heldout: 72 sources × three models × parent/candidate × known/auto ×
   three repeats = **2,592 cells**. Report every model/language/mode and failure.
   No retuning or second blind claim on this consumed set afterward.
   Partition this step into three predeclared 864-cell model matrices, each with
   its own configuration/freeze binding, to bound each guarded launch. The family
   freeze binds all three before the first heldout outcome, so later partitions
   cannot change their recipes, settings, cases or budgets in response.
   The pre-inference family seal also binds all diagnostic/development partition
   configurations and their planned cells. No later best-model selection is used.

Total maximum **4,212 inference cells** plus static inspections/exports; at most
three candidate artifacts and three compensated controls. Each stage uses new
output directories, no selective retries, serial two-thread inference, and a
finite timeout of at most 3,600 seconds per guarded launch. An interrupted stage
remains partial; a separately declared fresh run must retain its predecessor and
the same candidate identities. No undocumented resume or relaxed quality gate.

## Scoring, gates and decision rules

Keep the explicitly exploratory `swift-nfc-casefold-alphanumeric-v1` policy
unchanged for comparability. Chinese whitespace WER is unreported; CER is primary
there. Native-approved v2 scoring remains a separate pending gate. Successful
repeat 1 alone supplies quality. Repeated inference supplies variation and
descriptive timing; it does not add independent utterances.

For **each model separately**, compare its candidate with its exact parent:

- Primary known-mode equal-nine-language macro CER must fall by at least 5%
  relative. Report corpus-weighted per-language rates and denominators; never
  pool tiny/base/small or known/auto modes into a winning average.
- No language CER may increase by more than **0.01 absolute**.
- Mean of the eight meaningful per-language WERs must improve by at least **2%
  relative**; no individual WER may increase by more than **0.02 absolute**.
- Swiss written-German WER must **not increase at all**, independently of CER.
  Arabic/Spanish CER gains cannot cancel their WER losses. Report insertion,
  deletion and substitution counts where recorded.
- The heldout automatic mode must separately satisfy the same lexical gates,
  with zero newly wrong coarse published-source base-language labels. Missing,
  empty, ambiguous or multi-pass labels remain unknown/inconclusive, not correct.
  Label agreement is not dialect/switch/fallback/confidence accuracy.
- Complete planned paired coverage and valid immutable identity checks are
  required. Missing/failed/null evidence cannot be dropped from the denominator
  to turn a failure into a pass.
- Native review of names, quantities, negation, omissions and invented speech is
  unresolved. No newly introduced critical error is acceptable for promotion;
  absent adjudication is not a critical-content pass.

A model is rejected for promotion when a numerical gate fails. A numerical pass
is **continue research**, not release approval, while native review, grouping,
representative coverage, real independent-channel/live replay and controlled
resource gates are unresolved. All tested/rejected artifacts and negative
results remain preserved. No bundled default is selected by this protocol.

## Recording priority, resources and delivery

Immediately before inference inspect the exact running installed RecScribe:
recording idle and live transcription off. Freeze the same owned-session guard
source/hash for every stage. It uses bounded fail-closed process/file probes,
cancels on active/uncertain audio writes or known competing ASR/build/test/VM work,
and escalates only within the experiment's owned session. Keep serial utility
work, cancellation markers, finite timeouts and original/raw evidence.

The unchanged **1,000% raw per-process CPU stop threshold** is an extreme
contention gate, not an aggregate CPU/GPU/thermal isolation measurement. Polling
audio descriptors is not an authoritative capture-intent scheduler and leaves
a detection/shutdown race. Never stop capture or user applications to benchmark.
If capture or competing heavy work starts, cancel owned research and retain
partial evidence. Capture priority needs a future machine-readable intent/lease
before audio-file creation; do not pretend the current polling proves that.

This is a **quality-only shared-desktop experiment**. Preserve per-language
wall-time/load-timer/process-RSS observations, actual model bytes and ranges, but
mark controlled runtime/RSS acceptance **NOT EVALUATED**. First-result latency,
total unified GPU allocation, energy and assembled bundle increment remain
unmeasured. Bias edits do not reduce model parameters or storage layout.

Follow AGENTS.md: managed disposable logs, protected external persistent data,
existing build caches, mandatory frozen references and full current-head CI.
No installed-app replacement or UI changes. No automatic merge, model
distribution or default migration.
