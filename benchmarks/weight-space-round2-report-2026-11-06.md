# Round-2 localized affine-bias pilot — 2026-11-06

All **4,212/4,212 inference cells and 2,106/2,106 paired cells** completed under the frozen seven-partition plan. Each predeclared model/mode keeps its own result; there is no cross-model/mode winning average. **No default promotion is authorized.** A numerical pass means continue research only.

| Model | New development / known | Fresh heldout / known | Fresh heldout / automatic |
| --- | --- | --- | --- |
| tiny | reject | reject | reject |
| base | reject | reject | reject |
| small | reject | reject | reject |

The frozen held-out comparisons give the following equal-language means; WER excludes Chinese. Neither language mode meets both gain targets for any model.

| Model / mode | Parent → candidate CER | Parent → candidate WER | Reason for rejection |
| --- | ---: | ---: | --- |
| Tiny / known | 17.574% → 17.484% | 35.565% → 35.404% | Gain targets; French and Arabic CER regression caps |
| Tiny / auto | 18.681% → 18.796% | 36.756% → 36.445% | Gain targets; French and Arabic CER regression caps |
| Base / known | 13.137% → 13.284% | 26.834% → 26.972% | Gain targets; Swiss written-German WER increase |
| Base / auto | 13.137% → 13.284% | 27.437% → 27.575% | Gain targets; Swiss written-German WER increase |
| Small / known | 8.071% → 7.969% | 16.797% → 16.797% | CER gain 1.275% < 5%; WER gain 0% < 2% |
| Small / auto | 8.071% → 7.969% | 16.797% → 16.797% | CER gain 1.275% < 5%; WER gain 0% < 2% |

Reject this fixed family for promotion. This does not rule out other weight-space methods. The next research decision should use development-only evidence about actual error mechanisms, rather than a gain/head sweep on either consumed held-out set. There is no eligible combined configuration or bundled-default recommendation from these results.

This is a fixed no-training research family, not a best-model selection exercise. The [round-1 candidate](weight-space-pilot-report-2026-11-05.md) improved development CER while losing words and then failed its consumed heldout. That public rejection informed the stricter design. Round 2 fixes one localized value-bias operator, explicit WER/Swiss gates, eight new sources per language and a compensated numerical control. The new head/gain selection uses original weights; consumed reference/transcript content did not select it. Round-1 sources are excluded from both new splits. One pilot provides no general conclusion for or against weight-space methods.

## Fixed intervention and evidence limits

The [protocol](weight-space-round2-protocol.md) and [recipes](weight-space/round-2/README.md) fix one original-weight-selected decoder cross-attention head per model. Only its 64 F32 value-bias elements are multiplied by 0.90. The selection ratio ||O_h bV_h||₂ / ||O_h V_h||F is a coordinate-dependent affine-weight proxy, not activation saliency or a proven hallucination mechanism. No gain/head grid, training, fine-tuning, distillation, pruning, language masking or weight compression is performed.

A separate compensated control folds the rounded value-bias delta into output bias. Its stored-F32 static residual is bounded, but KV-cache casting/fused arithmetic can alter decoding. Actual hypothesis/label controls are reported rather than inferred from the algebra.

| Model | Selected layer/head (zero based) | Stored-F32 compensation residual L2 | Parent/candidate/control bytes each |
| --- | ---: | ---: | ---: |
| tiny | 0/3 | 5.775311164e-08 | 77,691,713 |
| base | 0/2 | 8.117161424e-08 | 147,951,465 |
| small | 5/3 | 3.687638903e-08 | 487,601,967 |

| Recipe-generation software (recorded metadata) | Python | NumPy | Numeric workers |
| --- | --- | --- | ---: |
| tiny | 3.15.0 (main, Oct  9 2026, 11:16:41) [Clang 21.0.0 (clang-2100.3.34.2)] | 2.5.4 | 1 |
| base | 3.15.0 (main, Oct  9 2026, 11:16:41) [Clang 21.0.0 (clang-2100.3.34.2)] | 2.5.4 | 1 |
| small | 3.15.0 (main, Oct  9 2026, 11:16:41) [Clang 21.0.0 (clang-2100.3.34.2)] | 2.5.4 | 1 |

Every independent static receipt reports unchanged originals, zero changed bytes outside declared ranges, 64 changed value-bias elements, absolute residual ≤1e−6 and relative residual ≤1e−5. Shapes, vocabulary, parameter count and exact file sizes are retained; the declared weight bytes change. Bundle increment, downloaded-container tradeoffs and distribution are unmeasured; these edits make no smaller-model claim.

## Sources, scoring and independence

Each new split contains 72 unique utterances: eight each for Swiss German, German, French, Italian, English, Arabic, Mandarin/Simplified Chinese, Spanish and Portuguese. The nine original development sources are reused only for the numerical control. The sealed acquisition attestation records exclusions for prior source IDs, original/prepared audio hashes, reference hashes and all known prior Swiss speaker IDs, including the consumed round-1 holdout. Its metadata-ledger hash is retained below. This renderer additionally checks current control/development/heldout disjointness for planned case IDs, original source IDs, prepared hashes and reference hashes; it does not independently reread every previous corpus or establish speaker independence/pretraining exclusion.

Swiss speech is evaluated against published written Standard German references; native fidelity/convention review is pending. Dialect spelling is a separate task. Regional/script scope remains narrow: FLEURS de_de/fr_fr/it_it/en_us, ar_eg read/MSA target (not established Egyptian-dialect coverage), cmn_hans_cn Mandarin/Simplified, es_419 Latin America and pt_br Brazil. Published Swiss speaker metadata is retained; broader Swiss regions/scripts and other varieties remain pending. Individual FLEURS speakers and all sessions are incompletely known. Natural/adverse/long-form, silence, overlap, switching, live and independent-channel coverage remain pending.

