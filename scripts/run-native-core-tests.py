#!/usr/bin/env python3
"""Run the complete native suite once, retaining bounded stall diagnostics.

Use through work-artifacts.py. This supervisor changes no test selection or
acceptance: a timeout, interrupted run, live descendant or failed command fails.
"""
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

TIMEOUT_SECONDS = 240
QUIET_SECONDS = 60
TERM_GRACE_SECONDS = 2
KILL_GRACE_SECONDS = 1
LOG_LIMIT = 32 * 1024 * 1024
COMMAND = ["xcrun", "swift", "test", "--package-path", "core"]
PASS_SUMMARY = re.compile(rb"Test run with ([0-9]+) tests?(?: in [0-9]+ suites?)? passed after")


def owned_processes(group):
    """Include child process groups only inside the new, owned session."""
    if type(group) is not int or group <= 1 or group == os.getpgrp():
        raise ValueError("Invalid owned native test process group")
    listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="],
                             capture_output=True, text=True, timeout=.5, check=True)
    result = []
    for line in listing.stdout.splitlines():
        values = line.split(None, 3)
        if len(values) != 4:
            raise ValueError("Malformed process ownership snapshot")
        pid, parent, pgid = map(int, values[:3])
        try:
            if os.getsid(pid) != group:
                continue
        except ProcessLookupError:
            continue
        result.append({"pid": pid, "parent": parent, "group": pgid, "command": values[3]})
    return result


def signal_owned(group, number):
    members = owned_processes(group)
    groups = {}
    for member in members:
        groups.setdefault(member["group"], member["pid"])
    for pgid, pid in groups.items():
        try:
            if os.getsid(pid) != group or os.getpgid(pid) != pgid or pgid == os.getpgrp():
                raise ValueError("Owned native group changed before signaling")
            os.killpg(pgid, number)
        except ProcessLookupError:
            pass
    return members


def test_process(value):
    name = Path(value["command"]).name
    return name.endswith(".xctest") or name in {"RecScribeCorePackageTests", "swiftpm-testing"}


def sample_owned(group, output, note, interrupted):
    targets = [p for p in owned_processes(group) if test_process(p)][:3]
    note("quiet_stall", quiet_seconds=QUIET_SECONDS, owned_test_pids=[p["pid"] for p in targets])
    for target in targets:
        if interrupted():
            return bool(targets)
        # Revalidate immediately before passing any PID to the sampler.
        if target not in owned_processes(group):
            continue
        destination = output / ("native-sample-" + str(target["pid"]) + ".txt")
        try:
            with destination.with_suffix(".stderr.txt").open("xb") as errors:
                result = subprocess.run(["/usr/bin/sample", str(target["pid"]), "1", "-file", str(destination)],
                                        stdout=errors, stderr=subprocess.STDOUT, timeout=2)
            note("sample_finished", pid=target["pid"], returncode=result.returncode, path=str(destination))
        except (OSError, subprocess.TimeoutExpired) as error:
            note("sample_unavailable", pid=target["pid"], error_type=type(error).__name__)
    return bool(targets)


def stop_owned(child, group, note):
    """Finite cleanup, including descendants remaining after the leader exits."""
    for number, grace in ((signal.SIGTERM, TERM_GRACE_SECONDS), (signal.SIGKILL, KILL_GRACE_SECONDS)):
        members = signal_owned(group, number)
        if members:
            note("owned_group_signal", signal=number, pids=[p["pid"] for p in members])
        deadline = time.monotonic() + grace
        while owned_processes(group) and time.monotonic() < deadline:
            child.poll()
            time.sleep(.05)
        if not owned_processes(group):
            break
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        return False
    return not owned_processes(group)


def reap_direct_child(child, note):
    """If inventory fails, still reap our direct Popen; descendants stay unknown."""
    for method in (child.terminate, child.kill):
        if child.poll() is not None:
            break
        try:
            method()
            child.wait(timeout=.5)
        except (OSError, subprocess.TimeoutExpired):
            continue
    try:
        child.wait(timeout=.5)
    except subprocess.TimeoutExpired:
        note("direct_child_reap_failed")


