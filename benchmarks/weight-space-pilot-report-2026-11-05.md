# First AI weight-edit diagnostic — 2026-11-05

The last-layer Tiny weight edit reduced known-language macro CER from
**21.37% to 18.96%**, an **11.3% relative reduction**, on nine
preselected development utterances. Swiss German remained poor and unchanged:
**54.65% CER / 115.38% WER** against written Standard German. This result supports
a larger development comparison; it does not establish representative accuracy,
an improved causal mechanism, a smaller model, or a new default.

All **324/324 inference cells** and **216/216 paired cells** completed. The
three weight recipes and source selection were fixed before edited-model
outcomes. Only successful repeat 1 supplies quality; three repeats are runtime
and variation observations, not additional independent speech. Native reference
and critical-content review remain unresolved. Latency/RSS observations are
**UNCONTROLLED**; the 10% resource gate is **NOT EVALUATED**. No held-out score,
release approval or model promotion is claimed.

This report covers the first diagnostic for [#112](https://github.com/moreaki/recscribe/issues/112).
The [frozen protocol](weight-space-pilot-protocol.md) defines the experiment and
execution-policy amendment. The separate [untouched five-model baseline](pilot-baseline-2026-11-05.md)
covers tiny, base, small, large-v3-turbo and full large-v3 on 27 utterances;
its unchanged CLI is retained. The causal comparisons below use freshly run
parents and variants under one current runner, rather than mixing their scores
with that earlier baseline.

## Intervention and controls

| Short name | Exact artifact ID | Parent | Operation |
| --- | --- | --- | --- |
| Tiny | `tiny` | Upstream multilingual Tiny | Unchanged matching parent |
| All +10% | `cross-all-gain-110` | Tiny | Multiply all four decoder `cross_attn.out.weight` matrices by 1.10 |
| All −10% | `cross-all-gain-090` | Tiny | Multiply the same matrices by 0.90; directional control |
| Last +10% | `cross-last-gain-110` | Tiny | Multiply only the last decoder layer's `cross_attn.out.weight` by 1.10 |
| Base | `base` | Upstream multilingual Base | Unchanged compression parent |
| Base q5_1 | `base-q5-1` | Base | Supported whisper.cpp q5_1 quantization; conventional compression control |

The AI proposed and executed the three explicit weight edits without retraining,
fine-tuning, gradients or distillation. The all-layer recipes select 589,824
FP16 elements; the last-layer recipe selects 147,456. Static audits retain tensor
shapes, file layout, biases and every unselected byte. These are bounded tests
of decoder acoustic conditioning, not evidence that the proposed mechanism is
correct or that weight-space programming generally improves Whisper.

All three edited Tiny files remain **77,691,713 bytes**, exactly the unchanged
Tiny file size. They make no compression or parameter-removal claim. Base q5_1
is **59,707,625 bytes**, versus Base **147,951,465** and Tiny **77,691,713**.
Its compression method and comparison are separate from the AI scaling effect.
No candidate app bundle was assembled; incremental bundle size is unmeasured.

## Sources, independence and scoring

Selection was the lexicographically first frozen source ID for each language,
chosen before candidate outcomes: nine utterances, **99.7853125 seconds** total.
Each `(model, language, mode)` has one independent utterance and three repeats.
The 108 such cohorts produce 324 invocations; four parent/candidate comparisons
produce 72 comparison cohorts and 216 matched repeat pairs. Reusing the same
sources across models, modes and repeats does not increase the independent
sample count beyond nine.

| Language / source coverage | Source ID | Reference words | Reference Unicode scalars | Audio seconds |
| --- | --- | ---: | ---: | ---: |
| Swiss German speech → written Standard German | `all-swiss-dialects-v1-000c8b7e-b222-4d8b-b701-0740a7c20500` | 13 | 86 | 6.5253125 |
| German, FLEURS `de_de` | `fleurs-de-de-10013061249039105343` | 36 | 173 | 16.14 |
| French, FLEURS `fr_fr` | `fleurs-fr-fr-10008051639162028459` | 39 | 176 | 17.40 |
| Italian, FLEURS `it_it` | `fleurs-it-it-10006672303518507506` | 22 | 108 | 8.10 |
| English, FLEURS `en_us` | `fleurs-en-us-10004088536354799741` | 19 | 87 | 6.80 |
| Arabic, FLEURS `ar_eg`, read/MSA target | `fleurs-ar-eg-10002899498199807056` | 20 | 83 | 11.70 |
| Mandarin, Simplified script, FLEURS `cmn_hans_cn` | `fleurs-cmn-hans-cn-10009480476880474721` | — | 38 | 7.80 |
| Spanish, Latin America, FLEURS `es_419` | `fleurs-es-419-10005668950815513748` | 10 | 54 | 5.76 |
| Portuguese, Brazil, FLEURS `pt_br` | `fleurs-pt-br-10009971053374752024` | 44 | 228 | 19.56 |

These are short published-reference sources, predominantly read speech. The
Swiss source is from the FHNW All Swiss German Dialects Test Set v1 (MIT).
FLEURS is pinned to `b4a42ed06e12025c42f3b4eff6338ace2fe2447a` (CC BY 4.0).
This diagnostic has only one Swiss source/speaker; it establishes no broad
regional Swiss coverage. The larger 27-source development baseline contains
three Swiss speakers with published canton labels BE, AG and SH. FLEURS
individual speaker/session identities are unavailable here, and Swiss sessions
are unknown. An `ar_eg` locale does not establish Egyptian dialect coverage;
Traditional Chinese, other Chinese languages, European Portuguese, other
Arabic varieties and broader regional English/French/German/Italian/Spanish
coverage remain unrepresented.

The executed scoring version for every cohort is
**`swift-nfc-casefold-alphanumeric-v1`**: NFC, POSIX case folding, replacement of
non-alphanumeric scalars other than underscore with spaces, then CER over
normalized Unicode scalars without spaces. Schema-1.0
compatibility selects this legacy scorer; newer per-case policy labels do not
mean v2/strict Arabic scoring executed. Chinese whitespace WER is deliberately
unreported. WER can exceed 100% through insertions. Swiss scoring uses
`standard_rendering`, not dialect spelling, and lexical distance alone cannot
adjudicate equivalent written-German wording or preserved meaning.

## Quality by language and mode

Every cell below is **WER% / CER%**, using its one repeat-1 source and the exact
denominators above. A dash suppresses Chinese WER. The primary macro is the
equal average of the nine per-language corpus-weighted CERs, not a pooled
1,033-scalar rate. Automatic mode is evaluated separately.

### Known language

| Language | Tiny | All +10% | All −10% | Last +10% | Base | Base q5_1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss German → German | 115.38 / 54.65 | 123.08 / 52.33 | 115.38 / 54.65 | 115.38 / 54.65 | 84.62 / 41.86 | 84.62 / 40.70 |
| German | 2.78 / 0.58 | 2.78 / 2.31 | 8.33 / 2.31 | 5.56 / 1.16 | 2.78 / 0.58 | 0.00 / 0.00 |
| French | 41.03 / 18.75 | 43.59 / 18.18 | 58.97 / 28.98 | 43.59 / 15.34 | 17.95 / 6.82 | 25.64 / 9.09 |
| Italian | 36.36 / 7.41 | 18.18 / 2.78 | 36.36 / 5.56 | 18.18 / 2.78 | 40.91 / 12.96 | 27.27 / 8.33 |
| English | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 0.00 / 0.00 | 5.26 / 3.45 |
| Arabic | 65.00 / 30.12 | 70.00 / 27.71 | 60.00 / 28.92 | 65.00 / 28.92 | 50.00 / 22.89 | 60.00 / 26.51 |
| Mandarin / Simplified | — / 44.74 | — / 42.11 | — / 42.11 | — / 42.11 | — / 52.63 | — / 60.53 |
| Spanish | 20.00 / 7.41 | 40.00 / 1.85 | 20.00 / 9.26 | 40.00 / 1.85 | 10.00 / 1.85 | 10.00 / 1.85 |
| Portuguese | 52.27 / 20.61 | 43.18 / 19.30 | 65.91 / 21.93 | 38.64 / 15.79 | 15.91 / 5.26 | 15.91 / 5.26 |

### Automatic language

| Language | Tiny | All +10% | All −10% | Last +10% | Base | Base q5_1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss German → German | 115.38 / 54.65 | 100.00 / 50.00 | 115.38 / 54.65 | 115.38 / 54.65 | 84.62 / 41.86 | 84.62 / 40.70 |
| German | 2.78 / 0.58 | 2.78 / 2.31 | 8.33 / 2.31 | 5.56 / 1.16 | 2.78 / 0.58 | 0.00 / 0.00 |
| French | 41.03 / 18.75 | 43.59 / 18.18 | 58.97 / 28.98 | 43.59 / 15.34 | 17.95 / 6.82 | 25.64 / 9.09 |
| Italian | 36.36 / 7.41 | 18.18 / 2.78 | 36.36 / 5.56 | 18.18 / 2.78 | 40.91 / 12.96 | 27.27 / 8.33 |
| English | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 0.00 / 0.00 | 5.26 / 3.45 |
| Arabic | 65.00 / 30.12 | 70.00 / 27.71 | 60.00 / 28.92 | 65.00 / 28.92 | 50.00 / 22.89 | 60.00 / 26.51 |
| Mandarin / Simplified | — / 44.74 | — / 42.11 | — / 42.11 | — / 42.11 | — / 52.63 | — / 60.53 |
| Spanish | 20.00 / 7.41 | 40.00 / 1.85 | 20.00 / 9.26 | 40.00 / 1.85 | 10.00 / 1.85 | 10.00 / 1.85 |
| Portuguese | 52.27 / 20.61 | 43.18 / 19.30 | 65.91 / 21.93 | 38.64 / 15.79 | 15.91 / 5.26 | 15.91 / 5.26 |

| Model | Known macro CER% | Auto macro CER% | Known relative CER reduction versus parent | Known >2 percentage point CER regressions versus parent |
| --- | ---: | ---: | ---: | --- |
| Tiny | 21.37 | 21.37 | Parent | — |
| All +10% | 19.40 | 19.14 | 9.20% | None in this diagnostic |
| All −10% | 22.42 | 22.42 | −4.91% | French |
| Last +10% | 18.96 | 18.96 | 11.27% | None in this diagnostic |
| Base | 16.10 | 16.10 | Parent | — |
| Base q5_1 | 17.30 | 17.30 | Compression control; no 5% accuracy-improvement requirement | French, English, Arabic, Mandarin |

The predeclared numeric Tiny expansion screen seeks at least 5% relative
known-mode macro CER reduction and flags any language whose absolute CER rises
by more than 0.02. All +10% and Last +10% meet those numeric conditions on this
diagnostic. All −10% fails and its French regression remains part of the result.
The automatic-mode >0.02 CER flags are the same as the known-mode flags.

CER gains do not erase WER regressions: All +10% worsens Swiss, French, Arabic
and Spanish WER in known mode. Last +10% worsens German, French and Spanish WER,
and does not improve Swiss CER or WER. Base q5_1 improves size but loses macro
CER against Base and has the four listed per-language CER regressions; against
Tiny its Mandarin CER also worsens substantially. No independent critical names,
numbers, negation, omission or semantic review has cleared any candidate.

### Observed automatic labels

| Model | Observed repeat-1 labels | Coarse source-label matches | Mismatch |
| --- | ---: | ---: | --- |
| Tiny | 9 / 9 | 9 / 9 | None observed |
| All +10% | 9 / 9 | 8 / 9 | Swiss source: expected base `de`, recognized `af` |
| All −10% | 9 / 9 | 9 / 9 | None observed |
| Last +10% | 9 / 9 | 9 / 9 | None observed |
| Base | 9 / 9 | 9 / 9 | None observed |
| Base q5_1 | 9 / 9 | 9 / 9 | None observed |

These labels come from one unambiguous nonempty native automatic pass per
repeat-1 source. They measure coarse agreement with published monolingual source
tags, not independently adjudicated language-ID accuracy, dialect recognition
or confidence. In particular, lower All +10% Swiss auto CER does not repair the
`af` label regression. Language switches, switch boundaries, abstention,
out-of-set languages and fallback behavior remain unmeasured here. Explicit
known-language rows are excluded from label agreement.

## Runtime, resources and execution policy

The same Mac Studio Mac14,14/M2 Ultra host used for the untouched baseline has
24 CPU cores, 60 GPU cores and 64 GiB memory. The report records macOS 26.6.2
(25G83); the retained toolchain is Xcode 27.1 (27A9275), Swift 6.4
(`swiftlang-6.4.0.34.1`). Recognition uses whisper.cpp 1.9.5/Metal, two threads,
serial utility jobs at nice 10, current-defaults profile, no VAD, `-tp 0 -mc 0`,
no terminology prompt and inherited upstream search/fallback defaults. Known
mode passes base language (`de-CH` → `de`); auto mode passes `auto`. The actual
native final-job preparation path is used with separate mono 16 kHz PCM16
derivatives; these sources do not validate independent channels or live replay.

Capture was verified idle before launch; the guard keeps recording priority,
cancels owned work for capture/known competing ASR/builds/tests/VMs, and fails
closed on capture-probe uncertainty. It does not stop foreign processes. An
earlier attempt stopped after six unchanged Tiny cells, before any edited
outcome, when Firefox exceeded the original 50% raw per-process CPU threshold.
That partial run is preserved. A pre-outcome amendment permitted ordinary
desktop load with a 300% raw per-process CPU stop threshold (three of 24 cores).
That threshold is not aggregate CPU/GPU telemetry. The fresh complete run used
one uniform policy and one frozen cancellation-fixed runner for all parents
and variants. The installed app was not replaced.

The following are **UNCONTROLLED observations**, not latency/memory gate passes.
Wall time is the median of three complete nine-source workloads (99.7853125 s
audio each), summing the corresponding source invocations within each repeat.
RTF is that median wall time divided by audio duration. Brackets give the
minimum–maximum of those three workloads. RSS is the maximum of
the recorded per-invocation process peaks for the indicated mode; it is not
total system or unified GPU memory.

| Model | Known workload wall median [range] s / RTF | Auto workload wall median [range] s / RTF | Known max process RSS bytes | Auto max process RSS bytes |
| --- | ---: | ---: | ---: | ---: |
| Tiny | 16.400 [16.052–16.615] / 0.1643 | 16.399 [15.924–16.812] / 0.1643 | 291,094,528 | 292,552,704 |
| All +10% | 16.515 [16.269–16.674] / 0.1655 | 16.803 [16.614–16.991] / 0.1684 | 293,158,912 | 291,389,440 |
| All −10% | 23.408 [23.347–24.819] / 0.2346 | 25.825 [25.125–26.295] / 0.2588 | 295,337,984 | 294,928,384 |
| Last +10% | 24.353 [23.956–24.851] / 0.2441 | 23.262 [23.112–23.795] / 0.2331 | 292,438,016 | 291,979,264 |
| Base | 22.358 [21.697–22.792] / 0.2241 | 23.716 [22.588–24.245] / 0.2377 | 409,288,704 | 409,092,096 |
| Base q5_1 | 23.314 [22.912–23.626] / 0.2336 | 24.024 [23.923–24.894] / 0.2408 | 286,834,688 | 286,900,224 |

The slower observed Last +10% wall time is retained rather than treated as a
speed improvement. Desktop load, invocation/model-load overhead and sequence
effects prevent attributing these differences to model weights alone. No 10%
latency/RSS regression gate has passed. First-result latency, controlled model
load/inference tradeoffs, energy and complete GPU memory remain pending.

## Exact artifact and evidence identities

All hashes below are SHA-256. Tiny/Base upstream artifacts are pinned to
`ggerganov/whisper.cpp@5359861c739e955e79d9a303bcbc70fb988958b1`.
Derived IDs point directly to their matching parent hashes above.

| Model | File bytes | SHA-256 |
| --- | ---: | --- |
| Tiny | 77,691,713 | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| All +10% | 77,691,713 | `7c30753f8421ffc6ebf02a31efb8112eb6ae60a6271217f46bdb2ad3158c8c42` |
| All −10% | 77,691,713 | `22662a18171ddbb7cea42d3e429abaadc5d23124798b00a0f12ad84c9c8f4f44` |
| Last +10% | 77,691,713 | `f7355c36ace23c76eb18ab84892e2d266b0552a29ce0a9da6a1eaafb52ebea7e` |
| Base | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| Base q5_1 | 59,707,625 | `80147c665f9ac54ab8c3c7f55da90ac030ea40610495ba4dd0aa6304fd49d731` |

| Identity | Value |
| --- | --- |
| Unchanged global control source revision | `c214a8ed03f972a5a9cab64105145a67371b97b4` |
| Matching diagnostic runner source revision | `4b71f4da65d23cab1538c6f3d0a2fa9bd2d1daf2` |
| Matching diagnostic runner binary | `5e5dad40ce2d3992a6e6bc6ccc71f9dbe5849ff3f2b00f2bcb8f815b17ecf879` |
| whisper-cli binary | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| Experiment configuration | `1a3987b422b7387af660a016c63c2c60883414571cf5296ab3163c252b72343d` |
| Selected corpus snapshot | `82388b43b4205de18a1b63299b8258e6b7ec07120dc35e6d064238e49cadc137` |
| Canonical expanded runtime settings | `cdd7cdc0076480723ee4be3cf4d5d2f417ffb7c6ce44fcaeaed517c164048169` |
| Raw current-defaults profile | `4fde2c62eaeb82fe10581324384d0af72f965f0cc1d8375b234453bbd24c1857` |
| Original frozen protocol | `f9824bf6978fea2c70ece92bb49a833a10099c8acc7e274db338fe1792abf9ec` |
| Protocol/selection freeze record | `050f84651e92600b61c43405584c45444d40cd51de8dbc12a43dbcefbf18f30d` |
| Execution lock, including resolved native-library inventory | `918777d81f884c43c43884893f7fe474393a4b71a524c9322a1f653a2d30c788` |
| Guard source | `8d66418f2c7207bf9e270adc840b0d71e70059f5aa130bff5643641f7ad73847` |
| Complete source matrix | `b1424f1142dd52d9403676a3abcfe70e3e7272a3bf7a6bebffd6d9149c63cf4c` |
| Structured report, `quality-pilot-report-1.1` | `a47090017a3d4b5a71437635419dec21d7f2fef266fb604f7394ba041c27e26a` |
| Frozen analyzer, `weight-space-quality-screen-1.0` | `374740f118d012f9982ebf76ba43812eba23f355607b713c52fe10eb1cdfe36e` |
| Structured screen summary | `64cf96cb6c02c26f4e1d8991124b478a7522ab84988310563d2cb74d9d437b49` |
| Expansion decision arithmetic verification | `6084b40ee61f923685281e4ac0c9c5d64fddc63196f9dec8ee39457e75b67333` |

The exact Last +10% relative reduction is `0.11271930241403842` from the counted
screen comparison. A separate retained arithmetic verification corrects a
slightly different manual decimal copy in the expansion decision; the rounded
11.3% result and selected candidate are unchanged.

Protected evidence is rooted at
`~/Library/Application Support/RecScribe/Benchmarks/Research/112/round-1/`.
The complete run is under `diagnostic-six-models-quality-v2/`, including
`execution-lock.json`, `experiment.json`, `corpus.json`, `matrix/`,
`report-v1.1/report.json`, and `screen-v1/summary.json`. Recipes, static tensor
audits, the guard, analyzer and preserved canceled attempts remain alongside it.
The dependency inventory was bound before this diagnostic; declared source
revisions alone do not authenticate a binary. Original audio/references,
derived preparation files, raw transcripts, source timing and provenance remain
external and preserved. This public report contains no raw speech text or audio.

The frozen analyzer validated fixed identities, all 324 cells/216 pairs, nine
source IDs, three repeats, one quality source per language/model/mode, legacy
scorer/reference denominators and counted rate/delta consistency. Its 24
synthetic validation groups passed, including missing/failed-cell refusal,
lineage/settings/configuration/runner mismatch and malformed-input handling.
It reads only the retained report and its own bytes; it does not independently
rescore or authenticate linked audio/reference/model files. These checks do not
replace the pending human/reference review or applicable full PR CI.

## Development expansion and remaining gates

A fresh paired **27-utterance** development expansion of unchanged Tiny and
Last +10% is **in progress**, under `development-27-last-layer-shared-v3/`:
two models × 27 sources × two language modes × three repeats = 324 inference
cells, with 162 planned matched pairs. Its configuration SHA-256 is
`1b2d1f7826073ea8bacc7e040ca21e286b61077da17699fdcf34f23428b308fb`.
It retains the same frozen binary, profile and model artifacts. No expansion
quality outcome is included in this report. The expansion is still development
data and follows selection on this nine-source subset; it is not an independent
held-out confirmation.

The preceding full-27 attempt under `development-27-last-layer/` stopped after
23 unchanged Tiny cells completed and one was canceled: `contactsd` reached
369.2% raw CPU, exceeding the 300% per-process gate. Cancellation exited cleanly
with code 130 and no remaining owned session process; all partial evidence is
retained. Before any full-27 edited-model outcome, a further execution-only
amendment started the fresh shared-v3 accuracy comparison with a 1,000% raw
per-process CPU stop threshold (ten of 24 cores). Capture/known-heavy-work
gates, recipes and quality thresholds remain unchanged. This relaxation permits
substantial desktop noise and provides no resource acceptance. The complete
nine-source diagnostic reported above retains its original uniform 300% policy;
the two attempts are not pooled or silently resumed.

Representative multilingual claims still require broader speakers/sessions,
regional/script coverage, natural and adverse long-form conditions, silence,
overlap, language switches, independent channels, native audio/reference and
critical-content adjudication, and controlled resource measurements. A frozen
combined configuration must then be evaluated once on untouched held-out data.
Held-out references remain unopened for this work. No UI/default/packaging
change is authorized by these diagnostic results.
