"""Offline fresh-slice exclusion, preservation and bounded-source contracts."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave

SPEC = importlib.util.spec_from_file_location("fresh_slice", Path(__file__).resolve().parents[1] / "quality/acquire-fresh-slice.py")
fresh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fresh)


def wav_bytes(samples=b"\x01\x00" * 160):
    stream = io.BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000); audio.writeframes(samples)
    return stream.getvalue()


def metadata(speaker=None):
    return {"evaluation_split": "development", "source_id": "published:source-a", "variety": "test variety",
            "script": "Latn", "license": "test license", "source_url": "https://public.example/source",
            "speaker_ids": [] if speaker is None else [speaker], "reference_conventions": "Exact published field"}


class QualityFreshSliceTests(unittest.TestCase):
    def test_exclusions_include_all_prior_ids_hashes_and_known_groups_without_inference(self):
        exclusions = fresh.Exclusions()
        exclusions.add({"id": "old", "source_id": "old-source", "sha256": "derived", "original_audio_sha256": "original",
                        "reference_sha256": "reference", "speaker_ids": ["known-speaker"], "session_id": "known-session"})
        self.assertEqual(exclusions.reasons("old", "old-source", "original", "reference", ["known-speaker"], "known-session"),
                         ["id", "source_id", "audio", "reference", "speaker", "session"])
        self.assertEqual(exclusions.reasons("new", "new-source", "derived", "new-reference"), ["audio"])
        exclusions.add({"id": "unknown", "source_id": "new-source", "speaker_ids": [], "session_id": None})
        self.assertEqual(exclusions.values["speaker"], {"known-speaker"})
        self.assertEqual(exclusions.values["session"], {"known-session"})

    def test_exclusion_manifest_identity_is_retained_without_reference_file_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            p = root / "prior.json"
            p.write_text(json.dumps({"cases": [{"id": "prior", "reference": "/must/not/open/reference.txt", "reference_sha256": "refhash"}]}))
            exclusions = fresh.Exclusions(); exclusions.load(p)
            self.assertEqual(exclusions.manifests[0]["sha256"], hashlib.sha256(p.read_bytes()).hexdigest())
            self.assertIn("refhash", exclusions.values["reference"])
            alias = root / "alias.json"; alias.symlink_to(p)
            with self.assertRaisesRegex(ValueError, "non-symlink"): exclusions.load(alias)

    def test_preparation_preserves_original_reference_ids_unknowns_and_legacy_scoring(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions())
            original, reference = wav_bytes(), "Opaque published human reference"
            def conversion(_a, _source, target, _maximum):
                with target.open("xb") as stream: stream.write(original)
                return ["fixture PCM conversion"]
            with patch.object(fresh, "convert", side_effect=conversion), patch.object(fresh.subprocess, "check_output", return_value="fixture converter\n"):
                case = fresh.prepare(acquisition, original, reference, "published-new", "de-CH", metadata(), "wav")
            folder = root / "development/published-new"
            self.assertEqual((folder / "source.original.wav").read_bytes(), original)
            self.assertEqual((folder / "reference.original.txt").read_bytes(), reference.encode())
            self.assertEqual(case["source_id"], "published:source-a")
            self.assertEqual(case["speaker_ids"], [])
            self.assertIsNone(case["session_id"])
            self.assertFalse(case["reviewed"])
            self.assertEqual(case["task"], "standard_rendering")
            self.assertEqual(case["development_role"], "validation")
            self.assertEqual(case["scoring_policy"], "swift-nfc-casefold-alphanumeric-v1")
            self.assertIsNone(fresh.prepare(acquisition, original, reference, "published-new", "de-CH", metadata(), "wav"))
            self.assertEqual((folder / "source.original.wav").read_bytes(), original)
            with self.assertRaises(FileExistsError): acquisition.save(folder / "source.original.wav", b"replacement")

    def test_known_speakers_and_reference_duplicates_are_skipped_before_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            exclusions = fresh.Exclusions()
            exclusions.add({"speaker_ids": ["known"], "reference_sha256": fresh.sha(b"same-reference")})
            acquisition = fresh.Acquisition(root, exclusions)
            with patch.object(fresh, "convert") as convert:
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(), "different", "new", "de-CH", metadata("known"), "wav"))
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(), "same-reference", "new", "fr", metadata(), "wav"))
                convert.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_known_session_is_preserved_and_excluded_before_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions())
            source = wav_bytes()
            info = dict(metadata(), session_id="published:session-1")
            def conversion(_a, _source, target, _maximum):
                target.write_bytes(source)
                return ["fixture PCM conversion"]
            with patch.object(fresh, "convert", side_effect=conversion), patch.object(fresh.subprocess, "check_output", return_value="fixture\n"):
                case = fresh.prepare(acquisition, source, "new reference", "session-case", "en", info, "wav")
            self.assertEqual(case["session_id"], "published:session-1")
            with patch.object(fresh, "convert") as convert:
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(b"\x02\x00" * 160), "other reference", "different-case", "en",
                                               dict(metadata(), source_id="other-source", session_id="published:session-1"), "wav"))
                convert.assert_not_called()

    def test_duration_and_flac_header_bounds_are_checked_without_decoding(self):
        packed = (16000 << 44) | (15 << 36) | 32000
        info = bytes(10) + packed.to_bytes(8, "big") + bytes(16)
        self.assertEqual(fresh.source_frames(b"fLaC\x80\x00\x00\x22" + info, "flac"), (32000, 16000))
        with self.assertRaisesRegex(ValueError, "STREAMINFO"): fresh.source_frames(b"not flac", "flac")
        with tempfile.TemporaryDirectory() as directory:
            acquisition = fresh.Acquisition(Path(directory).resolve(), fresh.Exclusions())
            with patch.object(fresh, "source_frames", return_value=(61 * 16000, 16000)), patch.object(fresh, "convert") as convert:
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(), "reference", "new", "fr", metadata(), "wav"))
                convert.assert_not_called()

    def test_network_time_cancel_and_output_bounds_fail_before_new_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions())
            acquisition.network_bytes = fresh.base.MAX_NETWORK_BYTES - 2
            source = io.BytesIO(b"abcdef")
            self.assertEqual(acquisition.read(source, 100), b"ab")
            with self.assertRaisesRegex(ValueError, "network budget"): acquisition.read(source, 1)
            self.assertEqual(source.tell(), 2)
            acquisition.network_bytes = 0
            acquisition.output_bytes = 240 * 1024 * 1024
            with self.assertRaisesRegex(ValueError, "output byte budget"): acquisition.save(root / "oversized", b"x")
            acquisition.deadline = 0
            with self.assertRaises(TimeoutError): acquisition.check()
            acquisition.deadline = float("inf")
            acquisition.cancel.touch()
            with self.assertRaises(InterruptedError): acquisition.save(root / "canceled", b"x")
            self.assertFalse((root / "canceled").exists())

    def test_swiss_archive_identity_is_pinned_before_ranges_are_used(self):
        with tempfile.TemporaryDirectory() as directory:
            acquisition = fresh.Acquisition(Path(directory).resolve(), fresh.Exclusions())
            response = Mock(headers={"ETag": "different", "Content-Length": str(fresh.SWISS_BYTES)})
            with patch.object(fresh.base.Acquisition, "open", return_value=response):
                with self.assertRaisesRegex(ValueError, "ETag/size"): acquisition.open(fresh.base.SWISS_ZIP, method="HEAD")
            response.close.assert_called_once()

    def test_traversing_tar_member_is_never_prepared_or_extracted(self):
        content = io.BytesIO()
        with tarfile.open(fileobj=content, mode="w:gz") as archive:
            entry = tarfile.TarInfo("../../outside.wav"); entry.size = 4
            archive.addfile(entry, io.BytesIO(b"RIFF"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions())
            acquisition.fetch = Mock(return_value=b"1\toutside.wav\topaque reference\tnormalized\tphones\t16\tFEMALE\n")
            acquisition.open = Mock(return_value=io.BytesIO(content.getvalue()))
            with patch.object(fresh, "prepare") as prepare:
                with self.assertRaisesRegex(ValueError, "Unsafe tar"): fresh.fleurs(acquisition, "en", 4, True)
                prepare.assert_not_called()
            self.assertFalse((root.parent / "outside.wav").exists())


if __name__ == "__main__":
    unittest.main()
