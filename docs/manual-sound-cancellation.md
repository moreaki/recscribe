# Manual sound-analysis cancellation — issue #123

UI acceptance belongs to the user. These are instructions, not executed UI tests.
Use a disposable transcript and a local reference clip; no cloud request is needed.
Keep a copy of the original audio and raw/canonical transcript files or compare
their SHA-256 hashes before/after. Corrections live separately from those files.

## Selected-passage Cancel sound analysis

1. Open the candidate in Studio with recording and audio tests idle. Open a
   disposable transcript with a timed passage between 3 seconds and 2 minutes on
   a known channel. A passage close to 2 minutes makes the active control easier
   to catch. Note its original words, language label, review state and corrections.
2. If the automatic music check is running, choose **Stop automatic music check**
   first. The selected-passage action should not have a competing automatic task.
3. Click **Analyze sound locally**, then immediately click **Cancel sound analysis**
   beside **Analyzing selected passage locally…** at the bottom of Studio.
4. Expect the progress/cancel row to disappear and Analyze to become available.
   No newly returned proposal, confirmation action or music-only correction may
   appear from the cancelled request. Words, language and review status remain as
   before this action. Already saved corrections from earlier actions stay saved.
5. Wait at least 30 seconds (the cooperative analysis deadline). A late framework
   completion must not put the cancelled result back. The app remains responsive.
6. Select a different passage/channel and analyze again without cancelling. Any
   result must show that new passage's timing/channel. Voice/uncertainty keeps words;
   a strong music proposal still needs **Confirm music only** for this manual path.
   Inspect Original recognition and the before/after file hashes.
7. Repeat cancellation by switching to another transcript or leaving Studio while
   analysis is active, then return. The old proposal must not appear in the new
   transcript or after returning. Repeat by closing and reopening the app; no old
   busy indicator or unsolicited correction should return.

Analysis can finish before the button is clicked, even for the maximum supported
passage. If it does, record **not exercised — completed before cancellation**, not
passed or failed. Do not extend passage bounds, alter privacy permissions or slow
production processing just to obtain a result. Deterministic cancellation and
late-return behavior are separately tested using an injected worker in
`SegmentAcousticReviewTests`; that automated evidence does not count as a manual
active-cancel interaction. Record candidate revision, passage duration/channel,
whether the cancel control was visible, observed outcome and preservation hashes.

## Automatic check stop, resume and restoration

1. Open an unreviewed disposable transcript with separate instrumental, speech and
   quiet speech-over-music passages. Automatic checking starts locally when Studio
   loads it; capture, background transcription and another passage analysis block it.
2. While **Checking music-only passages locally…** is visible, click **Stop automatic
   music check**. Expect the progress to stop promptly. Passages already saved as
   automatically hidden may remain; remaining passages keep their recognition.
   Wait 30 seconds and check that no late result hides another passage.
3. Choose **Continue music check**. No overlapping request should start. Each run
   checks at most 32 passages, two minutes of selected audio and 30 cooperative
   seconds; a paused run reports its remaining passages. Uncertain/failed/short
   passages keep words. Violin's existing ambiguous fixture must remain unsuppressed.
4. For an automatically hidden passage, choose **Restore original recognition**.
   Reopen the transcript and continue checking. That passage must keep its original
   text and should not be automatically hidden again for the same transcript
   revision. Edit another passage while a scan is running; the edit must take
   precedence, survive reopening and appear in copied/shared text.
5. Start another scan, then leave Studio or begin other audio work. The task must
   stop without applying late results. Existing saved changes remain recoverable.

The classifier's synchronous framework calls cannot be forcibly interrupted.
Cancellation is cooperative between calls; a delayed framework return must still
be rejected before applying a result. No audio upload or API key is involved.
