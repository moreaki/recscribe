#!/usr/bin/env python3
"""One local, SHA-bound Qwen3-ASR research case; no native Whisper emulation.

Wrap `run` in the existing recording-priority guard after fresh native idle
admission. Outputs belong in a NEW protected external directory. MLX imports
occur only in the bounded owned worker, after local inventories are verified.
"""
import argparse
from datetime import datetime, timezone
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
import wave

COMMON_PATH = Path(__file__).with_name("controlled-panel.py")
_SPEC = importlib.util.spec_from_file_location("qwen_resource_common", COMMON_PATH)
common = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(common)
VERSION = "qwen-asr-case-v1"
MODEL_REPO = "mlx-community/Qwen3-ASR-1.7B-8bit"
MODEL_REVISION = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
RUNTIME_REPO = "Neywa-Labs/mlx-audio"
RUNTIME_REVISION = "3e2368ef96e686ad6c2c8791272bd25617d3e71e"
RUNTIME_VERSION = "0.6.5"
LANGUAGES = {"de": "German", "fr": "French", "it": "Italian", "en": "English",
             "ar": "Arabic", "zh": "Chinese", "es": "Spanish", "pt": "Portuguese"}
MAX_MANIFEST = 16 * 1024 * 1024
MAX_TEXT = 1024 * 1024
OFFLINE = {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1",
           "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1", "PYTHONDONTWRITEBYTECODE": "1",
           "TOKENIZERS_PARALLELISM": "false"}


def read_manifest(path, expected):
    with Path(path).open("rb") as stream:
        raw = stream.read(MAX_MANIFEST + 1)
    if len(raw) > MAX_MANIFEST or common.hashlib.sha256(raw).hexdigest() != common.digest(expected):
        raise ValueError("Inventory exceeds 16 MiB or differs from its explicit SHA-256")
    return raw, common.decode(raw)


def language_argument(language, mode):
    if not isinstance(language, str) or not re.fullmatch(r"[a-z]{2}(?:-[A-Za-z0-9]{2,8})*", language):
        raise ValueError("Explicit priority-language source label required")
    base = language.split("-", 1)[0]
    if base not in LANGUAGES or mode not in ("known", "auto"):
        raise ValueError("Unsupported source language or language mode")
    # Source labels never become an oracle prompt in automatic mode.
    return LANGUAGES[base] if mode == "known" else None


def claim_path(request):
    value = request.get("claim_path")
    if not isinstance(value, str):
        raise ValueError("Freeze one absolute single-use execution claim path")
    path = Path(value).expanduser()
    if not path.is_absolute() or ".." in path.parts or not path.parent.is_dir() or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Execution claim needs an existing protected non-symlink parent")
    if path == common.REPO or common.REPO in path.parents:
        raise ValueError("Execution claims belong outside the checkout")
    return path


