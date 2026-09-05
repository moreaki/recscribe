# Security policy

RecScribe records audio and will process transcripts locally, so privacy and safe file
handling are core security requirements.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for
[`moreaki/recscribe`](https://github.com/moreaki/recscribe/security) when available.
If private reporting is unavailable, open an issue without exploit details and ask for
a private contact channel.

Do not include recordings, transcripts, credentials, signing certificates, private
keys, or other sensitive data in a public report.

## Supported versions

RecScribe has not published a stable release yet. Security fixes currently target the
latest commit on `main`.

## Security boundaries

- Audio capture and storage are local by default.
- The application contains no telemetry or analytics.
- The inherited Home Rec automatic-update channel has been removed.
- Signing keys, notarization credentials, and transcription service credentials must
  never be committed to the repository.
- Future remote transcription providers must be opt-in and disclose what data leaves
  the Mac.
