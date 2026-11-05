#!/usr/bin/env python3
"""Inspect and selectively edit derived, unquantized Whisper GGML artifacts.

Offline research only; no recognition, training, downloads or app dependencies.
Format pinned to whisper.cpp v1.9.5's loader and convert-pt-to-ggml.py:
https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp
https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/models/convert-pt-to-ggml.py

GGML dimensions are recorded first-axis-contiguous, the reverse of the original
PyTorch shape. Flat edit indices follow serialized file order. Quantized/GGUF or
other export layouts fail explicitly. Existing originals are never opened writable.
"""
import argparse
import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import stat
import struct
import sys
import tempfile
import time

FORMAT = "whisper-ggml-unquantized-v1"
SOURCE_VERSION = "whisper.cpp-v1.9.5"
MAGIC = 0x67676D6C
HEADER_FIELDS = ("n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
                 "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer", "n_mels", "ftype")
DTYPES = {0: ("f32", 4, "f"), 1: ("f16", 2, "e")}
BLOCK_BYTES = 256 * 1024
BLOCK_ELEMENTS = 32_768
MAX_JSON_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class Limits:
    model_bytes: int = 512 * 1024 * 1024
    vocabulary_bytes: int = 32 * 1024 * 1024
    tokens: int = 65_536
    token_bytes: int = 16_384
    tensors: int = 8192
    tensor_name_bytes: int = 512
    changed_elements: int = 1_048_576
    edit_operations: int = 1024


class Cancellation:
    def __init__(self, seconds=120, marker=None):
        if not math.isfinite(seconds) or not 0 < seconds <= 600:
            raise ValueError("Choose a positive timeout of at most 600 seconds")
        self.deadline = time.monotonic() + seconds
        self.marker = Path(marker) if marker else None
        self.requested = False

    def check(self):
        if self.requested or self.marker and self.marker.exists():
            raise InterruptedError("Weight research canceled; originals and partial evidence retained")
        if time.monotonic() >= self.deadline:
            raise TimeoutError("Weight research exceeded its explicit time budget")


def no_cancel():
    pass


def hash_file(path, check=no_cancel, expected_bytes=None):
    digest = hashlib.sha256()
    consumed = 0
    with Path(path).open("rb") as stream:
        while True:
            check()
            block = stream.read(BLOCK_BYTES)
            if not block:
                if expected_bytes is not None and consumed != expected_bytes:
                    raise ValueError("Model changed size while hashing")
                return digest.hexdigest()
            digest.update(block)
            consumed += len(block)
            if expected_bytes is not None and consumed > expected_bytes:
                raise ValueError("Model grew beyond its inspected size")


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def write_new_json(path, value):
    path = Path(path)
    with path.open("xb") as stream:
        stream.write(json_bytes(value))
        stream.flush()
        os.fsync(stream.fileno())