def supervise(output):
    requested = {"signal": None}
    previous = {}

    def interrupted(number, _frame):
        requested["signal"] = number

    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.signal(number, interrupted)
    child = None
    group = None
    reason = None
    cleaned = False
    events = []
    started = time.monotonic()
    last_output = started
    sampled = False
    next_sample = started
    log_bytes = 0
    summary_tail = b""

    def note(event, **details):
        value = {"event": event, "elapsed_seconds": time.monotonic() - started, **details}
        events.append(value)
        print("Native test supervisor: " + json.dumps(value, sort_keys=True), flush=True)

    try:
        with (output / "native-core.log").open("xb") as log:
            child = subprocess.Popen(COMMAND, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     start_new_session=True, bufsize=0)
            group = child.pid
            note("started", pid=group, timeout_seconds=TIMEOUT_SECONDS, command=COMMAND)
            # A signal arriving inside Popen must still enter owned cleanup.
            with selectors.DefaultSelector() as ready:
                os.set_blocking(child.stdout.fileno(), False)
                ready.register(child.stdout, selectors.EVENT_READ)
                eof = False
                while True:
                    now = time.monotonic()
                    if requested["signal"] is not None:
                        reason = "interrupted"
                        break
                    if now - started >= TIMEOUT_SECONDS:
                        reason = "timeout"
                        break
                    if not sampled and now >= next_sample and now - last_output >= QUIET_SECONDS:
                        sampled = sample_owned(group, output, note, lambda: requested["signal"] is not None)
                        next_sample = time.monotonic() + 15
                    for key, _ in ready.select(.1):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            eof = True
                            ready.unregister(key.fileobj)
                            continue
                        last_output = time.monotonic()
                        log_bytes += len(chunk)
                        summary_tail = (summary_tail + chunk)[-65536:]
                        if log_bytes > LOG_LIMIT:
                            reason = "log_limit"
                            break
                        log.write(chunk)
                        log.flush()
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                    if reason is not None:
                        break
                    if child.poll() is not None:
                        members = owned_processes(group)
                        if members:
                            reason = "live_owned_descendants_after_command"
                            break
                        if eof:
                            break
                if reason is None:
                    child.wait(timeout=1)
                    cleaned = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = "supervisor_error"
        note("supervisor_error", error_type=type(error).__name__)
    finally:
        try:
            if child is not None and not cleaned:
                cleaned = stop_owned(child, group, note)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            cleaned = False
            note("cleanup_error", error_type=type(error).__name__)
            if child is not None:
                reap_direct_child(child, note)
        finally:
            if child is not None and child.stdout is not None:
                child.stdout.close()
            for number, handler in previous.items():
                signal.signal(number, handler)
    returncode = child.returncode if child is not None else None
    summaries = PASS_SUMMARY.findall(summary_tail)
    tests_passed = int(summaries[0]) if len(summaries) == 1 else None
    if reason is None and returncode == 0 and (not log_bytes or not tests_passed):
        reason = "missing_or_zero_test_summary"
    result = (128 + requested["signal"] if requested["signal"] is not None else
              124 if reason == "timeout" else 1 if reason is not None or not cleaned else
              returncode if returncode is not None and returncode >= 0 else 128 - (returncode or 0))
    record = {"schema_version": "native-core-supervision-v1", "command": COMMAND,
              "timeout_seconds": TIMEOUT_SECONDS, "quiet_seconds": QUIET_SECONDS,
              "reason": reason, "command_returncode": returncode, "exit_code": result,
              "owned_group_reaped": cleaned, "signal": requested["signal"], "events": events,
              "elapsed_seconds": time.monotonic() - started, "log_bytes": log_bytes,
              "native_summary_tests_passed": tests_passed,
              "complete_suite_required": True, "retry_performed": False}
    with (output / "native-core-supervision.json").open("x") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return result


def main():
    if len(sys.argv) != 1:
        raise ValueError("Native supervisor takes no test-selection arguments")
    value = os.environ.get("RECSCRIBE_RUN_DIR")
    if not value:
        raise ValueError("Run native tests through scripts/work-artifacts.py")
    output = Path(value)
    if not output.is_absolute() or not output.is_dir() or any(p.is_symlink() for p in (output, *output.parents)):
        raise ValueError("Managed native-test artifact directory must be a real absolute directory")
    return supervise(output)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        raise SystemExit(1)
