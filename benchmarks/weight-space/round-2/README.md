# Round-2 affine-bias recipes

These are fixed research inputs for [#112](https://github.com/moreaki/recscribe/issues/112).
Read the [predeclared protocol](../../weight-space-round2-protocol.md) before
running them. No training, parameter search, language mask, app-default change
or compression is performed. Swiss speech targets faithful written Standard
German. Native/v2/representative review remains pending.

Each candidate scales one selected **64-element F32 value-bias block by 0.90**.
Selection uses only original weights: the largest static
`||O_h bV_h||_2 / ||O_h V_h||_F` across decoder cross-attention heads,
ties by lower layer/head. It is a coordinate-dependent weight heuristic, not
activation saliency or proof of an error mechanism. Tiny selects layer0/head3,
Base layer0/head2, Small layer5/head3 (zero based). No other byte is selected.

The independent control applies the same rounded bias change and compensates
the resulting constant in the output bias. The real-arithmetic affine identity
does not guarantee bitwise inference identity: KV-cache casts and fused
arithmetic can introduce input-dependent rounding. Actual control inference is
required. Static validation alone establishes no accuracy gain.

## Exact artifacts

| Model | Bytes in every artifact | Original SHA-256 |
| --- | ---: | --- |
| Tiny | 77,691,713 | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| Base | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| Small | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |

| Model | Candidate SHA-256 | Compensated-control SHA-256 |
| --- | --- | --- |
| Tiny | `25298e3a5ca56db8a8b4bcf57f6df397457e4500605a6773921a421c7217d32b` | `72a289860bf9063cd4c4cdef94db18e2bd384df40ccb436f6146242cb9536757` |
| Base | `5e23f028452ca7ec7dddd0cd57adfbc905817d9c69eff5c808f6d4057c79c663` | `d0bfdf29324e480a4584292189f254bcd5532158b5fbedd7f682601b5dee363c` |
| Small | `b87bbda0a4fa323072022fa0d99a04b77aeaa4440ad3451785d2796fe68e6206` | `bafdddc9c922b2b20b972ae988421c7bbcdcff96070f0fe6a06d96579e996be9` |

Candidate recipes are [Tiny](tiny-affine-090.recipe.json),
[Base](base-affine-090.recipe.json) and [Small](small-affine-090.recipe.json).
The source generator emits the longer explicit compensation recipes into a
new protected directory, without running ASR or editing a model. Exact source,
recipe, generator/editor hashes and all six byte-audited exports remain protected
under `~/Library/Application Support/RecScribe/Benchmarks/Research/112/round-2/`.

Independent inspection of the **stored F32 artifact bytes** found compensated
residual L2 5.7753e-8 / 8.1172e-8 / 3.6876e-8 for Tiny/Base/Small, below the
1e-6 absolute and 1e-5-relative limits. Originals and every byte outside declared
ranges match. Shapes, parameter count, vocabulary and file size remain unchanged.

## Reproduce a candidate

Use unchanged `scripts/quality/ggml_weights.py`, with the original model and
one public recipe. The parent protected directory must exist; the output must
be new. Run one transformation at a time with recording/audio tests idle:

```sh
python3 scripts/work-artifacts.py run --label affine-tiny-reproduce scratch -- \
  python3 scripts/quality/ggml_weights.py --timeout 600 \
  apply "$HOME/Library/Application Support/RecScribe/Models/ggml-tiny.bin" \
  benchmarks/weight-space/round-2/tiny-affine-090.recipe.json \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/112/tiny-affine-NEW"
```

Require a completed audit and the expected derived hash. Original files are
opened read-only. Failure/cancellation retains partial or quarantined evidence.
NumPy accelerates the editor's finite scans when available; its absence does not
change the editor's multiplication/F32 rounding.

## Regenerate the numerical-control recipe

The generator requires Python and the explicitly pinned offline NumPy dependency
in [requirements.txt](../../../scripts/quality/requirements.txt). CI installs it
in a managed disposable virtual environment; it is never an app dependency.
The recorded experiment used Python3.15 and NumPy2.5.4. Within a prepared Python
environment, this example generates Tiny's two recipes and static diagnostics:

```sh
python3 scripts/work-artifacts.py run --label affine-tiny-recipes scratch -- \
  python3 scripts/quality/affine-bias-recipes.py \
  --model "tiny=$HOME/Library/Application Support/RecScribe/Models/ggml-tiny.bin" \
  --sha256 tiny=be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21 \
  --development-evidence https://github.com/moreaki/recscribe/blob/50ff6ab20671e7270d8da5fe85949ef13c103583/benchmarks/pilot-baseline-2026-11-05.md \
  --author "Codex AI; fixed round-2 affine-bias hypothesis without training" \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/Research/112/recipes-NEW" \
  --timeout 600
```

Apply `tiny/compensation-control.recipe.json` with the same unchanged editor
to a separate new artifact directory. Base/Small use their named model, exact
parent hash and corresponding generated recipes. At most three originals are
processed sequentially, with one numeric worker and explicit cancellation/time,
model-size, tensor-read, finite-value and edit bounds. The tool performs no ASR,
corpus-reference reads, downloads or model writes.

The protocol fixes 4,212 planned inference cells, per-model WER/CER gates,
separate known/auto results, an opaque fresh heldout and all unresolved resource/
native/coverage gates. Only successful repeat1 supplies lexical quality.
Results must be reported whether positive, negative, partial or inconclusive;
these artifact identities by themselves are not a quality result.
