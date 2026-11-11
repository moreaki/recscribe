#!/usr/bin/env python3
"""Plan, run and collect a bounded, balanced, resource-only native Whisper panel.

Use work-artifacts.py for command logs and NEW protected external directories.
The measured run must be supervised by run-guard.py in its own owned session.
This controller never reads reference/hypothesis words or grants quality approval.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys
import time

VERSION = "controlled-resource-panel-v1"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_OUTPUT_BYTES = 512 * 1024 * 1024
MAX_INPUT_BYTES = 8 * 1024 * 1024 * 1024
MAX_CASES = 24
MAX_CALLS = 1000
STATUS_COMPLETE = {"completed", "completed_with_review"}
REPO = Path(__file__).resolve().parents[2]
ROW_KEYS = ("model", "profile", "id", "language_mode", "path", "repeat")
ROW_IDENTITIES = ("id", "language", "task", "source_channel", "model", "model_sha256", "model_kind",
                  "baseline_model_id", "baseline_model_sha256", "intervention_id", "precision", "checkpoint",
                  "profile", "profile_kind", "profile_sha256", "effective_profile_sha256", "vad_model_sha256",
                  "runtime_settings_sha256", "whisper_binary_sha256", "transcription_runner_sha256", "threads",
                  "preparation_policy", "baseline_runner_sha256", "source_revision", "language_mode", "path",
                  "repeat", "source_sha256", "reference_sha256", "measurement_scope", "scoring_policy")


def utcnow():
    return datetime.now(timezone.utc)


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Use an explicit timezone-aware ISO timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Timestamps must include a timezone")
    return result.astimezone(timezone.utc)


def bounded(value, lower, upper, label):
    if type(value) not in (int, float) or not math.isfinite(value) or not lower <= value <= upper:
        raise ValueError(f"{label} must be finite and in {lower}..{upper}")
    return value


def digest(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("Explicit lowercase SHA-256 required")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))


def raw_json(path, expected=None):
    path = Path(path)
    with path.open("rb") as stream:
        raw = stream.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError("JSON exceeds the 4 MiB metadata bound")
    if expected is not None and hashlib.sha256(raw).hexdigest() != digest(expected):
        raise ValueError("JSON differs from its explicit SHA-256: " + str(path))
    return raw, decode(raw)


def encoded(value):
    raw = (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError("Generated metadata exceeds 4 MiB")
    return raw


def write_new(path, raw):
    with Path(path).open("xb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def save(path, value):
    # Only the newly owned run's state is replaceable; inputs/snapshots are not.
    raw = encoded(value)
    temporary = path.with_name(path.name + ".next")
    with temporary.open("wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def absolute(value, relative_to=None):
    if not isinstance(value, str) or not value:
        raise ValueError("Nonempty input path required")
    path = Path(value).expanduser()
    if not path.is_absolute():
        if relative_to is None:
            raise ValueError("Use absolute input paths")
        path = relative_to / path
    return path.resolve(strict=True)


def new_output(value):
    path = Path(value).expanduser()
    if not path.is_absolute() or ".." in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Use a new absolute protected non-symlink output")
    if path == REPO or REPO in path.parents or not path.parent.is_dir():
        raise ValueError("Persistent results require an existing parent outside the checkout")
    path.mkdir(mode=0o700, exist_ok=False)
    return path


def hash_file(path, check=lambda: None):
    check()
    path = Path(path)
    with path.open("rb") as stream:
        before = os.fstat(stream.fileno())
        if not 0 <= before.st_size <= MAX_INPUT_BYTES:
            raise ValueError("Input exceeds the 8 GiB file bound")
        result = hashlib.sha256()
        while True:
            check()
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            result.update(chunk)
        after = os.fstat(stream.fileno())
    current = path.stat()
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
    if identity(before) != identity(after) or identity(before) != identity(current):
        raise ValueError("Input changed while hashing")
    return result.hexdigest(), before.st_size


def lock(role, path, expected=None, check=lambda: None):
    path = absolute(str(path))
    actual, size = hash_file(path, check)
    if expected is not None and actual != digest(expected):
        raise ValueError("Input checksum mismatch: " + role)
    return dict(role=role, path=str(path), sha256=actual, bytes=size)


def verify_lock(item, check=lambda: None):
    actual, size = hash_file(item["path"], check)
    if actual != item["sha256"] or size != item["bytes"]:
        raise ValueError("Frozen input changed: " + item["role"])


def permutations(models):
    if len(models) == 2:
        a, b = models
        return [[a, b], [b, a], [b, a], [a, b]]
    if len(models) == 3:
        return [list(value) for value in itertools.permutations(models)]
    raise ValueError("Choose exactly two or three distinct models")


def row_key(row):
    return tuple(row.get(key) for key in ROW_KEYS)


def expected_rows(matrix, identities, template, cases, models, profile_sha):
    """Trust native serialization from an exact SHA-bound unmeasured dry grid."""
    desired = dict(schema_version="1.0", dry_run=True, serial_jobs=True,
                   configuration_sha256=identities["experiment"]["sha256"],
                   corpus_sha256=identities["corpus"]["sha256"],
                   runner_sha256=identities["transcriber"]["sha256"],
                   coordinator_sha256=identities["coordinator"]["sha256"],
                   whisper_binary_sha256=identities["whisper"]["sha256"],
                   measurement_scope="resources_only", split="development", threads=template["threads"])
    if any(matrix.get(key) != value for key, value in desired.items()):
        raise ValueError("Expected native matrix does not bind the exact dry-run inputs/runtime")
    if matrix.get("dry_run") is not True or matrix.get("serial_jobs") is not True:
        raise ValueError("Expected native matrix must be an unmeasured serial dry run")
    profile = template["profiles"][0]
    if matrix.get("profile_sha256") != {profile["id"]: profile_sha}:
        raise ValueError("Expected native profile hash differs from the supplied settings")
    planned = {(model, profile["id"], case["id"], mode, "final", 1)
               for model in models for case in cases for mode in template["language_modes"]}
    rows, seen = matrix.get("rows"), {}
    if not isinstance(rows, list) or len(rows) != len(planned):
        raise ValueError("Expected native dry grid must contain every exact planned cell once")
    by_case = {case["id"]: case for case in cases}
    for row in rows:
        if not isinstance(row, dict) or row_key(row) not in planned or row_key(row) in seen:
            raise ValueError("Duplicate or unexpected native dry-grid cell")
        if row.get("status") != "ready" or row.get("measurement") is not None or row.get("evidence_directory") is not None or row.get("engine_identity_observations") is not None:
            raise ValueError("Expected native matrix must be ready and never measured")
        case, model = by_case[row["id"]], models[row["model"]]
        fixed = dict(language=case.get("language"), task=case.get("task"), source_channel=case.get("source_channel"),
                     source_sha256=case["sha256"], model_sha256=model["sha256"], profile_sha256=profile_sha,
                     model_kind=model.get("kind", "pretrained"),
                     baseline_model_id=model.get("baseline_model_id") if model.get("kind", "pretrained") != "pretrained" else model["id"],
                     baseline_model_sha256=model.get("baseline_model_sha256") if model.get("kind", "pretrained") != "pretrained" else model["sha256"],
                     intervention_id=model.get("intervention_id") if model.get("kind", "pretrained") != "pretrained" else None,
                     precision=model.get("precision"), checkpoint=model.get("checkpoint"),
                     profile_kind=profile["kind"], source_revision=profile.get("source_revision"),
                     transcription_runner_sha256=identities["transcriber"]["sha256"],
                     whisper_binary_sha256=identities["whisper"]["sha256"], threads=template["threads"],
                     measurement_scope="resources_only", scoring_policy="unscored-resources-v1", reference_sha256=None)
        if any(row.get(key) != value for key, value in fixed.items()):
            raise ValueError("Native dry-grid row contradicts its source/model/profile/runtime")
        if row.get("gaps") not in (None, []) or row.get("errors") not in (None, []):
            raise ValueError("Native dry grid contains readiness gaps or failures")
        digest(row.get("runtime_settings_sha256"))
        digest(row.get("effective_profile_sha256"))
        if row["runtime_settings_sha256"] != row["effective_profile_sha256"]:
            raise ValueError("Native dry grid has inconsistent effective profile identity")
        seen[row_key(row)] = row
    return rows


def engine_observations(value, expected):
    """Mirror the native recursive effective binary/model/profile identity check."""
    count = 0
    if isinstance(value, dict):
        if "binary_sha256" in value:
            decoding = value.get("decoding")
            if (value.get("binary_sha256") != expected["whisper_binary_sha256"]
                    or value.get("model_sha256") != expected["model_sha256"]
                    or not isinstance(decoding, dict)
                    or decoding.get("profile_sha256") != expected["effective_profile_sha256"]
                    or value.get("vad_model_sha256") != expected.get("vad_model_sha256")):
                raise ValueError("Effective engine binary/model/VAD/profile identity differs")
            count += 1
        for child in value.values():
            count += engine_observations(child, expected)
    elif isinstance(value, list):
        for child in value:
            count += engine_observations(child, expected)
    return count


def make_plan(spec_path, output):
    planning_deadline = time.monotonic() + 300

    def planning_check():
        if time.monotonic() >= planning_deadline:
            raise TimeoutError("Plan preparation exceeded 300 seconds")

    def bounded_lock(role, path, expected=None):
        return lock(role, path, expected, planning_check)

    spec_path = absolute(str(spec_path))
    spec_raw, spec = raw_json(spec_path)
    if spec.get("schema_version") != "controlled-panel-spec-v1":
        raise ValueError("Unsupported resource panel specification")
    max_seconds = bounded(spec.get("max_seconds"), 1, 3600, "Total seconds")
    block_seconds = bounded(spec.get("block_timeout_seconds"), 1, 600, "Block seconds")
    deadline = timestamp(spec.get("deadline_utc"))
    if deadline <= utcnow():
        raise ValueError("The fixed deadline is already expired")
    models = spec.get("model_ids")
    if not isinstance(models, list) or any(not isinstance(m, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", m) for m in models) or len(set(models)) != len(models):
        raise ValueError("Unique safe model IDs required")
    orders = permutations(models)
    modes = spec.get("language_modes")
    if not isinstance(modes, list) or not modes or len(set(modes)) != len(modes) or not set(modes) <= {"known", "auto"}:
        raise ValueError("Declare distinct known/auto modes")
    identities = {}
    for role in ("corpus", "experiment", "coordinator", "transcriber", "whisper", "expected_native_matrix"):
        identity = spec.get(role)
        if not isinstance(identity, dict):
            raise ValueError("Missing explicit input identity: " + role)
        identities[role] = bounded_lock(role, identity.get("path"), identity.get("sha256"))
        digest(identity.get("sha256"))
    for role in ("coordinator", "transcriber", "whisper"):
        if not os.access(identities[role]["path"], os.X_OK):
            raise ValueError("Native executables must already exist")
    corpus_raw, corpus = raw_json(identities["corpus"]["path"], identities["corpus"]["sha256"])
    config_raw, template = raw_json(identities["experiment"]["path"], identities["experiment"]["sha256"])
    cases = corpus.get("cases")
    if not isinstance(cases, list) or not 1 <= len(cases) <= MAX_CASES:
        raise ValueError("Declare 1–24 resource cases")
    if any(not isinstance(c, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", c.get("id", "")) for c in cases) or len({c["id"] for c in cases}) != len(cases):
        raise ValueError("Unique safe case IDs required")
    if len({c.get("sha256") for c in cases}) != len(cases):
        raise ValueError("Do not alias one exact audio input under multiple source case IDs")
    if len(cases) * len(modes) * len(orders) * len(models) > MAX_CALLS:
        raise ValueError("Panel exceeds 1000 native invocations")
    profiles = template.get("profiles", [])
    if (template.get("schema_version") != "1.0" or template.get("measurement_scope") != "resources_only"
            or template.get("split") != "development" or template.get("repetitions") != 1
            or template.get("paths") != ["final"] or template.get("language_modes") != modes
            or len(profiles) != 1 or profiles[0].get("kind") != "candidate"):
        raise ValueError("Use a development resources_only template, one candidate profile, final path and one native repeat")
    bounded(template.get("threads"), 1, 4, "Thread budget")
    if type(template["threads"]) is not int:
        raise ValueError("Native thread count must be an integer")
    by_model = {m["id"]: m for m in template.get("models", [])}
    if set(by_model) != set(models) or len(by_model) != len(template.get("models", [])):
        raise ValueError("Template must contain exactly the declared models")
    config_parent = Path(identities["experiment"]["path"]).parent
    if str(absolute(template.get("whisper_cli"), config_parent)) != identities["whisper"]["path"]:
        raise ValueError("Template uses a different Whisper executable")
    locked = list(identities.values())
    additional = spec.get("additional_inputs", [])
    if not isinstance(additional, list) or len(additional) > 64:
        raise ValueError("At most 64 additional build/dependency identities")
    for index, item in enumerate(additional):
        if not isinstance(item, dict):
            raise ValueError("Additional inputs require explicit path/hash identities")
        locked.append(bounded_lock("additional:" + str(index), item.get("path"), digest(item.get("sha256"))))
    for model in by_model.values():
        path = absolute(model.get("path"), config_parent)
        locked.append(bounded_lock("model:" + model["id"], path, digest(model.get("sha256"))))
        model["path"] = str(path)
    if len({m["sha256"] for m in by_model.values()}) != len(models):
        raise ValueError("Model artifacts must have distinct hashes")
    profile = profiles[0]
    profile_path = absolute(profile.get("settings"), config_parent)
    locked.append(bounded_lock("profile", profile_path))
    profile_raw, _ = raw_json(profile_path)
    native_raw, native_matrix = raw_json(identities["expected_native_matrix"]["path"], identities["expected_native_matrix"]["sha256"])
    native_rows = expected_rows(native_matrix, identities, template, cases, by_model, hashlib.sha256(profile_raw).hexdigest())
    native_parent = Path(identities["expected_native_matrix"]["path"]).parent
    for name, expected in (("experiment.original.json", identities["experiment"]["sha256"]),
                           ("corpus.original.json", identities["corpus"]["sha256"]),
                           ("profile-" + profile["id"] + ".json", hashlib.sha256(profile_raw).hexdigest())):
        raw_json(native_parent / name, expected)
    baseline = template.get("baseline_cli")
    if baseline is not None:
        baseline_path = absolute(baseline, config_parent)
        locked.append(bounded_lock("baseline_cli", baseline_path, digest(template.get("baseline_cli_sha256"))))
        template["baseline_cli"] = str(baseline_path)
    corpus_parent = Path(identities["corpus"]["path"]).parent
    for case in cases:
        if case.get("split", "development") not in ("development", "resource"):
            raise ValueError("Keep resource cases outside the blind quality holdout")
        if "known" in modes and (case.get("language") in (None, "und", "auto") or case.get("code_switches")):
            raise ValueError("Known-language control is unsupported for an unknown/switch case")
        audio = absolute(case.get("audio"), corpus_parent)
        locked.append(bounded_lock("source:" + case["id"], audio, digest(case.get("sha256"))))
        case["audio"] = str(audio)
        if case.get("reference"):
            # Resolve metadata only; resource-only planning never reads a reference.
            reference = Path(case["reference"])
            case["reference"] = str(reference if reference.is_absolute() else corpus_parent / reference)
    root = new_output(output)
    for name, raw in (("spec.original.json", spec_raw), ("corpus.original.json", corpus_raw),
                      ("experiment.original.json", config_raw), ("matched.profile.json", profile_raw),
                      ("expected-native-matrix.original.json", native_raw)):
        write_new(root / name, raw)
        locked.append(bounded_lock("snapshot:" + name, root / name))
    profile["settings"] = str(root / "matched.profile.json")
    template["whisper_cli"] = identities["whisper"]["path"]
    template["capture_inactive"] = True
    template["workload_attestation"] = "Conditional on SHA-bound fresh native admission retained by controlled-panel run; no recording interruption authorized"
    template["freeze"] = None
    blocks = []
    for case_index, case in enumerate(cases):
        case_modes = modes if case_index % 2 == 0 else list(reversed(modes))
        for mode in case_modes:
            for round_index, order in enumerate(orders, 1):
                index = len(blocks)
                name = f"block-{index:04d}"
                selected_order = order if case_index % 2 == 0 else list(reversed(order))
                config = dict(template, models=[by_model[m] for m in selected_order], language_modes=[mode])
                single = dict(corpus, cases=[case])
                config_file, corpus_file = root / (name + ".experiment.json"), root / (name + ".corpus.json")
                write_new(config_file, encoded(config)); write_new(corpus_file, encoded(single))
                blocks.append(dict(id=name, case_id=case["id"], language=case.get("language"), language_mode=mode,
                                   round_id=round_index, model_order=selected_order,
                                   source_sha256=case["sha256"], source_channel=case.get("source_channel"),
                                   experiment=bounded_lock("block_config", config_file), corpus=bounded_lock("block_corpus", corpus_file)))
    plan = dict(schema_version=VERSION, created_utc=utcnow().isoformat(), deadline_utc=deadline.isoformat(),
                max_seconds=max_seconds, block_timeout_seconds=block_seconds,
                identities=identities, protected_inputs=locked, model_ids=models, profiles=profiles,
                expected_native_rows=native_rows,
                execution_claim_path=str(root / "execution.claim.json"),
                threads=template["threads"], model_metadata=by_model, language_modes=modes,
                original_case_ids=[c["id"] for c in cases], blocks=blocks,
                planned_native_calls=len(blocks) * len(models), native_repetitions_per_block=1,
                scheduling="2models AB/BA/BA/AB; 3models complete permutations; alternate case/mode orientation",
                controller=bounded_lock("controller", Path(__file__).resolve()),
                measurement_scope="resources_only", quality_approval=False, unique_source_cases=len(cases),
                source_groups=[{key: case.get(key) for key in ("id", "source_id", "source_group_ids", "session_id", "speaker_ids", "parent_case_id")} for case in cases],
                independent_speaker_units=None,
                guard_policy=dict(foreign_cpu_limit_percent=50, nice=10, maximum_poll_seconds=1),
                required_admission="Fresh native idle/live-off plus quiet/power/thermal declarations; guarded own session",
                single_use_execution_claim="execution.claim.json; new sidecar, original plan bytes never modified",
                metric_scope="warm-filesystem fresh-process application job; hashing/setup/load/inference/rendering included",
                first_result_latency_seconds=None, total_initialization_seconds=None, total_unified_gpu_memory_bytes=None)
    write_new(root / "plan.json", encoded(plan))
    return plan, hash_file(root / "plan.json")[0]


def load_plan(path, expected):
    raw, plan = raw_json(path, expected)
    if plan.get("schema_version") != VERSION or plan.get("measurement_scope") != "resources_only":
        raise ValueError("Unsupported controlled resource plan")
    if not 1 <= len(plan.get("blocks", [])) <= 288 or not 1 <= plan.get("planned_native_calls", 0) <= MAX_CALLS:
        raise ValueError("Invalid bounded block/call count")
    if len(plan["blocks"]) * len(plan["model_ids"]) != plan["planned_native_calls"]:
        raise ValueError("Conflicting planned call count")
    orders = permutations(plan["model_ids"])
    protected = {item["role"]: item for item in plan["protected_inputs"]}
    if len(protected) != len(plan["protected_inputs"]):
        raise ValueError("Duplicate protected input role")
    spec_snapshot = protected["snapshot:spec.original.json"]
    frozen_root = Path(spec_snapshot["path"]).parent
    claim = Path(plan.get("execution_claim_path", ""))
    if (not claim.is_absolute() or claim != frozen_root / "execution.claim.json"
            or ".." in claim.parts or any(p.is_symlink() for p in (claim, *claim.parents))):
        raise ValueError("Single-use execution claim must bind the original absolute frozen plan directory")
    original = {}
    for role, name in (("corpus", "corpus.original.json"), ("experiment", "experiment.original.json"),
                       ("expected_native_matrix", "expected-native-matrix.original.json")):
        identity = protected["snapshot:" + name]
        if Path(identity["path"]).parent != frozen_root or identity["sha256"] != plan["identities"][role]["sha256"]:
            raise ValueError("Frozen metadata snapshot differs from its original identity")
        _, original[role] = raw_json(identity["path"], identity["sha256"])
    original_rows = expected_rows(original["expected_native_matrix"], plan["identities"], original["experiment"],
                                  original["corpus"]["cases"], plan["model_metadata"],
                                  protected["snapshot:matched.profile.json"]["sha256"])
    if plan.get("expected_native_rows") != original_rows:
        raise ValueError("Expected runtime identities differ from the frozen native dry grid")
    if plan.get("original_case_ids") != [case["id"] for case in original["corpus"]["cases"]] or plan.get("language_modes") != original["experiment"]["language_modes"]:
        raise ValueError("Plan changed its original source/mode grid")
    schedule = []
    for case_index, case in enumerate(original["corpus"]["cases"]):
        modes = plan["language_modes"] if case_index % 2 == 0 else list(reversed(plan["language_modes"]))
        for mode in modes:
            for round_id, order in enumerate(orders, 1):
                schedule.append((case, mode, round_id, order if case_index % 2 == 0 else list(reversed(order))))
    if len(schedule) != len(plan["blocks"]):
        raise ValueError("Plan omitted or duplicated a balanced source/mode/round block")
    for index, (block, (case, mode, round_id, order)) in enumerate(zip(plan["blocks"], schedule)):
        if block.get("id") != f"block-{index:04d}" or set(block.get("model_order", [])) != set(plan["model_ids"]) or len(block["model_order"]) != len(plan["model_ids"]):
            raise ValueError("Unsafe or incomplete block permutation")
        if type(block.get("round_id")) is not int or not 1 <= block["round_id"] <= 6:
            raise ValueError("Invalid round identity")
        fixed = dict(case_id=case["id"], language=case.get("language"), source_channel=case.get("source_channel"),
                     source_sha256=case["sha256"], language_mode=mode, round_id=round_id, model_order=order)
        if any(block.get(key) != value for key, value in fixed.items()):
            raise ValueError("Plan changed its balanced schedule or source controls")
    bounded(plan.get("max_seconds"), 1, 3600, "Total seconds")
    bounded(plan.get("block_timeout_seconds"), 1, 600, "Block seconds")
    timestamp(plan.get("deadline_utc"))
    return raw, plan


def validate_admission(admission, plan_sha, now):
    if admission.get("schema_version") != "controlled-panel-admission-v1" or admission.get("plan_sha256") != plan_sha:
        raise ValueError("Admission does not bind this plan")
    for key in ("capture_inactive", "live_transcription_off", "quiet_workload", "power_stable", "thermal_nominal"):
        if admission.get(key) is not True:
            raise ValueError("Missing recording/controlled-workload admission: " + key)
    age = (now - timestamp(admission.get("native_checked_utc"))).total_seconds()
    if not 0 <= age <= 300 or not isinstance(admission.get("workload_attestation"), str) or not admission["workload_attestation"].strip():
        raise ValueError("Require a native idle check within five minutes and a workload attestation")


def remaining_seconds(plan, now, monotonic_now, monotonic_deadline):
    # Neither a delayed start nor a backward wall-clock jump can extend the budget.
    return min(monotonic_deadline - monotonic_now, (timestamp(plan["deadline_utc"]) - now).total_seconds())


def owned_workers(session):
    if session != os.getpid() or os.getsid(0) != session:
        raise ValueError("Cleanup requires this controller's own guarded session")
    result = subprocess.run(["/bin/ps", "-axo", "pid,pgid"], capture_output=True, text=True, timeout=1, check=True)
    lines = result.stdout.splitlines()
    if len(lines) < 2 or "PID" not in lines[0] or "PGID" not in lines[0]:
        raise ValueError("Owned-process snapshot unavailable")
    groups = defaultdict(set)
    for line in lines[1:]:
        fields = line.split()
        if len(fields) != 2 or not all(value.isdigit() for value in fields):
            raise ValueError("Ambiguous owned-process snapshot")
        pid, group = map(int, fields)
        if pid == os.getpid():
            continue
        try:
            if os.getsid(pid) == session:
                groups[group].add(pid)
        except ProcessLookupError:
            continue
    return groups


def stop_workers(child, session, native_output):
    events, errors = [], []
    if child.poll() is None and native_output.is_dir() and not native_output.is_symlink():
        (native_output / "cancel.request").touch(exist_ok=True)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            groups = owned_workers(session)
            if not groups and child.poll() is not None:
                break
            for group, members in groups.items():
                verified = []
                for pid in members:
                    try:
                        if os.getsid(pid) == session and os.getpgid(pid) == group:
                            verified.append(pid)
                    except ProcessLookupError:
                        continue
                if not verified:
                    continue
                try:
                    if group == os.getpgrp():
                        # Never signal the controller itself, even if a child joined its group.
                        for pid in verified:
                            os.kill(pid, sig)
                    else:
                        os.killpg(group, sig)
                    events.append(dict(signal=int(sig), process_group=group, verified_members=verified))
                except ProcessLookupError:
                    pass
            until = time.monotonic() + 1
            while time.monotonic() < until:
                child.poll()
                if not owned_workers(session):
                    break
                time.sleep(.05)
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        # The direct Popen child is ours even if a failed session probe could not
        # establish safe group membership. Never leave it unreaped.
        try:
            child.kill()
            child.wait(timeout=1)
            events.append(dict(signal=int(signal.SIGKILL), direct_owned_pid=child.pid))
        except Exception as error:
            errors.append("direct_reap:" + type(error).__name__)
    except Exception as error:
        errors.append("reap:" + type(error).__name__)
    try:
        present = bool(owned_workers(session))
    except Exception as error:
        present = None
        errors.append("final_probe:" + type(error).__name__)
    return dict(returncode=child.returncode, child_reaped=child.returncode is not None,
                owned_workers_present=present, shutdown_errors=errors, signals=events)


def output_budget(root):
    total, count = 0, 0
    for path in root.rglob("*"):
        count += 1
        if path.is_symlink():
            raise ValueError("Owned output contains a symlink")
        if path.is_file():
            total += path.stat().st_size
        if total > MAX_OUTPUT_BYTES or count > 50000:
            raise ValueError("Owned output exceeds 512 MiB / 50,000 entries")


def execute(plan_path, expected, admission_path, admission_sha, output):
    plan_path, admission_path = absolute(str(plan_path)), absolute(str(admission_path))
    plan_raw, plan = load_plan(plan_path, expected)
    admission_raw, admission = raw_json(admission_path, admission_sha)
    now = utcnow()
    validate_admission(admission, expected, now)
    remaining = min(plan["max_seconds"], (timestamp(plan["deadline_utc"]) - now).total_seconds())
    if remaining <= 0:
        raise TimeoutError("Fixed panel deadline expired before launch")
    if os.getsid(0) != os.getpid():
        raise ValueError("Run this controller under run-guard.py in its own owned session")
    root = new_output(output)
    write_new(root / "plan.original.json", plan_raw)
    write_new(root / "admission.original.json", admission_raw)
    state = dict(schema_version=VERSION + "-run", plan_sha256=expected,
                 admission_sha256=digest(admission_sha), created_utc=now.isoformat(),
                 admission_path=str(admission_path), execution_claim_path=plan["execution_claim_path"],
                 controller_pid=os.getpid(), owned_session=os.getsid(0),
                 fixed_deadline_utc=plan["deadline_utc"], max_seconds=plan["max_seconds"],
                 status="running", inference_retries=0, measurement_scope="resources_only",
                 blocks=[dict(id=b["id"], case_id=b["case_id"], language_mode=b["language_mode"], round_id=b["round_id"],
                              status="queued", output=b["id"]) for b in plan["blocks"]])
    state_path = root / "state.json"
    save(state_path, state)
    monotonic_deadline = time.monotonic() + remaining
    requested = {"signal": None}
    previous = {}
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, lambda sig, frame: requested.update(signal=sig))
    last_scan = [float("-inf")]

    def check():
        if requested["signal"] is not None or (root / "cancel.request").exists():
            raise InterruptedError("Panel cancellation requested")
        if remaining_seconds(plan, utcnow(), time.monotonic(), monotonic_deadline) <= 0:
            raise TimeoutError("Fixed panel deadline/budget exhausted")
        if time.monotonic() - last_scan[0] >= 1:
            output_budget(root)
            last_scan[0] = time.monotonic()

    active, child, block_root = None, None, None
    try:
        write_new(plan["execution_claim_path"], encoded(dict(
            plan_sha256=expected, admission_sha256=admission_sha, output=str(root),
            claimed_utc=now.isoformat(), fixed_deadline_utc=plan["deadline_utc"], controller_pid=os.getpid())))
        verify_lock(plan["controller"], check)
        for item in plan["protected_inputs"]:
            verify_lock(item, check)
        for block, current in zip(plan["blocks"], state["blocks"]):
            active = current
            check()
            raw_json(plan_path, expected)
            verify_lock(block["experiment"], check)
            verify_lock(block["corpus"], check)
            for role in ("coordinator", "transcriber", "whisper"):
                verify_lock(plan["identities"][role], check)
            for item in plan["protected_inputs"]:
                if item["role"].startswith(("model:", "additional:", "snapshot:")) or item["role"] == "source:" + block["case_id"]:
                    verify_lock(item, check)
            block_root = root / block["id"]
            command = [plan["identities"]["coordinator"]["path"], "benchmark", block["corpus"]["path"],
                       "--experiment", block["experiment"]["path"], "--transcription-cli", plan["identities"]["transcriber"]["path"],
                       "--output", str(block_root)]
            # Persist before Popen: a failed launch/unknown outcome is never a retry.
            current.update(status="running", started_utc=utcnow().isoformat(), command=command)
            save(state_path, state)
            log_path = root / (block["id"] + ".console.log")
            with log_path.open("xb") as log:
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                         process_group=0)
                current["pid"] = child.pid
                save(state_path, state)
                block_deadline = min(monotonic_deadline, time.monotonic() + plan["block_timeout_seconds"])
                try:
                    while child.poll() is None:
                        check()
                        if time.monotonic() >= block_deadline or log_path.stat().st_size > 2 * 1024 * 1024:
                            raise TimeoutError("Native block exceeded time/log budget")
                        time.sleep(.1)
                    check()
                    if child.returncode:
                        raise RuntimeError("Native block failed; retained output, no retry")
                finally:
                    # Reap both the coordinator and any inherited native process groups.
                    current["shutdown"] = stop_workers(child, os.getpid(), block_root)
                    save(state_path, state)
                    child = None
                shutdown = current["shutdown"]
                if not shutdown["child_reaped"] or shutdown["owned_workers_present"] is not False or shutdown["shutdown_errors"] or shutdown["signals"]:
                    raise RuntimeError("Owned worker cleanup is uncertain")
            matrix = block_root / "matrix.json"
            matrix_raw, _ = raw_json(matrix)
            check()
            current.update(status="completed", completed_utc=utcnow().isoformat(), matrix_sha256=hashlib.sha256(matrix_raw).hexdigest())
            save(state_path, state)
        check()
        state["status"] = "completed"
    except BaseException as error:
        category = "cancelled" if isinstance(error, InterruptedError) else "deadline_exhausted" if isinstance(error, TimeoutError) else "failed"
        state.update(status=category, error=type(error).__name__ + ": " + str(error))
        if active is not None and active["status"] != "completed":
            active.update(status=category, error=state["error"])
        if child is not None:
            active["shutdown"] = stop_workers(child, os.getpid(), block_root)
        raise
    finally:
        state["ended_utc"] = utcnow().isoformat()
        save(state_path, state)
        for number, handler in previous.items():
            signal.signal(number, handler)
    return state


def numerical(value, positive=False):
    return type(value) in (int, float) and math.isfinite(value) and (value > 0 if positive else value >= 0)


def summary(values):
    return dict(count=len(values), median=statistics.median(values) if values else None,
                minimum=min(values) if values else None, maximum=max(values) if values else None)


def upstream_timers(records):
    """Retain native observations separately; overlapping phases are never summed."""
    result = []
    if not isinstance(records, list):
        return result
    for index, record in enumerate(records):
        timings = record.get("runtime_timings", {}) if isinstance(record, dict) else {}
        observations = timings.get("observations", {})
        if not isinstance(observations, dict):
            continue
        for phase in ("load", "mel", "sample", "encode", "decode", "batchd", "prompt", "total"):
            for item in observations.get(phase, []) if isinstance(observations.get(phase, []), list) else []:
                if isinstance(item, dict) and numerical(item.get("seconds")):
                    result.append(dict(native_invocation=index, phase=phase, seconds=item["seconds"],
                                       parser_version=timings.get("parser_version")))
    return result


def guard_assessment(path, expected, plan, plan_path, plan_sha, state, run_root):
    if path is None and expected is None:
        return dict(status="MISSING; controlled conditions not established")
    if path is None or expected is None:
        raise ValueError("Guard log and its exact SHA-256 are required together")
    with Path(path).open("rb") as stream:
        raw = stream.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES or hashlib.sha256(raw).hexdigest() != digest(expected):
        raise ValueError("Guard log exceeds bound or SHA differs")
    rows = [decode(line) for line in raw.splitlines() if line.strip()]
    start = next((row for row in rows if row.get("event") == "starting"), None)
    launched = next((row for row in rows if row.get("event") == "started"), None)
    final = rows[-1] if rows else {}
    command = start.get("command", []) if start else []
    def argument(name, value):
        return command.count(name) == 1 and command.index(name) + 1 < len(command) and command[command.index(name) + 1] == value
    matching_output = command.count("--output") == 1 and command.index("--output") + 1 < len(command) and command[command.index("--output") + 1] == str(run_root)
    controller = plan["controller"]["path"]
    matching_controller = (command.count(controller) == 1 and command.index(controller) + 1 < len(command)
                           and command[command.index(controller) + 1] == "run"
                           and argument("--plan", str(Path(plan_path).resolve()))
                           and argument("--plan-sha256", plan_sha)
                           and argument("--admission", state.get("admission_path"))
                           and argument("--admission-sha256", state.get("admission_sha256")))
    shutdown = final.get("shutdown") or {}
    event_counts = Counter(row.get("event") for row in rows)
    ordered_start = bool(rows and rows[0] is start and start and launched
                         and rows.index(start) < rows.index(launched) < len(rows) - 1)
    valid = bool(ordered_start and event_counts["starting"] == event_counts["started"] == event_counts["finished"] == 1
                 and not event_counts["cancel_requested"] and not event_counts["not_started"]
                 and matching_output and matching_controller and final.get("event") == "finished"
                 and final.get("reason") is None and final.get("failure") is None
                 and shutdown.get("cli_reaped") is True and shutdown.get("owned_session_present") is False
                 and shutdown.get("shutdown_errors") == [] and shutdown.get("returncode") == 0
                 and launched.get("child_nice") == plan["guard_policy"]["nice"]
                 and launched.get("pid") == state.get("controller_pid")
                 and launched.get("owned_session") == state.get("owned_session") == state.get("controller_pid")
                 and numerical(start.get("foreign_cpu_limit"), positive=True)
                 and start["foreign_cpu_limit"] <= plan["guard_policy"]["foreign_cpu_limit_percent"]
                 and numerical(start.get("poll_seconds"), positive=True)
                 and start["poll_seconds"] <= plan["guard_policy"]["maximum_poll_seconds"])
    return dict(status="observed declared guard conditions complete" if valid else "INVALID / INCOMPLETE",
                log_sha256=expected, final_reason=final.get("reason"), final_failure=final.get("failure"),
                cpu_scope="observed per-process CPU threshold; not GPU idle proof", gpu_idle_measured=False)


def collect(plan_path, expected, run_root, run_sha, output, guard_log=None, guard_sha=None):
    collection_deadline = time.monotonic() + 120
    _, plan = load_plan(plan_path, expected)
    run_root = absolute(str(run_root))
    state_raw, state = raw_json(run_root / "state.json", run_sha)
    if state.get("schema_version") != VERSION + "-run" or state.get("plan_sha256") != expected:
        raise ValueError("Run state does not bind the explicit plan")
    raw_json(run_root / "plan.original.json", expected)
    _, admission = raw_json(run_root / "admission.original.json", state["admission_sha256"])
    validate_admission(admission, expected, timestamp(state["created_utc"]))
    if state.get("fixed_deadline_utc") != plan["deadline_utc"] or state.get("max_seconds") != plan["max_seconds"]:
        raise ValueError("Run altered the fixed deadline/budget")
    if state.get("execution_claim_path") != plan["execution_claim_path"]:
        raise ValueError("Run changed the frozen single-use execution claim")
    _, claim = raw_json(plan["execution_claim_path"])
    claim_expected = dict(plan_sha256=expected, admission_sha256=state["admission_sha256"], output=str(run_root),
                          fixed_deadline_utc=plan["deadline_utc"], controller_pid=state["controller_pid"], claimed_utc=state["created_utc"])
    if claim != claim_expected:
        raise ValueError("Execution claim does not bind this exact run/admission/controller")
    if len(state.get("blocks", [])) != len(plan["blocks"]):
        raise ValueError("Run altered planned block count")
    measurements, pairs, thermals, statuses = [], [], [], Counter()
    model_locks = {v["role"].split(":", 1)[1]: v for v in plan["protected_inputs"] if v["role"].startswith("model:")}
    profile_id = plan["profiles"][0]["id"]
    profile_sha = next(v["sha256"] for v in plan["protected_inputs"] if v["role"] == "snapshot:matched.profile.json")
    native_expected = {row_key(row): row for row in plan["expected_native_rows"]}
    for block, current in zip(plan["blocks"], state["blocks"]):
        if time.monotonic() >= collection_deadline:
            raise TimeoutError("Resource collection exceeded 120 seconds")
        for key in ("id", "case_id", "round_id", "language_mode"):
            if current.get(key) != block[key]:
                raise ValueError("Run changed block identity")
        if current.get("output") != block["id"]:
            raise ValueError("Unsafe block evidence pointer")
        if current.get("status") not in {"queued", "running", "completed", "failed", "cancelled", "deadline_exhausted"}:
            raise ValueError("Unknown block status")
        statuses[current["status"]] += 1
        observed = {}
        if current["status"] == "completed":
            matrix_path = run_root / block["id"] / "matrix.json"
            _, matrix = raw_json(matrix_path, current["matrix_sha256"])
            for file_name, identity in (("experiment.original.json", block["experiment"]), ("corpus.original.json", block["corpus"])):
                raw_json(matrix_path.parent / file_name, identity["sha256"])
            raw_json(matrix_path.parent / ("profile-" + profile_id + ".json"), profile_sha)
            if matrix.get("profile_sha256") != {profile_id: profile_sha}:
                raise ValueError("Native profile identity differs from frozen settings")
            for name, desired in (("configuration_sha256", block["experiment"]["sha256"]), ("corpus_sha256", block["corpus"]["sha256"]),
                                  ("runner_sha256", plan["identities"]["transcriber"]["sha256"]), ("coordinator_sha256", plan["identities"]["coordinator"]["sha256"]),
                                  ("whisper_binary_sha256", plan["identities"]["whisper"]["sha256"]), ("measurement_scope", "resources_only"), ("threads", plan["threads"])):
                if matrix.get(name) != desired:
                    raise ValueError("Native matrix identity differs: " + name)
            thermals.append(matrix.get("host", {}).get("thermal_state"))
            rows = matrix.get("rows", [])
            if len(rows) != len(plan["model_ids"]) or [row.get("model") for row in rows] != block["model_order"]:
                raise ValueError("Native block did not execute its exact model permutation")
            for index, row in enumerate(rows):
                model = row["model"]
                desired = dict(id=block["case_id"], language=block["language"], source_channel=block["source_channel"],
                               language_mode=block["language_mode"], repeat=1, path="final",
                               source_sha256=block["source_sha256"], model_sha256=model_locks[model]["sha256"],
                               transcription_runner_sha256=plan["identities"]["transcriber"]["sha256"],
                               whisper_binary_sha256=plan["identities"]["whisper"]["sha256"],
                               measurement_scope="resources_only", scoring_policy="unscored-resources-v1", threads=plan["threads"],
                               profile=profile_id, profile_sha256=profile_sha)
                if any(row.get(name) != value for name, value in desired.items()):
                    raise ValueError("Native row identity differs")
                native = native_expected.get(row_key(row))
                if native is None or any(row.get(name) != native.get(name) for name in ROW_IDENTITIES):
                    raise ValueError("Native row differs from the exact frozen unmeasured native grid")
                measurement = row.get("measurement") or {}
                if row.get("status") not in STATUS_COMPLETE:
                    continue
                if measurement.get("status") != row["status"] or measurement.get("source_sha256") != block["source_sha256"] or measurement.get("scoring_version") != "unscored-resources-v1" or measurement.get("reference_sha256") is not None:
                    raise ValueError("Resource measurement was scored or used a different source")
                actual_passes = engine_observations(measurement.get("engine_passes"), native)
                if (actual_passes < 1 or type(row.get("engine_identity_observations")) is not int
                        or row["engine_identity_observations"] != actual_passes
                        or row.get("runner_sha256") != plan["identities"]["transcriber"]["sha256"]):
                    raise ValueError("Successful resource row lacks verified actual native engine/runner observations")
                evidence = row.get("evidence_directory")
                if evidence != "cell-" + str(index):
                    raise ValueError("Native cell evidence must be retained within its own block")
                _, case_report = raw_json(matrix_path.parent / evidence / "results.json")
                if case_report.get("results") != [measurement] or case_report.get("runner_sha256") != plan["identities"]["transcriber"]["sha256"]:
                    raise ValueError("Measurement differs from retained native case report")
                wall, rss = measurement.get("wall_seconds"), measurement.get("peak_rss_bytes")
                if not numerical(wall, positive=True) or not numerical(rss, positive=True):
                    continue
                value = dict(block_id=block["id"], round_id=block["round_id"], case_id=block["case_id"],
                             language=block["language"], language_mode=block["language_mode"], model=model,
                             model_sha256=model_locks[model]["sha256"], wall_seconds=wall, peak_rss_bytes=rss,
                             real_time_factor=measurement.get("real_time_factor"),
                             source_audio_seconds=measurement.get("source_audio_seconds"),
                             upstream_timers=upstream_timers(measurement.get("engine_runtime_measurements")),
                             first_result_latency_seconds=None, total_initialization_seconds=None, total_unified_gpu_memory_bytes=None)
                observed[model] = value
                measurements.append(value)
        control = observed.get(plan["model_ids"][0])
        for candidate in plan["model_ids"][1:]:
            after = observed.get(candidate)
            pair = dict(block_id=block["id"], round_id=block["round_id"], case_id=block["case_id"], language=block["language"],
                        language_mode=block["language_mode"], baseline_model=plan["model_ids"][0], candidate_model=candidate,
                        status="observed" if control and after else "missing_pair", wall_ratio=None, peak_rss_ratio=None)
            if control and after:
                pair.update(wall_ratio=after["wall_seconds"] / control["wall_seconds"],
                            peak_rss_ratio=after["peak_rss_bytes"] / control["peak_rss_bytes"],
                            wall_seconds_delta=after["wall_seconds"] - control["wall_seconds"],
                            peak_rss_bytes_delta=after["peak_rss_bytes"] - control["peak_rss_bytes"])
            pairs.append(pair)
    guard = guard_assessment(guard_log, guard_sha, plan, plan_path, expected, state, run_root)
    complete = state["status"] == "completed" and all(v["status"] == "observed" for v in pairs)
    clean_shutdown = all(b.get("shutdown", {}).get("child_reaped") is True
                         and b["shutdown"].get("owned_workers_present") is False
                         and b["shutdown"].get("shutdown_errors") == [] and b["shutdown"].get("signals") == []
                         for b in state["blocks"] if b["status"] == "completed")
    thermal_nominal = len(thermals) == len(plan["blocks"]) and all(type(value) is int and value == 0 for value in thermals)
    controlled = complete and clean_shutdown and thermal_nominal and guard["status"] == "observed declared guard conditions complete"
    source_pairs = []
    for candidate in plan["model_ids"][1:]:
        for mode in plan["language_modes"]:
            for case in plan["original_case_ids"]:
                values = [p for p in pairs if p["candidate_model"] == candidate and p["language_mode"] == mode and p["case_id"] == case]
                successful = [p for p in values if p["status"] == "observed"]
                source_pairs.append(dict(case_id=case, candidate_model=candidate, language_mode=mode,
                                         planned_rounds=len(values), observed_rounds=len(successful),
                                         complete=len(successful) == len(values),
                                         wall_ratio=summary([p["wall_ratio"] for p in successful]),
                                         peak_rss_ratio=summary([p["peak_rss_ratio"] for p in successful])))
    comparisons = []
    for candidate in plan["model_ids"][1:]:
        for mode in plan["language_modes"]:
            values = [p for p in source_pairs if p["candidate_model"] == candidate and p["language_mode"] == mode]
            observed = [p for p in values if p["complete"]]
            comparisons.append(dict(candidate_model=candidate, baseline_model=plan["model_ids"][0], language_mode=mode,
                                    planned_source_cases=len(values), completely_paired_source_cases=len(observed),
                                    source_median_wall_ratio=summary([p["wall_ratio"]["median"] for p in observed]),
                                    source_median_peak_rss_ratio=summary([p["peak_rss_ratio"]["median"] for p in observed]),
                                    scope="Per-source-case round medians; cases counted once, no speaker independence, population interval or acceptance inferred"))
    cohorts = []
    languages = sorted({block["language"] for block in plan["blocks"]}, key=str)
    for model in plan["model_ids"]:
        for mode in plan["language_modes"]:
            for language in languages:
                values = [v for v in measurements if v["model"] == model and v["language_mode"] == mode and v["language"] == language]
                cohorts.append(dict(model=model, language_mode=mode, declared_language=language, invocations=len(values),
                                    unique_source_cases=len({v["case_id"] for v in values}),
                                    wall_seconds=summary([v["wall_seconds"] for v in values]),
                                    peak_rss_bytes=summary([v["peak_rss_bytes"] for v in values]),
                                    real_time_factor=summary([v["real_time_factor"] for v in values if numerical(v["real_time_factor"], positive=True)]),
                                    upstream_load_seconds_per_native_invocation=summary([timer["seconds"] for v in values for timer in v["upstream_timers"] if timer["phase"] == "load"])))
    report = dict(schema_version=VERSION + "-report", created_utc=utcnow().isoformat(), plan_sha256=expected,
                  run_state_sha256=run_sha, measurement_scope="resources_only", block_statuses=dict(statuses),
                  planned_native_calls=plan["planned_native_calls"], measured_invocations=len(measurements),
                  unique_source_cases=plan["unique_source_cases"], source_groups=plan["source_groups"],
                  independent_speaker_units=None, quality_sample_size=0, quality_approval=False,
                  fixed_deadline_utc=plan["deadline_utc"], guard=guard,
                  nominal_native_block_thermal_states=thermal_nominal, observed_native_block_thermal_states=thermals,
                  thermal_observation_scope="Native block-start ProcessInfo thermalState; not continuous monitoring",
                  power_observation_scope="Admission declaration only; no measured power or GPU-idle claim",
                  clean_owned_shutdowns=clean_shutdown, complete_pairs=complete,
                  controlled_observed_conditions=controlled,
                  resource_acceptance="NOT_AUTHORIZED; observations under declared conditions only",
                  metric_scope=plan["metric_scope"], cohorts=cohorts, measurements=measurements, pairs=pairs,
                  source_pairs=source_pairs, source_comparison_summaries=comparisons,
                  missing_pairs=sum(p["status"] != "observed" for p in pairs),
                  first_result_latency_seconds=None, total_initialization_seconds=None, total_unified_gpu_memory_bytes=None,
                  limitations=["Warm filesystem/fresh processes, not cold-cache or resident-worker performance",
                               "RSS is maximum process RSS, not total unified CPU/GPU allocation",
                               "CPU/workload guard is not a measurement of GPU idle state",
                               "Source language declarations and repeated output do not establish quality or speaker independence",
                               "External block/round IDs preserve native repeat1 and original case IDs; no quality report is combined"])
    destination = new_output(output)
    write_new(destination / "report.json", encoded(report))
    text = ["# Controlled resource panel observations", "", "Quality remains unmeasured; no product acceptance.", "",
            f"Observed declared conditions complete: {controlled}. Missing pairs: {report['missing_pairs']}.",
            "Warm-filesystem fresh-process application jobs; RSS excludes total unified GPU allocation. First-result and full-initialization latency remain unmeasured.", "",
            "| Model | Mode | Declared language | Calls | Unique source cases | Wall median [min,max] s | Peak RSS median [min,max] bytes | Upstream load s/native call | RTF / job |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for cohort in cohorts:
        def span(key):
            item = cohort[key]
            return "pending" if item["median"] is None else f"{item['median']:.6f} [{item['minimum']:.6f},{item['maximum']:.6f}]"
        text.append("| " + " | ".join([cohort["model"], cohort["language_mode"], str(cohort["declared_language"]), str(cohort["invocations"]), str(cohort["unique_source_cases"]), span("wall_seconds"), span("peak_rss_bytes"), span("upstream_load_seconds_per_native_invocation"), span("real_time_factor")]) + " |")
    write_new(destination / "report.md", ("\n".join(text) + "\n").encode())
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    planning = sub.add_parser("plan")
    planning.add_argument("--spec", required=True, type=Path)
    planning.add_argument("--output", required=True, type=Path)
    running = sub.add_parser("run")
    collecting = sub.add_parser("collect")
    for command in (running, collecting):
        command.add_argument("--plan", required=True, type=Path)
        command.add_argument("--plan-sha256", required=True)
        command.add_argument("--output", required=True, type=Path)
    running.add_argument("--admission", required=True, type=Path)
    running.add_argument("--admission-sha256", required=True)
    collecting.add_argument("--run", required=True, type=Path)
    collecting.add_argument("--run-sha256", required=True, help="Exact stopped/final state.json SHA-256")
    collecting.add_argument("--guard-log", type=Path)
    collecting.add_argument("--guard-sha256")
    args = parser.parse_args(argv)
    try:
        if args.operation == "plan":
            plan, sha = make_plan(args.spec, args.output)
            print(json.dumps(dict(plan_sha256=sha, blocks=len(plan["blocks"]), planned_native_calls=plan["planned_native_calls"])))
        elif args.operation == "run":
            state = execute(args.plan, args.plan_sha256, args.admission, args.admission_sha256, args.output)
            print(json.dumps(dict(status=state["status"], inference_retries=0)))
        else:
            report = collect(args.plan, args.plan_sha256, args.run, args.run_sha256, args.output, args.guard_log, args.guard_sha256)
            print(json.dumps({key: report[key] for key in ("measured_invocations", "missing_pairs", "controlled_observed_conditions")}))
        return 0
    except (ValueError, OSError, TimeoutError, RuntimeError, InterruptedError, KeyError, TypeError) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