Sources: [Google FLEURS pinned release/card](https://huggingface.co/datasets/google/fleurs/tree/b4a42ed06e12025c42f3b4eff6338ace2fe2447a), CC BY 4.0; [FHNW All Swiss German Dialects Test Set](https://www.cs.technik.fhnw.ch/i4ds-datasets), v1 (2021-03-10), MIT. FLEURS dev/test and FHNW public/private source partitions supplied development-validation/held-out respectively. The deterministic bounded acquisition and exclusions are in [acquire-fresh-slice.py](../scripts/quality/acquire-fresh-slice.py); original cards, TSVs, archives/member identities, references, source timing and known Swiss speaker metadata remain protected. Published split names and duplicate exclusions do not prove complete speaker/session independence or absence from pretraining.

Executed scoring stays **swift-nfc-casefold-alphanumeric-v1**. Only successful repeat 1 supplies quality, with no later-repeat fallback/selective retry. CER is corpus-weighted within language then equally averaged across nine languages; WER is equally averaged across eight meaningful languages. Chinese whitespace WER is unreported. Repeated inference gives timing/variation observations, not more independent speech. Native-approved v2/strict Arabic scoring and critical-content adjudication remain pending.

Fixed per-model/mode gates: ≥5% relative macro CER gain; ≥2% relative eight-language macro WER gain; each CER increase≤0.01; each meaningful WER increase≤0.02; Swiss written-German WER increase≤0. Complete paired coverage and no newly wrong coarse automatic base labels are required. Missing/empty/ambiguous/multipass labels remain inconclusive. Numerical failure rejects; numerical success continues research only.

## Numerical mechanism controls

The control stage completed 324/324 inference and 162/162 pair cells. There are nine sources, known+auto, three repeats and three independent parent/control pairs. The following exact repeat 1 equality observations do not prove equality of every real-world inference.

| Model | Completed inference / pairs | Identical repeat 1 hypothesis pairs (known+auto) | Observed equal automatic label pairs | Mechanism-control status |
| --- | ---: | ---: | ---: | --- |
| tiny | 108/108; 54/54 | 18/18 | 9/9 | observed control requirements met |
| base | 108/108; 54/54 | 18/18 | 9/9 | observed control requirements met |
| small | 108/108; 54/54 | 18/18 | 9/9 | observed control requirements met |

## Descriptive repeat stability

Each group is one planned source/model/mode with three completed repeats. Stable means all three recorded canonical hypothesis hashes are present and equal; varied means all three are present and at least two differ; any missing/invalid hash stays unknown. This is output variation evidence, not an accuracy gate or three independent utterances/speakers. No explicit seed capability is claimed; retained effective arguments define inherited upstream search/fallback behavior. These counts do not attribute a specific RNG/backend cause or establish greedy/deterministic inference.

| Stage | Planned source/model/mode groups | Stable | Varied | Unknown |
| --- | ---: | ---: | ---: | ---: |
| numerical-controls | 108 | 108 | 0 | 0 |
| dev-validation-tiny | 144 | 144 | 0 | 0 |
| dev-validation-base | 144 | 144 | 0 | 0 |
| dev-validation-small | 144 | 144 | 0 | 0 |
| heldout-tiny | 288 | 288 | 0 | 0 |
| heldout-base | 288 | 288 | 0 | 0 |
| heldout-small | 288 | 288 | 0 | 0 |

## Tiny: independent parent/candidate comparison

### New development-validation / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 16.087% | 15.470% | 3.838% | not met |
| WER (eight; Chinese excluded) | 37.836% | 37.023% | 2.149% | met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 41.826% [197/471; 53/62/82] | 41.401% [195/471; 55/63/77] | 83.784% [62/74; 12/4/46] | 85.135% [63/74; 13/3/47] | -0.425 | +1.351 |
| de | 9.071% [84/926; 15/18/51] | 8.855% [82/926; 14/18/50] | 27.500% [44/160; 2/3/39] | 26.875% [43/160; 2/3/38] | -0.216 | -0.625 |
| fr | 20.703% [218/1053; 27/52/139] | 20.893% [220/1053; 33/59/128] | 48.585% [103/212; 26/4/73] | 46.226% [98/212; 22/4/72] | +0.190 | -2.358 |
| it | 9.398% [78/830; 31/11/36] | 8.916% [74/830; 26/13/35] | 29.518% [49/166; 7/3/39] | 30.120% [50/166; 5/3/42] | -0.482 | +0.602 |
| en | 5.548% [39/703; 9/10/20] | 5.548% [39/703; 9/10/20] | 16.312% [23/141; 4/1/18] | 16.312% [23/141; 4/1/18] | +0.000 | +0.000 |
| ar | 18.778% [126/671; 34/37/55] | 18.629% [125/671; 34/34/57] | 59.701% [80/134; 7/4/69] | 58.209% [78/134; 7/2/69] | -0.149 | -1.493 |
| zh | 27.706% [64/231; 0/2/62] | 23.810% [55/231; 0/2/53] | — | — | -3.896 | — |
| es | 3.382% [39/1153; 5/18/16] | 3.296% [38/1153; 5/18/15] | 12.134% [29/239; 3/2/24] | 11.297% [27/239; 2/2/23] | -0.087 | -0.837 |
| pt | 8.374% [68/812; 0/28/40] | 7.882% [64/812; 1/27/36] | 25.157% [40/159; 5/5/30] | 22.013% [35/159; 2/8/25] | -0.493 | -3.145 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | not met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 20.274 [20.189–21.300], n=3 | 20.831 [20.597–21.060], n=3 | 0.192 [0.093–0.310], n=24 | 0.158 [0.079–0.242], n=24 | 272.586 [267.094–277.203], n=24 | 272.977 [269.641–275.344], n=24 |
| de | 20.044 [19.664–20.915], n=3 | 20.919 [19.851–21.711], n=3 | 0.198 [0.092–0.355], n=24 | 0.165 [0.069–0.280], n=24 | 274.242 [269.719–275.609], n=24 | 273.930 [269.609–275.656], n=24 |
| fr | 21.536 [21.511–22.115], n=3 | 20.816 [20.278–21.583], n=3 | 0.196 [0.068–0.350], n=24 | 0.169 [0.046–0.303], n=24 | 274.227 [270.469–278.141], n=24 | 273.977 [270.219–277.156], n=24 |
| it | 21.025 [20.989–21.389], n=3 | 20.713 [20.592–21.046], n=3 | 0.172 [0.083–0.376], n=24 | 0.175 [0.089–0.325], n=24 | 274.156 [272.391–277.875], n=24 | 274.219 [272.547–277.375], n=24 |
| en | 20.878 [20.241–21.088], n=3 | 20.718 [20.054–20.948], n=3 | 0.208 [0.087–0.401], n=24 | 0.170 [0.069–0.247], n=24 | 272.664 [269.359–276.781], n=24 | 272.695 [266.625–276.266], n=24 |
| ar | 21.320 [20.408–21.535], n=3 | 20.963 [20.563–21.058], n=3 | 0.176 [0.072–0.293], n=24 | 0.175 [0.068–0.362], n=24 | 274.320 [271.719–276.500], n=24 | 274.508 [272.344–276.672], n=24 |
| zh | 20.623 [20.281–21.060], n=3 | 21.422 [20.288–21.733], n=3 | 0.178 [0.070–0.411], n=24 | 0.149 [0.069–0.218], n=24 | 274.484 [272.750–277.828], n=24 | 274.641 [272.469–276.531], n=24 |
| es | 20.684 [20.203–20.702], n=3 | 20.890 [20.570–21.437], n=3 | 0.169 [0.065–0.340], n=24 | 0.164 [0.070–0.242], n=24 | 274.812 [272.703–280.047], n=24 | 274.820 [272.953–280.297], n=24 |
| pt | 21.024 [20.615–21.418], n=3 | 20.437 [19.509–21.093], n=3 | 0.197 [0.068–0.405], n=24 | 0.145 [0.069–0.312], n=24 | 274.016 [271.625–275.781], n=24 | 273.742 [271.469–275.844], n=24 |

### Fresh heldout / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 17.574% | 17.484% | 0.511% | not met |
| WER (eight; Chinese excluded) | 35.565% | 35.404% | 0.453% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 44.253% [231/522; 55/63/113] | 42.912% [224/522; 54/61/109] | 83.133% [69/83; 13/3/53] | 80.723% [67/83; 10/3/54] | -1.341 | -2.410 |
| de | 7.265% [85/1170; 35/17/33] | 7.436% [87/1170; 36/15/36] | 25.000% [50/200; 8/7/35] | 25.500% [51/200; 9/7/35] | +0.171 | +0.500 |
| fr | 24.427% [245/1003; 51/62/132] | 25.723% [258/1003; 36/77/145] | 48.261% [111/230; 30/5/76] | 49.565% [114/230; 29/6/79] | +1.296 | +1.304 |
| it | 6.250% [52/832; 14/14/24] | 6.250% [52/832; 14/13/25] | 22.981% [37/161; 6/2/29] | 22.360% [36/161; 7/2/27] | +0.000 | -0.621 |
| en | 5.828% [44/755; 5/20/19] | 5.828% [44/755; 5/20/19] | 9.740% [15/154; 3/2/10] | 9.740% [15/154; 3/2/10] | +0.000 | +0.000 |
| ar | 19.645% [166/845; 34/48/84] | 20.947% [177/845; 36/53/88] | 59.195% [103/174; 9/4/90] | 59.770% [104/174; 8/5/91] | +1.302 | +0.575 |
| zh | 37.963% [123/324; 7/12/104] | 36.111% [117/324; 6/13/98] | — | — | -1.852 | — |
| es | 4.642% [37/797; 8/13/16] | 4.642% [37/797; 8/13/16] | 15.924% [25/157; 7/1/17] | 15.287% [24/157; 7/1/16] | +0.000 | -0.637 |
| pt | 7.892% [82/1039; 14/19/49] | 7.507% [78/1039; 8/19/51] | 20.290% [42/207; 8/4/30] | 20.290% [42/207; 7/5/30] | -0.385 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | not met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | not met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 8.974 [8.580–9.375], n=3 | 9.056 [8.919–9.598], n=3 | 0.043 [0.042–0.046], n=24 | 0.043 [0.042–0.046], n=24 | 272.836 [269.266–274.391], n=24 | 273.094 [269.234–275.969], n=24 |
| de | 9.400 [9.374–9.865], n=3 | 9.627 [9.198–9.909], n=3 | 0.043 [0.042–0.046], n=24 | 0.043 [0.042–0.046], n=24 | 274.133 [272.141–280.500], n=24 | 274.086 [272.344–279.672], n=24 |
| fr | 9.646 [9.491–9.791], n=3 | 9.659 [9.512–9.931], n=3 | 0.043 [0.042–0.046], n=24 | 0.043 [0.042–0.047], n=24 | 273.203 [272.031–275.562], n=24 | 273.195 [272.562–276.875], n=24 |
| it | 9.081 [8.406–9.415], n=3 | 9.153 [9.113–9.365], n=3 | 0.043 [0.042–0.046], n=24 | 0.043 [0.042–0.046], n=24 | 273.594 [272.000–277.344], n=24 | 273.594 [272.328–275.688], n=24 |
| en | 8.865 [8.651–9.168], n=3 | 8.952 [8.626–9.074], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.045], n=24 | 272.766 [269.250–274.844], n=24 | 272.484 [268.703–274.812], n=24 |
| ar | 10.027 [9.844–10.249], n=3 | 10.170 [10.017–10.544], n=3 | 0.043 [0.042–0.047], n=24 | 0.043 [0.042–0.046], n=24 | 274.516 [272.219–280.312], n=24 | 274.500 [272.516–278.609], n=24 |
| zh | 9.260 [8.989–9.569], n=3 | 9.385 [9.366–9.532], n=3 | 0.042 [0.042–0.045], n=24 | 0.043 [0.042–0.046], n=24 | 274.297 [272.000–276.688], n=24 | 274.102 [270.906–276.594], n=24 |
| es | 9.248 [8.885–9.413], n=3 | 9.179 [8.716–9.228], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.046], n=24 | 273.375 [269.609–275.172], n=24 | 273.469 [269.922–276.953], n=24 |
| pt | 9.552 [9.441–9.706], n=3 | 9.185 [9.072–9.426], n=3 | 0.043 [0.042–0.046], n=24 | 0.043 [0.041–0.046], n=24 | 274.594 [270.766–276.766], n=24 | 274.469 [272.844–276.609], n=24 |

### Fresh heldout / auto

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 18.681% | 18.796% | -0.615% | not met |
| WER (eight; Chinese excluded) | 36.756% | 36.445% | 0.848% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 48.659% [254/522; 45/103/106] | 49.042% [256/522; 41/124/91] | 90.361% [75/83; 10/16/49] | 86.747% [72/83; 7/21/44] | +0.383 | -3.614 |
| de | 7.265% [85/1170; 35/17/33] | 7.436% [87/1170; 36/15/36] | 25.000% [50/200; 8/7/35] | 25.500% [51/200; 9/7/35] | +0.171 | +0.500 |
| fr | 24.427% [245/1003; 51/62/132] | 25.723% [258/1003; 36/77/145] | 48.261% [111/230; 30/5/76] | 49.565% [114/230; 29/6/79] | +1.296 | +1.304 |
| it | 6.250% [52/832; 14/14/24] | 6.250% [52/832; 14/13/25] | 22.981% [37/161; 6/2/29] | 22.360% [36/161; 7/2/27] | +0.000 | -0.621 |
| en | 5.828% [44/755; 5/20/19] | 5.828% [44/755; 5/20/19] | 9.740% [15/154; 3/2/10] | 9.740% [15/154; 3/2/10] | +0.000 | +0.000 |
| ar | 25.207% [213/845; 39/38/136] | 26.627% [225/845; 41/43/141] | 61.494% [107/174; 9/8/90] | 62.069% [108/174; 8/9/91] | +1.420 | +0.575 |
| zh | 37.963% [123/324; 7/12/104] | 36.111% [117/324; 6/13/98] | — | — | -1.852 | — |
| es | 4.642% [37/797; 8/13/16] | 4.642% [37/797; 8/13/16] | 15.924% [25/157; 7/1/17] | 15.287% [24/157; 7/1/16] | +0.000 | -0.637 |
| pt | 7.892% [82/1039; 14/19/49] | 7.507% [78/1039; 8/19/51] | 20.290% [42/207; 8/4/30] | 20.290% [42/207; 7/5/30] | -0.385 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | met |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | not met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | not met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

