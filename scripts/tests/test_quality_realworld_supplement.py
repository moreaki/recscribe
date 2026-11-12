import importlib.util
import copy
import csv
from decimal import Decimal
import io
import json
from pathlib import Path
import unittest
from unittest import mock
import tempfile
import wave
import zipfile

SPEC = importlib.util.spec_from_file_location("meeting_supplement", Path(__file__).resolve().parents[1] / "quality/prepare-realworld-supplement.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def annotation(tiers):
    lines = ['File type = "ooTextFile"', 'Object class = "TextGrid"', 'item []:']
    for number, (speaker, intervals) in enumerate(tiers, 1):
        lines += [f' item [{number}]:', '  class = "IntervalTier"', f'  name = "{speaker}"']
        for index, (start, end, text) in enumerate(intervals, 1):
            escaped = text.replace('"', '""')
            lines += [f'  intervals [{index}]:', f'   xmin = {start}', f'   xmax = {end}', f'   text = "{escaped}"']
    return ('\n'.join(lines) + '\n').encode()


def audio_bytes(channels=1, frames=96000):
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setparams((channels, 2, 16000, 0, "NONE", "not compressed"))
        wav.writeframes((b"\x01\x00" if channels == 1 else b"\x01\x00\x02\x00") * frames)
    return output.getvalue()


def source(language="zh"):
    return dict(language=language, source_url="https://huggingface.co/datasets/fixture/corpus", license="synthetic fixture",
                variety="synthetic", script="Hans" if language == "zh" else "Latn", conditions=["synthetic test"],
                source_use_review="pending", dataset="fixture/corpus", revision="a" * 40)


def budgets():
    return dict(timeout_seconds=30, network_bytes=1024 ** 2, output_bytes=64 * 1024 ** 2)


def meeting_plan(root):
    original, text = root / "original.wav", root / "original.TextGrid"
    original.write_bytes(audio_bytes(channels=2))
    text.write_bytes(annotation([("001-M", [(0, 6, "保留原文，不是别的。")])]))
    item = dict(id="meeting-one", source_id="fixture:meeting-one", source_group_ids=["fixture:session-one"],
                session_id="fixture:session-one", split="held_out", audio=str(original), audio_bytes=original.stat().st_size,
                audio_sha256=MODULE.sha(original), annotation=str(text), annotation_sha256=MODULE.sha(text), channel=1)
    return dict(schema_version="realworld-supplement-v1", kind="aishell4", corpus_version="synthetic-meetings-v1",
                source=source(), budgets=budgets(), cases=[item])


def zip_plan(root, duplicate=False):
    text, name = "Olá, não vinte.", "audio/original.wav"
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name, audio_bytes())
        if duplicate:
            # Explicitly create an ambiguous source fixture; never suppress a
            # warning from production preparation.
            with __import__("warnings").catch_warnings():
                __import__("warnings").simplefilter("ignore", UserWarning)
                archive.writestr(name, audio_bytes(frames=80000))
    data = output.getvalue()
    csv_output = io.StringIO(newline="")
    writer = csv.DictWriter(csv_output, fieldnames=["file_path", "text", "speech_style"])
    writer.writeheader(); writer.writerow(dict(file_path=name, text=text, speech_style="synthetic"))
    metadata = root / "metadata.csv"
    metadata.write_bytes(csv_output.getvalue().encode())
    plan = dict(schema_version="realworld-supplement-v1", kind="coraa", corpus_version="synthetic-coraa-v1",
                source=source("pt"), budgets=budgets(), metadata=str(metadata), metadata_bytes=metadata.stat().st_size,
                metadata_sha256=MODULE.sha(metadata), metadata_remote_path="metadata/test.csv",
                archive=dict(path="audio/test.zip", bytes=len(data), etag="b" * 64),
                cases=[dict(id="zip-one", source_id="fixture:zip-one", source_group_ids=["fixture:recording-one"],
                            session_id=None, split="held_out", member=name)])
    return plan, data, text


