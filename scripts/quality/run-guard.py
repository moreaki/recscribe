#!/usr/bin/env python3
"""Serial offline research guard. Cancel this owned job, never capture.

Example (the output directory and JSONL log must both be new):
  python3 run-guard.py --output /protected/run/matrix --timeout 1800 -- \
    /path/to/recscribe-text benchmark /protected/corpus.json \
    --experiment /protected/experiment.json --output /protected/run/matrix

No shell is used. The CLI is launched in a new session; Foundation.Process may
give its workers separate groups in that same session. Escalation enumerates
and signals only groups verified in the owned session. Probes are bounded; any
uncertain probe, guard exception or signal cancels/reaps the owned CLI in finally.
This polling guard is not a real-time capture scheduler or proof of idle audio.
"""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


COMPETING_NAMES = {
    "xcodebuild", "xctest", "swift-test", "swift-build", "swift-frontend",
    "recscribe-text", "whisper-cli", "whisper-bench", "whisper-quantize",
    "quantize", "ffmpeg", "afplay", "sox", "cmake", "ninja", "clang", "clang++",
    "c++", "recscribe-activation-probe",
}
VM_NAMES = {"com.apple.Virtualization.VirtualMachine", "com.docker.virtualization",
            "vmware-vmx", "prl_vm_app", "UTM", "tart", "vfkit", "krun"}
AUDIO_SUFFIXES = (".wav", ".caf", ".pcm", ".aiff", ".aif", ".flac", ".m4a", ".mp3", ".opus", ".ogg")
LAST_PROBE_DETAIL = {}


def capture_or_competing_work(probe_timeout, owned_session=None, foreign_cpu_limit=50, observed_groups=None):
    LAST_PROBE_DETAIL.clear()
    process_info = {}

    def blocked(reason, pid=None):
        # Keep the original classification/gate unchanged. Retain the exact ps
        # observation before a transient offender disappears during cleanup.
        detail = {"classification": reason, "observed_at": time.time(),
                  "owned_session": owned_session, "foreign_cpu_limit_percent": foreign_cpu_limit,
                  "cpu_scope": "ps-reported process %CPU; not a GPU-activity measurement"}
        if pid is not None:
            detail.update(process_info.get(pid, {"pid": pid}))
            try:
                detail["session"] = os.getsid(pid)
                detail["session_status"] = "observed"
            except ProcessLookupError:
                detail["session"] = None
                detail["session_status"] = "process_disappeared_after_ps_snapshot"
            except OSError as error:
                detail["session"] = None
                detail["session_status"] = "unavailable:" + type(error).__name__
        LAST_PROBE_DETAIL.update(detail)
        return reason

    listing = subprocess.run(["/bin/ps", "-axo", "pid,pgid,pcpu,comm"], capture_output=True,
                             text=True, timeout=probe_timeout, check=True,
                             env=dict(os.environ, LC_ALL="C"))
    lines = listing.stdout.splitlines()
    if len(lines) < 2 or "PID" not in lines[0] or "PGID" not in lines[0]:
        return blocked("process_state_unavailable")
    applications = set()
    for line in lines[1:]:
        fields = line.strip().split(None, 3)
        if len(fields) != 4 or not fields[0].isdigit() or not fields[1].isdigit():
            return blocked("process_state_unavailable")
        pid, group, command = int(fields[0]), int(fields[1]), fields[3]
        try:
            cpu = float(fields[2])
        except ValueError:
            return blocked("process_state_unavailable", pid)
        if not math.isfinite(cpu) or cpu < 0:
            return blocked("process_state_unavailable", pid)
        name = Path(command).name
        process_info[pid] = {"pid": pid, "process_group": group, "command_name": name,
                             "command_path": command, "cpu_percent": cpu}
        if owned_session is not None:
            try:
                if os.getsid(pid) == owned_session:
                    if observed_groups is not None:
                        observed_groups.setdefault(group, set()).add(pid)
                    continue
            except ProcessLookupError:
                continue
            except OSError:
                return blocked("process_session_state_unavailable", pid)
        if name in COMPETING_NAMES or name.endswith(".xctest"):
            return blocked("competing_test_build_or_asr", pid)
        if name in VM_NAMES or name.startswith("qemu-system-"):
            return blocked("competing_vm_guest", pid)
        if pid != os.getpid() and cpu >= foreign_cpu_limit:
            return blocked("competing_high_cpu_process", pid)
        if name == "RecScribe":
            applications.add(pid)
    if not applications:
        return None
    files = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-F0pfan", "-p",
                            ",".join(str(pid) for pid in sorted(applications))],
                           capture_output=True, timeout=probe_timeout)
    # A warning or missing PID can mean permissions/partial inspection. Do not
    # turn incomplete visibility into an assertion that capture is idle.
    if files.returncode != 0 or files.stderr.strip() or not files.stdout:
        return blocked("capture_state_unavailable")
    seen, access, current_pid, descriptor = set(), None, None, None
    for field in files.stdout.split(b"\0"):
        field = field.lstrip(b"\n")
        if not field:
            continue
        tag, value = field[:1], field[1:]
        if tag == b"p":
            if not value.isdigit():
                return blocked("capture_state_unavailable")
            current_pid, access, descriptor = int(value), None, None
            seen.add(current_pid)
        elif tag == b"f":
            access, descriptor = None, value
        elif tag == b"a":
            access = value
        elif tag == b"n":
            if current_pid not in applications or descriptor is None:
                return blocked("capture_state_unavailable", current_pid)
            if descriptor in (b"cwd", b"rtd", b"txt", b"mem"):
                continue  # Metadata/mapping entries do not have fd access fields.
            if not descriptor.isdigit() or access is None:
                return blocked("capture_state_unavailable", current_pid)
            if access in (b"w", b"u"):
                name = os.fsdecode(value).lower()
                if any(suffix in name for suffix in AUDIO_SUFFIXES):
                    return blocked("application_writing_audio", current_pid)
    if seen != applications:
        return blocked("capture_state_unavailable")
    return None