| Coarse base-label evidence | Parent | Candidate / paired transition |
| --- | ---: | ---: |
| Planned cases | 72 | 72 |
| Observed nonempty unambiguous labels | 72 | 72 |
| Correct published-source base labels / planned | 69/72 | 69/72 |
| Paired unknown cases | — | 0 |
| Newly wrong cases | — | 0 |
| Changed labels while already wrong | — | 0 |

Coarse label preservation does not establish dialect, language-switch, fallback, confidence or human language-ID accuracy. Repairs cannot cancel a different newly wrong case.

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 10.023 [9.945–10.195], n=3 | 10.181 [10.073–10.248], n=3 | 0.043 [0.042–0.047], n=24 | 0.044 [0.043–0.048], n=24 | 273.102 [269.297–276.547], n=24 | 273.148 [269.125–277.641], n=24 |
| de | 9.569 [9.248–9.811], n=3 | 9.646 [9.582–9.713], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.045], n=24 | 273.953 [272.188–278.641], n=24 | 274.141 [272.422–278.734], n=24 |
| fr | 9.537 [9.268–9.683], n=3 | 9.525 [9.459–9.747], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.045], n=24 | 273.242 [272.422–275.703], n=24 | 273.281 [272.188–275.641], n=24 |
| it | 9.442 [9.309–9.496], n=3 | 9.518 [9.342–9.657], n=3 | 0.043 [0.042–0.047], n=24 | 0.043 [0.042–0.046], n=24 | 273.828 [272.047–277.484], n=24 | 273.836 [272.000–276.562], n=24 |
| en | 9.028 [8.899–9.036], n=3 | 8.893 [8.855–8.940], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.045], n=24 | 272.734 [269.469–275.688], n=24 | 272.898 [269.109–274.141], n=24 |
| ar | 10.254 [10.098–10.629], n=3 | 10.544 [10.227–10.671], n=3 | 0.043 [0.041–0.045], n=24 | 0.043 [0.042–0.047], n=24 | 274.805 [272.359–278.703], n=24 | 274.508 [271.828–280.172], n=24 |
| zh | 9.490 [9.459–9.714], n=3 | 9.517 [9.268–9.781], n=3 | 0.043 [0.042–0.045], n=24 | 0.043 [0.042–0.045], n=24 | 274.188 [272.453–276.406], n=24 | 274.211 [272.578–277.109], n=24 |
| es | 9.598 [8.801–9.656], n=3 | 9.327 [9.101–9.656], n=3 | 0.042 [0.042–0.044], n=24 | 0.043 [0.042–0.047], n=24 | 273.414 [269.719–274.484], n=24 | 273.453 [269.578–275.469], n=24 |
| pt | 9.554 [9.539–9.626], n=3 | 9.510 [9.437–9.677], n=3 | 0.043 [0.042–0.051], n=24 | 0.043 [0.042–0.048], n=24 | 274.594 [272.891–278.141], n=24 | 274.117 [272.500–276.734], n=24 |

## Base: independent parent/candidate comparison

### New development-validation / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 11.685% | 11.907% | -1.903% | not met |
| WER (eight; Chinese excluded) | 25.212% | 25.412% | -0.792% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 31.210% [147/471; 48/42/57] | 32.059% [151/471; 50/41/60] | 66.216% [49/74; 10/2/37] | 64.865% [48/74; 10/2/36] | +0.849 | -1.351 |
| de | 2.484% [23/926; 4/7/12] | 3.132% [29/926; 3/12/14] | 8.125% [13/160; 0/2/11] | 10.000% [16/160; 0/4/12] | +0.648 | +1.875 |
| fr | 11.016% [116/1053; 14/36/66] | 10.256% [108/1053; 13/35/60] | 25.000% [53/212; 10/0/43] | 23.585% [50/212; 8/0/42] | -0.760 | -1.415 |
| it | 6.024% [50/830; 22/7/21] | 5.663% [47/830; 20/7/20] | 18.675% [31/166; 5/2/24] | 17.470% [29/166; 4/2/23] | -0.361 | -1.205 |
| en | 4.410% [31/703; 2/10/19] | 4.410% [31/703; 1/11/19] | 12.057% [17/141; 1/0/16] | 12.766% [18/141; 2/0/16] | +0.000 | +0.709 |
| ar | 13.413% [90/671; 27/27/36] | 14.605% [98/671; 30/28/40] | 52.985% [71/134; 8/2/61] | 55.970% [75/134; 10/1/64] | +1.192 | +2.985 |
| zh | 30.303% [70/231; 0/1/69] | 30.736% [71/231; 0/1/70] | — | — | +0.433 | — |
| es | 1.995% [23/1153; 5/12/6] | 1.995% [23/1153; 5/12/6] | 7.950% [19/239; 1/3/15] | 7.950% [19/239; 1/3/15] | +0.000 | +0.000 |
| pt | 4.310% [35/812; 1/20/14] | 4.310% [35/812; 1/20/14] | 10.692% [17/159; 0/4/13] | 10.692% [17/159; 0/4/13] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | not met |
| ar_wer_increase_at_most_0.02 | not met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 20.889 [20.733–21.234], n=3 | 9.593 [9.066–9.661], n=3 | 0.209 [0.084–0.371], n=24 | 0.064 [0.062–0.068], n=24 | 382.594 [380.812–384.062], n=24 | 381.828 [380.641–383.719], n=24 |
| de | 20.631 [20.587–20.844], n=3 | 19.941 [19.819–21.779], n=3 | 0.195 [0.086–0.384], n=24 | 0.165 [0.065–0.220], n=24 | 383.242 [380.438–385.328], n=24 | 382.781 [380.156–386.938], n=24 |
| fr | 21.615 [20.877–23.041], n=3 | 21.332 [21.121–21.447], n=3 | 0.221 [0.089–0.396], n=24 | 0.179 [0.097–0.250], n=24 | 383.086 [380.562–385.672], n=24 | 383.000 [381.422–386.172], n=24 |
| it | 20.233 [19.863–20.388], n=3 | 21.979 [21.366–22.753], n=3 | 0.174 [0.088–0.295], n=24 | 0.186 [0.086–0.263], n=24 | 383.219 [381.266–389.094], n=24 | 383.531 [381.641–389.469], n=24 |
| en | 20.775 [20.270–20.992], n=3 | 13.565 [12.569–13.621], n=3 | 0.205 [0.090–0.381], n=24 | 0.063 [0.061–0.294], n=24 | 381.914 [380.828–386.141], n=24 | 381.500 [378.641–385.328], n=24 |
| ar | 22.726 [22.252–23.106], n=3 | 10.360 [10.307–10.688], n=3 | 0.213 [0.087–0.408], n=24 | 0.062 [0.061–0.066], n=24 | 383.289 [381.984–388.516], n=24 | 383.062 [381.141–385.141], n=24 |
| zh | 21.444 [20.186–21.467], n=3 | 9.838 [9.406–9.881], n=3 | 0.195 [0.084–0.353], n=24 | 0.062 [0.061–0.067], n=24 | 383.406 [379.141–387.938], n=24 | 383.023 [381.656–388.047], n=24 |
| es | 22.058 [21.047–22.250], n=3 | 10.023 [9.828–10.266], n=3 | 0.206 [0.094–0.377], n=24 | 0.063 [0.061–0.076], n=24 | 383.609 [381.609–390.438], n=24 | 383.508 [380.047–389.359], n=24 |
| pt | 21.061 [20.636–21.447], n=3 | 10.016 [9.349–10.203], n=3 | 0.229 [0.092–0.331], n=24 | 0.062 [0.061–0.066], n=24 | 383.266 [381.609–384.781], n=24 | 382.805 [381.141–384.547], n=24 |

