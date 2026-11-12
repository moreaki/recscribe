# No-retraining experiment contract

Use the existing `recscribe-text benchmark` command for single runs or a serial
matrix. No original weights, audio, manifests or raw transcripts are modified.
The corpus/scoring contract is [corpus-contract.md](corpus-contract.md).

## Reproduce the untouched control

The retained control is commit `c214a8ed03f972a5a9cab64105145a67371b97b4`, also
referenced by `codex/whisper-quality-untouched-control`. Build its native CLI from
that exact revision with the recorded Xcode/Swift version and existing SwiftPM
cache. Store the binary under `Build/Products`, record its SHA-256 in the external
experiment's `baseline_cli_sha256`, and retain its build record. A declaration of
a revision alone does not authenticate a binary; reports identify that limit.
The current runner drives that binary's unchanged `transcribe` command and scores
its preserved canonical outputs with the selected versioned scoring policy.

Retain the complete SwiftPM product: copy its generated runtime resource bundle
alongside the executable under `Build/Products`, and hash those resources in the
build receipt. For the macOS Swift build system this includes
`RecScribeCore_RecScribeCore.bundle`; other SwiftPM build systems may use a
`.resources` directory. Verify the schema bytes against that source revision and
run the frozen renderer fixture with the staged executable before inference.
Successful compilation or an executable hash alone does not establish that a
copied CLI has all its required resources. Preserve incomplete staging attempts
and their failed raw jobs when correcting packaging.

The control arguments remain `-tp 0 -mc 0`, without added search, fallback or VAD
overrides. Upstream defaults are version-specific: this is not a claim of greedy
search or disabled temperature fallback. The final pipeline skips exact digital
silence and preserves independent source channels. Silence outcomes therefore
measure pipeline behavior, not raw-model hallucinations. Use nonzero noise and
quiet speech for detector comparisons.

## Prepare and inspect a matrix

Copy `manifests/experiment.template.json` to the protected external benchmark
location. Fill only verified local paths, model checkpoint/precision and SHA-256.
Full large-v3 and large-v3-turbo are separate multilingual controls. No model is
downloaded automatically. Keep all nine language slices and both `known`/`auto`
controls. Code-switch and non-speech cases cannot have a single known-language
control; their rows stay explicitly unsupported. Swiss speech → written Standard
German is the primary Swiss output task (`standard_rendering`) and is scored
directly against reviewed written-German references. Optional dialect spelling
remains a separate task; no automatic LLM cleanup stage is implied.

```sh
python3 scripts/work-artifacts.py run --label issue-105-readiness benchmark -- \
  core/.build/debug/recscribe-text benchmark benchmarks/manifests/corpus.template.json \
  --experiment /path/to/private-experiment.json --dry-run \
  --output "$HOME/Library/Application Support/RecScribe/Benchmarks/NEW-READINESS"
```

An output directory must be new. Results are protected evidence outside the
checkout/disposable root, including exact source manifests/configuration, private
profile bytes, host evidence, raw ASR, canonical transcripts, subprocess logs and
timing files. Managed wrappers capture disposable command logs only. The matrix
is bounded to 20,000 cells, 1–10 repeats and 1–4 threads. One ASR job runs at a
time. Every cell records missing prerequisites; pending never means zero error.

A prospectively declared quality-only matrix may request one repeat to spend
its compute budget on more independent source recordings. It measures no repeat
variability. Keep at least three repeats in a separately fixed timing/stability
panel; its repeated outputs do not enlarge the quality sample. The template and
historical three-repeat experiments remain unchanged. Successful repeat 1 alone
supplies quality, with no fallback to a later successful repeat.
Checksums fail visibly. No retries beyond the existing recognizer policy are
added. `cancel.request` in the matrix directory or Ctrl-C propagates cancellation
to the active canonical job; previous and partial evidence remains available.

