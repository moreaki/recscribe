#!/usr/bin/env python3
"""Run the bounded, synthetic #83 storage probe with the selected Xcode."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("owned", "framework", "fenced"), default="owned")
    parser.add_argument("--buffers", type=int, default=20_000)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if not 1024 <= args.buffers <= 1_000_000:
        parser.error("--buffers must be between 1024 and 1000000")
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="recscribe-pcm-probe-") as temporary:
        output = args.output_dir or Path(temporary)
        output.mkdir(parents=True, exist_ok=True)
        executable = output / "pcm-storage-probe"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-sanitize=thread", "-g", "-O",
            str(root / "RecScribe/RecScribeTests/SampleBufferFixtures.swift"),
            str(root / "scripts/diagnostics/pcm-storage/main.swift"), "-o", str(executable),
        ], check=True)
        environment = os.environ.copy()
        # Collect final ownership/checksum evidence even for the diagnostic-only
        # framework mode. No suppressions: warnings must still fail the process.
        environment["TSAN_OPTIONS"] = "halt_on_error=0:exitcode=66"
        result = subprocess.run([str(executable), args.mode, str(args.buffers)],
                                env=environment, capture_output=True, text=True)
        log = result.stdout + result.stderr
        (output / f"{args.mode}.log").write_text(log)
        print(log, end="", flush=True)
        if result.returncode or "ThreadSanitizer:" in log:
            return result.returncode if result.returncode > 0 else 1
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
