"""Model-free serial release/cancellation contracts for the quality campaign."""
from datetime import datetime, timezone, timedelta
import hashlib
import importlib.util
import json
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import Mock

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "benchmarks/quantized-quality/campaign-runner-v1.py"
SPEC = importlib.util.spec_from_file_location("quality_campaign", SOURCE)
campaign = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(campaign)


def fixture(root, stale=False, wrong_order=False):
    plans = root / "plans-v1"; plans.mkdir()
    profile = plans / "profile.json"; profile.write_text('{"schema_version":"1.0"}\n')
    now = datetime.now(timezone.utc) - timedelta(seconds=1000 if stale else 0)
    campaign.save(plans / "launch.admission.json", dict(created_utc=now.isoformat(), recording_inactive=True, live_off=True, user_no_recording=True))
    stages = []
    for name, split in (("dev-a", "development"), ("dev-b", "development"), ("held-a", "held_out"), ("held-b", "held_out")):
        config = plans / (name + ".planned.json")
        campaign.save(config, dict(capture_inactive=False, profiles=[dict(id="matched", settings=str(profile))]))
        stages.append(dict(id=name, split=split, planned_config=str(config), planned_config_sha256=campaign.sha(config),
            experiment=str(plans / (name + ".experiment.json")), freeze=str(plans / (name + ".freeze.json")),
            output=str(root / name), guard_log=str(root / (name + ".guard.jsonl")), report=str(root / (name + "-report")),
            corpus=str(root / "synthetic-corpus.json"), corpus_sha256="a" * 64, deadline_seconds=30, planned_calls=1))
    if wrong_order: stages = [stages[2], stages[0], stages[1], stages[3]]
    campaign.save(root / "campaign.execution-plan.json", dict(repository_root=str(REPO), max_campaign_seconds=30,
        campaign_runner_sha256=campaign.sha(SOURCE), stages=stages, analysis_helpers={}, quality_policy={"synthetic": "no model inputs"},
        foreign_cpu_limit=1000, max_pre_stage_quiet_wait_seconds=1, complete_product={"cli": "/never/launched"}))
    return stages


class QualityCampaignTests(unittest.TestCase):
    def setUp(self):
        self.signals = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}

    def tearDown(self):
        for number, handler in self.signals.items(): signal.signal(number, handler)

    def test_all_development_precedes_joint_heldout_release_with_exact_config_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); stages = fixture(root); worker = campaign.Campaign(root)
            worker.verify = Mock()
            calls = []
            def run(stage):
                released = (worker.output / "heldout-family.freeze.json").exists()
                calls.append((stage["id"], released))
                if stage["split"] == "held_out":
                    self.assertTrue(all(Path(s["freeze"]).exists() for s in stages if s["split"] == "held_out"))
                    value = json.loads(Path(stage["freeze"]).read_text())
                    self.assertEqual(value["experiment_sha256"], campaign.sha(stage["experiment"]))
                    self.assertTrue(value["frozen_before_held_out"])
                Path(stage["output"]).mkdir(); campaign.save(Path(stage["output"]) / "matrix.json", {"rows": []})
                Path(stage["report"]).mkdir(); campaign.save(Path(stage["report"]) / "report.json", {"synthetic": True})
            worker.run_stage = run; worker.run()
            self.assertEqual(calls, [("dev-a", False), ("dev-b", False), ("held-a", True), ("held-b", True)])
            for stage in stages:
                self.assertFalse(json.loads(Path(stage["planned_config"]).read_text())["capture_inactive"])
                self.assertTrue(json.loads(Path(stage["experiment"]).read_text())["capture_inactive"])

    def test_development_stop_never_retries_or_releases_heldout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); fixture(root); worker = campaign.Campaign(root)
            worker.verify = Mock(); calls = []
            def stop(stage):
                calls.append(stage["id"])
                raise InterruptedError("synthetic recording-priority cancellation")
            worker.run_stage = stop
            with self.assertRaises(InterruptedError): worker.run()
            self.assertEqual(calls, ["dev-a"])
            self.assertFalse((worker.output / "heldout-family.freeze.json").exists())
            self.assertIn("campaign-stopped", worker.journal.read_text())

    def test_stale_admission_and_wrong_stage_order_fail_before_model_work(self):
        for flags in ({"stale": True}, {"wrong_order": True}):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve(); fixture(root, **flags)
                with self.assertRaises(ValueError): campaign.Campaign(root)

    def test_guard_cancellation_cannot_be_treated_as_a_complete_failed_cell_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); stages = fixture(root); worker = campaign.Campaign(root)
            worker.verify = Mock(); worker.guard.capture_or_competing_work = Mock(return_value=None)
            def guard(_args):
                Path(stages[0]["guard_log"]).write_text(json.dumps(dict(reason="application_writing_audio", failure=None,
                    shutdown=dict(cli_reaped=True, owned_session_present=False, shutdown_errors=[]))) + "\n")
                return 130
            worker.guard.main = guard
            with self.assertRaises(InterruptedError): worker.run_stage(stages[0])
            self.assertFalse(Path(stages[0]["report"]).exists())


if __name__ == "__main__": unittest.main()
