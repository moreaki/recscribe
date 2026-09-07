"""Synthetic cross-part and local AI contracts; no model downloads or private audio."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_pipeline import FFMPEG, SyntheticEngine, synthesize
from recscribe.job import Job, validate
from recscribe.local_ai import local_model, process
from recscribe.process import Cancellation, Cancelled
from recscribe.session import inspect_session
from recscribe.storage import sha256, write_json
from recscribe.renderers import render


class SessionAITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "OutputName.recscribe.json"
        self.options = {"source_language": "de-CH", "target_language": None, "mode": "verbatim",
                        "profile": "fast", "diarize": "off", "local_only": True,
                        "formats": ["json", "md", "txt", "srt", "vtt"]}
        self.manifest = {"schemaVersion": 1, "id": "synthetic-session", "status": "completed",
                         "sampleRate": 16000, "channels": 1, "bitDepth": 16,
                         "channelMap": ["channel-0"], "parts": [], "issues": []}
        for index in range(3):
            path = self.root / ("OutputName.wav" if index == 0 else f"OutputName-Part{index + 1}.wav")
            synthesize(path)
            self.manifest["parts"].append({"path": path.name, "startSample": index * 16000,
                "frames": 16000, "sizeBytes": path.stat().st_size, "sha256": sha256(path), "status": "verified"})
        write_json(self.source, self.manifest)
        self.cancel = Cancellation(self.root / "cancel")

    def run_job(self, **options):
        job = Job(self.root / "job", self.source, dict(self.options, **options))
        return job, job.run(SyntheticEngine(), FFMPEG)

    def test_continuous_timeline_all_artifacts_and_boundaries(self):
        job, document = self.run_job()
        self.assertEqual([s["start_ms"] for s in document["segments"]], [0, 1000, 2000])
        self.assertEqual(document["source"]["duration_ms"], 3000)
        self.assertTrue(all(any("part_boundary" in r for r in s["review_reasons"]) for s in document["segments"]))
        self.assertIn("00:00:02,000 --> 00:00:02,900", (job.directory / "transcript.srt").read_text())
        self.assertEqual(render(document), render(copy.deepcopy(document)))
        self.assertEqual(len(list(job.directory.glob("working*.wav"))), 0)
        self.assertTrue((job.directory / "transcript.raw.json").exists())
        self.assertTrue((job.directory / "transcript.verbatim.txt").exists())
        validate(document)

    def test_missing_part_keeps_gap_without_inventing_speech(self):
        (self.root / "OutputName-Part2.wav").unlink()
        _, document = self.run_job()
        self.assertEqual([s["start_ms"] for s in document["segments"]], [0, 2000])
        self.assertEqual(document["status"], "completed_with_review")
        self.assertTrue(any("part_2_unavailable" in r for r in document["review_reasons"]))

    def test_shared_completion_phases_and_rendering(self):
        self.manifest["parts"] = self.manifest["parts"][:1]
        write_json(self.source, self.manifest)
        for mode in ("verbatim", "normalize", "translate"):
            documents = []
            for name, source in (("wav", self.root / "OutputName.wav"), ("session", self.source)):
                job = Job(self.root / f"{mode}-{name}", source,
                          dict(self.options, mode=mode, target_language="de" if mode != "verbatim" else None))
                document = job.run(SyntheticEngine(), FFMPEG)
                documents.append(document)
                phases = [p["state"] for p in job.manifest["history"]]
                self.assertEqual(phases[-4:], ["post-processing", "validating", "rendering", document["status"]])
                timings = [p["elapsed_seconds"] for p in job.manifest["history"]]
                self.assertEqual(timings, sorted(timings))
                self.assertIn("transcript.raw.json", job.manifest["artifacts"])
            self.assertEqual(documents[0]["segments"], documents[1]["segments"])
            for name in ("transcript.verbatim.txt", "transcript.srt", "transcript.vtt"):
                self.assertEqual(render(documents[0])[name], render(documents[1])[name])

    def test_completion_cancellation_preserves_raw_and_never_completes(self):
        for source in (self.root / "OutputName.wav", self.source):
            for phase in ("post-processing", "validating", "rendering", "inventory"):
                job = Job(self.root / f"cancel-{source.suffix}-{phase}", source, self.options)
                original_transition, original_inventory = job.transition, job.inventory
                def transition(state, progress):
                    original_transition(state, progress)
                    if state == phase:
                        job.cancel.event.set()
                def inventory(*, cancellable=False):
                    if phase == "inventory" and cancellable:
                        job.cancel.event.set()
                    original_inventory(cancellable=cancellable)
                with patch.object(job, "transition", side_effect=transition), patch.object(job, "inventory", side_effect=inventory):
                    with self.assertRaises(Cancelled):
                        job.run(SyntheticEngine(), FFMPEG)
                self.assertEqual(job.manifest["state"], "cancelled")
                self.assertTrue((job.directory / "transcript.raw.json").exists())
                self.assertNotIn("completed_with_review", [p["state"] for p in job.manifest["history"]])

    def test_corrupt_part_is_reviewed(self):
        (self.root / "OutputName-Part2.wav").write_bytes(b"broken")
        _, document = self.run_job()
        self.assertEqual(len(document["segments"]), 2)

    def test_order_traversal_and_live_recording_refused(self):
        for mutate in [lambda m: m.update(status="recording"),
                       lambda m: m["parts"][1].update(startSample=1),
                       lambda m: m["parts"][0].update(path="../outside.wav")]:
            manifest = copy.deepcopy(self.manifest); mutate(manifest)
            write_json(self.source, manifest)
            with self.assertRaises(ValueError):
                inspect_session(self.source, self.cancel)

    def test_local_ai_modes_provenance_summary_and_immutable_raw(self):
        for mode, field in [("normalize", "normalized_text"), ("translate", "translated_text")]:
            segment = {"id": "seg-000001", "source_text": "Grüezi", "review_reasons": []}
            def request(route, payload=None, **kwargs):
                if route == "show": return {"model_info": {"architecture": "synthetic-test"}}
                return {"done": True, "response": json.dumps({"segments": [{"id": "seg-000001", "text": "Guten Tag"}],
                    "notes": [{"text": "Eine Begrüssung", "segment_ids": ["seg-000001"]}]}), "eval_count": 10}
            with patch("recscribe.local_ai.request", side_effect=request):
                language, summary = process([segment], dict(self.options, mode=mode, target_language="de", ollama_model="test-local", summarize=True), self.root, self.cancel)
            self.assertEqual(segment["source_text"], "Grüezi")
            self.assertEqual(segment[field], "Guten Tag")
            self.assertEqual(language["status"], "completed")
            self.assertEqual(summary["status"], "needs_review")
            self.assertFalse(language["derivations"][0]["human_verified"])
            self.assertTrue((self.root / "ai-raw-0000.json").exists())

    def test_remote_models_and_invalid_references_refused(self):
        with patch("recscribe.local_ai.request", return_value={"remote_host": "https://ollama.com", "model_info": {"x": 1}}):
            with self.assertRaises(ValueError): local_model("remote-test")
        with self.assertRaises(ValueError): local_model("large:cloud")
        with patch("recscribe.local_ai.request", side_effect=[{"model_info": {"x": 1}},
                {"done": True, "response": '{"segments":[{"id":"made-up","text":"invented"}]}'}]):
            with self.assertRaises(ValueError):
                process([{"id": "seg-000001", "source_text": "Grüezi", "review_reasons": []}],
                        dict(self.options, mode="normalize", ollama_model="local"), self.root, self.cancel)

    def test_full_session_ai_stage_validates_and_renders_source_linked_notes(self):
        def request(route, payload=None, **kwargs):
            if route == "show": return {"model_info": {"architecture": "synthetic-test"}}
            source = json.loads(payload["prompt"])["untrusted_transcript"]
            return {"done": True, "response": json.dumps({"segments": [dict(s, text="Guten Tag") for s in source],
                "notes": [{"text": "Begrüssung", "segment_ids": [source[0]["id"]]}]})}
        with patch("recscribe.local_ai.request", side_effect=request):
            job, document = self.run_job(mode="normalize", target_language="de", ollama_model="synthetic", summarize=True)
        validate(document)
        self.assertIn("Summary notes [REVIEW]", (job.directory / "transcript.cleaned.md").read_text())
        self.assertIn("Grüezi", (job.directory / "transcript.verbatim.txt").read_text())
        self.assertEqual(len(document["language_processing"]["derivations"]), 3)


if __name__ == "__main__":
    unittest.main()