### Fresh heldout / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 13.137% | 13.284% | -1.119% | not met |
| WER (eight; Chinese excluded) | 26.834% | 26.972% | -0.514% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 41.954% [219/522; 54/72/93] | 40.613% [212/522; 55/62/95] | 72.289% [60/83; 8/10/42] | 73.494% [61/83; 10/8/43] | -1.341 | +1.205 |
| de | 4.359% [51/1170; 13/16/22] | 4.530% [53/1170; 13/16/24] | 16.000% [32/200; 7/3/22] | 17.000% [34/200; 7/4/23] | +0.171 | +1.000 |
| fr | 17.946% [180/1003; 28/52/100] | 18.445% [185/1003; 28/54/103] | 32.609% [75/230; 11/8/56] | 30.870% [71/230; 8/10/53] | +0.499 | -1.739 |
| it | 4.567% [38/832; 6/12/20] | 4.808% [40/832; 7/12/21] | 19.876% [32/161; 2/3/27] | 19.876% [32/161; 2/3/27] | +0.240 | +0.000 |
| en | 4.503% [34/755; 7/15/12] | 4.503% [34/755; 7/15/12] | 7.143% [11/154; 3/1/7] | 7.143% [11/154; 3/1/7] | +0.000 | +0.000 |
| ar | 14.793% [125/845; 28/36/61] | 15.621% [132/845; 35/38/59] | 43.678% [76/174; 8/1/67] | 43.678% [76/174; 8/2/66] | +0.828 | +0.000 |
| zh | 22.222% [72/324; 4/10/58] | 23.148% [75/324; 4/11/60] | — | — | +0.926 | — |
| es | 2.886% [23/797; 5/9/9] | 2.886% [23/797; 5/9/9] | 9.554% [15/157; 2/1/12] | 10.191% [16/157; 3/1/12] | +0.000 | +0.637 |
| pt | 5.005% [52/1039; 0/20/32] | 5.005% [52/1039; 0/20/32] | 13.527% [28/207; 1/6/21] | 13.527% [28/207; 1/6/21] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | not met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 7.821 [7.468–7.873], n=3 | 9.582 [9.470–9.653], n=3 | 0.063 [0.062–0.068], n=24 | 0.064 [0.062–0.067], n=24 | 382.352 [380.766–384.906], n=24 | 382.023 [380.812–384.219], n=24 |
| de | 10.077 [9.770–10.083], n=3 | 10.044 [9.906–10.199], n=3 | 0.062 [0.061–0.068], n=24 | 0.063 [0.062–0.066], n=24 | 382.820 [380.969–388.141], n=24 | 382.828 [380.984–387.609], n=24 |
| fr | 9.918 [9.875–9.970], n=3 | 10.223 [10.034–10.350], n=3 | 0.063 [0.061–0.071], n=24 | 0.063 [0.061–0.089], n=24 | 382.609 [381.656–387.156], n=24 | 382.445 [381.578–384.797], n=24 |
| it | 9.588 [9.580–9.779], n=3 | 10.072 [9.660–10.175], n=3 | 0.062 [0.060–0.066], n=24 | 0.063 [0.062–0.066], n=24 | 382.734 [381.531–385.297], n=24 | 382.688 [381.359–384.875], n=24 |
| en | 8.402 [8.169–8.441], n=3 | 9.177 [9.145–9.325], n=3 | 0.064 [0.061–0.071], n=24 | 0.063 [0.062–0.070], n=24 | 382.062 [379.734–385.625], n=24 | 382.195 [381.000–383.656], n=24 |
| ar | 9.067 [9.051–9.429], n=3 | 10.899 [10.460–11.102], n=3 | 0.067 [0.063–0.075], n=24 | 0.063 [0.062–0.066], n=24 | 384.055 [380.906–389.781], n=24 | 383.602 [381.266–390.469], n=24 |
| zh | 8.330 [8.300–8.589], n=3 | 10.364 [10.190–11.643], n=3 | 0.064 [0.062–0.071], n=24 | 0.063 [0.062–0.069], n=24 | 383.109 [381.406–385.594], n=24 | 382.984 [381.406–385.156], n=24 |
| es | 7.658 [7.489–7.854], n=3 | 9.876 [9.602–9.969], n=3 | 0.063 [0.062–0.067], n=24 | 0.063 [0.062–0.068], n=24 | 382.664 [381.312–383.547], n=24 | 382.445 [381.094–386.047], n=24 |
| pt | 8.153 [8.047–8.245], n=3 | 9.845 [9.767–10.168], n=3 | 0.063 [0.061–0.067], n=24 | 0.063 [0.062–0.067], n=24 | 383.422 [381.859–387.219], n=24 | 383.266 [381.812–388.469], n=24 |

### Fresh heldout / auto

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 13.137% | 13.284% | -1.119% | not met |
| WER (eight; Chinese excluded) | 27.437% | 27.575% | -0.502% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 41.954% [219/522; 54/81/84] | 40.613% [212/522; 55/71/86] | 77.108% [64/83; 8/6/50] | 78.313% [65/83; 10/4/51] | -1.341 | +1.205 |
| de | 4.359% [51/1170; 13/16/22] | 4.530% [53/1170; 13/16/24] | 16.000% [32/200; 7/3/22] | 17.000% [34/200; 7/4/23] | +0.171 | +1.000 |
| fr | 17.946% [180/1003; 28/52/100] | 18.445% [185/1003; 28/54/103] | 32.609% [75/230; 11/8/56] | 30.870% [71/230; 8/10/53] | +0.499 | -1.739 |
| it | 4.567% [38/832; 6/12/20] | 4.808% [40/832; 7/12/21] | 19.876% [32/161; 2/3/27] | 19.876% [32/161; 2/3/27] | +0.240 | +0.000 |
| en | 4.503% [34/755; 7/15/12] | 4.503% [34/755; 7/15/12] | 7.143% [11/154; 3/1/7] | 7.143% [11/154; 3/1/7] | +0.000 | +0.000 |
| ar | 14.793% [125/845; 28/36/61] | 15.621% [132/845; 35/38/59] | 43.678% [76/174; 8/1/67] | 43.678% [76/174; 8/2/66] | +0.828 | +0.000 |
| zh | 22.222% [72/324; 4/10/58] | 23.148% [75/324; 4/11/60] | — | — | +0.926 | — |
| es | 2.886% [23/797; 5/9/9] | 2.886% [23/797; 5/9/9] | 9.554% [15/157; 2/1/12] | 10.191% [16/157; 3/1/12] | +0.000 | +0.637 |
| pt | 5.005% [52/1039; 0/20/32] | 5.005% [52/1039; 0/20/32] | 13.527% [28/207; 1/6/21] | 13.527% [28/207; 1/6/21] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | met |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | not met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

| Coarse base-label evidence | Parent | Candidate / paired transition |
| --- | ---: | ---: |
| Planned cases | 72 | 72 |
| Observed nonempty unambiguous labels | 72 | 72 |
| Correct published-source base labels / planned | 70/72 | 70/72 |
| Paired unknown cases | — | 0 |
| Newly wrong cases | — | 0 |
| Changed labels while already wrong | — | 0 |

Coarse label preservation does not establish dialect, language-switch, fallback, confidence or human language-ID accuracy. Repairs cannot cancel a different newly wrong case.

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 10.962 [10.736–11.260], n=3 | 11.148 [10.884–11.232], n=3 | 0.063 [0.062–0.071], n=24 | 0.064 [0.062–0.068], n=24 | 381.992 [380.031–388.938], n=24 | 382.078 [380.672–387.000], n=24 |
| de | 8.338 [8.282–8.342], n=3 | 10.149 [10.141–10.424], n=3 | 0.063 [0.062–0.066], n=24 | 0.063 [0.062–0.068], n=24 | 382.938 [381.391–388.766], n=24 | 382.672 [379.984–388.062], n=24 |
| fr | 8.217 [8.158–8.237], n=3 | 9.920 [9.675–10.270], n=3 | 0.063 [0.061–0.066], n=24 | 0.063 [0.062–0.068], n=24 | 382.305 [381.578–384.453], n=24 | 382.289 [381.656–384.141], n=24 |
| it | 8.059 [7.973–8.252], n=3 | 10.011 [10.006–10.086], n=3 | 0.063 [0.062–0.068], n=24 | 0.063 [0.062–0.067], n=24 | 382.539 [380.516–384.047], n=24 | 382.711 [381.250–385.062], n=24 |
| en | 7.566 [7.476–7.696], n=3 | 9.642 [9.372–9.645], n=3 | 0.063 [0.062–0.066], n=24 | 0.063 [0.062–0.068], n=24 | 381.922 [380.891–383.578], n=24 | 382.180 [380.938–385.422], n=24 |
| ar | 9.128 [8.956–9.220], n=3 | 11.104 [11.087–11.157], n=3 | 0.063 [0.061–0.067], n=24 | 0.064 [0.062–0.069], n=24 | 383.664 [380.125–389.656], n=24 | 384.023 [380.391–390.203], n=24 |
| zh | 8.626 [8.603–9.051], n=3 | 10.174 [9.916–10.175], n=3 | 0.063 [0.062–0.070], n=24 | 0.063 [0.062–0.067], n=24 | 382.898 [380.266–385.594], n=24 | 383.102 [381.750–386.531], n=24 |
| es | 9.791 [9.563–10.032], n=3 | 9.963 [9.751–10.048], n=3 | 0.063 [0.062–0.066], n=24 | 0.063 [0.062–0.067], n=24 | 382.359 [377.750–384.031], n=24 | 382.477 [380.969–383.906], n=24 |
| pt | 10.386 [10.100–10.580], n=3 | 10.148 [10.124–10.212], n=3 | 0.064 [0.062–0.067], n=24 | 0.063 [0.061–0.071], n=24 | 383.164 [381.125–388.516], n=24 | 383.281 [381.875–388.609], n=24 |

## Small: independent parent/candidate comparison

### New development-validation / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 7.028% | 6.823% | 2.928% | not met |
| WER (eight; Chinese excluded) | 14.155% | 13.985% | 1.203% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 21.019% [99/471; 38/32/29] | 21.019% [99/471; 38/32/29] | 37.838% [28/74; 6/3/19] | 37.838% [28/74; 6/3/19] | +0.000 | +0.000 |
| de | 1.620% [15/926; 2/7/6] | 1.620% [15/926; 2/7/6] | 3.125% [5/160; 0/0/5] | 3.125% [5/160; 0/0/5] | +0.000 | +0.000 |
| fr | 4.843% [51/1053; 8/21/22] | 4.463% [47/1053; 7/18/22] | 14.151% [30/212; 4/2/24] | 13.208% [28/212; 4/2/22] | -0.380 | -0.943 |
| it | 2.048% [17/830; 6/7/4] | 2.048% [17/830; 6/7/4] | 7.229% [12/166; 0/3/9] | 7.229% [12/166; 0/3/9] | +0.000 | +0.000 |
| en | 2.987% [21/703; 1/7/13] | 2.987% [21/703; 1/7/13] | 11.348% [16/141; 3/1/12] | 11.348% [16/141; 3/1/12] | +0.000 | +0.000 |
| ar | 6.408% [43/671; 4/19/20] | 6.408% [43/671; 4/19/20] | 27.612% [37/134; 2/1/34] | 27.612% [37/134; 2/1/34] | +0.000 | +0.000 |
| zh | 19.913% [46/231; 0/1/45] | 18.615% [43/231; 0/0/43] | — | — | -1.299 | — |
| es | 1.214% [14/1153; 3/9/2] | 1.041% [12/1153; 3/7/2] | 3.766% [9/239; 0/2/7] | 3.347% [8/239; 0/1/7] | -0.173 | -0.418 |
| pt | 3.202% [26/812; 1/18/7] | 3.202% [26/812; 1/18/7] | 8.176% [13/159; 0/2/11] | 8.176% [13/159; 0/2/11] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 11.760 [11.620–11.819], n=3 | 11.881 [11.763–12.282], n=3 | 0.154 [0.149–0.171], n=24 | 0.154 [0.150–0.160], n=24 | 856.195 [851.781–858.000], n=24 | 856.156 [854.047–859.328], n=24 |
| de | 12.672 [12.401–12.894], n=3 | 12.718 [12.499–12.759], n=3 | 0.154 [0.150–0.161], n=24 | 0.154 [0.151–0.164], n=24 | 857.039 [855.172–859.094], n=24 | 857.070 [855.281–858.719], n=24 |
| fr | 13.141 [12.554–13.210], n=3 | 12.881 [12.875–13.397], n=3 | 0.154 [0.152–0.165], n=24 | 0.154 [0.150–0.162], n=24 | 856.805 [855.375–860.469], n=24 | 857.000 [854.922–860.094], n=24 |
| it | 12.737 [12.680–13.123], n=3 | 12.802 [12.664–12.980], n=3 | 0.154 [0.151–0.159], n=24 | 0.154 [0.153–0.162], n=24 | 856.984 [854.344–858.906], n=24 | 857.203 [855.406–860.328], n=24 |
| en | 12.044 [11.978–12.154], n=3 | 12.011 [11.671–12.378], n=3 | 0.154 [0.152–0.160], n=24 | 0.154 [0.152–0.167], n=24 | 857.062 [854.531–858.578], n=24 | 856.531 [854.797–859.625], n=24 |
| ar | 13.116 [12.870–13.655], n=3 | 13.432 [12.725–13.466], n=3 | 0.154 [0.152–0.163], n=24 | 0.154 [0.149–0.162], n=24 | 856.883 [855.562–859.625], n=24 | 856.836 [855.609–860.391], n=24 |
| zh | 12.867 [12.645–13.100], n=3 | 12.704 [12.624–13.062], n=3 | 0.154 [0.151–0.171], n=24 | 0.154 [0.149–0.166], n=24 | 856.938 [855.203–859.578], n=24 | 856.789 [853.984–858.797], n=24 |
| es | 13.069 [12.772–13.177], n=3 | 12.978 [12.677–13.074], n=3 | 0.154 [0.152–0.166], n=24 | 0.154 [0.151–0.160], n=24 | 857.367 [855.750–860.875], n=24 | 857.070 [855.391–860.719], n=24 |
| pt | 12.499 [12.413–12.749], n=3 | 12.387 [12.015–12.620], n=3 | 0.156 [0.149–0.167], n=24 | 0.155 [0.152–0.161], n=24 | 856.750 [855.000–858.938], n=24 | 856.711 [851.344–858.781], n=24 |

