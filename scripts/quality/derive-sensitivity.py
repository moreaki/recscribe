#!/usr/bin/env python3
"""Prepare bounded synthetic development diagnostics; never recognizes audio.

Run through scripts/work-artifacts.py. --manifest must explicitly name the
selected development-only schema-1.0 corpus; --output must be a NEW protected
external directory. Originals, references and source metadata are never edited.
Neither derivative fills natural quiet/adverse-condition or approved-v2 coverage.
"""
import argparse
from array import array
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import random
import signal
import stat
import sys
import time
import wave

RATE = 16000
PREFIX_FRAMES = 30 * RATE
CHUNK_BYTES = 16384
LEGACY_POLICY = "swift-nfc-casefold-alphanumeric-v1"
REPOSITORY = Path(__file__).resolve().parents[2]
CONDITIONS = ("synthetic-digital-zero-prefix-30s", "synthetic-constant-gain-1-8")
LIMITATIONS = [
    "Synthetic development sensitivity only; not natural quiet/noisy or long-form coverage",
    "No native-language audio/reference or boundary adjudication performed",
    "Derivatives share the parent's source/speaker/session group; never independent samples",
    "Exploratory schema-1.0 evaluation uses legacy-v1; no scoring-version upgrade",
    "V2 approval, missing source grouping, and word/onset timing remain pending",
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value, base=None):
    """Reject lexical traversal and every existing symlink, including parents."""
    path = Path(value)
    if ".." in path.parts:
        raise ValueError("Path traversal is not allowed")
    if not path.is_absolute():
        if base is None:
            raise ValueError("Use an explicit absolute output path")
        path = base / path
    if any(part.lower().replace("_", "-") in {"held-out", "heldout", "holdout"} for part in path.parts):
        raise ValueError("Held-out paths are prohibited in development derivation")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError("Symlink paths are not allowed")
    return path


def open_regular(path):
    safe_path(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    stream = os.fdopen(descriptor, "rb")
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
        stream.close()
        raise ValueError("Input must be a regular file")
    return stream


class Budget:
    def __init__(self, maximum_bytes=64 * 1024 * 1024, seconds=120, cancel=None, check=None):
        if not 1024 <= maximum_bytes <= 256 * 1024 * 1024 or not 0 < seconds <= 900:
            raise ValueError("Output/time limits exceed supported bounds")
        # Reserve room for an incomplete-status record even after budget exhaustion.
        self.maximum_bytes, self.reserved = maximum_bytes, 512
        self.deadline = time.monotonic() + seconds
        self.cancel, self.callback = cancel, check

    def check(self):
        if self.callback:
            self.callback()
        if self.cancel and self.cancel.exists():
            raise InterruptedError("Canceled; partial protected evidence retained")
        if time.monotonic() >= self.deadline:
            raise TimeoutError("Derivation wall-time budget exceeded")

    def reserve(self, size):
        self.check()
        if size < 0 or self.reserved + size > self.maximum_bytes:
            raise ValueError("Total output byte budget exceeded")
        self.reserved += size


def inspect_file(path, maximum, budget):
    with open_regular(path) as stream:
        initial = os.fstat(stream.fileno())
        if initial.st_size > maximum:
            raise ValueError("Input file exceeds bounded size")
        digest = hashlib.sha256()
        count = 0
        while True:
            budget.check()
            block = stream.read(CHUNK_BYTES)
            if not block:
                break
            count += len(block)
            if count > maximum:
                raise ValueError("Input grew beyond bounded size")
            digest.update(block)
        final = os.fstat(stream.fileno())
    safe_path(path)
    current = path.stat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
    if count != initial.st_size or identity(initial) != identity(final) or identity(initial) != identity(current):
        raise ValueError("Source changed while reading")
    return {"path": str(path), "bytes": count, "sha256": digest.hexdigest(), "identity": identity(initial)}


def unchanged(snapshot, maximum, budget):
    current = inspect_file(Path(snapshot["path"]), maximum, budget)
    if current != snapshot:
        raise ValueError("Source changed after initial hash")


def read_small(path, maximum, budget):
    before = inspect_file(path, maximum, budget)
    with open_regular(path) as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum or sha(data) != before["sha256"]:
        raise ValueError("Source changed while reading metadata")
    unchanged(before, maximum, budget)
    return data, before


def save(path, data, budget):
    budget.reserve(len(data))
    with path.open("xb") as stream:
        stream.write(data)


def save_json(path, value, budget):
    save(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode(), budget)


def copy_snapshot(snapshot, destination, budget):
    budget.reserve(snapshot["bytes"])
    digest, count = hashlib.sha256(), 0
    with open_regular(Path(snapshot["path"])) as source, destination.open("xb") as target:
        while True:
            budget.check()
            block = source.read(CHUNK_BYTES)
            if not block:
                break
            count += len(block)
            if count > snapshot["bytes"]:
                raise ValueError("Source grew while copying")
            target.write(block)
            digest.update(block)
    if count != snapshot["bytes"] or digest.hexdigest() != snapshot["sha256"]:
        raise ValueError("Source changed while copying")
    unchanged(snapshot, snapshot["bytes"], budget)


def wav_info(path, maximum_seconds, budget):
    budget.check()
    try:
        with open_regular(path) as stream, wave.open(stream, "rb") as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, RATE, "NONE"):
                raise ValueError("Only mono 16 kHz uncompressed PCM16 WAV is supported")
            frames = audio.getnframes()
    except (wave.Error, EOFError) as error:
        raise ValueError("Unsupported or malformed PCM16 WAV") from error
    if frames <= 0 or frames > maximum_seconds * RATE:
        raise ValueError("Source duration exceeds its positive bounded limit")
    return frames


