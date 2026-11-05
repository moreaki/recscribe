# Nine-language untouched Whisper pilot — 2026-11-05

The first measured development baseline completed **810/810 inference cells**:
27 original utterances, five untouched multilingual models, known/automatic
language modes and three repeats. All cells completed with review status; none
failed or remained pending. This is an **exploratory short read-speech pilot**,
not representative multilingual acceptance or an adapted-model result.

Accuracy below uses **repeat 1 only**: three unique utterances per language,
not nine independent samples. Known and automatic modes produced the same
aggregate lexical scores in this pilot, so one quality table represents both.
All three repeats had stable hypothesis hashes within each model/mode/utterance.
No raw audio, reference text or recognizer text is included here.

## Inputs, scope and scoring

- Swiss German: three published speakers from the FHNW **All Swiss German
  Dialects Test Set v1**, MIT, public split; published canton labels **BE, AG,
  SH**. The target is written Standard German, scored as `standard_rendering`.
  These three speakers do not establish broad dialect coverage.
- German/French/Italian/English: FLEURS `de_de`, `fr_fr`, `it_it`, `en_us`.
- Arabic: FLEURS `ar_eg`, read Arabic/MSA target. The locale is not evidence of
  Egyptian dialect coverage. Chinese: `cmn_hans_cn`, Mandarin/Simplified script.
  Spanish: `es_419`, Latin America. Portuguese: `pt_br`, Brazilian Portuguese.
  Other varieties/scripts remain unrepresented.
- FLEURS is pinned to `b4a42ed06e12025c42f3b4eff6338ace2fe2447a`, CC BY 4.0,
  three training-split recordings per locale with their published raw human
  reference field. Selection preceded recognition. FLEURS individual speaker
  and session IDs are unavailable in the release metadata; Swiss speaker IDs
  are retained, but sessions are unknown. Published train/dev-test separation
  does not replace complete individual grouping evidence.
- Source audio, original references/TSVs, source/license evidence, hashes and
  preparation provenance remain protected outside the checkout. Mono 16 kHz
  PCM16 benchmark derivatives are separate from untouched originals. Separate
  blind holdout files are retained; no held-out evaluation was performed.

The pilot intentionally uses the compatible legacy corpus/scorer:
`swift-nfc-casefold-alphanumeric-v1` (NFC, POSIX case folding, punctuation to
spaces; CER counts normalized Unicode scalars without spaces). This normalization
can hide orthographic distinctions, including Arabic marks and German letter
forms. It is not the newer strict Arabic policy. **Chinese whitespace WER is
unreported; use CER.** WER may exceed 100% because insertions count as errors.
Swiss written-German scores measure the intended reference rendering, not dialect
spelling or independently established semantic fidelity.

The corpus remains explicitly exploratory/legacy. Native audio/reference
adjudication, critical names/numbers/negation/omissions, adequate speaker/session
grouping, natural long-form speech, adverse conditions, overlap, code-switching
and fresh holdouts remain pending for representative v2 coverage. Public-source
pretraining overlap is possible. No default or bundled model is selected here.

## Lexical quality

Each model cell is **corpus-weighted WER% / CER%** across the same three
utterances. Denominators are normalized reference words/scalars, identical across
models and modes. Full insertion/deletion/substitution counts and per-utterance
macro rates are retained in the JSON report; no cross-language aggregate is used
to hide regressions.

