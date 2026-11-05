# Speech and language experiments

These opt-in policies support isolated development experiments under #107 and
#108. They are not promoted defaults or evidence of improved quality. The current
fixed-window/no-VAD and automatic language controls remain available.

The private shared Whisper profile accepts `speech` and `language_policy`:

```json
{
  "schema_version": "1.0",
  "speech": {
    "mode": "silero",
    "vad_model": "/absolute/private/path/to/ggml-silero.bin",
    "threshold": 0.5,
    "min_speech_ms": 250,
    "min_silence_ms": 100,
    "max_speech_seconds": 30,
    "padding_ms": 30,
    "overlap_seconds": 0.1
  },
  "language_policy": "speech_aware_auto"
}
```

Use the shared profile's documented decoding fields as required. The no-VAD
control is `"speech":{"mode":"none"}`; the language control is
`"language_policy":"current_auto"`. Missing keys preserve existing behavior,
including an explicitly selected legacy final-job VAD model. Merely having an old
saved VAD path must not silently activate a new live experiment.

The speech policy uses whisper.cpp's existing Silero implementation and speech
padding/overlap. It does not add an energy threshold, discard quiet input in
RecScribe, trim original recordings, alter committed cursors, merge final channels
or infer missing word times. Parameter bounds reject unbounded padding/segments
before a recognizer process starts. The installed binary must advertise every
requested option and the model must pass the existing Silero header check.
Unknown or incompatible capabilities fail visibly.

In the inspected whisper.cpp 1.9.5 implementation,
[VAD precedes automatic detection](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp#L7256)
and [VAD offsets map back to original input time](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp#L6326).
Thus `speech_aware_auto` requires an explicit Silero policy for an automatic
request while retaining `-l auto`. It has no language whitelist, preference list,
cross-window vote or permanent lock. Explicit source languages still win; `de-CH`
maps to `de`, which makes no claim about Swiss German identification or wording.
Cross-invocation previous-text conditioning is unavailable, so earlier-language
text is not carried into the next source/window/channel invocation. A positive
`context_tokens` setting applies within the native invocation only. Internal
code-switching and context behavior inside a long final-file invocation remain
upstream behavior and require evaluation; no new mid-file language redetection
or context-reset algorithm is claimed.

The speech-aware language profile requires the inspected runtime version 1.9.5.
Other versions remain unavailable for that experiment until their ordering is
reviewed; VAD option names alone do not prove equivalent behavior.

The CLI's JSON records the recognizer language but not language-ID confidence,
VAD probabilities or rejected source intervals. These values remain null with
an explicit unavailable status; the retained private process log is evidence,
not a structured ground-truth segmentation. No speech text enters general app
logs. An empty ASR result is not proof of silence or correct rejection. The
upstream timestamp granularity and untimed-word limitations still apply.
Live attempts retain a bounded process prefix/tail and truncation flag beside
their raw recognizer output; a truncated log cannot establish every VAD region.

Run development profiles separately for VAD, padding changes and decoding. The
speech-aware language experiment necessarily shares upstream VAD processing;
compare it to both automatic/no-VAD and automatic/VAD controls and report that
interaction. It is not an independently trained language detector. Final jobs
and mixed live previews remain different input paths.
The opt-in live adapter API takes capabilities/version captured by its caller.
The benchmark's real live-replay integration and one-time binary/model identity
capture are still pending; the app's saved settings continue to use the control.

Pending acceptance includes: consented nine-language short/long-form corpus,
quiet speech and genuine non-speech, boundaries/overlaps/code switches, all model
controls, per-language lexical and critical-content review, quiet-speech deletion
and false-speech budgets, calibrated language-ID coverage, real-runtime source
interval mapping, live delay/backlog and resource measurements. No Silero model
was installed during the initial audit. Synthetic policy tests establish
validation/control-flow contracts only. Freeze settings after development
comparisons; held-out scoring and promotion remain pending until the matrix and
human review are complete. The previously rejected permanent lock is documented
in [live transcription reliability](../docs/live-transcription-reliability.md).
