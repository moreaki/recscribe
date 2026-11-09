# Round 4: attention rotations before Q4 quantization

**Reject this fixed attention-rotation family for promotion.** The fresh held-out
evaluation did not produce the required substantial AI quality gain in Small or
Turbo. No installed model, saved default or distribution is changed.

## Measured held-out results

**Reject both rotation families.** All four model/mode candidates miss the frozen material-gain targets. Small also violates original-F16 macro and Swiss/French/Arabic floors; Turbo violates Portuguese CER floors against both controls. The result rejects this fixed recipe, without establishing a limit on other weight-space methods or model capacity.

| Family | Mode | CER gain vs plain Q4 | WER gain vs plain Q4 | Frozen decision |
| --- | --- | ---: | ---: | --- |
| small | known | 1.742% | 1.816% | reject |
| small | auto | 0.156% | 0.135% | reject |
| large-v3-turbo | known | -2.901% | -3.986% | reject |
| large-v3-turbo | auto | -2.891% | -3.986% | reject |

Positive gain means lower error. The predeclared targets are at least 10% relative CER and 5% relative WER gain. Small’s known/auto original-F16 CER increases are 0.935/0.989 percentage points and WER increases 1.724/1.904 points, above the 0.25/0.50-point macro limits. Turbo’s macro floors pass, but Portuguese CER increases 1.202 points against original F16 and 1.306 against plain Q4, above the one-point language floor.

Both families pass the strict three-repeat panel: each has 54/54 hypothesis pairs and 27/27 automatic-label pairs matching, with no unknowns. Fresh held-out Small still has five observed original/rotated-F16 hypothesis differences per mode; its frozen descriptive identity status remains `inconclusive_no_promotion`, with the nullable identity field retained. This neither relaxes the panel contract nor creates a new veto. Turbo’s held-out F16 hypotheses match. Zero newly wrong coarse auto labels against either control and zero unknown pairs are observed across 144 cases per comparison; this does not establish perfect language ID or switch/fallback behavior. Existing Swiss source-base mismatches persist unchanged: two Small cases and one Turbo case, against expected `de`. These are metadata-label comparisons, not native dialect adjudication.

All 3,168 held-out calls succeeded, with 16/16 scored sources per language/model/mode. The full campaign has 4,554 terminal attempts: 4,553 successes and one unscored Base development German failure. Its full-planned German development CER/WER rates remain null at 7/8; observed partial rates are retained, and the corresponding full macros are unknown. This makes overall development quality incomplete while leaving the held-out family comparisons complete. No measured cell was retried.

### All eleven artifacts

These are equal-language means of counted corpus rates: CER nine languages, WER eight; Chinese whitespace WER is unreported. Known and auto reuse the same 144 held-out sources.

| Artifact | Known CER | Known WER | Auto CER | Auto WER |
| --- | ---: | ---: | ---: | ---: |
| Tiny F16 | 15.265% | 34.939% | 16.612% | 36.917% |
| Base F16 | 12.330% | 25.905% | 13.016% | 26.354% |
| Small F16 | 6.600% | 14.073% | 6.937% | 14.612% |
| Small rotated F16 | 6.581% | 14.123% | 6.917% | 14.663% |
| Small plain Q4 | 7.668% | 16.089% | 7.938% | 16.538% |
| Small rotated Q4 | 7.535% | 15.797% | 7.925% | 16.516% |
| Turbo F16 | 3.757% | 7.353% | 3.770% | 7.353% |
| Turbo rotated F16 | 3.757% | 7.353% | 3.770% | 7.353% |
| Turbo plain Q4 | 3.689% | 7.274% | 3.703% | 7.274% |
| Turbo rotated Q4 | 3.796% | 7.564% | 3.810% | 7.564% |
| Full Large-v3 F16 | 3.350% | 6.269% | 3.350% | 6.269% |

The complete [per-language measurements](weight-space-round4-measurements-2026-11-09.md) retain all 495 language cohorts, denominators and 55 macro rows. [Numeric exports and exact source/evidence hashes](weight-space/round-4/execution-evidence/README.md) permit inspection without publishing raw speech or transcripts.

### Per-language held-out CER