def validate_inventory(identity, role, python_target, check):
    raw, inventory = read_manifest(identity["path"], identity["sha256"])
    if inventory.get("schema_version") != "qwen-local-inventory-v1":
        raise ValueError("Unsupported local inventory")
    root = common.absolute(inventory.get("root"))
    if not root.is_dir():
        raise ValueError("Inventory root must be a complete local directory")
    files = inventory.get("files")
    limit = 1024 if role == "model" else 65536
    if not isinstance(files, list) or not 1 <= len(files) <= limit:
        raise ValueError("Inventory has an invalid bounded file count")
    expected, actual, ignored_links = {}, set(), []
    for item in files:
        relative = item.get("path")
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute() or ".." in Path(relative).parts or relative in expected:
            raise ValueError("Unique safe relative inventory paths required")
        if type(item.get("bytes")) is not int or not 0 <= item["bytes"] <= common.MAX_INPUT_BYTES:
            raise ValueError("Inventory needs bounded exact byte lengths")
        common.digest(item.get("sha256")); expected[relative] = item
    for path in root.rglob("*"):
        check()
        if path.is_symlink():
            relative = str(path.relative_to(root))
            interpreter_alias = (role == "runtime" and path.parent == root / "bin"
                                 and re.fullmatch(r"python(?:[0-9]+(?:\.[0-9]+)?t?)?", path.name)
                                 and path.resolve(strict=True) == python_target)
            if not interpreter_alias:
                raise ValueError("Uninventoried/symlinked runtime or model input: " + relative)
            ignored_links.append(dict(path=relative, resolved_target=str(python_target)))
            continue
        if path.is_file():
            actual.add(str(path.relative_to(root)))
    if actual != set(expected):
        raise ValueError("Inventory is not the exact complete local file set")
    total = 0
    for relative, item in expected.items():
        value, size = common.hash_file(root / relative, check)
        if value != item["sha256"] or size != item["bytes"]:
            raise ValueError("Inventoried file changed: " + relative)
        total += size
    if role == "model":
        if inventory.get("repo_id") != MODEL_REPO or inventory.get("revision") != MODEL_REVISION:
            raise ValueError("The model inventory uses a different repository/revision")
        required = {"config.json", "tokenizer_config.json", "preprocessor_config.json"}
        tokenizer_complete = "tokenizer.json" in actual or {"vocab.json", "merges.txt"} <= actual
        if not required <= actual or not tokenizer_complete or not any(name.endswith(".safetensors") for name in actual):
            raise ValueError("Complete local model, tokenizer and feature-extractor files are required")
    elif inventory.get("source_revision") != RUNTIME_REVISION or inventory.get("repo_id") != RUNTIME_REPO:
        raise ValueError("Runtime inventory does not declare the pinned source revision")
    return dict(root=str(root), files=len(files), bytes=total, inventory_sha256=identity["sha256"],
                ignored_interpreter_aliases=ignored_links, metadata=inventory), raw


def validate_request(path, expected, check=lambda: None):
    raw, request = common.raw_json(path, expected)
    if request.get("schema_version") != VERSION or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", request.get("case_id", "")):
        raise ValueError("A versioned single-case request and safe case ID are required")
    language_argument(request.get("source_language"), request.get("language_mode"))
    claim_path(request)
    if type(request.get("max_tokens")) is not int or not 1 <= request["max_tokens"] <= 2048:
        raise ValueError("Choose a fixed maximum of 1–2048 generated tokens")
    common.bounded(request.get("max_seconds"), 1, 600, "Case seconds")
    common.timestamp(request.get("deadline_utc"))
    if request.get("capture_inactive_attestation") is not True or not isinstance(request.get("workload_attestation"), str) or not request["workload_attestation"].strip():
        raise ValueError("An outer native idle/workload admission is required; never interrupt capture")
    common.verify_lock(dict(role="adapter", path=str(Path(__file__).resolve()), sha256=common.digest(request.get("adapter_sha256")), bytes=Path(__file__).stat().st_size), check)
    if common.hash_file(COMMON_PATH, check)[0] != common.digest(request.get("common_helper_sha256")):
        raise ValueError("Resource helper differs from the frozen request")
    python = request.get("python", {})
    # Retain the venv path for launch. Resolving it for argv would select global Python.
    executable = Path(python.get("path", "")).expanduser()
    if not executable.is_absolute() or not os.access(executable, os.X_OK):
        raise ValueError("Use an explicit installed isolated Python executable")
    target = executable.resolve(strict=True)
    if common.hash_file(target, check)[0] != common.digest(python.get("sha256")):
        raise ValueError("Python executable differs from its resolved SHA-256")
    audio_identity = request.get("audio", {})
    audio = common.absolute(audio_identity.get("path"))
    if audio.stat().st_size > 2 * 16000 * 60 + 1024 * 1024:
        raise ValueError("Audio file exceeds the 60-second PCM/metadata bound")
    if common.hash_file(audio, check)[0] != common.digest(audio_identity.get("sha256")):
        raise ValueError("Source audio differs from its frozen hash")
    with wave.open(str(audio), "rb") as stream:
        channels, width, rate, frames = stream.getnchannels(), stream.getsampwidth(), stream.getframerate(), stream.getnframes()
        if channels != 1 or width != 2 or rate != 16000 or stream.getcomptype() != "NONE" or not 1 <= frames <= 16000 * 60:
            raise ValueError("Use one original case view: mono PCM16 WAV, 16kHz, at most60 seconds")
        if len(stream.readframes(frames + 1)) != frames * 2:
            raise ValueError("Audio frame count is inconsistent")
    model, model_raw = validate_inventory(request["model_inventory"], "model", target, check)
    runtime, runtime_raw = validate_inventory(request["runtime_inventory"], "runtime", target, check)
    return request, raw, dict(audio=str(audio), audio_frames=frames, audio_seconds=frames / rate,
                             python_path=str(executable), python_resolved=str(target), model=model, runtime=runtime), (model_raw, runtime_raw)


