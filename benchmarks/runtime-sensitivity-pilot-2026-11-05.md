# Runtime sensitivity pilot, 2026-11-05

Keep the current runtime defaults: no VAD and inherited beam/search/fallback
settings. This Tiny-only development diagnostic found substantial sensitivity to
a constructed quiet prefix, alongside language-specific regressions and an empty
automatic-output case under attenuation. It does not establish formal runtime
acceptance, native-language correctness or a default promotion.

All **540 inference cells and 540 paired cells** completed: U 216/216,
Q30 162/162 and A18 162/162. Inference statuses are `completed_with_review`;
pairs are `paired_exploratory`. These statuses describe execution, not human
approval. Each source/profile/language-mode combination has three inference
repeats; quality and language-label results use repeat 1 only. The nine parent
utterances are reused across three conditions:
27 condition instances are not 27 people or independent utterances, and the
human speaker count remains unknown.

## Inputs, source timing and experimental arms

U uses the previously selected nine development utterances, one per priority
language. Q30 prepends exactly 480,000 zero-valued PCM16 frames (30 seconds) while
preserving every source PCM sample. Its source-to-derived time map adds 30 s.
A18 scales each signed PCM16 sample by 1/8, truncating toward zero, with unchanged
frame count/time; nominal gain is −18.0618 dB plus quantization. It scales
existing speech and noise together. Neither derivative establishes natural quiet
speech, realistic low-SNR/adverse conditions or long-form coverage.

Original audio, reference bytes, provenance and grouping remain protected.
The derivative preparation retains source WAV/reference/provenance and manifest
snapshots, recipe/hash evidence, and unreviewed v2-pending metadata separately
from its exploratory legacy manifest. Source IDs/speaker/session metadata are
not replaced with invented groups. FLEURS individual speaker/session identity
and native reference approval remain incomplete. The recorded development
selection preceded these outcomes; no selective retry or outcome-based
reselection is used.

| Profile | Intervention |
| --- | --- |
| control | No VAD; current decoding defaults |
| vad0 | Silero v6.2.0; padding 0 ms; overlap 0 s |
| vad30 | Same Silero settings, padding 30 ms; overlap 0.1 s |
| beam3 | Beam size 3; no VAD; U only |

Both VAD arms fix threshold 0.5, minimum speech 250 ms, minimum silence 100 ms
and maximum speech 30 s. All arms use unchanged multilingual Tiny, two threads,
whisper.cpp 1.9.5, the same frozen RecScribe runner, `-tp 0 -mc 0`, and inherited
upstream fallback/search settings except beam3's explicit beam change. Known
mode forces the source base language (`de-CH` → `de`); auto remains unrestricted.
These private VAD profiles use `current_auto`; the validated
`speech_aware_auto` policy would have the same effective recognition arguments
as Silero plus `-l auto`, so it is not a separate detector treatment.

The paired contrasts are vad0−control (Silero speech processing without added
boundary padding/overlap), vad30−vad0 (joint padding/overlap change),
vad30−control (total VAD/boundary intervention), and beam3−control on U only.
The two boundary parameters are not individually separable in this design.
Raw recognizer timestamps refer to the derived input; Q30 source projection
subtracts 30 s only over the intersection with retained source time. No word
alignment or human onset/boundary accuracy was measured.

## Descriptive result and retained-default decision

On U, the mean of the nine first-repeat CERs was 21.368% for control, 19.416%
for vad0, 20.856% for vad30 and 20.021% for beam3; known and auto results coincide
on this slice. The average hides regressions: French CER increased by 3.98
percentage points with vad0 and 15.91 with vad30. Beam3 increased CER for German,
French and Chinese. These are one-utterance observations, not representative
per-language estimates or confidence intervals.

With Q30, auto mean CER changed from 103.682% with control to 20.854% with vad0
and 21.302% with vad30. Coarse published-base-label matches changed from 1/9
planned origins to 8/9. The Swiss utterance still received `af` with both VAD
arms; the control label was `en`. This diagnoses sensitivity to a synthetic
opening and the ordering of speech processing before automatic detection. It
does not establish reliability on genuine quiet recordings or language switches.

A18 auto mean CER was 30.727% for control, 31.489% for vad0 and 31.549% for vad30.
The French control produced a nonempty scored hypothesis with an `en` label.
Both VAD auto profiles produced the exact empty scored-hypothesis hash on all
three repeats, yielding 100% CER for that utterance and an unobserved label.
The corresponding known-language VAD hypotheses were nonempty. Empty automatic
output alone cannot isolate Silero rejection from downstream decoding/no-speech
behavior; it is not proof of silence. Eight matching labels among eight observed
VAD labels remains **8 matches / 9 planned, 1 unknown**, not 100% language accuracy.

