# Quantized Whisper held-out results — 11 November 2026

**Full Large-v3 Q4 is the promising compression candidate:** its model file falls
from 3,095,033,483 to 889,340,843 bytes, a **71.27% saving**, while passing every
frozen lexical quality bound in both language modes and all nine languages.
Independent native reference review and broader confirmation remain pending.

All six frozen quantized artifacts exceeded the 30% model-file saving requirement.
The comparisons below use each artifact's own F16 parent. These short read-speech
results do not establish semantic/translation equivalence or product acceptance.

| Candidate | File saving | Known language | Automatic language |
| --- | ---: | --- | --- |
| small-q4_0 | 70.17% | fail_exploratory; parent gaps | fail_exploratory; parent gaps |
| small-q5_1 | 61.02% | fail_exploratory; parent gaps | fail_exploratory; parent gaps |
| large-v3-turbo-q4_0 | 70.82% | fail_exploratory | fail_exploratory |
| large-v3-turbo-q5_1 | 61.59% | fail_exploratory | fail_exploratory |
| large-v3-q5_1 | 61.97% | fail_exploratory | fail_exploratory |
| large-v3-q4_0 | 71.27% | pass_exploratory | pass_exploratory |

`pass_exploratory` requires all macro and language bounds; it is not a native-review or distribution approval. `fail_exploratory` can reflect an observed degradation or uncertainty wider than the fixed margin. Small additionally retains two cancelled parent first outcomes (known Arabic/automatic French), with no retry or lowered source requirement.

Small also has complete-language failures: Q4 known-French WER rises 3.628pp,
with a 7.048pp upper bound versus the 2pp limit. Both Turbo variants miss the
primary CER bound and language floors in both modes. Turbo Q5 Arabic CER rises
1.436pp. Large Q5 passes both primary macro bounds but misses the Arabic WER
bound in both modes: +1.049pp point / +2.555pp upper versus the 2pp limit.
These results do not depend only on the separate Swiss floor. The ordering of
Q4 and Q5 on this small panel is not evidence that lower precision always helps.

## Fixed quality comparison

[Exact counts, bounds, identities and provenance](quantized-quality-results-2026-11-11.json) · [Per-language quality/latency/RSS](quantized-quality/language-tradeoffs-2026-11-11.md) · [CSV](quantized-quality/language-tradeoffs-2026-11-11.csv) · [Frozen protocol](quantized-quality-protocol-2026-11-10.md). Rates are errors/reference units; deltas below are percentage points, candidate minus F16. Smaller is better.

| Candidate | Mode | Primary CER delta / 95% upper | Primary WER delta / 95% upper | Complete pairs |
| --- | --- | ---: | ---: | --- |
| small-q4_0 | known | pending | pending | False |
| small-q4_0 | auto | pending | pending | False |
| small-q5_1 | known | pending | pending | False |
| small-q5_1 | auto | pending | pending | False |
| large-v3-turbo-q4_0 | known | 0.517 / 0.851 | 0.213 / 0.766 | True |
| large-v3-turbo-q4_0 | auto | 0.517 / 0.844 | 0.213 / 0.750 | True |
| large-v3-turbo-q5_1 | known | 0.311 / 0.562 | 0.456 / 0.899 | True |
| large-v3-turbo-q5_1 | auto | 0.311 / 0.566 | 0.456 / 0.886 | True |
| large-v3-q5_1 | known | -0.003 / 0.128 | 0.021 / 0.295 | True |
| large-v3-q4_0 | known | 0.060 / 0.149 | 0.288 / 0.596 | True |
| large-v3-q5_1 | auto | -0.003 / 0.127 | 0.021 / 0.295 | True |
| large-v3-q4_0 | auto | 0.060 / 0.152 | 0.288 / 0.596 | True |

Primary CER equally weights eight non-Swiss languages; primary WER excludes
Chinese. Swiss has a separate floor and targets spoken Swiss German rendered
faithfully in written Standard German. The frozen one-sided 95% source bootstrap
uses 2,000 draws, seed 10410520261110 and 16/16 paired sources per language. Macro
margins are 0.5pp CER / 1pp WER; language margins 1pp CER / 2pp WER. Unknown
speaker/session dependence and unadjusted multiple comparisons keep inference
exploratory.

Full Large F16 and Q4 each match the published coarse base-language label in
144/144 automatic-language calls. This is observed agreement on monolingual
labels, not independently reviewed language-ID, dialect or switch accuracy.

## Full Large Q4 language bounds