Every displayed cell has **16/16 scored sources**. These are CER percentages under the same legacy scoring; per-language WER/error-unit denominators, all other arms and full resource ranges remain in the complete appendix/CSVs. Swiss speech uses the unchanged written Standard German reference. Known and auto reuse the same audio.

#### Known-language mode

| Language | Small F16 | Small Q4 | Small rotated Q4 | Turbo Q4 | Turbo rotated Q4 | Full Large-v3 F16 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss speech → written German | 13.091% | 17.333% | 17.091% | 11.515% | 11.515% | 9.455% |
| German | 2.587% | 2.749% | 2.506% | 1.091% | 1.091% | 1.253% |
| French | 6.470% | 6.470% | 7.829% | 1.922% | 2.672% | 2.532% |
| Italian | 1.266% | 1.354% | 1.397% | 2.969% | 1.528% | 2.795% |
| English | 2.126% | 2.064% | 2.189% | 0.750% | 0.500% | 0.750% |
| Arabic | 9.467% | 10.899% | 11.058% | 3.182% | 3.341% | 2.705% |
| Chinese (Mandarin/Hans) | 20.598% | 24.086% | 21.262% | 10.299% | 10.631% | 9.136% |
| Spanish | 1.497% | 1.657% | 1.710% | 0.481% | 0.588% | 0.534% |
| Portuguese | 2.299% | 2.403% | 2.769% | 0.993% | 2.299% | 0.993% |

#### Automatic-language mode

| Language | Small F16 | Small Q4 | Small rotated Q4 | Turbo Q4 | Turbo rotated Q4 | Full Large-v3 F16 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss speech → written German | 16.121% | 19.758% | 20.606% | 11.636% | 11.636% | 9.455% |
| German | 2.587% | 2.749% | 2.506% | 1.091% | 1.091% | 1.253% |
| French | 6.470% | 6.470% | 7.829% | 1.922% | 2.672% | 2.532% |
| Italian | 1.266% | 1.354% | 1.397% | 2.969% | 1.528% | 2.795% |
| English | 2.126% | 2.064% | 2.189% | 0.750% | 0.500% | 0.750% |
| Arabic | 9.467% | 10.899% | 11.058% | 3.182% | 3.341% | 2.705% |
| Chinese (Mandarin/Hans) | 20.598% | 24.086% | 21.262% | 10.299% | 10.631% | 9.136% |
| Spanish | 1.497% | 1.657% | 1.710% | 0.481% | 0.588% | 0.534% |
| Portuguese | 2.299% | 2.403% | 2.769% | 0.993% | 2.299% | 0.993% |

### Observed resource tradeoffs

Each pair below is **known / auto**. Every mode has 144/144 successful invocations, 144 wall/RSS/load observations and one complete-workload RTF aggregate over 1,621.072 source-audio seconds. Medians are pooled from individual invocations; ranges, maxima and exact counts remain in the CSVs. File bytes are exact; RSS uses MiB (1,048,576 bytes). These are shared-desktop observations, **UNCONTROLLED / NOT EVALUATED** for resource acceptance.

| Artifact | Model bytes | Wall median s K/A | RSS median MiB K/A | Upstream load median ms K/A | Whole-workload RTF K/A |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tiny F16 | 77,691,713 | 2.647 / 2.619 | 274.2 / 274.4 | 199.3 / 204.8 | 0.233 / 0.233 |
| Base F16 | 147,951,465 | 2.675 / 2.759 | 383.5 / 383.6 | 224.2 / 215.1 | 0.238 / 0.243 |
| Small F16 | 487,601,967 | 3.009 / 3.021 | 857.7 / 857.8 | 317.7 / 304.2 | 0.269 / 0.267 |
| Small rotated F16 | 487,601,967 | 2.990 / 3.010 | 857.6 / 857.7 | 290.2 / 284.8 | 0.266 / 0.269 |
| Small plain Q4 | 145,458,015 | 2.769 / 2.831 | 476.7 / 476.9 | 187.3 / 207.8 | 0.248 / 0.250 |
| Small rotated Q4 | 145,458,015 | 2.838 / 2.846 | 476.7 / 476.7 | 203.2 / 191.5 | 0.252 / 0.252 |
| Turbo F16 | 1,624,555,275 | 3.883 / 2.783 | 1928.8 / 1928.4 | 619.2 / 476.1 | 0.344 / 0.286 |
| Turbo rotated F16 | 1,624,555,275 | 2.456 / 2.626 | 1928.2 / 1928.2 | 461.5 / 459.8 | 0.219 / 0.235 |
| Turbo plain Q4 | 473,992,235 | 1.637 / 1.839 | 745.7 / 746.0 | 149.9 / 149.5 | 0.146 / 0.164 |
| Turbo rotated Q4 | 473,992,235 | 1.627 / 3.052 | 745.8 / 746.2 | 150.5 / 216.9 | 0.145 / 0.242 |
| Full Large-v3 F16 | 3,095,033,483 | 5.436 / 5.670 | 4034.4 / 4034.4 | 1040.6 / 1054.8 | 0.485 / 0.506 |

