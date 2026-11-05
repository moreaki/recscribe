#!/usr/bin/env python3
"""Reject retired project references throughout the current tracked tree.

Scans tracked paths and current file bytes, or a built application bundle. This is
an identifier regression guard, not proof of independent implementation or licensing.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

from source_baseline import identities

ROOT = Path(__file__).resolve().parent.parent
# Every tracked file is checked, including license, notice, assessment and tools.
# Resolve retired identities from the preserved historical snapshot rather than
# maintaining named exceptions or a duplicated registry in current sources.
RETIRED = None


def violation(path, content):
    return bool(RETIRED.search(path) or RETIRED.search(content.decode("utf-8", errors="replace")))


def inspect(paths, base):
    failures = []
    for path in paths:
        relative = path.relative_to(base).as_posix()
        if not path.is_file():
            continue
        if violation(relative, path.read_bytes()):
            failures.append(relative)
    return failures


def self_test():
    historical = identities()
    project = historical.projects[0]
    person = historical.contributors[0]
    token = historical.other_identifiers[0]
    cases = [(project + ".swift", b"", True),
             ("LICENSE", person.encode(), True),
             ("NOTICE", token.encode(), True),
             ("docs/provenance/assessment.md", project.encode(), True),
             ("scripts/example.py", project.swapcase().encode(), True),
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
    global RETIRED
    try:
        RETIRED = identities().pattern()
    except ValueError as error:
        parser.error(str(error))
    if args.self_test:
        self_test()
        return 0
    if args.bundle:
        base = args.bundle.resolve()
        if not (base / "Contents/MacOS/RecScribe").is_file():
            parser.error("--bundle must name a built RecScribe.app")
        paths = base.rglob("*")
    else:
        base = ROOT
        names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        paths = (base / name.decode() for name in names if name)
    failures = inspect(paths, base)
    for path in failures:
        print(f"Retired reference: {path}", file=sys.stderr)
    if failures:
        return 1
    print("Boundary guard passed (no file exceptions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
