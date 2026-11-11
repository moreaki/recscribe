# Reference review and segment alignment — issue #123

This is an offline, human review workflow for the research fitter introduced in
#134. It does not approve references, run ASR, play audio or test UI. All review
packets and exports contain private lexical text and belong in an explicit
protected directory outside the checkout. Original corpus/reference/job files
remain unchanged. Studio percentages still require separate qualification.

## Prepare one pending packet

Select an existing original corpus case and its matching completed local job.
Choose a scoring policy explicitly; historical benchmark scoring is not silently
upgraded. Run commands through `scripts/work-artifacts.py` for disposable logs:

```sh
python3 scripts/work-artifacts.py run --label accuracy-review scratch -- \
  python3 scripts/quality/reference-review.py prepare \
  --manifest /absolute/protected/corpus.json --case ORIGINAL_CASE_ID \
  --job /absolute/protected/MATCHING_JOB \
  --scoring-policy unicode-nfc-apostrophe-v2 \
  --output /absolute/protected/review/NEW_PENDING_PACKET.json
```

Preparation hashes the actual original audio/reference, canonical transcript,
raw-output index and raw JSON. It selects a single produced primary output through
the raw index's explicit channel/role and checks its original hash. It verifies
the retained decoding profile and binds model/runtime hashes from engine
provenance. The versioned decoding identity additionally includes effective ASR
language, speech/VAD configuration and recorded inference flags, with file/model/
output locations removed. Known-language and automatic runs stay distinct even
when their profile files are identical.

Canonical segment IDs are matched to raw entries by exact channel, original
interval and text. Global segment numbering is not a raw index. Multipart,
region-remapped, ambiguous, overlapping, decoder-padding-adjusted or otherwise
unsupported mappings are blocked, with a reason to retain in the review backlog.
Do not trim times or assign full-entry tokens to changed reference boundaries.

Every approval starts **pending**, with empty evidence and reviewer fields,
regardless of corpus `reviewed` or job `completed_with_review`. The published
reference is preserved as an unapproved proposal; segment references start empty.
Uncovered source intervals become explicit pending gap reviews. No whole-clip WER
is copied onto individual segments. There is no batch approval command.

## Human lexical/alignment review

Use the source file, channel and exact interval listed in `bindings.segments`.
For the independent first transcription pass, avoid reading the ASR hypothesis
or its token probabilities in `bindings`; use a native player or the app's bounded
passage listening yourself. The tool performs no playback. Published references
are proposals to verify against the audio, not already approved text. Freeze the
reference before comparing it with ASR to reduce self-scoring and anchoring.

Edit only `review` in the new sidecar:

1. Confirm the reference language, task and chosen normalization/scoring in
   `scope`. A detected language label is not reference approval. Swiss written
   Standard German and literal dialect transcription remain different tasks.
2. Confirm permission/licence/consent for this use in `permission`; preserve all
   published credits and source cards. A download or caption track is not a grant.
3. In `grouping`, independently establish `recordingID`, `sessionID`, all
   `speakerIDs` and ancestral `sourceIDs`. Include every `requiredSourceIDs`
   value, including an original-audio hash ancestor for normalized/derived clips.
   Add further shared-source/mixture ancestors. Do not invent people or sessions
   from case IDs, and do not equate channels with speakers. Unknown groups stay
   pending and block fitting export.
4. Assign an explicit research `split`: training, calibration or evaluation.
   Keep all source/model/mode/derived views together. Previously consumed holdouts
   can be repurposed for prototype development only; they do not become a fresh
   independent final evaluation panel merely by changing the split field.
5. For each segment write the exact reviewed `referenceText` for its bound original
   interval. Review lexical content and alignment separately. Use `disposition:
   speech`, `non_speech` or `unresolved`. Music/silence requires `non_speech` and
   empty reference text; it is counted as an exclusion, never a 100% speech target.
6. Review every uncovered gap. Verified non-speech gaps keep empty text. Speech in
   a gap is an unresolved missed-speech/recall case; it blocks export rather than
   disappearing from coverage. Empty ASR jobs also require a separate negative/
   missed-speech workflow; this first segment exporter cannot turn them into rows.
7. Each approved `permission`, `grouping`, `scope`, `lexical`, `alignment` or gap
   review record needs `status: approved`, a named `reviewer`, timezone-qualified
   ISO-8601 `reviewedAt` and an `evidence` pointer to actual listening/adjudication
   or rights records. Native-language competence and uncertainty resolution belong
   in those records. These declarations do not cryptographically prove review.

If a boundary is wrong, leave it unresolved. Changing a frozen binding invalidates
the packet; reference text and token evidence need a new explicitly supported
mapping. Do not rewrite original recognition or a published benchmark reference.

## Audit and export

```sh
python3 scripts/quality/reference-review.py audit /absolute/protected/PACKET.json
python3 scripts/quality/reference-review.py export \
  /absolute/protected/TRAIN_PACKET.json /absolute/protected/CAL_PACKET.json \
  /absolute/protected/EVAL_PACKET.json --output /absolute/protected/NEW_EXPORT
```

Audit recomputes bindings from original assets and reports remaining review blocks
and explicit exclusions. Export fails if any selected packet is unresolved. It
also rehashes the actual runtime/model/VAD files before accepting their declared
identities, rejects incompatible scopes, missing group ancestry, duplicate row
identities or cross-partition recording/session/speaker/source/audio/reference
groups. It never randomly assigns a split or fills missing grouping/approval.

The new private export directory retains exact-byte `packet-N.json` snapshots of
approved reviews, `audit.json` (packet hashes, exclusions, counts and limitations)
and, written last, `dataset.json` for `fit-accuracy`.
Reviewed segment reference hashes are new exact UTF-8 hashes; published reference
hashes stay in the packet/receipt. A partially written export is not a success:
the fitter still validates dataset structure and targets. Punctuation-only or
otherwise zero-denominator targets require adjudication and may be rejected by
the versioned Swift scorer even after structural export checks.

Limits: at most 32 packets/2,000 rows per export, 16 MiB JSON files, 120-second
selected sources, 4,096 tokens per hypothesis, 512 MiB original WAV inputs, 4 GiB
per model asset, 16 GiB total verification reads and a 90-second cooperative
deadline. File reads reject FIFOs/nonregular inputs. Writes use exclusive creation
and private file/directory modes; existing output is never replaced. Preparation/
audit hashes no model binary until an approved export is requested. No upload,
credentials, inference, recording, UI automation or model download occurs.

## Data gaps remain visible

The audited recent panel contains 36 development and 144 consumed held-out source
pairs, not 2,794 independent reviewed examples. All original references still need
lexical/boundary adjudication. The audited 144 Large F16 auto jobs have 203 ASR
segments; unknown speakers/sessions, interval gaps and unsupported remappings must
not be filled by guessing. Start with one exact scope, then expand.

The packet workflow does not solve missing natural quiet/whispered speech, music
overlap/vocals, silence/noise, long conversations, language switches or independent
channels. It does not replace a new untouched final panel, cluster-bootstrap
uncertainty or the proposed per-model/language and risk-slice qualification gates.
See [the reference audit](accuracy-reference-audit.md) and #123's work checklist.
Manual UI testing remains with the user.
