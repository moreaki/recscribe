# Bounded recording-priority benchmark guard

`scripts/quality/run-guard.py` is an offline worker supervisor, extracted with its
tested source bytes from the archived research branch. It launches one explicit
command without a shell, at nice 10 in a new owned session. Its timeout is bounded
to 1–3,600 seconds, with bounded probes and cleanup grace periods.

Before model initialization or ASR, inspect the exact running RecScribe app and
confirm recording is idle and live transcription is off. This polling guard is
not proof of native idle state, a real-time recording scheduler, or permission
to interrupt capture. Do not start a benchmark during recording or an audio test.

Use the managed wrapper for command logs and a new protected external directory
for actual benchmark output. The output parent must exist; the worker output
directory and guard JSONL must both be new. Exactly one worker `--output` argument
must match the guard's output path.

```sh
python3 scripts/work-artifacts.py run --label guarded-matrix benchmark -- \
  python3 scripts/quality/run-guard.py \
  --output /protected/new-matrix --log /protected/new-matrix.guard.jsonl \
  --timeout 1800 -- \
  /absolute/path/to/recscribe-text benchmark /protected/corpus.json \
  --experiment /protected/experiment.json --output /protected/new-matrix
```

The guard defers or cancels its worker on observed RecScribe audio writes,
competing build/test/ASR processes, VMs or the declared foreign-process CPU
threshold. Probe uncertainty fails closed. CPU observations do not establish GPU
idle state or controlled resource conditions. The guard never stops a foreign
process, VM or recording application.

SIGINT/SIGTERM/SIGHUP, a timeout, a competing-work observation or a guard exception
requests cancellation, then performs bounded shutdown/reaping of verified owned
session groups. Cleanup uncertainty fails the operation. It retains structured
start/stop/reason evidence, partial output and cancellation evidence; it does not
retry measured inference or turn a cancellation into a successful benchmark.

The offline tests mock process/file probes and owned launches. They protect
fail-closed classification and cancellation-during-launch behavior without
accessing microphones, models or the user's recording process. Historical runs
retain their separately frozen supervisors and limits; this extraction does not
change the source identity or acceptance of an earlier experiment.
