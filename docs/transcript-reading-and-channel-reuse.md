# Transcript reading and exact stereo-window reuse

## Existing transcripts: read-only SwiftUI projection

The Transcript tab defaults to **Reading**, with **All channels** available in the
same shared lightweight navigation style as other tabs. Canonical JSON, raw ASR,
exports, source audio, and existing derived text are never rewritten by this view.
No inference request or network connection is needed to open it.

- Adjacent cross-channel entries with exactly equal start/end times, original
  text, and selected rendered text appear once, labelled with every channel.
- Strongly overlapping entries (at least 80% of the longer interval, against
  every group member) can be grouped as expandable **channel alternatives**.
  They are not assumed to be one speaker or the same utterance. No variant is
  automatically selected as correct; weak overlaps remain separate.
- Same-channel repetitions and non-overlapping repetitions are retained.
  Missing timing/channel metadata disables grouping. Equal normalized text
  never hides differing original ASR.
- Each group retains source IDs, exact millisecond times, channel labels,
  original/derived wording and review reasons in its disclosure. Review status
  remains visible even when the source disclosure is closed.
- All channels restores every individual entry. This is a display preference,
  not a change to AI inputs or canonical exports of an existing job.

Grouping is deliberately conservative and linear over the canonical ordered
segments. It is not general transcript deduplication, speaker diarization, or
automatic correction of recognition errors. Styling and dimensions reuse existing
design tokens; UI rendering is separate from the projection model.

## New local jobs: pipeline 0.2.1

Streaming PCM analysis records exact equality in 30-second windows in
`audio-report.json` and canonical source metadata. It still reads bounded blocks,
including for 8/16/24/32-bit integer PCM, and records the final partial window.
No correlation or text-similarity threshold authorizes dropping a channel.

For non-identical **stereo** sources:

1. Channel 0 is transcribed normally across the full recording.
2. Channel 1 is transcribed only in windows containing different PCM, expanded by
   two seconds of context on each side and merged where overlapping/adjacent.
3. Exact equality proves that the omitted channel-1 inference intervals have
   their audio represented on channel 0. Originals are never downmixed/deleted.
4. Every regional backend response remains unchanged. An explicitly labelled
   output index stores raw/working hashes, source-frame ranges, offsets, actual
   backend commands and durations. Region timestamps are clipped to real working
   audio and offset onto the full timeline; original timing remains in raw ASR.
   Region-derived segments are review-marked for partial/duplicate boundary text.
5. Verification uses the same regions with the selected second engine/model.
   Multipart jobs add session offsets using the existing part orchestration.

Fully identical sources keep the existing one-channel path. Entirely different
sources, unsupported channel counts, or more than eight distinct regions retain
the full-channel path. Coverage is validated before reuse. Window/context/count
policies are centralized in `ChannelPolicy`; no new ASR engine or dependency is
introduced. Live Swift chunk processing already has exact per-chunk equality;
cloud streaming behavior is unchanged by this work.

Working-channel normalization still processes the selected complete channels.
The savings are in redundant **ASR audio**, not a promise to remove all disk I/O
or model-load cost. There is no automatic reprocessing of old jobs. The current
Python pipeline remains the reference backend during the staged Swift migration.

## Verification and limits

A read-only analysis of the user's 643.74-second stereo file found 21 of 22 exact
windows. The new plan requires one 34-second channel-1 region including context,
instead of a second full 643.74-second pass. No real ASR/model call was made for
this measurement, so it does not establish wall-clock speed or recognition quality.
Private audio/text is not included in fixtures or this document.

Synthetic tests cover exact duplicates, changed raw/derived text, nearby/different
timestamps, missing metadata, same-channel repetitions, source preservation,
window coverage, distinct channels, bounded regional copying, cancellation, raw
hashes, verification-model regions, and continuous multipart offsets. Offscreen
SwiftUI snapshots of Reading, expanded alternatives, and All channels were
visually inspected. Tests and artifacts are under ignored `Build/ReadingSnapshots`
and `Build/channel-reading-*.log`.

App 0.2.8 requires pipeline 0.2.1 for new completed-recording jobs, to avoid silently
using an older installed backend. Update through Settings → Transcription →
Set up isolated pipeline runtime when prompted. Existing environments and jobs
are retained. Reading existing transcripts does not require this runtime update.

## Local release verification

- 395 app tests, 31 core tests (including reference schema/export parity), and
  51 Python pipeline tests passed; the final bundled regional-processing source
  matches the tested checkout byte-for-byte.
- Candidate: `Build/ReadingRelease/Products/Release/RecScribe.app`, 0.2.8 (208),
  64-bit arm64, Swift 6 with complete concurrency checking.
- Bundle `com.moreaki.recscribe`, team `CDS4KLP8GT`, Apple Development authority
  Roberto Nibali (6RA9887B6U). Strict/deep code-signature verification passes;
  hardened runtime and the own-app Keychain group remain enabled, with no
  get-task-allow entitlement.
- Executable SHA-256:
  `92589a6262edf20a87b11a49385cf0d986e8db763a2c3b7ef7b394cbf5ce500b`.
- Not Developer ID signed or notarized; the distribution audit correctly rejects
  the development authority. No notarization submission, stapling, distribution
  zip, or public upload was performed. The running app and selected isolated
  environment were not replaced or restarted.
