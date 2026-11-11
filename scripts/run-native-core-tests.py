#!/usr/bin/env python3
"""Run the complete native suite once, retaining bounded stall diagnostics.

Use through work-artifacts.py. This supervisor changes no test selection or
acceptance: a timeout, interrupted run, live descendant or failed command fails.
"""
import json
import math
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
SAMPLER_TOTAL_SECONDS = 10
SAMPLER_CLEANUP_SECONDS = 2
SAMPLER_POLL_SECONDS = .1
OWNERSHIP_PROBE_SECONDS = .5
POST_COMMAND_PROBE_ATTEMPTS = 3
POST_COMMAND_PROBE_TOTAL_SECONDS = 2
OWNERSHIP_COMMAND = ["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="]
COMMAND = ["xcrun", "swift", "test", "--package-path", "core"]
PASS_SUMMARY = re.compile(rb"Test run with ([0-9]+) tests?(?: in [0-9]+ suites?)? passed after")


def owned_processes(group, timeout=OWNERSHIP_PROBE_SECONDS):
    """Include child process groups only inside the new, owned session."""
    if type(group) is not int or group <= 1 or group == os.getpgrp():
        raise ValueError("Invalid owned native test process group")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= OWNERSHIP_PROBE_SECONDS:
        raise ValueError("Invalid bounded ownership probe timeout")
    listing = subprocess.run(OWNERSHIP_COMMAND, capture_output=True, text=True, timeout=timeout, check=True)
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


def post_command_owned_processes(group, note, interrupted, suite_deadline):
    """Resample timed-out ownership observations, never the completed test run.

    A valid fresh snapshot is still mandatory. None only hands an interruption
    or the original suite deadline back to the supervisor's existing gates.
    Sampler and cleanup inventory retain their original single-probe behavior.
    """
    deadline = min(time.monotonic() + POST_COMMAND_PROBE_TOTAL_SECONDS, suite_deadline)
    for attempt in range(1, POST_COMMAND_PROBE_ATTEMPTS + 1):
        now = time.monotonic()
        if interrupted() or now >= suite_deadline:
            return None
        remaining = deadline - now
        if remaining <= 0:
            note("ownership_probe_deadline", phase="post_command", command=OWNERSHIP_COMMAND,
                 attempt=attempt, total_budget_seconds=POST_COMMAND_PROBE_TOTAL_SECONDS)
            raise subprocess.TimeoutExpired(OWNERSHIP_COMMAND, POST_COMMAND_PROBE_TOTAL_SECONDS)
        timeout = min(OWNERSHIP_PROBE_SECONDS, remaining)
        try:
            members = owned_processes(group, timeout=timeout)
        except subprocess.TimeoutExpired:
            note("ownership_probe_timeout", phase="post_command", command=OWNERSHIP_COMMAND,
                 attempt=attempt, maximum_attempts=POST_COMMAND_PROBE_ATTEMPTS, timeout_seconds=timeout,
                 total_budget_seconds=POST_COMMAND_PROBE_TOTAL_SECONDS)
            if interrupted() or time.monotonic() >= suite_deadline:
                return None
            if attempt == POST_COMMAND_PROBE_ATTEMPTS or time.monotonic() >= deadline:
                raise
        else:
            if interrupted() or time.monotonic() >= suite_deadline:
                return None
            if time.monotonic() >= deadline:
                note("ownership_probe_deadline", phase="post_command", command=OWNERSHIP_COMMAND,
                     attempt=attempt, total_budget_seconds=POST_COMMAND_PROBE_TOTAL_SECONDS)
                raise subprocess.TimeoutExpired(OWNERSHIP_COMMAND, POST_COMMAND_PROBE_TOTAL_SECONDS)
            if attempt > 1:
                note("ownership_probe_recovered", phase="post_command", command=OWNERSHIP_COMMAND,
                     attempt=attempt, owned_process_count=len(members))
            return members


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
    return name.endswith(".xctest") or name in {"xctest", "RecScribeCorePackageTests", "swiftpm-testing", "swiftpm-testing-helper"}


def stop_sampler(child, deadline, note):
    """Reap only the sampler's new session, inside its reserved total budget."""
    cleaned = False
    try:
        if deadline - time.monotonic() <= .5:
            raise subprocess.TimeoutExpired("sampler cleanup", 0)
        members = owned_processes(child.pid)
        groups = {}
        for member in members:
            groups.setdefault(member["group"], member["pid"])
        if child.poll() is None and not any(p["pid"] == child.pid for p in members):
            raise ValueError("Live sampler missing from its owned session")
        for pgid, pid in groups.items():
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired("sampler cleanup", 0)
            try:
                if os.getsid(pid) != child.pid or os.getpgid(pid) != pgid or pgid == os.getpgrp():
                    raise ValueError("Owned sampler identity changed before signaling")
                # subprocess.run previously used SIGKILL for its sampler timeout.
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        remaining = deadline - time.monotonic()
        if remaining <= .5:
            raise subprocess.TimeoutExpired("sampler reap", 0)
        child.wait(timeout=min(.5, remaining - .5))
        if deadline - time.monotonic() <= .5:
            raise subprocess.TimeoutExpired("sampler verification", 0)
        cleaned = not owned_processes(child.pid)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        note("sampler_cleanup_error", pid=child.pid, error_type=type(error).__name__)
        # If inventory failed, retain uncertainty but still reap our direct child.
        if child.poll() is None:
            try:
                if os.getsid(child.pid) == child.pid and os.getpgid(child.pid) == child.pid:
                    child.kill()
            except ProcessLookupError:
                pass
        remaining = deadline - time.monotonic()
        try:
            child.wait(timeout=min(.5, max(0, remaining)))
        except (OSError, subprocess.TimeoutExpired):
            pass
    within_budget = time.monotonic() <= deadline
    note("sampler_cleanup", pid=child.pid, owned_session_reaped=cleaned, within_total_budget=within_budget)
    return cleaned and within_budget


