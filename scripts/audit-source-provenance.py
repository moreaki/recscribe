#!/usr/bin/env python3
"""Report historical source ancestry without inferring copyright independence.

Run from any directory. Requires the original snapshot in local Git history;
never fetches another repository or examines untracked recordings/build output.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = "2f9c42dd92dad72cb7e1d29ce555c2ee48967e53"
REVIEW = ROOT / "docs/provenance/reviewed-components.json"



def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def audit():
    reviewed = {item["path"]: item for item in json.loads(REVIEW.read_text())["files"]} if REVIEW.exists() else {}
    upstream = git("rev-parse", UPSTREAM).decode().strip()
    ancestors = set(git("rev-list", upstream).decode().splitlines())
    contributor_commits = []
    for record in git("log", "--format=%H%x00%an%x00%B%x00%x1e").decode().split("\x1e"):
        fields = record.strip().split("\x00")
        if len(fields) < 3:
            continue
        sha, author, message = fields[:3]
        haystack = (author + " " + message).lower()
        if any(term in haystack for term in ("melissa", "pereira", "mdebritto", "claude", "anthropic")):
            contributor_commits.append({"commit": sha, "in_original_snapshot": sha in ancestors})
    original = collections.defaultdict(list)
    for entry in git("ls-tree", "-rz", "--full-tree", upstream).split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            original[meta.split()[2].decode()].append(path.decode())
    files = []
    for encoded in git("ls-files", "-z").split(b"\0"):
        if not encoded:
            continue
        path = encoded.decode()
        file = ROOT / path
        if not file.is_file():
            files.append({"path": path, "status": "removed"})
            continue
        content = file.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        exact = original.get(blob, [])
        inherited_lines = 0
        origins = set()
        # Binary files are compared by blob, with changes remaining unreviewed.
        if b"\0" not in content:
            result = subprocess.run(["git", "blame", "-M", "-C", "--line-porcelain", "--", path],
                                    cwd=ROOT, capture_output=True)
            if result.returncode and b"no such path" not in result.stderr:
                raise RuntimeError(result.stderr.decode())
            blame = result.stdout.decode()
            commit = None
            source = None
            for line in blame.splitlines():
                parts = line.split()
                if len(parts) in (3, 4) and len(parts[0]) == 40:
                    commit = parts[0]
                elif line.startswith("filename "):
                    source = line[9:]
                elif line.startswith("\t") and commit in ancestors and line[1:].strip():
                    inherited_lines += 1
                    if source:
                        origins.add(source)
        # Absence of unchanged lines is not proof that a file wasn't adapted.
        fingerprint = hashlib.sha256(content).hexdigest()
        decision = reviewed.get(path)
        if decision and decision["sha256"] == fingerprint:
            status = decision["decision"]
        elif decision:
            status = "changed-after-review"
        elif exact or inherited_lines:
            status = "ancestry-review-required"
        else:
            status = "no-direct-ancestry-found"
        files.append({"path": path, "status": status, "sha256": hashlib.sha256(content).hexdigest(),
                      "unchanged_ancestral_lines": inherited_lines,
                      "original_paths": sorted(set(exact) | origins)})
    return {"upstream_snapshot": upstream,
            "source_snapshot": git("rev-parse", "HEAD").decode().strip(),
            "method": "Exact Git blobs and git blame -M -C; not a clean-room or legal certification.",
            "contributor_reference_commits": contributor_commits,
            "files": files}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write JSON instead of stdout")
    args = parser.parse_args()
    result = json.dumps(audit(), indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")