The result supports further investigation while retaining the runtime defaults.
Context/terminology, stateful switching, independent-channel/live replay,
additional models, realistic quiet/adverse/long recordings and reviewed held-out
runtime evidence remain pending. AI-authored weight adaptation and its blind
evaluation are separate research; no model-edit scores are combined here.

## Scoring and denominators

All lexical values use `swift-nfc-casefold-alphanumeric-v1` (legacy-v1):
NFC/POSIX case folding, punctuation to spaces and collapsed whitespace; CER
counts Unicode scalars and omits spaces. No v2 scoring upgrade or reference
correction is implied. Chinese whitespace WER is suppressed. Rates can exceed
100% through insertions. Missing rates would remain null/inconclusive; none are
replaced with zero or a later repeat.

The following reference-unit counts apply to the same parent reference in every
condition/profile/mode. Each quality cell contains one unique parent utterance,
using repeat 1. The macro CER below equally weights nine individual rates,
including the Swiss written-German rendering task; it is not corpus-weighted or
a population estimate. No macro WER across scripts is used.

| Language/task | Reference words | Reference scalars | Parent case ID |
| --- | --- | --- | --- |
| Swiss German → written German | 13 | 86 | `all-swiss-dialects-v1-000c8b7e-b222-4d8b-b701-0740a7c20500` |
| German | 36 | 173 | `fleurs-de-de-10013061249039105343` |
| French | 39 | 176 | `fleurs-fr-fr-10008051639162028459` |
| Italian | 22 | 108 | `fleurs-it-it-10006672303518507506` |
| English | 19 | 87 | `fleurs-en-us-10004088536354799741` |
| Arabic | 20 | 83 | `fleurs-ar-eg-10002899498199807056` |
| Mandarin (Hans) | — | 38 | `fleurs-cmn-hans-cn-10009480476880474721` |
| Spanish (es_419) | 10 | 54 | `fleurs-es-419-10005668950815513748` |
| Portuguese (pt_BR) | 44 | 228 | `fleurs-pt-br-10009971053374752024` |


### Macro CER, descriptive only

| Condition | Profile | Known mean CER | Auto mean CER | Origins per mode planned/scored |
| --- | --- | --- | --- | --- |
| U | control | 21.368% | 21.368% | 9 / 9 |
| U | vad0 | 19.416% | 19.416% | 9 / 9 |
| U | vad30 | 20.856% | 20.856% | 9 / 9 |
| U | beam3 | 20.021% | 20.021% | 9 / 9 |
| Q30 | control | 27.503% | 103.682% | 9 / 9 |
| Q30 | vad0 | 20.725% | 20.854% | 9 / 9 |
| Q30 | vad30 | 21.432% | 21.302% | 9 / 9 |
| A18 | control | 28.328% | 30.727% | 9 / 9 |
| A18 | vad0 | 30.669% | 31.489% | 9 / 9 |
| A18 | vad30 | 30.728% | 31.549% | 9 / 9 |


## Every language/profile/mode: first-repeat WER / CER

All entries are percentages, displayed as **WER / CER**. Chinese uses **— / CER**. Known and auto are separate rows even where values coincide. Each displayed pair has one parent reference; the three repeats do not multiply its quality denominator.


### U — unchanged

| Language/task | Mode | control | vad0 | vad30 | beam3 |
| --- | --- | --- | --- | --- | --- |
| Swiss German → written German | known | 115.38 / 54.65 | 100.00 / 48.84 | 115.38 / 55.81 | 115.38 / 50.00 |
| Swiss German → written German | auto | 115.38 / 54.65 | 100.00 / 48.84 | 115.38 / 55.81 | 115.38 / 50.00 |
| German | known | 2.78 / 0.58 | 8.33 / 2.31 | 5.56 / 1.73 | 8.33 / 3.47 |
| German | auto | 2.78 / 0.58 | 8.33 / 2.31 | 5.56 / 1.73 | 8.33 / 3.47 |
| French | known | 41.03 / 18.75 | 46.15 / 22.73 | 69.23 / 34.66 | 51.28 / 23.30 |
| French | auto | 41.03 / 18.75 | 46.15 / 22.73 | 69.23 / 34.66 | 51.28 / 23.30 |
| Italian | known | 36.36 / 7.41 | 36.36 / 8.33 | 22.73 / 6.48 | 18.18 / 2.78 |
| Italian | auto | 36.36 / 7.41 | 36.36 / 8.33 | 22.73 / 6.48 | 18.18 / 2.78 |
| English | known | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 |
| English | auto | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 | 15.79 / 8.05 |
| Arabic | known | 65.00 / 30.12 | 60.00 / 22.89 | 55.00 / 24.10 | 70.00 / 25.30 |
| Arabic | auto | 65.00 / 30.12 | 60.00 / 22.89 | 55.00 / 24.10 | 70.00 / 25.30 |
| Mandarin (Hans) | known | — / 44.74 | — / 39.47 | — / 39.47 | — / 47.37 |
| Mandarin (Hans) | auto | — / 44.74 | — / 39.47 | — / 39.47 | — / 47.37 |
| Spanish (es_419) | known | 20.00 / 7.41 | 20.00 / 3.70 | 40.00 / 5.56 | 30.00 / 3.70 |
| Spanish (es_419) | auto | 20.00 / 7.41 | 20.00 / 3.70 | 40.00 / 5.56 | 30.00 / 3.70 |
| Portuguese (pt_BR) | known | 52.27 / 20.61 | 43.18 / 18.42 | 34.09 / 11.84 | 40.91 / 16.23 |
| Portuguese (pt_BR) | auto | 52.27 / 20.61 | 43.18 / 18.42 | 34.09 / 11.84 | 40.91 / 16.23 |


