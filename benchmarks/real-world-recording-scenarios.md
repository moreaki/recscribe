# Real-world recording scenarios (#122)

The public-video packages and the user's future recording supplement the short
read-speech pilot. All scenarios need source/reference review before scored
acceptance. Keep the original recording and independent channels unchanged.

For an initial consented recording, aim for 5–10 minutes in a language the speaker
actually uses. Record permission for local evaluation and assign anonymous
speaker/session/source IDs. A useful sequence is:

1. Leave 5–10 seconds of real room ambience, speak softly, then speak normally.
2. Discuss an actual topic naturally for a few minutes; include some pauses and
   sentences that continue across the live transcription window boundaries.
3. Include names and distinct numbers (for example 13 versus 30), dates, an
   address, and both a positive and a negated statement. Retain what was actually
   spoken in the reference, including corrections and meaningful omissions.
4. Include a separate noisier or more distant-microphone section and a quiet
   section. Record actual conditions rather than label a synthetic mix as natural.
5. If fluent speakers are available, add a clearly timed language switch and a
   brief overlap. Use genuine separate recording channels when testing channel
   independence; a mono public-video mix does not demonstrate that behavior.

Swiss German speech should be referenced as faithful written Standard German.
The reference reviewer checks meaning, names, numbers and negation; optional
dialect spelling remains separate. Record the actual variety and script for all
languages, including Arabic, Chinese and Portuguese.

Keep clean development and held-out recordings separate by actual speaker,
session and original source. A quieter/noisier derivative or second clip from
the same recording stays in that source's partition. Unknown grouping stays
unknown. A scripted checklist is a diagnostic condition, not spontaneous speech.

Public video acquisition retains audio, raw available same-language manual
captions, source metadata and fixed source intervals. Caption timing/content and
permitted use remain review tasks. Burned-in or automatic captions do not supply
an approved downloadable reference. Do not fill the gap with a recognizer's own
output. Review references using original audio/captions, with candidate transcripts
kept out of the reference-review process.

For poorer-audio diagnostics, the existing bounded `derive-sensitivity.py`
primitives retain the original, apply exact signed PCM attenuation (1/8 gain) or
add a 30-second digital-zero opening, and preserve source-time offsets/hashes.
These are labelled synthetic; they do not fill natural adverse-condition coverage.
Resource-only cases can retain these views without inventing reference text.

The same module also provides a bounded `add_white_noise` diagnostic primitive.
Use a prospectively fixed SNR and seed; it records achieved post-clipping SNR,
clipped samples, hashes and unchanged frame count. Retain the parent source group
and label it synthetic. Noise can mask words, so reference audibility review
remains necessary before scored acceptance.
