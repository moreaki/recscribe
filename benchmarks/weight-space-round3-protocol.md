# Round 3: activation-aware channel balancing before weight quantization

Research under #112/#103. Prospective protocol, 2026-11-06. No round-3
activation calibration, candidate inference or held-out outcomes have run when
this design is authored. Original controls and both consumed held-out sets stay
unchanged. Candidate and execution seals follow implementation/static review.

## Hypothesis and material benefit

Rounds 1–2 rejected blanket attention gains and a static affine-bias heuristic.
Static weight norms did not establish a beneficial error mechanism. This study
tests a different, analytically motivated mechanism: activation-aware channel
scales may reduce **weight-only quantization error** without changing the
floating-point function in real arithmetic. The AI authors the fixed mapping,
folds it into actual derived pretrained weights and audits the stored bytes.
No gradients, optimizer, reconstruction fitting, gain search or training occurs.

This is inspired by [AWQ](https://arxiv.org/abs/2306.00978v6), rather than a
reproduction of its scale-search method or evidence of a Whisper improvement.
The [weight-space programming article](https://rikiyat.github.io/blog/weight-space-programming/)
motivates reasoning about specific mechanisms; its results do not establish
Whisper gains. A small parameter count is not evidence that a checkpoint has
reached an information-theoretic optimum. Untouched Turbo/full Large-v3 provide
larger-model quality/resource references, without being treated as trained
teachers or a proven upper bound.

The four arms for **each** multilingual Tiny/Base/Small are:

1. Original F16 artifact, unchanged.
2. Balanced F16, to test the numerical/function-preservation control.
3. Original → ordinary official `q5_1` export, a conventional compression control.
4. Balanced F16 → the **same** `q5_1` exporter, the combined candidate.

Changing standard models requires a material advantage. Per model and language
mode, the balanced quantized arm must improve macro CER by **at least 10%** and
meaningful-language macro WER by **at least 5%** relative to ordinary Q5. It must
also preserve quality against its original F16 parent within the separate
budgets below and save **at least 50% actual model-file bytes**. Conventional
quantization alone is never reported as an AI-adaptation gain. An accuracy-led
edit against an original model would need the same 10%/5% gain targets; this
compression study does not imply that original-F16 accuracy improved.

## Fixed activation calibration and operator

Use only the **original 27 development recordings**, three per priority language,
for calibration. Neither consumed held-out set nor new validation/held-out data
selects scales. The diagnostic native source is pinned to whisper.cpp v1.9.5
commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`; the isolated probe records its
source/build/binary/backend/model hashes. It does not replace the installed app
or quality-comparison backend.

For each Tiny/Base/Small and each of the 27 recordings, encode once and evaluate
the same teacher-forced prefix twice, callback off/on, with KV state reset.
Prefix: SOT, known base language (`de` for Swiss), transcribe, no-timestamps,
then at most the first **60 published-reference tokens** (at most 64 positions).
No generated-token search or label-specific adjustment. Retain reference/audio,
tokenization/prefix hashes and actual token counts privately. Sources must be
mono PCM16, 16 kHz, at most 30 seconds; missing/long inputs fail visibly.

Require bitwise-identical prefix logits off/on before accepting statistics.
Record maximum differences and argmax disagreements even on failure. Failure
leaves calibration pending; do not relax this gate or switch algorithms merely
to get usable data. Maximum: **81 encodes and 162 decoder-prefix batches**.

Observe only each decoder block's **post-affine LayerNorm output**, after gamma
and beta, immediately before:

- `attn_ln` → self-attention Q, K **and** V;
- `cross_attn_ln` → cross-attention **Q only** (K/V consume encoder output);
- `mlp_ln` → first MLP linear (`mlp.0`), before GELU.

Record per-channel sum absolute value, sum squares, maximum and valid position
count, with finite/shape/site/recording bounds. No padded positions. For each
site/channel compute its mean absolute activation separately per recording,
then the equal mean over the 27 recordings (three per language). Let this be A.
For positive channels, G is their geometric mean and
`s = clamp(sqrt(A / G), 0.25, 4)`. Exactly-zero channels get s=1 and are excluded
from G; an all-zero/missing/nonfinite site fails. One fixed rule; no search,
backoff, clipping sweep, per-language weights or outcome-based replacement.

Fold `gamma' = F32(gamma / s)`, `beta' = F32(beta / s)` and multiply every
receiving input-channel weight by s with original F16 rounding. Receiving
linear biases are unchanged. In row-vector notation `x' = x D^-1`, `W' = D W`;
real-arithmetic linear outputs match. Audit GGML's first-axis-contiguous input
dimension explicitly. Never move scales through GELU, edit encoder weights,
tied embeddings, cross-attention K/V or second MLP/output weights. Stored
F16/F32 rounding and kernel behavior still require actual controls.

Only the exact unquantized Tiny/Base/Small layouts are supported. Stream edits
with finite/overflow, timeout/cancellation, source-identity and unchanged-region
checks. Originals are read-only; every output is a new external artifact.
Freeze full scales, input/output hashes, audits and exporter identity before
candidate outcomes. Quantization uses the existing official exporter and q5_1
only, without tuning quantization format after scores.

## Fresh data and finite comparison plan

Acquire **72 new development-validation and 144 new held-out recordings**:
eight and sixteen per language respectively. Pin FLEURS and FHNW releases and
deterministic source/member order. Exclude all prior IDs, original/prepared
audio hashes, reference hashes and known speakers/sessions, including both
consumed held-outs and round-2 development. Exclude overlap between new splits.
Freeze the acquisition rule and initial **512 MiB network / 512 MiB output**
budgets, 32 MiB source prefixes, per-source/duration limits and cancellation.
Insufficient data/budget is pending with partial evidence retained, not a reason
to silently reuse old data or increase bounds after outcomes.

Hold-out reference text and ASR outcomes remain opaque until the entire family,
settings, data identities, budgets and analysis code are sealed. Hashes/metadata
may be inspected for leakage/integrity. Both earlier held-outs remain consumed.
New FLEURS dev/test and FHNW public/private supply the splits. Known Swiss
speakers are excluded; unknown FLEURS speakers and sessions stay unknown.

Use the existing matrix runner and exactly one unchanged decoding profile:
two threads, serial utility work, temperature 0, context 0, VAD off, no prompt,
inherited pinned-backend search/fallback. Every native argument/hash is retained.
The original c214a8e source/CLI/five model baselines remain recoverable. A new
hashed runner permits a **prospectively declared one-repeat quality matrix**;
historical/default three-repeat plans stay unchanged. Quality always uses only
successful repeat 1, never a later-repeat fallback or selective retry.

There are 14 artifacts: four arms × three small models plus untouched Turbo and
full Large-v3. Bound every guarded launch to 3,600 seconds and partition before
execution, by small-model family or individual large reference:

| Stage | Sources | Modes | Repeats | Inference cells | Native parent pairs |
| --- | ---: | --- | ---: | ---: | ---: |
| Fixed original-development timing/numerical panel | 9 | known + auto | 3 | 756 | 486 |
| New development validation | 72 | known | 1 | 1,008 | 648 |
| Fresh held-out | 144 | known + auto | 1 | 4,032 | 2,592 |
| Total | | | | **5,796** | **3,726** |

Five partitions per stage: Tiny/Base/Small (four arms each), Turbo, full Large.
Native comparisons retain each derived arm's actual original-F16 parent.
The assessor separately derives matched balanced-Q5 versus ordinary-Q5 pairs
from the same source/runtime rows; it never relabels Q5 as untouched pretrained.
Their 1,242 possible panel/development/held-out comparisons are a distinct
contrast, not additional independent speech or native parent pairs.

All fixed artifacts proceed to evaluation regardless of development direction,
with failed/inconclusive control status retained. No posthoc cross-model winner,
replacement recipe, undocumented resume or partial-run deletion. Seal every
held-out partition together before the first held-out outcome.

## Scoring and prospective decisions

Keep explicit exploratory `swift-nfc-casefold-alphanumeric-v1`. Native-approved
v2/strict Arabic remains pending. Count errors/units within language, then equal
means over nine CER languages and eight meaningful WER languages; Chinese
whitespace WER is unreported. Keep known and auto results separate for each
model. Missing/failed/unknown planned cells cannot pass.

- AI effect: balanced Q5 versus ordinary Q5 must meet ≥10% relative macro CER
  and ≥5% relative macro WER reductions independently in each mode.
- F16 quality floor: balanced Q5 versus original may increase macro CER by at
  most **0.0025 absolute** and macro WER by **0.005 absolute**.
- Every language, including Swiss, has the same regression caps against both
  original F16 and ordinary Q5: CER increase ≤**0.01 absolute**, meaningful WER
  increase ≤**0.02 absolute**. Swiss has no additional zero-increase veto in
  this new study, reflecting the user's prospective product priority.
- Keep Swiss speech → published written Standard German as its explicit task.
  Do not rewrite completed experiments' stricter gates or negative decisions.
- Automatic mode: zero newly wrong coarse base-language labels against either
  control; unknown/empty/ambiguous evidence is inconclusive. A repair cannot
  conceal a new mismatch elsewhere. This is not human dialect/switch accuracy.
- Model file saving ≥50% relative to own original; actual download/container,
  installed/bundle increments and parameter/precision/layout are separate facts.
- Balanced-F16 numerical panel requires matching canonical transcript hashes
  and observed automatic labels against its parent in **all three panel repeats**.
  Otherwise mechanism-control
  status is inconclusive even if the combined artifact's lexical scores improve.
- Critical content/native fidelity, recording priority, uncertainty, switching,
  multilingual fallback and independent-channel acceptance remain required for
  any product decision; lexical gains do not establish them.

A failed numerical gate rejects the candidate for promotion. A numerical pass
means continue research only while native/representative/grouping/controlled
resource and real live/channel gates are unresolved. All results, including
ordinary compression outcomes, remain reportable; no automatic default change.

## Resource scope and preservation

Reuse the recorded host/software and freeze a fresh inventory. Report per-language
wall/load/RSS/outer-CLI RTF distributions, the larger references and actual bytes.
The three-repeat panel measures variation; full quality matrices with one repeat
cannot claim repeat stability. The shared desktop does not provide controlled
CPU/GPU/thermal isolation: resource acceptance remains **NOT EVALUATED**.
First-result latency, total GPU memory, energy and assembled bundle increments
stay unmeasured unless a separately declared measurement actually executes.

Before inference inspect the exact installed app as idle/live-off. Use a frozen
owned-session guard with cancellation markers, finite launches, no selective
retry and capture/uncertainty/competing-heavy-work stops. Never stop capture or
foreign applications to run the study. Existing descriptor polling has a
capture-intent race and is not proof of real-time capture scheduling.

The operational foreign-process CPU stop remains the round-2 value of **1,000%
raw per-process CPU**, selected before inference. It is an extreme-contention
stop on this 24-core host, not a controlled CPU/GPU/thermal measurement. Known
foreign ASR/build/test/VM processes and active/uncertain recording still stop
owned work independently of that threshold. Guard defaults must not silently
replace the study's explicitly recorded argument.

Preserve original audio, references, raw transcripts, source timings, manifests,
models and provenance externally. Follow AGENTS.md for managed disposable logs,
existing caches, product locations, mandatory frozen contracts and full CI.
No installed-app update, model distribution, packaging, merge or default change.