| Language | Mode | Paired sources | CER delta / upper pp | WER delta / upper pp |
| --- | --- | ---: | ---: | ---: |
| de-CH | known | 16 | 0.101 / 0.512 | -0.654 / 1.351 |
| de | known | 16 | 0.165 / 0.405 | 0.683 / 1.609 |
| fr | known | 16 | -0.294 / 0.087 | -0.680 / 0.397 |
| it | known | 16 | 0.102 / 0.226 | 0.794 / 1.515 |
| en | known | 16 | 0.136 / 0.381 | 0.319 / 0.888 |
| ar | known | 16 | 0.072 / 0.265 | -0.350 / 0.610 |
| zh | known | 16 | 0.000 / 0.000 | — |
| es | known | 16 | 0.163 / 0.306 | 0.798 / 1.489 |
| pt | known | 16 | 0.139 / 0.543 | 0.450 / 1.193 |
| de-CH | auto | 16 | 0.101 / 0.519 | -0.654 / 1.258 |
| de | auto | 16 | 0.165 / 0.407 | 0.683 / 1.706 |
| fr | auto | 16 | -0.294 / 0.090 | -0.680 / 0.418 |
| it | auto | 16 | 0.102 / 0.229 | 0.794 / 1.493 |
| en | auto | 16 | 0.136 / 0.387 | 0.319 / 0.893 |
| ar | auto | 16 | 0.072 / 0.268 | -0.350 / 0.627 |
| zh | auto | 16 | 0.000 / 0.000 | — |
| es | auto | 16 | 0.163 / 0.319 | 0.798 / 1.548 |
| pt | auto | 16 | 0.139 / 0.514 | 0.450 / 1.208 |

## Runtime and resource observations

**UNCONTROLLED / NOT EVALUATED for resource acceptance.** One quality repeat per source, serial/nice10/two threads, fresh invocation with warm caches and multiple execution windows. These are descriptions, not controlled speed or memory acceptance. Wall time includes setup/inspection/model loading/inference/rendering; process RSS excludes total unified GPU allocation. Upstream load is not total initialization. Complete initialization, first-result latency, unified GPU allocation, energy, download and bundle increments remain unmeasured.

| Model | Mode | Calls | Wall median s | Upstream load median s | Process peak RSS median MiB | Complete workload RTF |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| small | known | 143 | 1.679 | 0.169 | 857.703 | pending |
| small | auto | 143 | 1.444 | 0.166 | 857.562 | pending |
| small-q5_1 | known | 144 | 1.435 | 0.078 | 526.531 | 0.117 |
| small-q5_1 | auto | 144 | 1.372 | 0.077 | 526.023 | 0.111 |
| small-q4_0 | known | 144 | 1.348 | 0.065 | 476.984 | 0.111 |
| small-q4_0 | auto | 144 | 1.428 | 0.065 | 476.680 | 0.118 |
| large-v3-turbo | known | 144 | 2.473 | 0.488 | 1928.734 | 0.205 |
| large-v3-turbo | auto | 144 | 2.771 | 0.487 | 1928.562 | 0.227 |
| large-v3-turbo-q5_1 | known | 144 | 1.878 | 0.208 | 895.656 | 0.154 |
| large-v3-turbo-q5_1 | auto | 144 | 3.567 | 0.309 | 896.367 | 0.266 |
| large-v3-turbo-q4_0 | known | 144 | 1.728 | 0.163 | 746.086 | 0.142 |
| large-v3-turbo-q4_0 | auto | 144 | 1.928 | 0.163 | 746.195 | 0.159 |
| large-v3 | known | 144 | 5.780 | 1.093 | 4034.219 | 0.474 |
| large-v3 | auto | 144 | 6.007 | 1.094 | 4034.617 | 0.493 |
| large-v3-q5_1 | known | 144 | 4.395 | 0.504 | 2126.711 | 0.359 |
| large-v3-q5_1 | auto | 144 | 4.644 | 0.518 | 2126.562 | 0.382 |
| large-v3-q4_0 | known | 144 | 4.097 | 0.421 | 1845.617 | 0.336 |
| large-v3-q4_0 | auto | 144 | 4.277 | 0.434 | 1845.633 | 0.356 |

The host was a Mac Studio Mac14,14, M2 Ultra (24 CPU / 60 GPU cores), 64GiB,
macOS 26.6.2 (25G83), Xcode 27.1 (27A9275). Exact allowlisted hardware/software,
all eleven model hashes/sizes, native binary/dependency hashes, coordinator and
transcriber identities, profile, language policy and scorer version are in the
JSON. File savings change representation, not the parameter count. This phase
uses standard whisper.cpp Q4_0/Q5_1 exports; it tests no new weight-space rule.

