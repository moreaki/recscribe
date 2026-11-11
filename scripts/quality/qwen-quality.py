#!/usr/bin/env python3
"""Collect first-attempt external Qwen/native lexical counts, without ASR.

collect --plan ABS --plan-sha256 SHA --output NEW_PROTECTED_DIRECTORY

A qwen-quality-v1-plan binds corpus, native_matrices [{id,path,sha256}],
controls [{id,matrix_id,identity}], cases [{id,language_mode,qwen:{request:
{path,sha256},output,state_sha256}}], scorer {path,sha256,build_receipt:
{path,sha256},source_files:[{path,sha256}]}, adapter_sha256,
common_helper_sha256, collector_sha256, claim_path, deadline_utc, max_seconds,
per_score_seconds, scoring_policy and recognition_task:"transcribe".
The corpus supplies unchanged audio/reference, source/channel/task/language.
Null state_sha256 explicitly means an unsealed/missing first outcome, never a
permission to discover a later success. Failed cells stay missing. This report
is separate from the isolated-compression quality-preservation evaluator.
"""
import argparse
from collections import defaultdict
import hashlib
import importlib.util
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import wave

ADAPTER_PATH = Path(__file__).with_name("qwen-asr-case.py")
_SPEC = importlib.util.spec_from_file_location("qwen_quality_adapter", ADAPTER_PATH)
adapter = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(adapter)  # stdlib only; never imports MLX/model libraries
common = adapter.common
VERSION = "qwen-quality-v1"
POLICY = "swift-nfc-casefold-alphanumeric-v1"
MAX_CASES = 512
MAX_ROWS = 4096
MAX_MATRIX_BYTES = 64 * 1024 * 1024
MAX_TEXT = 1024 * 1024
MAX_LOG = 2 * 1024 * 1024
CONTROL_FIELDS = {"model", "model_sha256", "profile", "profile_sha256", "runtime_settings_sha256",
                  "transcription_runner_sha256", "whisper_binary_sha256", "source_revision"}
METRICS = {"cer": ("character", "reference_characters"), "wer": ("word", "reference_words")}


def safe_name(value):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value) is None:
        raise ValueError("Use a bounded safe identity")
    return value


def regular(value, must_exist=True):
    if not isinstance(value, str):
        raise ValueError("Absolute non-symlink input path required")
    path = Path(value).expanduser()
    if not path.is_absolute() or ".." in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Absolute non-symlink input path required")
    if must_exist and not path.is_file():
        raise ValueError("Regular input file required")
    return path


def json_identity(identity, check, maximum=common.MAX_JSON_BYTES):
    check()
    path = regular(identity.get("path"))
    expected = common.digest(identity.get("sha256"))
    if path.stat().st_size > maximum:
        raise ValueError("Metadata exceeds its bounded byte budget")
    with path.open("rb") as stream:
        raw = stream.read(maximum + 1)
    check()
    if len(raw) > maximum or hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("Metadata SHA-256 mismatch")
    return raw, common.decode(raw)


def file_identity(identity, check, maximum):
    path = regular(identity.get("path"))
    if path.stat().st_size > maximum:
        raise ValueError("Input exceeds its bounded byte budget")
    actual, _ = common.hash_file(path, check)
    if actual != common.digest(identity.get("sha256")):
        raise ValueError("Input SHA-256 mismatch")
    return path


def read_text(identity, check):
    path = file_identity(identity, check, MAX_TEXT)
    # Reject invalid UTF-8 before starting any scorer. No normalization/correction.
    with path.open("rb") as stream:
        raw = stream.read(MAX_TEXT + 1)
    raw.decode("utf-8", errors="strict")
    check()
    if len(raw) > MAX_TEXT or hashlib.sha256(raw).hexdigest() != identity["sha256"]:
        raise ValueError("Text changed while reading")
    return path


def metrics(value, language):
    if value.get("scoring_version") != POLICY:
        raise ValueError("Only the unchanged native legacy-v1 scorer is comparable")
    result = {}
    for name, (prefix, denominator) in METRICS.items():
        if name == "wer" and language.split("-", 1)[0] == "zh":
            result[name] = None
            continue
        keys = [prefix + "_errors", denominator] + [prefix + "_" + op for op in ("insertions", "deletions", "substitutions")]
        numbers = [value.get(key) for key in keys]
        if (any(type(x) is not int or not 0 <= x <= 100_000_000 for x in numbers)
                or numbers[1] <= 0 or numbers[0] != sum(numbers[2:])):
            raise ValueError("Consistent bounded edit counts with positive reference denominators required")
        rate = value.get(name)
        if type(rate) not in (int, float) or not math.isfinite(rate) or abs(rate - numbers[0] / numbers[1]) > 1e-12:
            raise ValueError("Edit-count/rate mismatch")
        result[name] = dict(zip(("errors", "units", "insertions", "deletions", "substitutions"), numbers))
    return result


