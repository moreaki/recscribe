#!/usr/bin/env python3
"""Prepare a fixed, untrained cross-attention affine-bias experiment offline.

Reads at most three original multilingual tiny/base/small GGML files. Produces
recipes and static evidence only: never changes weights, runs ASR or reads corpus
references/outcomes. Apply recipes separately with unchanged ggml_weights.py,
after reviewing the completed generation record and frozen evaluation protocol.
"""
import argparse
import importlib
import importlib.util
import math
import os
from pathlib import Path
import signal
import struct
import sys

# Configure before the optional NumPy import, even when invoked without env.
# The Gram calculations also deliberately avoid BLAS dispatch/worker pools.
THREAD_ENV = ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
              "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS")
for _name in THREAD_ENV:
    os.environ[_name] = "1"

SPEC = importlib.util.spec_from_file_location("_affine_ggml_weights_v1", Path(__file__).with_name("ggml_weights.py"))
weights = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = weights
SPEC.loader.exec_module(weights)

VERSION = "cross-head-affine-bias-1.0"
FACTOR = 0.9
MAX_MODEL_BYTES = 512 * 1024 * 1024
MAX_MODELS = 3
ARCHITECTURES = {"tiny": (384, 6, 4), "base": (512, 8, 6), "small": (768, 12, 12)}


def numpy_runtime():
    try:
        return importlib.import_module("numpy")
    except ImportError as error:
        raise ValueError("This offline statistics tool requires an explicitly installed NumPy; nothing is downloaded") from error


def f32(value):
    """Match the existing recipe applier's Python-double -> original F32 cast."""
    if not math.isfinite(value):
        raise ValueError("Non-finite affine arithmetic")
    try:
        result = struct.unpack("<f", struct.pack("<f", value))[0]
    except (OverflowError, struct.error) as error:
        raise ValueError("Affine control is not representable in F32") from error
    if not math.isfinite(result):
        raise ValueError("Affine control overflows F32")
    return result


def serialized_array(values, ggml_shape, np):
    """First GGML axis is contiguous: reconstruct original PyTorch axes."""
    if len(values) != math.prod(ggml_shape):
        raise ValueError("Tensor element count does not match its serialized shape")
    return np.asarray(values, dtype=np.float64).reshape(tuple(reversed(ggml_shape)))


def read_tensor(model, name, np, check):
    weights.verify_model_source(model, check, hash_content=False)
    tensor = model.tensor(name)
    if tensor.bytes > 8 * 1024 * 1024:
        raise ValueError("Selected tensor exceeds the 8 MiB statistics read budget")
    payload = bytearray()
    with model.path.open("rb") as stream:
        stream.seek(tensor.offset)
        while len(payload) < tensor.bytes:
            check()
            block = stream.read(min(weights.BLOCK_BYTES, tensor.bytes - len(payload)))
            if not block:
                raise ValueError("Truncated source during affine statistics")
            payload.extend(block)
    values = np.frombuffer(payload, dtype="<f2" if tensor.dtype == "f16" else "<f4").astype(np.float64)
    if not bool(np.isfinite(values).all()):
        raise ValueError(f"Non-finite value in {name}")
    weights.verify_model_source(model, check, hash_content=False)
    return serialized_array(values, tensor.shape, np)


