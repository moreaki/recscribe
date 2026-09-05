"""Reproducible local benchmark runner and engine-independent accuracy scoring."""

import argparse
import json
import platform
import os
from pathlib import Path
import re
import sys
import time
import unicodedata

from .job import validate
from .process import Cancellation, Cancelled, run_local
from .storage import sha256, write_json


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, token in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (token != other)))
        previous = current
    return previous[-1]


def normalized(text):
    return " ".join(re.sub(r"[^\w\s]", " ", unicodedata.normalize("NFC", text).casefold()).split())


def accuracy(reference: str, hypothesis: str) -> dict:
    ref, hyp = normalized(reference), normalized(hypothesis)
    words, chars = ref.split(), ref.replace(" ", "")
    word_errors = distance(words, hyp.split())
    char_errors = distance(chars, hyp.replace(" ", ""))
    return {"wer": word_errors / len(words) if words else None,
            "cer": char_errors / len(chars) if chars else None,
            "word_errors": word_errors, "reference_words": len(words),
            "character_errors": char_errors, "reference_characters": len(chars),
            "false_speech_words": len(hyp.split()) if not words else None,
            "normalization": "NFC, casefold, punctuation to spaces, collapsed whitespace"}


def main(argv=None):
    p = argparse.ArgumentParser(description="Local benchmark; input manifest must contain licensed references")
    p.add_argument("manifest", type=Path)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--whisper-cli", type=Path)
    p.add_argument("--model", type=Path)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    os.umask(0o077)
    manifest = json.loads(args.manifest.read_text())
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    cases = manifest["cases"]
    results = []
    for case in cases:
        case_id = case["id"]
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", case_id):
            raise ValueError("Case ID must be a safe directory component")
        source = (args.manifest.parent / case["audio"]).resolve() if case.get("audio") else None
        reference = (args.manifest.parent / case["reference"]).resolve() if case.get("reference") else None
        row = {"id": case_id, "category": case["category"], "status": "pending_corpus"}
        ready = (source is not None and source.is_file() and reference is not None
                 and reference.is_file() and case.get("license") and case.get("sha256"))
        if not ready:
            results.append(row)
            continue
        if sha256(source) != case["sha256"]:
            raise ValueError(f"Audio checksum mismatch: {case_id}")
        if args.dry_run:
            row["status"] = "ready"
            results.append(row)
            continue
        if args.whisper_cli is None or args.model is None:
            p.error("A real run requires --whisper-cli and --model")
        if sys.platform != "darwin":
            p.error("The initial resource measurement runner requires macOS /usr/bin/time")
        timing = args.output / f"{case_id}.time.txt"
        job_dir = args.output / case_id
        command = ["/usr/bin/time", "-l", "-o", str(timing), sys.executable, "-m", "recscribe",
                   str(source), "--output", str(job_dir), "--source-language", case["language"],
                   "--whisper-cli", str(args.whisper_cli.resolve()), "--model", str(args.model.resolve()),
                   "--local-only"]
        started = time.monotonic()
        try:
            run_local(command, args.output / f"{case_id}.log",
                      Cancellation(args.output / "cancel.request"), timeout=7200)
            transcript = json.loads((job_dir / "transcript.json").read_text())
            validate(transcript)
            hypothesis = " ".join(s["source_text"] for s in transcript["segments"])
            row.update(accuracy(reference.read_text(), hypothesis))
            elapsed = time.monotonic() - started
            memory = re.search(r"(\d+)\s+maximum resident set size", timing.read_text())
            row.update(status=transcript["status"], wall_seconds=elapsed,
                       real_time_factor=elapsed / (transcript["source"]["duration_ms"] / 1000),
                       peak_rss_bytes=int(memory[1]) if memory else None,
                       memory_method="macOS time -l; maximum process RSS, not summed concurrent memory",
                       reference_sha256=sha256(reference), source_sha256=case["sha256"],
                       reviewed_segments=sum(s["needs_review"] for s in transcript["segments"]),
                       engine_passes=transcript["processing"]["engine_passes"])
        except Cancelled:
            row.update(status="cancelled")
            results.append(row)
            break
        except Exception as error:
            row.update(status="failed", error=str(error))
        results.append(row)
        write_json(args.output / "results.json", {"schema_version": "1.0", "results": results})
    write_json(args.output / "results.json", {"schema_version": "1.0",
        "machine": {"platform": platform.platform(), "architecture": platform.machine()},
        "manifest_sha256": sha256(args.manifest), "results": results})
    if any(row["status"] == "cancelled" for row in results):
        return 130
    return 1 if any(row["status"] == "failed" for row in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
