"""Synthetic data and mocked HTTP only: never sends a real key or transcript."""
import io
import json
import struct
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from recscribe import openai_ai
from recscribe.cli import main
from recscribe.derive import run
from recscribe.engines import WhisperCpp
from recscribe.job import Job, validate
from recscribe.local_ai import process
from recscribe.process import Cancellation, Cancelled
from recscribe.storage import sha256
from recscribe.vad import PREFIX, HEADER_PARAMETERS, validate_vad
from test_pipeline import FFMPEG, SyntheticEngine, synthesize


class IntelligenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cancel = Cancellation(self.root / "cancel.request")
        self.options = dict(source_language="de-CH", target_language="de", mode="normalize", profile="fast",
                            diarize="off", local_only=False, allow_cloud_text=True, openai_model="synthetic",
                            summarize=True, formats=["json", "md", "txt", "srt", "vtt"])

    def segment(self):
        return {"id": "s1", "source_text": "Grüezi", "review_reasons": ["uncertain"]}

    def response(self, **extra):
        return dict(status="completed", output=[{"type": "message", "content": [{"type": "output_text", "text": json.dumps({
            "segments": [{"id": "s1", "text": "Guten Tag"}], "notes": [{"text": "A greeting", "segment_ids": ["s1"]}]})}]}],
                    usage={"input_tokens": 42, "output_tokens": 12}, **extra)

    def test_vad_rejects_asr_and_truncated_models_before_native_launch(self):
        model = self.root / "arbitrarily-renamed.bin"
        for data in (b"broken", struct.pack("<II", 0x67676D6C, 51866), PREFIX, PREFIX + bytes(24)):
            model.write_bytes(data)
            with patch("recscribe.engines.run_local") as launch:
                with self.assertRaisesRegex(ValueError, "Invalid VAD"):
                    WhisperCpp(Path("binary"), Path("asr"), model).transcribe(Path("audio"), self.root / "out", "de", self.cancel)
                launch.assert_not_called()
        model.write_bytes(PREFIX + HEADER_PARAMETERS.pack(6, 2, 0, 512, 64, 4))
        validate_vad(model)

    def test_consent_required_and_no_local_fallback(self):
        for change in ({"local_only": True}, {"allow_cloud_text": False}):
            with patch("recscribe.openai_ai.request") as network, patch("recscribe.local_ai.request") as local:
                with self.assertRaisesRegex(ValueError, "consent"):
                    process([self.segment()], dict(self.options, **change), self.root, self.cancel, cloud_key="test-key")
                network.assert_not_called(); local.assert_not_called()
        with patch("recscribe.openai_ai.request", side_effect=ValueError("HTTP 401")), patch("recscribe.local_ai.request") as local:
            with self.assertRaisesRegex(ValueError, "401"):
                process([self.segment()], self.options, self.root, self.cancel, cloud_key="test-key")
            local.assert_not_called()

    def test_structured_text_only_request_usage_and_raw_immutability(self):
        segment = self.segment()
        with patch("recscribe.openai_ai.request", return_value=self.response()) as network:
            language, summary = process([segment], self.options, self.root, self.cancel, cloud_key="test-key")
        payload = network.call_args.args[2]
        self.assertFalse(payload["store"])
        self.assertTrue(payload["text"]["format"]["strict"])
        self.assertNotIn("tools", payload)
        self.assertNotIn(str(self.root), json.dumps(payload))
        self.assertEqual(segment["source_text"], "Grüezi")
        self.assertEqual(segment["normalized_text"], "Guten Tag")
        self.assertEqual(language["derivations"][0]["prompt_tokens"], 42)
        self.assertEqual(summary["notes"][0]["segment_ids"], ["s1"])
        for file in self.root.glob("*.json"):
            self.assertNotIn("test-key", file.read_text())

    def test_refusal_incomplete_missing_output_and_cancellation(self):
        payload = dict(model="synthetic", system="test", prompt="test")
        for response in ({"status": "incomplete"}, {"status": "completed", "output": []},
                         {"status": "completed", "output": [{"type": "message", "content": [{"type": "refusal"}]}]}):
            with patch("recscribe.openai_ai.request", return_value=response):
                with self.assertRaises(ValueError): openai_ai.generate(payload, "test-key", self.cancel)
        self.cancel.event.set()
        with patch("http.client.HTTPSConnection") as connection:
            with self.assertRaises(Cancelled): openai_ai.request("responses", "test-key", payload, self.cancel)
            connection.return_value.request.assert_not_called()

    def test_fixed_tls_endpoint_no_redirect_retry_or_response_leak(self):
        for status, data in ((302, b"private body"), (401, b"private body"), (200, b"x" * (openai_ai.MAX_RESPONSE_BYTES + 1))):
            with patch("http.client.HTTPSConnection") as connection:
                response = connection.return_value.getresponse.return_value
                response.status = status; response.read.return_value = data
                with self.assertRaises(ValueError) as caught: openai_ai.request("models", "test-key")
                self.assertNotIn("private body", str(caught.exception))
                connection.assert_called_once_with("api.openai.com", timeout=openai_ai.REQUEST_TIMEOUT)
                connection.return_value.request.assert_called_once()

    def test_key_and_cli_gate_validation(self):
        for key in ("", "x" * (openai_ai.MAX_KEY_BYTES + 1), "bad\nkey", "☃"):
            with self.assertRaises(ValueError): openai_ai.read_key(io.StringIO(key))
        for flags in (["--openai-model", "test"], ["--allow-cloud-text"],
                      ["--derive", "--openai-model", "test", "--allow-cloud-text", "--openai-key-stdin", "--local-only"]):
            with self.assertRaises(SystemExit), patch("recscribe.cli.Job") as job:
                main(["source.wav", *flags])
            job.assert_not_called()

    def test_derive_preserves_parent_and_audio_without_asr(self):
        audio = self.root / "test.wav"; synthesize(audio)
        options = dict(self.options, mode="verbatim", local_only=True, allow_cloud_text=False, openai_model=None, summarize=False)
        parent = Job(self.root / "original", audio, options)
        original = parent.run(SyntheticEngine(), FFMPEG)
        before = {p: sha256(p) for p in parent.directory.rglob("*") if p.is_file()}
        derivative = Job(self.root / "derived", parent.directory / "transcript.json", self.options)
        response = self.response()
        response["output"][0]["content"][0]["text"] = json.dumps({"segments": [{"id": "seg-000001", "text": "Good day"}],
            "notes": [{"text": "A greeting", "segment_ids": ["seg-000001"]}]})
        with patch("recscribe.openai_ai.request", return_value=response), patch("recscribe.engines.run_local") as asr:
            document = run(derivative, "test-key")
        asr.assert_not_called()
        validate(document)
        self.assertEqual(original["source"], document["source"])
        self.assertEqual(original["segments"][0]["source_text"], document["segments"][0]["source_text"])
        self.assertEqual(before, {p: sha256(p) for p in before})
        self.assertFalse(list(derivative.directory.glob("*.wav")))
        self.assertTrue((derivative.directory / "transcript.cleaned.md").is_file())
        summary_job = Job(self.root / "summary", derivative.directory / "transcript.json", dict(self.options, mode="verbatim", target_language=None))
        with patch("recscribe.openai_ai.request", return_value=response):
            summary_document = run(summary_job, "test-key")
        validate(summary_document)
        self.assertEqual(summary_document["segments"][0]["normalized_text"], "Good day")
        self.assertEqual(summary_document["processing"]["mode"], "normalize")
        self.assertEqual(summary_document["language_processing"]["processor"], "openai:synthetic")
        self.assertTrue(Path(summary_document["language_processing"]["derivations"][0]["raw_path"]).is_absolute())

    def test_bit_identical_stereo_is_recognized_once_without_changing_audio(self):
        audio = self.root / "stereo.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"".join(struct.pack("<hh", n % 200, n % 200) for n in range(16000)))
        before = sha256(audio)
        job = Job(self.root / "job", audio, dict(self.options, mode="verbatim", local_only=True, allow_cloud_text=False, openai_model=None, summarize=False))
        document = job.run(SyntheticEngine(), FFMPEG)
        self.assertEqual(len(document["processing"]["engine_passes"]), 1)
        self.assertEqual(document["source"]["channels"], 2)
        self.assertEqual(len(document["segments"]), 1)
        self.assertEqual(before, sha256(audio))
        self.assertIn("shared_bit_identical_channel", (job.directory / "transcript.raw.json").read_text())


if __name__ == "__main__": unittest.main()
