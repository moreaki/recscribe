# First AI weight-space pilot protocol

Research issue: #112; corpus/controls: #104/#105. Written on 2026-11-05 before
any candidate model was evaluated or held-out reference/outcome was inspected.
This is an exploratory pilot, not a promise of an improved or shippable model.
The portable [three exact recipes and reproduction commands](weight-space/round-1/README.md)
are checked in separately from protected model artifacts and recognition results.

## Available evidence and limits

The acquired development set has 27 utterances, three per priority language,
totalling about 304 seconds. FLEURS supplies eight language slices; FHNW All
Swiss German Dialects supplies Swiss speech with written-German references.
Published human references and original audio are retained externally. Speaker/
session gaps, absence of native adjudication, short/read-speech domain and
possible public-pretraining overlap prevent a representative product claim.
The blind holdout is separate and is not used for hypothesis selection.

Untouched controls retain source c214a8ed03f972a5a9cab64105145a67371b97b4,
the original CLI hash and all five multilingual model hashes. The active pilot
uses the explicitly labelled legacy lexical scorer; Chinese results use CER,
not its whitespace WER. Numeric/format equivalence and critical meaning need
separate review; a rendering such as a percent sign can differ lexically while
preserving content. Swiss speech is scored against written Standard German.

Initial Tiny development outputs show acoustic/content substitutions, including
an Italian year changing from 1939 to 1989 and a German quantity rendered with
different numeric grouping. These are hypothesis inputs, not evidence of a
particular internal cause. Names and morphology also show errors. Repetition
has not been established as the dominant failure in this pilot.

Read-only inspection of the actual Tiny artifact found four encoder and four
decoder layers, width 384, six attention heads, 167 tensors and 37,760,640 stored
elements (including positional tensors). All scanned values were finite. Static
weight norms describe the artifact but do not establish a causal failure.

## Candidate hypothesis and actual edit

Test whether modestly increasing the decoder's acoustic cross-attention residual
contribution improves content recognition in Tiny. The architecture routes audio
through decoder cross-attention and autoregressive text through self-attention;
changing their relative contribution may change acoustic conditioning. The
observed errors and inspected architecture motivate the test. The hypothesis
may be false, and the edit may degrade quality or language identification.

The first AI-authored edit scales only
`decoder.blocks.{0,1,2,3}.cross_attn.out.weight` by **1.10**, retaining the original
FP16 shape, tokenizer, vocabulary, biases and every unselected byte. This changes
at most 589,824 selected elements, about 1.56% of stored elements, within the
tool's explicit bound. Scaling the matrix without its bias tests the audio-
dependent residual contribution rather than amplifying a constant bias.

The factor is a declared modest exploratory intervention, not a learned optimum
or a proven mechanistic repair. No gradient, optimizer or training loop is used.
The AI supplies the precise tensor recipe. The local tool applies it to a new
derived file only, validates finite values/layout and unchanged byte regions,
and retains original/derived/recipe/tool hashes plus an edit audit.

The model dimensions and file size remain unchanged. This is an accuracy-oriented
weight experiment; no compression, memory or speed gain follows from the edit.

## Comparisons and development decisions

Compare the unchanged Tiny artifact and edited artifact through the same current
CLI, baseline decoding profile, Whisper binary/backend, audio preparation,
language mode, thread budget, source/reference/scoring hashes and repeat plan.
The separately retained original CLI controls remain available to detect wrapper
differences. Keep original and edited artifact hashes distinct and verify their
declared lineage. Preserve every failed/cancelled/partial result.

The initial diagnostic comparison may use one source-ID-selected development
utterance per language to bound runtime. Selection is made before candidate
results and does not choose the easiest/best-improving case. It is not equivalent
to the full 27-utterance baseline. A promising candidate must be expanded to all
development utterances before a held-out quality claim.

Provisional exploratory screening thresholds, chosen before candidate results:

- Primary screening uses known-language mode. Macro CER means the arithmetic
  mean of the nine per-language corpus-weighted CERs from successful repeat 1;
  automatic-language mode is assessed separately and is never pooled with it.
  Seek at least a 5% relative reduction, with per-language denominators shown.
