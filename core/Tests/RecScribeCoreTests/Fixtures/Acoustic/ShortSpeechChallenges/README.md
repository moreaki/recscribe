# Short speech source bursts over piano

Nine eight-second mono PCM16/16 kHz derived challenges. A 250, 500 or 1000 ms
excerpt beginning two seconds into each existing English, German or Mandarin
FLEURS speech fixture is inserted at 3.5 seconds into the piano fixture. Excerpt
RMS is -30 dB relative to the full music RMS. The sum is rounded/clamped to PCM16
and the complete result multiplied by 0.7 and rounded. Hashes, exact offsets,
durations, levels and source hashes are in `manifest.json`.

They are speech-source development mixtures, not independently recorded whispers,
held-out speakers or listening-approved annotations. Their short excerpts have not
been independently aligned/adjudicated as individual words. Approval of original
clips does not approve these derivatives. All 27 development mixtures at -6/-18/-30
dB were already retained as voice by the #130 baseline; these nine quiet cases
protect preservation rather than demonstrating a new measured accuracy gain.

Piano: J. S. Bach, English Suite no. 3, Radek Materka, CC0-1.0. Speech: Google FLEURS,
Conneau et al., *FLEURS: Few-shot Learning Evaluation of Universal Representations
of Speech*, CC BY 4.0. These mixtures are modifications of those sources. Retain
the credits, exact source IDs/revisions and license links in `../README.md` and
`../manifest.json` along with the derivative hashes here.

Source originals and the complete development/baseline reports remain in protected
external RecScribe benchmark storage. Automatic suppression remains disabled.
