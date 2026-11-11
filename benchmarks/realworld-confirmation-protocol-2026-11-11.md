# Fresh real-world confirmation and external comparisons

This prospective phase follows the [frozen read-speech pilot](quantized-quality-results-2026-11-11.md).
It changes no installed model or default and performs no training. Model uploads
and merges require a separate instruction. Earlier successes, cancellations,
failures, incomplete budgets, original audio/references and frozen branches stay
retained. A new reference, repeat or execution window never repairs an old first
outcome.

## Fixed comparison tracks

1. **Same-runtime compression:** retain the exact full Large-v3 F16 parent
   (`64d182b4…`) and Q4_0 (`e002bafb…`). Add stock upstream Q5_0 as a separate
   fixed comparator: `ggerganov/whisper.cpp@5359861c739e955e79d9a303bcbc70fb988958b1`,
   1,081,140,203 bytes, SHA-256
   `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1`.
   Its upstream F16 is byte-identical to our existing parent. Repository hosting
   alone therefore establishes no quality difference.
2. **External architecture:** evaluate
   `mlx-community/Qwen3-ASR-1.7B-8bit@a8379a2e2f9e313c9292cdf1af4055ab56d50d55`
   separately, using pinned MLX-Audio source and an explicit local-only adapter.
   Its weight file is 2,463,307,541 bytes, SHA-256
   `bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c`.
   Model format, backend, precision and application/component timing boundaries
   differ; they must remain visible in every comparison. The publisher declares
   all eight non-Swiss target languages. Swiss rendering remains unvalidated.
   Its weight file is only 20.41% smaller than Large-v3 F16, before other assets
   and runtime dependencies, so file size alone does not meet the 30% gate.
   This track tests whether a different architecture supplies a substantial
   accuracy or measured runtime improvement.
3. **Screened follow-up:** TheStageAI's Whisper Turbo is a promising
   Whisper-derived checkpoint on the external leaderboard. Its public architecture
   appears convertible, but conversion/loading and Chinese coverage are not
   established. No leaderboard score is adopted as a local measurement.

All selected artifacts/settings advance regardless of development direction.
No held-out outcome chooses a quantization, prompt, reference correction, language
oracle or acceptance margin. External checkpoints may have been trained by their
publishers; this work trains no model and edits no weight values directly.

The inspected [Open ASR leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)
was revision `9b886ea495f5fe2c35cfa0376b5c25d003cf3b0b`, version 1.15.1.
Its main table is English short-form; its multilingual table covers only a subset
of our languages and omits Arabic, Chinese and Swiss. Its normalization differs
from our frozen lexical scorer. Rankings screen candidates; our audio, runtime
and scoring determine our results.

## Fresh source and reference plan

The target is two development and sixteen held-out source units per language,
plus a separate reference-free resource case. Metadata selection excludes 1,559
prior case records, including the consumed pilot and prepared video cases, by
source/audio/reference hashes and known speaker/session/parent groups. Actual
coverage, unknown identity, source-use review and failures remain explicit.

Planned sources:

| Coverage | Pinned source | Scope and unresolved review |
| --- | --- | --- |
| de/en/es/fr/it | `facebook/voxpopuli@42f01879c780b4a2e90ec0b4f616c2ece526e4f1` | Parliamentary source audio with published gold flags and speaker IDs; sentinel labels stay unknown. Prepared speeches do not prove spontaneous-conversation coverage. |
| ar | `UBC-NLP/Casablanca@8951b1b88e28c1107142ced57967b8d16350951d` | Egyptian development/test partitions, published human references; dialect/speaker/source-use review pending. Previously viewed Algeria validation is excluded from blind selection. |
| zh | `AISHELL/AISHELL-4@aada72727856313b19d4a030383c426364931dbf` | Original multichannel meetings and human TextGrids; explicitly select one channel and a whole non-overlapping annotation. Preserve local speaker labels without inventing global identity. |
| pt | `gabrielrstan/CORAA-v1.1@719c91226a79f5f9a8984145f15f29626eabc29a` | Human-validated pt-BR spontaneous recordings. Select distinct original recording suffixes, with eight held-out clips having publisher noise/low-voice votes and eight without. Actual audibility and identity remain unreviewed. |
| de-CH | `i4ds/SPC_test@48c389fb6b88c8e80f03273a677a422729183e06`, verified against original SPC v2 | All 3,332 clip paths, publisher speaker IDs and opaque reference SHA-256 values match the official manifest. Bern parliamentary speech targets written Standard German; 26 publisher speaker IDs, unknown sessions and independent native review remain explicit. |

The official SPC v2 README and test manifest are preserved and hashed. Their
Common Voice style columns describe the format, not read-speech provenance.
The initially ambiguous mirror correspondence was resolved by exact metadata
and reference-hash comparison before any audio inference. This covers Bern;
it does not demonstrate all Swiss regional varieties.

Original source terms and card bytes are retained separately. VoxPopuli's data
declaration is CC0. Original AISHELL terms say CC BY-SA 4.0 while the mirror's
metadata says Apache 2.0; record this discrepancy. Casablanca and CORAA declare
CC BY-NC-ND 4.0. Source-use review remains pending; this protocol approves no
redistribution or commercial/product eligibility.

Original compressed audio and raw annotation/caption/CSV bytes are retained.
Prepared PCM, aligned references and interval/channel mappings are separate
versioned artifacts. Metadata, durations and known groups drive selection;
candidate hypotheses never create or correct their own reference. No held-out
reference words are semantically inspected before the candidate/settings freeze.