def install_offline_policy():
    os.environ.update(OFFLINE)
    def audit(event, args):
        if event in {"socket.connect", "socket.getaddrinfo"}:
            raise RuntimeError("Network access is disabled for this local research worker")
    sys.addaudithook(audit)


def verify_installed_runtime(validated):
    root = Path(validated["runtime"]["root"])
    expected_prefix = Path(validated["runtime"]["metadata"].get("venv_path", root)).resolve(strict=True)
    if Path(sys.prefix).resolve() != expected_prefix:
        raise ValueError("Worker is not running in the inventoried isolated environment")
    versions = validated["runtime"]["metadata"].get("package_versions")
    if not isinstance(versions, dict) or not 1 <= len(versions) <= 256 or versions.get("mlx-audio") != RUNTIME_VERSION:
        raise ValueError("Runtime inventory must declare actual pinned package versions")
    for name, version in versions.items():
        if importlib.metadata.version(name) != version:
            raise ValueError("Installed package version changed: " + name)
    distribution = importlib.metadata.distribution("mlx-audio")
    direct = distribution.read_text("direct_url.json")
    if direct is None or common.decode(direct).get("vcs_info", {}).get("commit_id") != RUNTIME_REVISION:
        raise ValueError("Install mlx-audio from its exact pinned Git commit")
    for name in ("mlx_audio", "mlx", "numpy", "transformers", "scipy"):
        spec = importlib.util.find_spec(name)
        paths = ([spec.origin] if spec and spec.origin and spec.origin != "namespace" else []) + list(spec.submodule_search_locations or []) if spec else []
        if not paths or any(not (Path(p).resolve() == root or root in Path(p).resolve().parents) for p in paths):
            raise ValueError("Import resolves outside the inventoried runtime: " + name)
    return versions


def generation_kwargs(request):
    return dict(language=language_argument(request["source_language"], request["language_mode"]),
                max_tokens=request["max_tokens"], batch_size=1, temperature=0.0, top_p=1.0, top_k=0,
                min_p=0.0, repetition_penalty=None, prefill_step_size=2048,
                chunk_duration=60.0, min_chunk_duration=1.0, stream=False, verbose=False,
                system_prompt=None, hotwords=None)


def budget_remaining(request, monotonic_deadline):
    # Recheck UTC at every poll too: a forward clock jump cannot run past the
    # frozen absolute deadline, and a backward jump cannot extend monotonic time.
    return min(monotonic_deadline - time.monotonic(),
               (common.timestamp(request["deadline_utc"]) - common.utcnow()).total_seconds())