Plain Turbo Q4 is a useful **conventional-compression research lead**: at 473,992,235 bytes it achieves known/auto CER 3.689%/3.703% and WER 7.274%/7.274%, versus Small F16’s 6.600%/6.937% CER and 14.073%/14.612% WER at 487,601,967 bytes. Its observed wall/RSS values are also lower in this run. Italian CER nevertheless worsens from 1.266% to 2.969% in both modes, so this aggregate lead is not a uniform per-language improvement. This is separate from the rejected AI rotation, adds no new frozen adoption decision, and needs fresh representative/native and controlled resource/startup/packaging evidence before any default change. Timing variation among numerical controls prevents a causal speedup claim for rotation.

## Audit and validation evidence

The independent final audit reconciled 21,416 native count/rate checks, 495 quality and resource cohorts, 55 macro rows and all 327 gate observations (279 true, 47 false, one unknown). The unknown is Base development's incomplete planned grid and remains visible. Opaque post-run hashing verified 1,029 frozen inputs and inventoried 72,969 retained output files; its recording-priority guard closed with exit zero and owned-session cleanup. All 2,484 native parent pairs and 828 derived Q4 contrasts are complete; 1,242 reference-only placeholders remain separately unpaired.

- Final independent numeric/gate receipt: `69bd834cfd96dde4ddf8b1fd31335d200b8b63c33cabb465b6034dd8b834322d`.
- Post-run preservation receipt: `82149a50ce679bde1f18777d834d4430cfc6c9d9670095951765e4e876fe83d3`; closed guard `ec271b760510c896b8d02b95b8441b8706cf2785849f1fe0393f2fc9f2ef7ce0`.
- Summary/projector hashes, both unchanged raw journals and the explicitly derived logical journal are recorded in the public curated evidence index.

Local operator/export/assessment contracts, mandatory native/frozen checks and current predecessor full-CI evidence are detailed in the execution record. Full CI passed exact heads `08584bd` and parent `02ee557`, including native 87/15, functional/TSan each 461 tests in 86 matching suites (458 passed, three existing matching skips, zero failures), complete evidence gates and Release. Historical failed runs remain failed; the intermittent native hang is not proven fixed. The final publication head still requires its own complete-PR full CI. No fixture was rebaselined.

## Fixed experiment

The [prospective protocol](weight-space-round4-protocol.md) fixes Small and
large-v3-turbo as adaptation targets. Each has original F16, rotated F16,
ordinary Q4_0 and rotated Q4_0 arms. Untouched multilingual Tiny, Base and full
Large-v3 supply the other references. No training, fitting, mask/seed/head search
or outcome-based recipe replacement is used.

The AI-authored operator applies deterministic signed Hadamard rotations within
each 64-coordinate attention head, including encoder self-attention, decoder
self-attention and cross-attention. Paired Q/K and V/output transformations
preserve the attention function in real arithmetic. LayerNorm, MLPs, residual
streams, embeddings and vocabulary remain unchanged. Offline F64 accumulation
rounds back to original storage; finite weights and native caches can change
decoding, so numerical identity must be measured.

