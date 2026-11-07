"""Fail-closed capture probes and owned-launch cancellation; no real processes."""
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("research_guard", Path(__file__).parents[1] / "quality/run-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class ResearchGuardContracts(unittest.TestCase):
    def probe(self, listing, files=None, **kwargs):
        result = SimpleNamespace(stdout=" PID PGID %CPU COMM\n" + listing, stderr="", returncode=0)
        calls = [result] if files is None else [result, files]
        with patch.object(guard.subprocess, "run", side_effect=calls):
            return guard.capture_or_competing_work(1, **kwargs)

    def test_capture_writes_and_uncertain_visibility_block(self):
        listing = "200 200 0.0 /Applications/RecScribe.app/Contents/MacOS/RecScribe\n"
        for access in (b"w", b"u"):
            files = SimpleNamespace(returncode=0, stderr=b"", stdout=b"p200\0f12\0a" + access + b"\0n/private/audio.wav\0")
            self.assertEqual(self.probe(listing, files), "application_writing_audio")
        for files in (
            SimpleNamespace(returncode=1, stderr=b"", stdout=b""),
            SimpleNamespace(returncode=0, stderr=b"warning", stdout=b"p200\0"),
            SimpleNamespace(returncode=0, stderr=b"", stdout=b"p201\0"),
            SimpleNamespace(returncode=0, stderr=b"", stdout=b"p200\0f12\0n/audio.wav\0"),
        ):
            self.assertEqual(self.probe(listing, files), "capture_state_unavailable")

    def test_read_only_audio_is_not_capture_and_malformed_ps_fails(self):
        files = SimpleNamespace(returncode=0, stderr=b"", stdout=b"p200\0fcwd\0n/private\0f12\0ar\0n/audio.wav\0")
        self.assertIsNone(self.probe("200 200 0.0 /Applications/RecScribe.app/Contents/MacOS/RecScribe\n", files))
        self.assertEqual(self.probe("200 malformed\n"), "process_state_unavailable")
        self.assertEqual(self.probe("200 200 nan harmless\n"), "process_state_unavailable")

    def test_competing_research_build_and_vm_are_blocked(self):
        for name in ("recscribe-activation-probe", "clang++", "ninja", "cmake", "whisper-quantize"):
            self.assertEqual(self.probe(f"200 200 0.0 /usr/bin/{name}\n"), "competing_test_build_or_asr")
        self.assertEqual(self.probe("200 200 0.0 /usr/bin/qemu-system-aarch64\n"), "competing_vm_guest")

    def test_only_verified_owned_session_can_bypass_competing_probe(self):
        with patch.object(guard.os, "getsid", return_value=900):
            self.assertIsNone(self.probe("200 200 99.0 /usr/bin/whisper-cli\n", owned_session=900))
        with patch.object(guard.os, "getsid", side_effect=PermissionError):
            self.assertEqual(self.probe("200 200 0.0 harmless\n", owned_session=900), "process_session_state_unavailable")
        with patch.object(guard.os, "getsid", return_value=901):
            self.assertEqual(self.probe("200 200 0.0 /usr/bin/whisper-cli\n", owned_session=900), "competing_test_build_or_asr")

    def test_foreign_session_cannot_be_signaled_as_owned(self):
        child = SimpleNamespace(pid=200)
        with patch.object(guard.os, "killpg") as kill:
            with self.assertRaises(RuntimeError):
                guard.stop_owned(child, 201, Path("unused"), lambda *a, **k: None, 1, 1, 1, 1, {})
            kill.assert_not_called()

    def test_cancel_during_popen_still_cleans_up_owned_child(self):
        handlers = {}
        child = SimpleNamespace(pid=987654, poll=lambda: None)
        def register(number, handler): handlers[number] = handler
        def launch(*args, **kwargs):
            self.assertTrue(kwargs["start_new_session"])
            handlers[signal.SIGINT](signal.SIGINT, None)
            return child
        shutdown = {"returncode": 130, "cli_reaped": True, "owned_session_present": False, "shutdown_errors": []}
        with tempfile.TemporaryDirectory(prefix="recscribe-guard-contract-") as temporary:
            output = Path(temporary) / "new-output"
            with patch.object(guard.signal, "signal", side_effect=register), \
                 patch.object(guard, "capture_or_competing_work", return_value=None), \
                 patch.object(guard.subprocess, "Popen", side_effect=launch), \
                 patch.object(guard.os, "setpriority"), \
                 patch.object(guard, "stop_owned", return_value=shutdown) as stop:
                result = guard.main(["--output", str(output), "--", sys.executable, "--output", str(output)])
            self.assertEqual(result, 130)
            self.assertIs(stop.call_args.args[0], child)
            self.assertEqual(stop.call_args.args[1], child.pid)
            events = [json.loads(x) for x in output.with_name(output.name + ".guard.jsonl").read_text().splitlines()]
            self.assertTrue(events[-1]["canceled"])
            self.assertTrue(events[-1]["shutdown"]["cli_reaped"])


if __name__ == "__main__":
    unittest.main()