class MLXBackend:
    def __init__(self, validated):
        self.versions = verify_installed_runtime(validated)
        import mlx.core as mx
        import numpy as np
        from transformers import AutoTokenizer, WhisperFeatureExtractor
        model_root = Path(validated["model"]["root"])
        for factory in (AutoTokenizer, WhisperFeatureExtractor):
            original = factory.from_pretrained
            def local_loader(cls, path, *args, _original=original, **kwargs):
                if Path(path).resolve(strict=True) != model_root:
                    raise ValueError("Tokenizer/feature extractor must use the exact inventoried model directory")
                kwargs["local_files_only"] = True
                return _original(path, *args, **kwargs)
            factory.from_pretrained = classmethod(local_loader)
        from mlx_audio.stt.utils import load_model
        self.mx, self.np, self.load_model = mx, np, load_model
        self.device = str(mx.default_device())
        self.metal_available = bool(mx.metal.is_available())
        if not self.metal_available or "gpu" not in self.device.lower():
            raise ValueError("The frozen Mac comparison requires the Metal backend; no silent CPU fallback")

    def load(self, model_root):
        self.mx.reset_peak_memory()
        model = self.load_model(Path(model_root), lazy=False, strict=True)
        self.mx.synchronize()
        if ".qwen3_asr." not in type(model).__module__:
            raise ValueError("Local model loaded an unexpected architecture")
        return model

    def audio(self, source):
        with wave.open(source, "rb") as stream:
            raw = stream.readframes(stream.getnframes())
        return self.np.frombuffer(raw, dtype="<i2").astype(self.np.float32) / 32768.0

    def generate(self, model, audio, kwargs):
        result = model.generate(audio, **kwargs)
        self.mx.synchronize()
        return {name: getattr(result, name) for name in ("text", "segments", "language", "prompt_tokens", "generation_tokens",
                                                       "total_tokens", "prompt_tps", "generation_tps", "total_time")}

    def peak(self):
        return int(self.mx.get_peak_memory())


def perform(request, validated, root, check, backend_factory=MLXBackend):
    timings = {}
    started = time.monotonic(); backend = backend_factory(validated)
    timings["backend_import_and_metadata_seconds"] = time.monotonic() - started
    check()
    started = time.monotonic(); model = backend.load(validated["model"]["root"])
    timings["backend_load_call_seconds"] = time.monotonic() - started
    peak_loaded = backend.peak()
    check()
    started = time.monotonic(); audio = backend.audio(validated["audio"])
    timings["pcm_to_backend_array_seconds"] = time.monotonic() - started
    check()
    started = time.monotonic(); result = backend.generate(model, audio, generation_kwargs(request))
    timings["backend_generate_call_seconds"] = time.monotonic() - started
    peak = backend.peak()
    if not isinstance(result, dict) or not isinstance(result.get("text"), str) or len(result["text"].encode()) > MAX_TEXT:
        raise ValueError("Backend returned invalid/oversized recognized text")
    check()
    # Preserve exactly the backend-returned text; do not normalize or correct it.
    common.write_new(root / "backend-result.original.json", common.encoded(result))
    common.write_new(root / "hypothesis.txt", result["text"].encode("utf-8"))
    tokens = result.get("generation_tokens")
    capped = type(tokens) is int and tokens >= request["max_tokens"]
    metadata = dict(schema_version=VERSION + "-result", case_id=request["case_id"], engine="mlx-audio/qwen3_asr",
                    model_repo=MODEL_REPO, model_revision=MODEL_REVISION, runtime_repo=RUNTIME_REPO,
                    runtime_revision=RUNTIME_REVISION, runtime_version=RUNTIME_VERSION,
                    model_inventory_sha256=request["model_inventory"]["sha256"],
                    runtime_inventory_sha256=request["runtime_inventory"]["sha256"],
                    conversion_card_example_runtime="0.3.1; distinct from this pinned0.6.5 evaluation runtime",
                    source_sha256=request["audio"]["sha256"], source_language=request["source_language"],
                    language_mode=request["language_mode"], effective_language_prompt=generation_kwargs(request)["language"],
                    generation_settings=generation_kwargs(request), detected_language=result.get("language"),
                    raw_language_status="Unreviewed backend label; no dialect/switch/confidence claim",
                    hypothesis_sha256=common.hashlib.sha256(result["text"].encode()).hexdigest(),
                    status="completed_with_review", possible_token_limit=capped,
                    package_versions=backend.versions, component_timings=timings,
                    backend_model_class=type(model).__module__ + "." + type(model).__qualname__,
                    backend_device=getattr(backend, "device", None), metal_available=getattr(backend, "metal_available", None),
                    inference_python_version=sys.version, inference_python_prefix=sys.prefix, host_platform=platform.platform(),
                    source_audio_frames=validated["audio_frames"], source_audio_seconds=validated["audio_seconds"],
                    model_directory_file_bytes=validated["model"]["bytes"],
                    safetensors_weight_file_bytes=sum(item["bytes"] for item in validated["model"]["metadata"]["files"] if item["path"].endswith(".safetensors")),
                    inventoried_runtime_file_bytes=validated["runtime"]["bytes"],
                    mlx_allocator_peak_after_load_bytes=peak_loaded, mlx_allocator_peak_since_before_load_bytes=peak,
                    mlx_memory_scope="Observed MLX allocator high-water bytes only; excludes total unified GPU/system memory",
                    first_result_latency_seconds=None, full_system_initialization_seconds=None, total_unified_gpu_memory_bytes=None,
                    total_initialization_seconds=None,
                    timestamp_accuracy=None, word_alignment_status="Backend chunk boundaries retained; no word alignment inferred",
                    timing_scope="External MLX component calls; not RecScribe/whisper application-job latency",
                    local_only_policy="Local Path model loader; local_files_only tokenizer/extractor; offline HF/Transformers; Python socket audit",
                    recording_priority="Fresh native idle/workload admission and continuous guard are required externally",
                    quality_approval=False, reference_generated=False, post_correction=False)
    common.write_new(root / "result.json", common.encoded(metadata))
    return metadata


