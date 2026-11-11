# Quantized Whisper accuracy campaign status — 10 November 2026

This historical snapshot is retained. See the
[11 November target results](quantized-quality-results-2026-11-11.md) for the
completed Small/Turbo/Large continuation, unchanged prior gaps and final audits.

**Quality preservation for quantized Small, Turbo and full Large-v3 remains
pending.** All six artifacts already pass the 30% same-F16-parent file-size
gate: Q5_1 saves 61.02–61.97%, and Q4_0 saves 70.17–71.27%. Their held-out quality
batches are unstarted. The user gave the concurrent Studio UI work the local
Mac window after competing compilations stopped inference.

The [structured snapshot](quantized-quality-status-2026-11-10.json) records exact
model sizes/hashes, binary/profile/scorer identities, hardware/software, corpus
coverage, freezes, missing measurements and validation provenance. The
[original size evidence](quantization-readiness-2026-11-10.json) retains the
separate size decisions. Model-file savings establish no latency, RAM/GPU,
download/bundle or quality acceptance.

## Actual execution

| Batch | Planned | Completed with review | Failed | Cancelled | Queued/unstarted |
| --- | ---: | ---: | ---: | ---: | ---: |
| Development, all eleven artifacts | 792 | 598 | 0 | 2 | 192 |
| Held-out Tiny/Base references | 576 | 204 | 1 | 1 | 370 |
| Held-out Small F16/Q5/Q4 | 864 | 0 | 0 | 0 | 864 |
| Held-out Turbo F16/Q5/Q4 | 864 | 0 | 0 | 0 | 864 |
| Held-out Large F16/Q5/Q4, known | 432 | 0 | 0 | 0 | 432 |
| Held-out Large F16/Q5/Q4, auto | 432 | 0 | 0 | 0 | 432 |
| Total | 3,960 | 802 | 1 | 3 | 3,154 |

Original F16 development completed 359/360 cells. Its original completeness
requirement is **NOT_MET**, with 194 total development measurements missing.
The [explicit partial-development phase](quantized-quality/heldout-with-development-gaps-2026-11-10.md)
keeps this as missing validation. It advances every pre-fixed artifact regardless
of development direction and cannot authorize product acceptance.

All five held-out batches were jointly sealed at 19:27:41Z, before the first
held-out stage started at 19:27:43Z. Their five hashes still match. Tiny's known
pass completed 143 calls with one unscored Swiss failure; its auto pass completed 61
before a foreign `swift-build` appeared at 19:35:05Z. The guard cancelled and reaped
its owned worker cleanly. The compiler exited before its working directory could
be captured. Another local RecScribe chat was actively building/installing Studio;
the user then chose to finish that UI work first.

Every failed, cancelled and queued row remains unchanged. No inference was
retried, reference corrected or fixture rebaselined. Numerical quality gates
remain unchanged. The 2,592 Small/Turbo/Large calls retain their original
configurations and seals. Resuming
them requires a quiet local window, fresh native idle/live-off admission and the
unchanged guard. The original deadline remains 22:16:29Z (23:16:29 CET); an expired
budget does not silently restart.

## Corpus and scoring

The fresh read-speech corpus has 36 development/144 held-out sources, exactly 4/16
per language. All original audio and reference bytes, prepared mono PCM, timing,
source IDs/licenses and acquisition failures remain protected externally. Prior
source/hash/group exclusions were audited before selection. Published Swiss
speaker IDs are disjoint across splits and from prior known IDs; FLEURS speakers
and all sessions remain unknown. Pretraining overlap is unverified.

Swiss speech targets faithful written Standard German. The held-out metadata
declares AG, SG, ZH, BE, TG, GR, GL, FR and BL; these are publisher declarations,
not independent dialect approval. FLEURS uses de_DE, fr_FR, it_IT, en_US, ar_EG,
cmn_hans_CN, es_419 and pt_BR. Chinese covers published Mandarin/Simplified text;
Arabic audibility and broader regions/scripts remain unreviewed. The JSON
retains actual per-language declarations, group counts and durations.

The [fixed protocol](quantized-quality-protocol-2026-11-10.md) retains the legacy
`swift-nfc-casefold-alphanumeric-v1` scorer, exact matched profile, two threads,
known/auto policies, inherited search/fallback, no additional VAD and one quality
repeat. Paired preservation uses 16/16 sources per language, fixed source-unit
bootstrap seeds/2,000 draws, unchanged macro/per-language margins and a separate
Swiss floor. Chinese uses CER only. Unknown speaker/session dependence limits
these intervals to unadjusted exploratory descriptions. Native/v2 reference,
critical-content, representative-condition and controlled-resource acceptance
remain pending. Current timing/RSS observations are uncontrolled.

YouTube preparation is a separate pending corpus: 17 downloaded originals across
nine planned languages, only eight held-out sources, one uploaded en-US caption
track and zero approved references. Swiss held-out audio and the remaining
reference/coverage work stay open in #122. It supplies no current gold scores.

## Validation and preservation

- All 174 offline tests passed before launch, including explicit NOT_MET
  propagation and joint sealing before any call. All 92 native/frozen tests and
  five staged renderer export hashes passed for the unchanged frozen CLI before
  the later main integration.
- Independent audits verified 234 report cohorts and 1,963 count/rate checks,
  including partial reports. Corrupted-count/bound/identity fixtures were rejected.
- Post-stop SHA checks matched all 568 recorded files: 11 models, 17 native
  product/dependency files and 180 each of original audio, prepared PCM and
  original references. All five held-out seals remain unchanged.
- Historical PR head `0fb4515` passed [full CI 42869732554](https://github.com/moreaki/recscribe/actions/runs/42869732554):
  465 functional/465 TSan tests, each 462 passes/three skips, no failures,
  diagnostics or unexpected restarts. Provider digest and matching-count evidence
  were independently verified. **A new PR head requires fresh full CI**; this
  historical green result does not pass later source or main integration.

Protected evidence is under
`Benchmarks/Research/105/quantized-quality-20261110-v1`, including both stopped
development attempts, the joint held-out seal, partial reference report,
independent audits and preservation receipt. Sources are retained on the frozen
`codex/quantized-quality-frozen-964ca27`, both continuation branches and
`codex/quantized-heldout-frozen-c3cad7e` refs. All earlier research evidence and
the unchanged c214 control remain recoverable. No model/default change,
installed-app replacement or automatic merge occurred in this research work.
