# Local acoustic evidence for music-only passages

Issue #123 tracks instrumental music producing hallucinated words and spurious
language labels. A transcription model's text or language guess cannot establish
that speech exists. Silence detection and VAD alone cannot establish music-only
audio either, particularly with quiet speech over music.

The first implementation is an offline evaluation API in `RecScribeCore`:
`LocalSoundClassifier.assess(_:check:)`. It uses Apple's built-in
`SoundAnalysis.version1` classifier on one already extracted mono PCM WAV passage.
It does not upload audio, access credentials, download a model, rewrite recognition,
or run in capture callbacks. Studio's Analyze sound locally action now uses it for
one selected source/channel. It is not an automatic ASR suppression gate.

## Evidence and preservation

- Inputs are bounded to 3–120 seconds and 24 MB. Multichannel input is rejected;
  callers must choose a channel instead of silently mixing sources.
- Analysis uses three-second windows with a one-second hop, bounded to 512 observations.
  Read buffers are separate allocations because the analyzer may retain them.
  An unfinished tail is analyzed in a separate final three-second window taken
  entirely from the passage. No silence padding or neighbouring audio is added.
- Reports retain the input SHA-256, classifier version, analysis settings, window
  ranges and required class scores. Input bytes are checked again after analysis.
- Provisional candidate criteria require complete coverage, every window's music
  score at least 0.85, and every monitored voice score at most 0.05. Speech,
  whispering, singing, rap, humming and crowd voices all veto a candidate.
- Missing taxonomy/classes, malformed scores, gaps, short passages and insufficient
  music evidence remain inconclusive. Classifier errors throw; callers must preserve
  recognition. Cancellation/deadline checks run between reads, analysis calls and
  completion waits. Framework calls themselves are synchronous and cannot be
  forcibly interrupted; this API must run off the UI/capture thread.
- Scores are classifier outputs, not calibrated transcription accuracy percentages.
  Neither candidates nor inconclusive evidence establish a language.
- A strong music result additionally requires complete one-second voice windows
  with 50% overlap. Every monitored voice class must remain <=0.05 in every such
  window. Their music scores are not used to establish music; this pass checks for
  short speech that a longer window could dilute. Missing/invalid/unfinished voice
  evidence keeps recognition and cannot offer music-only confirmation.
- The original, one-second voice and optional eight-second context passes share
  one 512-observation budget and one cooperative deadline. Final windows stay
  entirely inside the selected passage; input bytes and channel bounds are unchanged.
- `automaticSuppressionAllowed` is always false, including for candidates. Raw
  transcripts and original audio must remain immutable in future integration.

### Longer context and the violin fixture

An inconclusive, voice-free passage of at least eight seconds can receive an
additional eight-second analysis with one-second hops. This is attempted only
when every short window has music score at least 0.65. Both passes retain all
33 voice vetoes at 0.05, valid scores, full coverage and a shared 512-observation
budget. The existing 30-second cooperative deadline covers both passes. A final
eight-second window completes fractional tails using only passage frames.

When every context window has music score at least 0.80, the result is
`musicNeedsListeningReview`: possible music with quiet speech unresolved. It is
never an instrumental music-only candidate. This distinction is necessary because
the reviewed violin and quiet speech-over-violin mixtures have overlapping scores.
The existing 0.85 short-window music-only candidate rule remains unchanged.

Reports retain both sets of windows and the attempted context settings/thresholds.
Old reports without optional context fields remain readable. Missing, malformed,
unfinished or gapped context stays inconclusive; context voice evidence keeps words.
Studio explains the uncertainty and keeps recognition. The existing manual Music
only action remains available after listening; the uncertain hint cannot invoke
Confirm music only or create a correction by itself. This is not an accuracy %.

Reports retain optional `voiceGuardWindows`, completion, window duration and overlap.
Legacy reports remain readable, but an old candidate without completed voice evidence
cannot offer music-only confirmation. Previously user-confirmed corrections are not
rewritten or revoked. The nine short speech-source mixture fixtures are derived,
unadjudicated development checks, not new listening approval or proof of whisper
accuracy. Their #130 baseline already retained all cases; no accuracy gain is claimed.

