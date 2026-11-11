# Accuracy reference reuse audit — issue #123

Read-only audit on 11 November 2026. Counts below come from retained manifests,
matrix JSON and the completed campaign's published count-only report. This audit
ran no recognition, listening, UI tests, acquisition or reference correction, and
did not rewrite protected evidence. It does not independently reapprove licences,
recheck every audio hash or establish speaker independence.

## What can be reused

| Evidence | Distinct original source/reference pairs | Existing recognition evidence | Calibration role now |
| --- | ---: | --- | --- |
| First public pilot | 27 development + 27 original held-out; 3 per language/split | Published baseline: 810 completed calls = 27 development sources × 5 F16 models × 2 language modes × 3 repeats | Prototype feature/target extraction and regression coverage; not independent reviewed calibration |
| Round 2 public slice | 72 development + 72 held-out; 8 per language/split | Historical model-edit research evidence; audit the selected matrix before importing particular outputs | Consumed development material only |
| Round 3 public slice | 72 development + 144 held-out; 8/16 per language | Historical research outputs | Consumed development material only |
| Final Round 4 public assembly | 72 development + 144 held-out; 8/16 per language | Historical research outputs; includes a separately preserved Italian completion | Consumed development material only; do not double-count assembly/components |
| Final Round 5 public assembly | 72 development + 144 held-out; 8/16 per language | Historical research outputs; includes a separately preserved Swiss completion | Consumed development material only; do not double-count assembly/components |
| Fresh quantized campaign | 36 development + 144 held-out; 4/16 per language | 598 successful development calls, two cancellations, 192 unstarted; 2,794 successful held-out calls, one failure, three cancellations and 370 unstarted | Richest reusable raw feature/prototype-target evidence; holdout is now consumed, not a fresh accuracy-estimator test set |
| Acoustic music/voice fixtures | 26 clips: 5 original-source excerpts plus 21 derived mixtures | SoundAnalysis reports and preservation tests; 4 listening-approved **class labels** | Music/speech abstention/regression challenges, not passage lexical-accuracy gold |
| Separate YouTube preparation | 17 original downloads: 9 development / 8 held-out, across 9 planned languages | 1 uploaded en-US caption track; 0 approved references | Acquisition/review backlog; no gold accuracy targets yet |

The five older public families listed above contain 846 distinct source IDs and
846 distinct original-audio hashes across those selected manifests, with no ID
duplicates in that inventory. This is not a count of independent speakers or
sessions, nor a claim that every selected historical source has complete ASR.
The new 144-source quantized holdout has no source-ID overlap with those 846.
Other historical snapshots/components must not be added as new samples.

The fresh campaign's development data are 409.4434375 seconds and its held-out
data 1,765.533875 seconds. All 180 original pairs are marked `reviewed: false`.
All 144 held-out entries declare only `read_speech` and `short_utterance`; all
sessions are unknown. There are no independently listening-approved v2 references
in these audited public families. `completed_with_review` is the job status and
does **not** mean a human approved the reference or recognition.

The 2,794 held-out successes comprise 2,590 target-model calls plus 204 Tiny/Base
reference calls on the same 144 sources. The target-model counts are:

| Family | Actual retained successes | Important missing data |
| --- | ---: | --- |
| Small F16/Q4_0/Q5_1, known + auto | 862 / 864 | Two cancelled F16 calls; preserve them, do not silently retry/replace |
| Turbo F16/Q4_0/Q5_1, known + auto | 864 / 864 | None in this held-out batch |
| Full Large F16/Q4_0/Q5_1, known + auto | 864 / 864 | None in this held-out batch |
| Tiny/Base F16, known + auto | 204 / 576 | One failure, one cancellation, 370 unstarted |

Model variants, language modes and repeats supply additional predictions, not
additional independent source/reference pairs. Never randomly split these rows
between fitting, calibration and evaluation.

## Reference and feature compatibility

