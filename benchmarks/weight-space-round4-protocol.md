# Round 4: fixed attention rotations before Q4 quantization

Prospective protocol, 2026-11-07. This is a new no-training experiment under
#112 after the three earlier families failed. Their artifacts, gates, scores
and consumed datasets remain unchanged. A significant improvement is required;
implementation, file compression or a numerical-control pass is insufficient.

## Question and fixed scope

Can one architecture-preserving change of attention coordinates improve
ordinary Q4_0 transcription enough to retain original-F16 quality at a smaller
file size? Small and large-v3-turbo are the two adapted families. Tiny, Base and
full large-v3 remain untouched references, preserving all five multilingual
baselines and all nine priority languages.

Small is a compact higher-quality tier; Turbo is a larger-capacity tier whose
round-3 reference errors were substantially lower. This selection uses historical
evidence before any round-4 inference. It is not a claim that smaller models have
reached a Shannon capacity limit. Full Large-v3 remains a reference because the
historical CER/WER results did not establish its universal superiority to Turbo.

Each adapted family has four separately hashed artifacts:

1. Original multilingual F16, never modified in place.
2. Rotated F16, the conversion/numerical control.
3. Original-to-Q4_0, the conventional compression control.
4. Rotated-F16-to-Q4_0, the combined candidate.

All artifacts follow the fixed plan regardless of development direction. No
gradient, training loop, fine-tuning, distillation, fitting, learned rotation,
seed/head/scale sweep, language masking or outcome-based recipe replacement is
allowed. No installed-app, saved default or distribution change is included.

## Architecture-specific weight program