def update_owned_audit(path, value):
    """Atomically update only this new output directory's lifecycle manifest."""
    descriptor, name = tempfile.mkstemp(prefix=".edit-audit.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(json_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        # Remove only this call's unpublished temporary audit. A later failure
        # update gets a new name and cannot collide with an earlier failed write.
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            # The unique unpublished temp cannot block a later audit update.
            # Preserve the write/replace failure if cleanup is also unavailable.
            pass


def file_identity(status):
    return (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns)


def read_json(path):
    with Path(path).open("rb") as stream:
        raw = stream.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError("Recipe exceeds the 4 MiB limit")
    def unique_fields(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"Duplicate recipe field: {key}")
            value[key] = item
        return value
    def reject_constant(value):
        raise ValueError(f"Non-finite JSON value: {value}")
    return json.loads(raw, object_pairs_hook=unique_fields, parse_constant=reject_constant)


@dataclass(frozen=True)
class Tensor:
    name: str
    shape: tuple
    dtype: str
    type_id: int
    offset: int
    elements: int
    bytes: int


@dataclass(frozen=True)
class Token:
    index: int
    offset: int
    bytes: int


@dataclass(frozen=True)
class Model:
    path: Path
    bytes: int
    architecture: dict
    mel_shape: tuple
    vocabulary: tuple
    vocabulary_sha256: str
    tensors: tuple
    source_identity: tuple
    source_sha256: str

    def tensor(self, name):
        for tensor in self.tensors:
            if tensor.name == name:
                return tensor
        raise ValueError(f"Unknown tensor: {name}")

    def token(self, index):
        if type(index) is not int or not 0 <= index < len(self.vocabulary):
            raise ValueError("Stored token index is outside the vocabulary")
        token = self.vocabulary[index]
        verify_model_source(self, hash_content=False)
        with self.path.open("rb") as stream:
            stream.seek(token.offset)
            value = stream.read(token.bytes)
        if len(value) != token.bytes:
            raise ValueError("Stored token changed after inspection")
        verify_model_source(self, hash_content=False)
        return value


def verify_model_source(model, check=no_cancel, hash_content=True):
    """Bind offsets, architecture and vocabulary to the exact inspected file."""
    check()
    if file_identity(model.path.stat()) != model.source_identity:
        raise ValueError("Model changed after format inspection")
    if hash_content and hash_file(model.path, check, model.bytes) != model.source_sha256:
        raise ValueError("Model content changed after format inspection")
    if file_identity(model.path.stat()) != model.source_identity:
        raise ValueError("Model changed during source verification")


def expected_tensors(hparams):
    """Exact stored names/shapes/dtypes for the pinned unquantized exporter."""
    result = {}
    precision = "f16" if hparams["ftype"] == 1 else "f32"

    def add(name, shape, dtype=None):
        result[name] = (tuple(shape), dtype or (precision if len(shape) > 1 else "f32"))

    for side, state, context, layers in [
        ("encoder", hparams["n_audio_state"], hparams["n_audio_ctx"], hparams["n_audio_layer"]),
        ("decoder", hparams["n_text_state"], hparams["n_text_ctx"], hparams["n_text_layer"]),
    ]:
        add(f"{side}.positional_embedding", [state, context], "f32")
        if side == "encoder":
            add("encoder.conv1.weight", [3, hparams["n_mels"], state])
            add("encoder.conv2.weight", [3, state, state])
            for index in [1, 2]:
                add(f"encoder.conv{index}.bias", [1, state], "f32")
            for suffix in ["weight", "bias"]:
                add(f"encoder.ln_post.{suffix}", [state])
        else:
            add("decoder.token_embedding.weight", [state, hparams["n_vocab"]])
            for suffix in ["weight", "bias"]:
                add(f"decoder.ln.{suffix}", [state])
        for layer in range(layers):
            prefix = f"{side}.blocks.{layer}"
            for attention in (["attn"] if side == "encoder" else ["attn", "cross_attn"]):
                for suffix in ["weight", "bias"]:
                    add(f"{prefix}.{attention}_ln.{suffix}", [state])
                for projection in ["query", "key", "value", "out"]:
                    add(f"{prefix}.{attention}.{projection}.weight", [state, state])
                    if projection != "key":
                        add(f"{prefix}.{attention}.{projection}.bias", [state])
            for suffix in ["weight", "bias"]:
                add(f"{prefix}.mlp_ln.{suffix}", [state])
            add(f"{prefix}.mlp.0.weight", [state, 4 * state])
            add(f"{prefix}.mlp.0.bias", [4 * state])
            add(f"{prefix}.mlp.2.weight", [4 * state, state])
            add(f"{prefix}.mlp.2.bias", [state])
    return result


def inspect_model(path, limits=Limits(), check=no_cancel):
    path = Path(path).resolve(strict=True)
    initial_status = path.stat()
    if not stat.S_ISREG(initial_status.st_mode):
        raise ValueError("Model must be a regular local file")
    size = initial_status.st_size
    if not 0 < size <= limits.model_bytes:
        raise ValueError("Model exceeds the selected file-size budget or is empty")
    with path.open("rb") as stream:
        identity = file_identity(os.fstat(stream.fileno()))
        if identity != file_identity(initial_status):
            raise ValueError("Model changed before format inspection")
        def read(count):
            check()
            if count < 0 or stream.tell() + count > size:
                raise ValueError("Truncated or invalid GGML section")
            value = stream.read(count)
            if len(value) != count:
                raise ValueError("Truncated GGML file")
            return value

        def integer():
            return struct.unpack("<i", read(4))[0]

        if integer() != MAGIC:
            raise ValueError("Expected pinned little-endian Whisper GGML magic; GGUF is unsupported")
        header = dict(zip(HEADER_FIELDS, struct.unpack("<11i", read(44))))
        if header["ftype"] not in [0, 1]:
            raise ValueError("Only unquantized ftype 0/1 models are supported")
        if any(not 0 < header[name] <= 65_536 for name in HEADER_FIELDS if name != "ftype"):
            raise ValueError("Invalid or unsupported architecture dimensions")
        if header["n_vocab"] > limits.tokens or max(header["n_audio_layer"], header["n_text_layer"]) > 64:
            raise ValueError("Architecture exceeds vocabulary/layer bounds")
        if header["n_audio_state"] != header["n_text_state"]:
            raise ValueError("This pinned format inspector requires matching encoder/decoder widths")
        for side in ["audio", "text"]:
            if header[f"n_{side}_state"] % header[f"n_{side}_head"]:
                raise ValueError("Attention head count must divide its state width")
        mel_shape = (integer(), integer())
        if mel_shape[0] != header["n_mels"] or not 0 < mel_shape[1] <= 65_536:
            raise ValueError("Invalid mel-filter dimensions")
        mel_bytes = math.prod(mel_shape) * 4
        if mel_bytes > 4 * 1024 * 1024:
            raise ValueError("Mel filters exceed the bounded format budget")
        read(mel_bytes)
        vocabulary_start = stream.tell()
        stored_tokens = integer()
        if not 0 < stored_tokens <= header["n_vocab"]:
            raise ValueError("Invalid stored vocabulary count")
        vocabulary = []
        vocabulary_hash = hashlib.sha256(struct.pack("<i", stored_tokens))
        for index in range(stored_tokens):
            token_size = integer()
            if not 0 <= token_size <= limits.token_bytes:
                raise ValueError("Token exceeds the bounded byte length")
            vocabulary.append(Token(index, stream.tell(), token_size))
            vocabulary_hash.update(struct.pack("<i", token_size))
            vocabulary_hash.update(read(token_size))
            if stream.tell() - vocabulary_start > limits.vocabulary_bytes:
                raise ValueError("Vocabulary exceeds the bounded section budget")
        tensors = []
        expected = expected_tensors(header)
        seen = set()
        while stream.tell() < size:
            if len(tensors) >= limits.tensors:
                raise ValueError("Tensor count exceeds its budget")
            rank, name_bytes, type_id = struct.unpack("<3i", read(12))
            if not 1 <= rank <= 4 or not 0 < name_bytes <= limits.tensor_name_bytes or type_id not in DTYPES:
                raise ValueError("Unsupported tensor rank/name/dtype; quantized tensors are unavailable")
            shape = tuple(integer() for _ in range(rank))
            if any(not 0 < dimension <= 65_536 for dimension in shape):
                raise ValueError("Invalid tensor shape")
            try:
                name = read(name_bytes).decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError("Tensor name is not UTF-8") from error
            dtype, width, _ = DTYPES[type_id]
            if name in seen or expected.get(name) != (shape, dtype):
                raise ValueError(f"Duplicate, unknown or incompatible tensor: {name}")
            seen.add(name)
            elements = math.prod(shape)
            count = elements * width
            offset = stream.tell()
            if offset + count > size:
                raise ValueError(f"Truncated tensor: {name}")
            tensors.append(Tensor(name, shape, dtype, type_id, offset, elements, count))
            stream.seek(count, os.SEEK_CUR)
        if seen != set(expected):
            missing = sorted(set(expected) - seen)
            raise ValueError(f"Missing expected tensors: {', '.join(missing[:3])}")
        digest = hashlib.sha256()
        stream.seek(0)
        remaining = size
        while remaining:
            check()
            block = stream.read(min(BLOCK_BYTES, remaining))
            if not block:
                raise ValueError("Model truncated while binding inspection identity")
            digest.update(block)
            remaining -= len(block)
        if file_identity(os.fstat(stream.fileno())) != identity or file_identity(path.stat()) != identity:
            raise ValueError("Model changed while binding inspection identity")
    return Model(path, size, header, mel_shape, tuple(vocabulary), vocabulary_hash.hexdigest(), tuple(tensors), identity, digest.hexdigest())


def tensor_statistics(model, check=no_cancel):
    """Chunked one-worker diagnostics; no model execution or causal interpretation."""
    verify_model_source(model, check, hash_content=False)
    try:
        import numpy as np
    except ImportError:
        np = None
    reports = []
    with model.path.open("rb") as stream:
        for tensor in model.tensors:
            stream.seek(tensor.offset)
            dtype, width, code = DTYPES[tensor.type_id]
            minimum, maximum, total, squares, zeros = math.inf, -math.inf, 0.0, 0.0, 0
            for start in range(0, tensor.elements, BLOCK_ELEMENTS):
                check()
                count = min(BLOCK_ELEMENTS, tensor.elements - start)
                block = stream.read(count * width)
                if len(block) != count * width:
                    raise ValueError("Model changed or truncated during diagnostics")
                if np is None:
                    values = [item[0] for item in struct.iter_unpack("<" + code, block)]
                    if not all(math.isfinite(value) for value in values):
                        raise ValueError(f"Non-finite value in {tensor.name}")
                    minimum, maximum = min(minimum, min(values)), max(maximum, max(values))
                    total += math.fsum(values)
                    squares += math.fsum(value * value for value in values)
                    zeros += sum(value == 0 for value in values)
                else:
                    values = np.frombuffer(block, dtype="<f2" if dtype == "f16" else "<f4").astype(np.float64)
                    if not bool(np.isfinite(values).all()):
                        raise ValueError(f"Non-finite value in {tensor.name}")
                    minimum, maximum = min(minimum, float(values.min())), max(maximum, float(values.max()))
                    total += float(values.sum())
                    squares += float((values * values).sum())
                    zeros += int((values == 0).sum())
            reports.append({"name": tensor.name, "minimum": minimum, "maximum": maximum,
                            "mean": total / tensor.elements, "l2_norm": math.sqrt(squares),
                            "rms": math.sqrt(squares / tensor.elements), "zero_elements": zeros,
                            "finite_elements": tensor.elements})
    verify_model_source(model, check, hash_content=False)
    return reports


def model_report(model, statistics=False, include_vocabulary=False, check=no_cancel):
    verify_model_source(model, check)
    original_hash = model.source_sha256
    report = {"schema_version": "1.0", "format": FORMAT, "format_reference": SOURCE_VERSION,
              "source_path": str(model.path), "source_sha256": original_hash,
              "inspector_sha256": hash_file(Path(__file__)), "python": sys.version,
              "file_bytes": model.bytes, "architecture": model.architecture, "mel_shape": model.mel_shape,
              "stored_vocabulary_tokens": len(model.vocabulary), "runtime_vocabulary_tokens": model.architecture["n_vocab"],
              "serialized_vocabulary_sha256": model.vocabulary_sha256,
              "tensor_count": len(model.tensors), "stored_tensor_elements": sum(t.elements for t in model.tensors),
              "stored_tensor_bytes": sum(t.bytes for t in model.tensors),
              "parameter_count_note": "Stored elements include positional tensors; trainable count is not inferred",
              "tensor_layout": "GGML first dimension contiguous; original PyTorch shape is reversed",
              "tensors": [dict(name=t.name, shape=t.shape, dtype=t.dtype, offset=t.offset,
                               elements=t.elements, bytes=t.bytes) for t in model.tensors],
              "limitations": ["Static tensor statistics do not establish a failure mechanism or recognition quality",
                              "No quantized layout, structural surgery or inference validation is claimed"]}
    if statistics:
        report["statistics"] = tensor_statistics(model, check)
        report["statistics_method"] = "Full per-tensor scan in blocks of at most 32768 elements; one worker"
        numpy = sys.modules.get("numpy")
        report["statistics_arithmetic"] = f"NumPy {numpy.__version__}; float64 block reductions" if numpy else "Python float with math.fsum block reductions"
    if include_vocabulary:
        tokens = []
        with model.path.open("rb") as stream:
            for token in model.vocabulary:
                check()
                stream.seek(token.offset)
                data = stream.read(token.bytes)
                if len(data) != token.bytes:
                    raise ValueError("Stored vocabulary changed during inspection")
                tokens.append(dict(index=token.index, bytes=token.bytes,
                    base64=base64.b64encode(data).decode("ascii")))
        report["stored_vocabulary"] = tokens
    verify_model_source(model, check)
    return report


def validate_recipe(model, recipe, limits=Limits()):
    allowed = {"schema_version", "format", "input_sha256", "hypothesis", "development_evidence", "author", "edits"}
    if not isinstance(recipe, dict) or set(recipe) - allowed or recipe.get("schema_version") != "1.0" or recipe.get("format") != FORMAT:
        raise ValueError("Expected a versioned explicit weight-edit recipe")
    expected_hash = recipe.get("input_sha256")
    if not isinstance(expected_hash, str) or len(expected_hash) != 64 or any(c not in "0123456789abcdef" for c in expected_hash):
        raise ValueError("Recipe requires the exact input SHA-256")
    for field in ["hypothesis", "author"]:
        if not isinstance(recipe.get(field), str) or not recipe[field].strip():
            raise ValueError(f"Recipe requires an explicit {field}")
    evidence = recipe.get("development_evidence")
    if not isinstance(evidence, list) or not evidence or not all(isinstance(x, str) and x.strip() for x in evidence):
        raise ValueError("Recipe requires development evidence references, never held-out outcomes")
    edits = recipe.get("edits")
    if not isinstance(edits, list) or not 0 < len(edits) <= limits.edit_operations:
        raise ValueError("Recipe edit count is empty or exceeds its budget")
    ranges, count = [], 0
    for edit in edits:
        if not isinstance(edit, dict):
            raise ValueError("Each edit must be explicit")
        tensor = model.tensor(edit.get("tensor"))
        shape = edit.get("shape")
        if not isinstance(shape, list) or not all(type(dimension) is int for dimension in shape) or shape != list(tensor.shape) or edit.get("dtype") != tensor.dtype:
            raise ValueError("Recipe tensor shape/dtype does not match the original artifact")
        operation = edit.get("op")
        common = {"tensor", "shape", "dtype", "op"}
        if operation == "set":
            if set(edit) != common | {"index", "value"}:
                raise ValueError("Set edits require only index and value")
            start, length, scalar = edit["index"], 1, edit["value"]
        elif operation == "scale":
            if set(edit) != common | {"start", "count", "factor"}:
                raise ValueError("Scale edits require only start, count and factor")
            start, length, scalar = edit["start"], edit["count"], edit["factor"]
        else:
            raise ValueError("Only explicit set or contiguous scale edits are supported")
        if type(start) is not int or type(length) is not int or start < 0 or length <= 0 or start + length > tensor.elements:
            raise ValueError("Recipe range is outside its tensor")
        try:
            finite_scalar = type(scalar) in [int, float] and math.isfinite(scalar)
        except OverflowError:
            finite_scalar = False
        if not finite_scalar:
            raise ValueError("Edit scalar must be finite")
        count += length
        if count > limits.changed_elements:
            raise ValueError("Recipe exceeds its changed-element budget")
        width = DTYPES[tensor.type_id][1]
        byte_start, byte_end = tensor.offset + start * width, tensor.offset + (start + length) * width
        if any(byte_start < previous_end and previous_start < byte_end for previous_start, previous_end in ranges):
            raise ValueError("Overlapping edits are ambiguous; use one explicit operation per range")
        ranges.append((byte_start, byte_end))
    return ranges


def unchanged_regions_equal(source, derived, size, ranges, check):
    digest = hashlib.sha256()
    position = 0
    with source.open("rb") as original, derived.open("rb") as candidate:
        for start, end in sorted(ranges) + [(size, size)]:
            original.seek(position); candidate.seek(position)
            remaining = start - position
            while remaining:
                check()
                count = min(BLOCK_BYTES, remaining)
                before, after = original.read(count), candidate.read(count)
                if len(before) != count or before != after:
                    raise ValueError("Unselected source bytes changed")
                digest.update(before)
                remaining -= count
            position = end
    return digest.hexdigest()


def artifact_identity(path):
    status = path.lstat()
    if not stat.S_ISREG(status.st_mode):
        raise ValueError("Derived artifact is no longer the created regular file")
    return (status.st_dev, status.st_ino)


def require_owned_artifact(path, identity):
    if artifact_identity(path) != identity:
        raise ValueError("Derived artifact identity changed unexpectedly")


def apply_recipe(source, recipe, output_directory, limits=Limits(), check=no_cancel):
    """Publish a new derived artifact only after a finite, byte-audited edit."""
    source = Path(source).resolve(strict=True)
    model = inspect_model(source, limits, check)
    ranges = validate_recipe(model, recipe, limits)
    expected_hash = recipe["input_sha256"]
    if model.source_sha256 != expected_hash:
        raise ValueError("Input model checksum does not match the recipe")
    # Full finite validation before editing; unchanged bytes remain proven equal.
    tensor_statistics(model, check)
    output = Path(output_directory)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    partial, final = output / "model.partial.bin", output / "model.bin"
    audit = {"schema_version": "1.0", "format": FORMAT, "state": "editing", "source_sha256": expected_hash,
             "source_path": str(source), "recipe": recipe, "recipe_sha256": hashlib.sha256(json_bytes(recipe)).hexdigest(),
             "script_sha256": hash_file(Path(__file__)), "python": sys.version,
             "format_reference": SOURCE_VERSION, "created_at": datetime.now(timezone.utc).isoformat(),
             "original_open_mode": "read_only", "copied_bytes": 0, "edits": []}
    ownership = None
    try:
        copied_hash = hashlib.sha256()
        with source.open("rb") as original, partial.open("xb") as candidate:
            opened = os.fstat(candidate.fileno())
            ownership = (opened.st_dev, opened.st_ino)
            os.chmod(partial, 0o600)
            remaining = model.bytes
            while remaining:
                check()
                block = original.read(min(BLOCK_BYTES, remaining))
                if not block:
                    break
                candidate.write(block); copied_hash.update(block); audit["copied_bytes"] += len(block)
                remaining -= len(block)
            if original.read(1):
                raise ValueError("Original grew beyond the inspected copy budget")
            candidate.flush(); os.fsync(candidate.fileno())
        if audit["copied_bytes"] != model.bytes or copied_hash.hexdigest() != expected_hash:
            raise ValueError("Original changed during the derived copy")
        require_owned_artifact(partial, ownership)
        descriptor = os.open(partial, os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "r+b") as candidate:
            opened = os.fstat(candidate.fileno())
            if (opened.st_dev, opened.st_ino) != ownership:
                raise ValueError("Derived artifact changed before editing")
            for edit in recipe["edits"]:
                tensor = model.tensor(edit["tensor"])
                _, width, code = DTYPES[tensor.type_id]
                start = edit["index"] if edit["op"] == "set" else edit["start"]
                count = 1 if edit["op"] == "set" else edit["count"]
                before_hash, after_hash, changed = hashlib.sha256(), hashlib.sha256(), 0
                for offset in range(0, count, BLOCK_ELEMENTS):
                    check()
                    length = min(BLOCK_ELEMENTS, count - offset)
                    location = tensor.offset + (start + offset) * width
                    candidate.seek(location)
                    before = candidate.read(length * width)
                    after = bytearray()
                    for (old,) in struct.iter_unpack("<" + code, before):
                        value = edit["value"] if edit["op"] == "set" else old * edit["factor"]
                        if not math.isfinite(value):
                            raise ValueError("Edit produced a non-finite value")
                        try:
                            packed = struct.pack("<" + code, value)
                        except (OverflowError, struct.error) as error:
                            raise ValueError("Edit is not representable in the original dtype") from error
                        if not math.isfinite(struct.unpack("<" + code, packed)[0]):
                            raise ValueError("Edit overflows the original dtype")
                        after.extend(packed)
                    changed += sum(before[i:i + width] != after[i:i + width] for i in range(0, len(before), width))
                    before_hash.update(before); after_hash.update(after)
                    candidate.seek(location); candidate.write(after)
                audit["edits"].append({"operation": edit, "before_sha256": before_hash.hexdigest(),
                    "after_sha256": after_hash.hexdigest(), "changed_elements": changed})
            candidate.flush(); os.fsync(candidate.fileno())
        if sum(entry["changed_elements"] for entry in audit["edits"]) == 0:
            raise ValueError("Recipe made no representable weight change")
        require_owned_artifact(partial, ownership)
        derived = inspect_model(partial, limits, check)
        if derived.architecture != model.architecture or derived.tensors != model.tensors:
            raise ValueError("Derived artifact changed tensor layout")
        audit["unchanged_regions_sha256"] = unchanged_regions_equal(source, partial, model.bytes, ranges, check)
        verify_model_source(model, check)
        verify_model_source(derived, check)
        audit["derived_sha256"] = derived.source_sha256
        audit["file_bytes"] = model.bytes
        audit["finite_validation"] = "All original tensor values scanned; selected derived values checked; other bytes equal"
        audit["state"] = "verified"
        audit["artifact"] = partial.name
        audit_path = output / "edit-audit.json"
        write_new_json(audit_path, audit)
        check()
        require_owned_artifact(partial, ownership)
        # link refuses any externally created destination instead of overwriting it.
        os.link(partial, final); partial.unlink()
        audit["state"] = "completed"
        audit["artifact"] = final.name
        update_owned_audit(audit_path, audit)
        return audit
    except BaseException as error:
        audit["state"] = "canceled" if isinstance(error, (InterruptedError, KeyboardInterrupt)) else "failed"
        audit["error"] = str(error)
        # A completion-manifest failure must not leave a success-named model.
        # Move only the artifact inode created by this invocation, never another
        # caller's file or any original model. Keep its bytes as failed evidence.
        if ownership is not None:
            try:
                if final.exists():
                    require_owned_artifact(final, ownership)
                    quarantine = output / "model.failed.bin"
                    os.link(final, quarantine, follow_symlinks=False)
                    final.unlink()
                    audit["artifact"] = quarantine.name
            except (OSError, ValueError) as quarantine_error:
                audit["quarantine_error"] = str(quarantine_error)
        audit["retained_artifacts"] = [path.name for path in [partial, final, output / "model.failed.bin"] if path.exists()]
        audit_path = output / "edit-audit.json"
        try:
            if audit_path.exists():
                update_owned_audit(audit_path, audit)
            else:
                write_new_json(audit_path, audit)
        except BaseException as persistence_error:
            # A full/unavailable filesystem may prevent a final audit. Preserve
            # the original failure and partial/quarantined bytes, not a new
            # FileExistsError from a stale temporary audit.
            try:
                write_new_json(output / "edit-failure.json", audit)
            except BaseException as fallback_error:
                note = f"Failure audit could not be persisted: {persistence_error}; fallback: {fallback_error}"
                if hasattr(error, "add_note"):
                    error.add_note(note)
                else:
                    error.__notes__ = list(getattr(error, "__notes__", [])) + [note]
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--cancel-file", type=Path)
    parser.add_argument("--max-model-bytes", type=int, default=Limits().model_bytes)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect")
    inspect.add_argument("model", type=Path)
    inspect.add_argument("--report", type=Path, required=True)
    inspect.add_argument("--statistics", action="store_true")
    inspect.add_argument("--include-vocabulary", action="store_true")
    apply = commands.add_parser("apply")
    apply.add_argument("model", type=Path)
    apply.add_argument("recipe", type=Path)
    apply.add_argument("--output", type=Path, required=True, help="New derived-artifact directory with an existing parent")
    args = parser.parse_args(argv)
    if not 0 < args.max_model_bytes <= 4 * 1024 ** 3:
        parser.error("Model byte budget must be positive and at most 4 GiB")
    cancel = Cancellation(args.timeout, args.cancel_file)
    def request_cancel(*_):
        cancel.requested = True
    signal.signal(signal.SIGINT, request_cancel)
    signal.signal(signal.SIGTERM, request_cancel)
    limits = Limits(model_bytes=args.max_model_bytes)
    try:
        if args.command == "inspect":
            model = inspect_model(args.model, limits, cancel.check)
            report = model_report(model, args.statistics, args.include_vocabulary, cancel.check)
            write_new_json(args.report, report)
            print(f"Inspected {len(model.tensors)} tensors; no weights changed; report: {args.report}")
        else:
            audit = apply_recipe(args.model, read_json(args.recipe), args.output, limits, cancel.check)
            print(f"Derived artifact {audit['derived_sha256']}; original retained; audit: {args.output / 'edit-audit.json'}")
    except (OSError, ValueError, InterruptedError) as error:
        print(str(error), file=sys.stderr)
        for note in getattr(error, "__notes__", []):
            print(note, file=sys.stderr)
        return 130 if isinstance(error, InterruptedError) else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
