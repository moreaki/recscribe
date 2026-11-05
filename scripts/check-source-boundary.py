#!/usr/bin/env python3
"""Reject retired project references outside the explicitly reviewed audit/notices.

Scans tracked paths and current file bytes, or a built application bundle. This is
an identifier regression guard, not proof of independent implementation or licensing.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
RETIRED = re.compile(rb"home[ _-]?rec|homerec-local|hr_snapshot|melissa|pereira|mdebritto|claude|anthropic", re.I)
# Historical notices are deliberately retained, not silently classified as zero references.
EXCEPTIONS = {
    "LICENSE": "Existing copyright notice; retained conservatively pending notice disposition.",
    "NOTICE": "Historical source attribution; no application integration is authorized by it.",
    "docs/provenance/recording-foundation.md": "Replacement evidence and explicit notice decision.",
    "scripts/audit-source-provenance.py": "History audit must identify the original contributors.",
    "scripts/check-source-boundary.py": "This guard defines the retired identifiers and its self-test.",
}


def violation(path, content):
    return bool(RETIRED.search(path.encode()) or RETIRED.search(content))


def inspect(paths, base, exceptions):
    failures = []
    for path in paths:
        relative = path.relative_to(base).as_posix()
        if relative in exceptions or not path.is_file():
            continue
        if violation(relative, path.read_bytes()):
            failures.append(relative)
    return failures


def self_test():
    cases = [("HomeRec.swift", b"", True), ("test.swift", b"home-rec", True),
             ("test.swift", b"HR_SNAPSHOT", True), ("test.swift", b"Claude", True),
             ("test.swift", b"melissa-pereira-deel", True),
             ("RecScribe.swift", b"recorder.start()", False),
             ("audio.wav", bytes(range(256)), False)]
    for path, data, expected in cases:
        if violation(path, data) != expected:
            raise AssertionError(path)
    print(f"Boundary guard: {len(cases)} positive/negative cases passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.bundle:
        base = args.bundle.resolve()
        if not (base / "Contents/MacOS/RecScribe").is_file():
            parser.error("--bundle must name a built RecScribe.app")
        paths, exceptions = base.rglob("*"), {}
    else:
        base = ROOT
        names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        paths = (base / name.decode() for name in names if name)
        exceptions = EXCEPTIONS
    failures = inspect(paths, base, exceptions)
    for path in failures:
        print(f"Retired reference: {path}", file=sys.stderr)
    if failures:
        return 1
    print("Boundary guard passed" + (" (reviewed historical notice/audit exceptions apply)" if exceptions else " (bundle)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