def session_groups(session, probe_timeout):
    listing = subprocess.run(["/bin/ps", "-axo", "pid,pgid"], capture_output=True,
                             text=True, timeout=probe_timeout, check=True)
    lines = listing.stdout.splitlines()
    if len(lines) < 2 or "PID" not in lines[0] or "PGID" not in lines[0]:
        raise RuntimeError("Owned-session process state is unavailable")
    groups = {}
    for line in lines[1:]:
        values = line.split()
        if len(values) != 2 or not all(value.isdigit() for value in values):
            raise RuntimeError("Owned-session process state is incomplete")
        pid, group = map(int, values)
        if pid <= 0:
            continue
        try:
            if os.getsid(pid) == session:
                groups.setdefault(group, set()).add(pid)
        except ProcessLookupError:
            continue
    return groups


def verified_group_member(group, session, members):
    if group <= 1 or group == os.getpgrp():
        return False
    for pid in members:
        try:
            if os.getsid(pid) == session and os.getpgid(pid) == group:
                return True
        except ProcessLookupError:
            continue
    return False


def stop_owned(child, session, output, record, interrupt_grace, terminate_grace, kill_grace,
               probe_timeout, observed_groups):
    if session != child.pid or session <= 1 or session == os.getsid(0):
        raise RuntimeError("Refusing to signal an unowned session")
    errors = []

    def note(event, **fields):
        try:
            record(event, **fields)
        except Exception as error:
            errors.append("evidence:" + type(error).__name__)

    def current_groups():
        groups = session_groups(session, probe_timeout)
        for group, members in groups.items():
            observed_groups.setdefault(group, set()).update(members)
        return groups

    def signal_groups(number):
        try:
            groups = current_groups()
        except Exception as error:
            errors.append("session_probe:" + type(error).__name__)
            groups = observed_groups
        for group, members in list(groups.items()):
            try:
                if verified_group_member(group, session, members):
                    os.killpg(group, number)
                    note("owned_group_signal", signal=number, group=group, session=session)
            except ProcessLookupError:
                pass
            except OSError as error:
                errors.append("signal:" + type(error).__name__)

    def wait_group(seconds):
        deadline = time.monotonic() + seconds
        while True:
            child.poll()  # Reap the direct CLI, including after it exits first.
            try:
                groups = current_groups()
            except Exception as error:
                errors.append("session_probe:" + type(error).__name__)
                return False
            if not groups and child.poll() is not None:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(0.2, remaining))

    try:
        active = child.poll() is None or bool(current_groups())
    except Exception as error:
        errors.append("session_probe:" + type(error).__name__)
        active = True
    if active:
        try:
            if output.is_dir() and not output.is_symlink():
                marker = output / "cancel.request"
                descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(descriptor)
        except FileExistsError:
            pass
        except OSError as error:
            errors.append("cancel_marker:" + type(error).__name__)
        # Give the canonical CLI its normal cancellation/evidence path first.
        try:
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
                note("owned_cli_signal", signal=signal.SIGINT, pid=child.pid)
            else:
                signal_groups(signal.SIGINT)
        except ProcessLookupError:
            pass
        except OSError as error:
            errors.append("interrupt:" + type(error).__name__)
        if not wait_group(interrupt_grace):
            signal_groups(signal.SIGTERM)
            if not wait_group(terminate_grace):
                signal_groups(signal.SIGKILL)
                wait_group(kill_grace)
    # SIGKILL is a last fallback if direct CLI reaping has not completed, even
    # when an earlier probe or evidence write failed. Never wait indefinitely.
    if child.poll() is None:
        signal_groups(signal.SIGKILL)
        try:
            child.kill()  # Direct Popen ownership remains valid even if ps failed.
        except ProcessLookupError:
            pass
    try:
        code = child.wait(timeout=kill_grace)
    except subprocess.TimeoutExpired:
        errors.append("owned_cli_not_reaped_after_kill")
        code = None
    try:
        alive = bool(current_groups())
    except Exception as error:
        errors.append("final_session_probe:" + type(error).__name__)
        alive = None
    if alive:
        errors.append("owned_session_groups_still_present")
    return {"returncode": code, "cli_reaped": code is not None, "owned_session_present": alive,
            "shutdown_errors": errors}


