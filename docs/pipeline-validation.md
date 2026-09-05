# Local validation record — 2026-09-05

Validation ran directly in the RecScribe checkout on the MacBook Air. Starting
commit: `4d695ed`. No cloud worker or separate application worktree was used.

## Native recorder

- `./scripts/build-app.sh`: signed Release build succeeded.
- Xcode's native unit suite: 288 tests passed, 313 executions including dynamic
  parameter cases, zero failures and skips.
- `codesign --verify --deep --strict`: passed.
- Bundle ID `com.moreaki.recscribe`, team `CDS4KLP8GT`, runtime signing flag present.
- Effective Release settings: Swift 6.0, strict concurrency `complete`, Hardened
  Runtime enabled. Apple Development signature; not a notarized distribution.
- Fresh Release process started directly from `Build/Products/Release/RecScribe.app`
  without launching Xcode. Native capture implementation was not modified.

## Pipeline

29 synthetic unit/integration tests passed. Tests include integer PCM widths,
channel preservation, silence, damaged input, source mutation, raw-file preservation,
schema and semantic validation, padding provenance, language modes, two-pass
disagreement, identical model rejection, subprocess failure/timeout, SIGTERM and
file-based cancellation, repetition/automatic-language review markers, exact exports,
whisper.cpp's CLI/JSON contract, benchmark
accuracy calculations, corpus readiness and real macOS resource accounting.

Built a Python wheel, installed it in a separate local test environment, verified
the packaged JSON Schema and exercised the installed CLI entry point. Validated
the repository's small Codex skill with the skill-creator validator.

Installed the reference CLI through Homebrew (`whisper.cpp` 1.9.2). Converted an
already present local Whisper `small.pt` using upstream's matching
`models/convert-pt-to-ggml.py` and the locally installed Whisper tokenizer assets.
No model weights were downloaded. The private user's supplied WAV completed the
full pipeline, with all nine required artifacts, immutable source/raw hashes and
deterministic re-rendering independently checked. Its transcript and audio remain
in ignored local job directories; no private samples or reference text are added
to this repository.

The real smoke test found and drove corrections: allow cold Metal kernel
initialization during version probing, and represent end-of-audio decoder padding
as an explicit reviewed timing derivation, and mark automatic language selection
and repeated phrases as unverified. Auto-detection on a quiet opening selected
English for a German recording; an explicitly German later excerpt recognized
coherent speech. A German full-file run still repeated one marker. A targeted
silence-then-speech comparison exposed a second failure in the initial decoder
configuration: carrying previous text while disabling temperature fallback could
trap the decoder in repetition. With text context disabled and upstream's local
decoder fallback restored, the speech after the silent opening was recognized.
These observations are not proof of dialect accuracy. Failed earlier jobs remain available
for inspection and were not reused or overwritten.

The benchmark template correctly reports all five categories as `pending_corpus`.
This work establishes executable orchestration and output contracts, not verified
recognition accuracy. There is no human-corrected reference corpus yet; WER/CER for
the private recording, dialect fidelity, translation/normalization quality,
diarization accuracy and WhisperKit/MLX comparisons remain unmeasured.
