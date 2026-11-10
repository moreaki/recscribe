#!/usr/bin/env python3
"""Offline synthetic contracts: no native/models/corpus inputs are opened."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

R = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, R / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


seal = load("test_round5_sealer", "seal-heldout.py")
serial = load("test_round5_serial", "run-remaining.py")


def digest(raw): return hashlib.sha256(raw).hexdigest()


class Fixture:
    def __init__(self, root):
        self.root = Path(root).resolve(); self.pins = {}
        def file(name, raw):
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True)
            if not isinstance(raw, bytes): raw = (json.dumps(raw, allow_nan=False) + "\n").encode()
            path.write_bytes(raw); value = {"path": str(path), "sha256": digest(raw)}
            self.pins[str(path)] = {**value, "kind": "synthetic"}
            return value
        self.file = file
        archive="quality/scripts/quality/"
        public=Path(os.environ.get("RECSCRIBE_SOURCE_ROOT",str(Path.cwd())))/"scripts/quality"
        tools={name:file(archive+filename,(public/filename).read_bytes()) for name,filename in
            (("reporter","report-pilot.py"),("assessor","assess-mlp-permutation.py"),("affine_helpers","assess-affine-pilot.py"),("ggml_parser","ggml_weights.py"))}
        for name,filename in (("coordinator","run-remaining.py"),("sealer","seal-heldout.py")):
            tools[name]=file(filename,(R/filename).read_bytes())
        r3=R.parent/"round-3"
        tools["guard"]=file("run-guard.py",(r3/"attempted-v1/run-guard.py").read_bytes())
        tools["failure_classifier"]=file("classify-native-output-failure-v2.py",(r3/"classify-native-output-failure-v2.py").read_bytes())
        file(archive+"mlp-permute.py",(public/"mlp-permute.py").read_bytes())
        quantizer=file("native/whisper-quantize",b"synthetic quantizer")
        permutation={"version":"whisper-mlp-permutation-v1","recipe_sha256":seal.RECIPE_SHA}
        quantization={"format":"q4_0","ftype":2,"quantizer_sha256":quantizer["sha256"]}
        runner = {**file("runner", b"runner"), "source_revision": "a" * 40}
        baseline = {**file("baseline", b"baseline"), "source_revision": "b" * 40}
        profile = {**file("profile.json", {}), "id": "current-defaults", "settings_sha256": "c" * 64}
        runtime = file("runtime.json", {"runner_sha256":runner["sha256"],"files":[]})
        natives = [file("native/whisper-cli" if i == 0 else "native/lib" + str(i), ("native" + str(i)).encode()) for i in range(11)]
        runtime = file("runtime.json", {"runner_sha256":runner["sha256"],"files":natives})
        models = []; arms_by_model = {}
        kinds = {"original": "pretrained", "permuted_f16": "conversion_control", "plain_q4": "compression", "permuted_q4": "combined"}
        for family in seal.MODELS:
            arms = {}
            for role, kind in (kinds.items() if family in {"small","large-v3-turbo"} else [("original", "pretrained")]):
                identifier = family if role == "original" else family + "-" + role.replace('_','-')
                raw = (("model " + identifier).encode() * 1000)[:350 if role in {"plain_q4","permuted_q4"} else 1000]
                value = {**file("models/" + identifier, raw), "id": identifier, "kind": kind, "model_file_bytes": len(raw),
                         "parent_original_id": family, "parent_original_sha256": arms.get("original", {}).get("sha256", digest(raw))}
                models.append(value); arms[role] = value
            arms_by_model[family] = arms
        self.family = {"schema_version": "mlp-permutation-family-pre-inference-v1", "planned_cells":4554,
            "planned_native_parent_pairs":2484, "planned_assessor_derived_q4_pairs":828,
            "planned_reference_runtime_placeholders":1242,"paths":seal.campaign_paths(self.root),"permutation":permutation,"quantization":quantization,"quantizer":quantizer,
            "promotion_authorized":False, "fresh_heldout_reference_content_inspected":False,
            "native_v2_grouping_approval":False, "controlled_resources":"NOT EVALUATED", "budgets":{"fixed":True},
            "tools":tools, "runner":runner, "baseline_control":baseline, "profile":profile,
            "runtime_record":runtime, "native_files":natives, "models":models, "stages":[]}
        for stage, prefix, count, modes, repetitions in seal.STAGE_RULES:
            cases = []; corpus_cases = []
            for index in range(count):
                language = seal.LANGUAGES[index % 9]; identifier = prefix + "-case-" + str(index)
                audio = file("data/" + identifier + ".wav", ("audio " + identifier).encode())
                reference = file("data/" + identifier + ".txt", ("reference " + identifier).encode())
                case = {"id":identifier, "source_id":"source-" + identifier, "language":language,
                    "task":"standard_rendering" if language == "de-CH" else "transcription", "source_channel":0,
                    "source_sha256":audio["sha256"], "reference_sha256":reference["sha256"], "code_switches":[]}
                cases.append(case)
                corpus_cases.append({**case, "audio":audio["path"], "reference":reference["path"], "sha256":audio["sha256"],
                    "scoring_policy":"swift-nfc-casefold-alphanumeric-v1", "reviewed":False,
                    "split":"held_out" if stage == "held_out" else "development"})
            for family in seal.MODELS:
                identifier = prefix + "-" + family; folder = self.root / identifier
                arms = arms_by_model[family]; kind = "family" if len(arms) == 4 else "reference"
                comparisons = {role:family + "-" + role.replace('_','-') + "-vs-original" for role in arms if role != "original"}
                corpus = file(identifier + "/corpus.original.json", {"schema_version":"1.0", "cases":corpus_cases,
                    "frozen":stage == "held_out", "native_review_status":"UNRESOLVED", "reference_content_inspected":False})
                config_models = []
                for role, value in arms.items():
                    model = {key:value[key] for key in ("id", "path", "sha256", "kind")}
                    if role != "original": model.update(baseline_model_id=family, baseline_model_sha256=arms["original"]["sha256"], intervention_id=value["id"])
                    config_models.append(model)
                freeze_path = str(folder / "freeze.json") if stage == "held_out" else None
                config = file(identifier + "/experiment.json", {"schema_version":"1.0", "split":"held_out" if stage == "held_out" else "development",
                    "threads":2, "repetitions":repetitions, "language_modes":modes, "paths":["final"], "freeze":freeze_path,
                    "capture_inactive":True, "baseline_revision":baseline["source_revision"], "baseline_cli":baseline["path"], "baseline_cli_sha256":baseline["sha256"],
                    "whisper_cli":natives[0]["path"], "models":config_models,
                    "profiles":[{"id":"current-defaults", "kind":"candidate", "source_revision":runner["source_revision"], "settings":profile["path"]}],
                    "comparisons":[{"id":cid, "intervention":kinds[role], "baseline_model_id":family,
                        "candidate_model_id":arms[role]["id"], "baseline_profile_id":"current-defaults", "candidate_profile_id":"current-defaults"}
                        for role, cid in comparisons.items()]})
                partition = {"id":family, "kind":kind}
                simple_arms = {role:{key:value[key] for key in ("id", "sha256", "model_file_bytes")} for role, value in arms.items()}
                if kind == "family": partition.update(arms=simple_arms, comparison_ids=comparisons)
                else: partition["model"] = simple_arms["original"]
                plan = file(identifier + "/assessment-plan.pre-freeze.json", {"schema_version":"mlp-permutation-assessment-plan-v1",
                    "permutation":permutation,"quantization":quantization,
                    "stage":stage, "split":"held_out" if stage == "held_out" else "development", "repetitions":repetitions,
                    "language_modes":modes, "cases":cases, "partition":partition, "runtime_record":runtime,
                    "execution":{"runner_sha256":runner["sha256"], "profile_sha256":profile["sha256"], "runtime_settings_sha256":profile["settings_sha256"],
                        "profile_id":"current-defaults", "threads":2, "vad_model_sha256":None, "corpus_sha256":corpus["sha256"],
                        "configuration_sha256":config["sha256"], "whisper_binary_sha256":natives[0]["sha256"]}})
                snapshot = file(identifier + "/source.original.json", {})
                multiplier = count * len(modes) * repetitions
                self.family["stages"].append({"paths":seal.stage_paths(self.root,identifier,stage=="held_out"),"id":identifier, "stage":stage, "partition_id":family, "partition_kind":kind,
                    "corpus":corpus["path"], "corpus_sha256":corpus["sha256"], "configuration":config["path"], "configuration_sha256":config["sha256"],
                    "assessment_pre_freeze_plan":plan["path"], "assessment_pre_freeze_plan_sha256":plan["sha256"],
                    "source_snapshot":snapshot["path"], "source_snapshot_sha256":snapshot["sha256"], "models":[a["id"] for a in arms.values()],
                    "language_modes":modes, "repetitions":repetitions, "planned_cells":multiplier*len(arms),
                    "planned_native_parent_pairs":multiplier*len(comparisons), "planned_assessor_derived_q4_pairs":multiplier if kind == "family" else 0,
                    "runtime_reference_placeholders_planned":multiplier if kind=="reference" else 0,
                    "guard_timeout_seconds":10800 if stage=="held_out" else 3600, "freeze":freeze_path})
        self.publish()

    def publish(self):
        self.family["immutable_files"] = list(self.pins.values())
        path = self.root / "pre-inference-family-seal.json"
        raw = (json.dumps(self.family, allow_nan=False) + "\n").encode(); path.write_bytes(raw)
        self.path = path; self.sha = digest(raw)

    def verified(self, check=lambda: None):
        family = seal.Family(self.path,self.sha,check)
        d=self.file("native-idle.json",{"schema_version":"round5-native-idle-attestation-v1","recording_active":False,"live_transcription_active":False,"inspection_method":"native-ui","inspected_utc":"2026-11-07T16:00:00+00:00","app_path":"/Applications/RecScribe.app","bundle_identifier":"synthetic.bundle"})
        family.bind_initial_attestation(d);family.verify_all();return family


class MetadataContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.fixture = Fixture(self.temp.name)

    def test_complete_fixed_preflight_then_changed_model_fails(self):
        family = self.fixture.verified()
        self.assertEqual(len(family.value["stages"]), 15)
        self.assertEqual(set(family.plans), {s["id"] for s in family.value["stages"]})
        self.assertTrue(all(family.plans[s["id"]]["partition"]["id"] == s["partition_id"] for s in family.value["stages"]))
        Path(family.value["models"][0]["path"]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "identity changed"): family.verify_step()
        with self.assertRaisesRegex(ValueError, "input changed"): family.verify_all()

    def test_preplan_vs_actual_config_lineage_preflight(self):
        stage = self.fixture.family["stages"][2]; path = Path(stage["configuration"])
        value = json.loads(path.read_text()); value["models"][1]["baseline_model_id"] = "foreign"
        desc = self.fixture.file(str(path.relative_to(self.fixture.root)), value)
        stage["configuration_sha256"] = desc["sha256"]
        plan_path = Path(stage["assessment_pre_freeze_plan"]); plan = json.loads(plan_path.read_text())
        plan["execution"]["configuration_sha256"] = desc["sha256"]
        stage["assessment_pre_freeze_plan_sha256"] = self.fixture.file(str(plan_path.relative_to(self.fixture.root)), plan)["sha256"]
        self.fixture.publish()
        with self.assertRaisesRegex(ValueError, "adaptation lineage"): self.fixture.verified()

    def test_missing_native_inventory_fails(self):
        self.fixture.family["native_files"].pop(); self.fixture.publish()
        with self.assertRaisesRegex(ValueError, "eleven-file"): self.fixture.verified()

    def test_missing_separate_quantizer_pin_is_rejected(self):
        self.fixture.family.pop('quantizer'); self.fixture.publish()
        with self.assertRaisesRegex(ValueError,'descriptor'): self.fixture.verified()

    def test_preparation_is_not_native_idle_admission(self):
        family=seal.Family(self.fixture.path,self.fixture.sha); family.verify_all()
        family.stage_evidence=self.history
        with self.assertRaisesRegex(ValueError,'idle attestation'): seal.seal(family,self.fixture.root/'heldout-family.freeze.json')
        self.assertFalse((self.fixture.root/'heldout-family.freeze.json').exists())
        d=self.fixture.file('active.json',{'schema_version':'round5-native-idle-attestation-v1','recording_active':True,
            'live_transcription_active':False,'inspection_method':'native-ui','inspected_utc':'2026-11-07T16:00:00Z',
            'app_path':'/Applications/RecScribe.app','bundle_identifier':'synthetic.bundle'})
        with self.assertRaisesRegex(ValueError,'idle/live-off'): family.bind_initial_attestation(d)

    def test_deadlines_are_prospective_stage_specific_and_not_quality_gates(self):
        self.fixture.family['stages'][0]['guard_timeout_seconds']=10800;self.fixture.publish()
        with self.assertRaisesRegex(ValueError,'grid/bound'): self.fixture.verified()

    def test_sources_mutated_after_freeze_rejected_before_launch(self):
        family = self.fixture.verified()
        Path(family.value["stages"][0]["corpus"]).write_bytes(b"{}")
        with self.assertRaisesRegex(ValueError, "identity changed"): family.verify_step()

    def test_nonfinite_json_exponent_rejected(self):
        path = self.fixture.root / "nonfinite.json"; path.write_bytes(b'{"x":1e999}')
        with self.assertRaisesRegex(ValueError, "Nonfinite"): seal.read(path)

    def test_classifier_filename_and_campaign_paths_are_bound_before_any_launch(self):
        stage=self.fixture.family['stages'][0]
        stage['paths']['classification_receipt']=str(self.fixture.root/stage['id']/'natural-failures.json')
        self.fixture.publish()
        with self.assertRaisesRegex(ValueError,'path-map'):self.fixture.verified()
        stage['paths']=seal.stage_paths(self.fixture.root,stage['id'],False)
        self.fixture.family['paths']['journal']=str(self.fixture.root/'alternate.events.jsonl');self.fixture.publish()
        with self.assertRaisesRegex(ValueError,'campaign paths'):self.fixture.verified()

    def test_sealed_path_map_contains_exact_writer_and_reader_locations(self):
        family=self.fixture.verified()
        for stage in family.value['stages']:
            paths=stage['paths']
            self.assertEqual(Path(paths['matrix_json']),Path(paths['matrix_directory'])/'matrix.json')
            self.assertEqual(Path(paths['classification_receipt']).name,'natural-failures.attempted-v2.json')
            self.assertEqual(Path(paths['assessment_json']).parent,Path(paths['assessment_directory']))
            self.assertEqual(Path(paths['report_json']).parent,Path(paths['report_directory']))
            self.assertEqual(stage['freeze'],paths['freeze'])

    def history(self, stage):
        return {"id":stage["id"],"planned_cells":stage["planned_cells"],"attempted_cells":stage["planned_cells"],"failed_cells":0, "decision":{"decision":"reject"},
            "completed_cells":stage["planned_cells"], "completed_native_parent_pairs":stage["planned_native_parent_pairs"],
            "completed_assessor_derived_q4_pairs":stage["planned_assessor_derived_q4_pairs"]}

    def test_tenth_stage_missing_blocks_every_heldout_freeze(self):
        family = self.fixture.verified(); seen = []
        def evidence(stage):
            seen.append(stage["id"])
            if len(seen) == 10: raise ValueError("synthetic incomplete tenth grid")
            return self.history(stage)
        family.stage_evidence = evidence
        with self.assertRaisesRegex(ValueError, "tenth grid"): seal.seal(family, self.fixture.root / "heldout-family.freeze.json")
        self.assertEqual(len(seen), 10)
        self.assertFalse(any(Path(s["freeze"]).exists() for s in family.value["stages"][10:]))

    def test_all_five_freezes_and_only_permitted_plan_links_despite_reject(self):
        family = self.fixture.verified(); seen = []
        def evidence(stage): seen.append(stage["id"]); return self.history(stage)
        family.stage_evidence = evidence
        digest_value, receipt = seal.seal(family, self.fixture.root / "heldout-family.freeze.json")
        self.assertEqual(len(seen), 10); self.assertEqual(len(receipt["partitions"]), 5)
        self.assertEqual(seal.sha(self.fixture.root / "heldout-family.freeze.json"), digest_value)
        for stage in family.value["stages"][10:]:
            binding = next(v for v in receipt["partitions"] if v["id"] == stage["id"])
            original = family.plans[stage["id"]]
            final, _ = seal.read(Path(stage["configuration"]).parent / "assessment-plan.final.json", binding["final_plan_sha256"])
            self.assertEqual(final["execution"].pop("freeze_sha256"), binding["freeze_sha256"])
            self.assertEqual(final.pop("pre_freeze_plan_sha256"), stage["assessment_pre_freeze_plan_sha256"])
            self.assertEqual(final.pop("pre_freeze_family_seal_sha256"), family.expected_sha)
            self.assertEqual(final, original)
            self.assertEqual(seal.sha(stage["assessment_pre_freeze_plan"]), stage["assessment_pre_freeze_plan_sha256"])

    def test_cancel_during_seal_retains_partial_without_global_release(self):
        family = self.fixture.verified(); family.stage_evidence = self.history
        first = Path(family.value["stages"][10]["freeze"])
        def check():
            if first.exists(): raise InterruptedError("synthetic cancellation")
        family.check = check
        with self.assertRaises(InterruptedError): seal.seal(family, self.fixture.root / "heldout-family.freeze.json")
        self.assertTrue(first.exists()); self.assertFalse((self.fixture.root / "heldout-family.freeze.json").exists())

    def test_any_heldout_outcome_prevents_family_seal(self):
        family = self.fixture.verified(); family.stage_evidence = self.history
        (Path(family.value["stages"][14]["configuration"]).parent / "matrix").mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"): seal.seal(family, self.fixture.root / "heldout-family.freeze.json")
        self.assertFalse(any(Path(s["freeze"]).exists() for s in family.value["stages"][10:]))


class CancellationContracts(unittest.TestCase):
    def coordinator(self, root):
        value = serial.Coordinator.__new__(serial.Coordinator)
        value.signal_requested = lambda: False; value.cancel = root / "cancel-serial.request"
        value.current = None; value.interrupted = False; value.journal = None
        value.family = mock.Mock(); value.note = mock.Mock()
        return value

    def test_cancel_in_popen_window_signals_and_reaps_owned_child(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); coordinator = self.coordinator(root)
            child = mock.Mock(pid=1234, returncode=130)
            child.poll.side_effect = [None, None] + [130] * 12
            def create(*args, **kwargs): coordinator.cancel.touch(); return child
            with mock.patch.object(serial.subprocess, "Popen", side_effect=create):
                with self.assertRaises(InterruptedError): coordinator.command(["synthetic"], "stage", "action", guarded=True)
            child.send_signal.assert_called_with(signal.SIGINT); child.wait.assert_called()
            child.terminate.assert_not_called(); child.kill.assert_not_called()

    def test_cancel_real_owned_guard_process_is_reaped(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); coordinator = self.coordinator(root)
            marker = root / "handled"
            program = "import pathlib,signal,time; signal.signal(signal.SIGINT,lambda *_:(pathlib.Path(" + repr(str(marker)) + ").touch(),exit(130))); time.sleep(30)"
            original_popen = serial.subprocess.Popen
            def create(*args, **kwargs):
                child = original_popen(*args, **kwargs)
                coordinator.cancel.touch()
                return child
            with mock.patch.object(serial.subprocess, "Popen", side_effect=create):
                with self.assertRaises(InterruptedError): coordinator.command([sys.executable, "-c", program], "stage", "action", guarded=True)
            self.assertIsNone(coordinator.current)

    def test_unreaped_guard_is_not_killed_or_reported_clean(self):
        with tempfile.TemporaryDirectory() as name:
            coordinator = self.coordinator(Path(name)); child = mock.Mock(pid=1234)
            child.poll.return_value = None; child.wait.side_effect = subprocess.TimeoutExpired("synthetic", 60)
            with self.assertRaisesRegex(RuntimeError, "cleanup"): coordinator.await_owned_child(child, True)
            child.send_signal.assert_called_with(signal.SIGINT)
            child.terminate.assert_not_called(); child.kill.assert_not_called()
            self.assertEqual(coordinator.note.call_args.args[0], "owned_guard_cleanup_pending")

    def test_all_five_plans_rechecked_before_any_held_launch(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);coordinator=self.coordinator(root)
            stages=[{'id':'heldout-'+str(i),'stage':'held_out'} for i in range(5)]
            coordinator.family.value={'stages':[{}]*10+stages}
            coordinator.heldout_bindings=lambda:{s['id']:{} for s in stages}
            visited=[]
            def verify(stage,_binding):
                visited.append(stage['id'])
                if len(visited)==5:raise ValueError('fifth held plan changed')
            coordinator.verify_heldout_plan=verify;coordinator.command=mock.Mock()
            with self.assertRaisesRegex(ValueError,'fifth held'):coordinator.stage_run(stages[0])
            self.assertEqual(visited,[s['id'] for s in stages]);coordinator.command.assert_not_called()

    def test_optimized_python_keeps_explicit_source_hash_gate(self):
        result = subprocess.run([sys.executable, "-O", str(R / "seal-heldout.py"), "--family-seal", "/does-not-exist",
            "--family-seal-sha256", "0"*64, "--expected-source-sha256", "0"*64, "--output","/does-not-exist","--initial-attestation","/does-not-exist","--initial-attestation-sha256","0"*64],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0); self.assertIn("source lock differs", result.stderr)


if __name__ == "__main__": unittest.main(verbosity=2)
