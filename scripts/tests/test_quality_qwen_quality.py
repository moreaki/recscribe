"""External quality contracts: synthetic receipts/scorer, no MLX, models or ASR."""
import copy
from datetime import timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import wave

SOURCE = Path(__file__).resolve().parents[1] / "quality/qwen-quality.py"
SPEC = importlib.util.spec_from_file_location("qwen_quality", SOURCE)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def text_sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value) + "\n")


def identity(path):
    return dict(path=str(path), sha256=sha(path))


def counts(errors=0, language="en"):
    value = dict(scoring_version=quality.POLICY, cer=errors / 6, character_errors=errors,
                 reference_characters=6, character_insertions=0, character_deletions=0, character_substitutions=errors,
                 wer=errors / 2, word_errors=errors, reference_words=2, word_insertions=0, word_deletions=0, word_substitutions=errors)
    if language == "zh":
        for key in ("wer", "word_errors", "reference_words", "word_insertions", "word_deletions", "word_substitutions"):
            value[key] = None
    return value


class Fixture:
    def __init__(self, root, language="en", mode="known", scorer_mode="success"):
        root = root.resolve()
        self.root, self.language, self.mode = root, language, mode
        self.audio, self.reference = root / "audio.wav", root / "reference.txt"
        with wave.open(str(self.audio), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
            stream.writeframes(b"\0\0" * 1600)
        self.reference.write_text("abc def")
        self.case = dict(id="case1", source_id="publisher:original1", source_channel=0, language=language,
                         task="standard_rendering" if language == "de-CH" else "transcription", split="held_out",
                         audio=str(self.audio), sha256=sha(self.audio), reference=str(self.reference),
                         reference_sha256=sha(self.reference), duration_seconds=.1, scoring_policy=quality.POLICY,
                         reviewed=False, variety="Synthetic fixture", script="Synthetic fixture")
        write(root / "corpus.json", dict(schema_version="1.1", cases=[self.case]))
        self.model_inventory = dict(schema_version="qwen-local-inventory-v1", root=str(root / "model"), files=[],
                                    repo_id=quality.adapter.MODEL_REPO, revision=quality.adapter.MODEL_REVISION)
        self.runtime_inventory = dict(schema_version="qwen-local-inventory-v1", root=str(root / "runtime"), files=[],
                                      repo_id=quality.adapter.RUNTIME_REPO, source_revision=quality.adapter.RUNTIME_REVISION)
        write(root / "model.json", self.model_inventory); write(root / "runtime.json", self.runtime_inventory)
        self.request = dict(schema_version=quality.adapter.VERSION, case_id="case1", source_language=language,
                            language_mode=mode, audio=identity(self.audio), max_tokens=1024, max_seconds=5,
                            deadline_utc=(quality.common.utcnow() + timedelta(seconds=120)).isoformat(),
                            adapter_sha256=sha(quality.ADAPTER_PATH), common_helper_sha256=sha(quality.adapter.COMMON_PATH),
                            claim_path=str(root / "qwen.claim.json"), model_inventory=identity(root / "model.json"),
                            runtime_inventory=identity(root / "runtime.json"))
        write(root / "request.json", self.request)
        self.out = root / "original-qwen"; self.out.mkdir()
        (self.out / "request.original.json").write_bytes((root / "request.json").read_bytes())
        (self.out / "hypothesis.txt").write_text("abc def")
        write(self.out / "backend-result.original.json", dict(text="abc def"))
        write(self.out / "model.inventory.original.json", self.model_inventory)
        write(self.out / "runtime.inventory.original.json", self.runtime_inventory)
        self.result = dict(schema_version=quality.adapter.VERSION + "-result", status="completed_with_review",
            engine="mlx-audio/qwen3_asr", case_id="case1", source_language=language, language_mode=mode,
            source_sha256=sha(self.audio), model_repo=quality.adapter.MODEL_REPO, model_revision=quality.adapter.MODEL_REVISION,
            runtime_repo=quality.adapter.RUNTIME_REPO, runtime_revision=quality.adapter.RUNTIME_REVISION,
            runtime_version=quality.adapter.RUNTIME_VERSION, model_inventory_sha256=sha(root / "model.json"),
            runtime_inventory_sha256=sha(root / "runtime.json"), generation_settings=quality.adapter.generation_kwargs(self.request),
            effective_language_prompt=quality.adapter.language_argument(language, mode), hypothesis_sha256=sha(self.out / "hypothesis.txt"),
            source_audio_seconds=.1, possible_token_limit=False, quality_approval=False, reference_generated=False, post_correction=False,
            component_timings=dict(backend_import_and_metadata_seconds=.1, backend_load_call_seconds=.2,
                                   pcm_to_backend_array_seconds=.01, backend_generate_call_seconds=.3),
            mlx_allocator_peak_since_before_load_bytes=1234, mlx_memory_scope="MLX allocator subset", timing_scope="MLX components")
        now = quality.common.utcnow()
        self.state = dict(schema_version=quality.adapter.VERSION + "-run", status="completed_with_review", stage="finished",
                          request_sha256=sha(root / "request.json"), case_id="case1", language_mode=mode,
                          inference_retries=0, full_application_comparison=False,
                          started_utc=(now - timedelta(seconds=2)).isoformat(), ended_utc=now.isoformat(),
                          deadline_utc=self.request["deadline_utc"],
                          shutdown=dict(returncode=0, child_reaped=True, owned_group_present=False,
                                        owned_session_workers_present=False, shutdown_errors=[], signals=[]))
        write(root / "qwen.claim.json", dict(request_sha256=sha(root / "request.json"), output=str(self.out),
              claimed_utc=(now - timedelta(seconds=1)).isoformat(), fixed_deadline_utc=self.request["deadline_utc"]))
        self.seal_result()
        self.control = dict(model="large-v3", model_sha256=text_sha("model"), profile="matched", profile_sha256=text_sha("profile"),
                            runtime_settings_sha256=text_sha("runtime"), transcription_runner_sha256=text_sha("runner"),
                            whisper_binary_sha256=text_sha("binary"), source_revision="a" * 40)
        self.native = dict(self.control, id="case1", language=language, language_mode=mode, task=self.case["task"],
                           source_channel=0, source_sha256=sha(self.audio), reference_sha256=sha(self.reference),
                           path="final", repeat=1, status="completed_with_review", scoring_policy=quality.POLICY,
                           measurement_scope="quality_and_resources", effective_profile_sha256=self.control["runtime_settings_sha256"],
                           runner_sha256=self.control["transcription_runner_sha256"], engine_identity_observations=1, vad_model_sha256=None)
        argument = "auto" if mode == "auto" else language.split("-")[0]
        self.native["measurement"] = dict(counts(1, language), id="case1", language=language, task=self.case["task"],
            source_sha256=sha(self.audio), reference_sha256=sha(self.reference), status="completed_with_review",
            hypothesis_sha256=text_sha("native raw text"), wall_seconds=1, peak_rss_bytes=2048, memory_method="time-l process RSS",
            engine_passes=[dict(engine="whisper.cpp", model_sha256=self.control["model_sha256"],
                binary_sha256=self.control["whisper_binary_sha256"], asr_language=argument,
                decoding=dict(profile_sha256=self.control["runtime_settings_sha256"]), vad_model_sha256=None,
                language_policy=dict(effective_argument=argument), command=["whisper-cli", "-l", argument])])
        self.matrix = dict(dry_run=False, measurement_scope="quality_and_resources", split="held_out", rows=[self.native])
        write(root / "matrix.json", self.matrix)
        self.scorer = root / "synthetic-scorer"
        self.make_scorer(scorer_mode)
        repo = SOURCE.parents[2]
        sources = [repo / "core/Sources/RecScribeCore/TranscriptAccuracy.swift", repo / "core/Sources/RecScribeCore/JSONValue.swift",
                   repo / "benchmarks/realworld/score-transcript.swift"]
        self.build = dict(schema_version="standalone-native-scorer-build-v1", synthetic_test_only=True,
            sources=[dict(**identity(p), bytes=p.stat().st_size) for p in sources],
            binary=dict(**identity(self.scorer), bytes=self.scorer.stat().st_size),
            reproduction_binary=dict(**identity(self.scorer), bytes=self.scorer.stat().st_size),
            byte_identical_reproduction=True, build_exit_code=0, compiled_contract_tests=dict(total=4, passed=4, failed=0),
            unchanged_legacy_scorer_sha256=sha(sources[0]), model_or_asr_execution=False,
            compiler="Synthetic test-only executable, no compiler invoked")
        write(root / "build-receipt.json", self.build)
        self.plan = dict(schema_version=quality.VERSION + "-plan", scoring_policy=quality.POLICY, recognition_task="transcribe",
            collector_sha256=sha(SOURCE), adapter_sha256=sha(quality.ADAPTER_PATH), common_helper_sha256=sha(quality.adapter.COMMON_PATH),
            corpus=identity(root / "corpus.json"), native_matrices=[dict(id="native", **identity(root / "matrix.json"))],
            controls=[dict(id="f16", matrix_id="native", identity=self.control)],
            cases=[dict(id="case1", language_mode=mode, qwen=dict(request=identity(root / "request.json"),
                        output=str(self.out), state_sha256=sha(self.out / "state.json")))],
            scorer=dict(**identity(self.scorer), build_receipt=identity(root / "build-receipt.json"), source_files=[identity(p) for p in sources]),
            claim_path=str(root / "collect.claim.json"), deadline_utc=(now + timedelta(seconds=60)).isoformat(),
            max_seconds=15, per_score_seconds=5)
        self.seal_plan()

    def seal_result(self):
        write(self.out / "result.json", self.result)
        self.state["result_sha256"] = sha(self.out / "result.json")
        write(self.out / "state.json", self.state)
        write(self.out / "worker.complete.json", dict(result_sha256=self.state["result_sha256"],
              request_sha256=sha(self.root / "request.json"), inputs_unchanged=True))

    def seal_plan(self):
        self.plan["native_matrices"][0].update(identity(self.root / "matrix.json"))
        write(self.root / "plan.json", self.plan)
        self.plan_sha = sha(self.root / "plan.json")

    def reseal_state(self):
        write(self.out / "state.json", self.state)
        self.plan["cases"][0]["qwen"]["state_sha256"] = sha(self.out / "state.json")
        self.seal_plan()

    def make_scorer(self, mode):
        code = '''
import json,os,pathlib,signal,sys,time
args=dict(zip(sys.argv[1::2],sys.argv[2::2]))
out=pathlib.Path(args["--output"]);out.mkdir()
mode=MODE
if mode=="wait":
    signal.signal(signal.SIGINT,signal.SIG_IGN)
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    (out/"started").write_text(str(os.getpid()))
    while True:
        if pathlib.Path(args["--cancel-marker"]).exists():
            (out/"cancel-observed").write_text("yes");sys.exit(1)
        time.sleep(.01)
if mode=="fail":
    (out/"partial.json").write_text("{}");sys.exit(1)
result=COUNTS
if args["--language"].split("-")[0]=="zh":
    for key in ("wer","word_errors","reference_words","word_insertions","word_deletions","word_substitutions"):
        result[key]=None
result.update(bridge_version="external-transcript-score-v1",source_language=args["--language"],reference_sha256=args["--reference-sha256"],hypothesis_sha256=args["--hypothesis-sha256"],quality_approval=False,reference_corrected=False)
if mode=="bad-count":result["character_errors"]=2
if mode=="bad-source":result["reference_sha256"]="0"*64
for role in ("reference","hypothesis"):
    (out/(role+".original.txt")).write_bytes(pathlib.Path(args["--"+role]).read_bytes())
(out/"score.json").write_text(json.dumps(result))
'''
        self.scorer.write_text("#!" + str(Path(sys.executable).resolve()) + "\n" + code.replace("MODE", repr(mode)).replace("COUNTS", repr(counts())))
        self.scorer.chmod(0o700)

    def collect(self, name="collected"):
        return quality.collect(self.root / "plan.json", self.plan_sha, self.root / name)


class QwenQualityTests(unittest.TestCase):
    def test_count_only_pair_keeps_distinct_engine_resources_and_unmeasured_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            value = fixture.collect()
            self.assertEqual(value["status"], "collected")
            row = value["rows"][0]
            self.assertEqual(row["pair_status"], {"f16": "paired"})
            comparison = value["comparisons"][0]
            self.assertEqual(comparison["cer"]["paired_rate_delta"], -1 / 6)
            self.assertEqual(comparison["wer"]["qwen"]["units"], 2)
            self.assertNotIn("engine_passes", row["qwen"])
            self.assertEqual(row["qwen"]["identity"]["engine"], "mlx-audio/qwen3_asr")
            self.assertEqual(row["qwen"]["resources"]["mlx_allocator_peak_since_before_load_bytes"], 1234)
            self.assertEqual(row["native"]["f16"]["resources"]["peak_rss_bytes"], 2048)
            self.assertIsNone(row["qwen"]["resources"]["total_unified_gpu_memory_bytes"])
            self.assertFalse(value["quality_approval"])
            self.assertFalse(value["inference_performed"])
            self.assertIn("NOT_AUTHORIZED", value["product_acceptance"])

    def test_auto_has_no_oracle_and_chinese_is_legacy_cer_only(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp), "zh", "auto")
            value = fixture.collect()
            self.assertIsNone(value["rows"][0]["qwen"]["identity"]["generation_settings"]["language"])
            self.assertIsNone(value["comparisons"][0]["wer"])
            self.assertIsNone(value["rows"][0]["native"]["f16"]["metrics"]["wer"])
            self.assertEqual(value["scoring_policy"], quality.POLICY)

    def test_swiss_standard_rendering_goal_stays_explicit(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp), "de-CH")
            value = fixture.collect()
            self.assertEqual(value["rows"][0]["task"], "standard_rendering")
            self.assertEqual(value["rows"][0]["qwen"]["identity"]["generation_settings"]["language"], "German")

    def test_tampered_plan_reference_and_collector_fail_before_scoring(self):
        for change in ("plan", "reference", "collector"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if change == "plan":
                    (fixture.root / "plan.json").write_bytes(b"{}")
                elif change == "reference":
                    fixture.reference.write_text("changed")
                else:
                    fixture.plan["collector_sha256"] = "0" * 64; fixture.seal_plan()
                with self.assertRaises(ValueError):
                    fixture.collect()
                self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_build_receipt_must_bind_actual_binary_sources_and_compiled_contracts(self):
        for change in ("binary", "source", "reproduction", "legacy", "tests"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if change == "binary": fixture.build["binary"]["sha256"] = "0" * 64
                elif change == "source": fixture.build["sources"][0]["sha256"] = "0" * 64
                elif change == "reproduction": fixture.build["reproduction_binary"]["sha256"] = "0" * 64
                elif change == "legacy": fixture.build["unchanged_legacy_scorer_sha256"] = "0" * 64
                else: fixture.build["compiled_contract_tests"]["failed"] = 1
                write(fixture.root / "build-receipt.json", fixture.build)
                fixture.plan["scorer"]["build_receipt"] = identity(fixture.root / "build-receipt.json"); fixture.seal_plan()
                with self.assertRaises(ValueError): fixture.collect()
                self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_collection_claim_cannot_consume_the_qwen_attempt_claim(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            claim = fixture.root / "qwen.claim.json"; original = claim.read_bytes()
            fixture.plan["claim_path"] = str(claim); fixture.seal_plan()
            with self.assertRaises(ValueError): fixture.collect()
            self.assertEqual(claim.read_bytes(), original)

    def test_no_overwrite_and_frozen_claim_prevents_copied_plan_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp)); fixture.collect()
            original = (fixture.root / "collected/report.json").read_bytes()
            with self.assertRaises(FileExistsError):
                fixture.collect()
            with self.assertRaises(FileExistsError):
                fixture.collect("copied-output")
            self.assertEqual((fixture.root / "collected/report.json").read_bytes(), original)
            self.assertEqual(json.loads((fixture.root / "copied-output/state.json").read_text())["status"], "failed")

    def test_missing_cancelled_partial_and_failed_first_attempts_stay_pending(self):
        for status in (None, "cancelled", "failed", "running"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if status is None:
                    fixture.plan["cases"][0]["qwen"]["state_sha256"] = None; fixture.seal_plan()
                else:
                    fixture.state["status"] = status; fixture.reseal_state()
                value = fixture.collect()
                self.assertEqual(value["status"], "collected_with_gaps")
                self.assertEqual(value["comparisons"][0]["paired_cells"], 0)
                self.assertIsNone(value["comparisons"][0]["cer"])
                self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_bad_first_receipts_never_score_even_when_result_exists(self):
        for change in ("state-sha", "request-snapshot", "completion", "raw-text", "claim-output", "shutdown", "settings", "deadline"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if change == "state-sha":
                    fixture.state["stage"] = "changed"; write(fixture.out / "state.json", fixture.state)
                elif change == "request-snapshot":
                    write(fixture.out / "request.original.json", {})
                elif change == "completion":
                    (fixture.out / "worker.complete.json").unlink()
                elif change == "raw-text":
                    (fixture.out / "hypothesis.txt").write_text("corrected")
                elif change == "claim-output":
                    claim = json.loads((fixture.root / "qwen.claim.json").read_text()); claim["output"] = str(fixture.root / "replacement"); write(fixture.root / "qwen.claim.json", claim)
                elif change == "shutdown":
                    fixture.state["shutdown"]["owned_session_workers_present"] = True; fixture.reseal_state()
                elif change == "settings":
                    fixture.result["generation_settings"]["system_prompt"] = "correct the reference"; fixture.seal_result(); fixture.reseal_state()
                else:
                    fixture.state["ended_utc"] = (quality.common.utcnow() + timedelta(seconds=300)).isoformat(); fixture.reseal_state()
                value = fixture.collect()
                self.assertEqual(value["comparisons"][0]["paired_cells"], 0)
                self.assertEqual(value["rows"][0]["qwen"]["status"], "invalid_or_failed")
                self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_native_mismatch_and_second_repeat_never_replace_first(self):
        for change in ("reference", "channel", "language", "task", "runtime", "engine", "actual-profile", "actual-vad", "runner", "observations", "repeat", "cancelled"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if change == "reference": fixture.native["reference_sha256"] = "0" * 64
                elif change == "channel": fixture.native["source_channel"] = 1
                elif change == "language": fixture.native["language"] = "fr"
                elif change == "task": fixture.native["task"] = "translation"
                elif change == "runtime": fixture.native["runtime_settings_sha256"] = "0" * 64
                elif change == "engine": fixture.native["measurement"]["engine_passes"][0]["engine"] = "fake-whisper"
                elif change == "actual-profile": fixture.native["measurement"]["engine_passes"][0]["decoding"]["profile_sha256"] = "0" * 64
                elif change == "actual-vad": fixture.native["measurement"]["engine_passes"][0]["vad_model_sha256"] = "0" * 64
                elif change == "runner": fixture.native["runner_sha256"] = "0" * 64
                elif change == "observations": fixture.native["engine_identity_observations"] = 0
                elif change == "repeat": fixture.native["repeat"] = 2
                else:
                    later = copy.deepcopy(fixture.native); later["repeat"] = 2; fixture.matrix["rows"].append(later)
                    fixture.native["status"] = "cancelled"
                write(fixture.root / "matrix.json", fixture.matrix); fixture.seal_plan()
                value = fixture.collect()
                self.assertEqual(value["comparisons"][0]["paired_cells"], 0)
                self.assertIsNone(value["comparisons"][0]["cer"])

    def test_scorer_failure_partial_bad_counts_and_mismatched_receipt_are_missing(self):
        for mode in ("fail", "bad-count", "bad-source"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp), scorer_mode=mode)
                value = fixture.collect()
                self.assertEqual(value["comparisons"][0]["paired_cells"], 0)
                self.assertEqual(value["rows"][0]["qwen"]["status"], "invalid_or_failed")
                local = json.loads((fixture.root / "collected/cell-0/state.json").read_text())
                self.assertTrue(local["shutdown"]["child_reaped"])

    def test_reference_denominators_must_match(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp)); fixture.native["measurement"]["reference_characters"] = 7
            fixture.native["measurement"]["cer"] = 1 / 7
            write(fixture.root / "matrix.json", fixture.matrix); fixture.seal_plan()
            value = fixture.collect()
            self.assertEqual(value["rows"][0]["pair_status"]["f16"], "invalid")

    def test_source_request_language_and_bounded_metadata_are_admission_contracts(self):
        for change in ("case", "auto-oracle", "case-budget", "text-budget", "json-budget", "duplicate"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                if change in ("case", "auto-oracle"):
                    fixture.request["case_id" if change == "case" else "language_mode"] = "other" if change == "case" else "auto"
                    write(fixture.root / "request.json", fixture.request)
                    fixture.plan["cases"][0]["qwen"]["request"] = identity(fixture.root / "request.json")
                elif change == "case-budget":
                    fixture.plan["cases"] *= quality.MAX_CASES + 1
                elif change == "text-budget":
                    fixture.reference.write_bytes(b"x" * (quality.MAX_TEXT + 1))
                    fixture.case["reference_sha256"] = sha(fixture.reference); write(fixture.root / "corpus.json", dict(cases=[fixture.case]))
                    fixture.plan["corpus"] = identity(fixture.root / "corpus.json")
                elif change == "json-budget":
                    (fixture.root / "corpus.json").write_bytes(b" " * (quality.common.MAX_JSON_BYTES + 1))
                    fixture.plan["corpus"] = identity(fixture.root / "corpus.json")
                else:
                    fixture.plan["cases"] *= 2
                fixture.seal_plan()
                with self.assertRaises(ValueError): fixture.collect()
                self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_absolute_deadline_cannot_reset_on_late_start(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp)); fixture.plan["deadline_utc"] = (quality.common.utcnow() - timedelta(seconds=1)).isoformat(); fixture.seal_plan()
            with self.assertRaises(TimeoutError): fixture.collect()
            state = json.loads((fixture.root / "collected/state.json").read_text())
            self.assertEqual(state["status"], "deadline_exhausted")
            self.assertFalse((fixture.root / "collect.claim.json").exists())

    def test_forward_utc_jump_aborts_before_score_even_with_monotonic_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp)); now = quality.common.utcnow(); calls = [0]
            def clock():
                calls[0] += 1
                return now if calls[0] < 5 else now + timedelta(seconds=120)
            with mock.patch.object(quality.common, "utcnow", side_effect=clock):
                with self.assertRaises(TimeoutError): fixture.collect()
            self.assertFalse((fixture.root / "collected/cell-0/score").exists())

    def test_scorer_cleanup_reaps_separate_groups_and_preserves_foreign_session(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            script = "import pathlib,subprocess,sys,time; child=subprocess.Popen([sys.executable,'-B','-c','import time; time.sleep(60)'],process_group=0); pathlib.Path(sys.argv[1]).write_text(str(child.pid)); child.wait()"
            child = subprocess.Popen([sys.executable, "-B", "-c", script, str(root / "descendant.pid")],
                                     start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            foreign = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(60)"], start_new_session=True)
            descendant = None
            try:
                until = time.monotonic() + 3
                while time.monotonic() < until and not (root / "descendant.pid").exists(): time.sleep(.02)
                self.assertTrue((root / "descendant.pid").exists())
                descendant = int((root / "descendant.pid").read_text())
                self.assertEqual(os.getsid(descendant), child.pid)
                self.assertNotEqual(os.getpgid(descendant), child.pid)
                result = quality.reap_scorer(child, root)
                self.assertTrue(result["child_reaped"])
                self.assertFalse(result["owned_session_workers_present"])
                self.assertFalse(result["shutdown_errors"])
                self.assertIsNone(foreign.poll())
                targeted = {pid for row in result["signals"] for pid in row["verified_members"]}
                self.assertIn(descendant, targeted)
                self.assertNotIn(foreign.pid, targeted)
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=3)
                if descendant is not None:
                    try:
                        if os.getsid(descendant) == child.pid: os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError: pass
                foreign.kill(); foreign.wait(timeout=3)

    def test_uncertain_session_membership_fails_closed_and_reaps_direct_scorer(self):
        with tempfile.TemporaryDirectory() as temp:
            child = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(60)"], start_new_session=True)
            try:
                with mock.patch.object(quality, "scorer_workers", side_effect=ValueError("uncertain membership")):
                    result = quality.reap_scorer(child, Path(temp).resolve())
                self.assertTrue(result["child_reaped"])
                self.assertIsNone(result["owned_session_workers_present"])
                self.assertTrue(result["shutdown_errors"])
                self.assertFalse(result["signals"])
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=3)

    def test_cancellation_forwards_active_marker_reaps_child_and_keeps_partial(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp), scorer_mode="wait")
            second_request = copy.deepcopy(fixture.request)
            second_request.update(language_mode="auto", claim_path=str(fixture.root / "second-qwen.claim.json"))
            write(fixture.root / "second-request.json", second_request)
            fixture.plan["cases"].append(dict(id="case1", language_mode="auto", qwen=dict(request=identity(fixture.root / "second-request.json"),
                output=str(fixture.root / "unstarted-qwen"), state_sha256=None)))
            fixture.seal_plan()
            output = fixture.root / "collected"
            child = subprocess.Popen([sys.executable, "-B", str(SOURCE), "collect", "--plan", str(fixture.root / "plan.json"),
                                      "--plan-sha256", fixture.plan_sha, "--output", str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                until = time.monotonic() + 5
                while time.monotonic() < until and not (output / "cell-0/score/started").exists():
                    time.sleep(.02)
                self.assertTrue((output / "cell-0/score/started").exists())
                started = json.loads((output / "cell-0/state.json").read_text())
                self.assertEqual(started["status"], "running")
                self.assertEqual(started["stage"], "scoring")
                (output / "cancel.request").touch()
                child.communicate(timeout=8)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(json.loads((output / "state.json").read_text())["status"], "cancelled")
                local = json.loads((output / "cell-0/state.json").read_text())
                self.assertTrue(local["shutdown"]["child_reaped"])
                self.assertFalse(local["shutdown"]["owned_session_workers_present"])
                self.assertTrue((output / "cell-0/cancel.request").exists())
                self.assertTrue((output / "cell-0/score/cancel-observed").exists())
                self.assertFalse((output / "report.json").exists())
                partial = json.loads((output / "partial-report.json").read_text())
                self.assertTrue(all(v["paired_cells"] == 0 for v in partial["comparisons"]))
                self.assertEqual(partial["rows"][1]["collection_status"], "not_started")
                self.assertEqual(partial["rows"][1]["qwen"]["status"], "not_started")
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