Measured execution requires a fresh `capture_inactive: true` attestation and a
nonempty `workload_attestation` after checking the actual app. Never stop capture
to benchmark. Stop a benchmark if recording needs resources; inference and scoring
are bounded and cancellable. User assertions are recorded, not proof of continued
idle status. Runtime comparisons also need stable power/thermal conditions and no
competing heavy workload.

## Reuse verified static host evidence

For guarded microblocks, capture static hardware and toolchain evidence once
with the candidate coordinator:

```sh
python3 scripts/work-artifacts.py run --label issue-105-host-evidence benchmark -- \
  python3 scripts/quality/run-guard.py \
  --output /absolute/protected/research/NEW-HOST-EVIDENCE \
  --log /absolute/protected/research/NEW-HOST-EVIDENCE.guard.jsonl --timeout 120 -- \
  /absolute/path/to/recscribe-text capture-benchmark-host \
  --output /absolute/protected/research/NEW-HOST-EVIDENCE
```

This bounded, cancellable command runs no recognition or model initialization.
It retains the fixed commands, raw output, exit evidence and hashes in a new
directory, then returns the `path`, `sha256` and `bytes` of `snapshot.json`.
Failed or cancelled captures retain their evidence without publishing a usable
snapshot. Existing directories are never overwritten.

Set the experiment's optional `host_evidence_snapshot` to the returned identity:

```json
"host_evidence_snapshot": {
  "path": "/absolute/protected/research/NEW-HOST-EVIDENCE/snapshot.json",
  "sha256": "<returned SHA-256>"
}
```

The runner verifies the snapshot and its raw-file hashes, schema, bounds and
same-machine fingerprint before model work. The snapshot must match the current
OS, architecture, CPU, memory and hashed machine identity (`gethostuuid`). Each
block still records fresh thermal and power-source observations and binds the snapshot identity in its
matrix. Static evidence is labelled with its capture time; ASR wall/RSS timing
keeps its existing scope. Without this option, the existing discovery path
remains in use. Recording-priority admission and continuous cancellation remain
required on both paths. Cached mode rejects failed or empty fresh power evidence.

## Experimental profiles and isolated comparisons

A `candidate` profile names a private JSON settings file and exact declared source
revision. The runner snapshots that file and forwards `--whisper-profile` only to
candidate invocations; baseline binaries never receive new options. Each setting
must be validated against actual runtime capabilities. Use one intervention at a
time on development data, then a combined profile after isolated comparisons.
Existing installed app preferences remain unchanged and select the control.

Models and runtime profiles are separate axes. A derived model declares `kind`
(`weight_edit`, `compression`, `conversion_control` or `combined`), its immutable
`baseline_model_id` and `baseline_model_sha256`, a safe `intervention_id`, its own
artifact hash, and explicit `profiles`. Derived models cannot run a profile of
kind `baseline`: that label is reserved for unchanged artifacts through the
retained control CLI. An optional model `download_artifact` points to an actual
local distribution file, with optional `download_artifact_sha256`; its measured
bytes are kept separate from the model's installed bytes.

An explicit `comparisons` entry names `id`, `intervention`,
`baseline_model_id`, `candidate_model_id`, `baseline_profile_id` and
`candidate_profile_id`. An isolated model comparison uses one shared profile of
kind `candidate` for both parent and edited model, preserving the same current
CLI, settings, Whisper binary and preparation. That shared profile may contain
only `{"schema_version":"1.0"}` to select unchanged decoding settings. A
runtime-only comparison uses the same artifact on both sides. Combined changes
are identified separately. Invalid/recursive lineage, mismatched parent hashes
and unassociated profiles fail before inference.

`final` uses the real native preprocessing/AudioJob/adapter. Source-channel human
references are scored against only that canonical channel, with channel identity
retained. A mixed reference must explicitly describe its interleaved contract.
`live-replay` rows currently remain `unsupported_live_replay`: the app's real
LiveAudioReader/controller cannot be substituted with a generic file splitter and
called equivalent. No live backlog, delay or live quality claim is produced by
this harness until that adapter is integrated and verified.

