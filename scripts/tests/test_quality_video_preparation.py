"""Offline source/caption and cancellation contracts; no public media is fetched."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("video", Path(__file__).resolve().parents[1] / "quality/prepare-video-cases.py")
video = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(video)


def case():
    return {"id": "swiss", "url": "https://www.youtube.com/watch?v=T492BPuRd-M", "language": "de-CH",
            "subtitle_language": "de", "split": "development", "start_seconds": 30, "duration_seconds": 60}


class VideoPreparationTests(unittest.TestCase):
    def setUp(self):
        probe = patch.object(video.guard, "capture_or_competing_work", return_value=None)
        probe.start()
        self.addCleanup(probe.stop)

    def test_recording_or_uncertain_state_defers_before_launch_without_stopping_foreign_processes(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); work = video.Preparation(root)
            with patch.object(video.guard, "capture_or_competing_work", return_value="active_capture"), patch.object(video.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(InterruptedError, "recording priority"):
                    work.run(["never-launch"], root, "test", 1)
                launch.assert_not_called()

    def test_swiss_written_german_and_explicit_source_interval(self):
        self.assertEqual(video.validate({"schema_version": "1.0", "cases": [case()]}), [case()])

    def test_url_shell_traversal_playlist_and_translated_track_are_rejected(self):
        for key, value in [("id", "../x"), ("id", "x;command"), ("url", "https://example.com/file"),
                           ("url", case()["url"] + "&list=anything"), ("subtitle_language", "en")]:
            c = case(); c[key] = value
            with self.assertRaises(ValueError):
                video.validate({"schema_version": "1.0", "cases": [c]})

    def test_finite_ranges_and_no_cross_partition_video_reuse(self):
        for key, value in [("start_seconds", -1), ("duration_seconds", 601), ("duration_seconds", True),
                           ("duration_seconds", float("nan")), ("start_seconds", float("inf"))]:
            c = case(); c[key] = value
            with self.assertRaises(ValueError):
                video.validate({"schema_version": "1.0", "cases": [c]})
        b = case(); b.update(id="held", split="held_out")
        with self.assertRaisesRegex(ValueError, "cannot cross"):
            video.validate({"schema_version": "1.0", "cases": [case(), b]})

    def test_manual_automatic_and_translated_captions_never_become_approved_truth(self):
        manual = {"subtitles": {"de": [{"ext": "vtt", "url": "https://example.com/caption"}]}}
        original = copy.deepcopy(manual)
        self.assertEqual(video.caption_status(manual, "de"), "manual_source_track_unreviewed")
        self.assertEqual(manual, original)
        auto = {"automatic_captions": {"de": [{"ext": "vtt"}]}}
        self.assertEqual(video.caption_status(auto, "de"), "automatic_only_not_reference")
        for suffix in ["?tlang=de", "?kind=asr"]:
            manual["subtitles"]["de"][0]["url"] += suffix
            self.assertEqual(video.caption_status(manual, "de"), "no_downloadable_same_language_reference")

    def test_cancel_prevents_helper_launch(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root / "cancel.request").touch()
            work = video.Preparation(root)
            with patch.object(video.subprocess, "Popen") as launch:
                with self.assertRaises(InterruptedError):
                    work.run(["not-launched"], root, "test", 1)
                launch.assert_not_called()

    def test_timeout_reaps_the_owned_helper_and_keeps_its_log(self):
        import sys
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); work = video.Preparation(root)
            with self.assertRaises(TimeoutError):
                work.run([sys.executable, "-c", "import time; print('started', flush=True); time.sleep(30)"], root, "bounded", .3)
            self.assertTrue((root / "bounded.log").is_file())
            self.assertFalse(json.loads((root / "bounded.cleanup.json").read_text())["owned_session_present"])

    def test_cleanup_reaps_owned_descendants_after_the_direct_helper_exits(self):
        import sys
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); work = video.Preparation(root)
            command = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])"
            work.run([sys.executable, "-c", command], root, "descendant", 5)
            cleanup = json.loads((root / "descendant.cleanup.json").read_text())
            self.assertTrue(cleanup["cli_reaped"])
            self.assertFalse(cleanup["owned_session_present"])
            self.assertEqual(cleanup["shutdown_errors"], [])

    def test_offline_preparation_retains_audio_and_raw_cues_without_approving_or_inventing_groups(self):
        def helper(self, command, directory, label, timeout):
            self.commands.append(command)
            (directory / (label + ".log")).write_text("mock helper\n")
            if label == "metadata":
                (directory / "source.info.json").write_text(json.dumps({"duration": 120, "subtitles": {
                    "de": [{"ext": "vtt", "url": "https://example.com/captions"}]}}))
            if label == "audio":
                (directory / "source.m4a").write_bytes(b"original audio fixture")
                (directory / "source.de.vtt").write_text("WEBVTT\n\n00:30.000 --> 00:31.000\nOriginal caption\n")
            if label == "stream-layout":
                (directory / "stream-layout.log").write_text('{"streams":[{"codec_type":"audio"}]}')
            if label == "preparation":
                (directory / "prepared.wav").write_bytes(b"derived PCM fixture")
        with tempfile.TemporaryDirectory() as name, patch.object(video.Preparation, "run", helper):
            output = Path(name).resolve() / "new"
            row = video.prepare({"schema_version": "1.0", "cases": [case()]}, output)[0]
            self.assertEqual(row["status"], "prepared_unreviewed")
            self.assertFalse(row["reviewed"])
            self.assertEqual(row["speaker_ids"], [])
            self.assertIsNone(row["session_id"])
            self.assertEqual((output / "swiss/source.m4a").read_bytes(), b"original audio fixture")
            self.assertIn("00:30.000", (output / "swiss/source.de.vtt").read_text())
            self.assertTrue(all(f["sha256"] for f in row["files"]))
            self.assertNotIn("reference.txt", [p.name for p in (output / "swiss").iterdir()])


if __name__ == "__main__":
    unittest.main()
