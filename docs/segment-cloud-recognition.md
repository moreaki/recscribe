# Selected-passage cloud re-recognition

Studio offers **Re-recognize with OpenAI…** beside a passage and in its review
source panel. The approval dialog identifies the recording, exact time range,
channel, provider, model, destination and mono WAV byte count. **Keep audio local**
closes the dialog without reading credentials or sending audio. Each attempt
requires a fresh approval, including after errors or cancellation. This explicit
action is available independently of the default processing location; it never
changes that preference or enables background cloud transcription.

Only the approved channel and interval are uploaded. No adjacent context, other
channels, original transcript text, source identifiers or local paths are included
in the HTTP request. The filename on the wire is `segment.wav`. Fractional sample
boundaries round inward. WAV inputs and verified multipart recording sessions are
supported; gaps, unknown channels, changed source identity/revisions and ranges
past the audio end fail before upload. Each request is limited to two minutes and
24,000,000 WAV bytes. Extraction uses bounded blocks and temporary audio is removed
on completion, cancellation or failure.

The client uses `gpt-transcribe` at
`https://api.openai.com/v1/audio/transcriptions`, with the app's existing OpenAI
Keychain entry. This file-transcription contract follows the
[official OpenAI file-transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text).
The approval discloses API charges and provider retention. A single direct request
has a 120-second timeout and a 256 KiB response limit, with no redirects, retries
or fallback. Capture/audio tests, other active processing, changing the transcript
or leaving the workspace revoke pending approval and cancel ongoing work. Uploaded
audio cannot be recalled by cancelling local work.

Returned text is shown as an unverified candidate. **Use this recognition** is a
separate action that saves a source-linked correction using the existing locked
review store. Original audio, raw recognition, canonical transcript and generated
job artifacts are preserved. A changed passage or a newer manual correction blocks
stale application. An empty result leaves recognition unchanged and never guesses
that a passage is music or silence. Model confidence is never invented. Removing
the correction restores the previous rendering. Accepted cloud corrections are
identified as cloud recognition in Studio and in processing provenance.

Immutable consent, exact provider response and result references are stored under
`~/Library/Application Support/RecScribe/SegmentRecognition/<operation UUID>`.
These persistent evidence files include the local source reference, selected
frames/channel, model, approval time and audio/response SHA-256 hashes; credentials
are excluded. **Reveal cloud response** opens the evidence folder. The selected
audio clip itself is temporary. A failed/cancelled attempt retains its available
evidence, and repeating an operation ID is refused. Accepted corrections carry the
evidence reference in v3 review metadata; v1/v2 files remain readable. Prior
revisions and raw recognition remain recoverable outside disposable-artifact cleanup.

Focused tests use synthetic audio and injected transports, with zero billed API
calls. They inspect the multipart body sample by sample, cover channel isolation,
inward rounding, verified multipart boundaries, approval/key access, empty/malformed
and oversized responses, immutable evidence, cancellation/capture, stale results,
manual-edit conflicts, legacy migration and original-file preservation. Full
functional and full Thread Sanitizer CI remain required. Native review covers the
approval dialog and cancellation; a live provider round trip needs an actual user
approval and configured account.
