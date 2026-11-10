"""Offline fresh-slice exclusion, preservation and bounded-source contracts."""
import hashlib
from contextlib import redirect_stdout, redirect_stderr
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
            with patch.object(fresh, "convert", side_effect=conversion), patch.object(fresh, "converter_version", return_value="fixture converter"):
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
            self.assertEqual(case["source_channels"], 1)
            provenance = json.loads((folder / "provenance.json").read_bytes())
            self.assertEqual((provenance["source_channels"], provenance["source_frames"], provenance["source_sample_rate"]), (1, 160, 16000))
            self.assertIn("no mixing", provenance["channel_preparation"])
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
            with patch.object(fresh, "convert", side_effect=conversion), patch.object(fresh, "converter_version", return_value="fixture"):
                case = fresh.prepare(acquisition, source, "new reference", "session-case", "en", info, "wav")
            self.assertEqual(case["session_id"], "published:session-1")
            with patch.object(fresh, "convert") as convert:
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(b"\x02\x00" * 160), "other reference", "different-case", "en",
                                               dict(metadata(), source_id="other-source", session_id="published:session-1"), "wav"))
                convert.assert_not_called()

    def test_new_known_speaker_is_reserved_before_any_heldout_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); acquisition = fresh.Acquisition(root, fresh.Exclusions())
            source = wav_bytes()
            def conversion(_acquisition, _source, target, _maximum):
                target.write_bytes(source)
                return ["fixture conversion"]
            with patch.object(fresh, "convert", side_effect=conversion), patch.object(fresh, "converter_version", return_value="fixture"):
                self.assertIsNotNone(fresh.prepare(acquisition, source, "development reference", "dev-speaker", "de-CH",
                                                  metadata("new-known-speaker"), "wav"))
            heldout_metadata = dict(metadata("new-known-speaker"), evaluation_split="held_out", source_id="different-published-source")
            with patch.object(fresh, "convert") as convert:
                self.assertIsNone(fresh.prepare(acquisition, wav_bytes(b"\x02\x00" * 160), "different opaque reference", "held-speaker",
                                                "de-CH", heldout_metadata, "wav"))
                convert.assert_not_called()
            self.assertEqual(acquisition.skipped["speaker"], 1)
            self.assertFalse((root / "held_out").exists())

    def test_duration_and_flac_header_bounds_are_checked_without_decoding(self):
        packed = (16000 << 44) | (15 << 36) | 32000
        info = bytes(10) + packed.to_bytes(8, "big") + bytes(16)
        self.assertEqual(fresh.source_frames(b"fLaC\x80\x00\x00\x22" + info, "flac"), (32000, 16000))
        with self.assertRaisesRegex(ValueError, "STREAMINFO"): fresh.source_frames(b"not flac", "flac")
        with tempfile.TemporaryDirectory() as directory:
            acquisition = fresh.Acquisition(Path(directory).resolve(), fresh.Exclusions())
            with patch.object(fresh, "source_layout", return_value=(61 * 16000, 16000, 1)), patch.object(fresh, "convert") as convert:
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

    def test_separate_counts_version_and_initial_budgets_validate_without_acquisition(self):
        required = ["--output", "/tmp/new-corpus", "--exclude-manifest", "/tmp/prior.json"]
        old = fresh.arguments(required + ["--count", "4"])
        self.assertEqual((old.count, old.heldout_count, old.corpus_version, old.max_network_mib, old.max_output_mib),
                         (4, 4, fresh.DEFAULT_CORPUS_VERSION, 256, 256))
        new = fresh.arguments(required + ["--heldout-count", "16", "--corpus-version", "round3-corpus-20261106-v1",
                                          "--max-network-mib", "512", "--max-output-mib", "512"])
        self.assertEqual((new.count, new.heldout_count, new.max_network_mib, new.max_output_mib), (8, 16, 512, 512))
        exclusions = fresh.Exclusions()
        exclusions.add({"id": "consumed-round2", "source_id": "old-source", "speaker_ids": ["used-speaker"]})
        plan = fresh.selection_plan(new, exclusions)
        self.assertEqual(plan["planned_cases"], {"development": 72, "held_out": 144})
        self.assertIsNone(plan["count_per_language_per_split"])
        self.assertEqual(plan["network_cap_bytes"], 512 * 1024 * 1024)
        self.assertEqual(plan["protected_output_cap_bytes"], 512 * 1024 * 1024)
        self.assertEqual(plan["swiss_prefix_cap_bytes"], 32 * 1024 * 1024)
        self.assertIn("consumed-round2", plan["prior_exclusions"]["id"])
        self.assertIn("used-speaker", plan["prior_exclusions"]["speaker"])
        for flags in [["--count", "9"], ["--heldout-count", "17"], ["--heldout-count", "0"],
                      ["--corpus-version", "../replace"], ["--corpus-version", "a" * 129],
                      ["--max-network-mib", "513"], ["--max-output-mib", "1024"]]:
            with self.subTest(flags=flags), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                fresh.arguments(required + flags)

    def test_mono_header_policy_refuses_silent_channel_mixing_before_conversion(self):
        stereo = io.BytesIO()
        with wave.open(stereo, "wb") as audio:
            audio.setnchannels(2); audio.setsampwidth(2); audio.setframerate(16000); audio.writeframes(b"\x01\x00\x02\x00" * 160)
        original = stereo.getvalue()
        self.assertEqual(fresh.source_layout(original, "wav"), (160, 16000, 2))
        packed = (16000 << 44) | (1 << 41) | (15 << 36) | 32000
        flac = b"fLaC\x80\x00\x00\x22" + bytes(10) + packed.to_bytes(8, "big") + bytes(16)
        self.assertEqual(fresh.source_layout(flac, "flac"), (32000, 16000, 2))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); acquisition = fresh.Acquisition(root, fresh.Exclusions())
            with patch.object(fresh, "convert") as convert, patch.object(fresh, "converter_version") as version:
                self.assertIsNone(fresh.prepare(acquisition, original, "opaque", "stereo", "en", metadata(), "wav"))
                convert.assert_not_called(); version.assert_not_called()
            self.assertEqual(acquisition.skipped["unsupported_source_channels"], 1)
            self.assertEqual(list(root.iterdir()), [])
            self.assertEqual(stereo.getvalue(), original)

    def test_larger_prospective_caps_keep_defaults_and_enforce_remaining_network_bytes(self):
        required = ["--output", "/tmp/new-corpus", "--exclude-manifest", "/tmp/prior.json"]
        default = fresh.arguments(required)
        self.assertEqual((default.archive_prefix_mib, default.max_network_mib), (32, 256))
        larger = fresh.arguments(required + ["--archive-prefix-mib", "128", "--max-network-mib", "2048"])
        plan = fresh.selection_plan(larger, fresh.Exclusions())
        self.assertEqual(plan["archive_stream_cap_bytes"], 128 * 1024 * 1024)
        self.assertEqual(plan["swiss_prefix_cap_bytes"], 128 * 1024 * 1024)
        self.assertEqual(plan["network_cap_bytes"], 2048 * 1024 * 1024)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions(), maximum_network_bytes=2048 * 1024 * 1024,
                                             archive_prefix_mib=128)
            self.assertEqual(acquisition.maximum_archive_bytes, 128 * 1024 * 1024)
            acquisition.network_bytes = acquisition.maximum_network_bytes - 2
            source = io.BytesIO(b"abcdef")
            self.assertEqual(acquisition.read(source, 99), b"ab")
            with self.assertRaisesRegex(ValueError, "network budget"):
                acquisition.read(source, 1)
            self.assertEqual(source.tell(), 2)
            for invalid in (0, 31, 129, True, 32.0):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    fresh.Acquisition(root, fresh.Exclusions(), archive_prefix_mib=invalid)

    def test_version_helper_has_cancel_timeout_output_bounds_and_caches_success(self):
        with tempfile.TemporaryDirectory() as directory:
            acquisition = fresh.Acquisition(Path(directory).resolve(), fresh.Exclusions())
            child = Mock(); child.poll.return_value = None
            with patch.object(acquisition, "check", side_effect=[None, InterruptedError("canceled")]), \
                 patch.object(fresh.subprocess, "Popen", return_value=child):
                with self.assertRaises(InterruptedError): fresh.run_bounded(acquisition, ["fixture-version"], 5, capture=True)
            child.terminate.assert_called_once(); child.wait.assert_called_once_with(timeout=2)
            child = Mock(); child.poll.return_value = None
            with patch.object(acquisition, "check"), patch.object(fresh.time, "monotonic", side_effect=[0, 6]), \
                 patch.object(fresh.subprocess, "Popen", return_value=child):
                with self.assertRaises(TimeoutError): fresh.run_bounded(acquisition, ["fixture-version"], 5, capture=True)
            child.terminate.assert_called_once()
            def noisy(_command, stdout, stderr):
                stdout.write(b"x" * 65537); stdout.flush()
                stopped = Mock(); stopped.poll.return_value = 0; stopped.returncode = 0
                return stopped
            with patch.object(fresh.subprocess, "Popen", side_effect=noisy):
                with self.assertRaisesRegex(ValueError, "log byte budget"):
                    fresh.run_bounded(acquisition, ["fixture-version"], 5, capture=True)
            with patch.object(fresh, "run_bounded", return_value=b"fixture converter 1.0\nother line\n") as run:
                self.assertEqual(fresh.converter_version(acquisition), "fixture converter 1.0")
                self.assertEqual(fresh.converter_version(acquisition), "fixture converter 1.0")
                run.assert_called_once_with(acquisition, ["ffmpeg", "-version"], timeout=5, capture=True)

    def test_explicit_512_mib_budgets_remain_finite_without_dynamic_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            acquisition = fresh.Acquisition(root, fresh.Exclusions(), maximum_network_bytes=512 * 1024 * 1024,
                                            maximum_output_bytes=512 * 1024 * 1024)
            acquisition.network_bytes = 512 * 1024 * 1024 - 2
            source = io.BytesIO(b"abcdef")
            self.assertEqual(acquisition.read(source, 100), b"ab")
            with self.assertRaisesRegex(ValueError, "network budget"): acquisition.read(source, 1)
            acquisition.network_bytes = 0; acquisition.output_bytes = 496 * 1024 * 1024
            with self.assertRaisesRegex(ValueError, "output byte budget"): acquisition.save(root / "oversized", b"x")
            self.assertEqual(acquisition.maximum_output_bytes, 512 * 1024 * 1024)
            with self.assertRaisesRegex(ValueError, "initial 256 or 512"):
                fresh.Acquisition(root, fresh.Exclusions(), maximum_network_bytes=513 * 1024 * 1024)

    def run_metadata_only_main(self, root, partial=False, languages=None):
        prior = root / "prior-consumed-round2.json"
        prior.write_text(json.dumps({"cases": [{"id": "round2-old", "source_id": "round2:source", "reference": "/not/opened",
                                                "reference_sha256": "old-reference", "speaker_ids": ["round2-speaker"]}]}))
        output = root / "new"
        calls = []
        def fleurs(acquisition, language, count, heldout):
            calls.append((language, count, heldout))
            split = "held_out" if heldout else "development"
            for number in range(count - (1 if partial and heldout and language == "en" else 0)):
                acquisition.cases.append({"id": f"fixture-{split}-{language}-{number}", "language": language, "split": split, "reviewed": False})
        def swiss(acquisition, development_count, heldout_count):
            calls.append(("de-CH", development_count, heldout_count))
            for split, count in [("development", development_count), ("held_out", heldout_count)]:
                acquisition.cases += [{"id": f"fixture-{split}-de-CH-{n}", "language": "de-CH", "split": split, "reviewed": False} for n in range(count)]
        args = ["--output", str(output), "--exclude-manifest", str(prior), "--count", "8", "--heldout-count", "16",
                "--corpus-version", "round3-corpus-20261106-v1", "--max-network-mib", "512", "--max-output-mib", "512"]
        if languages is not None: args += ["--languages", languages]
        with patch.object(fresh.Acquisition, "fetch", return_value=b"fixture source metadata"), \
             patch.dict(fresh.SOURCE_HASHES, {"card": fresh.sha(b"fixture source metadata")}), \
             patch.object(fresh, "fleurs", side_effect=fleurs), patch.object(fresh, "swiss", side_effect=swiss), \
             patch.object(fresh.signal, "signal"), redirect_stdout(io.StringIO()):
            if partial:
                with self.assertRaises(SystemExit): fresh.main(args)
            else: fresh.main(args)
        return output, calls

    def test_main_dispatches_and_retains_separate_frozen_targets_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); output, calls = self.run_metadata_only_main(root)
            plan = json.loads((output / "selection-plan.original.json").read_bytes())
            acquisition = json.loads((output / "acquisition.json").read_bytes())
            self.assertEqual(plan["planned_cases"], {"development": 72, "held_out": 144})
            self.assertEqual(acquisition["network_bytes"], 0)
            self.assertEqual(acquisition["counts_per_language"], {"development": 8, "held_out": 16})
            self.assertEqual(acquisition["excluded_counts"]["speaker"], 1)
            self.assertEqual([x["cases"] for x in acquisition["manifests"]], [72, 144])
            self.assertTrue(all(count == (16 if held else 8) for language, count, held in calls if language != "de-CH"))
            self.assertEqual(calls[-1], ("de-CH", 8, 16))
            for split, count, suffix in [("development", 72, "dev-validation"), ("held_out", 144, "fresh-heldout")]:
                manifest = json.loads((output / split / "manifest.exploratory.legacy.json").read_bytes())
                self.assertEqual(len(manifest["cases"]), count)
                self.assertEqual(manifest["corpus_version"], "round3-corpus-20261106-v1-" + suffix)
                self.assertFalse(manifest["reference_displayed_to_ai"])
                self.assertEqual(manifest["human_review"], "not_performed")

    def test_partial_heldout_never_reduces_target_or_reports_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output, _ = self.run_metadata_only_main(Path(directory).resolve(), partial=True)
            acquisition = json.loads((output / "acquisition.json").read_bytes())
            heldout = next(x for x in acquisition["manifests"] if x["split"] == "held_out")
            self.assertEqual((heldout["cases"], heldout["planned_cases"]), (143, 144))
            self.assertTrue((output / "held_out/NOT-FOR-DEVELOPMENT.txt").exists())

    def test_swiss_only_completion_never_reacquires_other_languages_or_reduces_requested_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            output, calls = self.run_metadata_only_main(Path(directory).resolve(), languages="de-CH")
            self.assertEqual(calls, [("de-CH", 8, 16)])
            plan = json.loads((output / "selection-plan.original.json").read_bytes())
            self.assertEqual(plan["languages"], ["de-CH"])
            self.assertEqual(plan["planned_cases"], {"development": 8, "held_out": 16})
            self.assertFalse(json.loads((output / "held_out/manifest.exploratory.legacy.json").read_bytes())["frozen"])
        for languages in ("", "en,en", "en,unknown", "en,"):
            with self.subTest(languages=languages), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                fresh.arguments(["--output", "/tmp/new", "--exclude-manifest", "/tmp/prior", "--languages", languages])


if __name__ == "__main__":
    unittest.main()