def head_statistics(out, value, bias, heads, np, check=weights.no_cancel):
    """Static operator norms, not activation importance or hallucination causes.

    O_h has contiguous input columns; V_h and bV_h have contiguous output rows.
    Rectangular synthetic inputs exercise orientation independently of the square
    production matrices. einsum(optimize=False) avoids BLAS matrix-multiply pools.
    """
    if len(out.shape) != 2 or len(value.shape) != 2 or len(bias.shape) != 1:
        raise ValueError("Expected matrix O/V and vector bV")
    state = out.shape[1]
    if type(heads) is not int or not 0 < heads <= 12 or state % heads or value.shape[0] != state or bias.shape[0] != state:
        raise ValueError("Head boundaries do not match O input columns and V/bV output rows")
    if max((*out.shape, *value.shape, *bias.shape)) > 768:
        raise ValueError("Affine statistics exceed the 768-wide architecture bound")
    if not all(bool(np.isfinite(x).all()) for x in (out, value, bias)):
        raise ValueError("Non-finite source tensor")
    width = state // heads
    if not 0 < width <= 64:
        raise ValueError("Head dimension exceeds the 64-wide statistics bound")
    result = []
    for head in range(heads):
        check()
        first, last = head * width, (head + 1) * width
        oh, vh = out[:, first:last], value[first:last, :]
        og = np.einsum("ki,kj->ij", oh, oh, optimize=False)
        vg = np.einsum("ik,jk->ij", vh, vh, optimize=False)
        square = float(np.sum(og * vg.T, dtype=np.float64))
        if not math.isfinite(square) or square <= 0:
            raise ValueError("Zero or invalid content norm; head ratio is undefined")
        content = math.sqrt(square)
        constant = np.einsum("ij,j->i", oh, bias[first:last], optimize=False)
        norm = math.sqrt(float(np.sum(constant * constant, dtype=np.float64)))
        ratio = norm / content
        if not math.isfinite(ratio):
            raise ValueError("Non-finite affine/content ratio")
        result.append({"head": head, "head_constant_l2": norm, "head_OV_frobenius": content, "ratio": ratio})
    return result


def selected_head(rows):
    if not rows or any(not math.isfinite(row["ratio"]) for row in rows):
        raise ValueError("Need finite cross-head statistics")
    return min(rows, key=lambda row: (-row["ratio"], row["layer"], row["head"]))


def compensation(out_head, old_bias, out_bias, np, check=weights.no_cancel):
    """Preserve O_h bV_h + bO in real arithmetic, accounting for both F32 casts."""
    if out_head.shape != (len(out_bias), len(old_bias)):
        raise ValueError("Compensation head dimensions do not match their biases")
    old = [float(x) for x in old_bias]
    new = [f32(x * FACTOR) for x in old]
    if not any(x != y for x, y in zip(old, new)):
        raise ValueError("Selected bias has no representable F32 change")
    delta_bias = [y - x for x, y in zip(old, new)]
    delta, corrected, residual = [], [], []
    for index, row in enumerate(out_head):
        check()
        change = math.fsum(float(x) * y for x, y in zip(row, delta_bias))
        before = float(out_bias[index])
        after = f32(before - change)
        delta.append(change); corrected.append(after); residual.append(math.fsum([change, after, -before]))
    effect = math.sqrt(math.fsum(x * x for x in delta))
    error = math.sqrt(math.fsum(x * x for x in residual))
    if not math.isfinite(effect) or not effect > 0 or not math.isfinite(error):
        raise ValueError("Invalid or zero affine intervention effect")
    # A compensated control must be much smaller than the actual intervention,
    # not merely finite. This bound is mathematical, not a quality acceptance gate.
    if error > 1e-5 * effect:
        raise ValueError("F32 compensated control exceeds its relative residual budget")
    return corrected, {"changed_F32_bias_elements": sum(x != y for x, y in zip(old, new)),
        "removed_input_independent_offset_l2": effect,
        "compensation_residual_l2_float64": error,
        "compensation_residual_max_abs_float64": max(abs(x) for x in residual)}


def validate_architecture(model, identifier):
    h = model.architecture
    state, heads, layers = ARCHITECTURES[identifier]
    if (h["n_text_state"], h["n_text_head"], h["n_text_layer"]) != (state, heads, layers) or \
       (h["n_audio_state"], h["n_audio_head"], h["n_audio_layer"]) != (state, heads, layers) or \
       h["n_vocab"] != 51865 or h["n_text_ctx"] != 448 or h["n_mels"] != 80:
        raise ValueError(f"Original architecture does not match multilingual {identifier}")


