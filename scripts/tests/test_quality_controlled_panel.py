"""Model-free balanced-resource lifecycle and evidence contracts."""
import copy
from datetime import timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "quality/controlled-panel.py"
SPEC = importlib.util.spec_from_file_location("controlled_panel", SOURCE)
panel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(panel)


FAKE_NATIVE = r'''
import hashlib,json,os,signal,subprocess,sys,time
from pathlib import Path
args=sys.argv[1:]
def arg(name):return args[args.index(name)+1]
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
corpus_path=Path(args[1]);config_path=Path(arg("--experiment"));out=Path(arg("--output"))
out.mkdir(mode=0o700)
(out/"experiment.original.json").write_bytes(config_path.read_bytes())
(out/"corpus.original.json").write_bytes(corpus_path.read_bytes())
with (out.parent/"launched.jsonl").open("a") as f:f.write(json.dumps({"block":out.name})+"\n")
mode=os.environ.get("PANEL_SYNTHETIC_NATIVE_MODE","")
if mode=="fail":sys.exit(7)
if mode=="hang":
 child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"],process_group=0)
 (out.parent/"descendant.pid").write_text(str(child.pid))
 try:
  while True:time.sleep(.1)
 except KeyboardInterrupt:
  try:child.terminate()
  except ProcessLookupError:pass
  child.wait(timeout=3)
  sys.exit(130)
config=json.loads(config_path.read_text());corpus=json.loads(corpus_path.read_text());case=corpus["cases"][0]
profile=config["profiles"][0];profile_sha=sha(profile["settings"])
(out/("profile-"+profile["id"]+".json")).write_bytes(Path(profile["settings"]).read_bytes())
runner=sha(arg("--transcription-cli"));binary=sha(config["whisper_cli"])
effective=hashlib.sha256(b"synthetic native serialization, distinct from raw profile bytes").hexdigest()
rows=[]
for index,model in enumerate(config["models"]):
 measurement=dict(status="completed_with_review",source_sha256=case["sha256"],reference_sha256=None,
  scoring_version="unscored-resources-v1",wall_seconds=1.0 if model["id"]=="f16" else .8,
  peak_rss_bytes=100 if model["id"]=="f16" else None if mode=="missing-rss" else 60,
  real_time_factor=.03,source_audio_seconds=30,
  engine_passes=[{"binary_sha256":binary,"model_sha256":model["sha256"],"vad_model_sha256":None,"decoding":{"profile_sha256":effective}}],
  engine_runtime_measurements=[{"runtime_timings":{"observations":{"load":[{"seconds":.1}]}}}])
 row=dict(id=case["id"],language=case["language"],task=case.get("task"),source_channel=case.get("source_channel"),language_mode=config["language_modes"][0],repeat=1,path="final",
  source_sha256=case["sha256"],model_sha256=model["sha256"],transcription_runner_sha256=runner,
  whisper_binary_sha256=binary,measurement_scope="resources_only",scoring_policy="unscored-resources-v1",
  model_kind=model["kind"],baseline_model_id=model.get("baseline_model_id",model["id"]),baseline_model_sha256=model.get("baseline_model_sha256",model["sha256"]),
  intervention_id=model.get("intervention_id"),precision=model["precision"],checkpoint=model["checkpoint"],
  profile=profile["id"],profile_kind=profile["kind"],profile_sha256=profile_sha,runtime_settings_sha256=effective,
  effective_profile_sha256=effective,vad_model_sha256=None,preparation_policy="synthetic-preparation-v1",
  baseline_runner_sha256=None,source_revision=profile["source_revision"],reference_sha256=None,
  threads=config["threads"],model=model["id"],status="completed_with_review",measurement=measurement,
  runner_sha256=runner,engine_identity_observations=1,
  evidence_directory="cell-"+str(index))
 rows.append(row)
 cell=out/row["evidence_directory"];cell.mkdir()
 (cell/"results.json").write_text(json.dumps({"runner_sha256":runner,"results":[measurement]}))
matrix=dict(schema_version="1.0",dry_run=False,serial_jobs=True,split="development",configuration_sha256=sha(config_path),corpus_sha256=sha(corpus_path),runner_sha256=runner,
 coordinator_sha256=sha(__file__),whisper_binary_sha256=binary,measurement_scope="resources_only",
 profile_sha256={profile["id"]:profile_sha},
 threads=config["threads"],host={"thermal_state":0},rows=rows)
(out/"matrix.json").write_text(json.dumps(matrix))
'''


