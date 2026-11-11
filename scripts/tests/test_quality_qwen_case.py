"""External-ASR adapter contracts using synthetic files and a mocked backend only."""
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

SOURCE = Path(__file__).resolve().parents[1] / "quality/qwen-asr-case.py"
SPEC = importlib.util.spec_from_file_location("qwen_case", SOURCE)
qwen = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qwen)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value) + "\n")


class Fixture:
    def __init__(self, root):
        self.root = root
        self.model, self.runtime = root / "model", root / "venv"
        self.model.mkdir(); self.runtime.mkdir(); (self.runtime / "bin").mkdir()
        (self.runtime / "bin/python").symlink_to(Path(sys.executable).resolve())
        (self.runtime / "runtime.txt").write_text("model-free mocked runtime")
        for name in ("config.json", "tokenizer.json", "tokenizer_config.json", "preprocessor_config.json"):
            write_json(self.model / name, {})
        (self.model / "model.safetensors").write_bytes(b"synthetic; never loaded")
        self.audio = root / "source.wav"
        self.wav()
        self.inventory(self.model, root / "model.inventory.json", dict(repo_id=qwen.MODEL_REPO, revision=qwen.MODEL_REVISION))
        self.inventory(self.runtime, root / "runtime.inventory.json", dict(repo_id=qwen.RUNTIME_REPO, source_revision=qwen.RUNTIME_REVISION,
                       venv_path=str(self.runtime), package_versions={"mlx-audio": qwen.RUNTIME_VERSION}))
        self.request = dict(schema_version=qwen.VERSION, case_id="en-source", source_language="en", language_mode="auto", max_tokens=1024,
                            max_seconds=10, deadline_utc=(qwen.common.utcnow() + timedelta(seconds=60)).isoformat(),
                            claim_path=str(root / "execution.claim.json"),
                            capture_inactive_attestation=True, workload_attestation="Synthetic test; no audio capture/model inference",
                            adapter_sha256=sha(SOURCE), common_helper_sha256=sha(qwen.COMMON_PATH),
                            python=dict(path=str(self.runtime / "bin/python"), sha256=sha(Path(sys.executable).resolve())),
                            audio=dict(path=str(self.audio), sha256=sha(self.audio)),
                            model_inventory=dict(path=str(root / "model.inventory.json"), sha256=sha(root / "model.inventory.json")),
                            runtime_inventory=dict(path=str(root / "runtime.inventory.json"), sha256=sha(root / "runtime.inventory.json")))
        self.write()

    def wav(self, channels=1, rate=16000, frames=1600):
        with wave.open(str(self.audio), "wb") as stream:
            stream.setnchannels(channels); stream.setsampwidth(2); stream.setframerate(rate)
            stream.writeframes(b"\0\0" * frames * channels)

    def inventory(self, root, path, metadata):
        files = [dict(path=str(p.relative_to(root)), bytes=p.stat().st_size, sha256=sha(p))
                 for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
        write_json(path, dict(schema_version="qwen-local-inventory-v1", root=str(root), files=files, **metadata))

    def write(self):
        write_json(self.root / "request.json", self.request)
        self.request_sha = sha(self.root / "request.json")

    def validate(self):
        return qwen.validate_request(self.root / "request.json", self.request_sha)

    def fake_worker(self, mode="success", output="run"):
        path = self.root / ("fake-" + mode + ".py")
        code = r'''
import hashlib,importlib.util,json,signal,subprocess,sys,time
from pathlib import Path
source,request_path,output,mode=sys.argv[1:]
spec=importlib.util.spec_from_file_location("fake_qwen_api",source);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
root=Path(output);request=json.loads(Path(request_path).read_text())
(root/"fake.started").write_text("started")
if mode=="fail":sys.exit(7)
if mode=="hang":time.sleep(60)
if mode=="hang-descendant":
 descendant=subprocess.Popen([sys.executable,"-B","-c","import time;time.sleep(60)"],process_group=0)
 (root/"descendant.pid").write_text(str(descendant.pid))
 signal.signal(signal.SIGINT,signal.SIG_IGN)
 def terminate(sig,frame):
  try:descendant.wait(timeout=2)
  except subprocess.TimeoutExpired:descendant.kill();descendant.wait(timeout=1)
  sys.exit(130)
 signal.signal(signal.SIGTERM,terminate)
 while True:time.sleep(.1)
text=b"  synthetic recognition unchanged  \n"
(root/"hypothesis.txt").write_bytes(text)
result=dict(source_sha256=request["audio"]["sha256"],engine="mlx-audio/qwen3_asr",case_id=request["case_id"],
 model_repo=module.MODEL_REPO,model_revision=module.MODEL_REVISION,runtime_repo=module.RUNTIME_REPO,
 runtime_revision=module.RUNTIME_REVISION,runtime_version=module.RUNTIME_VERSION,
 model_inventory_sha256=request["model_inventory"]["sha256"],runtime_inventory_sha256=request["runtime_inventory"]["sha256"],
 source_language=request["source_language"],language_mode=request["language_mode"],generation_settings=module.generation_kwargs(request),
 hypothesis_sha256=hashlib.sha256(text).hexdigest())
(root/"result.json").write_text(json.dumps(result))
complete=dict(request_sha256=hashlib.sha256(Path(request_path).read_bytes()).hexdigest(),inputs_unchanged=True,
 result_sha256=hashlib.sha256((root/"result.json").read_bytes()).hexdigest())
(root/"worker.complete.json").write_text(json.dumps(complete))
'''
        path.write_text(code)
        return [sys.executable, "-B", str(path), str(SOURCE), str(self.root / "request.json"), str(self.root / output), mode]

    def supervise(self, mode="success", output="run", request=None, clock_forward=False):
        # A synthetic directly guarded SID; backend command remains model-free.
        code = r'''
import datetime,importlib.util,json,sys
from pathlib import Path
source,request,expected,output,command,forward=sys.argv[1:]
spec=importlib.util.spec_from_file_location("isolated_qwen_supervisor",source);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
if forward=="yes":
 original=module.common.utcnow
 deadline=module.common.timestamp(json.loads(Path(request).read_text())["deadline_utc"])
 def clock():return deadline+datetime.timedelta(seconds=1) if (Path(output)/"fake.started").exists() else original()
 module.common.utcnow=clock
try:module.supervise(Path(request),expected,Path(output),json.loads(command))
except BaseException as error:
 print(type(error).__name__+": "+str(error),file=sys.stderr);sys.exit(1)
'''
        return subprocess.run([sys.executable, "-B", "-c", code, str(SOURCE), str(request or self.root / "request.json"),
                               self.request_sha, str(self.root / output), json.dumps(self.fake_worker(mode, output)),
                               "yes" if clock_forward else "no"], start_new_session=True,
                              capture_output=True, text=True, timeout=15)


class FakeBackend:
    seen = []
    def __init__(self, validated):
        self.versions = {"mlx-audio": "synthetic mock; no package imported"}
    def load(self, root): return object()
    def audio(self, source): return b"mock waveform"
    def generate(self, model, audio, kwargs):
        self.seen.append(kwargs)
        return dict(text="  Uncorrected RAW text!\n", segments=[dict(text="  Uncorrected RAW text!\n", start=0, end=.1)],
                    language="English", generation_tokens=4, prompt_tokens=2, total_tokens=6, total_time=.01)
    def peak(self): return 123456


class QwenCaseTests(unittest.TestCase):
    def fixture(self):
        folder = tempfile.TemporaryDirectory(); self.addCleanup(folder.cleanup)
        return Fixture(Path(folder.name).resolve())

    def test_complete_local_inventory_and_venv_interpreter_alias_are_preserved(self):
        f = self.fixture(); request, raw, validated, inventories = f.validate()
        self.assertEqual(validated["python_path"], str(f.runtime / "bin/python"))
        self.assertEqual(validated["python_resolved"], str(Path(sys.executable).resolve()))
        self.assertEqual(validated["audio_seconds"], .1)
        self.assertEqual(len(validated["runtime"]["ignored_interpreter_aliases"]), 1)
        self.assertEqual(raw, (f.root / "request.json").read_bytes())

    def test_all_priority_languages_have_explicit_known_names_and_no_automatic_oracle(self):
        for tag in ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt"):
            self.assertIsNotNone(qwen.language_argument(tag, "known"))
            self.assertIsNone(qwen.language_argument(tag, "auto"))
        self.assertEqual(qwen.language_argument("de-CH", "known"), "German")
        with self.assertRaises(ValueError): qwen.language_argument("unknown", "known")

    def test_tampered_audio_model_runtime_or_extra_model_code_is_rejected(self):
        for kind in ("audio", "model", "runtime", "extra"):
            f = self.fixture()
            if kind == "audio": f.audio.write_bytes(b"tampered")
            if kind == "model": (f.model / "config.json").write_text("changed")
            if kind == "runtime": (f.runtime / "runtime.txt").write_text("changed")
            if kind == "extra": (f.model / "unlocked.py").write_text("unlocked code")
            with self.subTest(kind=kind), self.assertRaises((ValueError, wave.Error)): f.validate()

    def test_both_published_tokenizer_layouts_are_admitted_without_asset_rewrites(self):
        for layout in ("json", "bpe"):
            f = self.fixture()
            if layout == "bpe":
                (f.model / "tokenizer.json").unlink()
                write_json(f.model / "vocab.json", {})
                (f.model / "merges.txt").write_text("#version: 0.2\n")
                f.inventory(f.model, f.root / "model.inventory.json", dict(repo_id=qwen.MODEL_REPO, revision=qwen.MODEL_REVISION))
                f.request["model_inventory"]["sha256"] = sha(f.root / "model.inventory.json");f.write()
            before = {p.name: p.read_bytes() for p in f.model.iterdir()}
            with self.subTest(layout=layout):f.validate()
            self.assertEqual(before, {p.name: p.read_bytes() for p in f.model.iterdir()})

    def test_incomplete_bpe_or_required_config_layout_never_becomes_a_valid_model(self):
        for missing in ("vocab.json", "merges.txt", "config.json", "tokenizer_config.json", "preprocessor_config.json"):
            f = self.fixture();(f.model / "tokenizer.json").unlink()
            write_json(f.model / "vocab.json", {});(f.model / "merges.txt").write_text("#version: 0.2\n")
            (f.model / missing).unlink()
            f.inventory(f.model, f.root / "model.inventory.json", dict(repo_id=qwen.MODEL_REPO, revision=qwen.MODEL_REVISION))
            f.request["model_inventory"]["sha256"] = sha(f.root / "model.inventory.json");f.write()
            with self.subTest(missing=missing), self.assertRaises(ValueError):f.validate()

    def test_request_hash_pins_code_and_model_repository_revision(self):
        f = self.fixture()
        with self.assertRaises(ValueError): qwen.validate_request(f.root / "request.json", "0" * 64)
        f.request["adapter_sha256"] = "0" * 64; f.write()
        with self.assertRaises(ValueError): f.validate()
        g = self.fixture()
        inventory = json.loads((g.root / "model.inventory.json").read_text());inventory["revision"] = "main"
        write_json(g.root / "model.inventory.json", inventory)
        g.request["model_inventory"]["sha256"] = sha(g.root / "model.inventory.json");g.write()
        with self.assertRaises(ValueError): g.validate()

    def test_audio_and_generation_limits_fail_before_backend_import(self):
        for channels, rate, frames in ((2, 16000, 1600), (1, 8000, 800), (1, 16000, 16000 * 60 + 1)):
            f = self.fixture(); f.wav(channels, rate, frames);f.request["audio"]["sha256"] = sha(f.audio);f.write()
            with self.subTest(channels=channels, rate=rate, frames=frames), self.assertRaises(ValueError): f.validate()
        for max_tokens in (0, 2049, True):
            f = self.fixture();f.request["max_tokens"] = max_tokens;f.write()
            with self.assertRaises(ValueError): f.validate()

    def test_mock_backend_preserves_raw_text_and_keeps_component_metrics_separate(self):
        f = self.fixture(); request, _, validated, _ = f.validate(); output = f.root / "result";output.mkdir()
        before = {name for name in sys.modules if name.startswith("mlx")}
        result = qwen.perform(request, validated, output, lambda: None, FakeBackend)
        self.assertEqual((output / "hypothesis.txt").read_bytes(), b"  Uncorrected RAW text!\n")
        self.assertEqual(before, {name for name in sys.modules if name.startswith("mlx")})
        self.assertIsNone(FakeBackend.seen[-1]["language"])
        self.assertIsNone(FakeBackend.seen[-1]["system_prompt"])
        self.assertIsNone(FakeBackend.seen[-1]["hotwords"])
        self.assertNotIn("engine_passes", result)
        self.assertIsNone(result["first_result_latency_seconds"])
        self.assertIsNone(result["total_unified_gpu_memory_bytes"])
        self.assertEqual(result["mlx_allocator_peak_since_before_load_bytes"], 123456)
        self.assertFalse(result["post_correction"])

    def test_offline_policy_blocks_python_network_before_any_backend_import(self):
        code = "import importlib.util,socket,sys,os; s=importlib.util.spec_from_file_location('q',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.install_offline_policy();assert os.environ['HF_HUB_OFFLINE']=='1';assert 'mlx.core' not in sys.modules;\ntry:socket.getaddrinfo('example.invalid',443)\nexcept RuntimeError:sys.exit(0)\nsys.exit(9)"
        result = subprocess.run([sys.executable, "-B", "-c", code, str(SOURCE)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_successful_owned_worker_is_reaped_and_new_output_cannot_be_overwritten(self):
        f = self.fixture()
        result = f.supervise();self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual(state["status"], "completed_with_review")
        self.assertTrue(state["shutdown"]["child_reaped"])
        self.assertFalse(state["shutdown"]["owned_group_present"])
        self.assertEqual(state["inference_retries"], 0)
        self.assertEqual((f.root / "run/hypothesis.txt").read_bytes(), b"  synthetic recognition unchanged  \n")
        result = f.supervise();self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileExistsError", result.stderr)

    def test_worker_failure_is_retained_and_same_request_cannot_silently_restart(self):
        f = self.fixture()
        result = f.supervise("fail");self.assertNotEqual(result.returncode, 0)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual(state["status"], "failed")
        self.assertTrue(state["shutdown"]["child_reaped"])
        result = f.supervise(output="second-run");self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileExistsError", result.stderr)
        self.assertFalse((f.root / "second-run/fake.started").exists())
        copied = f.root / "copied-request.json";copied.write_bytes((f.root / "request.json").read_bytes())
        result = f.supervise(output="copied-run", request=copied);self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileExistsError", result.stderr)
        self.assertFalse((f.root / "copied-run/fake.started").exists())

    def test_deadline_and_cancellation_reap_the_owned_backend_process(self):
        for reason in ("deadline", "cancel"):
            f = self.fixture(); f.request["max_seconds"] = 1 if reason == "deadline" else 10;f.write()
            code = r'''
import importlib.util,json,sys,time
from pathlib import Path
source,request,expected,output,command=sys.argv[1:]
spec=importlib.util.spec_from_file_location("cancel_qwen_supervisor",source);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
try:module.supervise(Path(request),expected,Path(output),json.loads(command))
except BaseException as error:print(type(error).__name__,file=sys.stderr);sys.exit(1)
'''
            child = subprocess.Popen([sys.executable, "-B", "-c", code, str(SOURCE), str(f.root / "request.json"), f.request_sha,
                                      str(f.root / "run"), json.dumps(f.fake_worker("hang"))],
                                     start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                if reason == "cancel":
                    until = time.monotonic() + 5
                    while not (f.root / "run/fake.started").exists():
                        if child.poll() is not None or time.monotonic() >= until:self.fail("Synthetic backend did not start")
                        time.sleep(.02)
                    (f.root / "run/cancel.request").touch()
                child.communicate(timeout=10)
                self.assertNotEqual(child.returncode, 0)
                state = json.loads((f.root / "run/state.json").read_text())
                self.assertEqual(state["status"], "deadline_exhausted" if reason == "deadline" else "cancelled")
                self.assertTrue(state["shutdown"]["child_reaped"])
                self.assertFalse(state["shutdown"]["owned_group_present"])
                self.assertEqual(state["deadline_utc"], f.request["deadline_utc"])
            finally:
                if child.poll() is None:child.kill();child.wait(timeout=3)

    def test_direct_guarded_sid_is_required_before_any_backend_launch(self):
        f = self.fixture()
        with mock.patch.object(qwen.os, "getsid", return_value=os.getpid() + 1), self.assertRaises(ValueError):
            qwen.supervise(f.root / "request.json", f.request_sha, f.root / "run")
        self.assertFalse((f.root / "run").exists())

    def test_forward_utc_jump_stops_a_running_worker_before_monotonic_budget(self):
        f = self.fixture(); started = time.monotonic()
        result = f.supervise("hang", clock_forward=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 5)
        state = json.loads((f.root / "run/state.json").read_text())
        self.assertEqual(state["status"], "deadline_exhausted")
        self.assertEqual(state["deadline_utc"], f.request["deadline_utc"])
        self.assertTrue(state["shutdown"]["child_reaped"])

    def test_separate_descendant_group_is_reaped_but_foreign_session_survives(self):
        f = self.fixture(); f.request["max_seconds"] = 1;f.write()
        foreign = subprocess.Popen([sys.executable, "-B", "-c", "import time;time.sleep(60)"], start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            result = f.supervise("hang-descendant")
            self.assertNotEqual(result.returncode, 0)
            state = json.loads((f.root / "run/state.json").read_text())
            descendant = int((f.root / "run/descendant.pid").read_text())
            self.assertTrue(state["shutdown"]["child_reaped"])
            self.assertFalse(state["shutdown"]["owned_session_workers_present"])
            self.assertTrue(any(event["process_group"] == descendant for event in state["shutdown"]["signals"]))
            self.assertIsNone(foreign.poll())
            with self.assertRaises(ProcessLookupError):os.kill(descendant, 0)
        finally:
            foreign.terminate();foreign.wait(timeout=3)

    def test_membership_probe_uncertainty_never_signals_an_unverified_group(self):
        f = self.fixture()
        child = mock.Mock(pid=12345, returncode=None)
        child.poll.side_effect = lambda: child.returncode
        child.kill.side_effect = lambda: setattr(child, "returncode", -9)
        child.wait.side_effect = lambda timeout: child.returncode
        with mock.patch.object(qwen, "owned_session_workers", side_effect=ValueError("uncertain membership")), mock.patch.object(qwen.os, "killpg") as group_signal:
            result = qwen.reap(child, f.root, 123)
        group_signal.assert_not_called()
        child.kill.assert_called_once()
        self.assertTrue(result["child_reaped"])
        self.assertIsNone(result["owned_session_workers_present"])
        self.assertTrue(result["shutdown_errors"])

    def test_session_membership_excludes_zero_parent_and_foreign_identities(self):
        snapshot = mock.Mock(stdout="  PID PGID\n0 111\n111 111\n222 222\n333 333\n", stderr="")
        def sid(pid):return 111 if pid in (0, 111, 222) else 333
        with mock.patch.object(qwen.os, "getpid", return_value=111), mock.patch.object(qwen.os, "getpgrp", return_value=111), mock.patch.object(qwen.os, "getsid", side_effect=sid), mock.patch.object(qwen.subprocess, "run", return_value=snapshot):
            groups = qwen.owned_session_workers(111)
        self.assertEqual(groups, {222: {222}})


if __name__ == "__main__":
    unittest.main()
