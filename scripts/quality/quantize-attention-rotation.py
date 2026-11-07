#!/usr/bin/env python3
"""Export pinned official Q4_0 artifacts and independently audit their containers.

No recognition, training or Python quantizer. Run serially under run-guard.py.
--model is the original F16 for plain_q4, or the hash-bound rotated intermediate
for rotated_q4. Both roles retain the untouched --parent/--parent-sha256.
Rotated exports additionally require hashed rotation-plan/audit and completed
--plain-control audit metadata. That descriptor names the one Q4 control model
which is rehashed, never any audio/reference/hypothesis paths.

Use a new external --output directory. Original/intermediate/control files are
read-only; failures retain partial output and logs. Native compatibility and all
quality/resource acceptance remain pending after static export success.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import stat
import struct
import subprocess
import sys
import time

NUMERIC_ENVIRONMENT = {key: "1" for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
                                          "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS")}
# Set before any optional NumPy import in the shared finite-statistics helper.
# The quantizer receives the same fixed values through an explicit child env.
for _key, _value in NUMERIC_ENVIRONMENT.items(): os.environ[_key] = _value

SPEC = importlib.util.spec_from_file_location("_attention_q4_weights", Path(__file__).with_name("ggml_weights.py"))
weights = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = weights
SPEC.loader.exec_module(weights)

VERSION = "attention-rotation-official-q4-v1"
STATIC_VERSION = "whisper-q4_0-container-audit-v1"
ROTATION_VERSION = "whisper-attention-rotation-v1"
PARSER_SHA256 = "11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3"
ROTATION_GENERATOR_SHA256 = "fcf21056cc0c0b1b39d21d43139398efbcf794e948d8c89a78e5f260832bae30"
QUANTIZER = Path("/opt/homebrew/bin/whisper-quantize")
QUANTIZER_SHA256 = "2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd"
MAX_MODEL_BYTES = 4 * 1024 ** 3
MAX_METADATA_BYTES = 8 * 1024 ** 2
MAX_LOG_BYTES = 32 * 1024 ** 2
BLOCK_BYTES = 256 * 1024
Q4_BLOCK_ELEMENTS, Q4_BLOCK_BYTES, Q4_TYPE, Q4_FTYPE = 32, 18, 2, 2002
LIMITS = weights.Limits(model_bytes=MAX_MODEL_BYTES)
SKIP = {"encoder.positional_embedding", "decoder.positional_embedding", "encoder.conv1.bias", "encoder.conv2.bias"}
ORIGINALS = {
    "small": ("1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", 487601967, 768, 12, 12, 12, 80, 51865),
    "large-v3-turbo": ("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", 1624555275, 1280, 20, 32, 4, 128, 51866),
}
SUFFIXES = {"query.weight": ("output_rows", "qk"), "query.bias": ("bias", "qk"),
            "key.weight": ("output_rows", "qk"), "value.weight": ("output_rows", "vo"),
            "value.bias": ("bias", "vo"), "out.weight": ("input_columns", "vo")}


def require(value, message):
    if not value: raise ValueError(message)


def valid_sha(value):
    return isinstance(value, str) and len(value) == 64 and all(v in "0123456789abcdef" for v in value)


def regular(path):
    require(isinstance(path, (str, os.PathLike)), "Explicit local input path required")
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and not any(p.is_symlink() for p in (path, *path.parents)),
            "Use an absolute nonsymlink input path")
    status = path.stat()
    require(stat.S_ISREG(status.st_mode), "Input must be a regular local file")
    return path


def identity(path):
    return weights.file_identity(Path(path).stat())


def bound_artifact(path, expected, expected_bytes, check):
    path = regular(path); before = identity(path)
    require(valid_sha(expected) and type(expected_bytes) is int and 0 < expected_bytes <= MAX_MODEL_BYTES
            and before[2] == expected_bytes, "Bound artifact size/checksum metadata differs")
    require(weights.hash_file(path, check, expected_bytes) == expected and identity(path) == before,
            "Bound artifact checksum/identity differs")
    return path, before


def read_metadata(path, expected):
    path = regular(path)
    require(valid_sha(expected), "Metadata checksum required")
    before = identity(path)
    require(before[2] <= MAX_METADATA_BYTES, "Metadata exceeds its explicit bound")
    with path.open("rb") as source: data = source.read(MAX_METADATA_BYTES + 1)
    require(len(data) <= MAX_METADATA_BYTES and identity(path) == before and hashlib.sha256(data).hexdigest() == expected,
            "Metadata checksum/identity differs")
    def fields(items):
        value = {}
        for key, item in items:
            require(key not in value, "Duplicate metadata key")
            value[key] = item
        return value
    def invalid(_): raise ValueError("Nonfinite metadata constant")
    value = json.loads(data, object_pairs_hook=fields, parse_constant=invalid)
    require(isinstance(value, dict), "Metadata must be a JSON object")
    return value


def external_output(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and path.parent.is_dir() and not path.exists()
            and not any(p.is_symlink() for p in (path, *path.parents)), "Use a new absolute nonsymlink external output")
    require(not any((p / ".git").exists() or (p / ".git").is_symlink() for p in (path, *path.parents)),
            "Model artifacts must be outside every Git checkout")
    here = Path(__file__).resolve()
    if here.parent.name == "quality" and here.parent.parent.name == "scripts":
        repo = here.parents[2]
        require(path != repo and repo not in path.parents, "Model artifacts must be outside the source archive")
    return path


def hash_range(stream, offset, count, check):
    stream.seek(offset); digest = hashlib.sha256()
    while count:
        check(); block = stream.read(min(BLOCK_BYTES, count))
        require(bool(block), "Truncated tensor payload")
        digest.update(block); count -= len(block)
    return digest.hexdigest()


def audit_q4(source, quantized, check=weights.no_cancel):
    """Walk Q4 bytes independently, using only inspected original F16 layout.

    The official exporter quantizes every eligible 2-D tensor, including token
    embeddings. A Q4_0 block has one finite signed half scale and 16 packed bytes.
    Passthrough tensors and the non-ftype header/mel/vocabulary stay exact.
    This proves the container contract, not quantization accuracy or model loading.
    """
    quantized = regular(quantized); initial = identity(quantized)
    require(0 < initial[2] <= MAX_MODEL_BYTES, "Q4 artifact exceeds its explicit size bound")
    weights.verify_model_source(source, check, hash_content=False)
    first = source.tensors[0]
    prefix_end = first.offset - 12 - 4 * len(first.shape) - len(first.name.encode("utf-8"))
    require(48 < prefix_end <= 40 * 1024 ** 2, "Invalid bounded mel/vocabulary prefix")
    tensors, blocks, copied, prefix_digest = [], 0, 0, hashlib.sha256()
    with source.path.open("rb") as original, quantized.open("rb") as target:
        require(weights.file_identity(os.fstat(target.fileno())) == initial, "Q4 file changed before audit")
        def read(count):
            check()
            require(type(count) is int and count >= 0 and target.tell() + count <= initial[2], "Truncated Q4 container")
            data = target.read(count)
            require(len(data) == count, "Truncated Q4 container")
            return data
        before, after = original.read(48), read(48)
        require(len(before) == 48 and before[:44] == after[:44] and struct.unpack("<i", before[44:])[0] == 1
                and struct.unpack("<i", after[44:])[0] == Q4_FTYPE, "Q4 architecture/header/ftype differs")
        prefix_digest.update(before[:44]); remaining = prefix_end - 48
        while remaining:
            check(); count = min(BLOCK_BYTES, remaining); left, right = original.read(count), read(count)
            require(len(left) == count and left == right, "Q4 changed raw mel/vocabulary prefix")
            prefix_digest.update(left); remaining -= count
        for tensor in source.tensors:
            rank, name_bytes, kind = struct.unpack("<3i", read(12))
            require(rank == len(tensor.shape) and 1 <= rank <= 4 and 0 < name_bytes <= LIMITS.tensor_name_bytes,
                    "Q4 tensor rank/name bound differs")
            shape = struct.unpack("<" + "i" * rank, read(4 * rank))
            try: name = read(name_bytes).decode("utf-8")
            except UnicodeDecodeError as error: raise ValueError("Invalid Q4 tensor name encoding") from error
            require(shape == tensor.shape and name == tensor.name, "Q4 dropped/reordered/renamed/reshaped a tensor")
            offset, digest = target.tell(), hashlib.sha256()
            quantize = rank == 2 and name not in SKIP
            if quantize:
                require(kind == Q4_TYPE and shape[0] % Q4_BLOCK_ELEMENTS == 0 and tensor.elements % Q4_BLOCK_ELEMENTS == 0,
                        "Wrong Q4_0 tensor type/block geometry")
                remaining = tensor.elements // Q4_BLOCK_ELEMENTS
                while remaining:
                    check(); count = min(8192, remaining); data = read(count * Q4_BLOCK_BYTES); digest.update(data)
                    require(all(math.isfinite(scale) for scale, _packed in struct.iter_unpack("<e16s", data)),
                            "Nonfinite Q4_0 half scale")
                    remaining -= count; blocks += count
                payload_bytes = tensor.elements // Q4_BLOCK_ELEMENTS * Q4_BLOCK_BYTES
            else:
                require(kind == tensor.type_id, "Q4 changed passthrough dtype")
                original.seek(tensor.offset); remaining = tensor.bytes
                while remaining:
                    check(); count = min(BLOCK_BYTES, remaining); data = read(count)
                    require(original.read(count) == data, "Q4 changed passthrough tensor bytes")
                    digest.update(data); remaining -= count; copied += count
                payload_bytes = tensor.bytes
            tensors.append({"name": name, "shape": list(shape), "type_id": kind, "source_type_id": tensor.type_id,
                            "offset": offset, "elements": tensor.elements, "payload_bytes": payload_bytes,
                            "payload_sha256": digest.hexdigest(), "quantized": quantize})
        require(target.tell() == initial[2], "Q4 has extra tensors/trailing bytes")
        require(weights.file_identity(os.fstat(target.fileno())) == initial, "Q4 file changed during audit")
    require(identity(quantized) == initial, "Q4 file identity changed")
    weights.verify_model_source(source, check, hash_content=False)
    return {"schema_version": STATIC_VERSION, "ftype": Q4_FTYPE, "type_id": Q4_TYPE, "block_elements": Q4_BLOCK_ELEMENTS,
            "block_bytes": Q4_BLOCK_BYTES, "model_file_bytes": initial[2], "finite_q4_blocks": blocks,
            "exact_passthrough_bytes": copied, "tensor_count": len(tensors), "tensors": tensors,
            "prefix_end": prefix_end, "preserved_prefix_sha256": prefix_digest.hexdigest(), "file_identity": list(initial),
            "architecture_mel_vocabulary_unchanged": True, "quantization_correctness_or_native_loading_claimed": False}


def attention_targets(architecture):
    sites = [f"encoder.blocks.{i}.attn" for i in range(architecture["n_audio_layer"])]
    sites += [f"decoder.blocks.{i}.{kind}" for i in range(architecture["n_text_layer"]) for kind in ("attn", "cross_attn")]
    return {site + "." + suffix: (operation, pair) for site in sites for suffix, (operation, pair) in SUFFIXES.items()}


def validate_original(model, model_id, expected):
    require(model_id in ORIGINALS and valid_sha(expected), "Supported original model and exact checksum required")
    sha, size, state, heads, encoder, decoder, mels, vocab = ORIGINALS[model_id]
    require(model.source_sha256 == expected == sha and model.bytes == size, "Untouched original identity differs")
    required = {"n_audio_state": state, "n_text_state": state, "n_audio_head": heads, "n_text_head": heads,
                "n_audio_layer": encoder, "n_text_layer": decoder, "n_mels": mels, "n_vocab": vocab, "ftype": 1}
    require(all(model.architecture.get(k) == v for k, v in required.items()), "Original model architecture differs")


def validate_rotation(parent, intermediate, model_id, plan, plan_sha, audit, check=weights.no_cancel):
    require(plan.get("schema_version") == audit.get("schema_version") == ROTATION_VERSION
            and plan.get("model_id") == audit.get("model_id") == model_id
            and plan.get("source_sha256") == audit.get("source_sha256") == parent.source_sha256
            and audit.get("state") == "completed" and audit.get("derived_sha256") == intermediate.source_sha256
            and audit.get("rotation_plan_sha256") == plan_sha and audit.get("file_bytes") == parent.bytes == intermediate.bytes
            and audit.get("architecture") == parent.architecture == intermediate.architecture
            and audit.get("outside_declared_changed_bytes") == 0 and type(audit.get("outside_declared_changed_bytes")) is int
            and audit.get("training_used") is False and audit.get("fitting_used") is False and audit.get("seed_search_used") is False
            and audit.get("parser_sha256") == PARSER_SHA256 and audit.get("generator_sha256") == ROTATION_GENERATOR_SHA256,
            "Rotation audit does not bind the original/intermediate/fixed recipe")
    require(parent.tensors == intermediate.tensors and parent.vocabulary_sha256 == intermediate.vocabulary_sha256
            and intermediate.source_sha256 != parent.source_sha256, "Rotation changed layout/vocabulary or made no artifact edit")
    state, heads = parent.architecture["n_text_state"], parent.architecture["n_text_head"]
    require(type(plan.get("head_channels")) is int and plan["head_channels"] == 64 and plan.get("state") == state
            and plan.get("head_count") == heads and state == 64 * heads
            and plan.get("seed_search") is False and plan.get("fitting") is False
            and type(plan.get("runtime_operations_added")) is int and plan["runtime_operations_added"] == 0,
            "Unexpected rotation geometry/search/runtime recipe")
    domain = b"recscribe-whisper-attention-rotation-v1\0"
    require(plan.get("domain_hex") == domain.hex()
            and plan.get("mask_encoding") == "domain+sha_raw32+site_ASCII+NUL+head_u32LE+pair_ASCII"
            and plan.get("sign_encoding") == "first8_SHA256_bytes_in_order; channel_j=byte[j//8]_bit[j%8]_LSB_first;1=-1;0=+1"
            and plan.get("matrix") == "normalized_Sylvester_H64_times_diagonal_signs; H64_coefficients=+/-1/8",
            "Unexpected fixed rotation encoding")
    targets = attention_targets(parent.architecture); expected_sites = {name.rsplit(".", 2)[0] for name in targets}
    records = plan.get("sites")
    require(isinstance(records, list) and len(records) == len(expected_sites), "Incomplete/extra rotation sites")
    observed = set()
    for record in records:
        require(isinstance(record, dict) and set(record) == {"site", "heads"} and record["site"] in expected_sites
                and record["site"] not in observed, "Duplicate/unexpected rotation site")
        site = record["site"]; observed.add(site)
        groups = record["heads"]
        require(isinstance(groups, list) and len(groups) == 2 * heads, "Incomplete rotation head masks")
        seen = set()
        for group in groups:
            require(isinstance(group, dict) and set(group) == {"head", "pair", "sha256", "mask_first8_hex"}
                    and type(group["head"]) is int and 0 <= group["head"] < heads and group["pair"] in {"qk", "vo"},
                    "Invalid rotation head mask")
            key = (group["head"], group["pair"]); require(key not in seen, "Duplicate rotation head mask"); seen.add(key)
            digest = hashlib.sha256(domain + bytes.fromhex(parent.source_sha256) + site.encode("ascii") + b"\0"
                                    + struct.pack("<I", key[0]) + key[1].encode("ascii")).digest()
            require(group["sha256"] == digest.hex() and group["mask_first8_hex"] == digest[:8].hex(), "Rotation mask recipe differs")
    edits = audit.get("edits")
    require(isinstance(edits, list) and len(edits) == len(targets), "Rotation audit target count differs")
    seen, ranges, changed = set(), [], 0
    with parent.path.open("rb") as original, intermediate.path.open("rb") as rotated:
        for edit in edits:
            name = edit.get("tensor") if isinstance(edit, dict) else None
            require(name in targets and name not in seen, "Duplicate/unexpected rotation tensor edit"); seen.add(name)
            tensor = parent.tensor(name); operation, pair = targets[name]
            require(edit.get("shape") == list(tensor.shape) and edit.get("dtype") == tensor.dtype
                    and edit.get("operation") == operation and edit.get("pair") == pair
                    and type(edit.get("changed_elements")) is int and 0 <= edit["changed_elements"] <= tensor.elements
                    and edit.get("selected_elements") == tensor.elements, "Rotation tensor edit descriptor differs")
            require(hash_range(original, tensor.offset, tensor.bytes, check) == edit.get("before_sha256")
                    and hash_range(rotated, tensor.offset, tensor.bytes, check) == edit.get("after_sha256"),
                    "Rotation tensor payload binding differs")
            changed += edit["changed_elements"]; ranges.append((tensor.offset, tensor.offset + tensor.bytes))
    require(changed > 0 and type(audit.get("selected_tensor_count")) is int and audit["selected_tensor_count"] == len(targets)
            and type(audit.get("selected_elements")) is int
            and audit["selected_elements"] == sum(parent.tensor(name).elements for name in targets),
            "Rotation audit declares no changes or mismatched selected-element budget")
    unchanged = weights.unchanged_regions_equal(parent.path, intermediate.path, parent.bytes, ranges, check)
    require(unchanged == audit.get("unchanged_regions_sha256"), "Rotation outside-target proof differs")
    return {"target_tensor_names": sorted(targets), "target_count": len(targets), "unchanged_regions_sha256": unchanged,
            "parent_sha256": parent.source_sha256, "intermediate_sha256": intermediate.source_sha256,
            "rotation_plan_sha256": plan_sha, "target_payload_bindings_verified": True}


def compare_plain_control(plain, static, targets, model_id, parent_sha):
    require(plain.get("schema_version") == VERSION and plain.get("state") == "completed" and plain.get("role") == "plain_q4"
            and plain.get("model_id") == model_id and plain.get("parent_sha256") == parent_sha
            and plain.get("input_sha256") == parent_sha and plain.get("quantizer_sha256") == QUANTIZER_SHA256
            and plain.get("kind") == "compression" and plain.get("parent_original_id") == model_id
            and plain.get("parent_original_sha256") == parent_sha
            and plain.get("quantization") == {"format": "q4_0", "ftype": 2, "file_header_ftype": Q4_FTYPE},
            "Plain Q4 control identity differs")
    before = plain.get("static_validation", {})
    require(before.get("schema_version") == static.get("schema_version") == STATIC_VERSION
            and before.get("ftype") == static.get("ftype") == Q4_FTYPE
            and before.get("model_file_bytes") == static.get("model_file_bytes")
            and before.get("preserved_prefix_sha256") == static.get("preserved_prefix_sha256"),
            "Plain/rotated Q4 sizes or prefix differ")
    a, b = before.get("tensors"), static.get("tensors")
    require(isinstance(a, list) and isinstance(b, list) and len(a) == len(b), "Plain/rotated Q4 tensor counts differ")
    unchanged, changes, seen = 0, [], set()
    for left, right in zip(a, b):
        require(isinstance(left, dict) and isinstance(right, dict)
                and all(left.get(k) == right.get(k) for k in ("name", "shape", "type_id", "source_type_id", "offset", "elements", "payload_bytes", "quantized"))
                and valid_sha(left.get("payload_sha256")) and valid_sha(right.get("payload_sha256")),
                "Plain/rotated Q4 tensor descriptor differs")
        name = right["name"]; require(name not in seen, "Duplicate Q4 comparison tensor"); seen.add(name)
        same = left["payload_sha256"] == right["payload_sha256"]
        if name not in targets:
            require(same, "Unmodified tensor differs between plain/rotated Q4: " + name); unchanged += 1
        else: changes.append({"name": name, "payload_changed": not same})
    require(set(targets) <= seen and len(changes) == len(targets), "Q4 comparison omitted an attention target")
    return {"same_file_bytes": True, "unmodified_tensors_byte_identical": True, "unmodified_tensor_count": unchanged,
            "attention_targets": changes, "changed_attention_target_payloads": sum(v["payload_changed"] for v in changes),
            "interpretation": "Payload hashes compare identical official export rules; no accuracy or extra size gain is inferred"}


def group_members(group, session):
    require(type(group) is int and group > 1 and group != os.getpgrp(), "Invalid owned quantizer process group")
    result = subprocess.run(["/bin/ps", "-axo", "pid,pgid"], capture_output=True, text=True, timeout=.5)
    require(result.returncode == 0 and len(result.stdout) <= 1024 ** 2, "Owned quantizer inventory unavailable")
    members = []
    for line in result.stdout.splitlines()[1:]:
        columns = line.split()
        require(len(columns) == 2 and all(v.isdigit() for v in columns), "Owned quantizer inventory malformed")
        pid, observed_group = map(int, columns)
        if observed_group != group: continue
        try:
            require(os.getsid(pid) == session and os.getpgid(pid) == group, "Quantizer group ownership changed")
            members.append(pid)
        except ProcessLookupError: continue
    return members


def cleanup_quantizer(child, group, session):
    """Signal only the group created for this Popen in our existing owned SID."""
    errors, signals = [], []
    for number, grace in ((signal.SIGINT, .5), (signal.SIGTERM, .5), (signal.SIGKILL, 1)):
        try:
            members = group_members(group, session)
            if not members: break
            # Revalidate immediately before every group signal. Never kill a
            # command-name match, a foreign SID or the wrapper's own group.
            require(all(os.getsid(pid) == session and os.getpgid(pid) == group for pid in members),
                    "Quantizer group ownership changed before signal")
            os.killpg(group, number); signals.append(int(number))
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                child.poll()
                if not group_members(group, session): break
                time.sleep(.025)
        except ProcessLookupError: continue
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            errors.append(type(error).__name__ + ": " + str(error)); break
    # Inventory uncertainty never authorizes a foreign/group-wide signal. The
    # exact Popen remains ours and can still be terminated/reaped directly.
    if child.poll() is None:
        try: child.kill()
        except ProcessLookupError: pass
    try: child.wait(timeout=.5)
    except subprocess.TimeoutExpired: errors.append("Owned quantizer did not reap")
    try: remaining = group_members(group, session)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        remaining = None; errors.append(type(error).__name__ + ": " + str(error))
    return {"process_id": child.pid, "owned_process_group": group, "owned_session": session,
            "returncode": child.returncode, "cli_reaped": child.poll() is not None,
            "owned_group_present": None if remaining is None else bool(remaining),
            "signals": signals, "errors": errors}


def run_quantizer(command, partial, ownership, log_path, check):
    child, group, session, shutdown = None, None, os.getsid(0), None
    env = {**os.environ, **NUMERIC_ENVIRONMENT}
    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(log_fd, "wb") as log:
            check(); weights.require_owned_artifact(partial, ownership)
            # A separate PGID inside the guard-owned SID permits local bounded
            # cleanup while keeping outer recording-priority ownership intact.
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                     env=env, process_group=0)
            group = child.pid
            while True:
                check(); weights.require_owned_artifact(partial, ownership)
                require(partial.stat().st_size <= MAX_MODEL_BYTES and log_path.stat().st_size <= MAX_LOG_BYTES,
                        "Quantizer output/log exceeded its explicit bound")
                if child.poll() is not None: break
                time.sleep(.05)
            require(child.returncode == 0, "Official quantizer exited with code " + str(child.returncode))
        require(not group_members(group, session), "Quantizer left an owned descendant running")
        shutdown = {"process_id": child.pid, "owned_process_group": group, "owned_session": session,
                    "returncode": child.returncode, "cli_reaped": True, "owned_group_present": False,
                    "signals": [], "errors": []}
        return shutdown
    finally:
        if child is not None and shutdown is None:
            shutdown = cleanup_quantizer(child, group, session)
            require(shutdown["cli_reaped"] is True and shutdown["owned_group_present"] is False and not shutdown["errors"],
                    "Owned quantizer cleanup incomplete: " + json.dumps(shutdown))


def run_export(source_path, expected_sha, model_id, role, parent_path, parent_sha, output,
               *, rotation_plan_path=None, rotation_plan_sha=None, rotation_audit_path=None, rotation_audit_sha=None,
               plain_control_path=None, plain_control_sha=None, timeout=600, cancel_marker=None):
    require(model_id in ORIGINALS and role in {"plain_q4", "rotated_q4"} and valid_sha(expected_sha) and valid_sha(parent_sha)
            and type(timeout) is int and 1 <= timeout <= 600, "Unsupported model/role/hash or finite duration")
    output = external_output(output)
    previous, requested = {}, {"value": False}
    start = time.monotonic(); deadline = start + timeout
    markers = [output / "cancel.request"]
    if cancel_marker is not None:
        cancel_marker = Path(cancel_marker)
        require(cancel_marker.is_absolute() and ".." not in cancel_marker.parts, "Absolute cancellation marker required")
        markers.append(cancel_marker)
    def check():
        if requested["value"] or any(p.exists() for p in markers): raise InterruptedError("Q4 export canceled; evidence retained")
        if time.monotonic() >= deadline: raise TimeoutError("Q4 export exceeded its finite duration")
    def stop(_number, _frame): requested["value"] = True
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): previous[number] = signal.signal(number, stop)
    partial, final = output / "model.partial.bin", output / "model.bin"
    created, ownership, plain_control = False, None, None
    audit = {"schema_version": VERSION, "state": "preparing", "role": role, "kind": "compression" if role == "plain_q4" else "combined",
             "model_id": model_id, "created_utc": datetime.now(timezone.utc).isoformat(), "training_used": False,
             "ai_accuracy_gain_claimed": False, "recognition_or_model_initialization_executed": False,
             "quality": "UNMEASURED", "native_compatibility": "PENDING", "resource_acceptance": "NOT_EVALUATED",
             "download_artifact_bytes": None, "incremental_bundle_bytes": None, "timeout_seconds": timeout,
             "maximum_input_or_output_bytes": MAX_MODEL_BYTES,
             "numeric_worker_environment": {key: os.environ[key] for key in NUMERIC_ENVIRONMENT},
             "quantization": {"format": "q4_0", "ftype": 2, "file_header_ftype": Q4_FTYPE},
             "original_open_mode": "read_only", "default_promotion": False}
    try:
        check()
        require(weights.hash_file(Path(weights.__file__), check) == PARSER_SHA256, "Unquantized parser checksum differs")
        source_path, parent_path = regular(source_path), regular(parent_path)
        binary = QUANTIZER.resolve(strict=True)
        require(stat.S_ISREG(binary.stat().st_mode) and os.access(binary, os.X_OK)
                and weights.hash_file(binary, check) == QUANTIZER_SHA256, "Pinned official quantizer differs")
        binary_identity = identity(binary)
        parent = weights.inspect_model(parent_path, limits=LIMITS, check=check)
        validate_original(parent, model_id, parent_sha)
        source = parent if source_path == parent_path else weights.inspect_model(source_path, limits=LIMITS, check=check)
        require(source.source_sha256 == expected_sha and source.architecture == parent.architecture
                and source.bytes == parent.bytes and source.tensors == parent.tensors, "F16 input identity/layout differs")
        audit.update(input=str(source.path), input_sha256=expected_sha, input_file_bytes=source.bytes,
                     parent=str(parent.path), parent_sha256=parent_sha, parent_file_bytes=parent.bytes,
                     parent_original_id=model_id, parent_original_sha256=parent_sha,
                     quantizer=str(binary), quantizer_sha256=QUANTIZER_SHA256, quantizer_file_identity=list(binary_identity),
                     generator_sha256=weights.hash_file(Path(__file__), check), parser_sha256=PARSER_SHA256,
                     input_file_identity=list(source.source_identity), parent_file_identity=list(parent.source_identity))
        if role == "plain_q4":
            require(source.path == parent.path and expected_sha == parent_sha
                    and all(v is None for v in (rotation_plan_path, rotation_plan_sha, rotation_audit_path, rotation_audit_sha,
                                               plain_control_path, plain_control_sha)),
                    "Plain Q4 must export the untouched parent without rotation/control metadata")
        else:
            require(all(v is not None for v in (rotation_plan_path, rotation_plan_sha, rotation_audit_path, rotation_audit_sha,
                                               plain_control_path, plain_control_sha)), "Rotated Q4 requires rotation and plain-control bindings")
            plan = read_metadata(rotation_plan_path, rotation_plan_sha)
            rotation = read_metadata(rotation_audit_path, rotation_audit_sha)
            audit["rotation_validation"] = validate_rotation(parent, source, model_id, plan, rotation_plan_sha, rotation, check)
            audit.update(rotation_plan={"path": str(rotation_plan_path), "sha256": rotation_plan_sha},
                         rotation_audit={"path": str(rotation_audit_path), "sha256": rotation_audit_sha},
                         plain_control={"path": str(plain_control_path), "sha256": plain_control_sha})
            plain_control = read_metadata(plain_control_path, plain_control_sha)
            control_sha = plain_control.get("derived_sha256")
            require(plain_control.get("model_file_bytes") == plain_control.get("static_validation", {}).get("model_file_bytes"),
                    "Plain Q4 control byte metadata differs")
            control_path, control_identity = bound_artifact(plain_control.get("model_path", ""), control_sha,
                                                           plain_control.get("model_file_bytes"), check)
        # Full original/intermediate finite scans remain bounded by one worker
        # and the caller's deadline; no dense whole-model allocation is used.
        weights.tensor_statistics(parent, check)
        if source.path != parent.path: weights.tensor_statistics(source, check)
        check(); output.mkdir(mode=0o700); created = True
        with partial.open("xb") as stream: os.chmod(partial, 0o600)
        ownership = weights.artifact_identity(partial)
        command = [str(binary), str(source.path), str(partial), "q4_0"]
        audit.update(state="exporting", command=command)
        weights.write_new_json(output / "export-start.json", audit)
        weights.verify_model_source(parent, check)
        if source.path != parent.path: weights.verify_model_source(source, check)
        require(identity(binary) == binary_identity and weights.hash_file(binary, check) == QUANTIZER_SHA256,
                "Quantizer changed before launch")
        audit["owned_quantizer_shutdown"] = run_quantizer(command, partial, ownership, output / "quantization.log", check)
        check(); weights.require_owned_artifact(partial, ownership)
        os.chmod(partial, 0o400)
        static = audit_q4(source, partial, check)
        require(0 < static["model_file_bytes"] < parent.bytes, "Official Q4 must be nonempty and smaller than original F16")
        audit["static_validation"] = static
        if role == "rotated_q4":
            audit["plain_control_comparison"] = compare_plain_control(plain_control, static,
                set(audit["rotation_validation"]["target_tensor_names"]), model_id, parent_sha)
            require(identity(control_path) == control_identity and bound_artifact(control_path, control_sha,
                    plain_control["model_file_bytes"], check)[1] == control_identity,
                    "Plain Q4 control changed during export")
        require(identity(partial) == tuple(static["file_identity"]), "Q4 payload changed after static validation")
        result_sha = weights.hash_file(partial, check, static["model_file_bytes"])
        require(identity(partial) == tuple(static["file_identity"]), "Q4 payload changed while hashing")
        weights.verify_model_source(parent, check)
        if source.path != parent.path: weights.verify_model_source(source, check)
        require(identity(binary) == binary_identity and weights.hash_file(binary, check) == QUANTIZER_SHA256
                and QUANTIZER.resolve(strict=True) == binary, "Quantizer changed during export")
        if role == "rotated_q4":
            read_metadata(rotation_plan_path, rotation_plan_sha); read_metadata(rotation_audit_path, rotation_audit_sha)
            read_metadata(plain_control_path, plain_control_sha)
        audit.update(state="verified", derived_sha256=result_sha, model_file_bytes=static["model_file_bytes"],
                     model_byte_saving_fraction=1 - static["model_file_bytes"] / parent.bytes,
                     original_after_sha256=parent.source_sha256, intermediate_after_sha256=source.source_sha256,
                     quantizer_after_sha256=QUANTIZER_SHA256, model_path=str(final), elapsed_seconds=time.monotonic() - start)
        weights.write_new_json(output / "export-audit.json", audit)
        check(); weights.require_owned_artifact(partial, ownership)
        require(identity(partial) == tuple(static["file_identity"]), "Q4 payload changed before publication")
        os.link(partial, final, follow_symlinks=False)
        weights.require_owned_artifact(final, ownership); partial.unlink(); check()
        audit.update(state="completed", artifact="model.bin")
        weights.update_owned_audit(output / "export-audit.json", audit); check()
        return audit
    except BaseException as error:
        audit.update(state="canceled" if isinstance(error, (InterruptedError, KeyboardInterrupt, TimeoutError)) else "failed",
                     error_type=type(error).__name__, error=str(error))
        if created:
            if ownership is not None and final.exists():
                try:
                    weights.require_owned_artifact(final, ownership)
                    os.link(final, output / "model.failed.bin", follow_symlinks=False); final.unlink()
                except (OSError, ValueError) as failure: audit["quarantine_error"] = str(failure)
            audit["retained_artifacts"] = [p.name for p in (partial, final, output / "model.failed.bin") if p.exists()]
            try:
                path = output / "export-audit.json"
                if path.exists(): weights.update_owned_audit(path, audit)
                else: weights.write_new_json(path, audit)
            except BaseException as failure:
                if hasattr(error, "add_note"): error.add_note("Failed to retain export audit: " + str(failure))
        raise
    finally:
        for number, handler in previous.items(): signal.signal(number, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=Path, required=True); parser.add_argument("--sha256", required=True)
    parser.add_argument("--model-id", choices=sorted(ORIGINALS), required=True)
    parser.add_argument("--role", choices=("plain_q4", "rotated_q4"), required=True)
    parser.add_argument("--parent", type=Path, required=True); parser.add_argument("--parent-sha256", required=True)
    parser.add_argument("--rotation-plan", type=Path); parser.add_argument("--rotation-plan-sha256")
    parser.add_argument("--rotation-audit", type=Path); parser.add_argument("--rotation-audit-sha256")
    parser.add_argument("--plain-control", type=Path); parser.add_argument("--plain-control-sha256")
    parser.add_argument("--output", type=Path, required=True); parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--cancel-marker", type=Path)
    args = parser.parse_args(argv)
    result = run_export(args.model, args.sha256, args.model_id, args.role, args.parent, args.parent_sha256, args.output,
        rotation_plan_path=args.rotation_plan, rotation_plan_sha=args.rotation_plan_sha256,
        rotation_audit_path=args.rotation_audit, rotation_audit_sha=args.rotation_audit_sha256,
        plain_control_path=args.plain_control, plain_control_sha=args.plain_control_sha256,
        timeout=args.timeout, cancel_marker=args.cancel_marker)
    print(json.dumps({key: result[key] for key in ("state", "role", "model_id", "derived_sha256", "model_file_bytes", "elapsed_seconds")}))
    return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except InterruptedError as error: print(str(error), file=sys.stderr); raise SystemExit(130)
    except TimeoutError as error: print(str(error), file=sys.stderr); raise SystemExit(124)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr); raise SystemExit(1)