- FLEURS uses the pinned release `b4a42ed06e12025c42f3b4eff6338ace2fe2447a`;
  retained manifests declare CC BY 4.0 with Google attribution. The fresh holdout
  contains 128 FLEURS pairs, 16 each in de/fr/it/en/ar/zh/es/pt, and 16 Swiss
  FHNW pairs whose retained licence declaration is MIT. Preserve source cards,
  release records, attribution and original/reference hashes; this is reuse of
  already retained local evidence, not a new redistribution grant.
- FLEURS targets are the published `raw_transcription` field, unadjudicated.
  Individual FLEURS speaker IDs are unknown. Known Swiss client IDs were excluded
  across earlier data/new splits, but are not independently verified real-person
  identities. All sessions remain unknown. No source-ID/hash exclusion can prove
  absence of hidden speaker, session, textual or model-pretraining overlap.
- Swiss is `standard_rendering`: spoken Swiss German rendered in written Standard
  German. It requires its own task/model scope and review, not a claim about exact
  dialect spelling. Locale labels do not establish spoken dialects. Mandarin is
  Simplified-script reference material; the existing pipeline reports CER rather
  than whitespace WER. Arabic read speech does not establish regional/dialect
  coverage; Spanish is Latin American and Portuguese Brazilian in this panel.
- Actual old and fresh campaign scoring is the versioned legacy
  `swift-nfc-casefold-alphanumeric-v1` path. Some historical manifest entries also
  carry newer per-case policy declarations; use the executed scoring provenance,
  not that field alone. To train a stricter word/character estimator, create a new
  versioned sidecar target export using preserved references/hypotheses. Never
  change a frozen transcript, reference or historical benchmark score to do so.
- Published references cover whole original utterances, not independently timed
  ASR segments. A direct audit of full Large F16 automatic mode found 144 complete
  raw jobs yielding **203 canonical segments**: 101 jobs with one raw segment,
  31 with two, 9 with three, 2 with four and 1 with five. Whole-utterance WER cannot
  be copied onto each of these 203 segments. Use a whole-clip research unit first,
  or obtain independently reviewed boundaries/reference text for segment targets.
- Those 144 raw jobs all retain token arrays with numeric `id` and `p`, plus token
  offsets/timestamps and `t_dtw`. They retain runtime/model/parameter metadata.
  All 203 canonical segment confidence fields are null; no raw segment in this
  audited arm supplies `no_speech_prob`. Extract from immutable raw JSON, not null
  canonical confidence. Exclude control/language/timestamp tokens under a
  model/tokenizer-bound rule; token probabilities alone are not word accuracy.
- The actual campaign records model SHA, quantization/precision, native binary,
  decoding profile, language mode/effective argument, source channel, prepared
  source/reference SHA and scoring version. Bind these identities to every
  imported example and fitted artifact. Quantized variants and known/auto modes
  are separate supported scopes unless cross-scope validity is demonstrated.
  Runtime timing/RSS were labelled uncontrolled and are not accuracy labels.
- Acoustic fixtures' 4 approved labels are piano, violin, English speech and the
  -18 dB piano/speech mix. They approve class presence, not word-by-word references.
  Excerpts, mixtures and quiet/short challenges share their underlying sources;
  the 26 clips are not 26 independent recordings. Cropped/mixed excerpts need new
  lexical/boundary review before a published full-source reference can label them.
- YouTube downloads and a VTT track are not reference approval or blanket rights
  to training/redistribution. Check access/licence basis and native review under
  #122; machine/translated captions and ASR output cannot become self-scoring gold.

## Split and collection recommendation

1. Freeze an explicit **research-only development** inventory of reusable legacy
   audio/reference/raw-ASR identities. Retain original manifests and missing-cell
   status. Derive separate labels/features with hashes; no inference rerun is
   needed to establish basic extraction/fitting contracts.
2. Group every view by original recording/source work, speaker/session when known,
   and all derived clips/mixtures. Group matching reference text as another leakage
   check across public read-speech datasets. Treat unknown speaker/session grouping
   as a limitation, not as one new independent speaker per source. The old and
   newly consumed model-selection holdouts may be explicitly repurposed for
   prototype development, but cannot remain the estimator's untouched final test.