### Q30 — synthetic-digital-zero-prefix-30s

| Language/task | Mode | control | vad0 | vad30 |
| --- | --- | --- | --- | --- |
| Swiss German → written German | known | 115.38 / 50.00 | 107.69 / 47.67 | 100.00 / 50.00 |
| Swiss German → written German | auto | 130.77 / 69.77 | 100.00 / 48.84 | 100.00 / 48.84 |
| German | known | 8.33 / 3.47 | 5.56 / 2.31 | 8.33 / 1.73 |
| German | auto | 141.67 / 95.38 | 5.56 / 2.31 | 8.33 / 1.73 |
| French | known | 43.59 / 22.16 | 53.85 / 27.84 | 61.54 / 32.95 |
| French | auto | 102.56 / 77.27 | 53.85 / 27.84 | 61.54 / 32.95 |
| Italian | known | 36.36 / 12.04 | 22.73 / 2.78 | 31.82 / 8.33 |
| Italian | auto | 113.64 / 68.52 | 22.73 / 2.78 | 31.82 / 8.33 |
| English | known | 21.05 / 20.69 | 15.79 / 8.05 | 15.79 / 8.05 |
| English | auto | 21.05 / 20.69 | 15.79 / 8.05 | 15.79 / 8.05 |
| Arabic | known | 100.00 / 44.58 | 70.00 / 28.92 | 65.00 / 30.12 |
| Arabic | auto | 230.00 / 165.06 | 70.00 / 28.92 | 65.00 / 30.12 |
| Mandarin (Hans) | known | — / 47.37 | — / 44.74 | — / 36.84 |
| Mandarin (Hans) | auto | — / 328.95 | — / 44.74 | — / 36.84 |
| Spanish (es_419) | known | 30.00 / 22.22 | 40.00 / 1.85 | 40.00 / 5.56 |
| Spanish (es_419) | auto | 40.00 / 25.93 | 40.00 / 1.85 | 40.00 / 5.56 |
| Portuguese (pt_BR) | known | 63.64 / 25.00 | 59.09 / 22.37 | 54.55 / 19.30 |
| Portuguese (pt_BR) | auto | 150.00 / 81.58 | 59.09 / 22.37 | 54.55 / 19.30 |


### A18 — synthetic-constant-gain-1-8

| Language/task | Mode | control | vad0 | vad30 |
| --- | --- | --- | --- | --- |
| Swiss German → written German | known | 107.69 / 47.67 | 92.31 / 46.51 | 123.08 / 65.12 |
| Swiss German → written German | auto | 107.69 / 47.67 | 92.31 / 46.51 | 123.08 / 65.12 |
| German | known | 2.78 / 0.58 | 19.44 / 6.94 | 5.56 / 1.73 |
| German | auto | 2.78 / 0.58 | 19.44 / 6.94 | 5.56 / 1.73 |
| French | known | 100.00 / 96.59 | 100.00 / 92.61 | 100.00 / 92.61 |
| French | auto | 225.64 / 118.18 | 100.00 / 100.00 | 100.00 / 100.00 |
| Italian | known | 22.73 / 4.63 | 22.73 / 4.63 | 22.73 / 6.48 |
| Italian | auto | 22.73 / 4.63 | 22.73 / 4.63 | 22.73 / 6.48 |
| English | known | 15.79 / 8.05 | 21.05 / 11.49 | 15.79 / 8.05 |
| English | auto | 15.79 / 8.05 | 21.05 / 11.49 | 15.79 / 8.05 |
| Arabic | known | 65.00 / 28.92 | 80.00 / 39.76 | 65.00 / 32.53 |
| Arabic | auto | 65.00 / 28.92 | 80.00 / 39.76 | 65.00 / 32.53 |
| Mandarin (Hans) | known | — / 42.11 | — / 44.74 | — / 47.37 |
| Mandarin (Hans) | auto | — / 42.11 | — / 44.74 | — / 47.37 |
| Spanish (es_419) | known | 40.00 / 1.85 | 20.00 / 7.41 | 40.00 / 5.56 |
| Spanish (es_419) | auto | 40.00 / 1.85 | 20.00 / 7.41 | 40.00 / 5.56 |
| Portuguese (pt_BR) | known | 72.73 / 24.56 | 56.82 / 21.93 | 43.18 / 17.11 |
| Portuguese (pt_BR) | auto | 72.73 / 24.56 | 56.82 / 21.93 | 43.18 / 17.11 |