The [weight-space programming article](https://rikiyat.github.io/blog/weight-space-programming/)
motivates AI-authored reasoning and weight edits. The attention derivation in
[QuaRot](https://arxiv.org/html/2404.00456v2) motivates a paired coordinate change;
it does not establish Whisper gains. This experiment uses neither QuaRot's
activation/KV quantization nor gradient-based rotation optimization such as
[SpinQuant](https://arxiv.org/abs/2405.16406).

The pinned whisper.cpp v1.9.5 architecture has 64 coordinates per attention
head. Small has 36 attention modules and Turbo 40, counting encoder self,
decoder self and decoder cross attention. Different encoder/decoder depths and
mel/vocabulary dimensions must be validated from each actual original model.

Use column vectors and stored weights viewed as output-by-input matrices.
For every head, apply fixed orthogonal matrices R and S:

- Q and K output rows: Wq'=R Wq, bq'=R bq, Wk'=R Wk. There is no key bias.
- V output rows and bias: Wv'=S Wv, bv'=S bv.
- Corresponding O input columns: Wo'[:,head]=Wo[:,head] S-transpose.
- Output bias stays unchanged. No coordinate mixing between different heads.

R-transpose R=S-transpose S=I preserves attention scores and the value/output
product in real arithmetic, including unequal query/key lengths, masks and
cross-attention. Scalar attention scaling commutes. LayerNorm, GELU, residual
streams, MLPs, embeddings, positional encodings and vocabulary are not edited.
No additional runtime operation or modified decoder implementation is required.

R=H64 Dqk and S=H64 Dvo, with right-multiplied diagonal sign matrices. H64[i,j]
equals (-1)^popcount(i&j)/8 in Sylvester order. Its coefficients are exactly
representable; finite weight/cache arithmetic is nevertheless not invariant.

For each sign mask, SHA-256 hashes this exact byte framing:

```
b"recscribe-whisper-attention-rotation-v1\0"
+ bytes.fromhex(ORIGINAL_MODEL_SHA256)
+ attention_tensor_prefix.encode("ascii") + b"\0"
+ head_index.to_bytes(4, "little")
+ pair_group.encode("ascii")  # exactly "qk" or "vo"
```

Take the first eight digest bytes, least-significant bit first within each byte;
bit zero means +1 and bit one means -1. The prefix, zero-based head, masks and
original hash are recorded. There is no configurable seed or alternate mask.
Signed H D is generally nonsymmetric: the O transformation must use its transpose.

Offline accumulation uses F64 and explicitly rounds back to the original F16/F32
storage type, with finite-value checks. Source identity/hash, architecture,
mel filters, vocabulary and every unselected byte region must be preserved.
Use the existing GGML inspector with an explicit bounded 4 GiB model limit;
its default 512 MiB must not be mistaken for Turbo support. New outputs are
exclusive external directories, with bounded tiles, cancellation and retained
failure/partial evidence. Originals are read-only.

## Quantization and attribution

Use the pinned official whisper-quantize executable, actual SHA recorded before
export, with Q4_0 only: ftype 2002, tensor type 2, blocks of 32 values/18 bytes.
The independent export audit validates actual container shapes/offsets/types,
finite scales, unchanged architecture/filter/vocabulary data and the official
passthrough rules. The F16 parser cannot certify a quantized artifact.

Plain and rotated Q4 must have the same layout and file bytes. All tensor payloads
unaffected by the rotation must match between those two exports. Per-site block
ranges and round-trip weight errors may be descriptive diagnostics, separated
for Q/K and V/O. They cannot select a different mask, head, recipe or threshold.
No new Python quantizer approximation substitutes for the pinned official binary.

Q4 supplies conventional file compression. Rotation adds no parameter reduction,
extra file saving or kernel-speed claim. A Turbo candidate matching Small F16's
487,601,967 bytes requires at least 69.9855% saving; the 65% acceptance floor alone
does not establish that size tier. Report actual bytes, not inferred download or
assembled-bundle size.

## Data and held-out isolation

Target 72 new development-validation and 144 new held-out sources: eight and
sixteen per language. Swiss German speech targets faithful written Standard
German. Dialect spelling is a separate task. Swiss has the same per-language
floors as German, French, Italian, English, Arabic, Chinese, Spanish and Portuguese.

Exclude all seven consumed manifests: original development, runtime sensitivity,
round-1 held-out, round-2 development/held-out and both entire round-3 manifests.
Exclude recorded case/source IDs, original/prepared audio/reference hashes and
known speaker/session overlaps. Reserve new Swiss speakers globally across both
splits, rather than assuming source partition names prove independence.
FLEURS speaker IDs and sessions remain incompletely known; no pretraining
exclusion, native approval or representative natural-condition claim follows.

Keep original audio, prepared inputs, reference bytes, source archive/member
identities, source timing and provenance in protected external storage. Held-out
reference content remains semantically uninspected before the candidate freeze.
The original acquisition freeze/stop and any prospectively bounded completion
amendment remain separate immutable records; missing cases cannot be discarded,
silently replaced or reported as complete. A derived final metadata view must
bind every retained source and amendment. No full held-out evaluation starts
unless all nine planned counts and opaque integrity/leakage checks pass.

The corpus is public short read speech, not reviewed-v2 product acceptance.
Document Swiss canton coverage and de_DE/fr_FR/it_IT/en_US/ar_EG/cmn_hans_CN/
es_419/pt_BR limits. Arabic locale is not dialect adjudication; Chinese means
Mandarin/Simplified here. Regional/script, adverse/long-form/non-speech, switches,
overlap, native critical-content and real independent-channel/live coverage stay
pending where missing. Published references are never rewritten to improve scores.

## Fixed evaluation grid

Use the existing unchanged comparison CLI and current-default profile, with
actual source/model/binary/library hashes and host/software fingerprints sealed.
Keep two threads, no VAD, no prompt or cross-source text conditioning, unrestricted
auto or explicit source base language (de for Swiss). Preserve inherited beam 5,
best-of 5 and temperature fallback. Pinned native CLI defaults enable Flash
Attention with F16 intermediate/cache storage: record and preserve that actual
setting. The earlier flash-disabled instrumentation probe is not an equivalence
check for these ASR calls. Temperature zero is not a determinism claim.

| Stage | Sources | Modes | Repeats | Runner cells | Native parent pairs | Q4 sibling contrasts |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Original-development numerical/timing panel | 9 | known + auto | 3 | 594 | 324 | 108 |
| Fresh development validation | 72 | known | 1 | 792 | 432 | 144 |
| Fresh held-out | 144 | known + auto | 1 | 3,168 | 1,728 | 576 |
| Total | | | | **4,554** | **2,484** | **828** |

The 1,242 reference-only runtime placeholders remain separately unpaired. The
Q4 sibling contrasts reuse canonical rows and add no native calls or independent
speech. Quality uses successful repeat 1 only, never a later-repeat fallback.
Panel repeats measure numerical identity/variation, not extra speech samples.

Freeze the operator, artifacts, settings, scoring, budgets and all 15 preplans
before quality inference. All ten panel/development grids must be terminally
attempted and assessed before all five held-out partitions/final plans seal
together. A fully attempted grid is not complete quality coverage. Natural native
format/timing failures remain failed and unscored under a fixed forensic contract;
unknown, setup/hash, capture, timeout and cancellation failures stop owned work.
Never repair transcript bytes, invent timing, retry measured cells or weaken gates.

## Material gain and preservation gates

Apply independently per adapted model and known/auto mode:

- At least 10% relative macro CER and 5% relative macro WER improvement versus
  ordinary Q4_0 of the same original model.
- Versus original F16, macro CER increase at most 0.0025 and WER at most 0.005:
  absolute 0.25/0.50 percentage points.
- Every language versus both controls: CER increase at most 0.01 and meaningful
  WER at most 0.02, absolute one/two percentage points. No extra Swiss veto.
- Zero newly wrong coarse automatic base-language labels against either control;
  unknown language evidence cannot pass or establish switch/fallback behavior.
- At least 65% observed model-file saving versus its original F16. This is
  compression, not credit for an additional rotation-only size improvement.
- Rotated F16 must match original canonical hypothesis hashes and automatic labels
  in all three numerical-panel repeats. Do not relax this after observing results.

Use the unchanged explicit legacy-v1 scoring version: counted corpus errors/units
per language, equal nine-language CER/eight-language WER means; omit Chinese
whitespace WER. Missing planned coverage keeps full rates/macros/gates unknown,
with observed partial counts separate. A known failed gate rejects even when
other gates are unknown. Numerical/quality success alone does not promote a default.

## Operating envelope and validation

Research stays serial at nice -n 10 with capture taking priority. Reuse the
inspected capture/uncertainty/heavy-job guard: a fresh native RecScribe idle/live-off
check admits the fixed inference campaign, with per-stage process/file probes.
No active capture or foreign app is interrupted. Keep the prospective finite
3,600-second non-held/10,800-second held bounds, 60-second supervisor grace and
one-second guard polling; retain the existing extreme-contention CPU policy
explicitly. Cancellation/owned-session reaping and bounded buffers are mandatory.
Descriptor polling has a capture-intent race; it is not a real-time scheduling proof.

Model edits/exports have finite 600-second limits and bounded memory/output;
reserve at least 10 GiB protected external space for successful and failed
artifacts. Temporary tests/logs use work-artifacts.py and existing build caches.
Original audio/transcripts, corpus inputs, frozen captures, model originals and
installed-app backups remain outside disposable retention. Do not install or
replace the signed app for this research experiment.

Before inference: synthetic masked multi-head algebra with unequal query/key
lengths, nonzero biases and nonsymmetric signed rotations; wrong-transpose and
missing-compensation negative tests; byte/layout/source/cancellation ownership
contracts; actual Q4 export/static/native-load checks; real packaged assessor and
terminal/failure-accounting write smokes. Run mandatory native/frozen checks and
complete-PR full CI. Never rebaseline fixtures merely to pass.

Report all per-language rates/counts, uncertainty, upstream load timers, wall
latency, throughput/RTF, process RSS and actual file sizes. Keep their observation
counts distinct. Record hardware/software, flags, VAD, language policy, hashes
and scoring versions. Shared-desktop resource observations are uncontrolled;
first-result/full initialization, unified GPU memory, energy and actual bundle
increments remain unmeasured unless separately executed. Native/v2/product and
controlled resource acceptance stay pending. No automatic merge or promotion.
