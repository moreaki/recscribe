"""Fixed toy containers and owned synthetic children; no ASR or real models."""
import copy
import hashlib
import io
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

QUALITY = Path(__file__).resolve().parents[1] / "quality"
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, QUALITY / file)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
q = module("mlp_q4_test", "quantize-mlp-permutation.py")
operator = module("mlp_operator_for_q4_tests", "mlp-permute.py")
def sha(data): return hashlib.sha256(data).hexdigest()


class MLPQuantizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name).resolve()
        self.parent = self.f16()
        self.operator_sha = sha(Path(operator.__file__).read_bytes())
        self.pin = mock.patch.object(q, "OPERATOR_SHA256", self.operator_sha); self.pin.start()

    def tearDown(self): self.pin.stop(); self.temp.cleanup()

    def f16(self):
        header = dict(zip(q.weights.HEADER_FIELDS, (2, 2, 64, 1, 1, 2, 64, 1, 1, 1, 1)))
        path = self.root / "original.bin"
        with path.open("xb") as stream:
            stream.write(struct.pack("<12i", q.weights.MAGIC, *header.values()))
            stream.write(struct.pack("<2i", 1, 201) + bytes(201 * 4))
            stream.write(struct.pack("<i", 2))
            for token in (b"a", b"b"): stream.write(struct.pack("<i", len(token)) + token)
            for name, (shape, dtype) in q.weights.expected_tensors(header).items():
                encoded = name.encode(); width, kind = (4, 0) if dtype == "f32" else (2, 1)
                stream.write(struct.pack("<3i", len(shape), len(encoded), kind))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                if name.endswith(".mlp.2.weight"):
                    row = [((255 - i) // 2) / 256 for i in range(256)]
                    stream.write(struct.pack("<256e", *row) * shape[1])
                elif name.endswith(".mlp.0.weight"):
                    for i in range(shape[1]): stream.write(struct.pack("<e", i / 256) * shape[0])
                elif name.endswith(".mlp.0.bias"):
                    stream.write(struct.pack("<256f", *[i + .25 for i in range(256)]))
                else: stream.write(bytes(math.prod(shape) * width))
        return q.weights.inspect_model(path, limits=q.LIMITS)

    def permuted(self):
        out = self.root / "permutation"
        with mock.patch.object(operator, "validate_geometry", return_value=(64, 1, 1)):
            audit = operator.apply_permutation(self.parent.path, "small", self.parent.source_sha256, out)
        plan_path, audit_path = out / "permutation-plan.json", out / "permutation-audit.json"
        plan = json.loads(plan_path.read_text()); digest = sha(plan_path.read_bytes())
        model = q.weights.inspect_model(out / "model.bin", limits=q.LIMITS)
        return model, plan, digest, audit, plan_path, audit_path

    def q4_container(self, source, name, plan=None, wrong=None):
        """Literal block fixtures only; no approximation/quantizer implementation."""
        path = self.root / name; permutations = {v["site"]: v["permutation"] for v in (plan or {}).get("sites", [])}
        tensor = source.tensors[0]; prefix_end = tensor.offset - 12 - 4 * len(tensor.shape) - len(tensor.name.encode())
        with source.path.open("rb") as original, path.open("xb") as out:
            prefix = bytearray(original.read(prefix_end)); prefix[44:48] = struct.pack("<i", 2002); out.write(prefix)
            for tensor in source.tensors:
                name = tensor.name; quantized = len(tensor.shape) == 2 and name not in q.core.SKIP
                encoded = name.encode(); out.write(struct.pack("<3i", len(tensor.shape), len(encoded), 2 if quantized else tensor.type_id))
                out.write(struct.pack("<" + "i" * len(tensor.shape), *tensor.shape) + encoded)
                if quantized:
                    for row in range(tensor.shape[1]):
                        old_row = permutations.get(name[:-9], list(range(tensor.shape[1])))[row] if name.endswith(".0.weight") else row
                        packed = 0x88
                        if name.endswith(".mlp.0.weight"): packed = ((old_row % 15) + 1) | (((old_row // 15) % 15 + 1) << 4)
                        if name == wrong: packed ^= 1
                        for _ in range(tensor.shape[0] // 32):
                            payload = bytes((i | ((15 - i) << 4) for i in range(16))) if name.endswith(".mlp.2.weight") else bytes([packed]) * 16
                            out.write(struct.pack("<e", -.125 if row % 2 else .125) + payload)
                else:
                    original.seek(tensor.offset); out.write(original.read(tensor.bytes))
        return path

    def pair(self):
        model, plan, digest, audit, *_ = self.permuted()
        proof = q.validate_permutation(self.parent, model, "small", plan, digest, audit)
        plain = self.q4_container(self.parent, "plain.bin")
        candidate = self.q4_container(model, "candidate.bin", plan)
        return model, plan, proof, plain, candidate, q.core.audit_q4(self.parent, plain), q.core.audit_q4(model, candidate)

    def test_native_signed_scale_and_low_then_high_nibbles_have_literal_oracle(self):
        raw = struct.pack("<e", -.25) + bytes([0xF0, 0x87]) + bytes([0x88]) * 14
        values = q.dequant_q4(raw).tolist()
        self.assertEqual(values[:2], [2., .25]); self.assertEqual(values[16:18], [-1.75, 0.])
        self.assertEqual(values[2:16] + values[18:], [0.] * 28)
        for bad in (raw[:-1], b"", struct.pack("<e", float("inf")) + bytes(16)):
            with self.subTest(bad=bad[:2]), self.assertRaises(ValueError): q.dequant_q4(bad)

    def test_actual_operator_plan_and_inverse_bytes_independently_verified(self):
        model, plan, digest, audit, *_ = self.permuted()
        result = q.validate_permutation(self.parent, model, "small", plan, digest, audit)
        self.assertEqual(result["target_count"], 6)
        # Tied adjacent maxima retain original index, rather than reversed ties.
        self.assertEqual(plan["sites"][0]["permutation"][:4], [254, 255, 252, 253])
        self.assertTrue(result["exact_selected_and_inverse_bytes_verified"])
        for key, value in (("generator_sha256", "0" * 64), ("derived_sha256", "0" * 64),
                           ("outside_declared_changed_bytes", False), ("no_op", True)):
            corrupt = copy.deepcopy(audit); corrupt[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                q.validate_permutation(self.parent, model, "small", plan, digest, corrupt)
        corrupt = copy.deepcopy(plan); corrupt["sites"][0]["permutation"][:2] = [255, 254]
        with self.assertRaisesRegex(ValueError, "stable ordering"):
            q.validate_permutation(self.parent, model, "small", corrupt, digest, audit)

    def test_f16_bias_corruption_is_rejected_even_after_rebinding_model_hash(self):
        model, plan, digest, audit, *_ = self.permuted()
        target = model.tensor("encoder.blocks.0.mlp.0.bias"); model.path.chmod(0o600)
        with model.path.open("r+b") as f: f.seek(target.offset); f.write(struct.pack("<f", -123))
        changed = q.weights.inspect_model(model.path, limits=q.LIMITS); audit["derived_sha256"] = changed.source_sha256
        with self.assertRaisesRegex(ValueError, "F32 bias"):
            q.validate_permutation(self.parent, changed, "small", plan, digest, audit)

    def test_fixed_no_op_and_zero_reference_norm_remain_explicit(self):
        with self.parent.path.open("r+b") as stream:
            for site in q.sites(self.parent.architecture):
                tensor = self.parent.tensor(site + ".2.weight"); stream.seek(tensor.offset); stream.write(bytes(tensor.bytes))
        self.parent = q.weights.inspect_model(self.parent.path, limits=q.LIMITS)
        model, plan, proof, plain, candidate, a, b = self.pair()
        self.assertEqual(model.source_sha256, self.parent.source_sha256)
        self.assertEqual(plan["sites"][0]["permutation"], list(range(256)))
        result = q.compare_quantized(self.parent, plain, a, candidate, b, proof)
        aggregate = result["weight_error_diagnostics"]["aggregate"]
        self.assertEqual(aggregate["reference_squared_frobenius"], 0)
        self.assertIsNone(aggregate["plain_q4_relative_frobenius"])
        self.assertIsNone(aggregate["permuted_q4_relative_frobenius"])

    def test_q4_row_bias_untouched_proofs_and_sse_have_independent_scalar_oracle(self):
        model, plan, proof, plain, candidate, a, b = self.pair()
        result = q.compare_quantized(self.parent, plain, a, candidate, b, proof)
        self.assertTrue(result["exact_q4_mlp1_row_and_f32_bias_permutation"])
        self.assertTrue(result["unmodified_tensors_byte_identical"])
        diagnostic = result["weight_error_diagnostics"]; self.assertFalse(diagnostic["selection_or_quality_gate"])
        permutation = plan["sites"][0]["permutation"]; inverse = [permutation.index(i) for i in range(256)]
        row = [((255 - i) // 2) / 256 for i in range(256)]
        unpacked = [i - 8 for i in range(16)] + [7 - i for i in range(16)]
        ep, ec = [], []
        for r in range(64):
            decoded = [(.125 if r % 2 == 0 else -.125) * unpacked[i % 32] for i in range(256)]
            ep.extend((decoded[i] - row[i]) ** 2 for i in range(256))
            ec.extend((decoded[inverse[i]] - row[i]) ** 2 for i in range(256))
        layer = diagnostic["layers"][0]
        self.assertAlmostEqual(layer["plain_q4_sse"], math.fsum(ep), places=9)
        self.assertAlmostEqual(layer["permuted_q4_inverse_aligned_sse"], math.fsum(ec), places=9)
        self.assertAlmostEqual(diagnostic["aggregate"]["plain_q4_sse"], 2 * math.fsum(ep), places=9)
        self.assertAlmostEqual(layer["plain_q4_relative_frobenius"], math.sqrt(math.fsum(ep) / layer["reference_squared_frobenius"]))
        # Metadata tampering cannot hide an unselected weight change.
        corrupt = copy.deepcopy(b); next(t for t in corrupt["tensors"] if t["name"] == "decoder.token_embedding.weight")["payload_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Unselected"):
            q.compare_quantized(self.parent, plain, a, candidate, corrupt, proof)
        wrong = self.q4_container(model, "wrong-rows.bin", None)
        with self.assertRaisesRegex(ValueError, "Q4 MLP1 rows"):
            q.compare_quantized(self.parent, plain, a, wrong, q.core.audit_q4(model, wrong), proof)

    def export_patches(self):
        binary = self.root / "synthetic-quantizer"; binary.write_bytes(b"not executable code\n"); binary.chmod(0o700)
        fixed = self.q4_container(self.parent, "fixed-export.bin")
        def export(command, partial, ownership, log, check):
            self.assertEqual(len(command), 4); self.assertEqual(command[-1], "q4_0")
            q.weights.require_owned_artifact(partial, ownership); check()
            with partial.open("wb") as target: target.write(self.fixed.read_bytes())
            log.write_text("Synthetic fixed-byte copy only; no quantizer\n")
            return {"returncode": 0, "cli_reaped": True, "owned_group_present": False, "errors": []}
        self.fixed = fixed
        original = (self.parent.source_sha256, self.parent.bytes, 64, 1, 1, 1, 1, 2)
        stack = __import__("contextlib").ExitStack()
        stack.enter_context(mock.patch.multiple(q, QUANTIZER=binary, QUANTIZER_SHA256=sha(binary.read_bytes())))
        stack.enter_context(mock.patch.object(q.core, "ORIGINALS", {"small": original}))
        stack.enter_context(mock.patch.object(q.core, "run_quantizer", side_effect=export))
        return stack

    def test_full_permuted_export_cli_binds_intermediate_control_and_actual_q4_rows(self):
        model, plan, digest, audit, plan_path, audit_path = self.permuted()
        bindings = {"permutation_plan_path": plan_path, "permutation_plan_sha": digest,
                    "permutation_audit_path": audit_path, "permutation_audit_sha": sha(audit_path.read_bytes())}
        with self.export_patches():
            plain = self.export(self.root / "plain-export")
            control = self.root / "plain-export/export-audit.json"
            bindings.update(plain_control_path=control, plain_control_sha=sha(control.read_bytes()))
            self.fixed = self.q4_container(model, "permuted-fixed.bin", plan)
            args = ["--model", str(model.path), "--sha256", model.source_sha256, "--model-id", "small", "--role", "permuted_q4",
                    "--parent", str(self.parent.path), "--parent-sha256", self.parent.source_sha256,
                    "--output", str(self.root / "candidate-export"), "--permutation-plan", str(plan_path), "--permutation-plan-sha256", digest,
                    "--permutation-audit", str(audit_path), "--permutation-audit-sha256", bindings["permutation_audit_sha"],
                    "--plain-control", str(control), "--plain-control-sha256", bindings["plain_control_sha"]]
            with mock.patch("sys.stdout", new=io.StringIO()) as stdout: self.assertEqual(q.main(args), 0)
            self.assertEqual(json.loads(stdout.getvalue())["state"], "completed")
            result = json.loads((self.root / "candidate-export/export-audit.json").read_text())
            self.assertEqual(result["input_sha256"], model.source_sha256)
            self.assertEqual(result["parent_original_sha256"], self.parent.source_sha256)
            self.assertEqual(result["model_file_bytes"], plain["model_file_bytes"])
            self.assertTrue(result["plain_control_comparison"]["exact_q4_mlp1_row_and_f32_bias_permutation"])
            self.assertFalse(result["plain_control_comparison"]["weight_error_diagnostics"]["selection_or_quality_gate"])
            bad = {**bindings, "permutation_audit_sha": "0" * 64}
            with self.assertRaisesRegex(ValueError, "Metadata checksum"):
                q.run_export(model.path, model.source_sha256, "small", "permuted_q4", self.parent.path,
                             self.parent.source_sha256, self.root / "wrong-audit", **bad)
            target = Path(plain["model_path"]); target.chmod(0o600)
            with target.open("r+b") as stream: stream.seek(-1, 2); stream.write(b"X")
            with self.assertRaisesRegex(ValueError, "Bound artifact checksum"):
                q.run_export(model.path, model.source_sha256, "small", "permuted_q4", self.parent.path,
                             self.parent.source_sha256, self.root / "wrong-control", **bindings)
            self.assertFalse((self.root / "wrong-control").exists())

    def export(self, folder, **kwargs):
        return q.run_export(self.parent.path, self.parent.source_sha256, "small", "plain_q4",
                            self.parent.path, self.parent.source_sha256, folder, **kwargs)

    def test_export_publication_is_exclusive_bound_and_attributed_to_reused_core(self):
        before = self.parent.path.read_bytes()
        with self.export_patches():
            result = self.export(self.root / "plain-export")
            self.assertEqual(result["state"], "completed"); self.assertEqual(result["reused_core"]["sha256"], q.REUSED_CORE_SHA256)
            self.assertFalse(result["reused_core"]["attention_rotation_validator_or_entrypoint_executed"])
            self.assertEqual(result["generator_sha256"], sha(Path(q.__file__).read_bytes()))
            self.assertEqual(result["numeric_worker_environment"], q.NUMERIC_ENVIRONMENT)
            self.assertEqual(result["derived_sha256"], sha((self.root / "plain-export/model.bin").read_bytes()))
            self.assertEqual(self.parent.path.read_bytes(), before)
            with self.assertRaises(ValueError): self.export(self.root / "plain-export")
            with self.assertRaises(ValueError): self.export(self.root / "wrong-sha", timeout=601)

    def test_cancel_corrupt_container_and_publication_tail_never_complete(self):
        marker = self.root / "cancel.request"; marker.touch()
        with self.assertRaises(InterruptedError): self.export(self.root / "pre-cancel", cancel_marker=marker)
        self.assertFalse((self.root / "pre-cancel").exists()); marker.unlink()
        with self.export_patches():
            self.fixed.write_bytes(self.fixed.read_bytes() + b"trailing")
            with self.assertRaisesRegex(ValueError, "trailing"): self.export(self.root / "bad-export")
            self.assertFalse((self.root / "bad-export/model.bin").exists())
            self.assertEqual(json.loads((self.root / "bad-export/export-audit.json").read_text())["state"], "failed")

    def test_tail_cancellation_quarantines_only_owned_published_inode(self):
        marker = self.root / "late.request"; output = self.root / "tail"
        update = q.weights.update_owned_audit
        def cancel_completed(path, value):
            update(path, value)
            if value["state"] == "completed": marker.touch()
        with self.export_patches(), mock.patch.object(q.weights, "update_owned_audit", side_effect=cancel_completed):
            with self.assertRaises(InterruptedError): self.export(output, cancel_marker=marker)
        self.assertFalse((output / "model.bin").exists()); self.assertTrue((output / "model.failed.bin").is_file())
        self.assertEqual(json.loads((output / "export-audit.json").read_text())["state"], "canceled")

    def test_wrong_tools_roles_and_repository_output_fail_before_child_launch(self):
        with self.export_patches(), mock.patch.object(q, "OPERATOR_SHA256", "0" * 64):
            with self.assertRaisesRegex(ValueError, "Pinned reused core"):
                self.export(self.root / "wrong-operator")
        self.assertFalse((self.root / "wrong-operator").exists())
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            q.run_export(self.parent.path, self.parent.source_sha256, "small", "rotated_q4", self.parent.path,
                         self.parent.source_sha256, self.root / "wrong-role")
        checkout = self.root / "git"; checkout.mkdir(); (checkout / ".git").write_text("gitdir: /synthetic")
        with self.assertRaisesRegex(ValueError, "Git checkout"): self.export(checkout / "weights")

    def test_replaced_owned_partial_is_never_published_or_deleted_as_ours(self):
        output = self.root / "replaced"
        def replace(command, partial, owner, log, check):
            partial.rename(partial.with_name("our-retained-inode.bin")); partial.write_bytes(b"foreign replacement")
            log.write_text("synthetic inode replacement\n")
            return {"returncode": 0, "cli_reaped": True, "owned_group_present": False, "errors": []}
        with self.export_patches(), mock.patch.object(q.core, "run_quantizer", side_effect=replace):
            with self.assertRaisesRegex(ValueError, "replaced|owned|identity"):
                self.export(output)
        self.assertEqual((output / "model.partial.bin").read_bytes(), b"foreign replacement")
        self.assertTrue((output / "our-retained-inode.bin").exists())
        self.assertFalse((output / "model.bin").exists())

    def test_owned_quantizer_cancel_and_log_bound_reap_only_synthetic_child(self):
        partial = self.root / "partial.bin"; partial.touch(); owner = q.weights.artifact_identity(partial)
        pidfile = self.root / "pid.txt"; start = time.monotonic()
        foreign = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        command = [sys.executable, "-c", "import os,time,pathlib;pathlib.Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid()));time.sleep(20)"]
        def cancel():
            if pidfile.exists(): raise InterruptedError("synthetic cancel")
            if time.monotonic() - start > 4: raise TimeoutError("synthetic child startup bound")
        try:
            with self.assertRaises(InterruptedError): q.core.run_quantizer(command, partial, owner, self.root / "owned.log", cancel)
            self.assertIsNone(foreign.poll())
            with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)
        finally:
            foreign.terminate()
            try: foreign.wait(timeout=2)
            except subprocess.TimeoutExpired: foreign.kill(); foreign.wait(timeout=2)
        with mock.patch.object(q.core, "MAX_LOG_BYTES", 1), self.assertRaisesRegex(ValueError, "log exceeded"):
            q.core.run_quantizer([sys.executable, "-c", "print('fixed synthetic log',flush=True);import time;time.sleep(10)"],
                                partial, owner, self.root / "overbound.log", lambda: None)


if __name__ == "__main__": unittest.main()