def worker(request_path, expected, root):
    root = common.absolute(str(root))
    _, state = common.raw_json(root / "state.json")
    if state.get("parent_pid") != os.getppid() or state.get("request_sha256") != expected or state.get("stage") != "worker_scheduled":
        raise ValueError("Worker requires its owning supervisor and retained scheduled state")
    install_offline_policy()
    _, preliminary = common.raw_json(request_path, expected)
    deadline = min(state["monotonic_deadline"], time.monotonic() + (common.timestamp(preliminary["deadline_utc"]) - common.utcnow()).total_seconds())
    def check():
        if (root / "cancel.request").exists():
            raise InterruptedError("Worker cancelled")
        if budget_remaining(preliminary, deadline) <= 0:
            raise TimeoutError("Frozen Qwen case deadline exhausted")
    request, _, validated, _ = validate_request(request_path, expected, check)
    check()
    result = perform(request, validated, root, check)
    validate_request(request_path, expected, check)
    common.write_new(root / "worker.complete.json", common.encoded(dict(result_sha256=common.hash_file(root / "result.json", check)[0],
                                                                      request_sha256=expected, inputs_unchanged=True)))
    return result


def owned_session_workers(session):
    if session != os.getpid() or os.getsid(0) != session or os.getpgrp() != session:
        raise ValueError("Cleanup requires the directly guarded adapter's own session")
    snapshot = subprocess.run(["/bin/ps", "-axo", "pid,pgid"], capture_output=True, text=True, timeout=1, check=True)
    lines = snapshot.stdout.splitlines()
    if snapshot.stderr.strip() or len(snapshot.stdout.encode()) > 1024 * 1024 or not 2 <= len(lines) <= 16385 or "PID" not in lines[0] or "PGID" not in lines[0]:
        raise ValueError("Owned group snapshot unavailable")
    groups = {}
    for line in lines[1:]:
        fields = line.split()
        if len(fields) != 2 or not all(value.isdigit() for value in fields):
            raise ValueError("Ambiguous owned group snapshot")
        pid, pgid = map(int, fields)
        # PID0 has special os.getsid/os.kill semantics (the caller), not an
        # ordinary kernel-process identity. Never classify/signal it as a child.
        if pid <= 0 or pgid <= 0 or pid == os.getpid():
            continue
        try:
            if os.getsid(pid) == session:
                groups.setdefault(pgid, set()).add(pid)
        except ProcessLookupError:
            pass
    return groups