## Coarse automatic labels and empty scored hypotheses

These are structured nonempty automatic recognizer labels compared with published monolingual base tags, not independently adjudicated language-ID accuracy. Known-language rows are forced controls and excluded. Confidence, intra-file switches and out-of-set acceptance are unmeasured.

| Condition | Profile | Planned | Observed | Matches | Mismatches | Unknown/excluded |
| --- | --- | --- | --- | --- | --- | --- |
| U | control | 9 | 9 | 9 | 0 | 0 |
| U | vad0 | 9 | 9 | 9 | 0 | 0 |
| U | vad30 | 9 | 9 | 9 | 0 | 0 |
| U | beam3 | 9 | 9 | 9 | 0 | 0 |
| Q30 | control | 9 | 9 | 1 | 8 | 0 |
| Q30 | vad0 | 9 | 9 | 8 | 1 | 0 |
| Q30 | vad30 | 9 | 9 | 8 | 1 | 0 |
| A18 | control | 9 | 9 | 8 | 1 | 0 |
| A18 | vad0 | 9 | 8 | 8 | 0 | 1 |
| A18 | vad30 | 9 | 8 | 8 | 0 | 1 |


All U labels matched the nine published base tags. On Q30, control labelled all nine inputs `en`; only the English input matched. VAD labelled the Swiss input `af` and the other eight inputs with matching bases. On A18, French was the control's sole mismatch (`en`), while both VAD arms had French unknown because their scored hypothesis was empty.

There were exactly six empty scored-hypothesis hash observations across 540 completed repeats: A18 French auto vad0 and vad30, each 3/3. Their repeat-1 WER/CER are 100%/100%; they remain included in lexical denominators. All 180 condition/language/profile/mode groups had one distinct scored-hypothesis hash across three repeats. This describes this run's output stability, not proven silence rejection or general reproducibility.

## Resources, provenance and reproduction

Resource/performance status is **UNCONTROLLED / NOT EVALUATED**. This was a
quality-only shared-desktop run with recording priority, bounded/cancellable
serial work and finite execution budgets. Actual per-language timing, upstream
model-load observations and process RSS remain in the protected stage reports
and matrices; they are not hidden or discarded. They do not establish speed,
latency, total unified GPU/CPU memory, energy or resource-gate improvement.
No first-result latency or controlled performance claim is made. Adding a
synthetic 30 s to a duration denominator must not manufacture a speed claim.

Protected root:
`~/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/`.
Each `U/`, `Q30/` and `A18/` retains `matrix/matrix.json`, immutable
corpus/config/profile snapshots, raw canonical jobs and `report-v1.1/report.json`
plus Markdown. `summary-v1/summary.json` and Markdown are the frozen analyzer's
descriptive extraction; this public report reads structured metrics only.
The original [810-cell, five-model baseline](pilot-baseline-2026-11-05.md) remains
a separate unchanged reference, with its recorded host/software and limitations.

| Identity | SHA-256 |
| --- | --- |
| Untouched Tiny model (77,691,713 bytes) | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| Official Silero v6.2.0 (885,098 bytes) | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |
| whisper-cli 1.9.5 | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| RecScribe runner | `5e5dad40ce2d3992a6e6bc6ccc71f9dbe5849ff3f2b00f2bcb8f815b17ecf879` |
| Pre-outcome runtime protocol | `450e7e32036cdb69ee0db0e324f24ea8ba4b8f629d0734f0c95462cecf5bb004` |
| Pre-execution runtime/library inventory | `15b6ad9b1deb221413e2933baba4e2d2f06f37dfb031ddca0c4124cebb536e86` |
| Analyzer frozen after synthetic validation | `d50d55728d8916f9663e16b8b02abb7370e45705de4b168c81da94733f892cea` |
| Structured summary | `b6bc0d372f2fd14c488c29587793970196001fb80e05b104fc391917b7849fe9` |