def validate_plan(path, expected, check=lambda: None):
    raw, plan = json_identity(dict(path=str(path), sha256=expected), check)
    if plan.get("schema_version") != VERSION + "-plan" or plan.get("scoring_policy") != POLICY or plan.get("recognition_task") != "transcribe":
        raise ValueError("Explicit versioned legacy-v1 transcription collection plan required")
    common.timestamp(plan.get("deadline_utc"))
    common.bounded(plan.get("max_seconds"), 1, 3600, "Collection budget")
    common.bounded(plan.get("per_score_seconds"), 1, 120, "Per-score budget")
    collection_claim = adapter.claim_path(plan)
    for source, key in ((Path(__file__).resolve(), "collector_sha256"), (ADAPTER_PATH, "adapter_sha256"),
                        (adapter.COMMON_PATH, "common_helper_sha256")):
        if common.hash_file(source, check)[0] != common.digest(plan.get(key)):
            raise ValueError("Frozen collection source changed: " + key)
    scorer = plan.get("scorer", {})
    scorer_path = file_identity(scorer, check, 128 * 1024 * 1024)
    if not os.access(scorer_path, os.X_OK):
        raise ValueError("Frozen scorer must be executable")
    _, build = json_identity(scorer.get("build_receipt", {}), check)
    sources = scorer.get("source_files")
    required = {"TranscriptAccuracy.swift", "JSONValue.swift", "score-transcript.swift"}
    if not isinstance(sources, list) or len(sources) != 3 or {Path(s.get("path", "")).name for s in sources} != required:
        raise ValueError("Bind all three unmodified standalone/native scorer sources")
    for source in sources:
        file_identity(source, check, MAX_TEXT)
    source_map = {s["path"]: s["sha256"] for s in sources}
    built_sources = build.get("sources")
    if (build.get("schema_version") != "standalone-native-scorer-build-v1" or type(build.get("build_exit_code")) is not int
            or build["build_exit_code"] != 0 or build.get("byte_identical_reproduction") is not True
            or not isinstance(built_sources, list) or len(built_sources) != 3
            or {s.get("path"): s.get("sha256") for s in built_sources} != source_map
            or build.get("binary", {}).get("path") != str(scorer_path)
            or build.get("binary", {}).get("sha256") != scorer["sha256"]):
        raise ValueError("Scorer build receipt is not linked to this exact binary and three sources")
    for source in built_sources:
        if type(source.get("bytes")) is not int or regular(source["path"]).stat().st_size != source["bytes"]:
            raise ValueError("Scorer build source byte length mismatch")
    if build["binary"].get("bytes") != scorer_path.stat().st_size:
        raise ValueError("Scorer build binary byte length mismatch")
    reproduced = build.get("reproduction_binary", {})
    file_identity(reproduced, check, 128 * 1024 * 1024)
    if reproduced.get("sha256") != scorer["sha256"] or reproduced.get("bytes") != scorer_path.stat().st_size:
        raise ValueError("Scorer reproduction binary identity mismatch")
    legacy_hash = next(s["sha256"] for s in sources if Path(s["path"]).name == "TranscriptAccuracy.swift")
    contracts = build.get("compiled_contract_tests", {})
    if (build.get("unchanged_legacy_scorer_sha256") != legacy_hash or build.get("model_or_asr_execution") is not False
            or not isinstance(build.get("compiler"), str) or not 1 <= len(build["compiler"]) <= 4096
            or contracts != dict(total=4, passed=4, failed=0)):
        raise ValueError("Scorer native-source/compiler/compiled-contract proof mismatch")
    corpus_raw, corpus = json_identity(plan.get("corpus", {}), check)
    corpus_cases = corpus.get("cases")
    if not isinstance(corpus_cases, list) or not 1 <= len(corpus_cases) <= MAX_CASES:
        raise ValueError("Bounded corpus case list required")
    corpus_index = {}
    for case in corpus_cases:
        identifier = safe_name(case.get("id"))
        if identifier in corpus_index:
            raise ValueError("Duplicate original corpus ID")
        corpus_index[identifier] = case
    matrices, matrix_raw = {}, {}
    matrix_specs = plan.get("native_matrices")
    if not isinstance(matrix_specs, list) or not 1 <= len(matrix_specs) <= 16:
        raise ValueError("Bind 1–16 retained native matrices")
    for identity in matrix_specs:
        identifier = safe_name(identity.get("id"))
        if identifier in matrices:
            raise ValueError("Duplicate native matrix identity")
        native_raw, native = json_identity(identity, check, MAX_MATRIX_BYTES)
        rows = native.get("rows")
        if not isinstance(rows, list) or len(rows) > MAX_ROWS or native.get("dry_run") is not False or native.get("measurement_scope") == "resources_only":
            raise ValueError("Bounded measured quality matrix required, never dry-run/resource-only")
        matrices[identifier], matrix_raw[identifier] = native, native_raw
    controls = plan.get("controls")
    if not isinstance(controls, list) or not 1 <= len(controls) <= 4:
        raise ValueError("Declare 1–4 native controls")
    seen = set()
    selectors = set()
    for control in controls:
        identifier = safe_name(control.get("id"))
        identity = control.get("identity", {})
        if identifier in seen or control.get("matrix_id") not in matrices or set(identity) != CONTROL_FIELDS:
            raise ValueError("Unique native controls with complete frozen runtime identities required")
        seen.add(identifier)
        selector = (control["matrix_id"], identity["model"], identity["profile"])
        if selector in selectors:
            raise ValueError("One control per native model/profile cell")
        selectors.add(selector)
        safe_name(identity["model"]); safe_name(identity["profile"])
        for key in CONTROL_FIELDS - {"model", "profile", "source_revision"}:
            common.digest(identity[key])
        if not isinstance(identity["source_revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", identity["source_revision"]):
            raise ValueError("Frozen native source revision required")
    entries = plan.get("cases")
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_CASES:
        raise ValueError("Freeze 1–512 first-attempt case/mode cells")
    seen, outputs, claims, selected = set(), set(), {collection_claim}, []
    for entry in entries:
        check()
        key = (entry.get("id"), entry.get("language_mode"))
        if key in seen or key[0] not in corpus_index or key[1] not in ("known", "auto"):
            raise ValueError("Unique original case and language-mode cells required")
        seen.add(key)
        case = corpus_index[key[0]]
        adapter.language_argument(case.get("language"), key[1])
        if (case.get("task") not in ("transcription", "standard_rendering") or case.get("source_channel") != 0
                or type(case.get("source_channel")) is not int or case.get("scoring_policy") != POLICY
                or not isinstance(case.get("source_id"), str) or not 1 <= len(case["source_id"]) <= 1024
                or case.get("measurement_scope") == "resources_only"):
            raise ValueError("Scored independent mono source/channel/task metadata required")
        audio_identity = dict(path=case.get("audio"), sha256=case.get("sha256"))
        audio = file_identity(audio_identity, check, 4 * 1024 * 1024)
        with wave.open(str(audio), "rb") as stream:
            if stream.getnchannels() != 1 or stream.getsampwidth() != 2 or stream.getframerate() != 16000:
                raise ValueError("Same mono PCM16 16kHz input required")
            seconds = stream.getnframes() / 16000
        common.bounded(seconds, 1 / 16000, 60, "Audio duration")
        duration = common.bounded(case.get("duration_seconds"), 1 / 16000, 60, "Source duration")
        if abs(duration - seconds) > 1 / 16000:
            raise ValueError("Source duration differs from unchanged audio")
        reference = dict(path=case.get("reference"), sha256=case.get("reference_sha256"))
        read_text(reference, check)
        qwen = entry.get("qwen", {})
        request_raw, request = json_identity(qwen.get("request", {}), check)
        expected_request = dict(schema_version=adapter.VERSION, case_id=case["id"], source_language=case["language"],
                                language_mode=key[1], adapter_sha256=plan["adapter_sha256"],
                                common_helper_sha256=plan["common_helper_sha256"])
        if any(request.get(k) != v for k, v in expected_request.items()) or request.get("audio") != audio_identity:
            raise ValueError("Qwen first request differs from original source/case/mode/code")
        adapter.generation_kwargs(request)  # validates no oracle language in auto
        if type(request.get("max_tokens")) is not int or not 1 <= request["max_tokens"] <= 2048:
            raise ValueError("Frozen bounded generation settings required")
        output = regular(qwen.get("output"), must_exist=False)
        if output == common.REPO or common.REPO in output.parents or output in outputs:
            raise ValueError("Unique protected first-attempt output required")
        outputs.add(output)
        claim = adapter.claim_path(request)
        if claim in claims:
            raise ValueError("Qwen cells must have distinct frozen first-attempt claims")
        claims.add(claim)
        if qwen.get("state_sha256") is not None:
            common.digest(qwen["state_sha256"])
        selected.append(dict(entry=entry, case=case, request=request, request_raw=request_raw, output=output,
                             reference=reference, seconds=seconds))
    return raw, plan, dict(corpus_raw=corpus_raw, corpus_case_count=len(corpus_index), matrices=matrices,
                           matrix_raw=matrix_raw, selected=selected)


def qwen_outcome(cell, check):
    entry, case, request, output = (cell[k] for k in ("entry", "case", "request", "output"))
    qwen = entry["qwen"]
    if qwen.get("state_sha256") is None:
        return dict(status="missing", reason="First outcome unsealed/missing; later discovery forbidden")
    _, state = json_identity(dict(path=str(output / "state.json"), sha256=qwen["state_sha256"]), check)
    request_sha = qwen["request"]["sha256"]
    if any(state.get(k) != v for k, v in dict(schema_version=adapter.VERSION + "-run", request_sha256=request_sha,
            case_id=case["id"], language_mode=entry["language_mode"], inference_retries=0, full_application_comparison=False).items()):
        raise ValueError("First Qwen state identity/retry mismatch")
    if type(state.get("inference_retries")) is not int:
        raise ValueError("Explicit zero first-attempt retry count required")
    if state.get("status") != "completed_with_review":
        return dict(status=state.get("status", "unknown"), reason="First Qwen attempt not completed; no replacement", state_sha256=qwen["state_sha256"])
    if state.get("stage") != "finished":
        raise ValueError("Completed Qwen state is partial")
    shutdown = state.get("shutdown", {})
    if any(shutdown.get(k) != v for k, v in dict(returncode=0, child_reaped=True, owned_group_present=False,
            owned_session_workers_present=False, shutdown_errors=[], signals=[]).items()):
        raise ValueError("Qwen worker/session shutdown incomplete or unexpected")
    json_identity(dict(path=str(output / "request.original.json"), sha256=request_sha), check)
    _, claim = common.raw_json(regular(str(adapter.claim_path(request))))
    if claim.get("request_sha256") != request_sha or claim.get("output") != str(output) or claim.get("fixed_deadline_utc") != request.get("deadline_utc"):
        raise ValueError("Not the claimed original Qwen attempt")
    started, ended, claimed, deadline = (common.timestamp(v) for v in (state.get("started_utc"), state.get("ended_utc"),
                                                claim.get("claimed_utc"), request.get("deadline_utc")))
    if not started <= claimed <= ended <= deadline or state.get("deadline_utc") != request.get("deadline_utc"):
        raise ValueError("First Qwen attempt exceeded/changed its frozen deadline")
    _, result = json_identity(dict(path=str(output / "result.json"), sha256=state.get("result_sha256")), check)
    _, complete = common.raw_json(regular(str(output / "worker.complete.json")))
    if complete != dict(result_sha256=state["result_sha256"], request_sha256=request_sha, inputs_unchanged=True):
        raise ValueError("Qwen postflight completion receipt missing/mismatched")
    required = dict(schema_version=adapter.VERSION + "-result", status="completed_with_review", engine="mlx-audio/qwen3_asr",
                    case_id=case["id"], source_language=case["language"], language_mode=entry["language_mode"],
                    source_sha256=case["sha256"], model_repo=adapter.MODEL_REPO, model_revision=adapter.MODEL_REVISION,
                    runtime_repo=adapter.RUNTIME_REPO, runtime_revision=adapter.RUNTIME_REVISION, runtime_version=adapter.RUNTIME_VERSION,
                    model_inventory_sha256=request.get("model_inventory", {}).get("sha256"),
                    runtime_inventory_sha256=request.get("runtime_inventory", {}).get("sha256"),
                    generation_settings=adapter.generation_kwargs(request), effective_language_prompt=adapter.language_argument(case["language"], entry["language_mode"]),
                    quality_approval=False, reference_generated=False, post_correction=False)
    if any(result.get(k) != v for k, v in required.items()) or "engine_passes" in result:
        raise ValueError("External model/runtime/source/settings identity mismatch")
    for role in ("model", "runtime"):
        _, inventory = json_identity(dict(path=str(output / (role + ".inventory.original.json")), sha256=required[role + "_inventory_sha256"]), check, adapter.MAX_MANIFEST)
        fields = dict(repo_id=adapter.MODEL_REPO, revision=adapter.MODEL_REVISION) if role == "model" else dict(repo_id=adapter.RUNTIME_REPO, source_revision=adapter.RUNTIME_REVISION)
        if inventory.get("schema_version") != "qwen-local-inventory-v1" or any(inventory.get(k) != v for k, v in fields.items()):
            raise ValueError("Retained model/runtime inventory source mismatch")
    hypothesis = dict(path=str(output / "hypothesis.txt"), sha256=common.digest(result.get("hypothesis_sha256")))
    read_text(hypothesis, check)
    _, backend = common.raw_json(regular(str(output / "backend-result.original.json")))
    if not isinstance(backend.get("text"), str) or hashlib.sha256(backend["text"].encode()).hexdigest() != hypothesis["sha256"]:
        raise ValueError("Exact raw backend text was not preserved")
    if abs(common.bounded(result.get("source_audio_seconds"), 1 / 16000, 60, "Qwen source duration") - cell["seconds"]) > 1 / 16000:
        raise ValueError("Qwen source duration mismatch")
    if type(result.get("possible_token_limit")) is not bool:
        raise ValueError("Retain the backend token-limit uncertainty")
    timings = result.get("component_timings", {})
    for key in ("backend_import_and_metadata_seconds", "backend_load_call_seconds", "pcm_to_backend_array_seconds", "backend_generate_call_seconds"):
        common.bounded(timings.get(key), 0, 600, "Qwen component timer")
    return dict(status="completed_with_review", hypothesis=hypothesis, result_sha256=state["result_sha256"],
                state_sha256=qwen["state_sha256"], possible_token_limit=result.get("possible_token_limit"),
                identity={k: result[k] for k in ("engine", "model_repo", "model_revision", "runtime_repo", "runtime_revision",
                                               "runtime_version", "model_inventory_sha256", "runtime_inventory_sha256", "generation_settings")},
                resources=dict(component_timings=timings, mlx_allocator_peak_since_before_load_bytes=result.get("mlx_allocator_peak_since_before_load_bytes"),
                               memory_scope=result.get("mlx_memory_scope"), timing_scope=result.get("timing_scope"),
                               first_result_latency_seconds=None, full_system_initialization_seconds=None, total_unified_gpu_memory_bytes=None))


def native_outcome(control, cell, matrix):
    case, mode, identity = cell["case"], cell["entry"]["language_mode"], control["identity"]
    rows = [r for r in matrix["rows"] if r.get("id") == case["id"] and r.get("model") == identity["model"]
            and r.get("profile") == identity["profile"] and r.get("language_mode") == mode
            and r.get("path") == "final" and type(r.get("repeat")) is int and r.get("repeat") == 1]
    if not rows:
        return dict(status="missing", reason="Missing native first-repeat/final cell; later repeats forbidden")
    if len(rows) != 1:
        raise ValueError("Duplicate native first-attempt cell")
    row = rows[0]
    required = dict(identity, language=case["language"], task=case["task"], source_channel=case["source_channel"],
                    source_sha256=case["sha256"], reference_sha256=case["reference_sha256"], scoring_policy=POLICY)
    if any(row.get(k) != v for k, v in required.items()):
        raise ValueError("Native first case/source/reference/runtime identity mismatch")
    measurement = row.get("measurement") or {}
    if row.get("status") not in common.STATUS_COMPLETE or measurement.get("status") not in common.STATUS_COMPLETE:
        return dict(status=row.get("status", "unknown"), reason="Native first attempt not completed; no replacement")
    for key in ("id", "language", "task", "source_sha256", "reference_sha256"):
        if measurement.get(key) != row.get(key):
            raise ValueError("Native measurement/source identity mismatch")
    if row.get("measurement_scope") == "resources_only" or measurement.get("measurement_scope") == "resources_only":
        raise ValueError("Resource-only native cell cannot supply quality")
    passes = measurement.get("engine_passes")
    if not isinstance(passes, list) or len(passes) != 1:
        raise ValueError("One direct native Whisper pass required")
    native = passes[0]
    common.digest(row.get("effective_profile_sha256"))
    if (row["effective_profile_sha256"] != identity["runtime_settings_sha256"]
            or common.engine_observations(passes, row) != 1
            or type(row.get("engine_identity_observations")) is not int or row["engine_identity_observations"] != 1
            or row.get("runner_sha256") != identity["transcription_runner_sha256"]):
        raise ValueError("Native actual decoding/VAD/runner observations differ from the retained control")
    argument = "auto" if mode == "auto" else case["language"].split("-", 1)[0]
    if (native.get("engine") != "whisper.cpp" or native.get("model_sha256") != identity["model_sha256"]
            or native.get("binary_sha256") != identity["whisper_binary_sha256"] or native.get("asr_language") != argument
            or native.get("language_policy", {}).get("effective_argument") != argument
            or "channel_regions" in native or any(v in ("-tr", "--translate") for v in native.get("command", []))):
        raise ValueError("Native engine/language/transcription identity mismatch")
    return dict(status="completed_with_review", metrics=metrics(measurement, case["language"]), identity=identity,
                hypothesis_sha256=common.digest(measurement.get("hypothesis_sha256")),
                configuration=dict(threads=row.get("threads"), effective_profile_sha256=row.get("effective_profile_sha256"),
                    vad_model_sha256=row.get("vad_model_sha256"), preparation_policy=row.get("preparation_policy"),
                    decoding=native.get("decoding"), speech=native.get("speech"), language_policy=native.get("language_policy")),
                resources=dict(wall_seconds=measurement.get("wall_seconds"), peak_rss_bytes=measurement.get("peak_rss_bytes"),
                    memory_scope=measurement.get("memory_method"), upstream_runtime_measurements=measurement.get("engine_runtime_measurements", []),
                    timing_scope="Retained RecScribe native application-job wall and upstream invocation timers; not MLX component calls",
                    first_result_latency_seconds=None, full_system_initialization_seconds=None, total_unified_gpu_memory_bytes=None))


def scorer_workers(session):
    """Only groups in the new scorer SID, never the collector/guard's groups."""
    if type(session) is not int or session <= 0 or session == os.getsid(0):
        raise ValueError("A separately created owned scorer session is required")
    snapshot = subprocess.run(["/bin/ps", "-axo", "pid,pgid"], capture_output=True, text=True, timeout=1, check=True)
    lines = snapshot.stdout.splitlines()
    if snapshot.stderr.strip() or len(snapshot.stdout.encode()) > 1024 * 1024 or not 2 <= len(lines) <= 16385 or "PID" not in lines[0] or "PGID" not in lines[0]:
        raise ValueError("Scorer session membership snapshot unavailable")
    groups = {}
    for line in lines[1:]:
        fields = line.split()
        if len(fields) != 2 or not all(value.isdigit() for value in fields):
            raise ValueError("Ambiguous scorer session membership")
        pid, group = map(int, fields)
        if pid <= 0 or group <= 0 or pid == os.getpid():
            continue
        try:
            if os.getsid(pid) == session:
                if group == os.getpgrp():
                    raise ValueError("Owned scorer unexpectedly shares the controller group")
                groups.setdefault(group, set()).add(pid)
        except ProcessLookupError:
            pass
    return groups


def reap_scorer(child, folder):
    # Popen(start_new_session=True) created SID=child.pid. Recheck every target
    # just before signalling; separately grouped descendants are included.
    errors, sent, session = [], [], child.pid
    if child.poll() is None:
        (folder / "cancel.request").touch(exist_ok=True)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            groups = scorer_workers(session)
            if not groups and child.poll() is not None:
                break
            for group, members in groups.items():
                verified = []
                for pid in members:
                    try:
                        if os.getsid(pid) == session and os.getpgid(pid) == group:
                            verified.append(pid)
                    except ProcessLookupError:
                        pass
                if verified:
                    try:
                        os.killpg(group, number)
                        sent.append(dict(signal=int(number), process_group=group, verified_members=verified))
                    except ProcessLookupError:
                        pass
            until = time.monotonic() + 1
            while time.monotonic() < until:
                child.poll()
                if not scorer_workers(session):
                    break
                time.sleep(.05)
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))
    try:
        if child.poll() is None:
            child.kill()  # Direct Popen child is always owned, even if ps fails.
        child.wait(timeout=1)
    except Exception as error:
        errors.append("direct_reap:" + type(error).__name__)
    try:
        present = bool(scorer_workers(session))
    except Exception as error:
        present = None; errors.append("final_probe:" + type(error).__name__)
    return dict(returncode=child.returncode, child_reaped=child.returncode is not None,
                owned_session_workers_present=present, shutdown_errors=errors, signals=sent,
                cleanup_scope="All verified groups in the separately created scorer SID")


