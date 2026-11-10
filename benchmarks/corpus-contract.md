# Corpus and lexical scoring contract (v2)

This is a preparation contract, not an approved corpus or recognition result.
All 50 template entries are pending. No recordings, references or model weights
are committed with this preparation template. Acquired evaluation material belongs
in a separate protected corpus and needs case-level provenance/review.
The manifest format is additive: schema 1.0 remains readable with its exact legacy
normalization; schema 2.0 requires explicit evidence and reference policies.
Do not use the readiness template to claim complete language or condition coverage.

## Planned coverage and present gaps

Every language needs independent development and held-out speakers, sessions and
source recordings, with short (target 2–30 seconds) and natural long-form (target
5–30 minutes) speech. These ranges are selection targets, not artificial padding.
Each language also needs quiet speech/openings, pauses, realistic noise, accents,
word-boundary cases, names/numbers/negation, overlap and language switches. Shared
noise/music/silence cases supplement these; they do not fill speech coverage.

| Language | Planned task/script | Regional coverage still pending |
| --- | --- | --- |
| Swiss German (`de-CH`) | Primary: faithful written Standard German with reviewed Swiss conventions, Latin; optional separate dialect-spelling task | AG, BE, BS, GR, LU, SG, VS, ZH and further dialects; record the source dialect/variety and assess content fidelity in the intended written output |
| German (`de`) | Transcription, Latin | DE, AT and Swiss Standard German; regional accents |
| French (`fr`) | Transcription, Latin | FR, CH, BE, CA and other varieties |
| Italian (`it`) | Transcription, Latin | IT, CH and regional accents |
| English (`en`) | Transcription, Latin | US, GB and other native/non-native accents |
| Arabic (`ar`) | Initially MSA target, Arabic script | MSA approval and each regional dialect separately; dialects are not covered by MSA |
| Chinese (`zh`) | Initially Mandarin/Simplified target, CER | Mandarin approval, Traditional script, Cantonese and other varieties separately; no script conversion |
| Spanish (`es`) | Transcription, Latin | ES and Latin American varieties separately |
| Portuguese (`pt`) | Transcription, Latin | Brazilian and European Portuguese separately; neither implies the other |

The variety in each approved case records what is actually audible. `planned_variety`
is an optional selection note, never proof of coverage. `und` shared placeholders
have no language evidence and must be replaced with labelled speech or retained as
non-speech. Additional languages use the same fields and scoring policies.

Preparation version `priority-nine-preparation-v2` keeps every earlier case ID
and output task, but prioritizes the four existing `de-CH-rendering-*` short/long,
development/held-out cases. They have `coverage_role: "primary"`; the four
`de-CH-*` dialect-spelling cases have `coverage_role: "optional"`. Other required
language/condition cases are primary. Earlier v2 manifests may omit this additive
planning field. Roles neither approve files nor prove coverage; optional dialect
spelling must not gate acceptance of the primary Swiss written-German task.
Reference conventions/hashes remain null and review remains false in the template.

## Candidate source inventory; case-level approval required

Reviewed source documentation on 2026-11-05. Exact release, attribution, access
terms and speaker/session mapping must be retained with the private selection.
Dataset discovery does not establish that Whisper never saw the material during
pretraining; public benchmark contamination is a limitation. Consented, newly
recorded holdouts are preferable for the final claim.