### Fresh heldout / known

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 8.071% | 7.969% | 1.275% | not met |
| WER (eight; Chinese excluded) | 16.797% | 16.797% | 0.000% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 29.693% [155/522; 55/47/53] | 29.693% [155/522; 55/47/53] | 53.012% [44/83; 9/3/32] | 53.012% [44/83; 9/3/32] | +0.000 | +0.000 |
| de | 2.222% [26/1170; 7/9/10] | 2.222% [26/1170; 7/9/10] | 9.500% [19/200; 2/3/14] | 9.500% [19/200; 2/3/14] | +0.000 | +0.000 |
| fr | 8.375% [84/1003; 20/29/35] | 8.375% [84/1003; 20/29/35] | 19.130% [44/230; 5/8/31] | 19.130% [44/230; 5/8/31] | +0.000 | +0.000 |
| it | 1.322% [11/832; 1/2/8] | 1.322% [11/832; 1/2/8] | 5.590% [9/161; 0/2/7] | 5.590% [9/161; 0/2/7] | +0.000 | +0.000 |
| en | 3.576% [27/755; 5/16/6] | 3.576% [27/755; 5/16/6] | 7.143% [11/154; 3/1/7] | 7.143% [11/154; 3/1/7] | +0.000 | +0.000 |
| ar | 8.284% [70/845; 5/32/33] | 8.284% [70/845; 5/32/33] | 28.161% [49/174; 1/3/45] | 28.161% [49/174; 1/3/45] | +0.000 | +0.000 |
| zh | 16.049% [52/324; 4/18/30] | 15.123% [49/324; 5/11/33] | — | — | -0.926 | — |
| es | 1.004% [8/797; 0/8/0] | 1.004% [8/797; 0/8/0] | 7.006% [11/157; 3/2/6] | 7.006% [11/157; 3/2/6] | +0.000 | +0.000 |
| pt | 2.117% [22/1039; 0/10/12] | 2.117% [22/1039; 0/10/12] | 4.831% [10/207; 0/2/8] | 4.831% [10/207; 0/2/8] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | N/A — explicit language; no automatic-ID evidence |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 11.835 [11.739–12.037], n=3 | 12.153 [11.975–12.273], n=3 | 0.154 [0.152–0.160], n=24 | 0.155 [0.151–0.166], n=24 | 856.656 [854.016–858.781], n=24 | 856.797 [855.000–858.703], n=24 |
| de | 13.161 [13.094–13.186], n=3 | 13.150 [12.819–13.288], n=3 | 0.154 [0.149–0.157], n=24 | 0.154 [0.150–0.161], n=24 | 857.711 [855.562–863.188], n=24 | 856.883 [855.172–861.828], n=24 |
| fr | 12.827 [12.652–12.993], n=3 | 12.735 [12.595–12.739], n=3 | 0.154 [0.150–0.159], n=24 | 0.154 [0.150–0.162], n=24 | 856.500 [855.125–859.047], n=24 | 856.359 [854.859–859.984], n=24 |
| it | 12.929 [12.139–13.179], n=3 | 12.632 [12.318–12.788], n=3 | 0.154 [0.152–0.161], n=24 | 0.156 [0.152–0.170], n=24 | 856.641 [854.922–860.078], n=24 | 856.867 [855.172–859.328], n=24 |
| en | 11.892 [11.750–12.181], n=3 | 11.971 [11.833–12.256], n=3 | 0.154 [0.150–0.161], n=24 | 0.155 [0.152–0.161], n=24 | 856.977 [853.844–858.656], n=24 | 857.039 [855.516–859.312], n=24 |
| ar | 13.960 [13.793–14.382], n=3 | 14.231 [14.010–14.291], n=3 | 0.153 [0.151–0.162], n=24 | 0.155 [0.151–0.162], n=24 | 857.359 [855.141–861.516], n=24 | 857.398 [855.266–861.219], n=24 |
| zh | 13.119 [12.979–13.283], n=3 | 13.389 [13.063–13.428], n=3 | 0.154 [0.151–0.169], n=24 | 0.156 [0.151–0.163], n=24 | 857.438 [855.312–859.547], n=24 | 856.961 [855.453–859.656], n=24 |
| es | 12.354 [12.131–12.586], n=3 | 12.705 [12.544–12.916], n=3 | 0.154 [0.150–0.162], n=24 | 0.156 [0.151–0.175], n=24 | 856.734 [855.641–858.312], n=24 | 856.703 [854.953–858.156], n=24 |
| pt | 12.802 [12.772–12.930], n=3 | 13.254 [12.742–13.274], n=3 | 0.154 [0.152–0.165], n=24 | 0.156 [0.151–0.166], n=24 | 857.430 [855.766–860.266], n=24 | 857.508 [855.469–860.781], n=24 |

### Fresh heldout / auto

Decision: **reject**. This is a numerical research decision; native/product acceptance is pending.

| Macro metric | Parent | Candidate | Relative gain | Frozen gain gate |
| --- | ---: | ---: | ---: | --- |
| CER (nine languages) | 8.071% | 7.969% | 1.275% | not met |
| WER (eight; Chinese excluded) | 16.797% | 16.797% | 0.000% | not met |

All language rows have **8/8 unique repeat-1 sources** per side. Cells are rate [errors/reference units; insertions/deletions/substitutions]. Reference units are observed counts, not guessed from duration or language. Positive deltas retain regressions.

| Language | Parent CER | Candidate CER | Parent WER | Candidate WER | CER delta pp | WER delta pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 29.693% [155/522; 55/47/53] | 29.693% [155/522; 55/47/53] | 53.012% [44/83; 9/3/32] | 53.012% [44/83; 9/3/32] | +0.000 | +0.000 |
| de | 2.222% [26/1170; 7/9/10] | 2.222% [26/1170; 7/9/10] | 9.500% [19/200; 2/3/14] | 9.500% [19/200; 2/3/14] | +0.000 | +0.000 |
| fr | 8.375% [84/1003; 20/29/35] | 8.375% [84/1003; 20/29/35] | 19.130% [44/230; 5/8/31] | 19.130% [44/230; 5/8/31] | +0.000 | +0.000 |
| it | 1.322% [11/832; 1/2/8] | 1.322% [11/832; 1/2/8] | 5.590% [9/161; 0/2/7] | 5.590% [9/161; 0/2/7] | +0.000 | +0.000 |
| en | 3.576% [27/755; 5/16/6] | 3.576% [27/755; 5/16/6] | 7.143% [11/154; 3/1/7] | 7.143% [11/154; 3/1/7] | +0.000 | +0.000 |
| ar | 8.284% [70/845; 5/32/33] | 8.284% [70/845; 5/32/33] | 28.161% [49/174; 1/3/45] | 28.161% [49/174; 1/3/45] | +0.000 | +0.000 |
| zh | 16.049% [52/324; 4/18/30] | 15.123% [49/324; 5/11/33] | — | — | -0.926 | — |
| es | 1.004% [8/797; 0/8/0] | 1.004% [8/797; 0/8/0] | 7.006% [11/157; 3/2/6] | 7.006% [11/157; 3/2/6] | +0.000 | +0.000 |
| pt | 2.117% [22/1039; 0/10/12] | 2.117% [22/1039; 0/10/12] | 4.831% [10/207; 0/2/8] | 4.831% [10/207; 0/2/8] | +0.000 | +0.000 |

Frozen gate observations (unknown never passes):