- Require successful matching parent/candidate cells in every selected slice.
  A missing/failed pair makes screening inconclusive rather than a pass; do not
  remove it from the planned language/sample denominator.
- Reject the current candidate for promotion if any language CER increases by
  more than 0.02 absolute, a newly reviewed critical-content error appears, or
  automatic-language behavior loses intended coverage.
- Report WER for meaningful whitespace scripts and CER independently; do not
  combine Chinese whitespace WER with other languages. Report content review
  status explicitly, including missing native review.
- Unperformed native/critical-content review remains review-unresolved. Missing
  review does not establish the absence of new critical errors and cannot be a
  promotion pass.
- Flag more than 10% median end-to-end runtime/RSS regression against the paired
  parent, with raw ranges and sample counts. Small samples do not prove a timing
  or memory improvement. Model/download size is expected to stay identical.

Record the exact diagnostic source IDs and hashes before candidate results.
The maximum three predeclared recipes are all-layer gain 1.10, all-layer gain
0.90 as a directional control, and last-decoder-layer-only gain 1.10 as a
localization control. Preserve every result, including regressions. This fixed
family tests the hypothesis without an optimizer or an unbounded parameter search.

These are screening rules, not product acceptance budgets. The current sample
cannot establish statistical equivalence or broad multilingual gains. At most
three manually reasoned development recipes belong to this first pilot; record
all tested/rejected recipes and their rationales. Model-order/cache/thermal drift
and changed decoded lengths can affect runtime; show length/variation evidence
and treat the 10% flag as a screening observation, not a speed proof. Do not silently select only
successful languages, change references or retune on held-out outcomes.

## Compression control and held-out gate

Separately evaluate a supported quantized export of the unchanged Base model as
a conventional compression control, if local budget permits. This is distinct
from AI weight adaptation. Compare it with its untouched Base parent under the
same settings, then show its tradeoff against Tiny as a model-selection result.
Verify actual artifact bytes/hash and runtime compatibility. A smaller file is
not evidence of faster decoding, lower total GPU allocation or higher accuracy.

Before any held-out candidate evaluation, freeze exact model/recipe/runner/
profile/corpus hashes, the selected candidate and explicit quality/runtime/size
budgets. Keep the holdout source/reference separation and sampling rule intact.
An automated research freeze is not native human adjudication or release
approval. If development candidates fail screening, publish the negative result
and retain the blind holdout for a later independent hypothesis.

Bundled-default selection remains pending representative long-form/adverse/
regional coverage, critical-content review, supported export/runtime, actual
package measurements, redistribution review and current-head validation. Keep
existing model selection/downloads and installed app unchanged during research.

## Execution-policy amendment before edited-model outcomes

On 2026-11-05, the initial guard stopped after six unchanged-Tiny cells when a
Firefox process reached 89.2% raw `ps` CPU (about 0.89 of this host's 24 cores).
No edited model had run. The partial matrix, raw evidence and guard observation
remain preserved. That cancellation also exposed a CLI signal-handler executor
crash; the fresh paired run must use the corrected CLI for every parent and
derived artifact.

The replacement diagnostic is explicitly **quality-only** under ordinary desktop
load. Its per-process CPU stop threshold is 300% raw (three cores, 12.5% of host
capacity); this is not an aggregate CPU budget or evidence of an idle GPU.
Recording, uncertain capture state, foreign ASR/build/test work and VM guests
still cancel the owned experiment. Exact guard policy and runner identities are
locked before the first edited-model outcome. Recipes, source IDs, scoring,
decoding settings and quality-screening thresholds remain fixed.

Retain timing and process-RSS observations, but mark the earlier 10% runtime/RSS
gate **not evaluated** for this diagnostic. Shared desktop-load measurements
cannot establish a speed/memory pass. Native critical-content review and all
product-promotion gates remain unresolved. A later controlled resource comparison
requires a fresh matching parent/candidate experiment, with this history retained.