3. Select one initial task/model/language/decoding scope. After native review, fit
   on a declared development partition and calibrate on a disjoint reviewed
   partition. Do not infer confidence for an unsupported language/model/mode from
   a pooled nine-language average. Shared source references across model arms are
   reusable, but all predictions for a source must remain in the same partition.
4. Collect a **new, untouched final evaluation panel** with known recording,
   speaker/session/source-work IDs, exact channel and start/end boundaries,
   independently listening-reviewed reference text and adjudication attribution.
   Keep train/calibration/test disjoint at these levels before looking at outcomes.
   Review names, numbers, negation, omissions and alternative valid renderings.
5. Missing risk slices in the fresh 144-source holdout are independently reviewed
   natural quiet/whispered speech, speech over music, singing/rap/humming, silence
   and noise, adverse/multisource audio, long conversations, language switches and
   independent channels. Existing synthetic challenges only test regression
   behavior. Include both correctly recognized and substantially wrong examples
   across feature-score ranges so calibration can measure confident errors.
6. The proposal's initial display gate is at least 100 independent held-out
   recordings and 500 scored speech segments **per displayed model/language
   family**, not 100 repeated model calls. Current 16 held-out clips per language
   (all unreviewed/consumed) do not meet it. Separately held calibration data,
   enough independent clusters per reported interval, supported risk-slice error
   bounds and model/runtime-matched features also remain missing. These are
   proposed product gates, not attained evidence or a statistical-power guarantee.
7. Until the data, fitted artifact and final evaluation qualify, keep production
   display unavailable. Prototype fits must carry research-only status and cannot
   make a calibrated UI percentage appear. Manual UI testing belongs to the user.

## Evidence locations

Protected root `B = ~/Library/Application Support/RecScribe/Benchmarks/`:

- Pilot: `B/Corpora/public-pilot-20261105-v1/development.with-swiss.exploratory.legacy.json`
  and `held_out/manifest.exploratory.legacy.json`; actual baseline matrix/report:
  `B/Baselines/nine-language-pilot-e1fe4c5d/{matrix,report-v1}`.
- Prior sources: `B/Corpora/round2-corpus-20261106-v1`,
  `round3-corpus-20261106-v1`, `round4-corpus-final-20261107-v1` and
  `round5-corpus-final-20261109-v1`, each development/held_out exploratory manifest.
- Fresh quantized root `Q = B/Research/105/quantized-quality-20261110-v1/`.
  Final development corpus: `Q/runs-v1/dev-references/corpus.original.json`.
  Complete 144-source corpus: `Q/runs-checkpoint-v2/held-large-auto/corpus.original.json`.
  The intermediate `Q/corpus-v1` contains only 32/128 FLEURS development/held-out
  rows; use the final assembled 36/144 corpus including Swiss completion.
- Final target matrices: `Q/runs-checkpoint-v2/{held-small,held-turbo,held-large-known,held-large-auto}/matrix.json`.
  Per-cell `*/asr-channel-0.json`, canonical `transcript.json` and `results.json`
  retain raw token/provenance and scoring evidence. Do not commit these texts.
- Count-only final publication:
  `/Users/moreaki/.codex/worktrees/whisper-research-sync/recscribe/benchmarks/quantized-quality-results-2026-11-11.{md,json}`;
  frozen protocol: adjacent `quantized-quality-protocol-2026-11-10.md`;
  executed preservation/publication receipt: `Q/public-results-final-v2.receipt.json`.
- Acoustic source/review manifests:
  `core/Tests/RecScribeCoreTests/Fixtures/Acoustic/{manifest.json,ViolinChallenges/manifest.json,ShortSpeechChallenges/manifest.json}`;
  protected originals under `B/Corpora/music-studio-v1/`.
- YouTube backlog/count provenance: adjacent benchmark worktree
  `benchmarks/quantized-quality-status-2026-11-10.md` and
  `benchmarks/quantized-evaluation.md`; protected acquisition area:
  `B/Research/105/quantized-small-turbo-20261110-v1/`.
