"""Local child processes, bounded cancellation and low-priority execution."""

import os
import signal
import subprocess
import threading
import time
from pathlib import Path


class Cancelled(Exception):
    pass


class Cancellation:
    def __init__(self, request_path: Path):
        self.request_path = request_path
        self.event = threading.Event()

    def check(self):
        if self.event.is_set() or self.request_path.exists():
            raise Cancelled("Cancellation requested")


def run_local(argv: list[str], log: Path, cancel: Cancellation,
              timeout: float = 3600) -> float:
    """No shell, network service or implicit executable lookup."""
    cancel.check()
    started = time.monotonic()
    with log.open("wb") as output:
        process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            while process.poll() is None:
                cancel.check()
                if time.monotonic() - started > timeout:
                    raise TimeoutError(f"Local process timed out; see {log.name}")
                cancel.event.wait(0.05)
            cancel.check()
            if process.returncode:
                raise RuntimeError(f"Local process exited {process.returncode}; see {log.name}")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
    return time.monotonic() - started
