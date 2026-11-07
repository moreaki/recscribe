#!/usr/bin/env python3
"""Fixed activation-aware channel conditioning for unquantized Whisper GGML.

This offline research tool never runs ASR, a quantizer, training or downloads.
It changes stored weights with one predeclared rule; it establishes no quality
gain. Test balanced-F16 preservation and plain/balanced Q5_1 independently.

  channel-balance.py calibrate WRAPPER.json --output NEW-calibration.json
  channel-balance.py apply MODEL --sha256 SHA --calibration CAL.json \
      --calibration-sha256 SHA --output NEW-DIRECTORY --timeout 600

Wrapper schema channel-balance-probe-manifest-v1:
  model={id:tiny|base|small,sha256:SHA};
  development_manifest={path:ABSOLUTE_JSON,sha256:ORIGINAL_27_DEV_SHA};
  probe={executable_sha256:SHA,source_sha256:SHA,native_source_commit:HEX};
  cases=[{id,language,source_sha256,reference_sha256,probe:{path,sha256}}].
Only explicit metadata JSONs are read; audio/reference/text paths are ignored.
Each native probe must be complete, original-vs-observed logit-identical, and
record all post-affine decoder LN sites for one prefix (four special positions
plus at most60 published-reference tokens). No raw token/activation text needed.

A_j is the equal mean of27 per-case mean-absolute post-affine LN activations
(three cases/language), not a pooled token average. Fixed scales are
  s_j=clamp(sqrt(A_j/GM(A_positive)),0.25,4).
Exactly-zero channels use s=1 and are excluded from the GM; all-zero sites fail.
Gamma and beta divide by s; every receiving linear's input columns multiply by
s. Real-arithmetic outputs agree. Stored F32/F16 rounding is explicit, so this
is not a promise of bitwise or transcript equivalence.

Mean-absolute statistics and LN/linear absorption are AWQ-inspired; unlike the
official implementation this tool performs no scale-ratio/error search:
https://github.com/mit-han-lab/llm-awq/blob/main/awq/quantize/auto_scale.py
GGML first axis is contiguous (original PyTorch input columns). Consumers:
self-attn LN ->Q,K,V; cross-attn LN ->Q only; MLP LN ->MLP.0. Cross K/V receive
encoder features and MUST NOT be scaled from decoder cross-attn-LN statistics.
Existing ggml_weights.py remains unchanged; its format, source, ownership and
byte-preservation helpers are reused without its selective-recipe edit limit.
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
import signal
import stat
import struct
import sys

for _key in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
             "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "BLIS_NUM_THREADS"):
    os.environ[_key] = "1"
_SPEC = importlib.util.spec_from_file_location("_channel_balance_ggml", Path(__file__).with_name("ggml_weights.py"))
weights = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = weights
_SPEC.loader.exec_module(weights)

VERSION = "whisper-channel-balance-v1"
CALIBRATION_VERSION = "channel-balance-calibration-v1"
DEVELOPMENT_SHA = "c030afc5394a1774d317c70ce9f404145b20cb4700f14d8da271a699673a4ed8"
NATIVE_SOURCE_COMMIT = "d1be6fde11ac6e0407606b4e42fe72d34add8037"
LANGUAGES = ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt")
GEOMETRIES = {"tiny": (384, 6, 4), "base": (512, 8, 6), "small": (768, 12, 12)}
MAX_PREFIX = 64
MAX_METADATA = 32 * 1024 * 1024
MAX_PROBE = 8 * 1024 * 1024
MAX_CASES = 27
MAX_CHANNELS = 768
MAX_LAYERS = 12
SCALE_MIN, SCALE_MAX = .25, 4.
BLOCK_ELEMENTS = 32_768
PROBE_RUNTIME = {"threads": 2, "use_gpu": True, "flash_attention": False,
                 "encoder_passes": 1, "decoder_passes": 2}


def require(value, message):
    if not value:
        raise ValueError(message)


def finite(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def close(left, right):
    return finite(left) and finite(right) and math.isclose(left, right, rel_tol=1e-8, abs_tol=1e-12)


def metadata(path, maximum=MAX_METADATA, expected=None):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and path.suffix == ".json"
            and not any(item.is_symlink() for item in (path, *path.parents)), "Use explicit absolute nonsymlink JSON metadata paths")
    require(stat.S_ISREG(path.stat().st_mode), "Calibration metadata must be a regular file")
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    require(len(data) <= maximum, "Calibration metadata exceeds its size bound")
    sha = hashlib.sha256(data).hexdigest()
    require(expected is None or valid_hash(expected) and sha == expected, "Calibration/probe metadata checksum differs")
    def fields(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, "Duplicate calibration metadata field")
            value[key] = item
        return value
    def nonfinite(_):
        raise ValueError("Nonfinite JSON calibration constant")
    value = json.loads(data, object_pairs_hook=fields, parse_constant=nonfinite)
    require(isinstance(value, dict), "Calibration metadata root must be an object")
    return value, sha


def external(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts
            and not any(item.is_symlink() for item in (path, *path.parents)), "Use a new external nonsymlink output")
    # A retained copy is intentionally executable outside the checkout. Its
    # grandparents may be protected research data, not a repository root.
    # Inspect the OUTPUT ancestry so a copied helper cannot write into another
    # checkout; a .git file covers linked worktrees as well as .git directories.
    require(not any((ancestor / ".git").exists() or (ancestor / ".git").is_symlink()
                    for ancestor in (path, *path.parents)), "Output must be outside every Git checkout")
    location = Path(__file__).resolve()
    if location.parent.name == "quality" and location.parent.parent.name == "scripts":
        repo = location.parents[2]
        # Source archives may lack .git. Only this verified project layout
        # establishes a fallback boundary; an arbitrary copied path does not.
        if (repo / "scripts/quality/ggml_weights.py").is_file() and (repo / "AGENTS.md").is_file():
            require(path != repo and repo not in path.parents, "Output must be outside the source checkout")
    require(path.parent.is_dir() and not path.exists(), "Output must be new and its parent must exist")
    return path


def validate_geometry(geometry, model_id):
    require(model_id in GEOMETRIES, "Only multilingual Tiny/Base/Small are supported")
    state, heads, layers = GEOMETRIES[model_id]
    require((geometry.get("n_text_state"), geometry.get("n_text_head", heads), geometry.get("n_text_layer")) == (state, heads, layers)
            and geometry.get("n_vocab") == 51865, "Calibration/model geometry differs from pinned multilingual architecture")
    for field, expected in (("n_audio_state", state), ("n_audio_head", heads), ("n_audio_layer", layers), ("n_mels", 80), ("ftype", 1)):
        require(field not in geometry or geometry[field] == expected, "Only the original unquantized multilingual layout is supported")
    return state, layers


def site_specs(state, layers):
    require(type(state) is int and 0 < state <= MAX_CHANNELS and type(layers) is int and 0 < layers <= MAX_LAYERS, "Site geometry exceeds its explicit bound")
    result = []
    for layer in range(layers):
        prefix = f"decoder.blocks.{layer}"
        for suffix, receivers in (("attn_ln", ("attn.query.weight", "attn.key.weight", "attn.value.weight")),
                                  ("cross_attn_ln", ("cross_attn.query.weight",)),
                                  ("mlp_ln", ("mlp.0.weight",))):
            site = prefix + "." + suffix
            result.append({"site": site, "normalization": (site + ".weight", site + ".bias"),
                           "receivers": tuple(prefix + "." + value for value in receivers)})
    return result


def source_cases(document):
    require(document.get("schema_version") == "1.0" and not document.get("errors"), "Expected the unchanged original development manifest")
    cases = document.get("cases")
    require(isinstance(cases, list) and len(cases) == MAX_CASES and all(isinstance(case, dict) for case in cases), "Exactly27 original development cases required")
    indexed = {}
    for case in cases:
        identity, language = case.get("id"), case.get("language")
        require(isinstance(identity, str) and identity and identity not in indexed and language in LANGUAGES
                and valid_hash(case.get("sha256")) and valid_hash(case.get("reference_sha256")), "Development source/hash identity is incomplete")
        indexed[identity] = {"id": identity, "language": language, "source_sha256": case["sha256"], "reference_sha256": case["reference_sha256"]}
    require(all(sum(case["language"] == language for case in indexed.values()) == 3 for language in LANGUAGES), "Exactly3 cases per priority language required")
    return indexed


def validate_probe(probe, case, expected_commit, model_id):
    require(probe.get("schema_version") == "whisper-ln-activation-probe-v1" and probe.get("status") == "complete"
            and probe.get("native_version") == "1.9.5" and probe.get("source_commit") == expected_commit == NATIVE_SOURCE_COMMIT,
            "Native probe is incomplete or uses another runtime")
    geometry = probe.get("geometry", {})
    state, layers = validate_geometry(geometry, model_id)
    conditioning = probe.get("conditioning", {})
    total, used, positions = (conditioning.get(key) for key in ("reference_tokens_total", "reference_tokens_used", "prefix_positions"))
    require(conditioning.get("method") == "published-development-reference-prefix"
            and all(type(value) is int for value in (total, used, positions)) and total > 0 and used == min(total, 60)
            and positions == 4 + used and 4 <= positions <= MAX_PREFIX
            and type(conditioning.get("source_audio_samples")) is int and 0 < conditioning["source_audio_samples"] <= 30 * 16_000
            and conditioning.get("explicit_language") == case["language"].split("-", 1)[0], "Probe must use the fixed valid64-position original-reference prefix")
    require(valid_hash(conditioning.get("prefix_sha256")) and conditioning.get("prefix_hash_encoding") == "u32-le-token-ids-v1"
            and conditioning.get("reference_input_sha256") == case["reference_sha256"], "Native prefix/raw-reference hash binding is missing or differs")
    require(all(type(conditioning.get(key)) is type(value) and conditioning[key] == value for key, value in PROBE_RUNTIME.items()),
            "Probe runtime differs from fixed two-thread GPU/non-flash one-encoder/two-decoder policy")
    identity = probe.get("identity", {})
    require(identity.get("bitwise_equal") is True and identity.get("max_abs_logit_difference") == 0
            and type(identity.get("argmax_mismatch_positions")) is int and identity["argmax_mismatch_positions"] == 0
            and type(identity.get("compared_logits")) is int and identity["compared_logits"] == positions * geometry["n_vocab"],
            "Observation hook changed logits or lacks complete identity evidence")
    targets = probe.get("targets")
    specs = {item["site"] for item in site_specs(state, layers)}
    require(isinstance(targets, list) and len(targets) == len(specs) and all(isinstance(value, dict) for value in targets)
            and {value.get("site") for value in targets} == specs, "Missing/duplicate/extra post-affine LN probe site")
    means = {}
    for value in targets:
        require(all(type(value.get(key)) is int for key in ("channels", "observations", "count"))
                and value["channels"] == state and value["observations"] == 1 and value["count"] == positions,
                "Each post-affine site must observe exactly its valid prefix positions once")
        arrays = {key: value.get(key) for key in ("sum_abs", "sum_squares", "max_abs", "mean_abs", "rms")}
        require(all(isinstance(vector, list) and len(vector) == state and all(finite(x) and x >= 0 for x in vector) for vector in arrays.values()),
                "Missing/nonfinite/negative channel statistics")
        for j in range(state):
            require(close(arrays["mean_abs"][j], arrays["sum_abs"][j] / positions)
                    and close(arrays["rms"][j], math.sqrt(arrays["sum_squares"][j] / positions))
                    and arrays["max_abs"][j] + 1e-12 >= arrays["mean_abs"][j], "Probe channel reductions disagree")
        means[value["site"]] = list(arrays["mean_abs"])
    return geometry, {"prefix_positions": positions, "reference_tokens_total": total, "reference_tokens_used": used,
                      "source_audio_samples": conditioning["source_audio_samples"], "prefix_sha256": conditioning["prefix_sha256"],
                      "prefix_hash_encoding": conditioning["prefix_hash_encoding"], "reference_input_sha256": conditioning["reference_input_sha256"],
                      "probe_runtime": dict(PROBE_RUNTIME), "sites": means}


def calibrate(wrapper_path, output, check=weights.no_cancel):
    wrapper, wrapper_sha = metadata(wrapper_path, 2 * 1024 * 1024)
    require(wrapper.get("schema_version") == "channel-balance-probe-manifest-v1", "Unsupported probe wrapper schema")
    model, producer = wrapper.get("model", {}), wrapper.get("probe", {})
    require(model.get("id") in GEOMETRIES and valid_hash(model.get("sha256")), "Wrapper requires explicit model ID/hash")
    require(valid_hash(producer.get("executable_sha256")) and valid_hash(producer.get("source_sha256"))
            and producer.get("native_source_commit") == NATIVE_SOURCE_COMMIT, "Probe executable/source identities are incomplete or use another native revision")
    manifest = wrapper.get("development_manifest", {})
    require(manifest.get("sha256") == DEVELOPMENT_SHA, "Only the frozen original27 development manifest may calibrate scales")
    development, manifest_sha = metadata(manifest.get("path", ""), 2 * 1024 * 1024, DEVELOPMENT_SHA)
    expected = source_cases(development)
    cases = wrapper.get("cases")
    require(isinstance(cases, list) and len(cases) == MAX_CASES and all(isinstance(case, dict) for case in cases)
            and {case.get("id") for case in cases} == set(expected), "Wrapper case membership differs from original27 development")
    records, geometry = [], None
    for case in cases:
        check(); source = expected[case["id"]]
        require(all(case.get(key) == value for key, value in source.items()), "Wrapper source/audio/reference identity differs from frozen development")
        binding = case.get("probe", {})
        require(valid_hash(binding.get("sha256")), "Every probe JSON needs an external hash binding")
        document, probe_sha = metadata(binding.get("path", ""), MAX_PROBE, binding["sha256"])
        current, record = validate_probe(document, case, producer["native_source_commit"], model["id"])
        require(geometry is None or geometry == current, "Probe geometry changes between cases")
        geometry = current
        records.append({**source, "probe_sha256": probe_sha, **record})
    result = {"schema_version": CALIBRATION_VERSION, "status": "complete", "model_id": model["id"], "model_sha256": model["sha256"],
        "split": "development", "development_manifest_sha256": manifest_sha, "geometry": geometry,
        "statistic": "equal_case_mean_of_post_affine_ln_mean_absolute_activation", "prefix_policy": "four_special_positions_then_first_at_most_60_published_reference_tokens",
        "maximum_prefix_positions": MAX_PREFIX, "wrapper_sha256": wrapper_sha, "probe": producer,
        "cases": sorted(records, key=lambda value: value["id"]), "training_used": False, "scale_search_used": False,
        "created_utc": datetime.now(timezone.utc).isoformat(), "generator_sha256": weights.hash_file(Path(__file__), check)}
    validate_calibration(result)
    check(); output = external(output)
    weights.write_new_json(output, result)
    return result


def validate_calibration(value):
    require(value.get("schema_version") == CALIBRATION_VERSION and value.get("status") == "complete" and value.get("split") == "development"
            and value.get("development_manifest_sha256") == DEVELOPMENT_SHA and valid_hash(value.get("model_sha256"))
            and value.get("statistic") == "equal_case_mean_of_post_affine_ln_mean_absolute_activation"
            and value.get("prefix_policy") == "four_special_positions_then_first_at_most_60_published_reference_tokens"
            and value.get("maximum_prefix_positions") == MAX_PREFIX and value.get("training_used") is False and value.get("scale_search_used") is False,
            "Calibration must retain the fixed original-development/statistic/prefix policy")
    producer = value.get("probe", {})
    require(valid_hash(value.get("wrapper_sha256")) and isinstance(producer, dict)
            and valid_hash(producer.get("executable_sha256")) and valid_hash(producer.get("source_sha256"))
            and producer.get("native_source_commit") == NATIVE_SOURCE_COMMIT,
            "Calibration lacks the externally hash-bound wrapper/probe provenance")
    state, layers = validate_geometry(value.get("geometry", {}), value.get("model_id"))
    specs = {item["site"] for item in site_specs(state, layers)}
    cases = value.get("cases")
    require(isinstance(cases, list) and len(cases) == MAX_CASES and all(isinstance(case, dict) for case in cases)
            and len({case.get("id") for case in cases}) == MAX_CASES, "Calibration needs27 distinct original-development cases")
    for case in cases:
        require(isinstance(case.get("id"), str) and case["id"] and case.get("language") in LANGUAGES
                and valid_hash(case.get("source_sha256")) and valid_hash(case.get("reference_sha256")) and valid_hash(case.get("probe_sha256")), "Calibration source/probe identities are absent")
        positions, used, total = (case.get(key) for key in ("prefix_positions", "reference_tokens_used", "reference_tokens_total"))
        require(all(type(v) is int for v in (positions, used, total)) and total > 0 and used == min(total, 60)
                and positions == 4 + used and positions <= MAX_PREFIX, "Calibration prefix count exceeds the fixed policy")
        require(type(case.get("source_audio_samples")) is int and 0 < case["source_audio_samples"] <= 30 * 16_000
                and valid_hash(case.get("prefix_sha256")) and case.get("prefix_hash_encoding") == "u32-le-token-ids-v1"
                and case.get("reference_input_sha256") == case["reference_sha256"] and case.get("probe_runtime") == PROBE_RUNTIME,
                "Calibration lost the bounded native prefix/reference/runtime provenance")
        sites = case.get("sites")
        require(isinstance(sites, dict) and set(sites) == specs and all(isinstance(vector, list) and len(vector) == state
                and all(finite(x) and x >= 0 for x in vector) for vector in sites.values()), "Incomplete/nonfinite post-affine calibration site")
    require(all(sum(case["language"] == language for case in cases) == 3 for language in LANGUAGES), "Calibration must weight exactly3 cases per language equally")
    return state, layers


def channel_scales(importance):
    require(isinstance(importance, (list, tuple)) and 0 < len(importance) <= MAX_CHANNELS
            and all(finite(value) and value >= 0 for value in importance), "Channel importance must be finite/nonnegative")
    logs = [math.log(value) for value in importance if value > 0]
    require(bool(logs), "An all-zero activation site cannot define channel balance")
    mean_log = math.fsum(logs) / len(logs)
    low, high = math.log(SCALE_MIN), math.log(SCALE_MAX)
    scales = [1. if value == 0 else math.exp(min(high, max(low, .5 * (math.log(value) - mean_log)))) for value in importance]
    require(all(finite(value) and SCALE_MIN <= value <= SCALE_MAX for value in scales), "Invalid fixed analytic scale")
    return {"mean_abs": list(importance), "positive_geometric_mean": math.exp(mean_log), "zero_channels": sum(value == 0 for value in importance),
            "clamped_low": sum(value == SCALE_MIN for value in scales), "clamped_high": sum(value == SCALE_MAX for value in scales), "scales": scales}


def scale_plan(calibration):
    state, layers = validate_calibration(calibration)
    sites = {}
    for specification in site_specs(state, layers):
        name = specification["site"]
        importance = [math.fsum(case["sites"][name][j] for case in calibration["cases"]) / MAX_CASES for j in range(state)]
        sites[name] = {**specification, **channel_scales(importance)}
    return {"schema_version": VERSION, "operator": "post_affine_ln_divide_and_all_receiver_input_columns_multiply",
        "alpha": .5, "scale_min": SCALE_MIN, "scale_max": SCALE_MAX, "normalizer": "positive_channel_geometric_mean;zero_channels_scale1",
        "case_weighting": "equal_utterance;27cases;3per_language;not_pooled_tokens", "model_id": calibration["model_id"],
        "model_sha256": calibration["model_sha256"], "geometry": calibration["geometry"], "sites": sites}


def tensor_plan(model, plan):
    state, layers = validate_geometry(model.architecture, plan["model_id"])
    require(model.architecture["ftype"] == 1 and model.architecture["n_text_state"] == plan["geometry"]["n_text_state"]
            and model.architecture["n_text_layer"] == plan["geometry"]["n_text_layer"], "Original model/calibration layout differs")
    specifications = site_specs(state, layers)
    require(set(plan["sites"]) == {item["site"] for item in specifications}, "Scale plan changed the complete fanout")
    result = []
    for specification in specifications:
        scales = plan["sites"][specification["site"]]["scales"]
        for name in specification["normalization"]:
            tensor = model.tensor(name)
            require(tensor.shape == (state,) and tensor.dtype == "f32", "LN affine tensors must retain original F32 channels")
            result.append((tensor, scales, "divide"))
        for name in specification["receivers"]:
            tensor = model.tensor(name); rows = 4 * state if name.endswith("mlp.0.weight") else state
            require(tensor.shape == (state, rows) and tensor.dtype == "f16", "Receiver must retain the original GGML input-first F16 matrix")
            result.append((tensor, scales, "multiply_input_columns"))
    require(len({tensor.name for tensor, _, _ in result}) == 11 * layers
            and sum(t.elements for t, _, op in result if op != "divide") == 8 * state * state * layers
            and sum(t.elements for t, _, op in result if op == "divide") == 6 * state * layers,
            "Channel balancing exceeded or omitted its exact tensor budget")
    return result


def converted_block(before, dtype, scales, start, operation, numpy=None):
    require(dtype in {"f16", "f32"} and type(start) is int and start >= 0, "Invalid tensor dtype or block offset")
    width, code = (2, "e") if dtype == "f16" else (4, "f")
    require(len(before) % width == 0 and operation in {"divide", "multiply_input_columns"}, "Invalid aligned tensor block")
    count, channels = len(before) // width, len(scales)
    require(count <= BLOCK_ELEMENTS and 0 < channels <= MAX_CHANNELS
            and all(finite(value) and SCALE_MIN <= value <= SCALE_MAX for value in scales), "Invalid or unbounded tensor scales/block")
    if numpy is not None:
        np = numpy
        values = np.frombuffer(before, dtype="<f2" if dtype == "f16" else "<f4").astype(np.float64)
        require(bool(np.isfinite(values).all()), "Original selected tensor is nonfinite")
        factors = np.asarray(scales, dtype=np.float64)[(np.arange(count, dtype=np.int64) + start) % channels]
        with np.errstate(over="ignore", invalid="ignore", divide="ignore"):
            transformed = values / factors if operation == "divide" else values * factors
            cast = transformed.astype("<f2" if dtype == "f16" else "<f4")
        require(bool(np.isfinite(transformed).all()) and bool(np.isfinite(cast).all()), "Channel edit overflows the original dtype")
        after = cast.tobytes()
        unsigned = "<u2" if width == 2 else "<u4"
        changed = int(np.count_nonzero(np.frombuffer(before, dtype=unsigned) != np.frombuffer(after, dtype=unsigned)))
        return after, changed
    after, changed = bytearray(), 0
    for j, (old,) in enumerate(struct.iter_unpack("<" + code, before)):
        require(math.isfinite(old), "Original selected tensor is nonfinite")
        factor = scales[(start + j) % channels]
        value = old / factor if operation == "divide" else old * factor
        require(math.isfinite(value), "Nonfinite channel edit")
        try:
            packed = struct.pack("<" + code, value)
        except (OverflowError, struct.error) as error:
            raise ValueError("Channel edit overflows the original dtype") from error
        require(math.isfinite(struct.unpack("<" + code, packed)[0]), "Channel edit overflows the original dtype")
        changed += packed != before[j * width:(j + 1) * width]
        after.extend(packed)
    return bytes(after), changed


def apply_balance(source, expected_hash, calibration_path, calibration_hash, output, check=weights.no_cancel):
    require(valid_hash(expected_hash) and valid_hash(calibration_hash), "Explicit original/calibration SHA256 locks required")
    calibration, observed_calibration = metadata(calibration_path, MAX_METADATA, calibration_hash)
    plan = scale_plan(calibration)
    require(plan["model_sha256"] == expected_hash, "Calibration is bound to another original model")
    source = Path(source).resolve(strict=True)
    model = weights.inspect_model(source, check=check)
    require(model.source_sha256 == expected_hash, "Original model checksum differs")
    tensors = tensor_plan(model, plan)
    weights.tensor_statistics(model, check)  # Whole original finite scan, bounded one-worker blocks.
    generator_sha = weights.hash_file(Path(__file__), check)
    parser_sha = weights.hash_file(Path(weights.__file__), check)
    check()
    output = external(output); output.mkdir(mode=0o700, exist_ok=False)
    partial, final, audit_path = output / "model.partial.bin", output / "model.bin", output / "balance-audit.json"
    ownership = None
    audit = {"schema_version": VERSION, "state": "editing", "source_path": str(source), "source_sha256": expected_hash,
        "calibration_sha256": observed_calibration, "file_bytes": model.bytes, "original_open_mode": "read_only",
        "created_utc": datetime.now(timezone.utc).isoformat(), "generator_sha256": generator_sha,
        "parser_sha256": parser_sha, "python": sys.version,
        "copied_bytes": 0, "edits": [], "training_used": False, "scale_search_used": False,
        "inference_or_quantization_executed": False, "quality_claim": "UNMEASURED; separately test balanced-F16 identity and plain/balanced Q5_1",
        "selected_f16_elements": sum(t.elements for t, _, op in tensors if op != "divide"),
        "selected_f32_elements": sum(t.elements for t, _, op in tensors if op == "divide")}
    try:
        plan_path = output / "scales.json"; weights.write_new_json(plan_path, plan)
        audit["scales_sha256"] = weights.hash_file(plan_path, check)
        digest = hashlib.sha256()
        with source.open("rb") as original, partial.open("xb") as target:
            ownership = weights.artifact_identity(partial); os.chmod(partial, 0o600)
            remaining = model.bytes
            while remaining:
                check(); block = original.read(min(weights.BLOCK_BYTES, remaining))
                require(bool(block), "Original truncated during copy")
                target.write(block); digest.update(block); audit["copied_bytes"] += len(block); remaining -= len(block)
            require(not original.read(1), "Original grew during copy")
            target.flush(); os.fsync(target.fileno())
        require(digest.hexdigest() == expected_hash and audit["copied_bytes"] == model.bytes, "Original changed during copy")
        try:
            import numpy as np
        except ImportError:
            np = None
        audit["arithmetic"] = "Python float64/struct original-dtype rounding" if np is None else "NumPy " + np.__version__ + ";float64 multiply/divide then original-dtype cast"
        weights.require_owned_artifact(partial, ownership)
        descriptor = os.open(partial, os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "r+b") as target:
            require((os.fstat(target.fileno()).st_dev, os.fstat(target.fileno()).st_ino) == ownership, "Created artifact was replaced")
            for tensor, scales, operation in tensors:
                check(); width = 2 if tensor.dtype == "f16" else 4
                before_hash, after_hash, changed = hashlib.sha256(), hashlib.sha256(), 0
                for start in range(0, tensor.elements, BLOCK_ELEMENTS):
                    check(); count = min(BLOCK_ELEMENTS, tensor.elements - start)
                    target.seek(tensor.offset + start * width); before = target.read(count * width)
                    require(len(before) == count * width, "Created tensor was truncated")
                    after, delta = converted_block(before, tensor.dtype, scales, start, operation, np)
                    before_hash.update(before); after_hash.update(after); changed += delta
                    target.seek(tensor.offset + start * width); target.write(after)
                audit["edits"].append({"tensor": tensor.name, "shape": list(tensor.shape), "dtype": tensor.dtype,
                    "operation": operation, "selected_elements": tensor.elements, "changed_elements": changed,
                    "before_sha256": before_hash.hexdigest(), "after_sha256": after_hash.hexdigest()})
            target.flush(); os.fsync(target.fileno())
        require(sum(value["changed_elements"] for value in audit["edits"]) > 0, "Balance made no representable weight change")
        weights.require_owned_artifact(partial, ownership)
        derived = weights.inspect_model(partial, check=check)
        require(derived.architecture == model.architecture and derived.tensors == model.tensors and derived.vocabulary_sha256 == model.vocabulary_sha256,
                "Balancing changed headers, layout or vocabulary")
        ranges = [(tensor.offset, tensor.offset + tensor.bytes) for tensor, _, _ in tensors]
        audit["unchanged_regions_sha256"] = weights.unchanged_regions_equal(source, partial, model.bytes, ranges, check)
        weights.verify_model_source(model, check); weights.verify_model_source(derived, check)
        audit.update(state="verified", derived_sha256=derived.source_sha256, artifact=partial.name,
            finite_validation="Whole original scanned; all selected derived values finite; unselected bytes identical",
            outside_declared_changed_bytes=0, vocabulary_sha256=model.vocabulary_sha256)
        weights.write_new_json(audit_path, audit); check(); weights.require_owned_artifact(partial, ownership)
        os.link(partial, final); partial.unlink()
        audit.update(state="completed", artifact=final.name); weights.update_owned_audit(audit_path, audit)
        return audit
    except BaseException as error:
        audit.update(state="canceled" if isinstance(error, (InterruptedError, KeyboardInterrupt, TimeoutError)) else "failed", error=str(error))
        if ownership is not None:
            try:
                if final.exists():
                    weights.require_owned_artifact(final, ownership)
                    quarantine = output / "model.failed.bin"; os.link(final, quarantine, follow_symlinks=False); final.unlink()
            except (OSError, ValueError) as failure:
                audit["quarantine_error"] = str(failure)
        audit["retained_artifacts"] = [path.name for path in (partial, final, output / "model.failed.bin") if path.exists()]
        try:
            if audit_path.exists(): weights.update_owned_audit(audit_path, audit)
            else: weights.write_new_json(audit_path, audit)
        except BaseException as failure:
            if hasattr(error, "add_note"): error.add_note("Failure audit persistence failed: " + str(failure))
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    assemble = commands.add_parser("calibrate"); assemble.add_argument("wrapper", type=Path); assemble.add_argument("--output", required=True, type=Path)
    apply = commands.add_parser("apply"); apply.add_argument("model", type=Path); apply.add_argument("--sha256", required=True)
    apply.add_argument("--calibration", required=True, type=Path); apply.add_argument("--calibration-sha256", required=True)
    apply.add_argument("--output", required=True, type=Path)
    for child in (assemble, apply):
        child.add_argument("--timeout", type=float, default=600); child.add_argument("--cancel-marker", type=Path)
    args = parser.parse_args(argv); cancellation = weights.Cancellation(args.timeout, args.cancel_marker)
    previous = {}
    def canceled(_signal, _frame): cancellation.requested = True
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, canceled)
    try:
        if args.command == "calibrate":
            result = calibrate(args.wrapper, args.output, cancellation.check)
            print(json.dumps({"calibration": str(args.output), "model": result["model_id"], "cases": len(result["cases"]),
                              "sha256": weights.hash_file(args.output, cancellation.check), "model_weights_changed": False}))
        else:
            result = apply_balance(args.model, args.sha256, args.calibration, args.calibration_sha256, args.output, cancellation.check)
            print(json.dumps({"output": str(args.output), "state": result["state"], "source_sha256": result["source_sha256"],
                              "derived_sha256": result["derived_sha256"], "file_bytes": result["file_bytes"], "quality": "unmeasured"}))
    finally:
        for number, handler in previous.items(): signal.signal(number, handler)
    return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except (ValueError, OSError, InterruptedError, TimeoutError) as error: raise SystemExit(type(error).__name__ + ": " + str(error))