Confirmation eligibility re-evaluates retained scores, ranges and current policy;
the stored `instrumentalMusicCandidate` status alone cannot authorize a correction.
Primary and optional context completion are recorded explicitly. Missing completion,
voice in any retained pass, missing classes, weak music, gaps, invalid timing or an
exceeded observation budget deny confirmation even if decoded status says candidate.
Older reports lacking these completion fields remain readable but cannot be newly
confirmed. This does not rewrite earlier user-confirmed music-only annotations.
The recheck is local, bounded by the existing observation limit, and runs no model,
audio extraction, network request or file write. It strengthens evidence consistency;
it does not establish a new measured detection-accuracy result.

## Studio confirmation and restoration

Analyze sound locally prepares exactly the selected channel/time range with the
same bounded, source-validated extractor as selected-segment cloud recognition.
It makes no cloud request and reads no credentials. Work is off the main actor;
one analysis per workspace is allowed. Capture/audio tests, processing, deletion,
leaving Studio and switching jobs cancel/revoke results. Late work and newer text
edits cannot replace a current correction.

A candidate is shown for listening review. Confirm music only separately writes a
reversible music-only correction with local evidence provenance. Inconclusive or
voice-bearing results keep recognition and offer no automatic replacement. The
existing manual Music only action remains available for classifier misses.

Confirmed music-only passages show `[Music only]` in Studio and copied/shared
transcript text. Original words are collapsed under Original recognition. When
all passages are marked music-only, current language display says no spoken
language. For mixed documents, recording-wide engine guesses cannot be attributed
to the remaining speech, so they are displayed as unverified instead of presenting
possibly music-derived language labels as current facts. Original model estimates
remain available in Details. Remove correction restores the original presentation.
Summaries retain their existing correction warning; original job exports remain
unchanged. Review metadata v4 retains acoustic references and reads v1/v2/v3 records.

Full local acoustic reports, hashes and analysis settings are retained under
Application Support/RecScribe/AcousticReview. Temporary mono passage copies are
removed on success, errors and cancellation. Reports contain no audio upload.

Inspect a prepared mono passage offline with:

```sh
core/.build/debug/recscribe-text inspect-sound passage.wav
```

The JSON report is printed to stdout. The command rejects processing/credential
options and cancellation propagates to the analysis worker.

Apple describes speech, music and singing as potentially co-occurring classes:
[Discover built-in sound classification in SoundAnalysis](https://developer.apple.com/videos/play/wwdc2021/10036/).

## Gate before production suppression

The broad benchmark template's music-only entry remains unfilled. A separate small
set now includes four user-listening-approved fixtures plus clearly labelled speech
and synthetic mixture challenges. See the hashes, licenses and review statuses in
`core/Tests/RecScribeCoreTests/Fixtures/Acoustic/manifest.json` and the results in
`benchmarks/music-only-studio-2026-11-10.md`. These are development data, not an
independent held-out corpus or proof that quiet speech is always preserved.

Before enabling suppression or replacing an inferred language with “No speech”:

1. Add licensed, hashed, reviewed development and held-out recordings covering
   instrumental music, silence, noise, vocals/rap/humming, multilingual speech,
   quiet/whispered speech over music, stereo disagreements and passage boundaries.
2. Annotate true speech/non-speech intervals and channels independently of Whisper.
   Keep the frozen transcription references unchanged.
3. Evaluate candidate precision, speech falsely suppressed and coverage by condition;
   retain per-window evidence. Tune thresholds only on development data. Require
   explicit review of any speech-bearing passage classified as music-only.
4. Integrate as a separate reversible acoustic annotation with original recognition
   retained, no inferred spoken-language label for validated non-speech passages,
   and an inconclusive fallback that keeps recognition. Validate imported and live
   transcription paths, cancellation, channel/time bounds and persistence.
5. Run full functional/TSan CI and review the actual Studio behavior before release.
