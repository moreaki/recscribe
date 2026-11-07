#!/usr/bin/env python3
"""Fold one fixed head-local signed Hadamard recipe into Whisper GGML weights.

Offline research only: no ASR, quantization, downloads, fitting or seed search.
CLI: attention-rotate.py apply MODEL --model-id small|large-v3-turbo
     --sha256 ORIGINAL_SHA --output NEW_EXTERNAL_DIR --timeout 600
     [--cancel-file PATH]

Column-vector/output-by-input convention: Q'=R Q, K'=R K, V'=S V,
O'[:,head]=O[:,head] S.T; Q/V biases rotate, K has no bias, O bias stays.
Every R/S is H64 D, with H64's exact coefficients +/-1/8. Attention heads,
not residual/LN/GELU coordinates, are rotated. Encoder self-attention, decoder
self-attention and decoder cross-attention all participate. Algebraic identity
does not imply machine/logit/transcript identity after F16/F32/cache rounding.

Mask bytes are SHA256(domain || original_SHA_raw32 || site_ASCII || NUL
 || head_u32LE || pair_ASCII), pair='qk' or 'vo'. The first eight digest
bytes supply channels0..63 in byte order, least-significant bit first; bit1
means -1. No seed/ratio/head-selection knob exists. Output is an unquantized
conversion control; independently compare ordinary and rotated Q4 artifacts.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import stat
import struct
import sys

for _key in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
             "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS"):
    os.environ[_key] = "1"

SPEC = importlib.util.spec_from_file_location("_attention_rotation_ggml", Path(__file__).with_name("ggml_weights.py"))
weights = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = weights
SPEC.loader.exec_module(weights)

VERSION = "whisper-attention-rotation-v1"
DOMAIN = b"recscribe-whisper-attention-rotation-v1\0"
HEAD = 64
ROWS = 64
MAX_MODEL_BYTES = 4 * 1024 ** 3
MAX_RSS_BYTES = 128 * 1024 ** 2
MAX_NUMERIC_WORKSPACE_BYTES = 8 * 1024 ** 2
TARGETS = ("small", "large-v3-turbo")
# state, heads, encoder layers, decoder layers, mel bins, vocabulary
GEOMETRIES = {"tiny": (384, 6, 4, 4, 80, 51865), "base": (512, 8, 6, 6, 80, 51865),
              "small": (768, 12, 12, 12, 80, 51865),
              "large-v3-turbo": (1280, 20, 32, 4, 128, 51866),
              "large-v3": (1280, 20, 32, 32, 128, 51866)}
LIMITS = weights.Limits(model_bytes=MAX_MODEL_BYTES)


def require(ok, message):
    if not ok:
        raise ValueError(message)


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def peak_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if sys.platform == "darwin" else value * 1024)


def numpy_module():
    try:
        import numpy
    except ImportError as error:
        raise ValueError("NumPy from scripts/quality/requirements.txt is required") from error
    return numpy


def validate_geometry(architecture, model_id):
    require(model_id in GEOMETRIES, "Unsupported multilingual geometry")
    state, heads, enc, dec, mels, vocab = GEOMETRIES[model_id]
    expected = {"n_audio_state": state, "n_text_state": state, "n_audio_head": heads,
                "n_text_head": heads, "n_audio_layer": enc, "n_text_layer": dec,
                "n_mels": mels, "n_vocab": vocab, "n_audio_ctx": 1500, "n_text_ctx": 448, "ftype": 1}
    require(all(type(architecture.get(k)) is int and architecture[k] == v for k, v in expected.items()),
            "Model differs from the pinned multilingual F16 geometry")
    require(state // heads == HEAD and state <= 1280, "Only bounded64-channel attention heads are supported")
    return state, heads, enc, dec


def sites(encoder_layers, decoder_layers):
    require(all(type(v) is int and 0 < v <= 32 for v in (encoder_layers, decoder_layers)), "Layer budget exceeded")
    return ([f"encoder.blocks.{i}.attn" for i in range(encoder_layers)]
            + [f"decoder.blocks.{i}.{kind}" for i in range(decoder_layers) for kind in ("attn", "cross_attn")])


def mask(source_sha, site, head, pair):
    require(valid_sha(source_sha) and isinstance(site, str)
            and re.fullmatch(r"(?:encoder|decoder)\.blocks\.\d+\.(?:attn|cross_attn)", site), "Invalid original/site identity")
    require(type(head) is int and 0 <= head < 20 and pair in ("qk", "vo"), "Invalid head/pair identity")
    encoded = (DOMAIN + bytes.fromhex(source_sha) + site.encode("ascii")
               + b"\0" + struct.pack("<I", head) + pair.encode("ascii"))
    digest = hashlib.sha256(encoded).digest()
    return digest, [(-1 if (digest[j // 8] >> (j % 8)) & 1 else 1) for j in range(HEAD)]


def rotation(source_sha, site, head, pair, np=None):
    np = np or numpy_module()
    digest, signs = mask(source_sha, site, head, pair)
    h = np.ones((1, 1), dtype=np.float64)
    while len(h) < HEAD:
        h = np.block([[h, h], [h, -h]])
    return (h / 8) * np.asarray(signs, dtype=np.float64), digest


def rotation_plan(model, model_id, geometry):
    state, heads, enc, dec = geometry
    records = []
    for site in sites(enc, dec):
        groups = []
        for head in range(heads):
            for pair in ("qk", "vo"):
                digest, _ = mask(model.source_sha256, site, head, pair)
                groups.append({"head": head, "pair": pair, "sha256": digest.hex(), "mask_first8_hex": digest[:8].hex()})
        records.append({"site": site, "heads": groups})
    return {"schema_version": VERSION, "model_id": model_id, "source_sha256": model.source_sha256,
            "head_channels": HEAD, "state": state, "head_count": heads, "sites": records,
            "domain_hex": DOMAIN.hex(), "mask_encoding": "domain+sha_raw32+site_ASCII+NUL+head_u32LE+pair_ASCII",
            "sign_encoding": "first8_SHA256_bytes_in_order; channel_j=byte[j//8]_bit[j%8]_LSB_first;1=-1;0=+1",
            "matrix": "normalized_Sylvester_H64_times_diagonal_signs; H64_coefficients=+/-1/8",
            "seed_search": False, "fitting": False, "runtime_operations_added": 0}


def tensor_plan(model, geometry):
    state, heads, enc, dec = geometry
    result = []
    for site in sites(enc, dec):
        for suffix, operation, pair in (("query.weight", "output_rows", "qk"), ("query.bias", "bias", "qk"),
                                        ("key.weight", "output_rows", "qk"), ("value.weight", "output_rows", "vo"),
                                        ("value.bias", "bias", "vo"), ("out.weight", "input_columns", "vo")):
            tensor = model.tensor(site + "." + suffix)
            shape, dtype = ((state,), "f32") if operation == "bias" else ((state, state), "f16")
            require(tensor.shape == shape and tensor.dtype == dtype, "Selected tensor layout differs")
            result.append((tensor, site, operation, pair))
    require(len(result) == 6 * (enc + 2 * dec) and len({t.name for t, *_ in result}) == len(result), "Incomplete/duplicate rotation tensor plan")
    return sorted(result, key=lambda item: item[0].offset)


def external_output(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and not any(p.is_symlink() for p in (path, *path.parents)),
            "Use a new absolute nonsymlink external output")
    require(not any((p / ".git").exists() or (p / ".git").is_symlink() for p in (path, *path.parents)), "Output must be outside every Git checkout")
    location = Path(__file__).resolve()
    if location.parent.name == "quality" and location.parent.parent.name == "scripts":
        repo = location.parents[2]
        if (repo / "AGENTS.md").is_file() and (repo / "scripts/quality/ggml_weights.py").is_file():
            require(repo not in path.parents and path != repo, "Output must be outside the source archive")
    require(path.parent.is_dir() and not path.exists(), "Output must be new; its parent must exist")
    return path


def cast_block(before, values, dtype, np):
    target_type = "<f2" if dtype == "f16" else "<f4"
    require(bool(np.isfinite(values).all()), "Nonfinite F64 rotation")
    with np.errstate(over="ignore", invalid="ignore"):
        cast = values.astype(target_type)
    require(bool(np.isfinite(cast).all()), "Rotation overflows original stored dtype")
    after = cast.tobytes(order="C")
    unsigned = "<u2" if dtype == "f16" else "<u4"
    changed = int(np.count_nonzero(np.frombuffer(before, dtype=unsigned) != np.frombuffer(after, dtype=unsigned)))
    rounded = cast.astype(np.float64)
    error = rounded - values
    return after, changed, {"max_abs_cast_error": float(np.abs(error).max()), "cast_squared_error": float((error * error).sum()),
                             "stored_max_abs": float(np.abs(rounded).max()), "stored_squared_l2": float((rounded * rounded).sum())}


def rotate_tensor(original, target, tensor, site, operation, pair, source_sha, state, heads, check, np):
    before_hash, after_hash = hashlib.sha256(), hashlib.sha256()
    changed = 0
    stats = {"max_abs_cast_error": 0., "cast_squared_error": 0., "stored_max_abs": 0., "stored_squared_l2": 0.}
    width = 2 if tensor.dtype == "f16" else 4
    dtype = "<f2" if tensor.dtype == "f16" else "<f4"
    for start in range(0, state, HEAD if operation != "input_columns" else ROWS):
        check()
        count = HEAD if operation != "input_columns" else min(ROWS, state - start)
        elements = count if operation == "bias" else count * state
        offset = tensor.offset + start * (1 if operation == "bias" else state) * width
        original.seek(offset); before = original.read(elements * width)
        require(len(before) == elements * width, "Original truncated during tensor rotation")
        values = np.frombuffer(before, dtype=dtype).astype(np.float64)
        require(bool(np.isfinite(values).all()), "Selected original tensor is nonfinite")
        if operation == "input_columns":
            values = values.reshape(count, state)
            result = np.empty_like(values)
            for head in range(heads):
                check(); matrix, _ = rotation(source_sha, site, head, pair, np)
                section = slice(head * HEAD, (head + 1) * HEAD)
                result[:, section] = values[:, section] @ matrix.T
        else:
            matrix, _ = rotation(source_sha, site, start // HEAD, pair, np)
            result = matrix @ (values if operation == "bias" else values.reshape(HEAD, state))
        require(before.__sizeof__() + values.nbytes + result.nbytes + matrix.nbytes + elements * 32 <= MAX_NUMERIC_WORKSPACE_BYTES,
                "Rotation tile exceeds its8MiB numeric workspace bound")
        after, delta, block_stats = cast_block(before, result, tensor.dtype, np)
        before_hash.update(before); after_hash.update(after); changed += delta
        for name, value in block_stats.items():
            stats[name] = max(stats[name], value) if name in ("max_abs_cast_error", "stored_max_abs") else stats[name] + value
        target.seek(offset); target.write(after)
    return {"tensor": tensor.name, "shape": list(tensor.shape), "dtype": tensor.dtype, "operation": operation, "pair": pair,
            "selected_elements": tensor.elements, "changed_elements": changed,
            "before_sha256": before_hash.hexdigest(), "after_sha256": after_hash.hexdigest(), **stats}


def apply_rotation(source, model_id, expected_sha, output, check=weights.no_cancel):
    require(model_id in TARGETS and valid_sha(expected_sha), "Small/Turbo and explicit original SHA256 are required")
    np = numpy_module()
    source = Path(source).resolve(strict=True)
    model = weights.inspect_model(source, LIMITS, check)
    require(model.source_sha256 == expected_sha, "Original model checksum differs")
    geometry = validate_geometry(model.architecture, model_id)
    planned = tensor_plan(model, geometry)
    plan = rotation_plan(model, model_id, geometry)
    weights.tensor_statistics(model, check)  # All original values, including unmodified regions, must be finite.
    check(); output = external_output(output); output.mkdir(mode=0o700, exist_ok=False)
    partial, final, audit_path = output / "model.partial.bin", output / "model.bin", output / "rotation-audit.json"
    ownership = None
    audit = {"schema_version": VERSION, "state": "editing", "created_utc": datetime.now(timezone.utc).isoformat(),
        "model_id": model_id, "source_path": str(source), "source_sha256": expected_sha, "original_open_mode": "read_only",
        "file_bytes": model.bytes, "architecture": model.architecture, "generator_sha256": weights.hash_file(Path(__file__), check),
        "parser_sha256": weights.hash_file(Path(weights.__file__), check), "python": sys.version, "numpy": np.__version__,
        "arithmetic": "F64 tiled matrix products then explicit original-F16/F32 cast; no F16 arithmetic accumulation",
        "numeric_workers": 1, "numeric_worker_environment": {k: os.environ[k] for k in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS")},
        "maximum_model_bytes": MAX_MODEL_BYTES, "numeric_workspace_bound_bytes": MAX_NUMERIC_WORKSPACE_BYTES,
        "cli_peak_rss_limit_bytes": MAX_RSS_BYTES, "copied_bytes": 0, "edits": [],
        "training_used": False, "fitting_used": False, "seed_search_used": False, "inference_or_quantization_executed": False,
        "quality_claim": "UNMEASURED; require native rotated-F16 numerical panel and separate plain/rotated-Q4 evaluation"}
    try:
        plan_path = output / "rotation-plan.json"; weights.write_new_json(plan_path, plan)
        audit["rotation_plan_sha256"] = weights.hash_file(plan_path, check)
        digest = hashlib.sha256()
        with source.open("rb") as original, partial.open("xb") as target:
            require(weights.file_identity(os.fstat(original.fileno())) == model.source_identity, "Original changed before copy")
            ownership = weights.artifact_identity(partial); os.chmod(partial, 0o600)
            remaining = model.bytes
            while remaining:
                check(); block = original.read(min(weights.BLOCK_BYTES, remaining))
                require(bool(block), "Original truncated during copy")
                target.write(block); digest.update(block); audit["copied_bytes"] += len(block); remaining -= len(block)
            require(not original.read(1), "Original grew during copy")
            target.flush(); os.fsync(target.fileno())
        require(digest.hexdigest() == expected_sha, "Original changed while copying")
        weights.require_owned_artifact(partial, ownership)
        descriptor = os.open(partial, os.O_RDWR | os.O_NOFOLLOW)
        with source.open("rb") as original, os.fdopen(descriptor, "r+b") as target:
            require((os.fstat(target.fileno()).st_dev, os.fstat(target.fileno()).st_ino) == ownership, "Created artifact was replaced")
            for tensor, site, operation, pair in planned:
                check(); weights.verify_model_source(model, check, hash_content=False)
                audit["edits"].append(rotate_tensor(original, target, tensor, site, operation, pair, expected_sha, geometry[0], geometry[1], check, np))
            target.flush(); os.fsync(target.fileno())
        require(sum(e["changed_elements"] for e in audit["edits"]) > 0, "Rotation made no representable weight changes")
        weights.require_owned_artifact(partial, ownership)
        derived = weights.inspect_model(partial, LIMITS, check)
        require(derived.architecture == model.architecture and derived.tensors == model.tensors
                and derived.vocabulary_sha256 == model.vocabulary_sha256, "Rotation changed headers, tensor layout or vocabulary")
        ranges = [(tensor.offset, tensor.offset + tensor.bytes) for tensor, *_ in planned]
        audit["unchanged_regions_sha256"] = weights.unchanged_regions_equal(source, partial, model.bytes, ranges, check)
        weights.verify_model_source(model, check); weights.verify_model_source(derived, check)
        audit.update(state="verified", artifact=partial.name, derived_sha256=derived.source_sha256,
            vocabulary_sha256=model.vocabulary_sha256, outside_declared_changed_bytes=0,
            selected_tensor_count=len(planned), selected_elements=sum(t.elements for t, *_ in planned),
            finite_validation="All original values scanned; every selected result finite; all other bytes identical",
            peak_rss_bytes=peak_rss_bytes())
        weights.write_new_json(audit_path, audit); check(); weights.require_owned_artifact(partial, ownership)
        os.link(partial, final, follow_symlinks=False)
        weights.require_owned_artifact(final, ownership); weights.require_owned_artifact(partial, ownership); partial.unlink()
        audit.update(state="completed", artifact=final.name); weights.update_owned_audit(audit_path, audit); check()
        return audit
    except BaseException as error:
        audit.update(state="canceled" if isinstance(error, (InterruptedError, KeyboardInterrupt, TimeoutError)) else "failed", error=str(error))
        if ownership is not None:
            try:
                if final.exists():
                    weights.require_owned_artifact(final, ownership)
                    os.link(final, output / "model.failed.bin", follow_symlinks=False); final.unlink()
            except (OSError, ValueError) as failure:
                audit["quarantine_error"] = str(failure)
        audit["retained_artifacts"] = [p.name for p in (partial, final, output / "model.failed.bin") if p.exists()]
        try:
            if audit_path.exists(): weights.update_owned_audit(audit_path, audit)
            else: weights.write_new_json(audit_path, audit)
        except BaseException as failure:
            if hasattr(error, "add_note"): error.add_note("Rotation failure audit persistence failed: " + str(failure))
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    apply = commands.add_parser("apply")
    apply.add_argument("model", type=Path); apply.add_argument("--model-id", choices=TARGETS, required=True)
    apply.add_argument("--sha256", required=True); apply.add_argument("--output", type=Path, required=True)
    apply.add_argument("--timeout", type=float, default=600); apply.add_argument("--cancel-file", type=Path)
    args = parser.parse_args(argv); cancel = weights.Cancellation(args.timeout, args.cancel_file)
    previous = {}
    def stopped(*_): cancel.requested = True
    def checked():
        cancel.check()
        if peak_rss_bytes() > MAX_RSS_BYTES:
            raise MemoryError("Rotation process exceeded its128MiB peak RSS ceiling")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): previous[number] = signal.signal(number, stopped)
    try:
        result = apply_rotation(args.model, args.model_id, args.sha256, args.output, checked)
        print(json.dumps({"state": result["state"], "source_sha256": result["source_sha256"], "derived_sha256": result["derived_sha256"],
                          "output": str(args.output), "file_bytes": result["file_bytes"], "quality": "unmeasured"}))
    finally:
        for number, handler in previous.items(): signal.signal(number, handler)
    return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except (ValueError, OSError, InterruptedError, TimeoutError, MemoryError) as error:
        raise SystemExit(type(error).__name__ + ": " + str(error))
