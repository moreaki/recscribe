#!/usr/bin/env python3
"""Bounded, opt-in retention for disposable developer output, never build caches.

Only marked runs under Build/Artifacts are eligible. Test inputs, recording data,
app backups, unknown directories and active/pinned runs are never pruned.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

PROJECT = Path(__file__).resolve().parent.parent
CATEGORIES = ("benchmark", "test", "scratch", "logs")
MARKER = ".artifact-run.json"
PROTECTED_SUFFIXES = {".wav", ".flac", ".m4a", ".mp3", ".opus", ".aif", ".aiff", ".caf", ".ogg", ".aac", ".app", ".dmg", ".zip", ".xcarchive"}
PROTECTED_NAMES = {"fixtures", "installedbackups", "deriveddata", "products", "raw", "asr", "originals"}


def protected(run):
    unreadable = []
    for folder, directories, files in os.walk(run, followlinks=False, onerror=unreadable.append):
        for name in directories + files:
            path = Path(folder) / name
            lower = name.lower()
            if (path.is_symlink() or lower in PROTECTED_NAMES or lower.startswith("reference")
                    or path.suffix.lower() in PROTECTED_SUFFIXES or "transcript" in lower
                    or lower.endswith((".recscribe.json", ".regions.json")) or lower.startswith("ai-raw-")
                    or path.stem.lower() in {"asr", "raw"} or lower == "canonical.json"):
                return True
    return bool(unreadable)


def safe_root(root):
    # Reject symlinks anywhere in the managed path, including a linked Build.
    if any(path.is_symlink() for path in (root, *root.parents)):
        raise ValueError("Artifact root must not traverse symlinks")


def prune(root, now=None, keep=5, days=7, apply=False):
    safe_root(root)
    if keep < 1 or days < 1:
        raise ValueError("Retention count and age must be positive")
    if not root.exists():
        return []
    now = time.time() if now is None else now
    removed = []
    for category in CATEGORIES:
        parent = root / category
        if not parent.is_dir() or parent.is_symlink():
            continue
        eligible = []
        for run in parent.iterdir():
            if not run.is_dir() or run.is_symlink() or (run / ".pin").exists():
                continue
            marker = run / MARKER
            lease_path = run / ".lease"
            if not marker.is_file() or marker.is_symlink() or not lease_path.is_file() or lease_path.is_symlink():
                continue
            lease = None
            try:
                lease = lease_path.open("r+")
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, BlockingIOError):
                if lease is not None:
                    lease.close()
                continue
            try:
                record = json.loads(marker.read_text())
                stamp = record["finished"] if record["state"] == "complete" else record["started"]
                if (record.get("state") not in {"running", "complete"} or type(record.get("version")) is not int or record.get("version") != 1 or record.get("category") != category
                        or record.get("disposable") is not True or type(stamp) not in (float, int)
                        or not 0 < stamp <= now or protected(run)):
                    lease.close()
                    continue
                # A crashed wrapper may leave an incomplete run. Give its child
                # and investigation a full retention window even without a lock.
                if record["state"] != "complete" and now - stamp < days * 86400:
                    lease.close()
                    continue
                eligible.append((stamp, run, lease, record["state"]))
            except (KeyError, ValueError, OSError, TypeError):
                lease.close()
        eligible.sort(key=lambda item: (item[0], item[1].name), reverse=True)
        completed = 0
        try:
            for stamp, run, lease, state in eligible:
                if state == "complete":
                    completed += 1
                    # Keep the latest completed result even after inactivity.
                    expire = completed > 1 and (completed > keep or now - stamp > days * 86400)
                else:
                    expire = True
                if expire:
                    if apply:
                        shutil.rmtree(run)  # Only locked, explicitly disposable run output.
                    removed.append(run)
        finally:
            for _, _, lease, _ in eligible:
                lease.close()
    return removed


def write_record(path, record):
    staged = path.with_suffix(".new")
    staged.write_text(json.dumps(record, indent=2) + "\n")
    staged.replace(path)


class RunInterrupted(Exception):
    def __init__(self, number):
        self.number = number


def interrupted(number, _frame):
    raise RunInterrupted(number)


def run_command(root, category, label, command):
    safe_root(root)
    prune(root, apply=True)
    parent = root / category
    if parent.is_symlink():
        raise ValueError("Category must not be a symlink")
    parent.mkdir(parents=True, exist_ok=True)
    run = parent / (time.strftime("%Y%m%d-%H%M%S") + "-" + label + "-" + uuid.uuid4().hex[:8])
    run.mkdir()
    with (run / ".lease").open("x+") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        record = dict(version=1, category=category, disposable=True, state="running", started=time.time())
        write_record(run / MARKER, record)
        environment = dict(os.environ, RECSCRIBE_RUN_DIR=str(run))
        print("Artifacts: " + str(run), file=sys.stderr)
        result = 130
        process = None
        previous_handler = signal.signal(signal.SIGTERM, interrupted)
        try:
            with (run / "console.log").open("wb") as log:
                process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, pass_fds=(lease.fileno(),))
                while chunk := process.stdout.read1(65536):
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                result = process.wait()
        except OSError as error:
            result = 127
            print(f"Artifact command could not execute: {error}", file=sys.stderr)
        except (KeyboardInterrupt, RunInterrupted) as error:
            result = 128 + getattr(error, "number", signal.SIGINT)
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            record.update(state="complete", finished=time.time(), exit_code=result)
            write_record(run / MARKER, record)
    prune(root, apply=True)
    return result if result >= 0 else 128 - result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    cleanup = sub.add_parser("prune", help="List expired managed runs; --apply removes only those runs")
    cleanup.add_argument("--apply", action="store_true")
    cleanup.add_argument("--quiet", action="store_true")
    execute = sub.add_parser("run", help="Run a disposable job with a leased output directory and captured log")
    execute.add_argument("category", choices=CATEGORIES)
    execute.add_argument("--label", default="run")
    execute.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = PROJECT / "Build/Artifacts"
    try:
        if args.action == "prune":
            paths = prune(root, apply=args.apply)
            if not args.quiet:
                for path in paths:
                    print(path)
                print(f"{'Removed' if args.apply else 'Eligible'} managed runs: {len(paths)}")
            return 0
        command = args.command
        if command and command[0] == "--":
            command = command[1:]
        if not command or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.label):
            parser.error("A command and simple label (1–64 letters/digits/_/-) are required")
        return run_command(root, args.category, args.label, command)
    except (OSError, ValueError) as error:
        print(f"Artifact retention: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