def score(cell, qwen, plan, folder, state, check):
    case = cell["case"]
    reference, hypothesis = cell["reference"], qwen["hypothesis"]
    scorer = file_identity(plan["scorer"], check, 128 * 1024 * 1024)
    read_text(reference, check); read_text(hypothesis, check)
    child_output, marker = folder / "score", folder / "cancel.request"
    command = [str(scorer), "--reference", reference["path"], "--reference-sha256", reference["sha256"],
               "--hypothesis", hypothesis["path"], "--hypothesis-sha256", hypothesis["sha256"],
               "--language", case["language"], "--output", str(child_output), "--duration-seconds", str(cell["seconds"]),
               "--max-seconds", str(plan["per_score_seconds"]), "--cancel-marker", str(marker)]
    state.update(status="running", stage="scoring", command=command)
    common.save(folder / "state.json", state)  # persist BEFORE invoking the scorer
    child, shutdown = None, None
    started = time.monotonic()
    try:
        check()
        with (folder / "scorer.console.log").open("xb") as stream:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                                     start_new_session=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
            state["scorer_pid"] = child.pid
            common.save(folder / "state.json", state)
            while child.poll() is None:
                check()
                if time.monotonic() - started > plan["per_score_seconds"] or (folder / "scorer.console.log").stat().st_size > MAX_LOG:
                    raise RuntimeError("Scorer exceeded its per-case time/log budget; no retry")
                time.sleep(.05)
            check()
            if (folder / "scorer.console.log").stat().st_size > MAX_LOG:
                raise RuntimeError("Scorer console exceeded its bounded budget")
            if child.returncode:
                raise RuntimeError("Scorer failed; partial output retained, no retry")
    finally:
        if child is not None:
            shutdown = reap_scorer(child, folder)
            state["shutdown"] = shutdown
            common.save(folder / "state.json", state)
    if (not shutdown or shutdown.get("returncode") != 0 or not shutdown.get("child_reaped")
            or shutdown.get("owned_session_workers_present") is not False or shutdown.get("shutdown_errors") or shutdown.get("signals")):
        raise RuntimeError("Scorer owned-session cleanup incomplete or unexpected")
    check()
    _, result = common.raw_json(regular(str(child_output / "score.json")))
    if any(result.get(k) != v for k, v in dict(bridge_version="external-transcript-score-v1", source_language=case["language"],
            reference_sha256=reference["sha256"], hypothesis_sha256=hypothesis["sha256"], quality_approval=False, reference_corrected=False).items()):
        raise ValueError("Scorer receipt/source/policy identity mismatch")
    if case["language"].split("-", 1)[0] == "zh" and any(result.get(k) is not None for k in
            ("wer", "word_errors", "word_insertions", "word_deletions", "word_substitutions", "reference_words")):
        raise ValueError("Chinese native-v1 reporting must remain CER-only")
    for original, snapshot in ((reference, "reference.original.txt"), (hypothesis, "hypothesis.original.txt")):
        read_text(dict(path=str(child_output / snapshot), sha256=original["sha256"]), check)
        read_text(original, check)
    file_identity(plan["scorer"], check, 128 * 1024 * 1024)
    return metrics(result, case["language"]), common.hash_file(child_output / "score.json", check)[0]


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        for control, observation in row["native"].items():
            groups[(control, row["language"], row["language_mode"])].append((row, observation))
    result = []
    for (control, language, mode), cells in sorted(groups.items()):
        pairs = [(row, native) for row, native in cells if row.get("pair_status", {}).get(control) == "paired"]
        value = dict(control=control, language=language, language_mode=mode, planned_cells=len(cells), paired_cells=len(pairs),
                     planned_source_units=len({row["source_id"] for row, _ in cells}),
                     paired_source_units=len({row["source_id"] for row, _ in pairs}),
                     completeness="complete" if len(pairs) == len(cells) else "pending", cer=None, wer=None)
        for metric in METRICS:
            if not pairs or (metric == "wer" and language.split("-", 1)[0] == "zh"):
                continue
            before = {key: sum(native["metrics"][metric][key] for _, native in pairs) for key in ("errors", "units", "insertions", "deletions", "substitutions")}
            after = {key: sum(row["qwen"]["metrics"][metric][key] for row, _ in pairs) for key in before}
            value[metric] = dict(native=before, qwen=after, native_rate=before["errors"] / before["units"],
                                 qwen_rate=after["errors"] / after["units"], paired_rate_delta=(after["errors"] - before["errors"]) / before["units"])
        result.append(value)
    return result