| Language | Reference words / scalars | tiny | base | small | large-v3-turbo | full large-v3 |
| --- | --- | --- | --- | --- | --- | --- |
| Swiss to written German | 34 / 240 | 111.76 / 45.42 | 108.82 / 55.00 | 44.12 / 18.33 | 38.24 / 12.92 | 26.47 / 8.33 |
| German | 81 / 411 | 18.52 / 5.60 | 12.35 / 2.43 | 6.17 / 1.95 | 6.17 / 1.46 | 3.70 / 1.46 |
| French | 99 / 464 | 33.33 / 11.21 | 12.12 / 3.88 | 4.04 / 1.51 | 2.02 / 0.43 | 8.08 / 6.25 |
| Italian | 67 / 326 | 32.84 / 9.82 | 29.85 / 11.35 | 7.46 / 3.07 | 1.49 / 0.31 | 0.00 / 0.00 |
| English | 58 / 261 | 15.52 / 9.58 | 8.62 / 5.36 | 8.62 / 3.83 | 5.17 / 4.98 | 5.17 / 4.98 |
| Arabic | 57 / 279 | 64.91 / 25.45 | 49.12 / 16.85 | 24.56 / 7.17 | 10.53 / 2.87 | 10.53 / 2.87 |
| Mandarin | — / 114 | — / 42.11 | — / 29.82 | — / 7.89 | — / 6.14 | — / 8.77 |
| Spanish | 67 / 301 | 25.37 / 7.64 | 8.96 / 2.33 | 11.94 / 2.66 | 4.48 / 1.66 | 4.48 / 1.33 |
| Portuguese | 100 / 521 | 34.00 / 12.67 | 12.00 / 3.84 | 10.00 / 4.03 | 5.00 / 1.92 | 4.00 / 1.34 |

The larger model does not win every small slice: full large-v3 has higher lexical
error than turbo on these French and Mandarin examples. Swiss errors are
particularly high for tiny/base, and tiny also struggles on the Arabic/Mandarin
slices. These are development observations for selecting a bounded research
hypothesis, not broad model rankings or proof of critical-content correctness.

## Latency and process memory by language/mode

Each wall-time observation is one complete **three-utterance workload**; the
table gives the median and [minimum–maximum] over three workload repeats. Wall
time includes each fresh job's inspection, preparation, loading, recognition,
validation and rendering. RSS gives median and [minimum–maximum] across the nine
completed utterance processes for that model/language/mode, in MiB (2^20 bytes).