| Candidate source | Suitable material and terms | Selection limitations / status |
| --- | --- | --- |
| [FHNW Swiss Parliaments Corpus and All Swiss German Dialects Test Set](https://www.cs.technik.fhnw.ch/i4ds-datasets) | Rights-holder page lists MIT for Swiss German parliament speech with Standard German transcripts (versions 1/2) and the dialect test set (version 1, 2021-03-10) | Retain the exact release/archive license and attribution; inspect transcript/audio alignment, original speaker/session grouping and actual dialect representation. Automatically aligned parliament text and possible Standard German speech need inspection under the primary rendering rubric. No candidate source alone proves conversational or fresh held-out coverage |
| [Google FLEURS, pinned dataset card](https://huggingface.co/datasets/google/fleurs/blob/b4a42ed06e12025c42f3b4eff6338ace2fe2447a/README.md) | CC BY 4.0 at the pinned revision; initial configs `ar_eg`, `cmn_hans_cn`, `de_de`, `en_us`, `es_419`, `fr_fr`, `it_it`, `pt_br` cover the other eight language targets | Read-sentence domain, not natural long form. Retain original/raw references, exact release and attribution. Published metadata lacks individual speaker/session IDs; inspect the grouping limits rather than invent IDs. The card states training speakers differ from dev/test, not that arbitrary dev/test samples form speaker-disjoint experiment splits. Missing v2 grouping stays pending; an exploratory pilot cannot claim completed held-out coverage |
| [Multilingual LibriSpeech, official OpenSLR release](https://www.openslr.org/94/) | Read audiobooks in German, French, Italian, English, Spanish and Portuguese; CC BY 4.0, retain attribution | Scripted audiobook domain; native long sessions/speaker IDs must be retained; not proof of conversational or regional coverage. Release and local selection pending |
| [Common Voice dataset catalog](https://commonvoice.mozilla.org/en/datasets) and [contributor terms](https://commonvoice.mozilla.org/en/terms) | Candidate short speech including Arabic and Chinese locale-labelled releases; catalog lists release-specific licenses, commonly CC0 | Pin release and locale, verify its own license and access terms; scripts/dialects and anonymous speaker grouping need review; not a long-form corpus. Pending |
| [SwissDial, ETH source](https://mtc.ethz.ch/publications/open-source/swiss-dial.html) | Swiss German and High German transcripts for eight listed dialects; ETH offers research-community access | Restricted access/use requires obtaining the actual agreement and verifying this project's permitted use; do not assume product/commercial permission. Speaker diversity and spontaneous long-form material limited. Pending |
| [STT4SG-350/SDS-200, rights-holder page](https://swissnlp.org/home/activities/datasets/) | Swiss German speech with Standard German text; research access under META-SHARE ResearchUsageOnly NoRedistribution terms, commercial arrangements separately | Standard German references evaluate rendering, not dialect wording. Signed permission and compatible use pending. Automatically generated dialect transcripts are not human ground truth |
| Explicitly consented local recordings | Nine-language long-form conversations, independent channels, adverse conditions and fresh holdouts | Record participant consent, permitted evaluation scope, anonymous speaker/session/source IDs and reference reviewers. No consented inputs have been approved here |

No listed source fills all gaps. Dataset-level terms and acquisition do not
establish per-case reference quality or representative coverage. Retain acquisition,
rights/provenance, native-language reference review and a frozen private manifest.
Missing material/review remains pending. Do not substitute
synthetic tests, generated transcripts or concatenated unrelated clips for a
natural long-form or human-reference acceptance requirement.

## Manifest evidence and freezing

Paths resolve relative to the manifest or may be absolute. Keep source audio,
original reference files and private manifests outside the checkout and disposable
artifact root, for example under the explicitly protected application-support
Benchmarks directory. Preserve originals and source frame timing. Preparation,
normalization, references and recognizer outputs are separate derived artifacts.

V2 stores language, variety, ISO 15924 script, duration, conditions, source domain,
anonymous speaker IDs, session/source IDs, zero-based source channel or `mix`,
code-switch source-time intervals, output task, split, source URL, license/consent,
reference conventions and human review. Optional `coverage_role` is validated as
`primary` or `optional`; absent roles retain earlier v2 compatibility. Empty/missing
evidence remains pending.
References must match exactly the declared source channel: use channel-specific human
references for independent-channel final jobs, or a separately reviewed interleaved
reference for a derived `mix` preview. Never compare all final channels joined together
to a single-channel reference. V2 eligibility currently marks `mix` unsupported:
the runner has no live replay adapter and does not silently concatenate independent
final channels. Integer channel IDs must exist in the original WAV. Declared duration
must match source frames within the larger of one sample or one millisecond, so
false-speech rates cannot use an arbitrary duration denominator.

Audio `sha256` and `reference_sha256` must match the original file bytes. Existing
mismatches fail even when review has not finished. The validator rejects overlap
between development and held-out speaker IDs, session IDs, source IDs or audio
hashes. Source IDs refer to original recordings, not arbitrary clip IDs; related
clips share one source ID. Do not rename IDs to disguise overlap.

Select and review human conventions before tuning, then freeze both hashes,
`corpus_version`, scoring policy and `frozen: true`. Retain the exact manifest hash
in every run. A legitimate reference correction gets a new corpus version and
review record; rerun both baseline and candidate, never change a reference merely
to improve a candidate score. Keep held-out references inaccessible during tuning.

For Swiss German speech, the primary task is `standard_rendering`: faithful
written Standard German using reviewed Swiss conventions. It is scored directly
against the reviewed written-German reference; no automatic LLM cleanup or
translation stage is required by this output contract. Preserve the source
meaning, names, numbers and negation. Optional `dialect_transcription` measures
audible dialect wording under an agreed spelling convention in separate cases
and scores. Other translation tasks also remain separate. Raw Whisper `de` is
only a base-language argument, not evidence of dialect identification or content
accuracy. The scorer does not choose whichever alternate spelling makes a candidate win.
If multiple spellings are acceptable, preserve the reviewed variant list privately
and report human adjudication independently from exact-reference lexical scores.

## Versioned scoring

| Policy | Exact normalization and limitations |
| --- | --- |
| `swift-nfc-casefold-alphanumeric-v1` | Unchanged legacy policy: NFC, Foundation POSIX case folding, retain alphanumeric/underscore, punctuation to spaces, collapse whitespace. WER uses whitespace; CER omits spaces and counts Unicode scalars |
| `unicode-nfc-apostrophe-v2` | NFC and same case folding; preserve letters/numbers/combining marks/underscore; retain internal letter-to-letter apostrophes, mapping curly apostrophe to ASCII; other punctuation becomes spaces. Whitespace WER and scalar CER |
| `unicode-nfc-cer-v2` | Same Unicode normalization; CER is primary; WER, word counts and word false-speech metrics are null. No Chinese word segmentation, script conversion or claimed word accuracy |
| `arabic-nfc-strict-v2` | Unicode v2 with Arabic vocalization and orthography retained; no alif/hamza/ya/ta marbuta/tatweel conflation. Report strict CER/WER first |
| `arabic-nfc-no-diacritics-v2` | Secondary explicit sensitivity analysis only: also remove combining marks in U+064B–U+065F, U+0670, U+06D6–U+06ED. This can hide vocalization/recitation errors; it must not replace strict scoring |

V2 ignores only listed Unicode display-direction controls. Digits are not rewritten,
accents are not stripped, numbers are not verbalized and simplified/traditional
Chinese are not collapsed. POSIX case folding can conflate letter forms such as
German sharp s; all normalization can hide distinctions. Compare only identical
versions, retain original text and report critical-content review separately.
No external segmenter is used. Any future Chinese word segmentation requires a
new pinned implementation/version and rescoring both arms.

Measured scoring is cancellable between alignment rows and rejects more than 1 MiB
per text or 100 million total word/character alignment cells. Oversize evidence
is retained with scoring pending/failure; it is never reported as zero error.
This is a documented limitation for long-form lexical scoring and must appear in
coverage reports. Do not truncate text silently to obtain a score.

Levenshtein alignment reports insertions, deletions, substitutions and total errors
with reference denominators, using deterministic ties (substitution, deletion,
insertion). Empty references have null WER/CER; false-speech words (where meaningful)
and characters are explicit. Per-minute false-speech rates require actual positive
audio duration. Rates can exceed one. Reference-only punctuation is empty after
normalization and must still receive human review.

Aggregate separately by language, output task, scoring policy, experiment
configuration and acoustic condition. Macro rates average scored case rates;
corpus-weighted rates divide summed errors by summed reference units. Show sample
counts and denominators; never treat pending, failed or canceled rows as zero error.
Tiny slices remain exploratory; confidence intervals and critical-content labels
are unmeasured until sufficient reviewed data exists. No lexical score implies
semantic, speaker, timestamp, language-ID or dialect-ID accuracy.

The same frozen corpus/reference/scoring versions support untouched models,
runtime controls and AI-directed model edits under #112. Keep candidate
development evidence separate from held-out references/outcomes. Runtime, model
and compression effects need isolated paired comparisons under #105; corpus
preparation itself is not a model improvement. Repeated fresh processes do not
establish cold filesystem caches, and read-speech subsets do not establish
long-form or adverse-condition acceptance.

## Human review rubric

For each paired transcript, native-language reviewers record the source-time span,
reference, raw hypothesis, severity and adjudication for names, quantities/units,
negation, omitted meaning, invented speech, repetition, code-switch content and
source-content preservation in the intended written output. For primary Swiss
cases, acceptable Standard German rendering is reviewed against the dialect
audio; dialect spelling is not required. Review optional dialect-spelling fidelity
only in its declared task. Record `correct`, `incorrect`, `uncertain` or `not reviewed`
for each applicable item; uncertainty is not a pass. Critical errors that reverse
meaning remain visible even if normalization or average WER improves. Review
independent channels and overlapping speech against their own source evidence;
a mixed live preview does not establish speaker attribution. Define budgets from
development baselines before freezing settings; review each language/model and
condition on held-out data before any default promotion.
