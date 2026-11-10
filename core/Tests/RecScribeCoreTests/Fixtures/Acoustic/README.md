# Acoustic review fixtures

Eight-second mono PCM16/16 kHz clips. `manifest.json` binds exact SHA-256 hashes,
source identity/license, preparation and listening-review status. No ASR output
was used to establish the speech/music labels.

On 2026-11-10 the user listened to the piano, violin, English speech and -18 dB
speech/music mixture in this Codex chat and confirmed all four expected labels.
German/Mandarin read speech and the other derived mixes are explicitly not marked
listening-approved. This small development/challenge set is not independent held-out
validation, does not cover whispered speech or vocals, and does not authorize
automatic suppression.

Piano: J. S. Bach, English Suite no. 3 BWV 808, performed by Radek Materka;
30–38 seconds. CC0-1.0. Source and license:
https://commons.wikimedia.org/wiki/File:J._S._Bach_-_English_Suite_no._3,_BWV_808.ogg

Violin/piano: Bach's Air, Joel Belov (violin), Robert Gayler (piano), 1920 recording;
30–38 seconds. Public domain. Source:
https://commons.wikimedia.org/wiki/File:Air_(Bach).ogg

Speech: Google FLEURS, Conneau et al., *FLEURS: Few-shot Learning Evaluation of
Universal Representations of Speech*. CC BY 4.0. These clips are modified to the
first eight seconds of the declared published files, mono PCM16/16 kHz. Individual
source IDs, original hashes and the pinned dataset revision are in the manifest.
https://huggingface.co/datasets/google/fleurs
https://creativecommons.org/licenses/by/4.0/

Mixtures combine the piano and English speech fixtures, with speech RMS at -6,
-18 or -30 dB relative to music, then multiply their sum by 0.7 and round/clamp to
PCM16. The music CC0 and speech CC BY 4.0 attribution above both apply. They are
explicit synthetic challenge mixtures, not naturally recorded conversations.

Source originals and acquisition/evaluation records remain in protected external
RecScribe benchmark storage. Frozen transcript references are unchanged.