def sample_owned(group, output, note, interrupted, suite_deadline):
    # One shared budget includes every target, inventory, startup and cleanup.
    started = time.monotonic()
    deadline = min(started + SAMPLER_TOTAL_SECONDS, suite_deadline)
    if started >= suite_deadline:
        note("sample_skipped", reason="suite_deadline_exhausted")
        return False
    owned = owned_processes(group)
    targets = [p for p in owned if test_process(p)][:3]
    snapshot = [{"pid": p["pid"], "parent": p["parent"], "group": p["group"],
                 "basename": Path(p["command"]).name, "eligible": test_process(p)} for p in owned[:64]]
    note("quiet_stall", quiet_seconds=QUIET_SECONDS, owned_test_pids=[p["pid"] for p in targets],
         owned_process_snapshot=snapshot, owned_process_count=len(owned),
         owned_process_snapshot_truncated=len(owned) > 64)
    for target in targets:
        if interrupted():
            return bool(targets)
        work_deadline = deadline - SAMPLER_CLEANUP_SECONDS
        if work_deadline - time.monotonic() <= 1:
            note("sample_skipped", pid=target["pid"], reason="insufficient_capture_and_cleanup_budget")
            break
        # Revalidate immediately before passing any PID to the sampler.
        if target not in owned_processes(group):
            continue
        if interrupted():
            return bool(targets)
        if work_deadline - time.monotonic() <= 1:
            note("sample_skipped", pid=target["pid"], reason="budget_exhausted_during_revalidation")
            break
        destination = output / ("native-sample-" + str(target["pid"]) + ".txt")
        child = None
        try:
            with destination.with_suffix(".stderr.txt").open("xb") as errors:
                child = subprocess.Popen(["/usr/bin/sample", str(target["pid"]), "1", "-file", str(destination)],
                                         stdin=subprocess.DEVNULL, stdout=errors, stderr=subprocess.STDOUT,
                                         start_new_session=True)
                if child.poll() is None and (os.getsid(child.pid) != child.pid or os.getpgid(child.pid) != child.pid):
                    raise ValueError("Sampler must own a new session")
                note("sample_started", pid=target["pid"], sampler_pid=child.pid, capture_seconds=1,
                     total_budget_seconds=deadline-started, cleanup_reserve_seconds=SAMPLER_CLEANUP_SECONDS)
                while child.poll() is None:
                    if interrupted():
                        break
                    remaining = work_deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        child.wait(timeout=min(SAMPLER_POLL_SECONDS, remaining))
                    except subprocess.TimeoutExpired:
                        pass
                if child.poll() is None:
                    note("sample_unavailable", pid=target["pid"],
                         error_type="Interrupted" if interrupted() else "SamplerWorkDeadlineExpired")
                else:
                    note("sample_finished", pid=target["pid"], returncode=child.returncode, path=str(destination))
        except (OSError, subprocess.TimeoutExpired) as error:
            note("sample_unavailable", pid=target["pid"], error_type=type(error).__name__)
        finally:
            if child is not None and not stop_sampler(child, deadline, note):
                raise ValueError("Owned sampler cleanup or total diagnostic budget is uncertain")
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
    suite_deadline = started + TIMEOUT_SECONDS
    last_output = started
    sampled = False
    next_sample = started
    log_bytes = 0
    summary_tail = b""
    phase = "launch"
    post_command_verified = False

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
                    phase = "supervision"
                    now = time.monotonic()
                    if requested["signal"] is not None:
                        reason = "interrupted"
                        break
                    if now >= suite_deadline:
                        reason = "timeout"
                        break
                    if not sampled and now >= next_sample and now - last_output >= QUIET_SECONDS:
                        phase = "quiet_diagnostics"
                        sampled = sample_owned(group, output, note, lambda: requested["signal"] is not None, suite_deadline)
                        next_sample = time.monotonic() + 15
                        if requested["signal"] is not None:
                            reason = "interrupted"
                            break
                        if time.monotonic() >= suite_deadline:
                            reason = "timeout"
                            break
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
                        if not post_command_verified:
                            phase = "post_command_ownership"
                            members = post_command_owned_processes(group, note, lambda: requested["signal"] is not None, suite_deadline)
                            if requested["signal"] is not None:
                                reason = "interrupted"
                                break
                            if time.monotonic() >= suite_deadline:
                                reason = "timeout"
                                break
                            if members is None:
                                raise ValueError("Completed command ownership remains unverified")
                            if members:
                                reason = "live_owned_descendants_after_command"
                                break
                            # No session members remain to spawn another owned
                            # child. Drain any buffered output without resetting
                            # the finite post-command observation budget.
                            post_command_verified = True
                        if eof:
                            break
                if reason is None:
                    phase = "post_command_wait"
                    child.wait(timeout=1)
                    cleaned = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = "supervisor_error"
        details = dict(phase=phase, error_type=type(error).__name__)
        if isinstance(error, subprocess.TimeoutExpired):
            details.update(command=error.cmd, timeout_seconds=error.timeout)
        note("supervisor_error", **details)
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
              "sampler_total_seconds": SAMPLER_TOTAL_SECONDS,
              "sampler_cleanup_reserve_seconds": SAMPLER_CLEANUP_SECONDS,
              "post_command_probe_maximum_attempts": POST_COMMAND_PROBE_ATTEMPTS,
              "post_command_probe_total_budget_seconds": POST_COMMAND_PROBE_TOTAL_SECONDS,
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
