"""Offline safety contracts for public corpus acquisition; no network or ASR."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave
import zipfile

MODULE = Path(__file__).resolve().parents[1] / "quality" / "acquire-pilot.py"
SPEC = importlib.util.spec_from_file_location("quality_acquisition", MODULE)
acquire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acquire)


class Response(io.BytesIO):
    def __init__(self, data=b"", status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class QualityAcquisitionTests(unittest.TestCase):
    def test_existing_original_is_never_truncated_or_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "source.original.wav"
            acquire.save(path, b"original")
            with self.assertRaises(FileExistsError):
                acquire.save(path, b"replacement")
            self.assertEqual(path.read_bytes(), b"original")

    def test_metadata_and_stream_byte_budgets_fail_visibly(self):
        with tempfile.TemporaryDirectory() as folder:
            acquisition = acquire.Acquisition(Path(folder))
            with patch.object(acquisition, "open", return_value=Response(b"oversized")):
                with self.assertRaisesRegex(ValueError, "bounded size"):
                    acquisition.fetch("https://public.example/metadata", maximum=3)
            stream = acquire.BoundedStream(acquisition, Response(b"12345"), maximum=3)
            with self.assertRaisesRegex(ValueError, "selection budget"):
                stream.read(5)
            acquisition.cancel.touch()
            with self.assertRaises(InterruptedError):
                acquisition.check()

    def test_range_server_must_honor_exact_request_without_reading_full_archive(self):
        acquisition = Mock()
        acquisition.open.side_effect = [Response(headers={"Content-Length": "100"}), Response(b"full archive", status=200)]
        remote = acquire.RemoteZIP(acquisition, "https://public.example/source.zip")
        remote.seek(50)
        with self.assertRaisesRegex(ValueError, "did not honor"):
            remote.read(10)
        acquisition.read.assert_not_called()
        self.assertEqual(acquisition.open.call_args.args[1], {"Range": "bytes=50-59"})

    def test_range_mismatch_and_read_size_are_rejected(self):
        acquisition = Mock()
        acquisition.open.side_effect = [Response(headers={"Content-Length": "100"}),
            Response(status=206, headers={"Content-Range": "bytes 0-9/100"})]
        remote = acquire.RemoteZIP(acquisition, "https://public.example/source.zip")
        remote.seek(50)
        with self.assertRaisesRegex(ValueError, "differs from request"):
            remote.read(10)
        acquisition.read.assert_not_called()
        remote.length = acquire.MAX_MEMBER_BYTES + 1
        remote.seek(0)
        with self.assertRaisesRegex(ValueError, "exceeds 16 MiB"):
            remote.read()

    def test_zip_metadata_inflation_is_bounded(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("metadata.tsv", "x" * 1000)
        data.seek(0)
        with zipfile.ZipFile(data) as archive:
            with self.assertRaisesRegex(ValueError, "bounded size"):
                acquire.read_zip_member(archive, "metadata.tsv", maximum=100)
            self.assertEqual(acquire.read_zip_member(archive, "metadata.tsv", maximum=1000), b"x" * 1000)

    def test_archive_paths_are_not_extracted_and_speaker_ids_are_not_inferred(self):
        archive_bytes = io.BytesIO()
        with tarfile.open(fileobj=archive_bytes, mode="w:gz") as archive:
            entry = tarfile.TarInfo("../../outside.wav")
            entry.size = 4
            archive.addfile(entry, io.BytesIO(b"RIFF"))
        metadata = b"1\toutside.wav\tPublished human reference\tnormalized\tphones\t4\tFEMALE\n"
        with tempfile.TemporaryDirectory() as folder:
            acquisition = acquire.Acquisition(Path(folder))
            acquisition.fetch = Mock(return_value=metadata)
            acquisition.open = Mock(return_value=Response(archive_bytes.getvalue()))
            with patch.object(acquire, "prepare_case", return_value={"id": "safe"}) as prepare:
                rows = acquire.acquire_fleurs(acquisition, "en", 1)
            self.assertEqual(rows, [{"id": "safe"}])
            args = prepare.call_args.args
            self.assertEqual(args[3], "fleurs-en-us-outside")
            self.assertEqual(args[5]["speaker_ids"], [])
            self.assertIsNone(args[5]["session_id"])
            self.assertEqual(args[5]["archive_member"], "../../outside.wav")
            self.assertFalse((Path(folder).parent / "outside.wav").exists())

    def test_case_identity_and_split_cannot_escape_external_root(self):
        with tempfile.TemporaryDirectory() as folder:
            acquisition = acquire.Acquisition(Path(folder))
            for identifier, split in [("../../outside", "development"), ("safe", "../../outside")]:
                with self.assertRaisesRegex(ValueError, "Unsafe corpus"):
                    acquire.prepare_case(acquisition, b"RIFF", "reference", identifier, "en", {"evaluation_split": split})
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_derivation_preserves_source_and_reference_and_requires_no_inferred_grouping(self):
        with tempfile.TemporaryDirectory() as folder:
            acquisition = acquire.Acquisition(Path(folder))
            original, reference = b"exact source bytes", "Human reference"
            metadata = {"license": "test license", "variety": "test", "script": "Latn", "source_url": "https://public.example/source",
                "source_id": "published-source", "reference_conventions": "exact original field", "limitations": ["test"]}
            def write_derived(command, **kwargs):
                with wave.open(command[-1], "wb") as output:
                    output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
                    output.writeframes(b"\0\0" * 16)
            with patch.object(acquire.subprocess, "run", side_effect=write_derived), patch.object(acquire.subprocess, "check_output", return_value="test ffmpeg\n"):
                row = acquire.prepare_case(acquisition, original, reference, "safe-id", "en", metadata)
            source = Path(folder) / "development" / "safe-id" / "source.original.wav"
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(Path(row["reference"]).read_text(), reference)
            self.assertEqual(row["original_audio_sha256"], acquire.digest(original))
            self.assertEqual(row["reference_sha256"], acquire.digest(reference.encode()))
            self.assertEqual(row["speaker_ids"], [])
            self.assertIsNone(row["session_id"])
            self.assertFalse(row["reviewed"])
            self.assertEqual(row["duration_seconds"], 0.001)
            with self.assertRaises(FileExistsError):
                acquire.prepare_case(acquisition, b"replacement", reference, "safe-id", "en", metadata)


if __name__ == "__main__":
    unittest.main()
