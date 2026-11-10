# Proposed passage accuracy display — issue #123

This is a design and calculation proposal, not a fitted model or a claim about
today's transcripts. The example percentages below are illustrative. Existing
model confidence stays separate until a calibrator has passed the release gates.

## Mock

```text
0:30–0:41 · Channel 1
People sing side by side on the front porch swing.

Estimated word accuracy   92%   ⓘ       [Listen to passage] [Edit text]
                         ▰▰▰▰▰▰▰▰▰▱

▸ About this estimate
  Expected word accuracy for this original recognition, based on
  independently reviewed recordings similar to this passage.
  Calibration uncertainty: 87–95% (95% interval for the matched group).
  This does not mean a 92% chance that every word is correct.
  Original model confidence: 97% · Calibration: whisper-turbo/en/v1
```

The range describes uncertainty in the calibration group's mean, not a guarantee
or prediction interval for this individual passage. Omit the range when the group
is too small. Show accessible text as well as a bar; color alone conveys nothing.
Use a neutral estimate label rather than an unchecked/checked or trust badge.

| Passage state | Visible label |
| --- | --- |
| Supported original speech | **Estimated word accuracy 92%**; details explain basis and limitations |
| Missing features, unsupported language/model or failed calibration gate | **Accuracy estimate unavailable**; details can still show original model confidence |
| Music automatically hidden | **Music only · automatically hidden** / **Text accuracy: not applicable**; Listen, Original recognition and Restore original recognition stay available |
| Manually corrected speech | **Manually corrected · not scored**; retain original estimate under Original recognition, never promote a manual edit to 100% |
| Translated/normalized text | Label any available estimate **Original speech estimate**; do not apply source ASR accuracy to a translation or rewrite |
| Character-based language with a validated separate model | **Estimated character accuracy 92%**; never silently relabel character error rate as word accuracy |

## Calculation

1. Build consented/licensed, independently listening-reviewed references, aligned
   to the same segment/channel as original ASR. Version normalization and word or
   character segmentation, including language-specific policies already used by
   `TranscriptAccuracy`. Reference ambiguity is reviewed or excluded explicitly.
2. For each speech reference with N reference words, align hypothesis and
   reference to count substitutions S, deletions D and insertions I:

   `WER = (S + D + I) / N`

   `y = clamp(1 - WER, 0, 1)`

   y is the bounded word-accuracy target, not a probability of a perfect passage.
   WER itself remains unclipped in benchmark reports, including values over 1.
   Example: N=50, S=2, D=1, I=1 gives a reference-measured target of 92%. It is
   not possible to calculate that measured value for unseen audio without a
   reference. Empty references have no WER; evaluate hallucinated words per minute
   and speech-preservation errors separately, rather than assigning 100% accuracy.
3. Fit a quality predictor using training recordings only. The initial transparent
   baseline is `q = sigmoid(b + β·x)`, fitted against y with soft-label cross entropy.
   Features can include length-weighted mean/lower-tail token log probabilities
   (when actually supplied), repetition, duration, speech/music evidence, source
   quality and disagreement between independently configured recognizers. Include
   missing-feature indicators; do not invent token probabilities for backends that
   omit them. Logits, coefficients, preprocessing and supported model/language
   combinations are versioned learned parameters, not hand-chosen quality votes.
4. On disjoint calibration recordings, fit a monotonic isotonic mapping
   `g = argmin Σ (g(q_i) - y_i)^2`. Display
   `round(100 × clamp(g(q), 0, 1))`. This estimates expected bounded word accuracy
   of comparable segments. It is not `100 × mean(token confidence)`, a SoundAnalysis
   score, `1 - no_speech_probability`, or a multiplication of correlated scores.
   Illustration only: q=0.89 mapped by a learned g to 0.92 would display 92%.
5. Keep training, calibration and final evaluation disjoint by recording, speaker,
   source work and all derived mixtures. Freeze the split before fitting. Evaluate
   by model/version, language and conditions including quiet speech, music overlap,
   singing and language switches. Never calibrate and report on the same fixtures
   used to tune music thresholds. User corrections enter only after explicit
   consent and listening review, with that recording held out of its evaluation.
6. Report mean absolute error and calibration curves comparing mean predicted and
   mean observed y in fixed bins. A continuous-target calibration error is
   `Σ_b (n_b/n) × abs(mean(p_b) - mean(y_b))`. Use recording/speaker-cluster bootstrap
   confidence intervals, rather than treating repeated words/derived mixtures as
   independent samples. Validate high-estimate mistakes as a separate slice. A
   low global calibration error cannot hide poor speech/music performance.
7. Proposed numeric release gates, to agree before data collection: at least 100
   independent held-out recordings and 500 scored speech segments per displayed
   model/language family; at least 50 independent recording clusters in any bin
   used for a displayed interval; calibration error ≤5 percentage points overall
   and ≤10 points in every supported risk slice, with bootstrap upper bounds also
   meeting those limits. These are proposed product criteria, not achieved results
   or a guarantee of sufficient statistical power. Unsupported/thin slices remain
   unavailable. Publish sample counts and interval widths. Revalidate after ASR,
   feature, language-policy or OS classifier changes; mismatch disables the number.

No recording-wide percentage is proposed initially: averaging segment percentages
or probabilities can mislead. Timestamp, speaker, semantic and translation accuracy
are outside this score and must not borrow its percentage.

The reason for a separate calibrated mapping is supported by
[Guo et al., 2017](https://proceedings.mlr.press/v70/guo17a.html), which studies
confidence miscalibration. [Scikit-learn's calibration documentation](https://scikit-learn.org/stable/modules/calibration.html)
describes isotonic/sigmoid calibration and the need for data separate from model
training. The continuous word-accuracy target, features and release gates above
are our proposed design; those sources do not validate it on RecScribe audio.
