# First reviewed music-only Studio fixtures

The user listened to the exact piano, violin/piano, English speech and -18 dB
speech-over-piano clips on 2026-11-10 and confirmed their proposed labels. Their
SHA-256 identities, licenses/credits and preparation are retained in
`core/Tests/RecScribeCoreTests/Fixtures/Acoustic/manifest.json`. German/Mandarin
speech and -6/-30 dB derived mixes remain explicitly listening-review pending.
Speech/mix fixtures are not licence-free: retain the Google FLEURS CC BY 4.0 credit.

## Development observation

The #128 baseline (one-second windows, minimum music 0.95) missed both instrumental
recordings. It retained all speech and mixed examples. Three-second windows with
one-second hops improve musical context. The minimum music score is now 0.85 for
suggestions requiring listening confirmation; the maximum voice score stays 0.05.
These settings were developed on this small set. No independent held-out claim is
made and automatic suppression remains disabled.

| Eight-second input | Minimum music score | Maximum monitored voice score | Result |
| --- | ---: | ---: | --- |
| Piano (approved music only) | 0.8995 | 0.0488 | Instrumental candidate; user confirmation required |
| 1920 violin/piano (approved music only) | 0.7002 | 0.0296 | Inconclusive; documented miss |
| English speech (approved speech) | 0.1343 | 0.7622 | Voice; preserve words |
| German speech (source-labelled) | 0.0793 | 0.9613 | Voice; preserve words |
| Mandarin speech (source-labelled) | 0.0912 | 0.9197 | Voice; preserve words |
| Speech/music at -6 dB (derived) | 0.7025 | 0.6822 | Voice; preserve words |
| Speech/music at -18 dB (approved mixed) | 0.8137 | 0.3002 | Voice; preserve words |
| Speech/music at -30 dB (derived) | 0.8768 | 0.1534 | Voice; preserve words |

Scores are SoundAnalysis outputs, not calibrated accuracy percentages. This is
one Mac/OS classifier implementation, not a cross-device performance guarantee.
There are two instrumental examples and only one English voice under the music;
the mixtures share their sources. Precision/recall estimates from this set would
not establish deployment accuracy. Silence and fractional-tail coverage also have
separate synthetic regression tests.

## Release boundary

Studio can analyze and offer a reversible suggestion, but it cannot silently erase
text or infer spoken language from acoustic scores. The user must listen and confirm
music-only passages. The violin miss remains visible and manually correctable.
Inconclusive/error paths preserve recognition. Raw audio, raw/canonical transcripts
and frozen references remain unchanged.

Before unattended suppression, add independently reviewed held-out instrument,
singing/rap/humming, whisper-over-music, language-switch, noisy, long-form and
independent-channel recordings, and evaluate speech falsely suppressed separately
from missed music. Full functional/TSan CI and direct Studio review remain required.

## Violin follow-up: supporting context is not absence of speech

The violin's three-second windows score music 0.7002–0.8206, with maximum
monitored voice 0.0296. Eight-second context scores music 0.8291 and voice 0.0160.
Instrument-specific labels were also inspected; their low scores did not justify
promoting them into a substitute probability or summing correlated class scores.

An experimental fallback retaining every short-window voice veto and requiring
eight-second music >=0.80 falsely accepted three new -30 dB speech-over-violin
mixtures. That music-only fallback was rejected. Threshold tuning cannot reliably
separate these examples: long-context music/voice scores overlap the instrumental
fixture. The current result is instead **possible music; listening review needed**,
with no music-only candidate/correction offered from that hint.

| Input | Short-window minimum music | Short-window maximum voice | Eight-second music / voice | Current result |
| --- | ---: | ---: | ---: | --- |
| Approved violin | 0.7002 | 0.0296 | 0.8291 / 0.0160 | Music/listening review; keep recognition |
| German speech over violin, -30 dB | 0.7167 | 0.0290 | 0.8121 / 0.0160 | Music/listening review; keep speech |
| English speech over violin, -30 dB | 0.7075 | 0.0355 | 0.8075 / 0.0138 | Music/listening review; keep speech |
| Mandarin speech over violin, -30 dB | 0.6840 | 0.0326 | 0.8467 / 0.0163 | Music/listening review; keep speech |

At -6 and -18 dB all six new violin/speech mixtures trigger the short-window voice
veto. Existing piano, speech, and piano/speech cases retain their previous outcomes.
The nine new mixtures are hashed derived challenges with explicit pending listening
review, shared sources and public-domain/CC BY 4.0 attribution. They are not new
independent held-out evidence. No score above is a transcription accuracy percentage.
