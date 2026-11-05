# No-retraining experiment contract

Use the existing `recscribe-text benchmark` command for single runs or a serial
matrix. No weights, original audio, manifests or raw transcripts are modified.
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
is bounded to 20,000 cells, 3–10 repeats and 1–4 threads. One ASR job runs at a
time. Every cell records missing prerequisites; pending never means zero error.
Checksums fail visibly. No retries beyond the existing recognizer policy are
added. `cancel.request` in the matrix directory or Ctrl-C propagates cancellation
to the active canonical job; previous and partial evidence remains available.

Measured execution requires a fresh `capture_inactive: true` attestation and a
nonempty `workload_attestation` after checking the actual app. Never stop capture
to benchmark. Stop a benchmark if recording needs resources; inference and scoring
are bounded and cancellable. User assertions are recorded, not proof of continued
idle status. Runtime comparisons also need stable power/thermal conditions and no
competing heavy workload.

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
`frozen_before_held_out: true` as the human review attestation. The corpus must be
`frozen: true`; hashes and speaker/session/source separation are validated. The
experiment must select `held_out` and reference that freeze file. The experiment
hash binds model identities, decoding, language modes, input paths and repeat
budgets; altered settings fail. Candidate bytes are retained in output.

Budget review must predeclare per-language/model WER/CER and quiet-speech deletion
limits, critical names/numbers/negation/omission/invented-speech tolerances,
latency/backlog and memory limits, minimum eligible speaker/session/sample counts,
and a rollback decision. The harness enforces the hash lock, not the scientific
adequacy of human budgets. No aggregate average alone promotes defaults. Without
eligible data, isolated evaluations, candidate selection/freeze and combined
held-out evaluation remain pending. Do not fabricate a frozen winner.
