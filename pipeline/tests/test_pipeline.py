"""Synthetic contract tests, not ASR accuracy claims. No private audio fixtures."""

import copy
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

from jsonschema import ValidationError

from recscribe.audio import inspect_wav
from recscribe.engines import EngineResult, WhisperCpp
from recscribe.job import Job, validate
from recscribe.process import Cancellation, Cancelled, run_local
from recscribe.renderers import render, timestamp
from recscribe.storage import sha256, write_json


ROOT = Path(__file__).resolve().parents[2]
FFMPEG = Path(shutil.which("ffmpeg") or "/missing-ffmpeg")


def synthesize(path, channels=1, width=2, rate=16000, silence=False):
    with wave.open(str(path), "wb") as wav:
        wav.setparams((channels, width, rate, 0, "NONE", "not compressed"))
        data = bytearray()
        for i in range(rate):
            for channel in range(channels):
                value = 0 if silence else round(math.sin(i * (channel + 1) * 0.11) * (2 ** (width * 8 - 3)))
                data.extend(bytes([value + 128]) if width == 1 else value.to_bytes(width, "little", signed=True))
        wav.writeframes(data)


class SyntheticEngine:
    """Test-only engine: explicitly labels its provenance as synthetic."""
    def __init__(self, text="Grüezi, 42!", start=0, end=900):
        self.text, self.start, self.end = text, start, end
        self.calls = 0

    def transcribe(self, audio, output, language, cancel):
        cancel.check()
        self.calls += 1
        raw = output.with_suffix(".json")
        write_json(raw, {"synthetic_test_only": True, "text": self.text})
        segments = [{"start_ms": self.start, "end_ms": self.end,
                     "source_text": self.text, "confidence": None,
                     "speaker": None, "words": []}] if self.text else []
        return EngineResult(segments, raw, {"engine": "synthetic-test-only",
            "version": "1", "model": "synthetic-text-fixture",
            "model_sha256": hashlib.sha256(self.text.encode()).hexdigest(),
            "command": [], "duration_seconds": 0, "local_only": True})


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.wav"
        synthesize(self.source)
        self.options = {"source_language": "de-CH", "target_language": None,
                        "mode": "verbatim", "profile": "fast", "diarize": "off",
                        "local_only": True, "formats": ["json", "md", "txt", "srt", "vtt"]}

    def job(self, name="job", **options):
        return Job(self.root / name, self.source, dict(self.options, **options))

    def run_job(self, engine=None, **options):
        job = self.job(**options)
        return job, job.run(engine or SyntheticEngine(), FFMPEG)

    def test_pcm_widths_and_rates(self):
        for width in (1, 2, 3, 4):
            with self.subTest(width=width):
                synthesize(self.source, channels=2, width=width, rate=22050)
                report = inspect_wav(self.source, Cancellation(self.root / "cancel"))
                self.assertEqual(report["sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
                self.assertEqual(report["bit_depth"], 8 * width)
                self.assertEqual(report["duration_ms"], 1000)
                self.assertEqual(len(report["channel_metrics"]), 2)
                self.assertGreater(report["channel_metrics"][0]["rms"], 0)

    def test_truncated_and_empty_wav_fail(self):
        self.source.write_bytes(self.source.read_bytes()[:-5])
        job = self.job()
        with self.assertRaises(ValueError):
            job.run(SyntheticEngine(), FFMPEG)
        self.assertEqual(json.loads((job.directory / "manifest.json").read_text())["state"], "failed")
        with wave.open(str(self.source), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", ""))
        with self.assertRaises(ValueError):
            inspect_wav(self.source, Cancellation(self.root / "cancel"))

    def test_all_artifacts_source_and_raw_immutable(self):
        before = self.source.read_bytes()
        job, doc = self.run_job()
        required = {"manifest.json", "audio-report.json", "transcript.raw.json", "transcript.json",
                    "transcript.verbatim.txt", "transcript.cleaned.md", "transcript.srt", "transcript.vtt", "review.md"}
        self.assertTrue(required <= {p.name for p in job.directory.iterdir()})
        self.assertEqual(before, self.source.read_bytes())
        self.assertEqual(doc["status"], "completed_with_review")
        self.assertIsNone(doc["segments"][0]["speaker"])
        self.assertEqual(doc["segments"][0]["source_text"], "Grüezi, 42!")
        index = json.loads((job.directory / "transcript.raw.json").read_text())
        raw = job.directory / index["outputs"][0]["path"]
        raw_bytes = raw.read_bytes()
        self.assertEqual(sha256(raw), index["outputs"][0]["sha256"])
        render(doc)
        self.assertEqual(raw_bytes, raw.read_bytes())
        manifest = json.loads((job.directory / "manifest.json").read_text())
        for name, info in manifest["artifacts"].items():
            self.assertEqual(sha256(job.directory / name), info["sha256"])
        self.assertEqual([s["state"] for s in manifest["history"]],
            ["queued", "inspecting", "preparing", "transcribing", "post-processing", "validating", "rendering", "completed_with_review"])
        with self.assertRaises(FileExistsError):
            self.job()

    def test_stereo_keeps_channels(self):
        synthesize(self.source, channels=2, rate=48000)
        engine = SyntheticEngine()
        job, doc = self.run_job(engine)
        self.assertEqual(engine.calls, 2)
        self.assertEqual([s["channel"] for s in doc["segments"]], [0, 1])
        pcm = []
        for c in range(2):
            with wave.open(str(job.directory / f"working-channel-{c}.wav"), "rb") as wav:
                self.assertEqual((wav.getnchannels(), wav.getframerate(), wav.getsampwidth()), (1, 16000, 2))
                pcm.append(wav.readframes(wav.getnframes()))
        self.assertNotEqual(*pcm)

    def test_silence_never_calls_asr(self):
        synthesize(self.source, silence=True)
        engine = SyntheticEngine()
        job, doc = self.run_job(engine, source_language="en")
        self.assertEqual(engine.calls, 0)
        self.assertEqual(doc["segments"], [])
        self.assertEqual(doc["status"], "completed")
        self.assertEqual((job.directory / "transcript.srt").read_text(), "")

    def test_non_silent_empty_asr_requires_review(self):
        _, doc = self.run_job(SyntheticEngine(text=""))
        self.assertIn("no_speech_recognized_in_non_silent_channel_0", doc["review_reasons"])

    def test_non_speech_markers_are_evidence_not_confident_speech(self):
        _, doc = self.run_job(SyntheticEngine(text=" [BLANK_AUDIO]"))
        self.assertEqual(doc["segments"][0]["source_text"], " [BLANK_AUDIO]")
        self.assertIn("engine_non_speech_marker", doc["segments"][0]["review_reasons"])

    def test_modes_never_fabricate_derived_text(self):
        for mode in ("normalize", "translate"):
            job = self.job(name=mode, mode=mode, target_language="de")
            doc = job.run(SyntheticEngine(), FFMPEG)
            self.assertEqual(doc["language_processing"]["status"], "pending")
            self.assertIsNone(doc["segments"][0]["normalized_text"])
            self.assertIsNone(doc["segments"][0]["translated_text"])
            self.assertIn("pending", (job.directory / "transcript.cleaned.md").read_text())

    def test_verified_disagreement_preserves_both_passes(self):
        job = self.job(profile="verified")
        doc = job.run(SyntheticEngine("Nicht 42"), FFMPEG, SyntheticEngine("42"))
        self.assertEqual(doc["segments"][0]["source_text"], "Nicht 42")
        self.assertIn("engine_pass_disagreement", doc["segments"][0]["review_reasons"])
        self.assertEqual(len(json.loads((job.directory / "transcript.raw.json").read_text())["outputs"]), 2)

    def test_cancellation_before_work(self):
        job = self.job()
        job.cancel.request_path.touch()
        with self.assertRaises(Cancelled):
            job.run(SyntheticEngine(), FFMPEG)
        self.assertEqual(json.loads((job.directory / "manifest.json").read_text())["state"], "cancelled")

    def test_verified_refuses_the_same_model(self):
        job = self.job(profile="verified")
        with self.assertRaisesRegex(ValueError, "distinct model"):
            job.run(SyntheticEngine(), FFMPEG, SyntheticEngine())

    def test_source_change_during_inference_invalidates_result(self):
        source = self.source
        class MutatingEngine(SyntheticEngine):
            def transcribe(self, *args):
                result = super().transcribe(*args)
                with source.open("ab") as stream:
                    stream.write(b"changed")
                return result
        job = self.job()
        with self.assertRaisesRegex(ValueError, "Source changed"):
            job.run(MutatingEngine(), FFMPEG)
        self.assertTrue((job.directory / "asr-channel-0.json").exists())
        self.assertFalse((job.directory / "transcript.json").exists())

    def test_cancellation_terminates_child(self):
        cancel = Cancellation(self.root / "cancel")
        timer = threading.Timer(0.3, cancel.event.set)
        timer.start()
        started = time.monotonic()
        with self.assertRaises(Cancelled):
            run_local([sys.executable, "-c", "import time; time.sleep(60)"], self.root / "child.log", cancel)
        timer.join()
        self.assertLess(time.monotonic() - started, 4)

    def test_process_failure_and_timeout(self):
        cancel = Cancellation(self.root / "cancel")
        with self.assertRaises(RuntimeError):
            run_local([sys.executable, "-c", "raise SystemExit(7)"], self.root / "error.log", cancel)
        with self.assertRaises(TimeoutError):
            run_local([sys.executable, "-c", "import time; time.sleep(60)"], self.root / "timeout.log", cancel, timeout=0.1)

    def test_schema_and_semantic_validation(self):
        _, doc = self.run_job()
        validate(doc)
        for field, value in (("end_ms", 2000), ("start_ms", -1), ("confidence", 2)):
            broken = copy.deepcopy(doc)
            broken["segments"][0][field] = value
            with self.assertRaises((ValueError, ValidationError)):
                validate(broken)
        broken = copy.deepcopy(doc)
        broken["segments"].append(copy.deepcopy(broken["segments"][0]))
        with self.assertRaises(ValueError):
            validate(broken)
        broken = copy.deepcopy(doc)
        broken["segments"][0]["normalized_text"] = "Untraceable rewriting"
        with self.assertRaises(ValueError):
            validate(broken)
        packaged = ROOT / "pipeline/src/recscribe/transcript.schema.json"
        self.assertEqual(packaged.read_bytes(), (ROOT / "schemas/transcript.schema.json").read_bytes())

    def test_out_of_bounds_engine_fails_instead_of_clamping(self):
        job = self.job()
        with self.assertRaises(ValueError):
            job.run(SyntheticEngine(end=40000), FFMPEG)
        self.assertTrue((job.directory / "transcript.raw.json").exists())
        self.assertFalse((job.directory / "transcript.json").exists())

    def test_decoder_padding_is_trimmed_with_explicit_provenance(self):
        job, doc = self.run_job(SyntheticEngine(end=1500))
        segment = doc["segments"][0]
        self.assertEqual(segment["end_ms"], 1000)
        self.assertEqual(segment["timing_adjustment"]["original_end_ms"], 1500)
        self.assertTrue(segment["needs_review"])

    def test_exports_deterministic_and_escape_markup(self):
        _, doc = self.run_job(SyntheticEngine(text="<script> & **hi**\n\nWEBVTT"))
        outputs = render(doc)
        self.assertEqual(outputs, render(json.loads(json.dumps(doc))))
        self.assertEqual(timestamp(3600007, ","), "01:00:00,007")
        self.assertIn("00:00:00,000 --> 00:00:00,900", outputs["transcript.srt"])
        self.assertIn("&lt;script&gt;", outputs["transcript.vtt"])
        self.assertNotIn("<script>", outputs["transcript.cleaned.md"])
        self.assertIn("[REVIEW]", outputs["transcript.srt"])

    def test_missing_model_fails_without_network_fallback(self):
        job = self.job()
        with self.assertRaises(ValueError):
            job.run(WhisperCpp(Path(sys.executable), self.root / "missing-model"), FFMPEG)
        self.assertEqual(job.manifest["state"], "failed")

    def test_cli_silence_and_invalid_mode(self):
        synthesize(self.source, silence=True)
        command = [sys.executable, "-m", "recscribe", str(self.source), "--output", str(self.root / "cli"), "--local-only"]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "completed")
        invalid = subprocess.run(command + ["--mode", "normalize"], capture_output=True)
        self.assertEqual(invalid.returncode, 2)

    def test_cli_signal_cancel(self):
        # Use a fake normalizer which waits; exercise actual CLI signal handling.
        binary = self.root / "slow-ffmpeg"
        binary.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(60)\n")
        binary.chmod(0o700)
        output = self.root / "signal-job"
        process = subprocess.Popen([sys.executable, "-m", "recscribe", str(self.source),
                                   "--output", str(output), "--ffmpeg", str(binary)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (output / "ffmpeg.version.log").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
            self.assertEqual(json.loads((output / "manifest.json").read_text())["state"], "cancelled")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_whisper_cpp_contract_real_subprocess(self):
        binary = self.root / "fake-whisper-cli"
        # This emits the documented whisper.cpp JSON structure, not recognized speech.
        binary.write_text(f"#!{sys.executable}\n" + '''import json, pathlib, sys
if "--version" in sys.argv:
    print("synthetic whisper.cpp contract fixture 1")
else:
    assert "-tr" not in sys.argv
    assert sys.argv[sys.argv.index("-l") + 1] == "de"
    out = pathlib.Path(sys.argv[sys.argv.index("-of") + 1] + ".json")
    out.write_text(json.dumps({"result": {"language": "de"}, "transcription": [
        {"offsets": {"from": 0, "to": 900}, "text": " Grüezi! "}]}))
''')
        binary.chmod(0o700)
        model = self.root / "synthetic-model.bin"
        model.write_bytes(b"not an ASR model")
        job, doc = self.run_job(WhisperCpp(binary, model))
        self.assertEqual(doc["segments"][0]["source_text"], " Grüezi! ")
        self.assertEqual(doc["processing"]["engine_passes"][0]["model_sha256"], sha256(model))
        raw = (job.directory / "asr-channel-0.json").read_bytes()
        self.assertNotIn(b"normalized_text", raw)
        with self.assertRaises(FileExistsError):
            WhisperCpp(binary, model).transcribe(job.directory / "working-channel-0.wav",
                job.directory / "asr-channel-0", "de-CH", job.cancel)


if __name__ == "__main__":
    unittest.main()