def bounded(value, minimum, maximum, name, unit="seconds"):
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be within {minimum}..{maximum} {unit}")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--poll-seconds", type=float, default=1)
    parser.add_argument("--probe-timeout", type=float, default=2)
    parser.add_argument("--foreign-cpu-limit", type=float, default=50,
                        help="Defer/cancel for a foreign process at this ps %%CPU threshold; not a GPU-idle proof")
    parser.add_argument("--interrupt-grace", type=float, default=8)
    parser.add_argument("--terminate-grace", type=float, default=3)
    parser.add_argument("--kill-grace", type=float, default=2)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        bounded(args.timeout, 1, 3600, "timeout")
        bounded(args.poll_seconds, 0.2, 2, "poll")
        bounded(args.probe_timeout, 0.1, 3, "probe timeout")
        bounded(args.foreign_cpu_limit, 10, 1000, "foreign CPU threshold", "percent")
        bounded(args.interrupt_grace, 1, 10, "interrupt grace")
        bounded(args.terminate_grace, 1, 5, "terminate grace")
        bounded(args.kill_grace, 1, 3, "kill grace")
        output = args.output.expanduser().resolve()
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command or command.count("--output") != 1:
            raise ValueError("Supply one CLI command with one matching --output argument")
        index = command.index("--output")
        if index + 1 >= len(command) or Path(command[index + 1]).expanduser().resolve() != output:
            raise ValueError("Guard output and CLI output differ")
        command[0] = str(Path(command[0]).expanduser().resolve(strict=True))
        if not os.access(command[0], os.X_OK):
            raise ValueError("CLI must be executable")
        if output.exists() or output.is_symlink() or not output.parent.is_dir():
            raise ValueError("Output must be new, with an existing parent directory")
        command[index + 1] = str(output)
        log = (args.log or output.with_name(output.name + ".guard.jsonl")).expanduser().resolve()
        descriptor = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    child, session, reason, failure, shutdown = None, None, None, None, None
    observation = None
    observed_groups = {}
    requested = {"signal": None}
    def signal_requested(number, _frame):
        requested["signal"] = number
    for number in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(number, signal_requested)
    started = time.monotonic()
    with os.fdopen(descriptor, "w", buffering=1) as evidence:
        def record(event, **fields):
            evidence.write(json.dumps({"time": time.time(), "event": event, **fields}, allow_nan=False) + "\n")
            evidence.flush()
            os.fsync(evidence.fileno())
        try:
            reason = capture_or_competing_work(args.probe_timeout, foreign_cpu_limit=args.foreign_cpu_limit)
            if reason or requested["signal"] is not None:
                reason = reason or "guard_signal_before_start"
                observation = dict(LAST_PROBE_DETAIL) if LAST_PROBE_DETAIL else None
                record("not_started", reason=reason, guard_observation=observation)
            else:
                record("starting", command=command, timeout_seconds=args.timeout, poll_seconds=args.poll_seconds,
                       probe_timeout_seconds=args.probe_timeout, interrupt_grace=args.interrupt_grace,
                       terminate_grace=args.terminate_grace, kill_grace=args.kill_grace,
                       foreign_cpu_limit=args.foreign_cpu_limit)
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
                session = child.pid  # Guaranteed by start_new_session, never another process's session.
                observed_groups[session] = {child.pid}
                try:
                    os.setpriority(os.PRIO_PROCESS, child.pid, 10)
                    nice = 10
                except ProcessLookupError:
                    if child.poll() is None:
                        raise
                    nice = None  # A very short CLI may exit before priority observation.
                record("started", pid=child.pid, owned_session=session, child_nice=nice)
                deadline = time.monotonic() + args.timeout
                while child.poll() is None:
                    if requested["signal"] is not None:
                        reason = "guard_signal"
                        break
                    if time.monotonic() >= deadline:
                        reason = "experiment_time_budget"
                        break
                    reason = capture_or_competing_work(args.probe_timeout, owned_session=session,
                                                       foreign_cpu_limit=args.foreign_cpu_limit,
                                                       observed_groups=observed_groups)
                    if reason:
                        observation = dict(LAST_PROBE_DETAIL) if LAST_PROBE_DETAIL else None
                        record("cancel_requested", reason=reason, guard_observation=observation)
                        break
                    time.sleep(min(args.poll_seconds, max(0, deadline - time.monotonic())))
                if reason is None and session_groups(session, args.probe_timeout):
                    reason = "owned_descendants_after_cli_exit"
        except BaseException as error:
            reason, failure = "guard_exception", type(error).__name__ + ": " + str(error)
        finally:
            # No guard probe/logging exception may leave the launched CLI behind.
            if child is not None:
                try:
                    shutdown = stop_owned(child, session, output, record, args.interrupt_grace,
                                          args.terminate_grace, args.kill_grace,
                                          args.probe_timeout, observed_groups)
                except BaseException as error:
                    # Even an unexpected shutdown/probe error must not bypass the
                    # final verified owned-session groups/direct CLI kill/reap
                    # attempt. No global process pattern or foreign PID is killed.
                    failure = failure or "guard_shutdown_exception:" + type(error).__name__
                    cleanup_errors = [type(error).__name__]
                    if session == child.pid and session > 1 and session != os.getsid(0):
                        try:
                            for group, members in session_groups(session, args.probe_timeout).items():
                                observed_groups.setdefault(group, set()).update(members)
                        except Exception as probe_error:
                            cleanup_errors.append(type(probe_error).__name__)
                        for group, members in list(observed_groups.items()):
                            try:
                                if verified_group_member(group, session, members):
                                    os.killpg(group, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            except OSError as kill_error:
                                cleanup_errors.append(type(kill_error).__name__)
                        try:
                            if child.poll() is None:
                                child.kill()
                        except ProcessLookupError:
                            pass
                        except OSError as kill_error:
                            cleanup_errors.append(type(kill_error).__name__)
                    try:
                        code = child.wait(timeout=args.kill_grace)
                    except (subprocess.TimeoutExpired, OSError) as wait_error:
                        code = None
                        cleanup_errors.append(type(wait_error).__name__)
                    shutdown = {"returncode": code, "cli_reaped": code is not None,
                                "owned_session_present": None, "shutdown_errors": cleanup_errors}
            try:
                record("finished", reason=reason, failure=failure, shutdown=shutdown, guard_observation=observation,
                       elapsed_seconds=time.monotonic() - started, canceled=reason is not None)
            except Exception as error:
                failure = failure or "guard_evidence_unavailable:" + type(error).__name__
                print("Guard evidence unavailable; owned benchmark cancellation was attempted", file=sys.stderr)
    if failure or shutdown and (shutdown["shutdown_errors"] or not shutdown["cli_reaped"]):
        return 1
    if child is None:
        return 75
    if reason == "experiment_time_budget":
        return 124
    if reason is not None:
        return 130
    return shutdown["returncode"]


if __name__ == "__main__":
    raise SystemExit(main())