The Parquet reader uses pinned HTTP ranges, bounded sparse disk transport and
native memory mapping with one-row batches. It caps network/output/time, row
metadata, individual reads, temporary physical disk allocation, materialized
batches and source-rowgroup sizes, and records observed Arrow allocation/RSS.
A real German structural probe still exceeded the fixed 128 MiB Arrow limit:
memory mapping did not prevent whole binary-page allocation. That failure stays
retained; it does not establish prepared VoxPopuli audio or a passed memory bound.
Other sources and a bounded alternative acquisition route progress separately.
A batch bound is not a guarantee about every transient native decoder allocation.
Unverified source/region/script/speaker/session and independent native review
stay pending. Published references permit an exploratory legacy lexical report,
not native-v2 or critical-content approval.

After source-decoding failures, a separate engineering revision is being prepared
before any ASR: isolated VoxPopuli workers allow an observed Arrow pool of 2 GiB
and process RSS of 3 GiB; isolated Arabic workers allow 256 MiB / 512 MiB. The
128 MiB materialized-batch limit and existing source, transport, disk, network
and time limits remain. A bounded parent watchdog checks the exact owned worker
and cancels on excessive RSS or uncertain probes. Sampling cannot guarantee the
absence of shorter transient spikes. The original failures remain failed; this
changes no quality threshold or inference retry rule.

The nine retained Arabic originals checked so far have nonidentical stereo
channels. They cannot be silently mixed or assigned a channel-specific reference.
Arabic quality therefore remains pending channel/reference proof or a suitable
source. A separate reference-free resource case may explicitly select channel
zero while retaining the whole stereo original and channel mapping; that case
provides no independent-channel or lexical-quality approval.

## Controlled resource panel

Use the retained transcription CLI (`b082ca6d…`), separately identified coordinator
(`b6670501…`), matched `{"schema_version":"1.0"}` profile, `-tp 0 -mc 0`,
inherited decoding/fallback, two threads, final path and no added VAD. Model,
source, native dependency, profile and expected native runtime identities are
SHA-bound before execution. A native dry grid establishes expected effective
settings without model inference.

Two models use four balanced rounds, AB / BA / BA / AB, reversing orientation
for alternating case/mode blocks. A three-model panel uses all six permutations.
Case IDs and native repeat 1 remain intact; external block/round IDs describe
repetition. No repeated clip is counted as a new independent speaker. Nine
resource cases and both language policies imply 144 calls for two models or
324 for three. Missing cases/pairs remain missing; the executed grid and its
coverage are reported without reducing the prospective requirement.

This measures **warm-filesystem, fresh-process application-job latency**,
including provenance hashing, preparation, load, decoding and rendering.
Fresh processes are not labelled cold-cache. Compare paired per-source round
wall times/RTF, upstream timers and maximum process RSS, with complete counts
and variation. First-result latency, complete initialization and total unified
GPU allocation remain unmeasured unless an actual instrument observes them.
An optional MLX allocator peak describes that allocator's subset, not whole GPU
or system memory.

The prospective same-runtime panel includes all three frozen Whisper artifacts,
giving 324 planned calls. One English resource case supplies a separate warm-up
for each artifact. The external Qwen comparison uses temperature zero, batch one,
60-second chunks, no system prompt/hotwords and a 1,024-token ceiling; the complete
local model/runtime inventories and published tokenizer assets are hash-bound.
Compatibility remains pending until guarded initialization. Truncated outputs
remain visible and scored, rather than being regenerated with a larger limit.

Before model initialization, inspect the exact running RecScribe app: recording
idle and live transcription off. Retain observed quiet-workload, stable power,
thermal and memory-pressure evidence. Use the existing serial nice-10 guard,
50% foreign-process CPU policy and cancellation for recording, builds/tests,
ASR, VMs and uncertain probes. CPU quiet does not prove GPU isolation; the
observed dimensions and unmeasured GPU factors remain explicit. Acquisition-only
1000% guards never qualify a resource comparison.

Every run has a fixed absolute deadline and at most 3,600 seconds, with a bounded
per-block budget. Running state precedes launch. The frozen absolute one-use
claim prevents copying a plan to restart it. Cancellation reaches the active
native output and only verified owned processes. No failed/cancelled/uncertain
attempt is retried to complete a pair. Continued execution windows cannot be
declared a controlled resource pass.

## Quality and acceptance

Keep `swift-nfc-casefold-alphanumeric-v1` and the previous macro/per-language
margins: primary CER +0.5pp, primary WER +1pp; language CER +1pp and WER +2pp.
The primary CER macro equally weights the eight non-Swiss languages. The WER
macro equally weights the other seven, excluding Chinese; Swiss has a separate
floor. Require all sixteen paired source units for every language. Incomplete
acquisition or results never reduce the planned language denominator.
Source grouping/dependence and unreviewed references limit the report to
exploratory lexical evidence. Critical content, switches, independent channels,
long/live operation, broader scripts/regions and independent Swiss native review
remain separate pending gates.

Qwen hypotheses use the unchanged native scorer through a bounded standalone
bridge, with source/compiler/binary hashes retained. They never masquerade as
Whisper engine passes or inherit external leaderboard numbers. All raw outputs,
failed attempts and unexecuted checks stay visible. No size, lexical or resource
result alone promotes a downloadable or bundled default.
