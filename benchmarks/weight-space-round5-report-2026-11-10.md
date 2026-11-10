# Round 5: fixed MLP permutation before Q4 — rejected

Both Small and large-v3-turbo are **REJECTED** in known and automatic language
modes under the [frozen protocol](weight-space-round5-protocol.md). Small became
worse than ordinary Q4 on CER and WER. Turbo's WER gain was below the required
5%, while CER became slightly worse. No model, default, package or installed-app
change is promoted. These are frozen practical effect thresholds, not claims of
statistical significance.

All **4,554/4,554 calls succeeded**, including all 3,168 held-out calls. Counted
quality is complete: 2,484 native original-parent pairs, 828 derived Q4 sibling
contrasts, and 1,242 separately unpaired reference placeholders. The four final
guarded steps—opaque preservation, summary, projection and independent numeric
audit—passed without retry, repair or changed gates. The audit checked 21,420
count/rate relations and 327 gate values: 278 true, 49 false, zero unknown.

## Intervention and attribution

One fixed AI-authored weight-only ordering sorted original MLP down-projection
columns by max absolute weight, breaking ties by original index. Matching first
projection rows/biases and second projection columns were byte-permuted in all
24 Small and 36 Turbo MLPs. Elementwise GELU permits this real-arithmetic symmetry;
finite reduction order still needs numerical controls. There was no training,
fitting, calibration, order/layer search, parameter reduction or runtime change.

The four arms were original F16, permuted F16, ordinary official Q4_0, and permuted
F16→Q4_0. Tiny, Base and full Large-v3 stayed untouched F16 references. Incremental
AI benefit is **permuted Q4 versus ordinary Q4**. Both Q4 arms have equal file
lengths: their 70.169% Small / 70.823% Turbo savings come from conventional Q4,
with **zero additional bytes saved by permutation**. Lower static reconstruction
error did not establish a useful speech-quality gain.

## Frozen held-out result

Positive gain means improvement; macro deltas are absolute percentage points.

| Family / mode | CER gain vs Q4 % | WER gain vs Q4 % | CER Δ vs F16 pp | WER Δ vs F16 pp | Decision |
| --- | --- | --- | --- | --- | --- |
| Small / known | -10.277 | -3.042 | +1.112 | +2.141 | REJECT |
| Small / auto | -7.074 | -3.910 | +1.504 | +2.640 | REJECT |
| Turbo / known | -0.689 | +1.759 | -0.072 | -0.161 | REJECT |
| Turbo / auto | -0.689 | +1.759 | -0.072 | -0.161 | REJECT |

The required gains were ≥10% relative CER and ≥5% relative WER versus ordinary
Q4. Original-F16 macro increases could be at most 0.25 CER / 0.50 WER points;
every language against both controls could increase at most 1 CER / 2 meaningful
WER points. Size saving had to be ≥65%, with no newly wrong coarse auto label.
All four held-out mode decisions have no unknown gates.

Small failed the gain, macro and multiple language floors, including Swiss speech
rendered as written Standard German and French/English/Arabic/Chinese/Portuguese constraints; automatic
mode also introduced 1 newly wrong base-language label against original
F16. Turbo passed its other held-out gates but failed both incremental gain
targets. The exact false/unknown lists are in [gate-headlines.json](weight-space/round-5/execution-evidence/gate-headlines.json).

Each family passed its strict original-development numerical panel: all 54
required hypothesis pairs and 27 automatic-label pairs matched across three
repeats, with no unknowns. Later held-out F16 controls had three differing
hypotheses per mode for Small and two for Turbo, with no differing auto labels.
Their retained descriptive control status is inconclusive; those observations
are not a new held-out veto. Known-mode label bookkeeping is N/A, not auto evidence.
Quality always uses successful repeat 1; later repeats are not fallback quality
or additional independent speech.

## Quality, sizes and language scope

K/A means known/auto. Macros use per-language summed errors/units and equal
language weights: CER nine languages, WER eight. Chinese whitespace WER is
unreported. All table rates below have complete planned coverage.

| Artifact | File MiB | CER % K / A | WER % K / A |
| --- | --- | --- | --- |
| Tiny F16 | 74.09 | 17.559 / 18.259 | 38.392 / 39.833 |
| Base F16 | 141.10 | 12.470 / 13.119 | 24.912 / 25.939 |
| Small F16 | 465.01 | 6.902 / 7.017 | 14.966 / 15.167 |
| Small permuted F16 | 465.01 | 6.882 / 6.997 | 15.050 / 15.251 |
| Small Q4 | 138.72 | 7.267 / 7.958 | 16.602 / 17.137 |
| Small permuted Q4 | 138.72 | 8.014 / 8.521 | 17.107 / 17.807 |
| Turbo F16 | 1549.30 | 4.002 / 4.002 | 8.908 / 8.908 |
| Turbo permuted F16 | 1549.30 | 3.993 / 3.993 | 8.908 / 8.908 |
| Turbo Q4 | 452.03 | 3.903 / 3.903 | 8.904 / 8.904 |
| Turbo permuted Q4 | 452.03 | 3.930 / 3.930 | 8.747 / 8.747 |
| Large-v3 F16 | 2951.65 | 3.652 / 3.652 | 8.205 / 8.205 |