The full native library inventory and profile file hashes are retained in
`pre-execution-runtime-identities.json` and `runtime-protocol.freeze.json`.
VAD source revision/license and static checks are documented in
[speech/language experiments](speech-language-experiments.md); this run used that
official pinned input. Actual model/download bytes are artifact sizes, not an
inferred app-bundle increment or GPU allocation.


| Stage | Retained evidence | SHA-256 |
| --- | --- | --- |
| U | matrix | `1a3f5682573a10fbad7873154b416a7c5d6427a8f5f9dfed5f42eb5652226c19` |
| U | report-v1.1 | `2972d4ca1789edf676342a7a8a69929f3322b7a57aa45c0f3cd13d3181a15707` |
| U | corpus snapshot | `82388b43b4205de18a1b63299b8258e6b7ec07120dc35e6d064238e49cadc137` |
| U | configuration snapshot | `a917a3eaecbb9e8f6d6d855247e8fb6c3cb02552a55dd1f64dec071340d2130c` |
| Q30 | matrix | `d13e18847c51d202f5c278bf3cac1889699a770f8e32b40bca31030bf9206033` |
| Q30 | report-v1.1 | `ec618a4a09b518519c4bcd9a9f6f8fa7ed779b965f8be444778c72a43ffca435` |
| Q30 | corpus snapshot | `c8f9793dbeee59251944e8fd31d2804214ed53947b939d534cc69ab676462898` |
| Q30 | configuration snapshot | `5af64c44724a3da15bf85d74b0c0e3e38813a2629b4c6d9cf4c97b3e3f38e5d2` |
| A18 | matrix | `d529ca5e75c166093abe2172e91c94c08ed7598005fd0c27fc58712e9a104168` |
| A18 | report-v1.1 | `ed99df4b3c0991dfc1c8dca53a002d57b2d36547787c39561112bf01e4a5b1b3` |
| A18 | corpus snapshot | `9877f57b3f4645c3954aa4afa40a166dcac071ba166e4d019e6f7e388c9d593d` |
| A18 | configuration snapshot | `eb01dfeb62533013b1a4bb78c4025113d0a4bc80ba6d4127389d0749b416226d` |


The analyzer was frozen before actual outcome analysis after 12 synthetic
validation tests, covering complete/missing/failed/null cells, repeat-1 selection,
hash/profile/source mismatches, Chinese suppression, empty hashes and unknown
labels. It validates report→matrix hashes, fixed row/pair grids, model/runtime/
VAD/profile identities, counted metrics and paired deltas. Its corpus/config
validation matches the public reporter's verified snapshot attestations to the
pinned protocol; the analyzer itself does not reread those corpus/config files.
The bounded derivative recipe's 11 offline tests and the public reporter tests
provide preparation/reporting evidence, not native quality approval. No new app
build, installed-app update, retraining or model-weight edit is part of this
runtime result. Required PR validation and native/held-out runtime acceptance
remain separate.

To reproduce the structured extraction into a new protected directory, use the
retained frozen analyzer through the managed wrapper:

```sh
python3 scripts/work-artifacts.py run --label runtime-summary logs -- \
  python3 "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/summarize-runtime.py" \
  --u-report "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/U/report-v1.1/report.json" \
  --q30-report "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/Q30/report-v1.1/report.json" \
  --a18-report "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/A18/report-v1.1/report.json" \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/runtime-sensitivity-round1/summary-NEW"
```

Sources: eight language inputs and published references come from
[Google FLEURS, pinned revision](https://huggingface.co/datasets/google/fleurs/blob/b4a42ed06e12025c42f3b4eff6338ace2fe2447a/README.md),
CC BY 4.0; the Swiss input and published written-Standard-German reference come
from [FHNW All Swiss German Dialects Test Set v1](https://www.cs.technik.fhnw.ch/i4ds-datasets),
MIT. Retained source pages/cards/release metadata preserve attribution and rights
evidence. Public-pretraining overlap is possible. The Arabic slice is read
Arabic/MSA from ar_eg, not proof of Egyptian dialect; Chinese is Mandarin/
Simplified, Spanish es_419 and Portuguese pt_BR. Other regional/script varieties
and pan-Swiss coverage remain pending. Native reviewers have not adjudicated
content, names, quantities, negation, switches, equivalent Swiss rendering or
these reference/audio pairs.
