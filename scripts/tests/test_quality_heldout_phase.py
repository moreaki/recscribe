"""Partial development is disclosed, never upgraded into complete validation."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "benchmarks/quantized-quality/heldout-phase-v1.py"
SPEC = importlib.util.spec_from_file_location("quality_heldout_phase", SOURCE)
phase = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(phase)


def fixture():
    cases = [dict(id=str(i), language="en", sha256="audio-" + str(i), reference_sha256="ref-" + str(i)) for i in range(4)]
    models = ["tiny", "base", "small", "large-v3-turbo", "large-v3"]
    rows = [dict(model=model, id=c["id"], language_mode=mode, repeat=1, path="final", status="completed_with_review",
                 source_sha256=c["sha256"], reference_sha256=c["reference_sha256"], measurement=dict(reference_characters=1,
                    scoring_version="swift-nfc-casefold-alphanumeric-v1")) for model in models for c in cases for mode in ("known", "auto")]
    return cases, rows, models


class QualityHeldoutPhaseTests(unittest.TestCase):
    def test_missing_original_and_candidate_cells_remain_missing_without_mutating_evidence(self):
        cases, rows, models = fixture()
        rows[-1]["status"] = "cancelled"
        rows += [dict(model="large-v3-q4_0", status="queued"), dict(model="large-v3-turbo-q5_1", status="cancelled")]
        before = copy.deepcopy(rows)
        value = phase.development_inventory(cases, rows, models)
        self.assertEqual(rows, before)
        self.assertEqual(value["completed_cells"], 39)
        self.assertEqual(value["original_completed_cells"], 39)
        self.assertEqual(value["missing_cells"], 3)
        self.assertEqual(value["original_development_completeness"], "NOT_MET")
        self.assertEqual(value["development_acceptance"], "pending")
        self.assertFalse(value["missing_measurements_retried"])

    def test_unknown_active_duplicate_or_changed_sources_are_rejected(self):
        for change in ("active", "duplicate", "source", "reference", "scorer", "missing_row"):
            cases, rows, models = fixture()
            if change == "active": rows[0]["status"] = "running"
            elif change == "duplicate": rows.append(copy.deepcopy(rows[0]))
            elif change == "source": rows[0]["source_sha256"] = "changed"
            elif change == "reference": rows[0]["reference_sha256"] = "changed"
            elif change == "scorer": rows[0]["measurement"]["scoring_version"] = "changed"
            else: rows.pop()
            with self.subTest(change=change), self.assertRaises(ValueError):
                phase.development_inventory(cases, rows, models)

    def test_absent_original_language_mode_baseline_cannot_start_the_phase(self):
        cases, rows, models = fixture()
        for row in rows:
            if row["model"] == "large-v3" and row["language_mode"] == "auto":
                row["status"] = "cancelled"
        with self.assertRaises(ValueError):
            phase.development_inventory(cases, rows, models)

    def test_all_heldout_batches_seal_with_pending_development_before_any_call(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            worker = phase.HeldOutPhase.__new__(phase.HeldOutPhase)
            worker.root = worker.output = root
            worker.development = dict(original_development_completeness="NOT_MET", missing_cells=194)
            profile = root / "profile.json"; profile.write_text("{}")
            output = root / "development"; output.mkdir(); (output / "matrix.json").write_text("{}")
            stages = [dict(id="dev", split="development", output=str(output))]
            for index in range(5):
                experiment = root / f"held-{index}.json"
                experiment.write_text(json.dumps(dict(profiles=[dict(id="matched", settings=str(profile))])))
                stages.append(dict(id=f"held-{index}", split="held_out", corpus_sha256="a" * 64,
                                   experiment=str(experiment), freeze=str(root / f"freeze-{index}.json")))
            policy = dict(macro_cer_margin=.005, bootstrap_seed=10410520261110)
            worker.plan = dict(stages=stages, quality_policy=policy)
            worker.stop_watch = threading.Event(); worker.watch = lambda: None
            events = []; worker.event = lambda name, **kw: events.append((name, kw))
            worker.verify = lambda: None
            def call(stage):
                for held in stages[1:]:
                    freeze = json.loads(Path(held["freeze"]).read_text())
                    self.assertEqual(freeze["development_checkpoint"], worker.development)
                    self.assertTrue(freeze["development_acceptance_remains_pending"])
                    self.assertEqual(freeze["budgets"], policy)
                events.append(("call", stage["id"]))
            worker.run_stage = call
            worker.run()
            self.assertEqual(sum(name == "call" for name, _ in events), 5)
            self.assertLess(next(i for i, e in enumerate(events) if e[0] == "all-heldout-freezes-released"),
                            next(i for i, e in enumerate(events) if e[0] == "call"))