Reports retain sample counts, edit counts and denominators; language/condition,
output task, scorer and configuration groups stay separate. Macro averages and
corpus-weighted rates are distinct. Repeats report median/range and distinct text
hashes. Paired deltas require identical source/reference/scorer/task/channel,
language mode, input path, thread/preparation identity and repeat. Runtime-only
pairs require the same model hash; model-edit pairs retain both distinct artifact
hashes and verify the declared untouched parent plus identical runtime settings.
Failure/pending cells remain unpaired.
Three repeats assess variability; they do not establish independent corpus size.
Quality aggregation uses successful repeat 1 only, with no replacement by a later
successful repeat. Failed or missing first-repeat cells remain missing quality
evidence. Timing/variation summaries retain all requested repeats separately.
Critical-content and language-ID confusion require annotated human ground truth
and remain unmeasured when unavailable. A `de` recognizer guess does not identify
Swiss dialect or establish dialect wording fidelity.

Wall time includes inspection/model load/inference/validation/rendering. Engine
passes retain their own elapsed times and exact commands/backend logs. Fresh
processes do not establish cold disk caches or resident-worker performance.
macOS `time -l` maximum RSS is not total unified CPU/GPU allocation. The versioned
`whisper-cpp-print-timings-v1` parser retains individual upstream load, mel,
sample, encode, decode, batchd, prompt and total timers from private logs. The
model-load timer is not total process initialization; overlapping timers are not
summed/subtracted. End-to-end audio-seconds-per-second is labeled as pipeline
throughput. First-token/result latency and total unified GPU allocation remain
unobserved when unavailable. Actual file/download sizes are measured separately;
incremental bundle bytes stay null until a candidate app bundle is assembled.

Use `scripts/quality/report-pilot.py /protected/matrix --output /protected/NEW-report`
to summarize retained metrics without recognition, rescoring or reading reference/
hypothesis text. The reporter verifies the matrix's retained corpus/configuration
snapshot hashes, preserves per-language/task/model/profile/mode/scorer cohorts,
reports unique first-repeat denominators, suppresses Chinese whitespace WER, and
leaves incomplete workload timing unaggregated. JSON retains measured sizes,
upstream timer scope, process-RSS limits, repeat variation and evidence pointers.
Old paired rows without complete identity fields are explicitly unavailable for
aggregation. A held-out report additionally requires explicit `--allow-held-out`
and verified retained freeze evidence. This does not replace human content review.

## Freeze and held-out evaluation

Do not select settings or budgets without development baselines. Before opening
held-out outcomes, retain a freeze JSON with `schema_version: "1.0"`, SHA-256s in
`corpus_sha256` and `experiment_sha256`, `profiles` mapping candidate IDs to exact
profile hashes, a nonempty `budgets` object, and
`frozen_before_held_out: true` as the operator's chronology and hash-lock
attestation. Record whether the actor is AI or human and explicitly retain the
native critical-content review and v2 corpus approval statuses. An automated
exploratory legacy research seal may preserve `reviewed: false` and unknown
speaker/session grouping; it does not approve v2 eligibility, representative
coverage or product/default promotion gates. The corpus must be `frozen: true`;
validate hashes and all known speaker/session/source separation, and identify
unknown grouping explicitly rather than reporting it as passed. Approved-v2
eligibility requirements remain enforced. The experiment must select `held_out`
and reference that freeze file.
The experiment hash binds model identities, decoding, language modes, input paths
and repeat budgets; altered settings fail. Candidate bytes are retained in output.

Budget review must predeclare per-language/model WER/CER and quiet-speech deletion
limits, critical names/numbers/negation/omission/invented-speech tolerances,
latency/backlog and memory limits, minimum eligible speaker/session/sample counts,
and a rollback decision. The harness enforces the hash lock, not the scientific
adequacy of human budgets. No aggregate average alone promotes defaults. Without
eligible data, isolated evaluations, candidate selection/freeze and combined
held-out evaluation remain pending. Do not fabricate a frozen winner.