## Coverage and pending evidence

The fresh acquisition contained 36 development / 144 held-out original
source/reference pairs, 4/16 per language, with a held-out duration of 1,765.534s.
Published read-speech references use legacy-v1 scoring and await independent
native/v2/critical-content approval. FLEURS speakers and all sessions are unknown;
known Swiss client IDs were kept disjoint from prior data/splits, without
independent real-identity proof. This holdout is now consumed evidence.

FLEURS is pinned at b4a42ed06e12025c42f3b4eff6338ace2fe2447a: de_DE,fr_FR,it_IT,en_US,ar_EG,cmn_hans_CN,es_419,pt_BR; Latin/Arabic/Simplified Chinese scripts. This covers published Mandarin/Simplified text, not all Chinese varieties/scripts, and does not independently verify spoken Arabic/regional varieties. Swiss held-out canton declarations are AG2/SG3/ZH3/BE3/TG1/GR1/GL1/FR1/BL1. Natural poor audio, long conversation, genuine non-speech, names/numbers/negation, language switches, independent channels and live operation remain unvalidated by this panel.

The separate YouTube preparation retains 17 originals across nine planned
languages, nine development / eight held-out sources, one uploaded en-US VTT and
zero approved references. Swiss held-out acquisition and reference, timing,
variety and speaker review remain pending in #122. Those downloads supply no
gold references for these scores.

## Checkpoint validation and preservation

The retained transcription executable is `b082ca6d…` from `517d344`; coordinator
`b6670501…` is separately built at `3fdad88`. TranscriptAccuracy.swift and
CorpusBenchmark.swift match the original source bytes. Checkpoint import verified
exact input/runtime identities and retained successful case reports, persisted
new attempts before invocation and executed only never-attempted queued rows.
Completed, failed, cancelled and ambiguous outcomes were not retried. The original
Small checkpoints, earlier budget failures, five joint seals, source audio and
references, raw/canonical transcripts, source timing and provenance remain
immutable. [Recovery contract](checkpoint-continuation.md).

Postflight verified 3,223 unique preserved input files unchanged, inventoried 38,941 output files and verified 29 frozen research refs unchanged. Every owned ASR session shut down cleanly; zero inference retries and no installed-app replacement.

Independent unchanged auditing checked 396 development/held-out cohorts, 7,161
count/rate calculations and 212 paired intervals. The target batches retain
2,590 completed-with-review calls and the two earlier Small cancellations.
Earlier development retains 598 completions / two cancellations / 192 unstarted;
original F16 development 359/360 is **NOT_MET**. Tiny/Base held-out retains 204
completions / one failure / one cancellation / 370 unstarted. These missing
checks remain pending.

Execution head `3fdad88` passed 119 local native/frozen tests (including seven
checkpoint tests), 174 offline tests, source-boundary/self-tests, 20,000-buffer
PCM ownership and all five staged Release renderer hashes. Six bounded
continuation contracts passed.
[Full CI 42913051459](https://github.com/moreaki/recscribe/actions/runs/42913051459)
passed both required checks, 121 native tests and matching 494-test functional/TSan
runs (491 passed / three skipped, zero failures, diagnostics or restarts).
Provider digest and the full sanitizer gate were independently verified. The
hosted merge-tree count differs from the local branch count. A later publication
and main-integration head needs its own full CI; these greens belong to `3fdad88`.

After the campaign and postflight audit, the publication branch merged fetched
`origin/main` at `12de549` without conflicts. All 121 native/frozen and 174 offline
tests passed again on that integrated source. Full hosted functional/TSan and
Release checks remain required on the final publication head; consult #125 for
their current state.

## Next confirmation

Keep Large Q4 fixed and evaluate it against its unchanged F16 parent on a fresh,
larger, independently reviewed panel of real speech. Cover names, numbers,
negation, natural poor audio, pauses, language switches and independent channels;
retain Swiss Standard German rendering and document actual varieties/scripts.
Use a separate controlled resource panel for latency and total memory. Native
reference approval, the earlier missing baseline checks and product acceptance
remain open in #104/#105/#122. This pilot justifies confirmation of Large Q4;
it does not authorize changing a download or bundled default.

Protected evidence remains under `Benchmarks/Research/105/quantized-quality-20261110-v1`; count-only receipt/source hashes in the JSON bind the public artifacts to retained evidence. Historical snapshots and archived/frozen branches are kept. No model/default promotion or automatic merge.