def collect(path, expected, output):
    raw, preliminary = common.raw_json(regular(str(path)), expected)
    seconds = common.bounded(preliminary.get("max_seconds"), 1, 3600, "Collection budget")
    deadline = time.monotonic() + min(seconds, (common.timestamp(preliminary.get("deadline_utc")) - common.utcnow()).total_seconds())
    root = common.new_output(output)
    state = dict(schema_version=VERSION + "-run", plan_sha256=expected, started_utc=common.utcnow().isoformat(),
                 deadline_utc=preliminary["deadline_utc"], status="running", stage="validating", inference_performed=False, retries=0)
    common.save(root / "state.json", state)
    requested, previous, rows, controls = {"signal": None}, {}, [], []
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, lambda sig, frame: requested.update(signal=sig))
    def check():
        if requested["signal"] is not None or (root / "cancel.request").exists():
            raise InterruptedError("Quality collection cancelled")
        if time.monotonic() >= deadline or common.utcnow() >= common.timestamp(preliminary["deadline_utc"]):
            raise TimeoutError("Fixed quality collection deadline exhausted")
    try:
        check()
        raw, plan, validated = validate_plan(path, expected, check)
        common.write_new(adapter.claim_path(plan), common.encoded(dict(plan_sha256=expected, output=str(root),
                         claimed_utc=common.utcnow().isoformat(), fixed_deadline_utc=plan["deadline_utc"])))
        common.write_new(root / "plan.original.json", raw)
        common.write_new(root / "corpus.original.json", validated["corpus_raw"])
        for identifier, native_raw in validated["matrix_raw"].items():
            common.write_new(root / ("native-" + identifier + ".original.json"), native_raw)
        controls = plan["controls"]
        for cell in validated["selected"]:
            case, entry = cell["case"], cell["entry"]
            rows.append(dict(id=case["id"], source_id=case["source_id"], source_channel=case["source_channel"],
                       language=case["language"], language_mode=entry["language_mode"], task=case["task"],
                       source_sha256=case["sha256"], reference_sha256=case["reference_sha256"],
                       scoring_policy=POLICY, qwen=dict(status="not_started"),
                       native={c["id"]: dict(status="not_started") for c in controls},
                       pair_status={c["id"]: "missing" for c in controls}, collection_status="not_started"))
        common.write_new(root / "planned-cells.json", common.encoded(rows))
        for index, cell in enumerate(validated["selected"]):
            check()
            case, entry = cell["case"], cell["entry"]
            folder = root / ("cell-" + str(index)); folder.mkdir(mode=0o700)
            local = dict(status="running", stage="collecting", id=case["id"], language_mode=entry["language_mode"])
            common.save(folder / "state.json", local)
            row = rows[index]
            row.update(collection_status="running", evidence_directory=folder.name)
            try:
                try:
                    row["qwen"] = qwen_outcome(cell, check)
                    if row["qwen"]["status"] == "completed_with_review":
                        row["qwen"]["metrics"], row["qwen"]["score_sha256"] = score(cell, row["qwen"], plan, folder, local, check)
                except (InterruptedError, TimeoutError):
                    raise
                except Exception as error:
                    row["qwen"].update(status="invalid_or_failed", reason=type(error).__name__ + ": " + str(error))
                    row["qwen"].pop("metrics", None)
                for control in plan["controls"]:
                    check()
                    identifier = control["id"]
                    try:
                        native = native_outcome(control, cell, validated["matrices"][control["matrix_id"]])
                        row["native"][identifier] = native
                        row["pair_status"][identifier] = "missing"
                        if "metrics" in row["qwen"] and "metrics" in native:
                            if any(row["qwen"]["metrics"][metric]["units"] != native["metrics"][metric]["units"]
                                   for metric in METRICS if row["qwen"]["metrics"][metric] is not None):
                                raise ValueError("Cross-backend reference denominators differ")
                            row["pair_status"][identifier] = "paired"
                    except (InterruptedError, TimeoutError):
                        raise
                    except Exception as error:
                        row["native"][identifier] = dict(status="invalid", reason=type(error).__name__ + ": " + str(error))
                        row["pair_status"][identifier] = "invalid"
                local.update(status="collected", stage="finished")
                row["collection_status"] = "collected"
            except BaseException as error:
                local.update(status="cancelled" if isinstance(error, InterruptedError) else "deadline_exhausted" if isinstance(error, TimeoutError) else "failed",
                             error=type(error).__name__ + ": " + str(error))
                row["collection_status"] = local["status"]
                raise
            finally:
                common.save(folder / "state.json", local)
                common.write_new(folder / "observation.json", common.encoded(row))
        check()
        # Revalidate every frozen input after scoring, before publishing counts.
        validate_plan(path, expected, check)
        for cell, row in zip(validated["selected"], rows):
            check()
            if "metrics" in row["qwen"]:
                qwen_outcome(cell, check)
        report = dict(schema_version="external-backend-quality-v1", plan_sha256=expected, scoring_policy=POLICY,
                      recognition_task="transcribe", rows=rows, comparisons=summarize(rows),
                      corpus_case_count=validated["corpus_case_count"], selected_original_cases=len({r["id"] for r in rows}),
                      planned_case_mode_cells=len(rows), completeness_scope="Frozen selected plan cells only; full corpus/language/mode campaign completeness is not inferred",
                      quality_approval=False, reference_review="NOT_ASSESSED", product_acceptance="NOT_AUTHORIZED",
                      inference_performed=False, source_unit_independence="Unknown speaker/session dependence; utterance counts are not independent populations",
                      resource_comparison="Backend-specific timing/memory scopes only; no cross-backend latency, RSS or unified-GPU equivalence inferred",
                      missing_policy="Original first attempts only; incomplete cells remain pending; no rerun or replacement",
                      word_reporting_policy="Chinese CER only; unchanged native legacy-v1 normalization")
        report["status"] = "collected" if all(v["completeness"] == "complete" for v in report["comparisons"]) else "collected_with_gaps"
        common.write_new(root / "report.json", common.encoded(report))
        state.update(status=report["status"], stage="finished", report_sha256=common.hash_file(root / "report.json", check)[0])
        return report
    except BaseException as error:
        state.update(status="cancelled" if isinstance(error, InterruptedError) else "deadline_exhausted" if isinstance(error, TimeoutError) else "failed",
                     error=type(error).__name__ + ": " + str(error))
        raise
    finally:
        state["ended_utc"] = common.utcnow().isoformat()
        state["planned_cells"] = len(rows)
        state["collected_cells"] = sum(row.get("collection_status") == "collected" for row in rows)
        try:
            if state["status"] in ("cancelled", "deadline_exhausted", "failed") and rows:
                try:
                    common.write_new(root / "partial-report.json", common.encoded(dict(schema_version="external-backend-quality-v1-partial",
                        status=state["status"], plan_sha256=expected, rows=rows, comparisons=summarize(rows),
                        quality_approval=False, inference_performed=False, missing_policy="Unstarted/cancelled/failed first cells remain pending")))
                except Exception as error:
                    state["partial_report_error"] = type(error).__name__ + ": " + str(error)
            common.save(root / "state.json", state)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("validate", "collect"))
    parser.add_argument("--plan", required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    try:
        if args.operation == "validate":
            _, preliminary = common.raw_json(regular(args.plan), args.plan_sha256)
            seconds = common.bounded(preliminary.get("max_seconds"), 1, 3600, "Validation budget")
            until = time.monotonic() + seconds
            def check():
                if time.monotonic() >= until or common.utcnow() >= common.timestamp(preliminary.get("deadline_utc")):
                    raise TimeoutError("Frozen validation deadline exhausted")
            validate_plan(args.plan, args.plan_sha256, check)
            print('{"status":"validated","inference_performed":false}')
        else:
            if not args.output:
                parser.error("collect requires one new protected --output")
            report = collect(args.plan, args.plan_sha256, args.output)
            print(common.encoded(dict(status=report["status"], cells=len(report["rows"]), quality_approval=False)).decode(), end="")
            return 0 if report["status"] == "collected" else 2
    except Exception as error:
        print("Collection failed: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
