# Fresh real-world Whisper confirmation — 11 November 2026

Large-v3 Q4_0 has a 71.27% smaller file than the F16 baseline. Its known-language comparison meets all eight available exploratory language bounds. Automatic mode fails the Swiss CER/WER and Portuguese CER bounds, while Arabic quality and the primary CER/WER macros remain pending. Stock upstream Q5_0 saves 65.07%, but fails the Chinese CER bound in both modes and Swiss CER in automatic mode. Neither artifact is approved as a multilingual default.

All 867 first Whisper calls completed: 3 unscored warmups, 96 development and 768 held-out. These totals cover the prepared subset; required Arabic development and held-out sources remain missing. There were no inference failures, cancellations or retries. This component reports the frozen legacy lexical counts. Native-language human review of the audio, references and critical content remains pending, as do source-use permission and representative regional, script, speaker, channel, language-switch and live-use validation. Models, audio and references remain local, and no product default changed.

## Per-language held-out quality

CER/WER are percentages. Upper deltas are one-sided 95% source-unit bootstrap bounds in percentage points (pp). Bold bounds exceed the frozen +1 pp CER / +2 pp WER language margins. Every available language has 16 paired sources; Arabic has 0/16. Chinese WER is unreported. Exact unrounded counts, bounds and seeds are retained in whisper-counts.json.

### Known language

| Language | Pairs | F16 CER / WER % | Q4 CER / WER % | Q4 upper Δ pp | Q5 CER / WER % | Q5 upper Δ pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss German → written Standard German | 16/16 | 14.9497 / 23.1818 | 14.3300 / 22.2727 | 0.7496 / 2.0000 | 14.4074 / 20.9091 | -0.0745 / -0.4386 |
| German | 16/16 | 6.1202 / 10.7143 | 5.6710 / 10.3896 | 0.0000 / 0.0000 | 5.7271 / 10.0649 | 0.0000 / 0.0000 |
| French | 16/16 | 9.8286 / 14.9644 | 9.8286 / 14.9644 | 0.0000 / 0.0000 | 9.8790 / 15.2019 | 0.1534 / 0.7481 |
| Italian | 16/16 | 20.7400 / 26.0870 | 20.8079 / 26.2681 | 0.1396 / 0.5217 | 20.3327 / 25.9058 | 0.0000 / 0.0000 |
| English | 16/16 | 4.2802 / 7.0588 | 4.2802 / 7.0588 | 0.0000 / 0.0000 | 4.3774 / 7.2941 | 0.2751 / 0.6508 |
| Arabic | 0/16 | — / — | — / — | — / — | — / — | — / — |
| Mandarin / Simplified | 16/16 | 42.2619 / — | 41.2698 / — | 0.2358 / — | 42.2619 / — | **1.4374** / — |
| Spanish | 16/16 | 5.7590 / 9.0211 | 5.7208 / 8.4453 | 0.0000 / 0.0000 | 5.7208 / 8.8292 | 0.0000 / 0.0000 |
| Portuguese | 16/16 | 15.5219 / 25.3676 | 14.7190 / 25.0000 | 0.9554 / 1.7065 | 15.1650 / 25.0000 | 0.9833 / 0.8032 |

### Automatic language

| Language | Pairs | F16 CER / WER % | Q4 CER / WER % | Q4 upper Δ pp | Q5 CER / WER % | Q5 upper Δ pp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swiss German → written Standard German | 16/16 | 14.9497 / 23.1818 | 15.4144 / 25.4545 | **3.1199** / **9.3407** | 15.7242 / 21.8182 | **3.4991** / 1.3889 |
| German | 16/16 | 6.1202 / 10.7143 | 5.6710 / 10.3896 | 0.0000 / 0.0000 | 5.7271 / 10.0649 | 0.0000 / 0.0000 |
| French | 16/16 | 9.8286 / 14.9644 | 9.8286 / 14.9644 | 0.0000 / 0.0000 | 9.8790 / 15.2019 | 0.1524 / 0.7380 |
| Italian | 16/16 | 20.7400 / 26.0870 | 20.8079 / 26.2681 | 0.1397 / 0.5008 | 20.3327 / 25.9058 | 0.0000 / 0.0000 |
| English | 16/16 | 4.2802 / 7.0588 | 4.2802 / 7.0588 | 0.0000 / 0.0000 | 4.3774 / 7.2941 | 0.2679 / 0.6356 |
| Arabic | 0/16 | — / — | — / — | — / — | — / — | — / — |
| Mandarin / Simplified | 16/16 | 42.2619 / — | 41.2698 / — | 0.2358 / — | 42.2619 / — | **1.4572** / — |
| Spanish | 16/16 | 5.7590 / 9.0211 | 5.7208 / 8.4453 | 0.0000 / 0.0000 | 5.7208 / 8.8292 | 0.0000 / 0.0000 |
| Portuguese | 16/16 | 15.5219 / 25.3676 | 14.7190 / 25.0000 | **1.1461** / 1.8657 | 15.1650 / 25.0000 | 0.9174 / 0.7576 |

## Interpretation

The Portuguese Q4 point CER improves by 0.802855 pp in both modes. Its 16 per-source edit-count vectors and transcript hashes are identical across modes, independently verified. The known-language upper bound of 0.955414 pp passes, while the automatic bound of 1.146132 pp misses the 1 pp margin. With identical observations and the same bootstrap formula, that difference comes from the frozen mode-specific resampling seeds. It is not evidence of worse Portuguese transcripts in automatic mode. The original conservative gate remains failed; no seed was changed or rerun to obtain a pass.