The nine-source original panel is separate from 72 fresh DEV and 144 fresh held-out
sources, 8/16 per language. Source/audio/reference hashes and recorded groups
were excluded against consumed data. Swiss speakers exclude 70 prior IDs;
192 FLEURS speakers and all 216 fresh sessions remain unknown. No pretraining
exclusion or population-representative claim follows.

Swiss speech targets published written Standard German, not independently
referenced dialect wording; it receives the same floors and macro weight. FLEURS
coverage is de_DE/fr_FR/it_IT/en_US/ar_EG/cmn_hans_CN/es_419/pt_BR. German, French,
Italian, English, Spanish and Portuguese use Latin script; Arabic uses Arabic
script; Mandarin uses Simplified Chinese. The Egypt locale is not independent
dialect adjudication. Swiss source canton labels were DEV: Thurgau (TG) 1,
Graubünden (GR) 1, Zürich (ZH) 2, Zug (ZG) 1, Solothurn (SO) 1, Lucerne (LU) 1,
St Gallen (SG) 1; held-out: Aargau (AG) 3, LU 1, GR 1, Bern (BE) 4, ZH 3, ZG 2,
SG 1, SO 1. This is uneven source metadata, not all-Switzerland coverage.

Held-out CER %, 16 sources per language/artifact/mode:

### Known language

| Language | Small F16 | Small Q4 | Small perm Q4 | Turbo F16 | Turbo Q4 | Turbo perm Q4 |
| --- | --- | --- | --- | --- | --- | --- |
| de-CH | 12.398 | 14.503 | 16.140 | 8.772 | 8.772 | 8.772 |
| de | 2.866 | 2.464 | 2.262 | 2.514 | 1.911 | 2.212 |
| fr | 3.890 | 3.770 | 5.087 | 1.496 | 1.137 | 1.137 |
| it | 0.847 | 0.758 | 0.936 | 0.535 | 0.535 | 0.669 |
| en | 2.839 | 3.430 | 4.080 | 2.898 | 2.898 | 2.898 |
| ar | 13.090 | 14.372 | 15.115 | 6.748 | 6.883 | 6.275 |
| zh | 18.382 | 18.015 | 20.221 | 8.824 | 8.640 | 9.007 |
| es | 2.960 | 3.700 | 2.729 | 1.711 | 1.896 | 1.943 |
| pt | 4.845 | 4.393 | 5.556 | 2.519 | 2.455 | 2.455 |

### Auto language

| Language | Small F16 | Small Q4 | Small perm Q4 | Turbo F16 | Turbo Q4 | Turbo perm Q4 |
| --- | --- | --- | --- | --- | --- | --- |
| de-CH | 12.632 | 19.415 | 19.649 | 8.772 | 8.772 | 8.772 |
| de | 3.670 | 3.771 | 3.318 | 2.514 | 1.911 | 2.212 |
| fr | 3.890 | 3.770 | 5.087 | 1.496 | 1.137 | 1.137 |
| it | 0.847 | 0.758 | 0.936 | 0.535 | 0.535 | 0.669 |
| en | 2.839 | 3.430 | 4.080 | 2.898 | 2.898 | 2.898 |
| ar | 13.090 | 14.372 | 15.115 | 6.748 | 6.883 | 6.275 |
| zh | 18.382 | 18.015 | 20.221 | 8.824 | 8.640 | 9.007 |
| es | 2.960 | 3.700 | 2.729 | 1.711 | 1.896 | 1.943 |
| pt | 4.845 | 4.393 | 5.556 | 2.519 | 2.455 | 2.455 |

Full meaningful per-language WER, denominators, counts and all stage cohorts are
in [quality.csv](weight-space/round-5/execution-evidence/quality.csv) and the
[verbatim measurements appendix](weight-space-round5-measurements-2026-11-10.md).
German, French, Italian, English, Arabic, Chinese, Spanish, Portuguese and Swiss
German are all retained; no language is selected out of the final result.

## Latency and resource tradeoffs

The following are pooled per-model/mode medians of 144 successful held jobs;
all wall/RSS/load observation counts are 144. Each workload RTF is one sum-wall /
sum-audio aggregate over the same 1,646.561 seconds, not a median of language
medians. Ranges, maxima and counts remain in the exact resource exports.

