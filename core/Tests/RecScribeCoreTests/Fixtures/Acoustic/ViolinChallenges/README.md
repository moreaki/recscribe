# Quiet speech over violin challenges

Nine synthetic mixtures of the existing violin fixture and the existing English,
German and Mandarin speech fixtures. Their source hashes, mixture parameters and
output hashes are in `manifest.json`. Speech RMS is -6, -18 or -30 dB relative to
the violin; the sum is multiplied by 0.7 and rounded/clamped to PCM16. No resampling
or source trimming is added. Each file is eight seconds, mono PCM16/16 kHz.

These mixtures contain known speech by construction, independent of classifier or
ASR output. They are development challenges with shared sources, not independently
recorded/held-out data, and are **not listening-approved**. Existing user approval
of the violin/English originals does not approve these mixtures.

The violin is a public-domain 1920 recording of Bach's Air by Joel Belov and
Robert Gayler. Speech is modified Google FLEURS data, CC BY 4.0, Conneau et al.,
*FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech*.
Retain the exact source IDs, published revision, hashes and credits in
`../manifest.json` and the source/license links in `../README.md`.

An experimental eight-second music-only fallback falsely accepted the three
-30 dB mixtures. It was rejected. Longer context can only yield a music/listening
review hint; it cannot make these cases eligible for music-only confirmation.