| Language | Model | Known wall s | Auto wall s | Known RSS MiB | Auto RSS MiB |
| --- | --- | --- | --- | --- | --- |
| Swiss to written German | tiny | 7.91 [7.50–8.04] | 8.44 [8.17–8.55] | 273.5 [272.3–274.3] | 274.1 [272.9–274.5] |
| Swiss to written German | base | 8.54 [7.89–8.89] | 8.21 [8.11–8.44] | 382.7 [381.3–383.1] | 383.1 [381.2–384.2] |
| Swiss to written German | small | 9.28 [9.23–9.75] | 9.42 [8.64–9.68] | 856.8 [855.5–858.5] | 856.5 [855.5–857.2] |
| Swiss to written German | turbo | 11.42 [11.39–11.65] | 11.91 [11.66–12.75] | 1928.0 [1925.8–1929.3] | 1927.8 [1925.7–1928.8] |
| Swiss to written German | full large-v3 | 15.53 [15.41–15.94] | 16.39 [16.25–17.06] | 4033.6 [4031.0–4034.8] | 4033.8 [4031.4–4035.1] |
| German | tiny | 7.74 [7.57–7.89] | 8.28 [8.18–8.76] | 275.3 [270.0–276.4] | 274.9 [270.9–276.5] |
| German | base | 7.50 [7.42–7.85] | 7.58 [7.25–8.15] | 384.5 [380.5–385.0] | 384.0 [380.1–385.1] |
| German | small | 9.00 [8.76–9.35] | 9.30 [8.74–9.37] | 858.8 [857.3–859.7] | 859.0 [857.9–860.9] |
| German | turbo | 12.15 [12.10–12.42] | 12.32 [11.96–12.42] | 1928.1 [1926.9–1931.9] | 1929.5 [1926.8–1930.3] |
| German | full large-v3 | 16.61 [16.50–16.70] | 17.06 [16.84–17.27] | 4035.3 [4032.3–4035.8] | 4034.4 [4031.7–4035.7] |
| French | tiny | 7.94 [7.86–8.31] | 8.19 [7.82–8.34] | 276.0 [273.8–276.6] | 276.5 [274.8–278.5] |
| French | base | 7.77 [7.75–7.89] | 8.28 [8.18–8.38] | 384.4 [380.0–385.5] | 384.1 [383.4–385.4] |
| French | small | 9.50 [8.85–9.54] | 9.39 [9.25–9.61] | 857.6 [855.4–858.4] | 858.5 [856.8–861.3] |
| French | turbo | 12.23 [11.97–12.77] | 12.68 [11.33–12.98] | 1929.5 [1927.9–1930.7] | 1929.5 [1928.6–1931.0] |
| French | full large-v3 | 17.21 [17.06–17.29] | 17.61 [17.23–17.63] | 4034.8 [4034.1–4036.3] | 4034.2 [4033.1–4039.0] |
| Italian | tiny | 8.11 [7.85–8.12] | 7.44 [6.93–8.23] | 273.7 [269.8–279.0] | 273.2 [268.7–275.5] |
| Italian | base | 8.18 [7.73–8.80] | 7.98 [7.63–8.53] | 383.9 [381.9–384.7] | 383.1 [381.8–386.1] |
| Italian | small | 9.24 [8.92–9.35] | 9.11 [9.04–9.80] | 857.9 [855.8–858.9] | 857.6 [856.0–859.0] |
| Italian | turbo | 12.02 [11.66–12.12] | 12.13 [12.12–12.27] | 1928.3 [1927.0–1930.0] | 1929.7 [1927.5–1930.3] |
| Italian | full large-v3 | 16.21 [15.96–16.51] | 16.80 [16.53–17.44] | 4033.4 [4032.7–4034.5] | 4035.4 [4030.9–4036.0] |
| English | tiny | 7.50 [7.42–7.58] | 8.20 [7.98–8.46] | 273.7 [272.4–276.2] | 273.6 [271.6–274.9] |
| English | base | 7.82 [7.37–8.43] | 7.91 [7.67–8.38] | 382.2 [380.7–383.9] | 382.7 [381.5–384.0] |
| English | small | 9.31 [9.01–9.52] | 9.33 [9.33–9.62] | 857.6 [856.8–858.8] | 856.5 [855.1–856.8] |
| English | turbo | 11.44 [11.22–11.60] | 12.14 [11.67–12.23] | 1928.1 [1926.8–1929.6] | 1928.3 [1927.1–1929.0] |
| English | full large-v3 | 16.04 [15.67–16.19] | 16.26 [16.10–16.88] | 4033.0 [4031.9–4034.7] | 4033.6 [4031.7–4035.6] |
| Arabic | tiny | 8.15 [7.75–8.16] | 8.30 [8.16–8.32] | 275.1 [273.2–276.6] | 275.2 [274.5–276.3] |
| Arabic | base | 9.01 [8.44–9.38] | 8.12 [8.00–9.52] | 383.7 [383.2–385.4] | 384.3 [381.9–386.1] |
| Arabic | small | 9.35 [9.23–9.36] | 9.23 [9.11–9.46] | 857.8 [856.0–859.5] | 858.1 [855.4–860.2] |
| Arabic | turbo | 11.63 [11.51–11.84] | 12.45 [12.27–12.48] | 1928.9 [1928.1–1930.5] | 1928.4 [1926.4–1931.0] |
| Arabic | full large-v3 | 17.10 [16.57–17.71] | 17.88 [17.45–18.05] | 4034.4 [4033.7–4037.0] | 4034.2 [4033.3–4036.0] |
| Mandarin | tiny | 8.35 [8.14–8.99] | 8.38 [7.74–8.58] | 274.0 [273.2–276.1] | 273.9 [272.4–276.5] |
| Mandarin | base | 7.88 [7.77–8.42] | 8.41 [8.17–8.82] | 382.5 [382.2–385.7] | 383.6 [382.2–385.7] |
| Mandarin | small | 9.04 [8.81–9.38] | 8.93 [8.78–9.57] | 857.1 [856.0–858.9] | 856.8 [855.9–858.8] |
| Mandarin | turbo | 11.94 [11.18–12.17] | 12.33 [12.31–12.55] | 1928.7 [1926.5–1930.7] | 1928.6 [1927.4–1930.0] |
| Mandarin | full large-v3 | 16.79 [16.39–16.93] | 17.24 [17.02–18.10] | 4034.5 [4033.0–4038.1] | 4034.9 [4032.5–4037.2] |
| Spanish | tiny | 7.94 [7.88–8.00] | 8.27 [8.06–8.50] | 273.5 [270.6–275.7] | 274.0 [270.7–275.2] |
| Spanish | base | 7.49 [7.36–8.08] | 8.29 [8.27–8.45] | 382.9 [381.3–384.0] | 383.2 [381.3–385.5] |
| Spanish | small | 9.39 [9.23–9.77] | 9.35 [8.61–9.69] | 857.8 [856.1–859.3] | 857.3 [855.4–858.8] |
| Spanish | turbo | 11.43 [11.21–11.72] | 11.89 [11.78–12.23] | 1928.6 [1926.6–1929.8] | 1928.8 [1927.4–1929.3] |
| Spanish | full large-v3 | 16.51 [15.74–16.68] | 17.22 [16.60–17.37] | 4034.0 [4030.6–4036.4] | 4032.7 [4029.9–4036.7] |
| Portuguese | tiny | 8.38 [7.78–8.79] | 7.88 [7.74–8.06] | 275.2 [272.4–276.6] | 275.7 [274.6–278.2] |
| Portuguese | base | 8.43 [8.41–8.70] | 8.70 [8.16–8.75] | 385.5 [382.3–389.3] | 385.5 [383.3–389.1] |
| Portuguese | small | 8.90 [8.83–9.10] | 9.15 [8.38–9.69] | 858.2 [856.5–860.1] | 858.3 [856.7–860.5] |
| Portuguese | turbo | 11.95 [11.44–12.22] | 12.78 [12.35–13.03] | 1930.5 [1927.7–1932.1] | 1929.7 [1926.4–1931.7] |
| Portuguese | full large-v3 | 17.35 [17.24–17.59] | 16.92 [16.73–17.51] | 4036.4 [4031.5–4037.7] | 4035.0 [4033.0–4038.5] |