| Gate | Result |
| --- | --- |
| complete_planned_coverage | met |
| no_new_wrong_auto_base_labels | met |
| macro_cer_gain_at_least_5_percent | not met |
| macro_wer_gain_at_least_2_percent | not met |
| de-CH_cer_increase_at_most_0.01 | met |
| de-CH_wer_increase_at_most_0.02 | met |
| swiss_written_german_wer_no_increase | met |
| de_cer_increase_at_most_0.01 | met |
| de_wer_increase_at_most_0.02 | met |
| fr_cer_increase_at_most_0.01 | met |
| fr_wer_increase_at_most_0.02 | met |
| it_cer_increase_at_most_0.01 | met |
| it_wer_increase_at_most_0.02 | met |
| en_cer_increase_at_most_0.01 | met |
| en_wer_increase_at_most_0.02 | met |
| ar_cer_increase_at_most_0.01 | met |
| ar_wer_increase_at_most_0.02 | met |
| zh_cer_increase_at_most_0.01 | met |
| es_cer_increase_at_most_0.01 | met |
| es_wer_increase_at_most_0.02 | met |
| pt_cer_increase_at_most_0.01 | met |
| pt_wer_increase_at_most_0.02 | met |

| Coarse base-label evidence | Parent | Candidate / paired transition |
| --- | ---: | ---: |
| Planned cases | 72 | 72 |
| Observed nonempty unambiguous labels | 72 | 72 |
| Correct published-source base labels / planned | 72/72 | 72/72 |
| Paired unknown cases | — | 0 |
| Newly wrong cases | — | 0 |
| Changed labels while already wrong | — | 0 |

Coarse label preservation does not establish dialect, language-switch, fallback, confidence or human language-ID accuracy. Repairs cannot cancel a different newly wrong case.

Observed resources: **UNCONTROLLED / NOT EVALUATED**. Each value is median [minimum–maximum], with its actual measured count. Wall is the sum of eight per-utterance job wall times in one language/repeat, summarized across three repeats; it excludes orchestration gaps and is not a contiguous eight-clip run or app first-result latency. Load is the upstream timer per native invocation. RSS is the per-invocation process peak distribution in MiB (2²⁰ bytes). These are distinct observation units.

| Language | Parent wall s | Candidate wall s | Parent native load s | Candidate native load s | Parent peak RSS MiB | Candidate peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| de-CH | 12.569 [12.470–12.907], n=3 | 23.882 [23.129–24.110], n=3 | 0.155 [0.150–0.163], n=24 | 0.267 [0.188–0.337], n=24 | 856.875 [855.250–858.734], n=24 | 857.070 [855.484–860.391], n=24 |
| de | 13.711 [13.642–13.719], n=3 | 13.828 [13.689–14.127], n=3 | 0.154 [0.151–0.159], n=24 | 0.157 [0.154–0.168], n=24 | 857.156 [855.125–861.719], n=24 | 857.188 [853.281–863.031], n=24 |
| fr | 13.312 [13.176–13.478], n=3 | 13.232 [13.224–13.507], n=3 | 0.153 [0.150–0.164], n=24 | 0.156 [0.152–0.161], n=24 | 856.070 [854.969–859.156], n=24 | 857.031 [854.953–859.328], n=24 |
| it | 13.163 [12.946–13.188], n=3 | 12.962 [12.719–13.419], n=3 | 0.154 [0.151–0.162], n=24 | 0.157 [0.152–0.165], n=24 | 857.078 [854.812–859.906], n=24 | 856.906 [854.562–859.125], n=24 |
| en | 12.428 [12.009–12.806], n=3 | 12.511 [12.413–12.672], n=3 | 0.153 [0.150–0.163], n=24 | 0.156 [0.153–0.163], n=24 | 856.797 [855.188–858.781], n=24 | 856.984 [855.703–858.422], n=24 |
| ar | 14.160 [13.981–14.228], n=3 | 23.782 [23.272–24.300], n=3 | 0.154 [0.149–0.161], n=24 | 0.274 [0.160–0.354], n=24 | 858.031 [855.172–862.500], n=24 | 857.953 [855.391–862.453], n=24 |
| zh | 13.484 [13.346–13.781], n=3 | 24.287 [23.497–24.900], n=3 | 0.153 [0.150–0.164], n=24 | 0.276 [0.194–0.355], n=24 | 857.359 [855.562–860.844], n=24 | 857.961 [856.375–863.031], n=24 |
| es | 12.992 [12.655–13.037], n=3 | 23.703 [23.037–24.549], n=3 | 0.153 [0.151–0.161], n=24 | 0.272 [0.193–0.352], n=24 | 856.750 [854.656–859.172], n=24 | 857.641 [853.750–858.594], n=24 |
| pt | 13.368 [13.085–13.834], n=3 | 23.989 [23.717–24.448], n=3 | 0.154 [0.152–0.163], n=24 | 0.281 [0.188–0.363], n=24 | 857.234 [855.500–858.891], n=24 | 857.961 [855.500–860.422], n=24 |

## Held-out source duration and outer-CLI RTF context

UNCONTROLLED shared-desktop observations; no resource acceptance. The held-out set contains 802.52 unique audio seconds, reused across every model/mode; repeats do not add independent audio. Each row has eight unique sources. Wall is the median of three per-repeat sums of outer CLI job wall times, including load/preparation/rendering, excluding serial coordinator/orchestration gaps. RTF is that wall divided by unique source-audio duration; it is not steady decoder throughput or first-result latency. Numeric source_audio_seconds is the only duration source; no corpus or linked audio/reference/model path was opened. Full ranges and counts are in JSON.

| Model | Mode | Language | Unique audio s | Parent median wall s | Parent RTF | Candidate median wall s | Candidate RTF |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| tiny | known | de-CH | 67.140000 | 8.973581 | 0.133655 | 9.056290 | 0.134887 |
| tiny | known | de | 123.180000 | 9.399544 | 0.076307 | 9.626961 | 0.078154 |
| tiny | known | fr | 76.380000 | 9.645509 | 0.126283 | 9.658623 | 0.126455 |
| tiny | known | it | 88.320000 | 9.080696 | 0.102816 | 9.153453 | 0.103640 |
| tiny | known | en | 65.000000 | 8.864857 | 0.136382 | 8.952387 | 0.137729 |
| tiny | known | ar | 99.080000 | 10.026855 | 0.101200 | 10.169913 | 0.102643 |
| tiny | known | zh | 94.420000 | 9.260380 | 0.098076 | 9.385004 | 0.099396 |
| tiny | known | es | 79.860000 | 9.247764 | 0.115800 | 9.178704 | 0.114935 |
| tiny | known | pt | 109.140000 | 9.552124 | 0.087522 | 9.185396 | 0.084162 |
| tiny | auto | de-CH | 67.140000 | 10.022801 | 0.149282 | 10.181405 | 0.151644 |
| tiny | auto | de | 123.180000 | 9.568633 | 0.077680 | 9.645873 | 0.078307 |
| tiny | auto | fr | 76.380000 | 9.536829 | 0.124860 | 9.524665 | 0.124701 |
| tiny | auto | it | 88.320000 | 9.442223 | 0.106909 | 9.518408 | 0.107772 |
| tiny | auto | en | 65.000000 | 9.028404 | 0.138899 | 8.893320 | 0.136820 |
| tiny | auto | ar | 99.080000 | 10.254118 | 0.103493 | 10.543956 | 0.106419 |
| tiny | auto | zh | 94.420000 | 9.490356 | 0.100512 | 9.517405 | 0.100799 |
| tiny | auto | es | 79.860000 | 9.597819 | 0.120183 | 9.326510 | 0.116786 |
| tiny | auto | pt | 109.140000 | 9.553965 | 0.087539 | 9.510315 | 0.087139 |
| base | known | de-CH | 67.140000 | 7.820513 | 0.116481 | 9.582026 | 0.142717 |
| base | known | de | 123.180000 | 10.076921 | 0.081806 | 10.043985 | 0.081539 |
| base | known | fr | 76.380000 | 9.917856 | 0.129849 | 10.223044 | 0.133845 |
| base | known | it | 88.320000 | 9.587847 | 0.108558 | 10.071883 | 0.114039 |
| base | known | en | 65.000000 | 8.401858 | 0.129259 | 9.176500 | 0.141177 |
| base | known | ar | 99.080000 | 9.066944 | 0.091511 | 10.899250 | 0.110005 |
| base | known | zh | 94.420000 | 8.329516 | 0.088218 | 10.364070 | 0.109766 |
| base | known | es | 79.860000 | 7.657960 | 0.095892 | 9.876212 | 0.123669 |
| base | known | pt | 109.140000 | 8.153361 | 0.074706 | 9.844523 | 0.090201 |
| base | auto | de-CH | 67.140000 | 10.962435 | 0.163277 | 11.148045 | 0.166042 |
| base | auto | de | 123.180000 | 8.338054 | 0.067690 | 10.149085 | 0.082392 |
| base | auto | fr | 76.380000 | 8.216898 | 0.107579 | 9.920153 | 0.129879 |
| base | auto | it | 88.320000 | 8.058637 | 0.091244 | 10.010683 | 0.113346 |
| base | auto | en | 65.000000 | 7.566388 | 0.116406 | 9.641873 | 0.148337 |
| base | auto | ar | 99.080000 | 9.128279 | 0.092130 | 11.103855 | 0.112070 |
| base | auto | zh | 94.420000 | 8.625912 | 0.091357 | 10.173621 | 0.107749 |
| base | auto | es | 79.860000 | 9.790512 | 0.122596 | 9.962714 | 0.124752 |
| base | auto | pt | 109.140000 | 10.385668 | 0.095159 | 10.148286 | 0.092984 |
| small | known | de-CH | 67.140000 | 11.835355 | 0.176279 | 12.153311 | 0.181014 |
| small | known | de | 123.180000 | 13.161381 | 0.106847 | 13.150325 | 0.106757 |
| small | known | fr | 76.380000 | 12.827481 | 0.167943 | 12.734720 | 0.166728 |
| small | known | it | 88.320000 | 12.928978 | 0.146388 | 12.631904 | 0.143024 |
| small | known | en | 65.000000 | 11.892257 | 0.182958 | 11.971246 | 0.184173 |
| small | known | ar | 99.080000 | 13.959577 | 0.140892 | 14.231266 | 0.143634 |
| small | known | zh | 94.420000 | 13.119320 | 0.138946 | 13.388919 | 0.141802 |
| small | known | es | 79.860000 | 12.353759 | 0.154693 | 12.704612 | 0.159086 |
| small | known | pt | 109.140000 | 12.801790 | 0.117297 | 13.253887 | 0.121439 |
| small | auto | de-CH | 67.140000 | 12.569458 | 0.187213 | 23.881850 | 0.355702 |
| small | auto | de | 123.180000 | 13.710567 | 0.111305 | 13.828379 | 0.112262 |
| small | auto | fr | 76.380000 | 13.312213 | 0.174289 | 13.232222 | 0.173242 |
| small | auto | it | 88.320000 | 13.163392 | 0.149042 | 12.961633 | 0.146758 |
| small | auto | en | 65.000000 | 12.428472 | 0.191207 | 12.511348 | 0.192482 |
| small | auto | ar | 99.080000 | 14.159688 | 0.142912 | 23.782410 | 0.240032 |
| small | auto | zh | 94.420000 | 13.484323 | 0.142812 | 24.286990 | 0.257223 |
| small | auto | es | 79.860000 | 12.992223 | 0.162687 | 23.702699 | 0.296803 |
| small | auto | pt | 109.140000 | 13.367512 | 0.122480 | 23.989239 | 0.219802 |