For one source labelled Swiss German, the automatic runs recorded the base-language label `de` for F16 and `en` for both quantized artifacts. All three known-language runs recorded `de`. These runtime labels do not establish dialect fidelity, human verification of the spoken language, or the sole cause of the aggregate edit differences. Genuine language switches must remain preserved. Automatic Q4 Swiss WER point delta is +2.272727 pp and its upper bound is +9.340659 pp; the CER upper bound is +3.119869 pp. The Swiss results cover the Bern source slice and written Standard German references. Native-language human review and broader Swiss dialect coverage remain pending.

Q5 Chinese aggregate CER is unchanged (213/504), but per-source edit composition differs. Upper bounds of 1.437372 pp / 1.457195 pp exceed 1 pp. An unchanged aggregate point does not establish a preservation bound.

Primary CER equally weights eight non-Swiss languages, and primary WER excludes Chinese. Required Arabic quality is absent, so all primary macros remain null; the language denominator is not reduced. Swiss German has a separate language bound. All comparisons remain incomplete, with the observed failed bounds retained.

## Model size and provenance

| Artifact | Bytes | Saving vs F16 | SHA-256 |
| --- | ---: | ---: | --- |
| large-v3 | 3095033483 | 0.0000% | 64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2 |
| large-v3-q4_0 | 889340843 | 71.2656% | e002bafb9831c78dcee921e152611fb7e4d9c70d60f9eb46401783d3f861e7c3 |
| large-v3-upstream-q5_0 | 1081140203 | 65.0685% | d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1 |

Q4 is the retained conventional whisper.cpp export of the unchanged F16 parent. Q5_0 is a pinned upstream artifact. Its hosted F16 file matches the baseline used here, but the upstream quantizer, settings and actual parent used to produce Q5_0 are unknown. These savings do not establish an AI weight-space-programming gain or a reduction in parameter count.

## Runtime and evidence limits

The recorded host is Apple M2 Ultra (Mac14,14), 24 CPU cores / 60 GPU cores, 64 GiB, macOS 26.6.2 (25G83). Retained logs confirm Metal with BLAS/CPU support and GPU/flash-attention enabled. Whisper's requested thread count was two; this does not measure every internal BLAS or OpenMP thread. RecScribe's retained Whisper transcriber is source 517d344 / binary b082ca6d…; its coordinator is b6670501…; the original retained control is 9788fa4e…; and whisper.cpp 1.9.5 is binary e23dcdf5…. Known/auto modes, the matched default profile, `-tp 0` / `-mc 0`, inherited fallback and no added VAD or terminology remain frozen.

The original twenty-file Whisper software inventory omitted three dynamically loaded backend modules and libomp. A later bounded static snapshot hashes five library files, including one already covered dependency, and records alias metadata. Pre-execution coverage for the missing dependencies remains NOT_ESTABLISHED for this quality campaign. Post-hoc hashing does not repair the original freeze. Full coverage of actually loaded libraries and system-driver bytes is also unestablished; the OS build is recorded.

All quality-stage wall-time/RSS observations are UNCONTROLLED under the separately frozen 1000% foreign-process CPU policy, nice 10 and recording/capture/build/test/ASR/VM/uncertainty guard. They support no speed, memory, energy or cross-backend acceptance. The original strict resource plan expired unexecuted; a separately frozen first-attempt panel retains the 50% CPU, 3600 s total and 120 s block limits and adds prospective backend locks. Its results remain pending. Qwen accuracy is a separate comparison and is outside this Whisper component.

Scoring remains `swift-nfc-casefold-alphanumeric-v1`. The frozen bootstrap uses 2,000 draws, seed 10410520261110, one-sided 95% nearest-rank bounds and sixteen source units per language. Macro margins are +0.5 pp CER / +1 pp WER; language margins are +1 pp CER / +2 pp WER. Speaker/session dependence and unadjusted multiple comparisons make these exploratory lexical observations. No reference, seed, margin or first outcome was substituted.

## Retained identities

Whisper count source: /Users/moreaki/Library/Application Support/RecScribe/Benchmarks/Research/105/quantized-realworld-confirmation-20261111-v1/analysis/native-count-audit-measured-v1/report.json (SHA-256 b4351f9a3491b599413dc8c3929ee25e84c62b2f80f5fbe19dd876bd729b4b90). Independent interval checks: 60. Exact first matrices/guards, canonical raw transcripts, source intervals/channels, original compressed audio/references, runtime/build receipts, failed preparations and frozen branches remain protected under /Users/moreaki/Library/Application Support/RecScribe/Benchmarks/Research/105/quantized-realworld-confirmation-20261111-v1. This confirmation phase performed no retraining, fine-tuning, distillation, direct AI weight editing, app installation, model publication or automatic merge.

## Draft edit provenance

This review copy derives from `analysis/native-confirmation-report-v1/report-v2.md` in the protected campaign root and the unchanged `whisper-counts.json` copied here. The earlier `report.md` remains in that protected directory. The v2 prose clarifies runtime labels versus human language review and distinguishes the F16 baseline from unverified upstream Q5 parentage. All numeric table cells and metrics are unchanged. All seventeen copied fields in `whisper-counts.json` match the sealed report above, including null macros, gates, counts and resource scopes. The independent metadata facts remain in protected `analysis/native-quality-facts-independent-v1/facts-v2.json` (SHA-256 793a3811b411d02dbbb545207c99dd6aa035336889deba9ef29b34f33deeaec0). No scores were recomputed or references/hypothesis words inspected for this edit. This derived review copy authorizes no model publication, default promotion or merge.
