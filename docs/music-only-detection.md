# Local acoustic evidence for music-only passages

Issue #123 tracks instrumental music producing hallucinated words and spurious
language labels. A transcription model's text or language guess cannot establish
that speech exists. Silence detection and VAD alone cannot establish music-only
audio either, particularly with quiet speech over music.

The first implementation is an offline evaluation API in `RecScribeCore`:
`LocalSoundClassifier.assess(_:check:)`. It uses Apple's built-in
`SoundAnalysis.version1` classifier on one already extracted mono PCM WAV passage.
It does not upload audio, access credentials, download a model, rewrite recognition,
or run in capture callbacks. It is not yet connected to production transcription
or language display. Manual Music only corrections remain available in Studio.

## Evidence and preservation

- Inputs are bounded to 3–120 seconds and 24 MB. Multichannel input is rejected;
  callers must choose a channel instead of silently mixing sources.
- Analysis uses one-second windows with 50% overlap, bounded to 512 observations.
  Read buffers are separate allocations because the analyzer may retain them.
- Reports retain the input SHA-256, classifier version, analysis settings, window
  ranges and required class scores. Input bytes are checked again after analysis.
- Provisional candidate criteria require complete coverage, every window's music
  score at least 0.95, and every monitored voice score at most 0.05. Speech,
  whispering, singing, rap, humming and crowd voices all veto a candidate.
- Missing taxonomy/classes, malformed scores, gaps, short passages and insufficient
  music evidence remain inconclusive. Classifier errors throw; callers must preserve
  recognition. Cancellation/deadline checks run between reads, analysis calls and
  completion waits. Framework calls themselves are synchronous and cannot be
  forcibly interrupted; this API must run off the UI/capture thread.
- Scores are classifier outputs, not calibrated transcription accuracy percentages.
  Neither candidates nor inconclusive evidence establish a language.
- `automaticSuppressionAllowed` is always false, including for candidates. Raw
  transcripts and original audio must remain immutable in future integration.

Apple describes speech, music and singing as potentially co-occurring classes:
[Discover built-in sound classification in SoundAnalysis](https://developer.apple.com/videos/play/wwdc2021/10036/).

## Gate before production suppression

The current benchmark template's music-only entry has no reviewed audio/reference.
Policy tests and a real classifier smoke check on synthetic silence verify failure
handling and plumbing; they do not validate music detection accuracy.

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