These are cache-warmed fresh-process measurements, not cold filesystem-cache or
resident-worker measurements. Maximum process RSS is not total concurrent or
unified CPU/GPU allocation. First-result latency, steady decoder throughput,
live delay/backlog and total GPU memory remain unmeasured. Actual audio durations
for workload RTF are recorded per row; all nine language workloads together are
approximately 304.22 seconds of source audio.

For context, the following complete 27-utterance wall times are calculated by
summing the nine language workloads within each repeat, then taking the median
and range. Upstream load observations are kept separate: 81 native invocations
per model/mode, median [minimum–maximum] seconds. An upstream model-load timer
does not measure complete process initialization and is not subtracted from wall
time to invent an inference-only result.

| Model | Known 27-clip wall s | Auto 27-clip wall s | Known upstream load s | Auto upstream load s |
| --- | --- | --- | --- | --- |
| tiny | 71.77 [71.29–72.58] | 73.24 [72.99–73.69] | 0.161 [0.070–0.413] | 0.168 [0.067–0.395] |
| base | 73.21 [72.66–73.36] | 73.86 [72.67–75.80] | 0.192 [0.087–0.418] | 0.192 [0.092–0.394] |
| small | 83.03 [82.34–83.63] | 83.43 [81.47–84.69] | 0.301 [0.198–0.513] | 0.293 [0.187–0.627] |
| turbo | 106.38 [104.95–107.08] | 110.51 [109.53–110.97] | 0.608 [0.490–0.825] | 0.606 [0.494–0.839] |
| full large-v3 | 148.69 [148.20–150.52] | 154.07 [153.19–154.19] | 1.024 [0.896–1.261] | 1.012 [0.888–1.176] |

## Exact artifacts and execution identity

All models are GGML ftype 1 (mixed F16/F32 tensors), from the pinned
`ggerganov/whisper.cpp` artifact snapshot
`5359861c739e955e79d9a303bcbc70fb988958b1`. Model bytes and the actual downloaded
raw `.bin` artifact bytes coincide here; no separate compressed model was tested.
Incremental app-bundle size is unmeasured because no candidate bundle was built.

| Model | Model/download bytes | SHA-256 |
| --- | --- | --- |
| tiny | 77,691,713 | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| base | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| small | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| turbo | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| full large-v3 | 3,095,033,483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

Host: Mac Studio Mac14,14, M2 Ultra, 24 CPU cores (16 performance/8 efficiency),
60 GPU cores, 64 GiB; macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), Swift 6.4
(swiftlang-6.4.0.34.1). Recognition used whisper.cpp 1.9.5, its local Metal path,
two threads, serial utility jobs, no VAD, `-tp 0 -mc 0` and inherited upstream
search/fallback defaults. Known mode passes the base language (`de-CH` → `de`);
automatic mode passes `auto`. The actual native final-job preparation/channel
path was used; this mono pilot does not validate independent multi-channel or
live-replay behavior.