def analyze_model(model, identifier, evidence, author, np, check):
    weights.verify_model_source(model, check)
    h = model.architecture
    rows = []
    for layer in range(h["n_text_layer"]):
        check()
        prefix = f"decoder.blocks.{layer}.cross_attn"
        out = read_tensor(model, prefix + ".out.weight", np, check)
        value = read_tensor(model, prefix + ".value.weight", np, check)
        bias = read_tensor(model, prefix + ".value.bias", np, check)
        rows.extend(dict(row, layer=layer) for row in head_statistics(out, value, bias, h["n_text_head"], np, check))
    chosen = selected_head(rows)
    width = h["n_text_state"] // h["n_text_head"]
    first = chosen["head"] * width
    prefix = f"decoder.blocks.{chosen['layer']}.cross_attn"
    tensor = model.tensor(prefix + ".value.bias")
    out_tensor = model.tensor(prefix + ".out.bias")
    if tensor.dtype != "f32" or out_tensor.dtype != "f32":
        raise ValueError("Affine recipes require original F32 value/output biases")
    out = read_tensor(model, prefix + ".out.weight", np, check)
    bias = read_tensor(model, tensor.name, np, check)
    out_bias = read_tensor(model, out_tensor.name, np, check)
    corrected, effects = compensation(out[:, first:first + width], bias[first:first + width], out_bias, np, check)
    edit = {"tensor": tensor.name, "shape": list(tensor.shape), "dtype": "f32", "op": "scale",
            "start": first, "count": width, "factor": FACTOR}
    common = {"schema_version": "1.0", "format": weights.FORMAT, "input_sha256": model.source_sha256,
              "development_evidence": list(evidence), "author": author}
    candidate = dict(common, hypothesis="Fixed 10% attenuation of one high affine/content-ratio cross-head value bias; static hypothesis, no causal or ASR improvement established",
                     edits=[edit])
    control = dict(common, hypothesis="Compensated affine identity control: same F32 value-bias attenuation, removed constant folded into F32 out.bias; numerical equivalence is approximate, not bit-exact inference",
                   edits=[dict(edit)] + [{"tensor": out_tensor.name, "shape": list(out_tensor.shape), "dtype": "f32", "op": "set", "index": index, "value": value}
                                          for index, value in enumerate(corrected)])
    for recipe in [candidate, control]:
        weights.validate_recipe(model, recipe)
    weights.verify_model_source(model, check)
    record = {"schema_version": VERSION, "model": identifier, "source_path": str(model.path),
        "source_sha256": model.source_sha256, "architecture": model.architecture,
        "selection_rule": "argmax ||O_h bV_h||_2 / ||O_h V_h||_F over all decoder cross heads; ties lower layer then head",
        "selected": chosen, "all_heads": rows, "head_dimension": width, "bias_factor": FACTOR,
        "candidate_edit_operations": 1, "candidate_changed_element_cap": width,
        "control_edit_operations": len(control["edits"]), "control_changed_element_cap": width + len(corrected),
        "expected_effect": effects, "development_evidence": list(evidence),
        "limitations": ["Static weight proxy, not observed activation importance or hallucination attribution",
                        "No head pruning, alignment mask, language mask, head search or gain grid",
                        "No ASR, training, corpus/reference/outcome reads, app change or default promotion",
                        "Compensated real-arithmetic identity may still change finite-precision decoding"]}
    return record, candidate, control


