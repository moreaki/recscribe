"""Native CI ownership/status contracts; no Swift, samplers or child launches."""
import importlib.util
import json
from pathlib import Path
import signal
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("native_core_supervisor", Path(__file__).parents[1] / "run-native-core-tests.py")
supervisor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supervisor)


class NativeCoreSupervisorContracts(unittest.TestCase):
    def test_complete_command_and_finite_budget_are_fixed(self):
        self.assertEqual(supervisor.COMMAND, ["xcrun", "swift", "test", "--package-path", "core"])
        self.assertEqual(supervisor.TIMEOUT_SECONDS, 240)
        self.assertEqual(supervisor.QUIET_SECONDS, 60)

    def test_foreign_groups_and_mismatched_sessions_cannot_be_signaled(self):
        snapshot = SimpleNamespace(stdout="100 1 100 /foreign/test.xctest\n200 1 200 /owned/test.xctest\n")
        with patch.object(supervisor.subprocess, "run", return_value=snapshot), \
             patch.object(supervisor.os, "getpgrp", return_value=999), \
             patch.object(supervisor.os, "getsid", return_value=201), \
             patch.object(supervisor.os, "killpg") as kill:
            self.assertEqual(supervisor.signal_owned(200, signal.SIGTERM), [])
            kill.assert_not_called()
        with patch.object(supervisor.os, "getpgrp", return_value=200), \
             patch.object(supervisor.os, "killpg") as kill:
            with self.assertRaises(ValueError):supervisor.signal_owned(200, signal.SIGTERM)
            kill.assert_not_called()

    def test_snapshot_only_returns_the_launched_session_and_group(self):
        snapshot = SimpleNamespace(stdout="100 1 100 /foreign/test.xctest\n200 1 200 /owned/swift\n201 200 201 /owned/RecScribeCorePackageTests\n")
        with patch.object(supervisor.subprocess, "run", return_value=snapshot), \
             patch.object(supervisor.os, "getpgrp", return_value=999), \
             patch.object(supervisor.os, "getsid", side_effect=lambda pid:100 if pid==100 else 200) as sid:
            self.assertEqual([p["pid"] for p in supervisor.owned_processes(200)], [200, 201])
            self.assertEqual([call.args[0] for call in sid.call_args_list], [100, 200, 201])

    def test_separate_child_groups_are_signaled_only_in_the_owned_session(self):
        members=[{"pid":200,"group":200},{"pid":201,"group":201}]
        with patch.object(supervisor, "owned_processes", return_value=members), \
             patch.object(supervisor.os, "getsid", return_value=200), \
             patch.object(supervisor.os, "getpgid", side_effect=lambda pid:pid), \
             patch.object(supervisor.os, "getpgrp", return_value=999), \
             patch.object(supervisor.os, "killpg") as kill:
            supervisor.signal_owned(200, signal.SIGTERM)
            self.assertEqual([c.args for c in kill.call_args_list],[(200,signal.SIGTERM),(201,signal.SIGTERM)])

    def test_failed_inventory_still_reaps_direct_child_without_claiming_descendant_cleanup(self):
        child=MagicMock()
        child.poll.side_effect=[None,0]
        supervisor.reap_direct_child(child,lambda *a,**k:None)
        child.terminate.assert_called_once()
        child.wait.assert_called()

    def test_sampler_revalidates_only_owned_test_descendants(self):
        owned = [{"pid":200,"parent":1,"group":200,"command":"/bin/swift"},
                 {"pid":201,"parent":200,"group":200,"command":"/owned/RecScribeCorePackageTests"},
                 {"pid":202,"parent":200,"group":200,"command":"/bin/clang"}]
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", return_value=owned), \
             patch.object(supervisor.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            self.assertTrue(supervisor.sample_owned(200, Path(root), lambda *a, **k:None, lambda:False))
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:3], ["/usr/bin/sample", "201", "1"])
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", side_effect=[owned, []]), \
             patch.object(supervisor.subprocess, "run") as run:
            supervisor.sample_owned(200, Path(root), lambda *a, **k:None, lambda:False)
            run.assert_not_called()

    def test_actual_host_basenames_are_exact_without_including_the_coordinator(self):
        for name in ("xctest", "swiftpm-testing-helper"):
            self.assertTrue(supervisor.test_process({"command": "/owned/toolchain/" + name}))
        for name in ("swift-test", "not-swiftpm-testing-helper", "swiftpm-testing-helper-old"):
            self.assertFalse(supervisor.test_process({"command": "/owned/toolchain/" + name}))

    def test_xctest_and_testing_helper_are_sampled_only_after_owned_session_filtering(self):
        for name in ("xctest", "swiftpm-testing-helper"):
            with self.subTest(host=name):
                listing = SimpleNamespace(stdout=f"100 1 100 /foreign/toolchain/{name}\n"
                    f"200 1 200 /owned/swift\n201 200 201 /owned/toolchain/{name}\n"
                    "202 200 200 /owned/unrecognized-test-host\n")
                sampled, notes = [], []
                def run(argv, **kwargs):
                    if argv[0] == "/bin/ps": return listing
                    sampled.append(argv)
                    return SimpleNamespace(returncode=0)
                with tempfile.TemporaryDirectory() as root, \
                     patch.object(supervisor.subprocess, "run", side_effect=run), \
                     patch.object(supervisor.os, "getpgrp", return_value=999), \
                     patch.object(supervisor.os, "getsid", side_effect=lambda pid:100 if pid==100 else 200):
                    self.assertTrue(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False))
                self.assertEqual([argv[:3] for argv in sampled], [["/usr/bin/sample", "201", "1"]])
                event, details = notes[0]
                self.assertEqual(event, "quiet_stall")
                self.assertEqual(details["owned_test_pids"], [201])
                self.assertEqual(details["owned_process_count"], 3)
                self.assertFalse(details["owned_process_snapshot_truncated"])
                self.assertEqual(details["owned_process_snapshot"], [
                    {"pid":200,"parent":1,"group":200,"basename":"swift","eligible":False},
                    {"pid":201,"parent":200,"group":201,"basename":name,"eligible":True},
                    {"pid":202,"parent":200,"group":200,"basename":"unrecognized-test-host","eligible":False}])

    def test_helper_sampling_preserves_three_target_cap_and_two_second_bound(self):
        owned = [{"pid":201+i,"parent":200,"group":201+i,"command":"/owned/swiftpm-testing-helper"} for i in range(5)]
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", return_value=owned), \
             patch.object(supervisor.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            self.assertTrue(supervisor.sample_owned(200, Path(root), lambda *a, **k:None, lambda:False))
        self.assertEqual([c.args[0][:3] for c in run.call_args_list],
                         [["/usr/bin/sample",str(pid),"1"] for pid in (201,202,203)])
        self.assertTrue(all(c.kwargs["timeout"] == 2 for c in run.call_args_list))

    def test_stall_retains_unknown_or_empty_owned_inventory_without_sampling_foreign_names(self):
        for owned in ([], [{"pid":201,"parent":200,"group":201,"command":"/owned/unknown-host"}]):
            notes = []
            with tempfile.TemporaryDirectory() as root, \
                 patch.object(supervisor, "owned_processes", return_value=owned), \
                 patch.object(supervisor.subprocess, "run") as run:
                self.assertFalse(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False))
                run.assert_not_called()
            details = notes[0][1]
            self.assertEqual(details["owned_process_count"], len(owned))
            self.assertEqual(len(details["owned_process_snapshot"]), len(owned))
            self.assertEqual(details["owned_test_pids"], [])
            self.assertFalse(details["owned_process_snapshot_truncated"])
            self.assertTrue(all(not p["eligible"] and "command" not in p for p in details["owned_process_snapshot"]))

    def test_stall_inventory_is_bounded_to_64_with_exact_total_and_truncation(self):
        owned = [{"pid":201+i,"parent":200,"group":200,"command":"/owned/unknown-"+str(i)} for i in range(70)]
        notes = []
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", return_value=owned), \
             patch.object(supervisor.subprocess, "run") as run:
            self.assertFalse(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False))
            run.assert_not_called()
        details = notes[0][1]
        self.assertEqual(details["owned_process_count"], 70)
        self.assertTrue(details["owned_process_snapshot_truncated"])
        self.assertEqual([p["pid"] for p in details["owned_process_snapshot"]], list(range(201,265)))
        self.assertTrue(all(set(p)=={"pid","parent","group","basename","eligible"} for p in details["owned_process_snapshot"]))

    def test_cleanup_reaps_descendants_even_after_the_leader_exits(self):
        members = [{"pid":201}]
        numbers = []
        def send(group, number):
            self.assertEqual(group, 200);numbers.append(number)
            before = list(members)
            if number == signal.SIGKILL:members.clear()
            return before
        child = SimpleNamespace(poll=lambda:0, wait=lambda timeout:0)
        with patch.object(supervisor, "signal_owned", side_effect=send), \
             patch.object(supervisor, "owned_processes", side_effect=lambda _:list(members)), \
             patch.object(supervisor, "TERM_GRACE_SECONDS", 0):
            self.assertTrue(supervisor.stop_owned(child, 200, lambda *a, **k:None))
        self.assertEqual(numbers, [signal.SIGTERM, signal.SIGKILL])

    def execute_mock(self, *, canceled=False, timeout=False, returncode=37, output=b""):
        child = MagicMock(pid=200)
        child.stdout.fileno.return_value = 123
        child.returncode = returncode
        child.poll.return_value = returncode
        child.wait.return_value = returncode
        handlers = {}
        def register(number, handler):
            old = handlers.get(number);handlers[number] = handler;return old
        def launch(*args, **kwargs):
            self.assertEqual(args[0], supervisor.COMMAND)
            self.assertTrue(kwargs["start_new_session"])
            if canceled:handlers[signal.SIGTERM](signal.SIGTERM, None)
            return child
        selector = MagicMock()
        selector.__enter__.return_value = selector
        selector.select.return_value = [(SimpleNamespace(fd=123, fileobj=child.stdout), None)]
        clock = [0, 0, 241, 241] if timeout else [0]*30
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor.signal, "signal", side_effect=register), \
             patch.object(supervisor.subprocess, "Popen", side_effect=launch), \
             patch.object(supervisor.selectors, "DefaultSelector", return_value=selector), \
             patch.object(supervisor.os, "set_blocking"), \
             patch.object(supervisor.os, "read", side_effect=[output,b""] if output else [b""]), \
             patch.object(supervisor.sys, "stdout", MagicMock()), \
             patch.object(supervisor.time, "monotonic", side_effect=clock), \
             patch.object(supervisor, "owned_processes", return_value=[]), \
             patch.object(supervisor, "stop_owned", return_value=True) as stop:
            result=supervisor.supervise(Path(root))
            record=json.loads((Path(root)/"native-core-supervision.json").read_text())
            return result,record,stop.call_count

    def test_cancel_during_popen_still_cleans_up_and_never_passes(self):
        result,record,stops=self.execute_mock(canceled=True)
        self.assertEqual(result, 128+signal.SIGTERM)
        self.assertEqual(record["reason"], "interrupted")
        self.assertEqual(stops, 1)
        self.assertTrue(record["owned_group_reaped"])

    def test_natural_nonzero_status_is_preserved_without_retry(self):
        result,record,stops=self.execute_mock(returncode=37)
        self.assertEqual(result, 37)
        self.assertIsNone(record["reason"])
        self.assertFalse(record["retry_performed"])
        self.assertEqual(stops, 0)

    def test_timeout_fails_and_cleans_up(self):
        result,record,stops=self.execute_mock(timeout=True)
        self.assertEqual(result, 124)
        self.assertEqual(record["reason"], "timeout")
        self.assertEqual(stops, 1)

    def test_zero_exit_without_positive_complete_test_summary_cannot_pass(self):
        for output in (b"", b"Test run with 0 tests passed after 0 seconds.\n", b"Build complete!\n"):
            result,record,_=self.execute_mock(returncode=0,output=output)
            self.assertEqual(result, 1)
            self.assertEqual(record["reason"], "missing_or_zero_test_summary")

    def test_complete_native_summary_and_status_are_both_required(self):
        result,record,_=self.execute_mock(returncode=0,output=b"Test run with 88 tests in 15 suites passed after 1 second.\n")
        self.assertEqual(result, 0)
        self.assertEqual(record["native_summary_tests_passed"], 88)


if __name__ == "__main__":unittest.main()
