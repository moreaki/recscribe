# Round 1 weight-edit reproduction inputs

These are the three AI-authored recipes predeclared in the
[pilot protocol](../../weight-space-pilot-protocol.md), for research issue #112.
They are required research inputs, not model binaries, recognition results or
selected defaults. The motivating development evidence is pinned to the
[untouched baseline report at `50ff6ab`](https://github.com/moreaki/recscribe/blob/50ff6ab20671e7270d8da5fe85949ef13c103583/benchmarks/pilot-baseline-2026-11-05.md).
No held-out references/outcomes inform these recipes.

All recipes require the unchanged multilingual Tiny GGML source, **77,691,713
bytes**, SHA-256
`be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21`.
They scale only the declared FP16 decoder cross-attention output-projection
matrices. Shapes, tokenizer/vocabulary, biases and every unselected byte remain
unchanged. The serialized GGML shape is `[384, 384]`, with its first dimension
contiguous; flat ranges follow file order.

| Recipe | Declared intervention | Expected derived model SHA-256 |
| --- | --- | --- |
| [cross-all-gain-110.recipe.json](cross-all-gain-110.recipe.json) | All four decoder layers, factor 1.10; 589,824 selected elements | `7c30753f8421ffc6ebf02a31efb8112eb6ae60a6271217f46bdb2ad3158c8c42` |
| [cross-all-gain-090.recipe.json](cross-all-gain-090.recipe.json) | Directional control: all four decoder layers, factor 0.90; 589,824 selected elements | `22662a18171ddbb7cea42d3e429abaadc5d23124798b00a0f12ad84c9c8f4f44` |
| [cross-last-gain-110.recipe.json](cross-last-gain-110.recipe.json) | Localization control: decoder layer 3 only, factor 1.10; 147,456 selected elements | `f7355c36ace23c76eb18ab84892e2d266b0552a29ce0a9da6a1eaafb52ebea7e` |

The protected original runs constructed these artifacts and completed static
finite/layout/byte-difference validation. These hashes identify model bytes;
candidate ASR quality, latency and memory comparisons remain pending at this
revision. Every derived model has the same byte size as its source. This edit
does not demonstrate compression or a recognition improvement.

The published all-layer 1.10 recipe was also executed independently and reproduced
the exact expected model SHA-256 above. All three public recipe objects were
checked against their protected originals; only evidence metadata differs.

## Tool, dependencies and limits

[`scripts/quality/ggml_weights.py`](../../../scripts/quality/ggml_weights.py)
uses Python 3's standard library for parsing/editing. NumPy is an optional
accelerator for read-only finite/norm diagnostics; it is not required for the
edited byte values. No Torch, training loop, network service or app-runtime
dependency is used. Tool/Python identities are retained in each edit audit.

The format is pinned to whisper.cpp **v1.9.5**'s legacy little-endian Whisper
GGML loader/exporter. It accepts unquantized header ftype 0/1 with the expected
F32/F16 tensor names/shapes/dtypes, original serialized vocabulary and mel-filter
layout. **Quantized tensors and GGUF are rejected.** The separately exported
Base Q5_1 control is not one of these AI recipes and cannot be inspected or
edited with this tool.

Default limits are 512 MiB per model, 32 MiB serialized vocabulary, 65,536 stored
tokens, 8,192 tensors, 1,024 edit operations and 1,048,576 selected elements.
Scans use bounded blocks and cancellation checks. The CLI allows an explicit
model-size budget up to 4 GiB and a positive timeout up to 600 seconds. Recipes
support only validated `set` and contiguous `scale` operations; no arbitrary code
or architecture surgery is executed. Source identity/hash, finite values,
selected ranges and unchanged bytes are checked. Original files are opened
read-only. A failure retains partial/quarantined artifacts and failure evidence
instead of a completed candidate.

## Reproduce one artifact

From the repository root, run one transformation at a time while recording and
audio tests are idle. The output directory must be new and its parent must
exist. Keep model artifacts/audits in the protected external benchmark location;
the artifact wrapper captures only disposable command logs.

```sh
RECSCRIBE_WEIGHT_REPRO_DIR="$HOME/Library/Application Support/RecScribe/Benchmarks/Research/112/reproduction"
mkdir -p "$RECSCRIBE_WEIGHT_REPRO_DIR"

python3 scripts/work-artifacts.py run --label issue-112-reproduce scratch -- \
  python3 scripts/quality/ggml_weights.py --timeout 120 \
  --cancel-file "$RECSCRIBE_WEIGHT_REPRO_DIR/cancel.request" \
  apply "$HOME/Library/Application Support/RecScribe/Models/ggml-tiny.bin" \
  benchmarks/weight-space/round-1/cross-all-gain-110.recipe.json \
  --output "$RECSCRIBE_WEIGHT_REPRO_DIR/cross-all-gain-110-NEW"
```

Successful output contains `model.bin` and `edit-audit.json`. Compare the audit's
`source_sha256` and `derived_sha256` with the hashes above; require
`state: "completed"`. Creating `cancel.request` at the chosen path or sending
Ctrl-C requests cancellation. Check capture state again before any later
inference run; this reproduction command performs no recognition.

The other two recipes use the same command with the corresponding recipe and
a different new output directory. Keep factors and tensor/range selections
unchanged for this frozen three-candidate family.

Read-only inspection is available with `inspect MODEL --statistics --report
NEW_JSON`, following any global timeout/cancellation options. Focused tool
regressions can be run through the artifact wrapper:

```sh
python3 scripts/work-artifacts.py run --label issue-112-weight-tool test -- \
  python3 -m unittest discover -s scripts/tests -p test_ggml_weights.py
```

## Public recipe metadata and original private freeze

The original protected recipes, freeze and edit audits remain unchanged. These
public copies preserve their exact source hash, author, hypothesis, tensor
operations, factors, shapes and dtypes. Only `development_evidence` changes:
machine-local evidence paths are replaced with the public baseline permalink.
That metadata change alters the canonical recipe SHA-256 and a newly generated
audit's metadata hashes; it does not alter any selected model value or expected
derived model hash. Reproduction audits also record their actual local paths,
time and tool/Python version, so audit-file hashes are not expected to match the
original private audit-file bytes.

The original private canonical recipe hashes, retained in those frozen audits,
are:

- All-layer 1.10: `430fe077dddccb82dbaf92c4a1b51562c5e31790121fdb79bf8df22bd1a5fbb6`.
- All-layer 0.90: `f867da447d7b5add61f7c37943417da4dbf976c0f4641630fb817d9f81e8fc2a`.
- Last-layer 1.10: `2f08d139d11bb49dd140cde5afec655b352edf3e5e17d49cdb4e980bd88b6d41`.

The protected freeze remains the record of what was selected before candidate
outcomes. Publishing portable metadata does not reopen selection, add a fourth
candidate, change a parameter or establish a held-out result.