def prepare(models, output, *, evidence, author, seconds=120, cancel=None, check=weights.no_cancel):
    if not isinstance(models, list) or not 1 <= len(models) <= MAX_MODELS:
        raise ValueError("Choose at most three original models, sequentially")
    if not isinstance(evidence, list) or not evidence or not all(isinstance(x, str) and x.strip() for x in evidence) or \
       not isinstance(author, str) or not author.strip():
        raise ValueError("Record development-only evidence references and an author")
    if any(not isinstance(spec, dict) or set(spec) != {"id", "path", "sha256"} or spec["id"] not in ARCHITECTURES or
           not isinstance(spec["sha256"], str) or len(spec["sha256"]) != 64 or
           any(c not in "0123456789abcdef" for c in spec["sha256"]) for spec in models):
        raise ValueError("Each model needs tiny/base/small ID, exact original path and lowercase SHA-256")
    paths = [Path(spec["path"]).resolve(strict=True) for spec in models]
    if len({spec["id"] for spec in models}) != len(models) or len(set(paths)) != len(paths):
        raise ValueError("Duplicate model IDs or original paths")
    budget = weights.Cancellation(seconds, cancel)
    def checked():
        budget.check(); check()
    checked()
    np = numpy_runtime()
    tool_hash = weights.hash_file(Path(__file__), checked)
    editor_hash = weights.hash_file(Path(weights.__file__), checked)
    output = Path(output)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    records, sources = [], []
    try:
        for spec, path in zip(models, paths):
            checked()
            model = weights.inspect_model(path, weights.Limits(model_bytes=MAX_MODEL_BYTES), checked)
            sources.append(model)
            if model.source_sha256 != spec["sha256"]:
                raise ValueError(f"Original checksum mismatch: {spec['id']}")
            validate_architecture(model, spec["id"])
            weights.tensor_statistics(model, checked) # Full finite input scan, bounded block memory.
            record, candidate, control = analyze_model(model, spec["id"], evidence, author, np, checked)
            record["provenance"] = {"generator_sha256": tool_hash, "editor_sha256": editor_hash,
                "format_reference": weights.SOURCE_VERSION, "python": sys.version, "numpy": np.__version__,
                "numeric_workers": 1, "BLAS_matrix_multiply": False,
                "thread_environment": {key: os.environ.get(key) for key in THREAD_ENV},
                "source_after_sha256": weights.hash_file(path, checked, model.bytes)}
            if record["provenance"]["source_after_sha256"] != model.source_sha256:
                raise ValueError("Original changed during affine recipe generation")
            directory = output / spec["id"]
            directory.mkdir(mode=0o700)
            files = {"selection.json": record, "candidate.recipe.json": candidate,
                     "compensation-control.recipe.json": control}
            hashes = {}
            for name, value in files.items():
                checked()
                weights.write_new_json(directory / name, value)
                hashes[name] = weights.hash_file(directory / name, checked)
            records.append({"model": spec["id"], "source_sha256": model.source_sha256,
                            "selection": record["selected"], "files": hashes})
        for source in sources:
            weights.verify_model_source(source, checked)
        if weights.hash_file(Path(__file__), checked) != tool_hash or weights.hash_file(Path(weights.__file__), checked) != editor_hash:
            raise ValueError("Recipe generator or editor source changed during generation")
        completed = {"schema_version": VERSION, "state": "completed", "models": records,
                     "generator_sha256": tool_hash, "editor_sha256": editor_hash, "asr_executed": False,
                     "weights_modified": False, "originals_unchanged": True,
                     "recipe_count": len(records) * 2, "maximum_model_bytes": MAX_MODEL_BYTES,
                     "time_budget_seconds": seconds, "repetition_or_parameter_search": False}
        checked(); weights.write_new_json(output / "COMPLETED.json", completed)
        return completed
    except BaseException as error:
        failure = {"schema_version": VERSION, "state": "cancelled" if isinstance(error, (InterruptedError, KeyboardInterrupt)) else "failed",
                   "error": str(error), "completed_models": records, "asr_executed": False, "weights_modified": False}
        try:
            weights.write_new_json(output / "FAILED.json", failure)
        except OSError as persistence_error:
            error.add_note(f"Failure evidence could not be persisted: {persistence_error}")
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", action="append", required=True, metavar="ID=ORIGINAL_PATH")
    parser.add_argument("--sha256", action="append", required=True, metavar="ID=ORIGINAL_SHA256")
    parser.add_argument("--development-evidence", action="append", required=True)
    parser.add_argument("--author", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--cancel-file", type=Path)
    args = parser.parse_args(argv)
    def pairs(values):
        result = {}
        for value in values:
            name, separator, text = value.partition("=")
            if not separator or name in result or not text:
                parser.error("Use unique ID=value model/hash pairs")
            result[name] = text
        return result
    paths, hashes = pairs(args.model), pairs(args.sha256)
    if paths.keys() != hashes.keys():
        parser.error("Provide exactly one original SHA-256 for each model")
    requested = False
    def stop(*_):
        nonlocal requested
        requested = True
    signal.signal(signal.SIGINT, stop); signal.signal(signal.SIGTERM, stop)
    def check():
        if requested:
            raise InterruptedError("Affine recipe generation cancelled; partial evidence retained")
    try:
        result = prepare([{"id": name, "path": path, "sha256": hashes[name]} for name, path in paths.items()],
                         args.output, evidence=args.development_evidence, author=args.author,
                         seconds=args.timeout, cancel=args.cancel_file, check=check)
        print(f"Prepared {result['recipe_count']} recipes; no weights changed or ASR run; evidence: {args.output}")
    except (OSError, ValueError, TimeoutError, InterruptedError) as error:
        print(str(error), file=sys.stderr)
        return 130 if isinstance(error, InterruptedError) else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