Frozen public-report SHA-256: c92bb46dba468ce3fef32a22be013397bdcb739a20f76cbe536f166e405040f2
Audit source SHA-256: 32a0271789ed4945b88dde8f8f44bc0adfe8124dee48f25e90feb22bd9ed8520

## Immutable identities and completion chain

All hashes are SHA-256. Reads were limited to explicit metadata/event/report/assessment/matrix JSON. No paths to audio, raw references, hypotheses, models, binaries/libraries or native logs were followed. The pre-inference family seal and execution-only partition amendment retain all three recipes and 4,212 cells; the superseded unexecuted aggregate development configuration is excluded. Global heldout freezing occurred after all control/development assessments and before the first heldout launch in the declared AI event chronology. Every final plan strips exactly back to its pre-freeze plan after removing the freeze hash/link.

The actor is **Codex AI**, human_native_approval=false. Hash/snapshot/timestamp bindings are research chronology attestations, not independent human proof of prior outcome inaccessibility or native semantic approval. All three candidates proceeded regardless of development direction; no posthoc winner, recipe change, retry or quality-budget relaxation is inferred. The original family seal binds the pre-partition protocol bytes; the execution-only five-line partition note is a separate amendment and does not change recipes, gates or 4,212 cells. The renderer does not mistake that documented note for an altered frozen quality protocol.