def attenuate(block):
    """Signed integer division by eight, explicitly truncating toward zero."""
    values = array("h")
    values.frombytes(block)
    if sys.byteorder != "little":
        values.byteswap()
    result = array("h", (x // 8 if x >= 0 else -((-x) // 8) for x in values))
    if sys.byteorder != "little":
        result.byteswap()
    return result.tobytes()


def transform(source, destination, condition, frames, budget):
    prefix = PREFIX_FRAMES if condition == CONDITIONS[0] else 0
    if condition not in CONDITIONS:
        raise ValueError("Unknown synthetic condition")
    expected_bytes = 44 + 2 * (frames + prefix)
    budget.reserve(expected_bytes)
    source_pcm, derived_pcm, retained_pcm = hashlib.sha256(), hashlib.sha256(), hashlib.sha256()
    with open_regular(source) as raw, wave.open(raw, "rb") as incoming, destination.open("xb") as target:
        with wave.open(target, "wb") as outgoing:
            outgoing.setnchannels(1)
            outgoing.setsampwidth(2)
            outgoing.setframerate(RATE)
            remaining = prefix
            while remaining:
                budget.check()
                count = min(remaining, CHUNK_BYTES // 2)
                zeros = bytes(count * 2)
                outgoing.writeframesraw(zeros)
                derived_pcm.update(zeros)
                remaining -= count
            remaining = frames
            while remaining:
                budget.check()
                count = min(remaining, CHUNK_BYTES // 2)
                block = incoming.readframes(count)
                if len(block) != count * 2:
                    raise ValueError("Truncated source PCM frames")
                source_pcm.update(block)
                derived = block if prefix else attenuate(block)
                outgoing.writeframesraw(derived)
                derived_pcm.update(derived)
                if prefix:
                    retained_pcm.update(derived)
                remaining -= count
    if destination.stat().st_size != expected_bytes:
        raise ValueError("Derived WAV frame/byte count differs from recipe")
    if prefix and retained_pcm.digest() != source_pcm.digest():
        raise ValueError("Quiet-prefix suffix did not preserve source samples")
    output = inspect_file(destination, expected_bytes, budget)
    return {"audio_sha256": output["sha256"], "audio_bytes": expected_bytes,
            "source_pcm_sha256": source_pcm.hexdigest(), "derived_pcm_sha256": derived_pcm.hexdigest(),
            "retained_source_suffix_pcm_sha256": retained_pcm.hexdigest() if prefix else None,
            "source_frames": frames, "derived_frames": frames + prefix, "sample_rate": RATE,
            "channels": 1, "sample_format": "signed_pcm16_little_endian", "condition": condition,
            "prefix_frames": prefix, "gain_numerator": 1, "gain_denominator": 1 if prefix else 8,
            "integer_rounding": "unchanged samples" if prefix else "truncate signed division toward zero",
            "source_to_derived_offset_seconds": prefix / RATE,
            "source_time_preserved": True, "word_alignment": "unavailable; no word/onset times inferred"}


def add_white_noise(source, destination, *, snr_db, seed, budget):
    """Supplemental PCM diagnostic, never natural-noise or independent speech.

    Uniform MT19937 noise, scaled by full-source RMS; round-to-even PCM16 with
    explicit clipping counts. Record achieved post-clipping SNR, not a guarantee
    of audibility/word preservation. Existing two-condition recipes are unchanged.
    """
    if type(snr_db) not in (int, float) or not math.isfinite(snr_db) or not 0 <= snr_db <= 40:
        raise ValueError("Synthetic SNR must be finite and between 0 and 40 dB")
    if type(seed) is not int or not 0 <= seed < 2 ** 64:
        raise ValueError("Use an explicit unsigned 64-bit seed")
    source, destination = safe_path(source), safe_path(destination)
    frames = wav_info(source, 600, budget)
    original = inspect_file(source, 32 * 1024 * 1024, budget)
    energy = 0
    with open_regular(source) as raw, wave.open(raw, "rb") as incoming:
        while block := incoming.readframes(CHUNK_BYTES // 2):
            budget.check()
            values = array("h"); values.frombytes(block)
            if sys.byteorder != "little": values.byteswap()
            energy += sum(v * v for v in values)
    if energy == 0:
        raise ValueError("Silent input has no defined signal-relative SNR")
    amplitude = math.sqrt(energy / frames) * 10 ** (-snr_db / 20) * math.sqrt(3)
    rng, noise_energy, clipped = random.Random(seed), 0, 0
    budget.reserve(44 + frames * 2)
    with open_regular(source) as raw, wave.open(raw, "rb") as incoming, destination.open("xb") as target:
        with wave.open(target, "wb") as outgoing:
            outgoing.setnchannels(1); outgoing.setsampwidth(2); outgoing.setframerate(RATE)
            while block := incoming.readframes(CHUNK_BYTES // 2):
                budget.check()
                values = array("h"); values.frombytes(block)
                if sys.byteorder != "little": values.byteswap()
                result = array("h")
                for value in values:
                    noisy = round(value + rng.uniform(-amplitude, amplitude))
                    bounded = min(32767, max(-32768, noisy))
                    clipped += noisy != bounded
                    noise_energy += (bounded - value) ** 2
                    result.append(bounded)
                if sys.byteorder != "little": result.byteswap()
                outgoing.writeframesraw(result.tobytes())
    unchanged(original, 32 * 1024 * 1024, budget)
    result = inspect_file(destination, 44 + frames * 2, budget)
    if result["bytes"] != 44 + frames * 2:
        raise ValueError("Noisy derivative changed the declared frame count")
    return {"condition": "synthetic-additive-uniform-white-noise", "source_sha256": original["sha256"],
        "audio_sha256": result["sha256"], "audio_bytes": result["bytes"], "source_frames": frames, "derived_frames": frames,
        "sample_rate": RATE, "requested_snr_db": snr_db, "achieved_post_clipping_snr_db": 10 * math.log10(energy / noise_energy) if noise_energy else None,
        "seed": seed, "random_algorithm": "Python random.Random MT19937 uniform", "integer_rounding": "round to nearest, ties to even; clamp PCM16",
        "clipped_samples": clipped, "source_to_derived_offset_seconds": 0, "source_time_preserved": True,
        "word_alignment": "unreviewed; no word/onset times or reference approval inferred"}


def prepare(manifest, output, *, maximum_cases=9, maximum_seconds=60,
            maximum_bytes=64 * 1024 * 1024, seconds=120, cancel=None, check=None):
    if not 1 <= maximum_cases <= 9 or not math.isfinite(maximum_seconds) or not 0 < maximum_seconds <= 60:
        raise ValueError("Case/duration limits exceed supported bounds")
    manifest, output = safe_path(manifest), safe_path(output)
    if output == REPOSITORY or REPOSITORY in output.parents:
        raise ValueError("Protected corpus output must be outside the checkout")
    if output.exists():
        raise FileExistsError("Refusing to reuse or overwrite an output directory")
    budget = Budget(maximum_bytes, seconds, Path(cancel) if cancel else output / "cancel.request", check)
    original, manifest_snapshot = read_small(manifest, 1024 * 1024, budget)
    corpus = json.loads(original)
    cases = corpus.get("cases")
    if corpus.get("schema_version") != "1.0" or not isinstance(cases, list) or not 1 <= len(cases) <= maximum_cases:
        raise ValueError("Explicit selected schema-1.0 development manifest required within case bound")
    if corpus.get("split", "development") != "development" or corpus.get("errors"):
        raise ValueError("Only error-free development manifests may be derived")
    seen, inputs = set(), []
    # Reject every non-development case before reading any reference/audio file.
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("Source cases must be metadata objects")
        identifier = case.get("id", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", identifier) or identifier in seen:
            raise ValueError("Unsafe or duplicate source case ID")
        if case.get("split") != "development" or case.get("evaluation_split", "development") != "development":
            raise ValueError("Held-out or unspecified split prohibited")
        if not isinstance(case.get("source_id"), str) or not case["source_id"]:
            raise ValueError("Original source_id is required; never infer grouping")
        if not isinstance(case.get("category"), str) or not case["category"].strip():
            raise ValueError("Source category metadata is required")
        if not isinstance(case.get("conditions"), list) or not all(isinstance(x, str) and x.strip() for x in case["conditions"]):
            raise ValueError("Source conditions must be preserved as a list")
        if ":test:" in case["source_id"] or case.get("code_switches") or type(case.get("source_channel")) is not int or case["source_channel"] != 0:
            raise ValueError("Only selected development single-channel cases without switch annotations are supported")
        seen.add(identifier)
    for case in cases:
        snapshots = {}
        for key, limit in (("audio", 4 * 1024 * 1024), ("reference", 1024 * 1024), ("provenance", 1024 * 1024)):
            if not isinstance(case.get(key), str):
                raise ValueError("Source audio, reference and provenance paths are required")
            path = safe_path(case[key], manifest.parent)
            snapshots[key] = inspect_file(path, limit, budget)
        for key, hash_key in (("audio", "sha256"), ("reference", "reference_sha256")):
            if not re.fullmatch(r"[0-9a-f]{64}", case.get(hash_key, "")) or snapshots[key]["sha256"] != case[hash_key]:
                raise ValueError("Source audio/reference hash mismatch")
        provenance_bytes, _ = read_small(Path(snapshots["provenance"]["path"]), 1024 * 1024, budget)
        provenance = json.loads(provenance_bytes)
        if provenance.get("evaluation_split", "development") != "development" or provenance.get("dataset_split") in {"test", "private"}:
            raise ValueError("Held-out source provenance prohibited")
        frames = wav_info(Path(snapshots["audio"]["path"]), maximum_seconds, budget)
        duration = case.get("duration_seconds")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or abs(duration - frames / RATE) > 1 / RATE:
            raise ValueError("Source duration does not match exact frames")
        inputs.append((case, snapshots, frames))
    budget.check()
    output.parent.mkdir(parents=True, exist_ok=True)
    safe_path(output)
    output.mkdir()
    try:
        save(output / "source.manifest.original.json", original, budget)
        recipe, recipe_snapshot = read_small(Path(__file__).resolve(), 128 * 1024, budget)
        save(output / "recipe.original.py", recipe, budget)
        save_json(output / "STARTED.json", {"status": "preparing", "source_manifest_sha256": sha(original),
                  "source_manifest_path": str(manifest), "recipe_sha256": sha(recipe), "protected_data": True}, budget)
        derived_cases = []
        for case, snapshots, frames in inputs:
            budget.check()
            folder = output / case["id"]
            folder.mkdir()
            for key, name in (("audio", "source.input.original.wav"), ("reference", "reference.original.txt"),
                              ("provenance", "source.provenance.original.json")):
                copy_snapshot(snapshots[key], folder / name, budget)
            for condition in CONDITIONS:
                destination = folder / (condition + ".wav")
                evidence = transform(folder / "source.input.original.wav", destination, condition, frames, budget)
                evidence.update({"schema_version": "1.0", "parent_case_id": case["id"],
                    "source_manifest_sha256": sha(original), "source_manifest_path": str(manifest),
                    "source_audio_sha256": snapshots["audio"]["sha256"],
                    "source_reference_sha256": snapshots["reference"]["sha256"], "recipe_sha256": sha(recipe),
                    "source_provenance_sha256": snapshots["provenance"]["sha256"],
                    "source_id": case["source_id"], "speaker_ids": case.get("speaker_ids"), "session_id": case.get("session_id"),
                    "source_audio_modified": False, "derived_audio_modified": True,
                    "native_review": "pending", "natural_adverse_recording": False})
                evidence_path = folder / (condition + ".provenance.json")
                save_json(evidence_path, evidence, budget)
                row = copy.deepcopy(case)
                row.update({"id": case["id"] + "-" + condition, "parent_case_id": case["id"],
                    "audio": str(destination), "reference": str(folder / "reference.original.txt"),
                    "sha256": evidence["audio_sha256"], "duration_seconds": evidence["derived_frames"] / RATE,
                    "provenance": str(evidence_path), "source_provenance_snapshot": str(folder / "source.provenance.original.json"),
                    "source_audio_snapshot": str(folder / "source.input.original.wav"),
                    "source_declared_scoring_policy": case.get("scoring_policy"), "scoring_policy": LEGACY_POLICY,
                    "evaluation_scoring_version": "legacy-v1", "reviewed": False,
                    "evaluation_tier": "synthetic_development_sensitivity_not_v2_approved",
                    "synthetic_condition": condition, "source_timing": evidence,
                    "conditions": list(case.get("conditions", [])) + [condition],
                    "coverage_limitations": list(case.get("coverage_limitations", [])) + LIMITATIONS})
                derived_cases.append(row)
        unchanged(manifest_snapshot, 1024 * 1024, budget)
        unchanged(recipe_snapshot, 128 * 1024, budget)
        for _, snapshots, _ in inputs:
            for snapshot in snapshots.values():
                unchanged(snapshot, snapshot["bytes"], budget)
        result = {"schema_version": "1.0", "corpus_version": corpus.get("corpus_version", "") + "-synthetic-sensitivity-v1",
            "frozen": False, "evaluation_tier": "synthetic_development_sensitivity_not_v2_approved", "split": "development",
            "scoring_version": "legacy-v1", "source_manifest_sha256": sha(original), "recipe_sha256": sha(recipe),
            "unique_parent_cases": len(cases), "condition_instances": len(derived_cases), "cases": derived_cases,
            "limitations": LIMITATIONS, "errors": []}
        save_json(output / "manifest.exploratory.legacy.json", result, budget)
        pending = copy.deepcopy(result)
        pending.update(schema_version="2.0", approval_status="pending; synthetic derivatives are not representative v2 coverage")
        for row in pending["cases"]:
            # Explicit unknown, not an invented source domain. Required v2 keys
            # may be null while eligibility remains pending.
            row.setdefault("domain", None)
        save_json(output / "manifest.v2.pending.json", pending, budget)
        save_json(output / "COMPLETED.json", {"status": "prepared_not_evaluated", "unique_parent_cases": len(cases),
                  "condition_instances": len(derived_cases), "reserved_output_bytes_before_this_record": budget.reserved,
                  "selected_input_files_hashes_verified_before_after": True,
                  "asr_executed": False, "protected_data": True}, budget)
        return result
    except BaseException as error:
        # Never delete partial protected originals or overwrite an earlier record.
        failure = {"status": "incomplete", "error_type": type(error).__name__, "asr_executed": False,
                   "partial_evidence_retained": True}
        with (output / "FAILED.json").open("x") as stream:
            json.dump(failure, stream)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-cases", type=int, default=9)
    parser.add_argument("--max-source-seconds", type=float, default=60)
    parser.add_argument("--max-output-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--cancel-file", type=Path)
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise InterruptedError("Derivation interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        result = prepare(args.manifest, args.output, maximum_cases=args.max_cases, maximum_seconds=args.max_source_seconds,
                         maximum_bytes=args.max_output_bytes, seconds=args.timeout_seconds, cancel=args.cancel_file)
    except (ValueError, OSError, TimeoutError, InterruptedError, KeyboardInterrupt) as error:
        parser.exit(1, type(error).__name__ + ": " + str(error) + "\n")
    print(json.dumps({"status": "prepared_not_evaluated", "output": str(args.output),
                      "unique_parent_cases": result["unique_parent_cases"], "condition_instances": result["condition_instances"]}))


if __name__ == "__main__":
    main()