class Fixture:
    def __init__(self, root, model_count=2, seconds=60):
        self.root = root
        self.write("audio.wav", b"model-free synthetic source; never opened by a recognizer")
        self.write("transcriber", b"#!/bin/sh\nexit 99\n", executable=True)
        self.write("whisper", b"#!/bin/sh\nexit 98\n", executable=True)
        self.write("coordinator", ("#!" + sys.executable + "\n" + FAKE_NATIVE).encode(), executable=True)
        self.write("profile.json", b'{"schema_version":"1.0"}\n')
        models = []
        for identifier in ("f16", "q4", "q5")[:model_count]:
            self.write(identifier + ".bin", ("synthetic-" + identifier).encode())
            models.append(dict(id=identifier, path=str(root / (identifier + ".bin")), sha256=self.sha(identifier + ".bin"),
                               kind="pretrained" if identifier == "f16" else "compression", profiles=["matched"],
                               precision=identifier, checkpoint="synthetic"))
        for model in models[1:]:
            model.update(baseline_model_id="f16", baseline_model_sha256=models[0]["sha256"], intervention_id="synthetic-quantization")
        self.corpus = dict(schema_version="1.0", cases=[dict(id="en-src", language="en", audio=str(root / "audio.wav"),
                                                             sha256=self.sha("audio.wav"), source_channel=0, license="synthetic")])
        self.template = dict(schema_version="1.0", measurement_scope="resources_only", split="development", repetitions=1,
                             paths=["final"], language_modes=["auto"], threads=2, baseline_revision="a" * 40,
                             whisper_cli=str(root / "whisper"), models=models,
                             profiles=[dict(id="matched", kind="candidate", source_revision="b" * 40, settings=str(root / "profile.json"))])
        self.write_json("corpus.json", self.corpus); self.write_json("experiment.json", self.template)
        self.spec = dict(schema_version="controlled-panel-spec-v1", model_ids=[m["id"] for m in models], language_modes=["auto"],
                         deadline_utc=(panel.utcnow() + timedelta(seconds=120)).isoformat(), max_seconds=seconds, block_timeout_seconds=10)
        for name, file in (("corpus", "corpus.json"), ("experiment", "experiment.json"), ("coordinator", "coordinator"),
                           ("transcriber", "transcriber"), ("whisper", "whisper")):
            self.spec[name] = dict(path=str(root / file), sha256=self.sha(file))

    def write(self, name, raw, executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        if executable:
            path.chmod(0o700)

    def write_json(self, name, value):
        self.write(name, (json.dumps(value) + "\n").encode())

    def sha(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def plan(self):
        # A separately retained, native-style unmeasured full grid binds the
        # decoded profile fingerprint; it deliberately differs from raw bytes.
        self.prepare_native_grid()
        self.write_json("spec.json", self.spec)
        self.plan_data, self.plan_sha = panel.make_plan(self.root / "spec.json", self.root / "plan")
        self.write_json("admission.json", dict(schema_version="controlled-panel-admission-v1", plan_sha256=self.plan_sha,
                        capture_inactive=True, live_transcription_off=True, quiet_workload=True, power_stable=True, thermal_nominal=True,
                        native_checked_utc=panel.utcnow().isoformat(), workload_attestation="Model-free synthetic test; no audio capture or ASR"))
        return self.plan_data

    def prepare_native_grid(self):
        rows = []
        profile = self.template["profiles"][0]
        effective = hashlib.sha256(b"synthetic native serialization, distinct from raw profile bytes").hexdigest()
        for model in self.template["models"]:
            for case in self.corpus["cases"]:
                for mode in self.template["language_modes"]:
                    rows.append(dict(id=case["id"], language=case["language"], task=case.get("task"), source_channel=case.get("source_channel"),
                        model=model["id"], model_sha256=model["sha256"], model_kind=model["kind"],
                        baseline_model_id=model.get("baseline_model_id", model["id"]), baseline_model_sha256=model.get("baseline_model_sha256", model["sha256"]),
                        intervention_id=model.get("intervention_id"), precision=model["precision"], checkpoint=model["checkpoint"],
                        profile=profile["id"], profile_kind=profile["kind"], profile_sha256=self.sha("profile.json"),
                        effective_profile_sha256=effective, vad_model_sha256=None, runtime_settings_sha256=effective,
                        whisper_binary_sha256=self.sha("whisper"), transcription_runner_sha256=self.sha("transcriber"), threads=self.template["threads"],
                        preparation_policy="synthetic-preparation-v1", baseline_runner_sha256=None, source_revision=profile["source_revision"],
                        language_mode=mode, path="final", repeat=1, source_sha256=case["sha256"], reference_sha256=None,
                        measurement_scope="resources_only", scoring_policy="unscored-resources-v1", status="ready", gaps=[], errors=[]))
        matrix = dict(schema_version="1.0", dry_run=True, serial_jobs=True, split="development", rows=rows,
                      configuration_sha256=self.sha("experiment.json"), corpus_sha256=self.sha("corpus.json"),
                      runner_sha256=self.sha("transcriber"), coordinator_sha256=self.sha("coordinator"), whisper_binary_sha256=self.sha("whisper"),
                      measurement_scope="resources_only", threads=self.template["threads"], profile_sha256={profile["id"]: self.sha("profile.json")})
        for source, target in (("experiment.json", "experiment.original.json"), ("corpus.json", "corpus.original.json"), ("profile.json", "profile-matched.json")):
            self.write("native-dry/" + target, (self.root / source).read_bytes())
        self.write_json("native-dry/matrix.json", matrix)
        self.spec["expected_native_matrix"] = dict(path=str(self.root / "native-dry/matrix.json"), sha256=self.sha("native-dry/matrix.json"))

    def command(self, output="run"):
        return [sys.executable, str(SOURCE), "run", "--plan", str(self.root / "plan/plan.json"), "--plan-sha256", self.plan_sha,
                "--admission", str(self.root / "admission.json"), "--admission-sha256", self.sha("admission.json"), "--output", str(self.root / output)]

    def run(self, mode="", output="run"):
        return subprocess.run(self.command(output), start_new_session=True, capture_output=True, text=True, timeout=20,
                              env=dict(os.environ, PANEL_SYNTHETIC_NATIVE_MODE=mode))

    def collect(self, output="report", guard=None):
        return panel.collect(self.root / "plan/plan.json", self.plan_sha, self.root / "run", self.sha("run/state.json"),
                             self.root / output, guard, panel.hash_file(guard)[0] if guard else None)


class ControlledPanelTests(unittest.TestCase):
    def fixture(self, **kwargs):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return Fixture(Path(temporary.name).resolve(), **kwargs)

    def test_two_model_schedule_is_balanced_without_renaming_sources_or_native_repeats(self):
        f = self.fixture(); plan = f.plan()
        self.assertEqual([b["model_order"] for b in plan["blocks"]], [["f16", "q4"], ["q4", "f16"], ["q4", "f16"], ["f16", "q4"]])
        self.assertEqual(plan["planned_native_calls"], 8)
        self.assertEqual(plan["unique_source_cases"], 1)
        for block in plan["blocks"]:
            _, corpus = panel.raw_json(block["corpus"]["path"])
            _, config = panel.raw_json(block["experiment"]["path"])
            self.assertEqual(corpus["cases"][0]["id"], "en-src")
            self.assertEqual(config["repetitions"], 1)
            self.assertEqual(config["measurement_scope"], "resources_only")

    def test_three_model_schedule_has_every_permutation_and_position_twice(self):
        f = self.fixture(model_count=3); plan = f.plan()
        orders = [tuple(b["model_order"]) for b in plan["blocks"]]
        self.assertEqual(len(set(orders)), 6)
        for model in plan["model_ids"]:
            for position in range(3):
                self.assertEqual(sum(order[position] == model for order in orders), 2)
        self.assertEqual(plan["planned_native_calls"], 18)

    def test_plan_rejects_missing_hash_changed_input_scope_or_time_bound(self):
        for problem in ("hash", "scope", "budget", "repeat"):
            f = self.fixture()
            if problem == "hash": f.spec["coordinator"]["sha256"] = None
            if problem == "budget": f.spec["max_seconds"] = 3601
            if problem in ("scope", "repeat"):
                f.template["measurement_scope" if problem == "scope" else "repetitions"] = "quality_and_resources" if problem == "scope" else 3
                f.write_json("experiment.json", f.template); f.spec["experiment"]["sha256"] = f.sha("experiment.json")
            f.write_json("spec.json", f.spec)
            with self.subTest(problem=problem), self.assertRaises((ValueError, TypeError)):
                panel.make_plan(f.root / "spec.json", f.root / "plan")

    def test_metadata_duplicate_keys_size_and_case_limit_are_bounded(self):
        f = self.fixture()
        with self.assertRaises(ValueError): panel.decode(b'{"same":1,"same":2}')
        f.write("too-big.json", b" " * (panel.MAX_JSON_BYTES + 1))
        with self.assertRaises(ValueError): panel.raw_json(f.root / "too-big.json")
        f.corpus["cases"] = [dict(f.corpus["cases"][0], id="case-" + str(i)) for i in range(panel.MAX_CASES + 1)]
        f.write_json("corpus.json", f.corpus); f.spec["corpus"]["sha256"] = f.sha("corpus.json")
        f.write_json("spec.json", f.spec)
        with self.assertRaises(ValueError): panel.make_plan(f.root / "spec.json", f.root / "plan")

    def test_deadline_clamps_delayed_start_and_backward_clock_jump(self):
        f = self.fixture(); plan = f.plan()
        deadline = panel.timestamp(plan["deadline_utc"])
        self.assertEqual(panel.remaining_seconds(plan, deadline - timedelta(seconds=2), 10, 15), 2)
        self.assertEqual(panel.remaining_seconds(plan, deadline - timedelta(hours=2), 10, 15), 5)
        self.assertLessEqual(panel.remaining_seconds(plan, deadline + timedelta(seconds=1), 10, 15), 0)

    def test_admission_must_bind_plan_and_fresh_native_quiet_conditions(self):
        f = self.fixture(); f.plan()
        _, admission = panel.raw_json(f.root / "admission.json")
        for change in (dict(plan_sha256="0" * 64), dict(native_checked_utc=(panel.utcnow() - timedelta(minutes=6)).isoformat()),
                       dict(capture_inactive=False), dict(live_transcription_off=False), dict(quiet_workload=False)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                panel.validate_admission(dict(admission, **change), f.plan_sha, panel.utcnow())

    def test_success_collects_only_resource_pairs_and_never_approves_missing_guard(self):
        f = self.fixture(); f.plan(); result = f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = f.collect()
        self.assertEqual(report["measured_invocations"], 8)
        self.assertEqual(report["missing_pairs"], 0)
        self.assertEqual(report["unique_source_cases"], 1)
        self.assertIsNone(report["independent_speaker_units"])
        self.assertEqual(report["quality_sample_size"], 0)
        self.assertFalse(report["quality_approval"])
        self.assertFalse(report["controlled_observed_conditions"])
        self.assertTrue(all(p["wall_ratio"] == .8 and p["peak_rss_ratio"] == .6 for p in report["pairs"]))
        self.assertEqual(report["source_comparison_summaries"][0]["completely_paired_source_cases"], 1)
        self.assertEqual(report["source_comparison_summaries"][0]["source_median_wall_ratio"]["count"], 1)
        self.assertEqual(report["cohorts"][0]["upstream_load_seconds_per_native_invocation"]["median"], .1)
        self.assertIsNone(report["first_result_latency_seconds"])
        self.assertIsNone(report["total_initialization_seconds"])
        self.assertIsNone(report["total_unified_gpu_memory_bytes"])
        self.assertTrue(all(v["round_id"] in (1, 2, 3, 4) and v["case_id"] == "en-src" for v in report["measurements"]))
        with self.assertRaises(FileExistsError): f.collect()

    def test_exact_guard_proof_is_required_and_relaxed_cpu_policy_does_not_pass(self):
        f = self.fixture(); f.plan(); result = f.run(); self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((f.root / "run/state.json").read_text())
        rows = [dict(event="starting", command=f.command(), foreign_cpu_limit=50, poll_seconds=1),
                dict(event="started", child_nice=10, pid=state["controller_pid"], owned_session=state["owned_session"]), dict(event="finished", reason=None, failure=None,
                     shutdown=dict(cli_reaped=True, owned_session_present=False, shutdown_errors=[], returncode=0))]
        f.write("guard.jsonl", b"".join((json.dumps(r) + "\n").encode() for r in rows))
        report = f.collect(guard=f.root / "guard.jsonl")
        self.assertTrue(report["controlled_observed_conditions"])
        self.assertFalse(report["guard"]["gpu_idle_measured"])
        rows[0]["foreign_cpu_limit"] = 1000
        f.write("guard-relaxed.jsonl", b"".join((json.dumps(r) + "\n").encode() for r in rows))
        report = f.collect("relaxed", f.root / "guard-relaxed.jsonl")
        self.assertFalse(report["controlled_observed_conditions"])

    def test_changed_model_fails_before_launch_and_single_use_plan_cannot_restart(self):
        f = self.fixture(); f.plan(); f.write("q4.bin", b"changed")
        result = f.run()
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual(state["status"], "failed")
        self.assertTrue(all(b["status"] == "queued" for b in state["blocks"]))
        self.assertFalse((f.root / "run/launched.jsonl").exists())
        f.write("q4.bin", b"synthetic-q4")
        result = f.run(output="second-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((f.root / "second-run/launched.jsonl").exists())

    def test_failed_native_block_is_retained_and_never_retried_or_zero_scored(self):
        f = self.fixture(); f.plan(); result = f.run("fail")
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual([b["status"] for b in state["blocks"]], ["failed", "queued", "queued", "queued"])
        self.assertEqual(len((f.root / "run/launched.jsonl").read_text().splitlines()), 1)
        self.assertTrue(state["blocks"][0]["shutdown"]["child_reaped"])
        report = f.collect()
        self.assertEqual(report["missing_pairs"], 4)
        self.assertEqual(report["measured_invocations"], 0)
        self.assertTrue(all(p["wall_ratio"] is None for p in report["pairs"]))

    def test_budget_exhaustion_cancels_and_reaps_the_owned_worker(self):
        f = self.fixture(seconds=1); f.plan(); result = f.run("hang")
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual(state["status"], "deadline_exhausted")
        self.assertEqual(state["blocks"][0]["status"], "deadline_exhausted")
        self.assertTrue(state["blocks"][0]["shutdown"]["child_reaped"])
        self.assertFalse(state["blocks"][0]["shutdown"]["owned_workers_present"])
        self.assertEqual(state["fixed_deadline_utc"], f.plan_data["deadline_utc"])

    def test_signal_forwards_cancel_and_reaps_separate_owned_descendant_group(self):
        f = self.fixture(); f.plan()
        child = subprocess.Popen(f.command(), start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, env=dict(os.environ, PANEL_SYNTHETIC_NATIVE_MODE="hang"))
        try:
            deadline = time.monotonic() + 10
            while not (f.root / "run/descendant.pid").exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    self.fail("Synthetic owned descendant did not start")
                time.sleep(.02)
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=10)
            state = json.loads((f.root / "run/state.json").read_text())
            self.assertEqual(state["status"], "cancelled")
            self.assertTrue((f.root / "run/block-0000/cancel.request").exists())
            self.assertTrue(state["blocks"][0]["shutdown"]["child_reaped"])
            self.assertFalse(state["blocks"][0]["shutdown"]["owned_workers_present"])
            self.assertEqual(len((f.root / "run/launched.jsonl").read_text().splitlines()), 1)
        finally:
            if child.poll() is None:
                child.kill(); child.wait(timeout=5)

    def test_missing_rss_stays_missing_and_cannot_qualify_controlled_pairs(self):
        f = self.fixture(); f.plan(); result = f.run("missing-rss")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = f.collect()
        self.assertEqual(report["measured_invocations"], 4)
        self.assertEqual(report["missing_pairs"], 4)
        self.assertFalse(report["complete_pairs"])
        self.assertEqual(report["source_comparison_summaries"][0]["completely_paired_source_cases"], 0)

    def test_expired_absolute_deadline_cannot_start_a_delayed_run(self):
        f = self.fixture(); f.plan()
        delayed = panel.timestamp(f.plan_data["deadline_utc"]) + timedelta(seconds=1)
        with mock.patch.object(panel, "utcnow", return_value=delayed), self.assertRaises(TimeoutError):
            panel.execute(f.root / "plan/plan.json", f.plan_sha, f.root / "admission.json", f.sha("admission.json"), f.root / "run")
        self.assertFalse((f.root / "run").exists())

    def test_additional_dependency_hash_is_locked_and_alias_sources_are_rejected(self):
        f = self.fixture(); f.write("dependency.bin", b"synthetic native dependency")
        f.spec["additional_inputs"] = [dict(path=str(f.root / "dependency.bin"), sha256=f.sha("dependency.bin"))]
        f.plan(); f.write("dependency.bin", b"changed dependency")
        result = f.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((f.root / "run/launched.jsonl").exists())
        g = self.fixture()
        g.corpus["cases"].append(dict(g.corpus["cases"][0], id="alias"))
        g.write_json("corpus.json", g.corpus); g.spec["corpus"]["sha256"] = g.sha("corpus.json")
        g.write_json("spec.json", g.spec)
        with self.assertRaises(ValueError): panel.make_plan(g.root / "spec.json", g.root / "plan")

    def test_collector_rejects_tampered_state_matrix_and_scored_measurements(self):
        f = self.fixture(); f.plan(); result = f.run(); self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(ValueError):
            panel.collect(f.root / "plan/plan.json", f.plan_sha, f.root / "run", "0" * 64, f.root / "bad-state")
        state_path = f.root / "run/state.json"; matrix_path = f.root / "run/block-0000/matrix.json"
        original_state, original_matrix = state_path.read_bytes(), matrix_path.read_bytes()
        state, matrix = json.loads(original_state), json.loads(original_matrix)
        for change in ("config", "source", "scorer", "repeat", "order", "profile", "runtime"):
            current, changed = copy.deepcopy(state), copy.deepcopy(matrix)
            if change == "config": changed["configuration_sha256"] = "0" * 64
            if change == "source": changed["rows"][0]["source_sha256"] = "0" * 64
            if change == "scorer": changed["rows"][0]["measurement"]["scoring_version"] = "a-quality-score"
            if change == "repeat": changed["rows"][0]["repeat"] = 2
            if change == "order": changed["rows"].reverse()
            if change == "profile": changed["profile_sha256"]["matched"] = "0" * 64
            if change == "runtime": changed["rows"][0]["runtime_settings_sha256"] = "0" * 64
            matrix_path.write_text(json.dumps(changed)); current["blocks"][0]["matrix_sha256"] = panel.hash_file(matrix_path)[0]
            state_path.write_text(json.dumps(current))
            with self.subTest(change=change), self.assertRaises(ValueError): f.collect("bad-" + change)
        state_path.write_bytes(original_state); matrix_path.write_bytes(original_matrix)

    def test_native_dry_grid_is_required_complete_unmeasured_and_hash_bound(self):
        for problem in ("missing", "header", "measurement", "grid", "source", "profile", "model", "snapshot"):
            f = self.fixture(); f.prepare_native_grid()
            path = f.root / "native-dry/matrix.json"
            matrix = json.loads(path.read_text())
            if problem == "missing": del f.spec["expected_native_matrix"]
            if problem == "header": matrix["runner_sha256"] = "0" * 64
            if problem == "measurement": matrix["rows"][0]["measurement"] = {"wall_seconds": 1}
            if problem == "grid": matrix["rows"].append(copy.deepcopy(matrix["rows"][0]))
            if problem == "source": matrix["rows"][0]["source_channel"] = 1
            if problem == "profile": matrix["rows"][0]["profile_kind"] = "baseline"
            if problem == "model": matrix["rows"][0]["model_sha256"] = "0" * 64
            if problem == "snapshot": f.write("native-dry/experiment.original.json", b"changed")
            if problem not in ("missing", "snapshot"):
                f.write_json("native-dry/matrix.json", matrix)
                f.spec["expected_native_matrix"]["sha256"] = f.sha("native-dry/matrix.json")
            f.write_json("spec.json", f.spec)
            with self.subTest(problem=problem), self.assertRaises(ValueError):
                panel.make_plan(f.root / "spec.json", f.root / "plan")

    def test_resource_split_groups_and_decoded_profile_identity_are_retained(self):
        f = self.fixture()
        f.corpus["cases"][0].update(split="resource", task="transcription", source_group_ids=["meeting-1"], speaker_ids=[])
        f.write_json("corpus.json", f.corpus); f.spec["corpus"]["sha256"] = f.sha("corpus.json")
        plan = f.plan()
        self.assertEqual(plan["source_groups"][0]["source_group_ids"], ["meeting-1"])
        self.assertNotEqual(plan["expected_native_rows"][0]["effective_profile_sha256"], f.sha("profile.json"))
        self.assertEqual(plan["execution_claim_path"], str(f.root / "plan/execution.claim.json"))
        result = f.run(); self.assertEqual(result.returncode, 0, result.stderr)
        report = f.collect()
        self.assertEqual(report["source_groups"][0]["source_group_ids"], ["meeting-1"])
        self.assertIn("not continuous", report["thermal_observation_scope"])

    def test_copying_exact_frozen_plan_cannot_reset_single_use_claim(self):
        f = self.fixture(); f.plan(); result = f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        f.write("copied/plan.json", (f.root / "plan/plan.json").read_bytes())
        command = f.command("copy-run")
        command[command.index("--plan") + 1] = str(f.root / "copied/plan.json")
        result = subprocess.run(command, start_new_session=True, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((f.root / "copy-run/launched.jsonl").exists())
        self.assertFalse((f.root / "copied/execution.claim.json").exists())
        self.assertEqual(json.loads((f.root / "plan/execution.claim.json").read_text())["output"], str(f.root / "run"))

    def test_coherently_wrong_runtime_is_rejected_against_native_unmeasured_grid(self):
        f = self.fixture(); f.plan(); result = f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        state_path = f.root / "run/state.json"
        state = json.loads(state_path.read_text())
        for current in state["blocks"]:
            matrix_path = f.root / "run" / current["id"] / "matrix.json"
            matrix = json.loads(matrix_path.read_text())
            for row in matrix["rows"]:
                row["runtime_settings_sha256"] = row["effective_profile_sha256"] = "0" * 64
                row["measurement"]["engine_passes"][0]["decoding"]["profile_sha256"] = "0" * 64
                report_path = matrix_path.parent / row["evidence_directory"] / "results.json"
                report_path.write_text(json.dumps(dict(runner_sha256=f.sha("transcriber"), results=[row["measurement"]])))
            matrix_path.write_text(json.dumps(matrix)); current["matrix_sha256"] = panel.hash_file(matrix_path)[0]
        state_path.write_text(json.dumps(state))
        with self.assertRaisesRegex(ValueError, "frozen unmeasured native grid"):
            f.collect("coherent-wrong-runtime")

    def test_reported_channel_language_task_runner_and_actual_engine_identity_are_checked(self):
        f = self.fixture(); f.plan(); result = f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        state_path = f.root / "run/state.json"; matrix_path = f.root / "run/block-0000/matrix.json"
        original_state, original_matrix = state_path.read_bytes(), matrix_path.read_bytes()
        for field, value in (("source_channel", 1), ("language", "zh"), ("task", "standard_rendering"),
                             ("runner_sha256", "0" * 64), ("engine_identity_observations", 0),
                             ("empty-passes", []), ("model-pass", "0" * 64), ("profile-pass", "0" * 64)):
            state, matrix = json.loads(original_state), json.loads(original_matrix)
            row = matrix["rows"][0]
            if field == "empty-passes": row["measurement"]["engine_passes"] = value
            elif field == "model-pass": row["measurement"]["engine_passes"][0]["model_sha256"] = value
            elif field == "profile-pass": row["measurement"]["engine_passes"][0]["decoding"]["profile_sha256"] = value
            else: row[field] = value
            # Keep the retained case report consistent so rejection proves the
            # effective identity contract, rather than a trivial JSON mismatch.
            report_path = matrix_path.parent / row["evidence_directory"] / "results.json"
            report_path.write_text(json.dumps(dict(runner_sha256=f.sha("transcriber"), results=[row["measurement"]])))
            matrix_path.write_text(json.dumps(matrix)); state["blocks"][0]["matrix_sha256"] = panel.hash_file(matrix_path)[0]
            state_path.write_text(json.dumps(state))
            with self.subTest(field=field), self.assertRaises(ValueError): f.collect("wrong-" + field)
        state_path.write_bytes(original_state); matrix_path.write_bytes(original_matrix)

    def test_guard_proof_must_bind_exact_admission_hash_and_path(self):
        f = self.fixture(); f.plan(); result = f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((f.root / "run/state.json").read_text())
        for field, value in (("--admission-sha256", "0" * 64), ("--admission", str(f.root / "different.json"))):
            command = f.command(); command[command.index(field) + 1] = value
            rows = [dict(event="starting", command=command, foreign_cpu_limit=50, poll_seconds=1),
                    dict(event="started", child_nice=10, pid=state["controller_pid"], owned_session=state["owned_session"]),
                    dict(event="finished", reason=None, failure=None,
                         shutdown=dict(cli_reaped=True, owned_session_present=False, shutdown_errors=[], returncode=0))]
            name = "wrong-guard-" + field[2:]
            f.write(name + ".jsonl", b"".join((json.dumps(row) + "\n").encode() for row in rows))
            report = f.collect(name, f.root / (name + ".jsonl"))
            self.assertFalse(report["controlled_observed_conditions"])


if __name__ == "__main__":
    unittest.main()