def acquisition(root):
    root.mkdir()
    return MODULE.rw.Acquisition(root, {"budgets": budgets()}, MODULE.rw.Exclusions(), priority_probe=None)


def converter(_acquisition, command, _timeout, capture=False, target=None, maximum_bytes=None):
    if capture:
        return b"ffmpeg synthetic fixture\n"
    duration = Decimal(command[command.index("-t") + 1])
    target.write_bytes(audio_bytes(frames=int(duration * 16000)))


class MeetingAnnotationTests(unittest.TestCase):
    def test_unicode_and_quoted_original_reference_is_preserved(self):
        original = '数字十三，不是三十。 "quote"'
        rows = MODULE.textgrid(annotation([("001-M", [(0, 6, original)])]))
        self.assertEqual(rows[0]["text"], original)
        self.assertEqual(rows[0]["start"], Decimal(0))
        self.assertEqual(rows[0]["speaker"], "001-M")

    def test_overlapping_other_speaker_is_not_a_single_speaker_reference(self):
        rows = MODULE.textgrid(annotation([
            ("001-M", [(0, 6, "first"), (10, 16, "later")]),
            ("002-F", [(2, 4, "overlap")])]))
        self.assertEqual(MODULE.choose_interval(rows)["text"], "later")

    def test_empty_pause_does_not_hide_an_actual_overlapping_speaker(self):
        rows = MODULE.textgrid(annotation([
            ("001-M", [(0, 6, "spoken")]), ("002-F", [(0, 6, "")])]))
        self.assertEqual(MODULE.choose_interval(rows)["text"], "spoken")

    def test_reversed_nan_and_missing_annotation_fields_fail(self):
        for start, end in ((6, 0), (0, "NaN"), (-1, 6)):
            with self.assertRaises(MODULE.rw.Failure):
                MODULE.textgrid(annotation([("speaker", [(start, end, "words")])]))
        raw = annotation([("speaker", [(0, 6, "words")])]).replace(b"   xmax = 6\n", b"")
        with self.assertRaises(MODULE.rw.Failure):
            MODULE.textgrid(raw)

    def test_long_or_uncertain_boundary_is_pending_without_text_truncation(self):
        rows = MODULE.textgrid(annotation([("speaker", [(0, 61, "all original words")])]))
        with self.assertRaises(MODULE.rw.Failure):
            MODULE.choose_interval(rows)

    def test_multiline_reference_is_preserved_and_unterminated_is_rejected(self):
        raw = annotation([("speaker", [(0, 6, "words")])]).replace(b'"words"', b'"first\nsecond"')
        self.assertEqual(MODULE.textgrid(raw)[0]["text"], "first\nsecond")
        with self.assertRaises(MODULE.rw.Failure):
            MODULE.textgrid(raw.replace(b'second"', b'second'))

    def test_preparation_retains_original_reference_channel_and_timing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = root / "original.wav"
            with wave.open(str(original), "wb") as wav:
                wav.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
                wav.writeframes(b"\x01\x00\x02\x00" * 96000)
            original_hash = MODULE.sha(original)
            output = root / "prepared"; output.mkdir()
            acquisition = MODULE.rw.Acquisition(output, {"budgets": {"timeout_seconds": 30, "network_bytes": 1024 ** 2, "output_bytes": 16 * 1024 ** 2}}, MODULE.rw.Exclusions(), priority_probe=None)
            case = dict(id="meeting-one", source_id="publisher:one", published_source_id="one.wav", source_group_ids=["publisher:session-one"],
                        session_id="publisher:session-one", speaker_ids=[], split="held_out")
            source = dict(language="zh", source_url="https://example.test/pinned", license="synthetic", variety="synthetic", script="Hans", conditions=["synthetic test"])
            def convert(acquisition, command, timeout, capture=False, target=None, maximum_bytes=None):
                if capture: return b"ffmpeg synthetic test\n"
                with wave.open(str(target), "wb") as wav:
                    wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    wav.writeframes(b"\x02\x00" * 64000)
            reference = "保留原文".encode()
            with mock.patch.object(MODULE.rw, "run_bounded", side_effect=convert):
                actual = MODULE.corpus(acquisition, case, source, original, reference, Decimal(1), Decimal(5), 1, original_hash)
            self.assertEqual(actual["source_interval_seconds"], ["1", "5"])
            self.assertEqual(actual["original_source_channel"], 1)
            self.assertEqual(actual["source_channel"], 0)
            self.assertEqual(Path(actual["reference"]).read_bytes(), reference)
            self.assertEqual(MODULE.sha(original), original_hash)
            self.assertFalse(actual["reviewed"])
            self.assertFalse(actual["independent_speaker_units_verified"])
            self.assertIn("Local tier labels are not global", actual["grouping_review"])
            self.assertEqual(acquisition.cases, [actual])

    def test_parser_and_selection_poll_cancellation_and_enforce_record_bound(self):
        raw = annotation([("001", [(i * 10, i * 10 + 6, "words") for i in range(10)])])
        def stop():
            raise InterruptedError("fixture cancellation")
        with self.assertRaises(InterruptedError):
            MODULE.textgrid(raw, stop)
        rows = MODULE.textgrid(raw)
        with self.assertRaises(InterruptedError):
            MODULE.choose_interval(rows, stop)
        with mock.patch.object(MODULE, "MAX_INTERVALS", 4):
            with self.assertRaisesRegex(MODULE.rw.Failure, "annotation_interval_count"):
                MODULE.textgrid(raw)
        self.assertLessEqual(MODULE.MAX_INTERVALS, 10000)

    def test_duplicate_local_tiers_and_same_tier_overlap_are_ambiguous(self):
        for tiers in [[("001", [(0, 6, "first")]), ("001", [(2, 8, "other")])],
                      [("001", [(0, 6, "first"), (2, 8, "other")])]]:
            with self.subTest(tiers=tiers), self.assertRaises(MODULE.rw.Failure):
                MODULE.textgrid(annotation(tiers))

    def test_reference_cap_is_enforced_before_output_or_conversion(self):
        with mock.patch.object(MODULE.rw, "MAX_REFERENCE", 8):
            with self.assertRaisesRegex(MODULE.rw.Failure, "reference_size_bound"):
                MODULE.textgrid(annotation([("001", [(0, 6, "too many reference words")])]))

    def test_sweep_rejects_long_earlier_overlap_and_accepts_adjacent_boundaries(self):
        rows = MODULE.textgrid(annotation([
            ("001", [(0, 40, "long earlier speaker")]),
            ("002", [(10, 16, "overlap"), (40, 46, "adjacent clear")])]))
        self.assertEqual(MODULE.choose_interval(rows)["text"], "adjacent clear")

    def test_full_meeting_run_retains_annotation_exact_reference_and_unknown_people(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            plan = meeting_plan(root)
            plan_path = root / "plan.json"; plan_path.write_text(json.dumps(plan))
            before_audio = Path(plan["cases"][0]["audio"]).read_bytes()
            before_annotation = Path(plan["cases"][0]["annotation"]).read_bytes()
            output = root / "prepared"
            original_acquisition = MODULE.rw.Acquisition
            def factory(*args):
                return original_acquisition(*args, priority_probe=None)
            with mock.patch.object(MODULE.rw, "Acquisition", side_effect=factory), mock.patch.object(MODULE.rw, "run_bounded", side_effect=converter), mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(MODULE.run(plan_path, output, []), 0)
            receipt = json.loads((output / "preparation.receipt.json").read_text())
            self.assertEqual((receipt["status"], receipt["completed_cases"]), ("completed", 1))
            case = json.loads((output / "held_out.corpus.json").read_text())["cases"][0]
            self.assertEqual(case["speaker_ids"], [])
            self.assertEqual(case["published_local_speaker_label"], "001-M")
            self.assertFalse(case["independent_speaker_units_verified"])
            self.assertEqual(Path(case["reference"]).read_bytes(), "保留原文，不是别的。".encode())
            self.assertEqual(Path(case["original_annotation"]).read_bytes(), before_annotation)
            self.assertEqual(Path(case["source_annotation"]).read_bytes(), before_annotation)
            self.assertEqual(Path(case["original_audio"]).read_bytes(), before_audio)
            provenance = json.loads(Path(case["provenance"]).read_text())
            self.assertFalse(provenance["channel_mixing"])
            self.assertFalse(provenance["human_approval"])
            self.assertIn("pan=mono|c0=c1", provenance["preparation_command"])
            self.assertEqual(case["source_interval_seconds"], ["0", "6"])
            self.assertEqual(case["original_source_channel"], 1)
            self.assertEqual(provenance["reference_source"]["original_annotation_sha256"], plan["cases"][0]["annotation_sha256"])

    def test_resource_meeting_never_opens_or_requires_annotation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = meeting_plan(root)
            item = plan["cases"][0]; item["split"] = "resource"
            del item["annotation"], item["annotation_sha256"]
            MODULE.validate_plan(plan)
            state = acquisition(root / "prepared")
            with mock.patch.object(MODULE, "corpus") as prepared:
                MODULE.meetings(state, plan)
            self.assertIsNone(prepared.call_args.args[4])
            self.assertEqual(prepared.call_args.args[5:7], (None, None))
            self.assertIsNone(prepared.call_args.kwargs["annotation_snapshot"])

    def test_coraa_uses_pinned_etag_and_retains_metadata_and_member_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan, raw_zip, reference = zip_plan(root)
            MODULE.validate_plan(plan)
            state = acquisition(root / "prepared"); remote = io.BytesIO(raw_zip)
            with mock.patch.object(MODULE.rw, "RangeFile", return_value=remote) as range_file, mock.patch.object(MODULE.rw, "run_bounded", side_effect=converter):
                MODULE.coraa(state, plan)
            self.assertTrue(remote.closed)
            range_file.assert_called_once_with(state, "https://huggingface.co/datasets/fixture/corpus/resolve/" + "a" * 40 + "/audio/test.zip", len(raw_zip), "b" * 64)
            actual = state.cases[0]
            self.assertEqual(Path(actual["reference"]).read_bytes(), reference.encode())
            self.assertEqual(Path(actual["original_audio"]).read_bytes(), audio_bytes())
            self.assertEqual(Path(actual["published_metadata"]).read_bytes(), Path(plan["metadata"]).read_bytes())
            self.assertFalse(actual["remote_archive"]["whole_file_sha256_verified"])
            self.assertFalse(actual["reviewed"])
            self.assertEqual(actual["speaker_ids"], [])
            self.assertEqual(actual["source_interval_seconds"], ["0", "6"])
            self.assertIn("/resolve/" + "a" * 40, actual["published_metadata_remote_url"])

    def test_duplicate_zip_member_is_rejected_before_saving_an_audio_member(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan, raw_zip, _ = zip_plan(root, duplicate=True)
            state = acquisition(root / "prepared"); remote = io.BytesIO(raw_zip)
            with mock.patch.object(MODULE.rw, "RangeFile", return_value=remote), mock.patch.object(MODULE.rw, "run_bounded") as helper:
                with self.assertRaisesRegex(MODULE.rw.Failure, "ambiguous_or_missing_zip_member"):
                    MODULE.coraa(state, plan)
            self.assertTrue(remote.closed)
            self.assertFalse((state.root / "originals/audio/original.wav").exists())
            self.assertEqual(state.cases, [])
            helper.assert_not_called()

    def test_pinned_archive_and_metadata_invalid_plans_fail_before_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan, _, _ = zip_plan(root)
            mutations = [("source", "revision", "main"), ("archive", "url", "https://huggingface.co/unpinned.zip"),
                         ("archive", "etag", "weak"), ("archive", "bytes", True), ("archive", "path", "../outside.zip"),
                         ("source", "source_use_review", "approved"), (None, "metadata_remote_path", "../metadata.csv"),
                         (None, "metadata_bytes", MODULE.MAX_METADATA + 1)]
            for section, key, value in mutations:
                candidate = copy.deepcopy(plan)
                (candidate[section] if section else candidate)[key] = value
                path = root / "plan.json"; path.write_text(json.dumps(candidate))
                with self.subTest(section=section, key=key), self.assertRaises(MODULE.rw.Failure):
                    MODULE.run(path, root / "must-not-exist", [])
                self.assertFalse((root / "must-not-exist").exists())

    def test_reused_source_groups_or_invented_global_speakers_fail_preflight(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = meeting_plan(root)
            other = dict(plan["cases"][0], id="meeting-two", source_id="fixture:meeting-two", audio_sha256="c" * 64)
            plan["cases"].append(other)
            with self.assertRaisesRegex(MODULE.rw.Failure, "source_groups_not_disjoint"):
                MODULE.validate_plan(plan)
            plan["cases"] = plan["cases"][:1]
            plan["cases"][0]["speaker_ids"] = ["invented-global-person-001"]
            with self.assertRaisesRegex(MODULE.rw.Failure, "global_speaker_identity_unverified"):
                MODULE.validate_plan(plan)

    def test_helper_failure_or_cancellation_keeps_originals_and_failed_receipt(self):
        for error, status in [(MODULE.rw.Failure("synthetic_helper_failed"), "failed"), (InterruptedError("fixture_cancelled"), "cancelled")]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve(); plan = meeting_plan(root)
                source_path = Path(plan["cases"][0]["audio"]); before = source_path.read_bytes()
                path = root / "plan.json"; path.write_text(json.dumps(plan)); output = root / "prepared"
                original_acquisition = MODULE.rw.Acquisition
                def factory(*args):
                    return original_acquisition(*args, priority_probe=None)
                def fail_helper(_a, _command, _timeout, **kwargs):
                    if kwargs.get("target"):
                        kwargs["target"].write_bytes(b"retained incomplete PCM")
                    raise error
                with mock.patch.object(MODULE.rw, "Acquisition", side_effect=factory), mock.patch.object(MODULE.rw, "run_bounded", side_effect=fail_helper), mock.patch("sys.stdout", new=io.StringIO()):
                    self.assertEqual(MODULE.run(path, output, []), 1)
                receipt = json.loads((output / "preparation.receipt.json").read_text())
                self.assertEqual(receipt["status"], status)
                self.assertEqual(receipt["completed_cases"], 0)
                self.assertFalse(receipt["human_approval"])
                self.assertEqual(source_path.read_bytes(), before)
                self.assertEqual((output / "held_out/meeting-one/benchmark.pcm16.wav").read_bytes(), b"retained incomplete PCM")
                with self.assertRaises(FileExistsError):
                    MODULE.run(path, output, [])

    def test_converter_source_mutation_is_detected_without_scoring_or_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); plan = meeting_plan(root); state = acquisition(root / "prepared")
            def alter_input(acq, command, timeout, **kwargs):
                converter(acq, command, timeout, **kwargs)
                Path(plan["cases"][0]["audio"]).write_bytes(b"unexpected source mutation")
            with mock.patch.object(MODULE.rw, "run_bounded", side_effect=alter_input):
                with self.assertRaisesRegex(MODULE.rw.Failure, "original_audio_changed"):
                    MODULE.meetings(state, plan)
            self.assertEqual(state.cases, [])