| Artifact | Parent | Candidate | Compensated control |
| --- | --- | --- | --- |
| tiny | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` | `25298e3a5ca56db8a8b4bcf57f6df397457e4500605a6773921a421c7217d32b` | `72a289860bf9063cd4c4cdef94db18e2bd384df40ccb436f6146242cb9536757` |
| base | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | `5e23f028452ca7ec7dddd0cd57adfbc905817d9c69eff5c808f6d4057c79c663` | `d0bfdf29324e480a4584292189f254bcd5532158b5fbedd7f682601b5dee363c` |
| small | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | `b87bbda0a4fa323072022fa0d99a04b77aeaa4440ad3451785d2796fe68e6206` | `bafdddc9c922b2b20b972ae988421c7bbcdcff96070f0fe6a06d96579e996be9` |

| Metadata/source identity | SHA-256 |
| --- | --- |
| Pre-inference family seal | `6f748704da9c234725163094d30884039951ec1b84e70221547d4c151b40b5c0` |
| Execution partition amendment | `0a30d1501a2a02489f1bd8b2cd3e4929fa94bc87eb1cf7a01918817838737605` |
| Final shared heldout-family freeze | `9439dab406e8b0472a439a0c7782523d0c803a7bcecf6a751ebd456d5526f9ff` |
| Independent stored-F32 static receipt | `a7872fd0c3391301a29a5efa6cd5d5c3914ebbc83f0264eb8aff3700aa435505` |
| Serial completed4212 event journal | `b0f762e293a82c195ab609e9ea7c296b4ec34fab8b6acb1dd035825f2cea5c78` |
| Runner CLI | `5e5dad40ce2d3992a6e6bc6ccc71f9dbe5849ff3f2b00f2bcb8f815b17ecf879` |
| whisper-cli | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| Raw current-defaults profile | `4fde2c62eaeb82fe10581324384d0af72f965f0cc1d8375b234453bbd24c1857` |
| Canonical runtime settings | `cdd7cdc0076480723ee4be3cf4d5d2f417ffb7c6ce44fcaeaed517c164048169` |
| Owned-session guard | `8d66418f2c7207bf9e270adc840b0d71e70059f5aa130bff5643641f7ad73847` |
| Assessment tool | `44e8c0c6f5cbae36c829bcebf4609272d5a514a86b2b4744333ba93c1474ce53` |
| Public reporter | `121b097f00eff413a47b940ef71a91db55270a42e545ebdd919f97de3e169059` |
| Normalized native runtime record | `268e4396dff7e4f6b70b20c24a298442d85f50db5ca764e1f314e3567b567f57` |
| Native/model pre-execution inventory | `57867eaee0ad4d13ba17e62e13357bd913d7c0024e3bab7453654712f5f69b4f` |
| Recipe generation completion | `e9a6c3757d83446162a72587666ca2d9ea60db36811e4a000ce5ee3724901b03` |
| Original static head selection | `af8c2d71659caffba9e1aa632e2b9724c86004d4a75dd138c6d6c91a9474d356` |
| Serial coordinator source (recorded before execution) | `d956548c650dc28ba3916d8030a449e71fcfc7139ff9b446aceed04114515bc7` |
| Separate Tiny development AI-only text-review receipt (hash only; not approval) | `6edff5a42c930be0b80426952e42bf45d87b7b4db7e8d25bc0dbc37f32913c46` |
| Freshness integrity ledger | `2c5370f059db262c24c2f1a40150ae590ffe9f419a560760de42718d4387668e` |
| Frozen source: benchmarks/weight-space-round2-protocol.md | `cfc7f7be9a54ca485d99ef9d8aa585610e3a4ac380f8e3530a18cd0b779906f2` |
| Frozen source: scripts/quality/acquire-fresh-slice.py | `20fc09f43d55f7adb89a263df3c52627516ae7ee4e2aff463833f5ac228e2fb5` |
| Frozen source: scripts/quality/affine-bias-recipes.py | `432075eb2f3bdcd6888092c782d17525c78850d076167afe1652af5e030fa28b` |
| Frozen source: scripts/quality/assess-affine-pilot.py | `44e8c0c6f5cbae36c829bcebf4609272d5a514a86b2b4744333ba93c1474ce53` |
| Frozen source: scripts/quality/ggml_weights.py | `11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3` |
| Frozen source: scripts/quality/report-pilot.py | `121b097f00eff413a47b940ef71a91db55270a42e545ebdd919f97de3e169059` |
| Frozen source: scripts/quality/requirements.txt | `54b37774f3ac636a0ef1f014bc5a8cfc44ecb4c4afd2ca485177a6c268018783` |

| Native inventory entry (metadata only) | SHA-256 |
| --- | --- |
| whisper-cli | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| libggml-base.0.27.0.dylib | `4b83a188ddd93a32003edbe342aeae7e3726b7aed2c2e7774642f80fb4855d7f` |
| libomp.dylib | `432b8d15fc1b2431f937bba89796a32daaa2dd464eda12a744d9cb2818842477` |
| libggml.0.27.0.dylib | `eea477583ec2610f261a08e80f07593d6fceaa30418d7ae95e385e2cda5d9b74` |
| libggml-blas.so | `bc7cdf71b25a4ef01387c2a0f218fe995d2c70869df03ae8921e6bde3da57214` |
| libggml-cpu-apple_m1.so | `3146b7ad6d6602df9c6b05407b1b30479cea77383be9dbf72a2865841d28a05c` |
| libggml-cpu-apple_m2_m3.so | `dc13929118733f01625f7ea1beec95b43ff3143a87a44cd0b16824cf08cdff7e` |
| libggml-cpu-apple_m4.so | `d90161124de31c08897872eafa7e3ddc3b43a713e184cef59c8af002bf2161bf` |
| libggml-metal.so | `0e7f450879c116699bee6c3bbc3a8630d01d6e4e74e9f918af6dd6b1c7facffa` |
| libparakeet.1.9.5.dylib | `16ed9f49842cde9371fc605e0d6a7ad1dae5b8d8df9c97c72bce2f3c663ca0e6` |
| libwhisper.1.9.5.dylib | `a2972b454e49de7c83036eed4adbd06d8271f6f7c87b14e679d035d898d3ed4d` |

### Evidence: numerical-controls

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `82388b43b4205de18a1b63299b8258e6b7ec07120dc35e6d064238e49cadc137` |
| Configuration | `26ae1970fd7012d3f8a8a17b47f0417b7f5a78be3ae35b0cd336bdd59d0d2e7a` |
| Pre-freeze assessment plan | `5ef59290a7b04906ccebde2931b347ce7cedf0603b10a6178ac629cc27662e74` |
| Executed assessment plan | `5ef59290a7b04906ccebde2931b347ce7cedf0603b10a6178ac629cc27662e74` |
| Matrix | `35143781223e53547f91e15477b472b6ce12d7c5ecdef350600ded1c40439d30` |
| Report | `c2cde2eb612168ab22f30d83ceed7cdd506e8380cf76d223f3de23278812d478` |
| Assessment | `e63d23bc50efded6296e41e39f18d4d1f00facdb455a4c56697e5e3eb30ca3ca` |

### Evidence: dev-validation-tiny

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `264a36167279e6e1e090cff993a9ffa5ebc242fa77c1e1ac0adb4371ed16d260` |
| Configuration | `8cae3c5474122307cc1184c5484445bc37392367900f1ac0ad5bc9c39fce46a0` |
| Pre-freeze assessment plan | `10dc22c60fcc682e0431539a29342cc1621b4b582483eb4f54480cc9d656e5b0` |
| Executed assessment plan | `10dc22c60fcc682e0431539a29342cc1621b4b582483eb4f54480cc9d656e5b0` |
| Matrix | `2f1f06b4415ca0183b4b66e48903ce0c1e10ab616ac825d8a78e0e40351ffa5b` |
| Report | `98d496741613f35df98e4dbe5af6e33f7f431f2a8fdb8df51660387d7a5ea232` |
| Assessment | `fd6f62d869820ef3778918ac7bd4de3d991b45984b524c58891b4cb50d9c763e` |

### Evidence: dev-validation-base

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `264a36167279e6e1e090cff993a9ffa5ebc242fa77c1e1ac0adb4371ed16d260` |
| Configuration | `95ed892e560a92b1f7142c87ca885e9bc22b75000cab61a01a221e6a1f452170` |
| Pre-freeze assessment plan | `9efbc108d2acd882be26ce8114b71f2cbea4c91ce72a585adf8a01a4ea0fdec9` |
| Executed assessment plan | `9efbc108d2acd882be26ce8114b71f2cbea4c91ce72a585adf8a01a4ea0fdec9` |
| Matrix | `c7c1c874385476ef1ad81bc87eed6e397c5633c2533e275496ae1d0d67c310ae` |
| Report | `a39de6343caa7a4d608433a348bd8ef3a55ad746a08a8f4f17f70722914cdb1a` |
| Assessment | `c6778f600d113048fae36acf168d77c14517d01420cb6d4a94a3f71f2e402d8d` |

### Evidence: dev-validation-small

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `264a36167279e6e1e090cff993a9ffa5ebc242fa77c1e1ac0adb4371ed16d260` |
| Configuration | `f4b7079312cb4d598f3d922948ea360ca03356ce2f7b5dffe6f16caa78fe0b3b` |
| Pre-freeze assessment plan | `02b194d709876ba046dec62dd3509e87848091b8f0a12b23c89e46b9e7e65681` |
| Executed assessment plan | `02b194d709876ba046dec62dd3509e87848091b8f0a12b23c89e46b9e7e65681` |
| Matrix | `1d29002cf0deee58d4d04dcd775db966afee91437d10abffc3187698273037d7` |
| Report | `4678f7a978e05e3ccce265a31ef83932af036d1bc68d5a12fade8cbb29a26217` |
| Assessment | `77d7d21b48eac73ef77f684c19ca6421dab39747dba880ad65078969cbf0a06b` |

### Evidence: heldout-tiny

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `a68a340c716522d018603b23739ad3ea8e539cbcc1fc97e57084fa29734d5ec4` |
| Configuration | `bc6dc5c9028860a32fe423a923d918e40d3032b868893dc986b9378200a817fd` |
| Pre-freeze assessment plan | `b27c567e130b90d176133a0f399ccc25af137b21b58b08913102bc88efbdc7d4` |
| Executed assessment plan | `e9318ddef68b7de4ab5e07617d37bc33e4601a2e06766aee591ca1e04e8bb9f3` |
| Matrix | `3391c642175fc8fe03dfabda9e35f4894315be4f2f986f20e10ddd3ba7a7a54e` |
| Report | `ecc6c3eb78628ccba62de7c7bb0c02eafecf0dc08fd96a7540942f92867a65fe` |
| Assessment | `25132f5ec4b2649e4d649fa3cff85de0986376561a8db9b902730b0ad9debc32` |
| Partition freeze | `772b4765f6c4b8ad6aec17053e1506b80c3a46ccd65b13f563e2e6b3135438e2` |

### Evidence: heldout-base

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `a68a340c716522d018603b23739ad3ea8e539cbcc1fc97e57084fa29734d5ec4` |
| Configuration | `1faa717b31a981467318ff2fc852285068ecd0ee54d456055d1f237eb86c2204` |
| Pre-freeze assessment plan | `e4204a02eaf084bcf8ca9d3f6bfe230d3dc577547eca9245191b3d1f135fe585` |
| Executed assessment plan | `2a4055f05ed9c68e0fb2e8e689c95f0eecaeafd1fa486ec75587f032f21bbd54` |
| Matrix | `f6c6f2c4fd79729655fda795e334d534a9e9ec9eb176ef2bfda326afaeb000f8` |
| Report | `ea536721f5394e76b84cfebd96a2a10d79753b059aeee7552270ab618f799c48` |
| Assessment | `a3e0f820f0614df9df4f8ddaecbf7cc82206dd53afc2a4a41e11b9eed1f103fe` |
| Partition freeze | `1f6f6673fb9b38ad0635bed6815dac61ddb83e2ddd92340396c1eb483e1cb8d2` |

### Evidence: heldout-small

| Retained item | SHA-256 |
| --- | --- |
| Corpus | `a68a340c716522d018603b23739ad3ea8e539cbcc1fc97e57084fa29734d5ec4` |
| Configuration | `0a214f252103b54d0f31ce922010504999cba4b01e7d951cda6bda76a28d82ed` |
| Pre-freeze assessment plan | `6230e92a8764d2dd0af61afd668458383963bce83190d1d8170d315dfc8f7bca` |
| Executed assessment plan | `be37e93036ec05fefc29c1276c1ce4ddfab634be35716716010d23f5546e9ec8` |
| Matrix | `b455cbc35e3582903c63a165592e0df24497a7a5fc35e3b76521e140ff95adec` |
| Report | `34df1fb3777ef1b027f95f430530f35cd92c1907d643afcee24225fe91fda8b3` |
| Assessment | `5469cf737f759f32467aa2b35c3afe4889e0ee0fba49f93850fc5408d3fd174c` |
| Partition freeze | `b1050cf031f7e30de3514d0182bbb4bd6afdbab4e68b795a548e23cc69c2020d` |

## Resource and product limits

The frozen host inventory and pre-execution recheck record a Mac Studio (Mac14,14), Apple M2 Ultra, 24 CPU cores, 60 GPU cores and 64 GiB unified memory; macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), Swift 6.4 (swiftlang-6.4.0.34.1). The shared desktop and model-first serial order do not establish thermal/cache/background-load balance.

Every native invocation retained its full argument list. The common quality settings were `-t 2 -tp 0 -mc 0`, VAD off, no terminology prompt, and no explicit search/fallback overrides. The exact hashed whisper.cpp 1.9.5 backend inherits beam size 5, best-of 5, temperature increment 0.20 and enabled temperature fallback (its retained help was rechecked after execution, SHA-256 `e4e1aedcbb8e57b53238993f3be894cd271aebabfff256b2eaa7abe4d191e9f4`); temperature zero alone is not a claim of greedy decoding, disabled fallback, a fixed seed or deterministic inference. Known-language arguments were `de` for Swiss/German, and `fr`, `it`, `en`, `ar`, `zh`, `es`, `pt`; automatic mode passed unrestricted `auto`. Confidence is unavailable, not fabricated. Each source/channel/invocation is isolated; these file comparisons do not exercise later language switches or live channel state.

Both sides used frozen research runner `4b71f4d` and identical runtime settings. The [untouched five-model baseline](pilot-baseline-2026-11-05.md) retains original control revision `c214a8ed03f972a5a9cab64105145a67371b97b4` and CLI SHA-256 `9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6`. It was neither moved nor rebuilt to obtain these comparisons. Large-v3-turbo and full large-v3 remain untouched baseline models; this round edits Tiny/Base/Small only.

Reported host: Version 26.6.2 (Build 25G83); CPU count 24; physical memory bytes 68719476736. Full hardware/power/toolchain records remain protected. The pinned Whisper backend is 1.9.5/Metal; source revision 4b71f4da65d23cab1538c6f3d0a2fa9bd2d1daf2 is used for both sides, with two threads, serial nice 10 utility work, no VAD, inherited search/fallback and no cross-source/channel text conditioning.

Resource acceptance is **UNCONTROLLED / NOT EVALUATED**. The 1,000% raw per-process CPU stop is an extreme-contention limit, not aggregate CPU/GPU/thermal isolation. Guard polling cancels owned work for active/uncertain audio writes and known competing heavy work; it is not an authoritative capture-intent scheduler and leaves a detection/shutdown race. Recording priority needs a future intent/lease before audio-file creation. No capture or foreign application is stopped for this research.

Observed wall/load/RSS ranges are descriptive only. First-result latency, steady decode throughput, total unified GPU memory, energy and assembled bundle increment remain unmeasured. Original audio/reference/source timings and raw transcripts remain protected and unchanged.

Native review of names/quantities/negation/omissions/invented speech, faithful Swiss written rendering, v2 scoring, individual speaker/session grouping, representative regions/scripts, natural/adverse/long-form and switch/out-of-set/confidence/fallback/live/independent-channel behavior remain **PENDING**, never passed by lexical scores. Public-source pretraining overlap remains possible. The fresh heldout is consumed once; future recipes require fresh predeclared evidence rather than retuning or another blind claim on this set. No bundled model, installed app, settings default, distribution or automatic merge changes.

Renderer version: `round2-public-renderer-v1`; source SHA-256: `5f0e2a7c8d9524199b8c79e9074b238fced6f090e6e91c0d27ac1a36df366e52`. Public report output is a new curated artifact; it contains no raw speech text or audio.

The unedited generated report is retained externally as `public-report-v1.md`, SHA-256 `c92bb46dba468ce3fef32a22be013397bdcb739a20f76cbe536f166e405040f2`. This published version adds the decision summary, source attribution, recorded host/settings context, observation-scope clarifications and the separately audited duration/RTF derivation. Its numerical tables and frozen decisions are unchanged. The renderer verified completion and immutable bindings before opening outcomes; independent numeric review is recorded in the PR validation evidence. Neither text curation nor AI development triage supplies native/audio approval.

The post-execution identity receipt, SHA-256 `d3631e3187c5404b789325bd3b8ce4a0f948cd387d91d575b9a2ff10ccc5648f`, rehashed the frozen runner, eleven native binary/library files and three original models: all 15 still match the pre-execution inventory. The retained untouched-control branch still resolves to `c214a8e`. Completed benchmark, renderer and identity-check logs are pinned managed artifacts; original corpus/model/result evidence remains outside disposable retention.
