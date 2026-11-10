"""Native CI ownership/status contracts; no Swift, samplers or child launches."""
import importlib.util
from contextlib import contextmanager
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


class FakeClock:
    def __init__(self): self.value = 0
    def __call__(self): return self.value


class FakeSampler:
    def __init__(self, clock, pid, finish_after):
        self.clock, self.pid = clock, pid
        self.finish = None if finish_after is None else clock.value + finish_after
        self.returncode = None
        self.waits, self.kills = [], 0
    def poll(self):
        if self.returncode is None and self.finish is not None and self.clock.value >= self.finish:
            self.returncode = 0
        return self.returncode
    def wait(self, timeout):
        self.waits.append(timeout)
        if self.poll() is not None: return self.returncode
        if self.finish is not None and self.finish <= self.clock.value + timeout:
            self.clock.value = self.finish
            self.returncode = 0
            return 0
        self.clock.value += timeout
        raise supervisor.subprocess.TimeoutExpired("synthetic sampler", timeout)
    def kill(self):
        self.kills += 1
        self.returncode = -signal.SIGKILL


class NativeCoreSupervisorContracts(unittest.TestCase):
    def test_complete_command_and_finite_budget_are_fixed(self):
        self.assertEqual(supervisor.COMMAND, ["xcrun", "swift", "test", "--package-path", "core"])
        self.assertEqual(supervisor.TIMEOUT_SECONDS, 240)
        self.assertEqual(supervisor.QUIET_SECONDS, 60)
        self.assertEqual(supervisor.SAMPLER_TOTAL_SECONDS, 10)
        self.assertEqual(supervisor.SAMPLER_CLEANUP_SECONDS, 2)
        self.assertEqual(supervisor.SAMPLER_POLL_SECONDS, .1)

    @staticmethod
    def finished_sampler(pid=500):
        return SimpleNamespace(pid=pid, returncode=0, poll=lambda:0, wait=lambda timeout:0)

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
             patch.object(supervisor, "owned_processes", side_effect=lambda group:owned if group==200 else []), \
             patch.object(supervisor.time, "monotonic", return_value=0), \
             patch.object(supervisor.subprocess, "Popen", return_value=self.finished_sampler()) as launch:
            self.assertTrue(supervisor.sample_owned(200, Path(root), lambda *a, **k:None, lambda:False, 240))
            self.assertEqual(launch.call_count, 1)
            self.assertEqual(launch.call_args.args[0][:3], ["/usr/bin/sample", "201", "1"])
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", side_effect=[owned, []]), \
             patch.object(supervisor.time, "monotonic", return_value=0), \
             patch.object(supervisor.subprocess, "Popen") as launch:
            supervisor.sample_owned(200, Path(root), lambda *a, **k:None, lambda:False, 240)
            launch.assert_not_called()

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
                notes = []
                def run(argv, **kwargs):
                    self.assertEqual(argv[0], "/bin/ps")
                    return listing
                with tempfile.TemporaryDirectory() as root, \
                     patch.object(supervisor.subprocess, "run", side_effect=run), \
                     patch.object(supervisor.subprocess, "Popen", return_value=self.finished_sampler()) as launch, \
                     patch.object(supervisor.time, "monotonic", return_value=0), \
                     patch.object(supervisor.os, "getpgrp", return_value=999), \
                     patch.object(supervisor.os, "getsid", side_effect=lambda pid:100 if pid==100 else 200):
                    self.assertTrue(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False, 240))
                self.assertEqual(launch.call_args.args[0][:3], ["/usr/bin/sample", "201", "1"])
                self.assertTrue(launch.call_args.kwargs["start_new_session"])
                event, details = notes[0]
                self.assertEqual(event, "quiet_stall")
                self.assertEqual(details["owned_test_pids"], [201])
                self.assertEqual(details["owned_process_count"], 3)
                self.assertFalse(details["owned_process_snapshot_truncated"])
                self.assertEqual(details["owned_process_snapshot"], [
                    {"pid":200,"parent":1,"group":200,"basename":"swift","eligible":False},
                    {"pid":201,"parent":200,"group":201,"basename":name,"eligible":True},
                    {"pid":202,"parent":200,"group":200,"basename":"unrecognized-test-host","eligible":False}])

    def test_helper_sampling_preserves_three_target_cap_and_shared_ten_second_bound(self):
        owned = [{"pid":201+i,"parent":200,"group":201+i,"command":"/owned/swiftpm-testing-helper"} for i in range(5)]
        notes = []
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor, "owned_processes", side_effect=lambda group:owned if group==200 else []), \
             patch.object(supervisor.time, "monotonic", return_value=0), \
             patch.object(supervisor.subprocess, "Popen", side_effect=[self.finished_sampler(500+i) for i in range(3)]) as launch:
            self.assertTrue(supervisor.sample_owned(200, Path(root), lambda e,**k:notes.append((e,k)), lambda:False, 240))
        self.assertEqual([c.args[0][:3] for c in launch.call_args_list],
                         [["/usr/bin/sample",str(pid),"1"] for pid in (201,202,203)])
        self.assertEqual([v["total_budget_seconds"] for e,v in notes if e=="sample_started"], [10]*3)

    @contextmanager
    def sampling_fixture(self, *, targets=1, finish_after=None, startup=0, inventory_cost=0,
                         cancel_at=None, cancel_after_spawn=False, changed_target=False,
                         cleanup_error=False, descendants=False, foreign_descendant=False):
        clock, children, launches, notes, kills = FakeClock(), [], [], [], []
        native = [{"pid":201+i,"parent":200,"group":201+i,"command":"/owned/swiftpm-testing-helper"} for i in range(targets)]
        calls = {"native_inventory":0}
        descendant_live = {}
        def launch(argv, **kwargs):
            self.assertEqual(argv[0], "/usr/bin/sample")
            self.assertEqual(argv[2], "1")
            self.assertTrue(kwargs["start_new_session"])
            clock.value += startup
            selected = finish_after[len(children)] if isinstance(finish_after,list) else finish_after
            child = FakeSampler(clock,500+10*len(children),selected)
            children.append(child);launches.append((argv,kwargs));descendant_live[child.pid]=descendants
            return child
        def inventory(group):
            clock.value += inventory_cost
            if group==200:
                calls["native_inventory"]+=1
                return [{**native[0],"group":777}] if changed_target and calls["native_inventory"]>1 else native
            child=next(c for c in children if c.pid==group)
            if cleanup_error:raise ValueError("Synthetic inventory failure")
            result=[]
            if child.poll() is None:result.append({"pid":child.pid,"parent":999,"group":child.pid,"command":"/usr/bin/sample"})
            if descendant_live[child.pid]:result.append({"pid":child.pid+1,"parent":child.pid,"group":child.pid+1,"command":"/owned/sampler-child"})
            return result
        def sid(pid):
            if any(v["pid"]==pid for v in native):return 200
            for child in children:
                if pid==child.pid:return child.pid
                if pid==child.pid+1:return 777 if foreign_descendant else child.pid
            return 777
        def kill_group(group,number):
            kills.append((group,number))
            for child in children:
                if group==child.pid:child.kill()
                if group==child.pid+1:descendant_live[child.pid]=False
        def interrupted():
            return cancel_after_spawn and bool(children) or cancel_at is not None and clock.value>=cancel_at
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor.time,"monotonic",side_effect=clock), \
             patch.object(supervisor,"owned_processes",side_effect=inventory), \
             patch.object(supervisor.subprocess,"Popen",side_effect=launch), \
             patch.object(supervisor.os,"getsid",side_effect=sid), \
             patch.object(supervisor.os,"getpgid",side_effect=lambda pid:pid), \
             patch.object(supervisor.os,"getpgrp",return_value=999), \
             patch.object(supervisor.os,"killpg",side_effect=kill_group):
            yield SimpleNamespace(clock=clock,children=children,launches=launches,notes=notes,kills=kills,calls=calls,
                collect=lambda deadline:supervisor.sample_owned(200,Path(root),lambda e,**k:notes.append((e,k)),interrupted,deadline))

    def test_slow_first_sampler_cannot_reset_shared_budget_for_another_target(self):
        with self.sampling_fixture(targets=3,inventory_cost=.5) as f:
            self.assertTrue(f.collect(240))
            self.assertEqual(len(f.launches),1)
            self.assertLessEqual(f.clock.value,10)
            self.assertEqual(f.children[0].returncode,-signal.SIGKILL)
            self.assertTrue(any(e=="sample_skipped" for e,_ in f.notes))
            self.assertEqual(f.kills,[(500,signal.SIGKILL)])

    def test_fast_first_and_slow_second_share_the_original_budget(self):
        with self.sampling_fixture(targets=3,finish_after=[1,None,None]) as f:
            f.collect(240)
            self.assertEqual(len(f.launches),2)
            self.assertAlmostEqual(f.clock.value,8)
            self.assertEqual(f.children[0].returncode,0)
            self.assertEqual(f.children[1].returncode,-signal.SIGKILL)

    def test_shorter_suite_deadline_clamps_sampling_and_reserved_cleanup(self):
        with self.sampling_fixture() as f:
            f.collect(5)
            self.assertEqual(len(f.launches),1)
            self.assertLessEqual(f.clock.value,5)
            self.assertAlmostEqual(f.clock.value,3)
            self.assertTrue(all(v["within_total_budget"] for e,v in f.notes if e=="sampler_cleanup"))

    def test_no_sampler_launch_when_deadline_is_exhausted_or_safe_budget_missing(self):
        for deadline in (0,1,2,3):
            with self.subTest(deadline=deadline),self.sampling_fixture() as f:
                f.collect(deadline)
                self.assertEqual(f.launches,[])
                if deadline==0:self.assertEqual(f.calls["native_inventory"],0)

    def test_inventory_and_revalidation_consume_the_shared_allowance(self):
        with self.sampling_fixture(inventory_cost=.5) as f:
            f.collect(4)
            self.assertEqual(f.launches,[])
            self.assertAlmostEqual(f.clock.value,1)
            self.assertTrue(any(v.get("reason")=="budget_exhausted_during_revalidation" for _,v in f.notes))

    def test_popen_startup_consumes_active_budget_instead_of_resetting_it(self):
        with self.sampling_fixture(startup=3) as f:
            f.collect(240)
            self.assertAlmostEqual(f.clock.value,8)
            self.assertEqual(f.children[0].returncode,-signal.SIGKILL)
            self.assertTrue(all(timeout<=.1 for timeout in f.children[0].waits[:-1]))

    def test_startup_past_total_deadline_fails_closed_and_reaps_direct_sampler(self):
        with self.sampling_fixture(startup=11) as f:
            with self.assertRaises(ValueError):f.collect(240)
            self.assertEqual(f.children[0].returncode,-signal.SIGKILL)
            self.assertTrue(any(v["within_total_budget"] is False for e,v in f.notes if e=="sampler_cleanup"))

    def test_interruption_after_popen_or_while_polling_reaps_only_sampler(self):
        for settings in ({"cancel_after_spawn":True},{"cancel_at":.2}):
            with self.subTest(settings=settings),self.sampling_fixture(**settings) as f:
                f.collect(240)
                self.assertEqual(f.kills,[(500,signal.SIGKILL)])
                self.assertEqual(f.children[0].returncode,-signal.SIGKILL)
                self.assertLessEqual(f.clock.value,.2)
                self.assertTrue(f.launches[0][1]["stdout"].closed)

    def test_changed_foreign_target_membership_prevents_sampler_launch(self):
        with self.sampling_fixture(changed_target=True) as f:
            f.collect(240)
            self.assertEqual(f.launches,[])
            self.assertEqual(f.kills,[])

    def test_sampler_descendants_in_distinct_owned_groups_are_cleaned(self):
        with self.sampling_fixture(descendants=True) as f:
            f.collect(240)
            self.assertEqual(f.kills,[(500,signal.SIGKILL),(501,signal.SIGKILL)])
            self.assertTrue(any(v["owned_session_reaped"] for e,v in f.notes if e=="sampler_cleanup"))

    def test_uncertain_sampler_inventory_is_fatal_but_direct_child_is_reaped(self):
        with self.sampling_fixture(cleanup_error=True) as f:
            with self.assertRaises(ValueError):f.collect(240)
            self.assertEqual(f.children[0].returncode,-signal.SIGKILL)
            self.assertEqual(f.kills,[])
            self.assertTrue(any(v["owned_session_reaped"] is False for e,v in f.notes if e=="sampler_cleanup"))

    def test_sampler_group_identity_change_never_signals_foreign_group(self):
        with self.sampling_fixture(descendants=True,foreign_descendant=True) as f:
            with self.assertRaises(ValueError):f.collect(240)
            self.assertNotIn((501,signal.SIGKILL),f.kills)

    def test_stall_retains_unknown_or_empty_owned_inventory_without_sampling_foreign_names(self):
        for owned in ([], [{"pid":201,"parent":200,"group":201,"command":"/owned/unknown-host"}]):
            notes = []
            with tempfile.TemporaryDirectory() as root, \
                 patch.object(supervisor, "owned_processes", return_value=owned), \
                 patch.object(supervisor.time, "monotonic", return_value=0), \
                 patch.object(supervisor.subprocess, "Popen") as launch:
                self.assertFalse(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False, 240))
                launch.assert_not_called()
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
             patch.object(supervisor.time, "monotonic", return_value=0), \
             patch.object(supervisor.subprocess, "Popen") as launch:
            self.assertFalse(supervisor.sample_owned(200, Path(root), lambda event, **details:notes.append((event,details)), lambda:False, 240))
            launch.assert_not_called()
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

    def execute_mock(self, *, canceled=False, timeout=False, returncode=37, output=b"",
                     diagnostic_deadline=False, diagnostic_uncertain=False):
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
        clock = ([0,0,61]+[240]*30 if diagnostic_deadline else [0,0]+[61]*30 if diagnostic_uncertain
                 else [0, 0, 241, 241] if timeout else [0]*30)
        with tempfile.TemporaryDirectory() as root, \
             patch.object(supervisor.signal, "signal", side_effect=register), \
             patch.object(supervisor.subprocess, "Popen", side_effect=launch), \
             patch.object(supervisor.selectors, "DefaultSelector", return_value=selector), \
             patch.object(supervisor.os, "set_blocking"), \
             patch.object(supervisor.os, "read", side_effect=[output,b""] if output else [b""]), \
             patch.object(supervisor.sys, "stdout", MagicMock()), \
             patch.object(supervisor.time, "monotonic", side_effect=clock), \
             patch.object(supervisor, "sample_owned", side_effect=ValueError("Uncertain sampler cleanup") if diagnostic_uncertain else None,
                          return_value=True) as diagnostic, \
             patch.object(supervisor, "owned_processes", return_value=[]), \
             patch.object(supervisor, "stop_owned", return_value=True) as stop:
            result=supervisor.supervise(Path(root))
            record=json.loads((Path(root)/"native-core-supervision.json").read_text())
            if diagnostic_deadline or diagnostic_uncertain:
                selector.select.assert_not_called()
                self.assertEqual(diagnostic.call_args.args[-1],240)
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

    def test_original_suite_deadline_is_rechecked_immediately_after_diagnostics(self):
        result,record,stops=self.execute_mock(diagnostic_deadline=True)
        self.assertEqual(result,124)
        self.assertEqual(record["reason"],"timeout")
        self.assertEqual(record["timeout_seconds"],240)
        self.assertEqual(record["sampler_total_seconds"],10)
        self.assertEqual(stops,1)

    def test_uncertain_sampler_cleanup_prevents_supervisor_success(self):
        result,record,stops=self.execute_mock(diagnostic_uncertain=True,returncode=0)
        self.assertEqual(result,1)
        self.assertEqual(record["reason"],"supervisor_error")
        self.assertEqual(stops,1)

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
