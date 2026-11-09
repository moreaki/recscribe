#!/usr/bin/env python3
"""Official Q4 exports with independent, fixed MLP-permutation proofs.

No recognition, fitting or Python quantizer. The unchanged, SHA-pinned round-4
module supplies container parsing and owned export-process cleanup, explicitly
attributed below. This module supplies the new MLP proofs; it never calls the
attention rotation validator or labels this operation as a rotation.

Use exclusive external output directories under the recording-priority guard.
All input/model/reference paths except explicitly bound weight artifacts remain
unfollowed. Weight SSE is descriptive, never a transcription or selection gate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
from importlib.metadata import version as package_version
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import time

NUMERIC_ENVIRONMENT = {key: "1" for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
                                          "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS")}
for _key, _value in NUMERIC_ENVIRONMENT.items(): os.environ[_key] = _value
REUSED_CORE_SHA256 = "bf3f2ef5e00a4c06ef7fd4912c46dd2a0d50f7a381d45fff7cef6c5fae93c4e0"
PARSER_SHA256 = "11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3"
OPERATOR_SHA256 = "0a33ffab0c343b88e1cffa3e571619b414148d4b88673b69fa77386124087122"
OPERATOR_FILE = "mlp-permute.py"
CORE_PATH = Path(__file__).with_name("quantize-attention-rotation.py")
if hashlib.sha256(CORE_PATH.read_bytes()).hexdigest() != REUSED_CORE_SHA256:
    raise ValueError("Reused official-Q4 container/lifecycle source checksum differs")
SPEC = importlib.util.spec_from_file_location("_mlp_reused_q4_core", CORE_PATH)
core = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(core)
weights = core.weights
require, valid_sha = core.require, core.valid_sha
VERSION = "mlp-permutation-official-q4-v1"
PERMUTATION_VERSION = "whisper-mlp-permutation-v1"
ORDERING = {"key": "original_mlp2_column_max_abs_f64", "direction": "ascending",
            "ties": "original_hidden_index", "index_semantics": "new_position_to_original_hidden_index",
            "index_encoding": "u32-le"}
ORIGINALS = core.ORIGINALS
QUANTIZER = core.QUANTIZER
QUANTIZER_SHA256 = core.QUANTIZER_SHA256
LIMITS = core.LIMITS
MAX_LOG_BYTES, MAX_MODEL_BYTES = core.MAX_LOG_BYTES, core.MAX_MODEL_BYTES
OPERATIONS = {".0.weight": "rows", ".0.bias": "bias", ".2.weight": "columns"}


def sites(architecture):
    return [f"{side}.blocks.{i}.mlp" for side, key in (("encoder", "n_audio_layer"), ("decoder", "n_text_layer"))
            for i in range(architecture[key])]


def vector_sha(permutation):
    return hashlib.sha256(struct.pack("<" + "I" * len(permutation), *permutation)).hexdigest()


def original_permutation(model, site, check=weights.no_cancel):
    """Bounded F64 column maxima; no activations or calibration data."""
    import numpy as np
    tensor = model.tensor(site + ".2.weight")
    hidden, rows = tensor.shape
    require(tensor.dtype == "f16" and hidden == 4 * rows and 0 < hidden <= 5120 and 0 < rows <= 1280,
            "MLP2 original geometry differs")
    maxima = np.zeros(hidden, dtype=np.float64)
    with model.path.open("rb") as stream:
        stream.seek(tensor.offset)
        for start in range(0, rows, 8):
            check(); count = min(8, rows - start)
            data = stream.read(count * hidden * 2)
            require(len(data) == count * hidden * 2, "Truncated original MLP2")
            tile = np.frombuffer(data, dtype="<f2").astype(np.float64).reshape(count, hidden)
            require(np.isfinite(tile).all(), "Nonfinite original MLP2")
            maxima = np.maximum(maxima, np.max(np.abs(tile), axis=0))
    permutation = sorted(range(hidden), key=lambda i: (float(maxima[i]), i))
    return permutation, {"column_max_abs_min": float(np.min(maxima)), "column_max_abs_max": float(np.max(maxima)),
                         "zero_scale_channels": int(np.count_nonzero(maxima == 0))}


def exact_f16_permutation(parent, intermediate, site, permutation, check):
    """Compare serialized values as bytes, including signed zero and F32 bias."""
    import numpy as np
    results = {}
    with parent.path.open("rb") as a, intermediate.path.open("rb") as b:
        for suffix, operation in OPERATIONS.items():
            tensor = parent.tensor(site + suffix)
            before = core.hash_range(a, tensor.offset, tensor.bytes, check)
            after = core.hash_range(b, tensor.offset, tensor.bytes, check)
            inverse = hashlib.sha256()
            changed = 0
            if operation == "rows":
                width = tensor.shape[0] * 2
                require(tensor.dtype == "f16" and tensor.shape[1] == len(permutation), "MLP1 geometry differs")
                for new, old in enumerate(permutation):
                    check(); a.seek(tensor.offset + old * width); b.seek(tensor.offset + new * width)
                    expected, actual = a.read(width), b.read(width)
                    require(len(expected) == len(actual) == width and expected == actual, "MLP1 rows are not the exact fixed permutation")
                    a.seek(tensor.offset + new * width)
                    changed += int(np.count_nonzero(np.frombuffer(a.read(width), dtype="<u2") != np.frombuffer(actual, dtype="<u2")))
                for old, new in enumerate(np.argsort(permutation)):
                    check(); b.seek(tensor.offset + int(new) * width); inverse.update(b.read(width))
            elif operation == "bias":
                require(tensor.dtype == "f32" and tensor.shape == (len(permutation),), "MLP1 bias geometry differs")
                a.seek(tensor.offset); b.seek(tensor.offset)
                original, candidate = a.read(tensor.bytes), b.read(tensor.bytes)
                expected = b"".join(original[i * 4:i * 4 + 4] for i in permutation)
                require(candidate == expected, "MLP1 F32 bias is not the exact fixed permutation")
                changed = int(np.count_nonzero(np.frombuffer(original, dtype="<u4") != np.frombuffer(candidate, dtype="<u4")))
                inverse.update(b"".join(candidate[int(i) * 4:int(i) * 4 + 4] for i in np.argsort(permutation)))
            else:
                hidden, rows = tensor.shape
                require(tensor.dtype == "f16" and hidden == len(permutation), "MLP2 geometry differs")
                a.seek(tensor.offset); b.seek(tensor.offset); undo = np.argsort(permutation)
                for _ in range(rows):
                    check(); left, right = a.read(hidden * 2), b.read(hidden * 2)
                    require(len(left) == len(right) == hidden * 2, "Truncated MLP2 permutation")
                    expected = np.frombuffer(left, dtype="<u2")[permutation].tobytes()
                    require(right == expected, "MLP2 columns are not the exact fixed permutation")
                    changed += int(np.count_nonzero(np.frombuffer(left, dtype="<u2") != np.frombuffer(right, dtype="<u2")))
                    inverse.update(np.frombuffer(right, dtype="<u2")[undo].tobytes())
            require(inverse.hexdigest() == before, "Inverse MLP permutation differs from original bytes")
            results[tensor.name] = {"before_sha256": before, "after_sha256": after,
                                    "inverse_permutation_sha256": inverse.hexdigest(), "changed_elements": changed}
    return results


def validate_permutation(parent, intermediate, model_id, plan, plan_sha, audit, check=weights.no_cancel):
    require(valid_sha(OPERATOR_SHA256), "Reviewed permutation operator source pin is required")
    require(plan.get("schema_version") == audit.get("schema_version") == PERMUTATION_VERSION
            and plan.get("model_id") == audit.get("model_id") == model_id
            and plan.get("source_sha256") == audit.get("source_sha256") == parent.source_sha256
            and audit.get("state") == "completed" and audit.get("derived_sha256") == intermediate.source_sha256
            and audit.get("permutation_plan_sha256") == plan_sha
            and audit.get("file_bytes") == parent.bytes == intermediate.bytes
            and audit.get("architecture") == parent.architecture == intermediate.architecture
            and audit.get("vocabulary_sha256") == parent.vocabulary_sha256 == intermediate.vocabulary_sha256
            and parent.tensors == intermediate.tensors,
            "Permutation audit original/intermediate/layout binding differs")
    require(type(audit.get("outside_declared_changed_bytes")) is int and audit["outside_declared_changed_bytes"] == 0
            and audit.get("training_used") is False and audit.get("fitting_used") is False and audit.get("seed_search_used") is False
            and audit.get("parser_sha256") == PARSER_SHA256 and audit.get("generator_sha256") == OPERATOR_SHA256,
            "Permutation audit source or no-search contract differs")
    architecture = parent.architecture
    require(plan.get("ordering") == ORDERING and plan.get("state") == architecture["n_text_state"]
            and plan.get("encoder_layers") == architecture["n_audio_layer"]
            and plan.get("decoder_layers") == architecture["n_text_layer"]
            and type(plan.get("runtime_operations_added")) is int and plan["runtime_operations_added"] == 0
            and plan.get("fitting") is False and plan.get("seed_search") is False, "Fixed MLP ordering/geometry differs")
    expected_sites = sites(architecture); records = plan.get("sites")
    require(isinstance(records, list) and len(records) == len(expected_sites)
            and [r.get("site") for r in records if isinstance(r, dict)] == expected_sites, "Exact ordered MLP site inventory required")
    edits = audit.get("edits")
    require(isinstance(edits, list) and all(isinstance(e, dict) for e in edits), "Permutation edit inventory missing")
    edit_map = {e.get("tensor"): e for e in edits}
    targets = {site + suffix for site in expected_sites for suffix in OPERATIONS}
    require(len(edits) == len(edit_map) == len(targets) and set(edit_map) == targets,
            "Exact MLP edit inventory required")
    ranges, selected, permutations = [], 0, {}
    for record in records:
        check(); site = record["site"]; expected, stats = original_permutation(parent, site, check)
        permutation = record.get("permutation"); hidden = 4 * architecture["n_text_state"]
        require(isinstance(permutation, list) and len(permutation) == hidden
                and all(type(i) is int and 0 <= i < hidden for i in permutation)
                and permutation == expected and type(record.get("hidden_channels")) is int and record["hidden_channels"] == hidden
                and record.get("permutation_sha256") == vector_sha(permutation)
                and type(record.get("nonidentity_positions")) is int and record["nonidentity_positions"] == sum(i != v for i, v in enumerate(permutation))
                and type(record.get("zero_scale_channels")) is int
                and all(type(record.get(k)) in (float, int) for k in ("column_max_abs_min", "column_max_abs_max"))
                and all(record.get(k) == v for k, v in stats.items()), "MLP permutation is not the fixed original-weight stable ordering")
        proofs = exact_f16_permutation(parent, intermediate, site, permutation, check)
        for suffix, operation in OPERATIONS.items():
            name = site + suffix; tensor = parent.tensor(name); edit = edit_map[name]
            require(edit.get("site") == site and edit.get("shape") == list(tensor.shape) and edit.get("dtype") == tensor.dtype
                    and edit.get("operation") == operation and edit.get("permutation_sha256") == vector_sha(permutation)
                    and type(edit.get("changed_elements")) is int and 0 <= edit["changed_elements"] <= tensor.elements
                    and edit.get("selected_elements") == tensor.elements and edit.get("inverse_permutation_equal") is True
                    and all(edit.get(k) == v for k, v in proofs[name].items()), "MLP tensor/inverse payload proof differs")
            ranges.append((tensor.offset, tensor.offset + tensor.bytes)); selected += tensor.elements
        permutations[site] = permutation
    require(type(audit.get("selected_tensor_count")) is int and audit["selected_tensor_count"] == len(targets)
            and type(audit.get("selected_elements")) is int and audit["selected_elements"] == selected,
            "Selected MLP tensor/element budget differs")
    changed = sum(e["changed_elements"] for e in edits)
    require(type(audit.get("changed_elements")) is int and audit["changed_elements"] == changed
            and audit.get("no_op") is (changed == 0)
            and (parent.source_sha256 == intermediate.source_sha256) is (changed == 0), "Permutation no-op/changed-byte accounting differs")
    unchanged = weights.unchanged_regions_equal(parent.path, intermediate.path, parent.bytes, ranges, check)
    require(unchanged == audit.get("unchanged_regions_sha256"), "Permutation changed bytes outside the fixed MLP tensors")
    return {"target_tensor_names": sorted(targets), "target_count": len(targets), "permutations": permutations,
            "unchanged_regions_sha256": unchanged, "parent_sha256": parent.source_sha256,
            "intermediate_sha256": intermediate.source_sha256, "permutation_plan_sha256": plan_sha,
            "exact_selected_and_inverse_bytes_verified": True}


def dequant_q4(data):
    """Native Q4_0: signed half d; first 16 low nibbles, then 16 high nibbles."""
    import numpy as np
    require(isinstance(data, bytes) and len(data) > 0 and len(data) % 18 == 0, "Q4 row must contain complete 18-byte blocks")
    blocks = np.frombuffer(data, dtype=np.dtype([("d", "<f2"), ("q", "u1", (16,))]))
    scale = blocks["d"].astype(np.float64)
    require(np.isfinite(scale).all(), "Nonfinite Q4 half scale")
    packed = blocks["q"]
    values = np.concatenate(((packed & 15).astype(np.int16) - 8, (packed >> 4).astype(np.int16) - 8), axis=1)
    return (values * scale[:, None]).reshape(-1)


def compare_plain_metadata(plain, static, model_id, parent_sha):
    require(plain.get("schema_version") == VERSION and plain.get("state") == "completed" and plain.get("role") == "plain_q4"
            and plain.get("kind") == "compression" and plain.get("model_id") == model_id
            and plain.get("parent_original_id") == model_id
            and plain.get("parent_original_sha256") == plain.get("parent_sha256") == plain.get("input_sha256") == parent_sha
            and plain.get("quantizer_sha256") == QUANTIZER_SHA256
            and plain.get("quantization") == {"format": "q4_0", "ftype": 2, "file_header_ftype": 2002},
            "Completed plain Q4 control identity differs")
    retained = plain.get("static_validation", {})
    require(all(retained.get(k) == v for k, v in static.items() if k != "file_identity"),
            "Plain Q4 actual container differs from its retained audit")


def compare_quantized(parent, plain_path, plain, candidate_path, candidate, proof, check=weights.no_cancel):
    import numpy as np
    require(plain.get("model_file_bytes") == candidate.get("model_file_bytes")
            and plain.get("preserved_prefix_sha256") == candidate.get("preserved_prefix_sha256"), "Q4 pair sizes/prefix differ")
    targets = set(proof["target_tensor_names"]); a, b = plain["tensors"], candidate["tensors"]
    require(set(proof["permutations"]) == set(sites(parent.architecture))
            and targets == {site + suffix for site in sites(parent.architecture) for suffix in OPERATIONS},
            "All fixed MLP sites/targets are required for Q4 diagnostics")
    require(len(a) == len(b), "Q4 pair tensor counts differ")
    maps = [{t["name"]: t for t in seq} for seq in (a, b)]
    require(len(maps[0]) == len(a) and len(maps[1]) == len(b), "Duplicate Q4 tensors")
    unchanged, changed = 0, []
    for left, right in zip(a, b):
        require(all(left.get(k) == right.get(k) for k in ("name", "shape", "type_id", "source_type_id", "offset", "elements", "payload_bytes", "quantized")),
                "Q4 pair tensor layout differs")
        if right["name"] not in targets:
            require(left["payload_sha256"] == right["payload_sha256"], "Unselected quantized/passthrough payload differs: " + right["name"])
            unchanged += 1
        else: changed.append({"name": right["name"], "payload_changed": left["payload_sha256"] != right["payload_sha256"]})
    require(set(maps[0]) == set(maps[1]) and targets <= set(maps[0]), "Q4 MLP target missing")
    layers, energies, plain_errors, candidate_errors = [], [], [], []
    with parent.path.open("rb") as original, Path(plain_path).open("rb") as p, Path(candidate_path).open("rb") as c:
        for site, permutation in proof["permutations"].items():
            check(); hidden = len(permutation); inverse = np.argsort(permutation)
            require(hidden == 4 * parent.architecture["n_text_state"] and all(type(i) is int for i in permutation)
                    and sorted(permutation) == list(range(hidden)), "Invalid verified MLP permutation vector")
            w1, bias, w2 = [maps[0][site + suffix] for suffix in OPERATIONS]
            require(w1["quantized"] and w2["quantized"] and not bias["quantized"] and bias["type_id"] == 0,
                    "Q4 MLP types differ")
            row_bytes = w1["shape"][0] // 32 * 18
            for new, old in enumerate(permutation):
                check(); p.seek(w1["offset"] + old * row_bytes); c.seek(w1["offset"] + new * row_bytes)
                require(p.read(row_bytes) == c.read(row_bytes), "Q4 MLP1 rows are not the exact permutation of plain Q4")
            p.seek(bias["offset"]); c.seek(bias["offset"])
            raw_bias = p.read(bias["payload_bytes"])
            require(c.read(bias["payload_bytes"]) == b"".join(raw_bias[i * 4:i * 4 + 4] for i in permutation),
                    "Q4 MLP1 F32 bias permutation differs")
            original_tensor = parent.tensor(site + ".2.weight")
            original.seek(original_tensor.offset); p.seek(w2["offset"]); c.seek(w2["offset"])
            row_bytes = hidden // 32 * 18; e0, ep, ec = [], [], []
            for _ in range(w2["shape"][1]):
                check(); reference = np.frombuffer(original.read(hidden * 2), dtype="<f2").astype(np.float64)
                require(len(reference) == hidden and np.isfinite(reference).all(), "Truncated/nonfinite original MLP2 row")
                left, right = dequant_q4(p.read(row_bytes)), dequant_q4(c.read(row_bytes))[inverse]
                ep.append(float(np.dot(left - reference, left - reference)))
                ec.append(float(np.dot(right - reference, right - reference))); e0.append(float(np.dot(reference, reference)))
            energy, pe, ce = math.fsum(e0), math.fsum(ep), math.fsum(ec)
            require(all(math.isfinite(v) and v >= 0 for v in (energy, pe, ce)), "Invalid MLP2 squared-error diagnostic")
            energies.append(energy); plain_errors.append(pe); candidate_errors.append(ce)
            layers.append({"site": site, "elements": original_tensor.elements, "reference_squared_frobenius": energy,
                           "plain_q4_sse": pe, "permuted_q4_inverse_aligned_sse": ce,
                           "plain_q4_relative_frobenius": math.sqrt(pe / energy) if energy else None,
                           "permuted_q4_relative_frobenius": math.sqrt(ce / energy) if energy else None})
    energy, pe, ce = math.fsum(energies), math.fsum(plain_errors), math.fsum(candidate_errors)
    return {"same_file_bytes": True, "unmodified_tensors_byte_identical": True, "unmodified_tensor_count": unchanged,
            "mlp_targets": changed, "exact_q4_mlp1_row_and_f32_bias_permutation": True,
            "weight_error_diagnostics": {"scope": "all MLP2 weights only, dequantized against original F16; inverse-align candidate columns",
                "descriptive_only": True, "selection_or_quality_gate": False, "layers": layers,
                "aggregate": {"elements": sum(v["elements"] for v in layers), "reference_squared_frobenius": energy,
                    "plain_q4_sse": pe, "permuted_q4_inverse_aligned_sse": ce,
                    "plain_q4_relative_frobenius": math.sqrt(pe / energy) if energy else None,
                    "permuted_q4_relative_frobenius": math.sqrt(ce / energy) if energy else None},
                "zero_reference_norm_relative_error": "null; never substitute zero",
                "interpretation": "Weight reconstruction error is not ASR quality or an adoption decision"}}


def verify_tools(check, exporter_sha=None):
    sources = [(CORE_PATH, REUSED_CORE_SHA256), (Path(weights.__file__), PARSER_SHA256),
               (Path(__file__).with_name(OPERATOR_FILE), OPERATOR_SHA256)]
    if exporter_sha is not None: sources.append((Path(__file__), exporter_sha))
    for path, expected in sources:
        require(valid_sha(expected) and weights.hash_file(core.regular(path.absolute()), check) == expected,
                "Pinned reused core/parser/permutation operator differs")


def run_export(source_path, expected_sha, model_id, role, parent_path, parent_sha, output,
               *, permutation_plan_path=None, permutation_plan_sha=None, permutation_audit_path=None, permutation_audit_sha=None,
               plain_control_path=None, plain_control_sha=None, timeout=600, cancel_marker=None):
    require(model_id in ORIGINALS and role in {"plain_q4", "permuted_q4"} and valid_sha(expected_sha) and valid_sha(parent_sha)
            and type(timeout) is int and 1 <= timeout <= 600, "Unsupported model/role/hash or finite duration")
    output = core.external_output(output)
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
             "maximum_input_or_output_bytes": MAX_MODEL_BYTES, "maximum_log_bytes": MAX_LOG_BYTES,
             "python": sys.version, "numpy": package_version("numpy"), "maximum_mlp2_row_elements": 5120,
             "column_max_abs_tile_rows": 8,
             "numeric_worker_environment": {key: os.environ[key] for key in NUMERIC_ENVIRONMENT},
             "quantization": {"format": "q4_0", "ftype": 2, "file_header_ftype": 2002},
             "reused_core": {"path": str(CORE_PATH.absolute()), "sha256": REUSED_CORE_SHA256,
                 "functions": ["audit_q4", "run_quantizer", "cleanup_quantizer", "group_members", "external_output", "read_metadata", "bound_artifact"],
                 "attention_rotation_validator_or_entrypoint_executed": False},
             "original_open_mode": "read_only", "default_promotion": False}
    bindings = (permutation_plan_path, permutation_plan_sha, permutation_audit_path, permutation_audit_sha,
                plain_control_path, plain_control_sha)
    try:
        check(); verify_tools(check)
        exporter_sha = weights.hash_file(Path(__file__), check)
        source_path, parent_path = core.regular(source_path), core.regular(parent_path)
        binary = QUANTIZER.resolve(strict=True)
        require(os.access(binary, os.X_OK) and core.regular(binary) == binary
                and weights.hash_file(binary, check) == QUANTIZER_SHA256, "Pinned official quantizer differs")
        binary_identity = core.identity(binary)
        parent = weights.inspect_model(parent_path, limits=LIMITS, check=check)
        core.validate_original(parent, model_id, parent_sha)
        source = parent if source_path == parent_path else weights.inspect_model(source_path, limits=LIMITS, check=check)
        require(source.source_sha256 == expected_sha and source.architecture == parent.architecture
                and source.bytes == parent.bytes and source.tensors == parent.tensors, "F16 input identity/layout differs")
        audit.update(input=str(source.path), input_sha256=expected_sha, input_file_bytes=source.bytes,
                     parent=str(parent.path), parent_sha256=parent_sha, parent_file_bytes=parent.bytes,
                     parent_original_id=model_id, parent_original_sha256=parent_sha,
                     quantizer=str(binary), quantizer_sha256=QUANTIZER_SHA256, quantizer_file_identity=list(binary_identity),
                     generator_sha256=exporter_sha, parser_sha256=PARSER_SHA256,
                     input_file_identity=list(source.source_identity), parent_file_identity=list(parent.source_identity))
        if role == "plain_q4":
            require(source.path == parent.path and expected_sha == parent_sha and all(v is None for v in bindings),
                    "Plain Q4 must export original F16 without permutation/control bindings")
        else:
            require(all(v is not None for v in bindings), "Permuted Q4 requires permutation and plain-control bindings")
            plan = core.read_metadata(permutation_plan_path, permutation_plan_sha)
            permutation = core.read_metadata(permutation_audit_path, permutation_audit_sha)
            proof = validate_permutation(parent, source, model_id, plan, permutation_plan_sha, permutation, check)
            audit["permutation_validation"] = {k: v for k, v in proof.items() if k != "permutations"}
            audit.update(permutation_plan={"path": str(permutation_plan_path), "sha256": permutation_plan_sha},
                         permutation_audit={"path": str(permutation_audit_path), "sha256": permutation_audit_sha},
                         plain_control={"path": str(plain_control_path), "sha256": plain_control_sha})
            plain_control = core.read_metadata(plain_control_path, plain_control_sha)
            control_sha = plain_control.get("derived_sha256")
            control_path, control_identity = core.bound_artifact(plain_control.get("model_path", ""), control_sha,
                                                               plain_control.get("model_file_bytes"), check)
            plain_static = core.audit_q4(parent, control_path, check)
            compare_plain_metadata(plain_control, plain_static, model_id, parent_sha)
        weights.tensor_statistics(parent, check)
        if source.path != parent.path: weights.tensor_statistics(source, check)
        check(); output.mkdir(mode=0o700); created = True
        with partial.open("xb"): os.chmod(partial, 0o600)
        ownership = weights.artifact_identity(partial)
        command = [str(binary), str(source.path), str(partial), "q4_0"]
        audit.update(state="exporting", command=command)
        weights.write_new_json(output / "export-start.json", audit)
        weights.verify_model_source(parent, check)
        if source.path != parent.path: weights.verify_model_source(source, check)
        verify_tools(check, exporter_sha)
        require(core.identity(binary) == binary_identity and weights.hash_file(binary, check) == QUANTIZER_SHA256,
                "Quantizer changed before launch")
        audit["owned_quantizer_shutdown"] = core.run_quantizer(command, partial, ownership, output / "quantization.log", check)
        check(); weights.require_owned_artifact(partial, ownership); os.chmod(partial, 0o400)
        static = core.audit_q4(source, partial, check)
        require(0 < static["model_file_bytes"] < parent.bytes, "Q4 must be nonempty and smaller than original F16")
        audit["static_validation"] = static
        if role == "permuted_q4":
            audit["plain_control_comparison"] = compare_quantized(parent, control_path, plain_static, partial, static, proof, check)
            require(core.identity(control_path) == control_identity and core.bound_artifact(control_path, control_sha,
                    plain_control["model_file_bytes"], check)[1] == control_identity, "Plain Q4 control changed during export")
        require(core.identity(partial) == tuple(static["file_identity"]), "Q4 changed after static validation")
        result_sha = weights.hash_file(partial, check, static["model_file_bytes"])
        require(core.identity(partial) == tuple(static["file_identity"]), "Q4 changed while hashing")
        weights.verify_model_source(parent, check)
        if source.path != parent.path: weights.verify_model_source(source, check)
        verify_tools(check, exporter_sha)
        require(core.identity(binary) == binary_identity and weights.hash_file(binary, check) == QUANTIZER_SHA256
                and QUANTIZER.resolve(strict=True) == binary, "Quantizer changed during export")
        if role == "permuted_q4":
            core.read_metadata(permutation_plan_path, permutation_plan_sha); core.read_metadata(permutation_audit_path, permutation_audit_sha)
            core.read_metadata(plain_control_path, plain_control_sha)
        audit.update(state="verified", derived_sha256=result_sha, model_file_bytes=static["model_file_bytes"],
                     model_byte_saving_fraction=1 - static["model_file_bytes"] / parent.bytes,
                     original_after_sha256=parent.source_sha256, intermediate_after_sha256=source.source_sha256,
                     quantizer_after_sha256=QUANTIZER_SHA256, model_path=str(final), elapsed_seconds=time.monotonic() - start)
        weights.write_new_json(output / "export-audit.json", audit)
        check(); weights.require_owned_artifact(partial, ownership)
        require(core.identity(partial) == tuple(static["file_identity"]), "Q4 changed before publication")
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True); parser.add_argument("--sha256", required=True)
    parser.add_argument("--model-id", choices=sorted(ORIGINALS), required=True)
    parser.add_argument("--role", choices=("plain_q4", "permuted_q4"), required=True)
    parser.add_argument("--parent", type=Path, required=True); parser.add_argument("--parent-sha256", required=True)
    parser.add_argument("--permutation-plan", type=Path); parser.add_argument("--permutation-plan-sha256")
    parser.add_argument("--permutation-audit", type=Path); parser.add_argument("--permutation-audit-sha256")
    parser.add_argument("--plain-control", type=Path); parser.add_argument("--plain-control-sha256")
    parser.add_argument("--output", type=Path, required=True); parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--cancel-marker", type=Path)
    args = parser.parse_args(argv)
    result = run_export(args.model, args.sha256, args.model_id, args.role, args.parent, args.parent_sha256, args.output,
        permutation_plan_path=args.permutation_plan, permutation_plan_sha=args.permutation_plan_sha256,
        permutation_audit_path=args.permutation_audit, permutation_audit_sha=args.permutation_audit_sha256,
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
