#!/usr/bin/env python3
"""Reject sensitive paths and recognizable secrets in the Git index.

Read staged blobs rather than working files. Diagnostics contain only paths and
rule names; secret contents are never printed. No network or credential lookup.
"""
from pathlib import Path
import re
import subprocess
import sys

PATH_RULE = re.compile(
    r"(^|/)(?:\.env(?:\..*)?|private|BACKLOG\.md|secrets\.[^/]*|id_(?:rsa|dsa|ecdsa|ed25519))($|/)"
    r"|\.private\.md$|\.(?:p12|cer|p8|key|pem|mobileprovision|provisionprofile)$"
    r"|(?:[-_]|^)priv(?:ate)?[-_]?key|(?:sparkle|signing)[-_].*key|appcast.*\.key$"
    r"|(^|/)AuthKey_.*\.p8$|(^|/)notariz.*\.txt$|(^|/)docs/product-strategy/",
    re.IGNORECASE,
)
CONTENT_RULES = {
    "private key": rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----",
    "AWS access key": rb"\bAKIA[0-9A-Z]{16}\b",
    "Slack token": rb"\bxox[baprs]-[0-9A-Za-z-]{10,}\b",
    "live payment key": rb"\bsk_live_[0-9A-Za-z]{16,}\b",
    "GitHub token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})\b",
    "raw signing seed": rb"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/])",
    "app password": rb"(?<![a-z-])(?:[a-z]{4}-){3}[a-z]{4}(?![a-z-])",
}
COMPILED = {name: re.compile(pattern) for name, pattern in CONTENT_RULES.items()}


def violations(path, content):
    if PATH_RULE.search(path):
        yield "sensitive path"
    for name, pattern in COMPILED.items():
        if pattern.search(content):
            yield name


def main():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    names = subprocess.check_output(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd=root)
    blocked = False
    for raw in names.split(b"\0"):
        if not raw:
            continue
        path = raw.decode("utf-8", errors="surrogateescape")
        blob = subprocess.check_output(["git", "show", ":" + path], cwd=root)
        for rule in violations(path, blob):
            print(f"Commit blocked: {path!r} matches {rule}.", file=sys.stderr)
            blocked = True
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
