#!/usr/bin/env python3
"""Apply one fixed, data-free MLP-neuron permutation to Whisper GGML files.

No recognition, quantization, training, reconstruction fitting or recipe search.
For h=GELU(W1*x+b1), reorder hidden neurons by original W2 column maxabs:
W1'=P*W1, b1'=P*b1, W2'=W2*P.T. Values move as original stored bytes.
Real-arithmetic equivalence does not establish finite-decoding identity.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import resource
import signal
import struct
import sys

WORKER_ENVIRONMENT = ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
                      "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS")
for _key in WORKER_ENVIRONMENT:
    os.environ[_key] = "1"

SPEC = importlib.util.spec_from_file_location("_mlp_permutation_ggml", Path(__file__).with_name("ggml_weights.py"))
weights = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = weights
SPEC.loader.exec_module(weights)

VERSION = "whisper-mlp-permutation-v1"
TARGETS = ("small", "large-v3-turbo")
# state, heads, encoder layers, decoder layers, mel bins, vocabulary
GEOMETRIES = {"small": (768, 12, 12, 12, 80, 51865),
              "large-v3-turbo": (1280, 20, 32, 4, 128, 51866)}
MAX_MODEL_BYTES = 4 * 1024 ** 3
MAX_RSS_BYTES = 128 * 1024 ** 2
MAX_NUMERIC_WORKSPACE_BYTES = 8 * 1024 ** 2
ROWS = 32
LIMITS = weights.Limits(model_bytes=MAX_MODEL_BYTES)


def require(value, message):
    if not value:
        raise ValueError(message)


def peak_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if sys.platform == "darwin" else value * 1024)


def numpy_module():
    try:
        import numpy
    except ImportError as error:
        raise ValueError("NumPy from scripts/quality/requirements.txt is required") from error
    return numpy


def workspace(*sizes):
    require(sum(sizes) <= MAX_NUMERIC_WORKSPACE_BYTES, "Permutation tile exceeds its8MiB numeric workspace bound")


def validate_geometry(architecture, model_id):
    require(model_id in TARGETS, "Only multilingual Small and Turbo are supported")
    state, heads, enc, dec, mels, vocab = GEOMETRIES[model_id]
    expected = {"n_audio_state": state, "n_text_state": state, "n_audio_head": heads,
                "n_text_head": heads, "n_audio_layer": enc, "n_text_layer": dec,
                "n_mels": mels, "n_vocab": vocab, "n_audio_ctx": 1500, "n_text_ctx": 448, "ftype": 1}
    require(all(type(architecture.get(k)) is int and architecture[k] == v for k, v in expected.items()),
            "Model differs from the pinned multilingual F16 geometry")
    return state, enc, dec


def sites(encoder_layers, decoder_layers):
    require(all(type(n) is int and 0 < n <= 32 for n in (encoder_layers, decoder_layers)), "Layer bound exceeded")
    return [f"{side}.blocks.{i}.mlp" for side, count in (("encoder", encoder_layers), ("decoder", decoder_layers)) for i in range(count)]


def tensor_plan(model, geometry):
    state, enc, dec = geometry
    result = []
    for site in sites(enc, dec):
        for suffix, shape, dtype, operation in ((".0.weight", (state, 4 * state), "f16", "rows"),
                                               (".0.bias", (4 * state,), "f32", "bias"),
                                               (".2.weight", (4 * state, state), "f16", "columns")):
            tensor = model.tensor(site + suffix)
            require(tensor.shape == shape and tensor.dtype == dtype, "Selected MLP tensor shape/dtype differs")
            result.append((tensor, site, operation))
    require(len(result) == 3 * (enc + dec) and len({t.name for t, *_ in result}) == len(result), "Incomplete or duplicate MLP plan")
    return sorted(result, key=lambda item: item[0].offset)


def read_exact(stream, offset, size):
    stream.seek(offset)
    value = stream.read(size)
    require(len(value) == size, "Tensor truncated while permuting")
    return value


def column_order(stream, tensor, check=weights.no_cancel, np=None):
    """F64 maxabs only; no weight arithmetic or activation observations."""
    np = np or numpy_module()
    require(tensor.dtype in ("f16", "f32") and len(tensor.shape) == 2, "A finite matrix is required")
    hidden, rows = tensor.shape
    require(0 < hidden <= 5120 and 0 < rows <= 1280, "MLP ordering dimensions exceed fixed bounds")
    width, dtype = (2, "<f2") if tensor.dtype == "f16" else (4, "<f4")
    maxima = np.zeros(hidden, dtype=np.float64)
    for start in range(0, rows, ROWS):
        check()
        count = min(ROWS, rows - start)
        elements = count * hidden
        workspace(elements * (width + 8 + 1), hidden * 8 * 5)
        raw = read_exact(stream, tensor.offset + start * hidden * width, elements * width)
        values = np.frombuffer(raw, dtype=dtype).astype(np.float64).reshape(count, hidden)
        require(bool(np.isfinite(values).all()), "Original MLP2 contains nonfinite values")
        np.abs(values, out=values)
        np.maximum(maxima, values.max(axis=0), out=maxima)
    original_indices = np.arange(hidden, dtype=np.int64)
    order = np.lexsort((original_indices, maxima))
    encoded = order.astype("<u4").tobytes()
    return order, {"hidden_channels": hidden, "permutation": order.tolist(),
                   "permutation_sha256": hashlib.sha256(encoded).hexdigest(),
                   "nonidentity_positions": int(np.count_nonzero(order != original_indices)),
                   "column_max_abs_min": float(maxima.min()), "column_max_abs_max": float(maxima.max()),
                   "zero_scale_channels": int(np.count_nonzero(maxima == 0))}


def permutation_plan(model, model_id, geometry, check, np):
    state, enc, dec = geometry
    records = []
    with model.path.open("rb") as source:
        for site in sites(enc, dec):
            check(); weights.verify_model_source(model, check, hash_content=False)
            _, record = column_order(source, model.tensor(site + ".2.weight"), check, np)
            records.append({"site": site, **record})
    return {"schema_version": VERSION, "model_id": model_id, "source_sha256": model.source_sha256,
            "state": state, "encoder_layers": enc, "decoder_layers": dec,
            "ordering": {"key": "original_mlp2_column_max_abs_f64", "direction": "ascending",
                         "ties": "original_hidden_index", "index_semantics": "new_position_to_original_hidden_index",
                         "index_encoding": "u32-le"}, "sites": records,
            "runtime_operations_added": 0, "fitting": False, "seed_search": False,
            "weight_values": "original_stored_bytes; no value arithmetic or casts"}


def checked_order(order, hidden, np):
    original = np.asarray(order)
    require(original.ndim == 1 and len(original) == hidden and original.dtype.kind in "iu"
            and bool((original >= 0).all()) and bool((original < hidden).all()), "Invalid neuron permutation")
    result = original.astype(np.int64, copy=False)
    require(np.array_equal(np.sort(result), np.arange(hidden)), "Invalid neuron permutation")
    return result


def hash_tensor(stream, tensor, check):
    digest = hashlib.sha256()
    for start in range(0, tensor.bytes, weights.BLOCK_BYTES):
        check(); digest.update(read_exact(stream, tensor.offset + start, min(weights.BLOCK_BYTES, tensor.bytes - start)))
    return digest.hexdigest()


def permute_tensor(original, target, tensor, site, operation, order, permutation_sha, check, np):
    hidden = tensor.shape[0] if operation != "rows" else tensor.shape[1]
    order = checked_order(order, hidden, np)
    width = 2 if tensor.dtype == "f16" else 4
    unsigned = "<u2" if width == 2 else "<u4"
    before_hash, after_hash = hash_tensor(original, tensor, check), hashlib.sha256()
    changed = 0
    rows, columns = (hidden, tensor.shape[0]) if operation == "rows" else ((1, hidden) if operation == "bias" else (tensor.shape[1], hidden))
    for start in range(0, rows, 1 if operation == "rows" else ROWS):
        check()
        count = 1 if operation == "rows" else min(ROWS, rows - start)
        length = count * columns * width
        workspace(length * 5, order.nbytes * 3)
        offset = tensor.offset + start * columns * width
        before = read_exact(original, offset, length)
        if operation == "rows":
            after = read_exact(original, tensor.offset + int(order[start]) * columns * width, length)
        else:
            values = np.frombuffer(before, dtype=unsigned).reshape(count, columns)
            after = values[:, order].tobytes(order="C")
        changed += int(np.count_nonzero(np.frombuffer(before, dtype=unsigned) != np.frombuffer(after, dtype=unsigned)))
        target.seek(offset); target.write(after); after_hash.update(after)
    return {"tensor": tensor.name, "site": site, "shape": list(tensor.shape), "dtype": tensor.dtype,
            "operation": operation, "permutation_sha256": permutation_sha,
            "selected_elements": tensor.elements, "changed_elements": changed,
            "before_sha256": before_hash, "after_sha256": after_hash.hexdigest()}


def inverse_tensor_proof(original, target, tensor, operation, order, check, np):
    hidden = tensor.shape[1] if operation == "rows" else tensor.shape[0]
    order = checked_order(order, hidden, np)
    inverse = np.argsort(order)
    width = 2 if tensor.dtype == "f16" else 4
    unsigned = "<u2" if width == 2 else "<u4"
    digest = hashlib.sha256()
    rows, columns = (hidden, tensor.shape[0]) if operation == "rows" else ((1, hidden) if operation == "bias" else (tensor.shape[1], hidden))
    for start in range(0, rows, 1 if operation == "rows" else ROWS):
        check()
        count = 1 if operation == "rows" else min(ROWS, rows - start)
        length = count * columns * width
        workspace(length * 5, order.nbytes * 4)
        before = read_exact(original, tensor.offset + start * columns * width, length)
        if operation == "rows":
            restored = read_exact(target, tensor.offset + int(inverse[start]) * columns * width, length)
        else:
            after = read_exact(target, tensor.offset + start * columns * width, length)
            restored = np.frombuffer(after, dtype=unsigned).reshape(count, columns)[:, inverse].tobytes(order="C")
        require(restored == before, "Inverse permutation failed exact stored-byte proof")
        digest.update(restored)
    return digest.hexdigest()


def external_output(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and not any(p.is_symlink() for p in (path, *path.parents)), "Use a new absolute nonsymlink external output")
    require(not any((p / ".git").exists() or (p / ".git").is_symlink() for p in (path, *path.parents)), "Output must be outside every Git checkout")
    location = Path(__file__).resolve()
    if location.parent.name == "quality" and location.parent.parent.name == "scripts":
        repo = location.parents[2]
        if (repo / "AGENTS.md").is_file() and (repo / "scripts/quality/ggml_weights.py").is_file():
            require(repo not in path.parents and path != repo, "Output must be outside the source archive")
    require(path.parent.is_dir() and not path.exists(), "Output must be new; its parent must exist")
    return path


def apply_permutation(source, model_id, expected_sha, output, check=weights.no_cancel):
    require(model_id in TARGETS and isinstance(expected_sha, str) and re.fullmatch(r"[0-9a-f]{64}", expected_sha), "Small/Turbo and explicit original SHA256 required")
    np = numpy_module()
    source = Path(source).resolve(strict=True)
    model = weights.inspect_model(source, LIMITS, check)
    require(model.source_sha256 == expected_sha, "Original model checksum differs")
    geometry = validate_geometry(model.architecture, model_id)
    planned = tensor_plan(model, geometry)
    weights.tensor_statistics(model, check)
    plan = permutation_plan(model, model_id, geometry, check, np)
    orders = {item["site"]: item for item in plan["sites"]}
    check(); output = external_output(output); output.mkdir(mode=0o700, exist_ok=False)
    partial, final = output / "model.partial.bin", output / "model.bin"
    plan_path, audit_path = output / "permutation-plan.json", output / "permutation-audit.json"
    ownership = audit_owner = plan_owner = None
    audit = {"schema_version": VERSION, "state": "editing", "created_utc": datetime.now(timezone.utc).isoformat(),
             "model_id": model_id, "source_path": str(source), "source_sha256": expected_sha,
             "original_open_mode": "read_only", "file_bytes": model.bytes, "architecture": model.architecture,
             "generator_sha256": weights.hash_file(Path(__file__), check), "parser_sha256": weights.hash_file(Path(weights.__file__), check),
             "python": sys.version, "numpy": np.__version__, "numeric_workers": 1,
             "numeric_worker_environment": {key: os.environ[key] for key in WORKER_ENVIRONMENT},
             "arithmetic": "F64 column maxabs and deterministic ordering only; original stored weight/bias bytes permuted without casts",
             "maximum_model_bytes": MAX_MODEL_BYTES, "numeric_workspace_bound_bytes": MAX_NUMERIC_WORKSPACE_BYTES,
             "cli_peak_rss_limit_bytes": MAX_RSS_BYTES, "copied_bytes": 0, "edits": [],
             "training_used": False, "fitting_used": False, "seed_search_used": False,
             "inference_or_quantization_executed": False,
             "quality_claim": "UNMEASURED; require permuted-F16 numerical panel and separate plain/permuted-Q4 evaluation"}

    def persist():
        nonlocal audit_owner
        if audit_owner is None:
            weights.write_new_json(audit_path, audit)
        else:
            weights.require_owned_artifact(audit_path, audit_owner)
            weights.update_owned_audit(audit_path, audit)
        audit_owner = weights.artifact_identity(audit_path)

    try:
        weights.write_new_json(plan_path, plan); plan_owner = weights.artifact_identity(plan_path)
        audit["permutation_plan_sha256"] = weights.hash_file(plan_path, check)
        persist()
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
            for tensor, site, operation in planned:
                check(); weights.verify_model_source(model, check, hash_content=False)
                item = orders[site]
                audit["edits"].append(permute_tensor(original, target, tensor, site, operation, item["permutation"], item["permutation_sha256"], check, np))
            target.flush(); os.fsync(target.fileno())
            for (tensor, site, operation), edit in zip(planned, audit["edits"]):
                check(); weights.require_owned_artifact(partial, ownership)
                inverse_hash = inverse_tensor_proof(original, target, tensor, operation, orders[site]["permutation"], check, np)
                require(inverse_hash == edit["before_sha256"] and hash_tensor(target, tensor, check) == edit["after_sha256"], "Permutation byte hashes changed")
                edit.update(inverse_permutation_sha256=inverse_hash, inverse_permutation_equal=True)
        derived = weights.inspect_model(partial, LIMITS, check)
        require(derived.architecture == model.architecture and derived.tensors == model.tensors and derived.vocabulary_sha256 == model.vocabulary_sha256, "Permutation changed layout, header or vocabulary")
        ranges = [(tensor.offset, tensor.offset + tensor.bytes) for tensor, *_ in planned]
        audit["unchanged_regions_sha256"] = weights.unchanged_regions_equal(source, partial, model.bytes, ranges, check)
        weights.verify_model_source(model, check); weights.verify_model_source(derived, check)
        weights.require_owned_artifact(plan_path, plan_owner)
        require(weights.hash_file(plan_path, check) == audit["permutation_plan_sha256"], "Permutation plan changed before publication")
        changed = sum(item["changed_elements"] for item in audit["edits"])
        audit.update(state="verified", artifact=partial.name, derived_sha256=derived.source_sha256,
                     vocabulary_sha256=model.vocabulary_sha256, outside_declared_changed_bytes=0,
                     selected_tensor_count=len(planned), selected_elements=sum(t.elements for t, *_ in planned),
                     changed_elements=changed, no_op=changed == 0, finite_validation="All original values finite; selected values are byte permutations; all other bytes identical",
                     peak_rss_bytes=peak_rss_bytes())
        persist(); check(); weights.require_owned_artifact(partial, ownership)
        os.link(partial, final, follow_symlinks=False)
        weights.require_owned_artifact(final, ownership); weights.require_owned_artifact(partial, ownership); partial.unlink()
        audit.update(state="completed", artifact=final.name); persist(); check()
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
            persist()
        except BaseException as failure:
            if hasattr(error, "add_note"):
                error.add_note("Permutation failure audit persistence failed: " + str(failure))
        raise


def main(argv=None):
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    apply = commands.add_parser("apply")
    apply.add_argument("model", type=Path); apply.add_argument("--model-id", choices=TARGETS, required=True)
    apply.add_argument("--sha256", required=True); apply.add_argument("--output", type=Path, required=True)
    apply.add_argument("--timeout", type=float, default=600); apply.add_argument("--cancel-file", type=Path)
    args = parser.parse_args(argv); cancel = weights.Cancellation(args.timeout, args.cancel_file)
    previous = {}
    def stopped(*_):
        cancel.requested = True
    def checked():
        cancel.check()
        if peak_rss_bytes() > MAX_RSS_BYTES:
            raise MemoryError("Permutation process exceeded its128MiB peak RSS ceiling")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, stopped)
    try:
        result = apply_permutation(args.model, args.model_id, args.sha256, args.output, checked)
        print(json.dumps({key: result[key] for key in ("state", "source_sha256", "derived_sha256", "file_bytes", "no_op")}))
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, InterruptedError, TimeoutError, MemoryError) as error:
        raise SystemExit(type(error).__name__ + ": " + str(error))
