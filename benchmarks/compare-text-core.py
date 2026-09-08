#!/usr/bin/env python3
"""Compare validated rendering only; no ASR/model/network calls or private text in results.

Run with the reference pipeline interpreter after building core in Release.
All temporary exports are private and removed after comparison.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import time


def reference(source, output):
    from recscribe.job import validate
    from recscribe.renderers import render
    document = json.loads(source.read_bytes())
    validate(document)
    output.mkdir(mode=0o700)
    for name, text in render(document).items():
        (output / name).write_bytes(text.encode())


def benchmark(source, native, repetitions):
    data = source.read_bytes()
    document = json.loads(data)
    samples = {"swift": [], "python": []}
    with tempfile.TemporaryDirectory(prefix="recscribe-text-benchmark-") as temporary:
        root = Path(temporary)
        for index in range(repetitions):
            # Alternate order to reduce cache/order bias.
            for runtime in (["swift", "python"] if index % 2 == 0 else ["python", "swift"]):
                output = root / f"{runtime}-{index}"
                command = ([str(native), "render", str(source), "--output", str(output)] if runtime == "swift"
                           else [sys.executable, __file__, "--reference", str(source), str(output)])
                start = time.perf_counter()
                completed = subprocess.run(["/usr/bin/time", "-l", *command], capture_output=True, timeout=60)
                elapsed = time.perf_counter() - start
                if completed.returncode:
                    raise RuntimeError(f"{runtime} validation/render failed; no output content is included")
                rss = re.search(rb"(\d+)\s+maximum resident set size", completed.stderr)
                if not rss:
                    raise RuntimeError("macOS /usr/bin/time RSS output missing")
                samples[runtime].append({"wall_seconds": elapsed, "peak_rss_bytes": int(rss[1])})
            left, right = root / f"swift-{index}", root / f"python-{index}"
            names = {p.name for p in left.iterdir()}
            if names != {p.name for p in right.iterdir()} or any((left / name).read_bytes() != (right / name).read_bytes() for name in names):
                raise RuntimeError("Native/reference export mismatch")
    return {"scope": "canonical JSON validation and five deterministic exports; not ASR or AI inference",
            "source_sha256": hashlib.sha256(data).hexdigest(), "source_bytes": len(data),
            "segments": len(document["segments"]), "runs": repetitions, "exports_byte_equal": True,
            "results": {name: {"samples": values, "median_wall_seconds": statistics.median(v["wall_seconds"] for v in values),
                "maximum_peak_rss_bytes": max(v["peak_rss_bytes"] for v in values)} for name, values in samples.items()}}


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--reference":
        reference(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("transcript", type=Path)
        parser.add_argument("--native", type=Path, required=True)
        parser.add_argument("--runs", type=int, default=5)
        args = parser.parse_args()
        if args.runs < 1:
            parser.error("--runs must be positive")
        print(json.dumps(benchmark(args.transcript.resolve(), args.native.resolve(), args.runs), indent=2))