def reap(child, root, session):
    errors, signals = [], []
    if child.poll() is None:
        (root / "cancel.request").touch(exist_ok=True)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            groups = owned_session_workers(session)
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
                if not verified:
                    continue
                try:
                    if group == os.getpgrp():
                        # Never signal our own process group. If a descendant
                        # joined it, target only its separately verified PID.
                        for pid in verified:
                            os.kill(pid, number)
                    else:
                        os.killpg(group, number)
                    signals.append(dict(signal=int(number), process_group=group, verified_members=verified))
                except ProcessLookupError:
                    pass
            until = time.monotonic() + 1
            while time.monotonic() < until:
                child.poll()
                if not owned_session_workers(session):
                    break
                time.sleep(.05)
        except ProcessLookupError:
            pass
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))
    try:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=1)
    except Exception as error:
        errors.append("direct_reap:" + type(error).__name__)
    try:
        present = bool(owned_session_workers(session))
    except Exception as error:
        present = None; errors.append("final_probe:" + type(error).__name__)
    return dict(returncode=child.returncode, child_reaped=child.returncode is not None,
                owned_group_present=present, owned_session_workers_present=present,
                cleanup_scope="All worker groups in this directly guarded SID; controller excluded",
                shutdown_errors=errors, signals=signals)


def supervise(request_path, expected, output, worker_command=None):
    request_path = common.absolute(str(request_path))
    raw, preliminary = common.raw_json(request_path, expected)
    seconds = common.bounded(preliminary.get("max_seconds"), 1, 600, "Case seconds")
    deadline = min(time.monotonic() + seconds, time.monotonic() + (common.timestamp(preliminary.get("deadline_utc")) - common.utcnow()).total_seconds())
    if os.getsid(0) != os.getpid() or os.getpgrp() != os.getpid():
        raise ValueError("Wrap each adapter run directly in run-guard.py; an ancestor orchestrator's session is insufficient")
    root = common.new_output(output)
    state = dict(schema_version=VERSION + "-run", request_sha256=expected, parent_pid=os.getpid(),
                 owned_session=os.getsid(0),
                 case_id=preliminary.get("case_id"), language_mode=preliminary.get("language_mode"),
                 started_utc=common.utcnow().isoformat(), deadline_utc=preliminary["deadline_utc"],
                 monotonic_deadline=deadline,
                 status="running", stage="validating", inference_retries=0, full_application_comparison=False)
    common.save(root / "state.json", state)
    requested = {"signal": None}; previous = {}
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, lambda sig, frame: requested.update(signal=sig))
    def check():
        if requested["signal"] is not None or (root / "cancel.request").exists():
            raise InterruptedError("Qwen case cancelled")
        if budget_remaining(preliminary, deadline) <= 0:
            raise TimeoutError("Frozen Qwen deadline/runtime budget exhausted")
    child = None
    try:
        check()
        request, _, validated, inventories = validate_request(request_path, expected, check)
        common.write_new(claim_path(request), common.encoded(dict(
            request_sha256=expected, output=str(root), claimed_utc=common.utcnow().isoformat(),
            fixed_deadline_utc=request["deadline_utc"])))
        for name, data in (("request.original.json", raw), ("model.inventory.original.json", inventories[0]), ("runtime.inventory.original.json", inventories[1])):
            common.write_new(root / name, data)
        command = worker_command or [validated["python_path"], "-I", "-B", str(Path(__file__).resolve()), "worker",
                                     "--request", str(request_path), "--request-sha256", expected, "--output", str(root)]
        state.update(stage="worker_scheduled", command=command, audio_frames=validated["audio_frames"], audio_seconds=validated["audio_seconds"],
                     model_inventory_sha256=request["model_inventory"]["sha256"], runtime_inventory_sha256=request["runtime_inventory"]["sha256"],
                     inference_python_path=validated["python_path"], inference_python_resolved=validated["python_resolved"])
        common.save(root / "state.json", state)
        env = dict(os.environ, **OFFLINE)
        with (root / "worker.console.log").open("xb") as log:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                     env=env, process_group=0)
            state["worker_pid"] = child.pid
            common.save(root / "state.json", state)
            try:
                while child.poll() is None:
                    check()
                    if (root / "worker.console.log").stat().st_size > 2 * 1024 * 1024:
                        raise ValueError("Worker console exceeded 2 MiB")
                    time.sleep(.1)
                check()
                if child.returncode:
                    raise RuntimeError("Owned Qwen worker failed; evidence retained, no retry")
            finally:
                state["shutdown"] = reap(child, root, os.getsid(0))
                common.save(root / "state.json", state)
                child = None
        shutdown = state["shutdown"]
        if not shutdown["child_reaped"] or shutdown["owned_group_present"] is not False or shutdown["shutdown_errors"] or shutdown["signals"]:
            raise RuntimeError("Owned worker shutdown was incomplete or unexpected")
        _, completed = common.raw_json(root / "worker.complete.json")
        if completed.get("request_sha256") != expected or completed.get("inputs_unchanged") is not True or completed.get("result_sha256") != common.hash_file(root / "result.json", check)[0]:
            raise ValueError("Worker completion does not bind retained output/input identities")
        _, result = common.raw_json(root / "result.json")
        required = dict(source_sha256=request["audio"]["sha256"], engine="mlx-audio/qwen3_asr", case_id=request["case_id"],
                        model_repo=MODEL_REPO, model_revision=MODEL_REVISION, runtime_repo=RUNTIME_REPO,
                        runtime_revision=RUNTIME_REVISION, runtime_version=RUNTIME_VERSION,
                        model_inventory_sha256=request["model_inventory"]["sha256"],
                        runtime_inventory_sha256=request["runtime_inventory"]["sha256"],
                        source_language=request["source_language"], language_mode=request["language_mode"],
                        generation_settings=generation_kwargs(request))
        if any(result.get(key) != value for key, value in required.items()):
            raise ValueError("Worker result used different source/model/runtime/language/settings identities")
        if (root / "hypothesis.txt").stat().st_size > MAX_TEXT or common.hash_file(root / "hypothesis.txt", check)[0] != result.get("hypothesis_sha256"):
            raise ValueError("Raw recognized text differs from retained result identity")
        state.update(status="completed_with_review", stage="finished", result_sha256=completed["result_sha256"])
        check()
    except BaseException as error:
        state.update(status="cancelled" if isinstance(error, InterruptedError) else "deadline_exhausted" if isinstance(error, TimeoutError) else "failed",
                     error=type(error).__name__ + ": " + str(error))
        if child is not None:
            state["shutdown"] = reap(child, root, os.getsid(0))
        raise
    finally:
        state["ended_utc"] = common.utcnow().isoformat()
        common.save(root / "state.json", state)
        for number, handler in previous.items():
            signal.signal(number, handler)
    return state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("run", "worker"))
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--request-sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = supervise(args.request, args.request_sha256, args.output) if args.operation == "run" else worker(args.request, args.request_sha256, args.output)
        print(json.dumps(dict(status=result.get("status"), case_id=result.get("case_id"), raw_text_printed=False)))
        return 0
    except (ValueError, OSError, KeyError, TypeError, RuntimeError, TimeoutError, InterruptedError, wave.Error) as error:
        if args.output.is_dir() and not (args.output / "failure.json").exists():
            common.write_new(args.output / "failure.json", common.encoded(dict(error=type(error).__name__, detail=str(error))))
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