| Artifact | Wall s K / A | Load ms K / A | RSS MiB K / A | Workload RTF K / A |
| --- | --- | --- | --- | --- |
| Tiny F16 | 1.122 / 2.273 | 43.4 / 70.2 | 273.7 / 274.0 | 0.099 / 0.171 |
| Base F16 | 2.653 / 2.678 | 222.2 / 225.9 | 383.4 / 383.4 | 0.233 / 0.236 |
| Small F16 | 3.008 / 3.040 | 298.2 / 301.1 | 857.6 / 857.5 | 0.263 / 0.265 |
| Small permuted F16 | 3.014 / 3.041 | 299.7 / 293.6 | 857.6 / 857.7 | 0.264 / 0.267 |
| Small Q4 | 2.755 / 2.866 | 207.9 / 192.8 | 476.6 / 476.8 | 0.244 / 0.254 |
| Small permuted Q4 | 2.785 / 2.866 | 186.5 / 204.6 | 476.8 / 476.6 | 0.244 / 0.252 |
| Turbo F16 | 3.875 / 3.499 | 635.2 / 586.0 | 1928.6 / 1928.7 | 0.340 / 0.314 |
| Turbo permuted F16 | 3.906 / 4.052 | 600.4 / 590.8 | 1928.6 / 1928.7 | 0.340 / 0.356 |
| Turbo Q4 | 3.069 / 3.271 | 283.9 / 291.7 | 746.0 / 746.3 | 0.269 / 0.287 |
| Turbo permuted Q4 | 3.095 / 3.275 | 283.1 / 281.0 | 746.1 / 746.3 | 0.270 / 0.286 |
| Large-v3 F16 | 5.392 / 5.662 | 1034.7 / 1032.1 | 4034.2 / 4034.2 | 0.475 / 0.495 |

These shared-desktop observations are **UNCONTROLLED / NOT EVALUATED** for
resource acceptance. Wall includes preparation/inspection, model load, ASR and
rendering. The upstream load timer excludes full initialization/first-result
latency; process RSS is not total unified GPU memory or concurrent recording
memory. Energy, first result and actual bundle/download increments are unmeasured.
Observed Q4 size/load/RSS savings do not demonstrate an incremental permutation
speed benefit or authorize a compact default.

## Validation, provenance and remaining acceptance

Six initialization-only checks passed on the exact native backend, and all fixed
ASR calls completed. Native human review, reviewed-v2/product acceptance and
broader long/adverse/non-speech/switch/live/independent-channel evidence remain
pending. Multilingual fallback and app behavior were not changed.

The recorded host was Mac14,14 (24 CPUs, 64 GiB); the hash-bound native load log
names its Metal GPU `MTL0 (Apple M2 Ultra)`. Software was macOS 26.6.2, Xcode
27.1 / Swift 6.4, Python 3.15.0 / NumPy 2.5.4, whisper.cpp 1.9.5 / ggml 0.27.0.
Every R5 arm used the same pre-existing `a55b9ef…` comparison CLI (`5190e4d…`),
including its earlier Q4 support; R5 did not rebuild or change that runtime.
The distinct original `c214a8e…` control (`9788fa4…`) remains untouched and
recoverable. Method/assessment and explicit legacy-v1 scoring-policy sources
were frozen at `e03c5ca…`. The separately admitted `59a1b7f…` checkout included
the test-only teardown repair and full CI; it is not the comparison binary's
source revision. Two threads, no VAD/prompt/cross-source text state,
beam/best-of 5, temperature fallback increment 0.2, native FA/F16 caches and the
known-base/unrestricted-auto policies stayed fixed. All ten panel/DEV grids were
assessed before five held-out plans sealed together; no measured cell was retried.

The opaque audit preserved 1,097 frozen inputs and 72,974 retained outputs across
225 distinct source cases. Raw audio, references, transcripts, corpus manifests,
models and binaries remain externally protected. See the [evidence index](weight-space/round-5/execution-evidence/evidence-index.json)
and [replay/access limits](weight-space/round-5/execution-evidence/README.md).
The exact 107-file source archive and separate six-file replay addendum are
inspection copies, with a separately labelled post-inference execution driver.

Historical full CI at `59a1b7f…` [passed](https://github.com/moreaki/recscribe/actions/runs/42692826227): native/frozen contracts 87 tests
in 15 suites; complete functional and TSan runs each 461 tests/86 suites,
458 passed plus the same three skips, no failures/runtime diagnostics/restart,
and Release/evidence gates passed. **Full CI on the new publication head is
pending**; the historical pass does not replace it. No fixtures were rebaselined
and no automatic merge or default promotion is authorized.