Rotation's quality effect is **rotated Q4 versus plain Q4** within the same
family, mode and source rows. Original versus rotated F16 is the separate
numerical control. Plain Q4 versus original F16 measures conventional compression.
The two Q4 files per family have equal byte lengths and layouts, with different
selected weight payloads and hashes. Rotation adds no parameter or file-size
reduction. Actual Q4 files are 145,458,015 bytes for Small and 473,992,235 for
Turbo: 70.1687% and 70.8233% below their respective original F16 files. Turbo Q4
is 13,609,732 bytes below Small F16; size alone establishes no quality advantage.
All eleven artifact hashes are in the [frozen inventory](weight-space-round4-artifacts-2026-11-07.md).

The unchanged comparison CLI, native binary/libraries, model hashes, host/software
fingerprint and effective settings are retained. The original `c214a8e` source
and hashed control CLI remain recoverable. Every arm uses two threads, no VAD,
no prompt or cross-source context, inherited beam/best-of 5 and temperature
fallback increment 0.2, native Flash Attention and F16 caches. Known language uses the source
base label (`de` for Swiss); automatic mode remains unrestricted.

## Fresh data and interpretation

There are 72 new development and 144 new held-out sources: eight and sixteen per
language. Swiss German speech targets the unchanged published **written Standard
German** reference. Swiss receives the same language floors as German, French,
Italian, English, Arabic, Chinese, Spanish and Portuguese. Dialect spelling is
a separate unmeasured task. Regional/script coverage and Swiss canton counts are
documented in the artifact inventory: FLEURS locales are Germany, France, Italy,
US English, Egypt Arabic, Mandarin/Simplified Chinese, Latin American Spanish and
Brazilian Portuguese. These locale labels are not native dialect approval.

Recorded IDs, audio/reference hashes and known Swiss speakers were excluded
against all seven consumed manifests. The 24 new published Swiss speaker IDs are
disjoint across splits and from 46 prior IDs. FLEURS speakers are unknown for
192 cases; all 216 sessions are unknown. All fresh cases are unreviewed short
read speech, mono channel 0, without switch annotations. Natural long-form,
adverse/non-speech/overlap, broader regions/scripts, native critical-content,
reviewed-v2, switches/fallback and real independent-channel/live acceptance remain
pending. Hash separation does not establish absence from model pretraining.

Quality uses successful canonical repeat 1 only, without fallback to later
repeats, retaining `swift-nfc-casefold-alphanumeric-v1` scoring. Each language rate
divides summed edit errors by summed reference units.
Macro CER equally weights nine languages; macro WER eight, with Chinese whitespace
WER unreported. Missing planned coverage keeps full rates and macros unknown;
observed partial counts stay separate. Modes, artifacts and panel repeats reuse
the same speech, so call/pair counts do not multiply independent sources.

The predeclared practical improvement bar is at least 10% relative macro CER and
5% relative macro WER gain over plain Q4, with original-F16 macro increases no greater
than 0.25/0.50 percentage points and per-language increases no greater than one
CER/two WER points against both controls. Further gates require no newly wrong
coarse automatic labels, at least 65% actual file saving and exact rotated-F16
hypothesis/automatic-label agreement in all three numerical-panel repeats.
Unknown evidence cannot pass; a known failed gate rejects despite other unknowns.
These are material-effect thresholds, not statistical-significance claims.

## Measurement scope and preservation

Wall time includes inspection, loading, inference, validation and rendering.
Upstream load timers do not measure full initialization or first-result latency.
Process RSS is not total unified GPU allocation. Reported workload RTF is summed
wall time divided by summed source duration, with its aggregate count kept
separate from invocation counts. Shared-desktop resource acceptance is
**UNCONTROLLED / NOT EVALUATED**; energy, complete GPU memory and actual
download/bundle/installed-app increments remain unmeasured.

The [execution record](weight-space-round4-execution-2026-11-09.md) preserves the
actual metadata stop, both raw journals and prospective continuation. No measured
call was retried, transcript timing repaired or gate weakened. Original weights,
audio, references, raw transcripts, source timing and provenance remain protected
externally. The [source archive](weight-space/round-4/execution-evidence/README.md)
distinguishes actual executing scripts, reused numerical cores and derived
logical history. Final opaque preservation and independent numeric/gate audits
have passed; native/product and controlled resource gates remain pending. No installed-app, default or distribution change, and no
automatic merge.