The running app was verified idle, recording was never stopped for measurement,
and the installed app was not replaced. The baseline guard monitored capture,
competing ASR, tests and builds. It did **not** collect complete continuous
CPU/GPU workload telemetry; ordinary desktop/remote-display/OS services remained.
A busy `contactsd` was observed after the baseline and delayed subsequent
candidate work; there is no evidence here that it was active during the baseline.
That limitation precludes treating these timings as isolated laboratory results.

- Unchanged control source: `c214a8ed03f972a5a9cab64105145a67371b97b4`, retained
  on `codex/whisper-quality-untouched-control`.
- Unchanged control CLI SHA-256:
  `9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6`.
- Outer benchmark runner SHA-256:
  `a5a2f1494c7d77cec54a2502bbb898bb7d850df7485be7f2d862ef76b12c1f17`.
- whisper-cli SHA-256:
  `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16`.
- Corpus snapshot SHA-256:
  `c030afc5394a1774d317c70ce9f404145b20cb4700f14d8da271a699673a4ed8`.
- Experiment snapshot SHA-256:
  `e889abc1dc2b69a0e97676c70f1efae963d4f335426f57dc671c75514f1e2212`.
- Completed matrix SHA-256:
  `1723c26eb84dcec0a0c5824a200436043bf20cab4b9593c2dc7dbb85cae07025`.

Exact commands, model-load timer logs, model/binary identities, source hashes,
host/power/toolchain evidence, guard observations and raw canonical job evidence
are retained externally. A supplemental resolved-library inventory (including
libwhisper, GGML Metal/CPU backends and helper libraries) was captured **after**
this run. It is not a claim that every dependency was hash-locked before the
baseline. Candidate runs must bind the fuller dependency inventory before
execution; a changed runtime/dependency requires a matching control rerun.
Source-revision declarations alone do not authenticate an executable; retained
binary hashes/build records provide the concrete identities.

## Evidence, reproduction and validation

Protected evidence root:
`~/Library/Application Support/RecScribe/Benchmarks/Baselines/nine-language-pilot-e1fe4c5d/`.
It contains the immutable `matrix/` snapshots and completed cells, the verified
`report-v1/report.json` and `report.md`, host evidence, guard logs and library
inventories. Original corpus material remains in the external `Corpora/` tree.
The reporter verifies corpus/config snapshot hashes, reads structured metrics
only and does not load raw reference/hypothesis text or rerun recognition.

To reproduce the report into a new protected directory:

```sh
python3 scripts/work-artifacts.py run --label issue-105-pilot-report logs -- \
  python3 scripts/quality/report-pilot.py \
  "$HOME/Library/Application Support/RecScribe/Benchmarks/Baselines/nine-language-pilot-e1fe4c5d/matrix" \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/Baselines/nine-language-pilot-e1fe4c5d/report-NEW"
```

Local validation for the pending PR update: **84 native core tests**, including
mandatory frozen-reference contracts, and **28 offline acquisition/report tests**
passed. Source-boundary and PCM ownership checks passed. Twelve tensor-tooling
tests passed separately under #112; they do not establish model improvement.
Incremental Release app/CLI compilation and the compiled app's source-boundary
check passed; no installed app was replaced.
Full functional app/Thread Sanitizer/Release CI remains required on each updated
PR head and is pending for the new changes. No CI requirement was disabled and
no automatic merge or default promotion is included.

Sources: [Google FLEURS pinned dataset card](https://huggingface.co/datasets/google/fleurs/blob/b4a42ed06e12025c42f3b4eff6338ace2fe2447a/README.md),
[FHNW dataset page](https://www.cs.technik.fhnw.ch/i4ds-datasets), and the
[SwissText 2021 source description](https://ceur-ws.org/Vol-2957/sg_paper1.pdf).
Full regional/reference/scoring gaps remain governed by the
[corpus contract](corpus-contract.md), [experiment contract](experiment-contract.md)
and #103–#105/#112. The next research result must compare an actual AI-authored
weight edit against these controls under a matching, recorded runtime.
