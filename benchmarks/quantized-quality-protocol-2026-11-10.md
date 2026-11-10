# Fresh quantized-model accuracy protocol — 10 November 2026

Compare the six fixed ordinary Small, large-v3-turbo and full large-v3 Q5_1/Q4_0
artifacts with their exact original F16 parents. Retain multilingual Tiny and
Base F16 as reference arms. All eleven identities and the matched baseline
decoding profile are already fixed by the quantization/compatibility evidence;
no new weight edits, recipe search or tuning is permitted. Every fixed artifact
advances regardless of development direction. Model-file admission remains at
least 30% fewer bytes than the same F16 parent.

The YouTube corpus has development audio in all nine languages, but lacks a
Swiss held-out source and approved references. Its raw caption review remains
separate. To obtain paired lexical evidence now, acquire a separate fresh public
read-speech slice using exact published human references. This is **exploratory
legacy-v1 evidence, not reviewed-v2 or representative product acceptance**.

## Prospective source selection

Use the existing pinned Google FLEURS release for German, French, Italian,
English, Arabic, Chinese, Spanish and Portuguese, and the pinned FHNW Swiss
dialect release with written Standard German references. Preserve original
audio/reference bytes, source intervals, licenses, release metadata and hashes.
Do not display held-out reference text or outcomes before freezing.

Select four development and sixteen held-out sources per language: 36/144,
180 sources total. Select the first eligible archive members with the existing
source/hash/group exclusions and mono-header policy. A union of 433 prior
manifest snapshots excludes 1,327 distinct case records, 1,232 source IDs,
original/prepared audio and reference hashes, and 94 known speakers. Unknown
speaker/session identities remain unknown; separate source names do not prove
speaker independence or pretraining exclusion.

Freeze acquisition caps before downloading: 128 MiB per archive prefix,
2 GiB aggregate network, 512 MiB retained output and 1,800 seconds. These
explicit initial caps accommodate the accumulated prior-source exclusions;
defaults remain 32 MiB/256 MiB. No failed run may grow its prefix/budget, reduce
its requested counts or overwrite partial evidence. A genuinely incomplete
acquisition remains pending. Any separately planned completion must preserve
that failure and declare its own provenance and bounds before acquisition.

FLEURS locales are de_DE, fr_FR, it_IT, en_US, ar_EG, cmn_hans_CN, es_419 and
pt_BR. These tags do not establish audible dialects. Chinese covers published
Mandarin/Simplified text, not Traditional/Cantonese; Arabic read speech does not
establish dialect coverage; Brazilian Portuguese and Latin American Spanish do
not cover all regions. Swiss canton/speaker declarations are retained, with
written Standard German as the primary task. All source/reference critical
content and native review remain pending.

## Execution and frozen decision rules

Run the existing native matrix with the complete staged CLI, the exact matched
`-tp 0 -mc 0` profile, inherited search/fallback, no added VAD, known/automatic
modes, two threads and one quality repeat. This requests 792 development and
3,168 held-out calls (3,960 total), with 432/1,728 direct parent comparisons.
Tiny/Base remain separate reference models. Repeated quality inference is not
used to repair a failed first result or enlarge the independent sample.

Retain development baselines before sealing the final held-out corpus/config,
profiles, source/model/binary hashes and budgets. Budget values below are
prospective and cannot be relaxed in response to development failures. A legacy
`frozen: true` is a hash/chronology lock, never human review. Preserve the
unmodified acquisition manifests alongside the separately frozen copies.

Evaluate each quantized candidate against its own F16 parent, independently in
known and auto modes. The primary optimization macro uses the eight non-Swiss
languages equally. Swiss remains a separate non-regression floor; nine-language
descriptive summaries are also reported. Chinese uses CER, never whitespace WER.

- Primary macro corpus-weighted-per-language CER increase: at most **0.5
  percentage points**; WER across the seven meaningful non-Swiss languages:
  at most **1 percentage point**.
- Each language, including Swiss: at most **1 percentage point CER** and
  **2 percentage points meaningful WER** increase.
- Report point deltas and one-sided 95% source-unit bootstrap upper bounds,
  2,000 draws with a fixed recorded seed. A numerical non-inferiority pass needs
  the upper bound within its margin. These are descriptive, unadjusted exploratory
  intervals: unknown speaker/session dependence prevents population-level
  equivalence claims. No tuning or seed search.
- Missing/failed/cancelled first-repeat evidence remains missing. A cohort with
  fewer than all sixteen planned paired held-out sources has **pending**
  acceptance; do not compute a complete-cohort macro or replace it with a later
  success. Report actual counts and all insertion/deletion/substitution totals.
- Native critical-content/reference review, representative natural conditions,
  independent groups and controlled resource evidence remain separate required
  adoption gates. Even a numerical lexical pass cannot promote an artifact.

Use the unchanged scorer `swift-nfc-casefold-alphanumeric-v1`, explicitly
retaining its punctuation/combining-mark limitations. Do not silently upgrade
these unreviewed references to v2 or choose normalization to favor a candidate.
Report actual count-based CER and meaningful WER, uncertainty, failures and
denominators. No lexical score establishes semantic, timing, dialect or switch
accuracy. Swiss does not require dialect spelling or an LLM cleanup stage.

Quality-only runs may use the prospectively declared 1000% foreign-process
guard, nice 10 and serial model work while retaining capture/uncertainty,
competing test/build/ASR/VM cancellation and bounded deadlines. All resulting
timings/RSS are **UNCONTROLLED / NOT EVALUATED** for resource acceptance.
The separate controlled three-repeat timing panel retains its 50% policy.
Obtain fresh native idle/live-off admission only when all inputs/plans are ready.

Keep all old frozen branches, models, corpora, references, raw transcripts,
timing/provenance and failed attempts intact. No automatic merge, model/default
promotion, retraining or reference rebaseline.
