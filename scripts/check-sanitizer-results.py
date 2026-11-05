#!/usr/bin/env python3
"""Reject sanitizer diagnostics even when xcodebuild exits zero after a restart."""
import argparse
import json
from pathlib import Path
import re


DIAGNOSTIC = re.compile(
    r"(?:WARNING|SUMMARY|ERROR):\s*ThreadSanitizer|ThreadSanitizer:\s*(?:data race|reported)|"
    r"Thread Sanitizer:|Restarting after unexpected exit, crash, or test timeout", re.IGNORECASE)


def problems(summary, functional, log):
    errors = []
    if summary.get("result") != "Passed" or summary.get("failedTests") != 0:
        errors.append("Sanitizer test result is not a complete pass")
    if not isinstance(summary.get("runtimeWarnings"), list) or summary.get("runtimeWarnings") or summary.get("testFailures"):
        errors.append("Sanitizer result bundle contains runtime warnings or failures")
    if functional.get("result") != "Passed" or functional.get("failedTests") != 0:
        errors.append("Functional baseline is missing or failed")
    count = summary.get("totalTestCount", 0)
    if not isinstance(count, int) or count <= 0 or count != functional.get("totalTestCount"):
        errors.append("Functional and sanitizer test counts differ or are missing")
    if DIAGNOSTIC.search(log):
        errors.append("Sanitizer log contains a diagnostic or unexpected test-host restart")
    if "** TEST SUCCEEDED **" not in log:
        errors.append("Sanitizer log has no successful completion marker")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("functional", type=Path)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        errors = problems(json.loads(args.summary.read_text()),
                          json.loads(args.functional.read_text()), args.log.read_text())
    except (OSError, ValueError, TypeError, AttributeError) as error:
        errors = [f"Cannot verify sanitizer evidence: {error}"]
    for error in errors:
        print(f"::error::{error}")
    if not errors:
        print("Sanitizer evidence is complete and contains no runtime diagnostics.")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
