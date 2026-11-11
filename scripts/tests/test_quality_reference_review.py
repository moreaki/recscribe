"""Reference packet contracts using generated local evidence only.

No real corpora, recognition processes, playback, providers or UI are involved.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import wave


SCRIPT = Path(__file__).resolve().parents[1] / "quality/reference-review.py"
SPEC = importlib.util.spec_from_file_location("reference_review", SCRIPT)
REVIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REVIEW)
POLICY = "unicode-nfc-apostrophe-v2"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_bytes(REVIEW.encoded(value))


class Fixture:
    """A self-contained, immutable original corpus/job plus editable review copy."""
    def __init__(self, root, tag, mode="auto", amplitude=None, corpus_reviewed=False,
                 with_entries=True):
        self.tag = tag
        self.root = Path(root) / tag
        self.root.mkdir()
        self.job = self.root / "job"
        self.job.mkdir()
        self.audio = self.root / "source.wav"
        self.reference = self.root / "reference.original.txt"
        self.manifest = self.root / "corpus.json"
        self.packet = self.root / "review.json"
        self.raw = self.job / "asr-channel-0.json"
        self.profile = self.job / "asr-channel-0.profile.json"
        self.runtime = self.root / "runtime.bin"
        self.model = self.root / "model.bin"
        # File identities are real even though no executable/model is run.
        self.runtime.write_bytes(b"synthetic unchanged runtime asset")
        self.model.write_bytes(b"synthetic unchanged model asset")
        sample = amplitude if amplitude is not None else 100 + sum(tag.encode())
        with wave.open(str(self.audio), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(sample.to_bytes(2, "little", signed=True) * 64000)
        self.reference.write_text(f"Published original {tag} first. Published original {tag} second.", encoding="utf-8")
        self.case_id = f"case-{tag}"
        source_sha = sha(self.audio.read_bytes())
        case = {"id": self.case_id, "category": "generated-test", "language": "en",
                "task": "transcription", "split": "development", "reviewed": corpus_reviewed,
                "audio": str(self.audio), "reference": str(self.reference),
                "sha256": source_sha, "reference_sha256": sha(self.reference.read_bytes()),
                "duration_seconds": 4.0, "source_channel": 0,
                "source_id": f"source-{tag}", "speaker_ids": [], "session_id": None,
                "license": "generated unit-test fixture; not an external licence claim",
                "scoring_policy": POLICY}
        write_json(self.manifest, {"schema_version": "2.0", "corpus_version": "synthetic-only-v1",
                                   "frozen": True, "cases": [case]})
        profile = {"schema_version": "1.0", "context_tokens": 0, "temperature": 0,
                   "no_fallback": False, "speech": {"mode": "none"}, "language_policy": "current_auto"}
        write_json(self.profile, profile)
        engine = {"engine": "whisper.cpp", "version": "synthetic-test",
                  "model_sha256": sha(self.model.read_bytes()),
                  "binary_sha256": sha(self.runtime.read_bytes()),
                  "asr_language": mode, "detected_language": "en", "local_only": True,
                  "decoding": {"profile": profile, "profile_sha256": sha(self.profile.read_bytes())},
                  "speech": {"configuration": {"mode": "none"}}, "vad_model_sha256": None,
                  "command": [str(self.runtime), "-m", str(self.model), "-f", str(self.job / "working-channel-0.wav"),
                              "-l", mode, "-ojf", "-of", str(self.raw.with_suffix("")), "-t", "2", "-tp", "0", "-mc", "0"]}
        entries = []
        if with_entries:
            for number, (start, end) in enumerate([(0, 1500), (2000, 3500)]):
                text = f"Original recognition {tag} {number}"
                entries.append({"text": text, "offsets": {"from": start, "to": end},
                                "tokens": [{"text": text, "id": 100 + number, "p": 0.7}]})
        write_json(self.raw, {"model": {"type": "synthetic", "ftype": 0},
                              "params": {"model": str(self.model), "language": mode, "translate": False},
                              "result": {"language": "en"}, "transcription": entries})
        source = {"path": str(self.audio), "sha256": source_sha, "duration_ms": 4000,
                  "sample_rate": 16000, "channels": 1, "frames": 64000,
                  "bit_depth": 16, "channels_bit_identical": True}
        segments = [{"id": f"seg-{number + 1:06d}", "channel": 0,
                     "start_ms": entry["offsets"]["from"], "end_ms": entry["offsets"]["to"],
                     "source_text": entry["text"], "confidence": None,
                     "needs_review": True, "review_reasons": ["confidence_unavailable"]}
                    for number, entry in enumerate(entries)]
        write_json(self.job / "transcript.json", {"schema_version": "1.0", "status": "completed_with_review",
                    "source": source, "segments": segments, "review_reasons": [],
                    "processing": {"source_language": mode, "mode": "verbatim", "profile": "fast", "engine_passes": [engine]}})
        write_json(self.job / "audio-report.json", source)
        write_json(self.job / "transcript.raw.json", {"schema_version": "1.0", "kind": "immutable_engine_output_index",
                    "outputs": [{"channel": 0, "role": "primary", "status": "produced", "path": self.raw.name,
                                 "sha256": sha(self.raw.read_bytes()), "provenance": engine}]})
        artifacts = {path.name: {"sha256": sha(path.read_bytes()), "size_bytes": path.stat().st_size}
                     for path in self.job.iterdir()}
        write_json(self.job / "manifest.json", {"schema_version": "1.0", "state": "completed_with_review",
                    "source_path": str(self.audio), "options": {"source_language": mode, "mode": "verbatim", "profile": "fast"},
                    "artifacts": artifacts, "working_audio_retained": False})
        self.originals = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}

    def prepare(self):
        return REVIEW.prepare(self.manifest, self.case_id, self.job, POLICY, self.packet)

    def assert_originals_unchanged(self, testcase):
        for path, expected in self.originals.items():
            testcase.assertEqual(path.read_bytes(), expected, str(path))


def approval():
    return {"status": "approved", "reviewer": "Synthetic human-review fixture",
            "reviewedAt": "2026-11-11T10:00:00Z", "evidence": "Synthetic review record for contract tests only"}


def approve(fixture, split):
    """Test-only explicit review mutation; preparation never calls this."""
    packet = json.loads(fixture.packet.read_text())
    review = packet["review"]
    review.update(permission=approval(), grouping=approval(), scope=approval(), recordingID=f"recording-{fixture.tag}",
                  sessionID=f"session-{fixture.tag}", speakerIDs=[f"speaker-{fixture.tag}"],
                  sourceIDs=packet["bindings"]["requiredSourceIDs"], split=split)
    for number, segment in enumerate(review["segments"]):
        segment.update(referenceText=f"Reviewed truth {fixture.tag} segment {number}", disposition="speech",
                       lexical=approval(), alignment=approval())
    for gap in review["gaps"]:
        gap.update(referenceText="", review=approval())
    write_json(fixture.packet, packet)
    return packet


class ReferenceReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reference-review-tests-")
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def three_packets(self):
        fixtures = [Fixture(self.root, name) for name in ("alpha", "beta", "gamma")]
        for fixture, split in zip(fixtures, ("training", "calibration", "evaluation")):
            fixture.prepare()
            approve(fixture, split)
        return fixtures

    def test_prepare_is_pending_and_never_confuses_machine_flags_with_human_approval(self):
        fixture = Fixture(self.root, "pending", corpus_reviewed=True)
        packet = fixture.prepare()
        self.assertEqual(packet["version"], 1)
        self.assertEqual(packet["review"]["permission"]["status"], "pending")
        self.assertEqual(packet["review"]["grouping"]["status"], "pending")
        self.assertEqual(packet["review"]["scope"]["status"], "pending")
        self.assertIsNone(packet["review"]["split"])
        self.assertEqual(packet["review"]["speakerIDs"], [])
        self.assertEqual(packet["review"]["sessionID"], "")
        for segment in packet["review"]["segments"]:
            self.assertEqual(segment["referenceText"], "")
            for kind in ("lexical", "alignment"):
                self.assertEqual(segment[kind], {"status": "pending", "reviewer": "", "reviewedAt": "", "evidence": ""})
        _, rows, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
        self.assertTrue(audit["blocks"])
        self.assertEqual(stat.S_IMODE(fixture.packet.stat().st_mode), 0o600)
        fixture.assert_originals_unchanged(self)

    def test_approved_same_scope_three_partitions_export_exact_references_and_hashes(self):
        fixtures = self.three_packets()
        output = self.root / "export"
        dataset = REVIEW.export([fixture.packet for fixture in fixtures], output)
        self.assertEqual(dataset["version"], 1)
        self.assertEqual(dataset["scope"]["unit"], "studioSegment")
        self.assertEqual(len(dataset["rows"]), 6)
        self.assertEqual({row["split"] for row in dataset["rows"]}, {"training", "calibration", "evaluation"})
        for row in dataset["rows"]:
            self.assertEqual(row["referenceSHA256"], sha(row["reference"].encode()))
            self.assertTrue(row["alignmentReviewed"])
            fixture = next(f for f in fixtures if row["recordingID"] == f"recording-{f.tag}")
            self.assertEqual(row["audioSHA256"], sha(fixture.audio.read_bytes()))
            self.assertEqual(row["channel"], 0)
            self.assertNotEqual(row["reference"], row["recognition"]["text"])
        audit = json.loads((output / "audit.json").read_text())
        self.assertEqual(audit["purpose"], "research_only")
        self.assertEqual(audit["datasetSHA256"], sha((output / "dataset.json").read_bytes()))
        for receipt, fixture in zip(audit["packets"], fixtures):
            self.assertEqual((output / receipt["snapshot"]).read_bytes(), fixture.packet.read_bytes())
            self.assertEqual(receipt["packetSHA256"], sha((output / receipt["snapshot"]).read_bytes()))
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / "dataset.json").stat().st_mode), 0o600)
        for fixture in fixtures:
            fixture.assert_originals_unchanged(self)

    def test_stale_job_inventory_and_naive_review_timestamp_do_not_qualify(self):
        fixture = Fixture(self.root, "inventory")
        fixture.prepare()
        approve(fixture, "training")
        packet = json.loads(fixture.packet.read_text())
        packet["review"]["scope"]["reviewedAt"] = "2026-11-11"
        write_json(fixture.packet, packet)
        self.assertIn("scope", REVIEW.audit_packet(fixture.packet, REVIEW.Budget())[2]["blocks"])
        manifest = fixture.job / "manifest.json"
        record = json.loads(manifest.read_text())
        record["artifacts"]["transcript.json"]["sha256"] = "0" * 64
        write_json(manifest, record)
        with self.assertRaises(ValueError):
            REVIEW.audit_packet(fixture.packet, REVIEW.Budget())

    def test_stale_original_evidence_and_bound_timing_are_rejected(self):
        for name in ("audio", "reference", "raw", "profile", "timing"):
            with self.subTest(evidence=name):
                fixture = Fixture(self.root, name)
                fixture.prepare()
                approve(fixture, "training")
                if name == "timing":
                    packet = json.loads(fixture.packet.read_text())
                    packet["bindings"]["segments"][0]["startMs"] = 1
                    write_json(fixture.packet, packet)
                else:
                    path = getattr(fixture, name)
                    path.write_bytes(path.read_bytes() + b" ")
                with self.assertRaises((ValueError, OSError)):
                    REVIEW.audit_packet(fixture.packet, REVIEW.Budget())

    def test_missing_grouping_and_approval_evidence_remain_blocked(self):
        fixture = Fixture(self.root, "unknown")
        fixture.prepare()
        packet = approve(fixture, "training")
        packet["review"]["sessionID"] = "unknown"
        write_json(fixture.packet, packet)
        _, _, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
        self.assertTrue(audit["blocks"])
        packet["review"]["sessionID"] = "known-session"
        packet["review"]["segments"][0]["alignment"]["evidence"] = ""
        write_json(fixture.packet, packet)
        _, _, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
        self.assertTrue(audit["blocks"])

    def test_cross_partition_group_leakage_is_rejected(self):
        fixtures = self.three_packets()
        packet = json.loads(fixtures[1].packet.read_text())
        packet["review"]["sessionID"] = "session-alpha"
        write_json(fixtures[1].packet, packet)
        with self.assertRaises(ValueError):
            REVIEW.export([f.packet for f in fixtures], self.root / "leaking-export")
        self.assertFalse((self.root / "leaking-export/dataset.json").exists())

    def test_known_and_auto_invocations_have_distinct_decoding_scopes(self):
        auto = Fixture(self.root, "auto", mode="auto")
        known = Fixture(self.root, "known", mode="en")
        a, b = auto.prepare()["bindings"]["scope"], known.prepare()["bindings"]["scope"]
        self.assertEqual(a["modelSHA256"], b["modelSHA256"])
        self.assertEqual(a["runtimeSHA256"], b["runtimeSHA256"])
        self.assertEqual(sha(auto.profile.read_bytes()), sha(known.profile.read_bytes()))
        self.assertNotEqual(a["decodingSHA256"], b["decodingSHA256"])
        approve(auto, "training")
        approve(known, "calibration")
        with self.assertRaises(ValueError):
            REVIEW.export([auto.packet, known.packet], self.root / "mixed-scopes")

    def test_actual_model_and_runtime_changes_block_export(self):
        fixtures = self.three_packets()
        fixtures[0].model.write_bytes(b"changed model bytes")
        with self.assertRaises(ValueError):
            REVIEW.export([f.packet for f in fixtures], self.root / "changed-model")
        fixtures[0].model.write_bytes(fixtures[0].originals[fixtures[0].model])
        fixtures[0].runtime.write_bytes(b"changed runtime bytes")
        with self.assertRaises(ValueError):
            REVIEW.export([f.packet for f in fixtures], self.root / "changed-runtime")

    def test_fifo_is_rejected_and_existing_outputs_are_never_overwritten(self):
        fifo = self.root / "input-pipe"
        os.mkfifo(fifo, 0o600)
        with self.assertRaises((ValueError, OSError)):
            REVIEW.Budget().file(fifo)
        fixtures = self.three_packets()
        packet_before = fixtures[0].packet.read_bytes()
        with self.assertRaises(FileExistsError):
            fixtures[0].prepare()
        self.assertEqual(fixtures[0].packet.read_bytes(), packet_before)
        output = self.root / "existing-export"
        REVIEW.export([f.packet for f in fixtures], output)
        before = (output / "dataset.json").read_bytes()
        with self.assertRaises(FileExistsError):
            REVIEW.export([f.packet for f in fixtures], output)
        self.assertEqual((output / "dataset.json").read_bytes(), before)

    def test_gap_missed_speech_blocks_export_but_verified_silence_does_not(self):
        fixture = Fixture(self.root, "gaps")
        fixture.prepare()
        packet = approve(fixture, "training")
        self.assertEqual(len(packet["review"]["gaps"]), 2)
        _, rows, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
        self.assertFalse(audit["blocks"])
        self.assertEqual(len(rows), 2)
        packet["review"]["gaps"][0]["referenceText"] = "Speech missed by ASR"
        write_json(fixture.packet, packet)
        _, _, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
        self.assertTrue(audit["blocks"])

    def test_nonspeech_exclusion_is_counted_without_an_accuracy_target(self):
        fixtures = self.three_packets()
        for fixture in fixtures:
            packet = json.loads(fixture.packet.read_text())
            packet["review"]["segments"][0].update(disposition="non_speech", referenceText="")
            write_json(fixture.packet, packet)
            _, rows, audit = REVIEW.audit_packet(fixture.packet, REVIEW.Budget())
            self.assertFalse(audit["blocks"])
            self.assertEqual(len(rows), 1)
            self.assertEqual(len(audit["excluded"]), 1)
        output = self.root / "with-exclusions"
        dataset = REVIEW.export([f.packet for f in fixtures], output)
        self.assertEqual(len(dataset["rows"]), 3)
        self.assertEqual(sum(len(a["excluded"]) for a in json.loads((output / "audit.json").read_text())["packets"]), 3)
        empty = Fixture(self.root, "missed", with_entries=False)
        with self.assertRaises(ValueError):
            empty.prepare()
        self.assertFalse(empty.packet.exists())


if __name__ == "__main__":
    unittest.main()
