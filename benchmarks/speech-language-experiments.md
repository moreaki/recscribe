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

## Prepared synthetic development inputs

`scripts/quality/derive-sensitivity.py` prepares two explicitly synthetic
conditions from an explicitly selected development-only legacy manifest. It
performs no recognition or downloads. The protected preparation at
`~/Library/Application Support/RecScribe/Benchmarks/Corpora/runtime-sensitivity-20261105-v1/`
contains 18 derivatives from nine parent utterances, one per priority language,
plus byte snapshots of each selected input WAV, reference and provenance, the
input manifest and the preparation recipe. Preparation completed; VAD/language
inference on these inputs has not started and no quality results are claimed.

The unchanged-input stage U uses the existing nine-case
`Research/112/round-1/development.selected.json` manifest. Q30 adds exactly 480,000
zero-valued PCM frames (30 seconds) before each input, retaining every original
PCM sample unchanged. A18 applies a fixed gain of 1/8, with signed integer
division truncated toward zero, retaining the frame count. This is nominal
−18.0618 dB amplitude attenuation plus quantization; existing speech and noise
are scaled together. Each condition has nine instances sharing the same parent
source/speaker/session groups. These are nine distinct parent utterances, not
27 independent samples; speaker/session independence remains unestablished.
Neither constructed silence nor attenuation establishes natural quiet speech,
realistic adverse conditions, long-form coverage or new dialect/script coverage.
Originals and held-out data remain separate.

Reproduce preparation into a **new** protected external directory:

```sh
python3 scripts/work-artifacts.py run --label quality-sensitivity benchmark -- \
  python3 scripts/quality/derive-sensitivity.py \
  --manifest "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/112/round-1/development.selected.json" \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/Corpora/NEW-runtime-sensitivity"
```

The script accepts only mono 16 kHz PCM16 WAV, rejects held-out inputs,
symlinks/traversal, mismatched hashes/durations and existing output directories,
and checks source hashes before/after processing. Defaults bound preparation to
nine inputs of at most 60 seconds, 64 MiB of output and 120 seconds. Ctrl-C,
SIGTERM or `cancel.request` in the output directory cancels between bounded
chunks; incomplete protected evidence remains. Logs are disposable wrapper
output; source snapshots, references, manifests and derivatives are protected
corpus data.

`manifest.exploratory.legacy.json` is for a future exploratory ASR run using
`swift-nfc-casefold-alphanumeric-v1` (`legacy-v1`). The original declared policy
is retained separately; schema conversion does not upgrade scoring.
`manifest.v2.pending.json` keeps `reviewed: false`, `frozen: false` and unknown
grouping/domain evidence pending. No native approval is inferred. Chinese
results must use legacy CER only, without interpreting whitespace WER as word
accuracy. Q30 timestamps refer first to the derived file; preserve raw times
and retain a separate source projection subtracting 30 seconds only for the
intersection with original input time. No word/onset alignment is available.

## Planned isolated runtime stages

Start with unchanged multilingual Tiny and the same frozen CLI, whisper.cpp
1.9.5 binary/libraries, decoding settings, two threads and source path in every
arm. Keep known-language and unrestricted auto controls in each stage; `de-CH`
maps to the known `de` control. Run U before Q30 before A18, with three repeats
per cell; score repeat 1 only and use repeats for timing/variation evidence.

| Profile | Speech/boundary intervention |
| --- | --- |
| No VAD | Current decoding and language controls |
| Silero without added boundary padding/overlap | Padding 0 ms; overlap 0 s |
| Silero with boundary padding/overlap | Padding 30 ms; overlap 0.1 s |

Both Silero arms fix threshold 0.5, minimum speech 250 ms, minimum silence
100 ms and maximum speech 30 seconds. Their contrast isolates the joint
padding/overlap treatment; it cannot distinguish the individual effects of
those two parameters. Each core stage is 9 origins × 3 profiles × 2 language
modes × 3 repeats = 162 planned cells. An optional beam-size-3 decoding arm
belongs on U only, with no VAD and all other settings identical, adding 54
planned cells without combining decoding and speech interventions.

`speech_aware_auto` has the same effective recognition arguments as Silero plus
`-l auto`; its validation/provenance does not create an independent detector
arm. An empty VAD result with a raw `en` label can reflect upstream initial
state, not an observed English decision. Require nonempty auto ASR and detector
evidence for published-label language agreement; known-language labels are
forced controls, and `de` agreement does not identify Swiss dialects.

The official MIT-declared Silero v6.2.0 input is retained externally under
`Benchmarks/Models/silero-v6.2.0-hf-9ffd54a1e1ee/`: 885,098 bytes, SHA-256
`2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`.
It matches the published LFS hash at pinned
[model revision 9ffd54a1e1ee413ddf265af9913beaf518d1639b](https://huggingface.co/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b),
is listed by the pinned upstream download script, and passed static header
validation. This preparation is not an executed runtime-compatibility, quality
or latency result. Freeze settings/identities and finite run budgets before
inference, give recording priority, retain failures/pending cells, and complete
native review and held-out validation before considering defaults.

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
