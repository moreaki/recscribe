"""Toy GGML container/provenance/lifecycle tests; no models, NN or quantization."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("attention_q4", Path(__file__).resolve().parents[1] / "quality/quantize-attention-rotation.py")
q4 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(q4)


def sha(data): return hashlib.sha256(data).hexdigest()


class AttentionQuantizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.parent = self.f16("original.bin")

    def tearDown(self): self.temporary.cleanup()

    def f16(self, name):
        header = dict(zip(q4.weights.HEADER_FIELDS, (2, 2, 64, 1, 1, 2, 64, 1, 1, 1, 1)))
        path = self.root / name
        with path.open("xb") as stream:
            stream.write(struct.pack("<12i", q4.weights.MAGIC, *header.values()))
            stream.write(struct.pack("<2i", 1, 201) + bytes(201 * 4))
            stream.write(struct.pack("<i", 2))
            for value in (b"a", b"b"): stream.write(struct.pack("<i", len(value)) + value)
            for tensor, (shape, dtype) in q4.weights.expected_tensors(header).items():
                encoded = tensor.encode(); kind, width = (0, 4) if dtype == "f32" else (1, 2)
                stream.write(struct.pack("<3i", len(shape), len(encoded), kind))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                stream.write(bytes(width * __import__("math").prod(shape)))
        return q4.weights.inspect_model(path, limits=q4.LIMITS)

    def q4_container(self, source, name, *, scale=-.125, altered=None, forced_passthrough=None):
        """Serialize fixed test blocks, not a quantizer or quality reference."""
        path = self.root / name
        first = source.tensors[0]
        prefix_end = first.offset - 12 - 4 * len(first.shape) - len(first.name.encode())
        with source.path.open("rb") as original, path.open("xb") as target:
            prefix = bytearray(original.read(prefix_end)); prefix[44:48] = struct.pack("<i", q4.Q4_FTYPE)
            target.write(prefix)
            for tensor in source.tensors:
                quantize = len(tensor.shape) == 2 and tensor.name not in q4.SKIP and tensor.name != forced_passthrough
                encoded = tensor.name.encode(); kind = q4.Q4_TYPE if quantize else tensor.type_id
                target.write(struct.pack("<3i", len(tensor.shape), len(encoded), kind))
                target.write(struct.pack("<" + "i" * len(tensor.shape), *tensor.shape) + encoded)
                if quantize:
                    packed = 0x89 if tensor.name == altered else 0x88
                    target.write((struct.pack("<e", scale) + bytes([packed]) * 16) * (tensor.elements // 32))
                else:
                    original.seek(tensor.offset); target.write(original.read(tensor.bytes))
        return path

    def rotated(self):
        path = self.root / "rotated.bin"; shutil.copyfile(self.parent.path, path)
        name = "encoder.blocks.0.attn.query.bias"; tensor = self.parent.tensor(name)
        with path.open("r+b") as stream: stream.seek(tensor.offset); stream.write(struct.pack("<f", 1))
        return q4.weights.inspect_model(path, limits=q4.LIMITS)

    def rotation_metadata(self, rotated):
        domain = b"recscribe-whisper-attention-rotation-v1\0"; targets = q4.attention_targets(self.parent.architecture)
        sites = sorted({name.rsplit(".", 2)[0] for name in targets})
        records = []
        for site in sites:
            masks = []
            for pair in ("qk", "vo"):
                digest = hashlib.sha256(domain + bytes.fromhex(self.parent.source_sha256) + site.encode() + b"\0" + struct.pack("<I", 0) + pair.encode()).digest()
                masks.append({"head": 0, "pair": pair, "sha256": digest.hex(), "mask_first8_hex": digest[:8].hex()})
            records.append({"site": site, "heads": masks})
        plan = {"schema_version": q4.ROTATION_VERSION, "model_id": "small", "source_sha256": self.parent.source_sha256,
                "head_channels": 64, "state": 64, "head_count": 1, "sites": records, "domain_hex": domain.hex(),
                "mask_encoding": "domain+sha_raw32+site_ASCII+NUL+head_u32LE+pair_ASCII",
                "sign_encoding": "first8_SHA256_bytes_in_order; channel_j=byte[j//8]_bit[j%8]_LSB_first;1=-1;0=+1",
                "matrix": "normalized_Sylvester_H64_times_diagonal_signs; H64_coefficients=+/-1/8",
                "seed_search": False, "fitting": False, "runtime_operations_added": 0}
        plan_sha = sha(json.dumps(plan).encode()); edits, ranges = [], []
        with self.parent.path.open("rb") as original, rotated.path.open("rb") as target:
            for name, (operation, pair) in targets.items():
                tensor = self.parent.tensor(name)
                a = q4.hash_range(original, tensor.offset, tensor.bytes, lambda: None)
                b = q4.hash_range(target, tensor.offset, tensor.bytes, lambda: None)
                edits.append({"tensor": name, "shape": list(tensor.shape), "dtype": tensor.dtype, "operation": operation,
                              "pair": pair, "selected_elements": tensor.elements, "changed_elements": int(a != b),
                              "before_sha256": a, "after_sha256": b})
                ranges.append((tensor.offset, tensor.offset + tensor.bytes))
        audit = {"schema_version": q4.ROTATION_VERSION, "state": "completed", "model_id": "small",
                 "source_sha256": self.parent.source_sha256, "derived_sha256": rotated.source_sha256,
                 "rotation_plan_sha256": plan_sha, "file_bytes": self.parent.bytes, "architecture": self.parent.architecture,
                 "outside_declared_changed_bytes": 0, "training_used": False, "fitting_used": False, "seed_search_used": False,
                 "parser_sha256": q4.PARSER_SHA256, "generator_sha256": q4.ROTATION_GENERATOR_SHA256,
                 "selected_tensor_count": len(edits), "selected_elements": sum(e["selected_elements"] for e in edits),
                 "edits": edits, "unchanged_regions_sha256": q4.weights.unchanged_regions_equal(self.parent.path, rotated.path, self.parent.bytes, ranges, lambda: None)}
        return plan, plan_sha, audit

    def plain_audit(self, path, static):
        return {"schema_version": q4.VERSION, "state": "completed", "role": "plain_q4", "model_id": "small",
                "parent_sha256": self.parent.source_sha256, "input_sha256": self.parent.source_sha256,
                "kind": "compression", "parent_original_id": "small", "parent_original_sha256": self.parent.source_sha256,
                "quantization": {"format": "q4_0", "ftype": 2, "file_header_ftype": 2002},
                "quantizer_sha256": q4.QUANTIZER_SHA256, "static_validation": static,
                "model_path": str(path), "model_file_bytes": path.stat().st_size, "derived_sha256": sha(path.read_bytes())}

    def test_q4_walk_covers_embeddings_all_2d_and_exact_skip_passthrough(self):
        path = self.q4_container(self.parent, "plain.bin")
        result = q4.audit_q4(self.parent, path)
        self.assertEqual(result["ftype"], 2002); self.assertEqual(result["block_bytes"], 18)
        self.assertEqual(result["tensor_count"], len(self.parent.tensors))
        tensors = {t["name"]: t for t in result["tensors"]}
        self.assertTrue(tensors["decoder.token_embedding.weight"]["quantized"])
        self.assertFalse(tensors["encoder.positional_embedding"]["quantized"])
        self.assertFalse(tensors["decoder.positional_embedding"]["quantized"])
        self.assertFalse(tensors["encoder.conv1.bias"]["quantized"])
        self.assertFalse(tensors["encoder.conv2.weight"]["quantized"])
        self.assertTrue(result["architecture_mel_vocabulary_unchanged"])
        self.assertFalse(result["quantization_correctness_or_native_loading_claimed"])
        self.assertEqual(self.parent.source_sha256, sha(self.parent.path.read_bytes()))

    def test_nonfinite_half_scales_wrong_embedding_type_and_trailing_bytes_fail(self):
        for index, scale in enumerate((float("inf"), float("-inf"), float("nan"))):
            with self.subTest(scale=scale), self.assertRaisesRegex(ValueError, "Nonfinite Q4"):
                q4.audit_q4(self.parent, self.q4_container(self.parent, f"nonfinite{index}.bin", scale=scale))
        path = self.q4_container(self.parent, "embedding.bin", forced_passthrough="decoder.token_embedding.weight")
        with self.assertRaisesRegex(ValueError, "Wrong Q4_0"): q4.audit_q4(self.parent, path)
        path = self.q4_container(self.parent, "trailing.bin")
        with path.open("ab") as stream: stream.write(b"x")
        with self.assertRaisesRegex(ValueError, "extra tensors/trailing"): q4.audit_q4(self.parent, path)

    def test_corrupt_header_prefix_name_shape_dtype_and_passthrough_are_rejected(self):
        original_path = self.q4_container(self.parent, "valid.bin")
        valid = original_path.read_bytes(); static = q4.audit_q4(self.parent, original_path)
        matrix = next(t for t in static["tensors"] if t["quantized"])
        skipped = next(t for t in static["tensors"] if t["name"] == "decoder.positional_embedding")
        header = matrix["offset"] - len(matrix["name"].encode()) - 4 * len(matrix["shape"]) - 12
        corruptions = [(44, struct.pack("<i", 2009)), (56, b"\1"), (header, struct.pack("<i", 4)),
                       (header + 8, struct.pack("<i", 7)), (header + 12, struct.pack("<i", 999)),
                       (matrix["offset"] - len(matrix["name"]), b"X"), (skipped["offset"], b"\1")]
        for index, (offset, replacement) in enumerate(corruptions):
            data = bytearray(valid); data[offset:offset + len(replacement)] = replacement
            path = self.root / f"corrupt{index}.bin"; path.write_bytes(data)
            with self.subTest(index=index), self.assertRaises(ValueError): q4.audit_q4(self.parent, path)
        path = self.root / "truncated.bin"; path.write_bytes(valid[:-1])
        with self.assertRaisesRegex(ValueError, "Truncated"): q4.audit_q4(self.parent, path)

    def test_static_audit_is_cancellable_bounded_and_rejects_symlink(self):
        path = self.q4_container(self.parent, "cancel.bin")
        def cancel(): raise InterruptedError("synthetic cancellation")
        with self.assertRaises(InterruptedError): q4.audit_q4(self.parent, path, cancel)
        with mock.patch.object(q4, "MAX_MODEL_BYTES", path.stat().st_size - 1), self.assertRaisesRegex(ValueError, "size bound"):
            q4.audit_q4(self.parent, path)
        alias = self.root / "alias.bin"; alias.symlink_to(path)
        with self.assertRaisesRegex(ValueError, "nonsymlink"): q4.audit_q4(self.parent, alias)

    def test_rotation_binding_requires_actual_target_hashes_fixed_masks_and_generator(self):
        rotated = self.rotated(); plan, digest, audit = self.rotation_metadata(rotated)
        proof = q4.validate_rotation(self.parent, rotated, "small", plan, digest, audit)
        self.assertEqual(proof["target_count"], 18)
        for field, value in (("generator_sha256", "0" * 64), ("derived_sha256", self.parent.source_sha256),
                             ("outside_declared_changed_bytes", False), ("selected_elements", 1)):
            corrupted = copy.deepcopy(audit); corrupted[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                q4.validate_rotation(self.parent, rotated, "small", plan, digest, corrupted)
        bad = copy.deepcopy(plan); bad["sites"][0]["heads"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "mask recipe"): q4.validate_rotation(self.parent, rotated, "small", bad, digest, audit)
        bad = copy.deepcopy(audit); bad["edits"][0]["after_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "payload binding"): q4.validate_rotation(self.parent, rotated, "small", plan, digest, bad)
        bad = copy.deepcopy(audit); bad["edits"].pop()
        with self.assertRaisesRegex(ValueError, "target count"): q4.validate_rotation(self.parent, rotated, "small", plan, digest, bad)

    def test_plain_rotated_comparison_proves_unmodified_tensor_payloads_and_size(self):
        rotated = self.rotated(); plain = self.q4_container(self.parent, "plain.bin")
        candidate = self.q4_container(rotated, "candidate.bin")
        a, b = q4.audit_q4(self.parent, plain), q4.audit_q4(rotated, candidate)
        audit = self.plain_audit(plain, a); targets = set(q4.attention_targets(self.parent.architecture))
        result = q4.compare_plain_control(audit, b, targets, "small", self.parent.source_sha256)
        self.assertTrue(result["same_file_bytes"]); self.assertTrue(result["unmodified_tensors_byte_identical"])
        self.assertEqual(result["changed_attention_target_payloads"], 1)
        changed = self.q4_container(rotated, "wrong-mlp.bin", altered="decoder.blocks.0.mlp.0.weight")
        corrupted = q4.audit_q4(rotated, changed)
        with self.assertRaisesRegex(ValueError, "Unmodified tensor differs"):
            q4.compare_plain_control(audit, corrupted, targets, "small", self.parent.source_sha256)
        corrupted = copy.deepcopy(b); corrupted["model_file_bytes"] += 1
        with self.assertRaisesRegex(ValueError, "sizes or prefix"):
            q4.compare_plain_control(audit, corrupted, targets, "small", self.parent.source_sha256)
        bad = copy.deepcopy(audit); bad["parent_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "control identity"):
            q4.compare_plain_control(bad, b, targets, "small", self.parent.source_sha256)

    def test_strict_hashed_metadata_and_external_output_exclusivity(self):
        path = self.root / "duplicate.json"; path.write_text('{"x":1,"x":2}')
        with self.assertRaisesRegex(ValueError, "Duplicate"): q4.read_metadata(path, sha(path.read_bytes()))
        with self.assertRaisesRegex(ValueError, "checksum/identity"): q4.read_metadata(path, "0" * 64)
        repo = self.root / "checkout"; repo.mkdir(); (repo / ".git").write_text("gitdir: /synthetic")
        with self.assertRaisesRegex(ValueError, "Git checkout"): q4.external_output(repo / "models")
        existing = self.root / "existing"; existing.mkdir()
        with self.assertRaisesRegex(ValueError, "new absolute"): q4.external_output(existing)

    def fake_official_export(self, command, partial, ownership, log, check):
        self.assertEqual(command[-1], "q4_0"); self.assertEqual(len(command), 4)
        self.assertEqual(Path(command[1]), getattr(self, "expected_source", self.parent.path))
        q4.weights.require_owned_artifact(partial, ownership)
        with partial.open("wb") as out, self.fixed_q4.open("rb") as source: shutil.copyfileobj(source, out)
        log.write_text("Synthetic fixed-container copy; no quantizer executed\n")
        return {"returncode": 0, "cli_reaped": True, "owned_group_present": False, "signals": [], "errors": []}

    def export_patches(self):
        self.fixed_q4 = self.q4_container(self.parent, "fixed-q4.bin")
        binary = self.root / "not-executed-quantizer"; binary.write_text("synthetic fixture, never executed\n"); binary.chmod(0o700)
        original = (self.parent.source_sha256, self.parent.bytes, 64, 1, 1, 1, 1, 2)
        return mock.patch.multiple(q4, QUANTIZER=binary, QUANTIZER_SHA256=sha(binary.read_bytes()), ORIGINALS={"small": original},
                                   run_quantizer=self.fake_official_export)

    def export(self, output, **kwargs):
        return q4.run_export(self.parent.path, self.parent.source_sha256, "small", "plain_q4",
                             self.parent.path, self.parent.source_sha256, output, **kwargs)

    def test_export_publishes_only_after_static_proof_and_preserves_parent(self):
        before = self.parent.path.read_bytes(); output = self.root / "export"
        with self.export_patches(): result = self.export(output)
        self.assertEqual(result["state"], "completed")
        self.assertEqual(result["derived_sha256"], sha((output / "model.bin").read_bytes()))
        self.assertEqual(result["original_after_sha256"], self.parent.source_sha256)
        self.assertEqual(result["numeric_worker_environment"], q4.NUMERIC_ENVIRONMENT)
        self.assertEqual((output / "model.bin").stat().st_mode & 0o777, 0o400)
        self.assertFalse(result["recognition_or_model_initialization_executed"])
        self.assertEqual(self.parent.path.read_bytes(), before)
        with self.assertRaisesRegex(ValueError, "new absolute"): self.export(output)

    def test_cancel_before_launch_or_after_quantizer_keeps_no_completed_artifact(self):
        marker = self.root / "cancel.request"; marker.touch()
        output = self.root / "pre-cancel"
        with self.assertRaises(InterruptedError): self.export(output, cancel_marker=marker)
        self.assertFalse(output.exists()); marker.unlink()
        output = self.root / "post-cancel"
        with self.export_patches():
            original = q4.run_quantizer
            def cancel_after(*args):
                result = original(*args); marker.touch(); return result
            with mock.patch.object(q4, "run_quantizer", cancel_after), self.assertRaises(InterruptedError):
                self.export(output, cancel_marker=marker)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertEqual(json.loads((output / "export-audit.json").read_text())["state"], "canceled")

    def test_rotated_export_binds_physical_intermediate_and_completed_plain_control(self):
        rotated = self.rotated(); plan, plan_sha, rotation = self.rotation_metadata(rotated)
        plan_path, rotation_path = self.root / "rotation-plan.json", self.root / "rotation-audit.json"
        plan_path.write_bytes(json.dumps(plan).encode()); rotation_path.write_bytes(json.dumps(rotation).encode())
        with self.export_patches():
            plain = self.export(self.root / "plain-export")
            control = self.root / "plain-export/export-audit.json"
            bindings = {"rotation_plan_path": plan_path, "rotation_plan_sha": plan_sha,
                        "rotation_audit_path": rotation_path, "rotation_audit_sha": sha(rotation_path.read_bytes()),
                        "plain_control_path": control, "plain_control_sha": sha(control.read_bytes())}
            self.fixed_q4 = self.q4_container(rotated, "rotated-fixture.bin"); self.expected_source = rotated.path
            result = q4.run_export(rotated.path, rotated.source_sha256, "small", "rotated_q4", self.parent.path,
                                   self.parent.source_sha256, self.root / "rotated-export", **bindings)
            self.assertEqual(result["state"], "completed"); self.assertEqual(result["kind"], "combined")
            self.assertEqual(result["input_sha256"], rotated.source_sha256)
            self.assertEqual(result["parent_original_sha256"], self.parent.source_sha256)
            self.assertEqual(result["model_file_bytes"], plain["model_file_bytes"])
            self.assertTrue(result["plain_control_comparison"]["unmodified_tensors_byte_identical"])
            self.assertEqual(result["plain_control_comparison"]["changed_attention_target_payloads"], 1)
            bad = {**bindings, "rotation_audit_sha": "0" * 64}
            with self.assertRaisesRegex(ValueError, "Metadata checksum/identity"):
                q4.run_export(rotated.path, rotated.source_sha256, "small", "rotated_q4", self.parent.path,
                              self.parent.source_sha256, self.root / "wrong-binding", **bad)
            self.assertFalse((self.root / "wrong-binding").exists())
            control_model = self.root / "plain-export/model.bin"; control_model.chmod(0o600)
            with control_model.open("r+b") as f: f.seek(-1, os.SEEK_END); f.write(b"X")
            with self.assertRaisesRegex(ValueError, "Bound artifact checksum/identity"):
                q4.run_export(rotated.path, rotated.source_sha256, "small", "rotated_q4", self.parent.path,
                              self.parent.source_sha256, self.root / "changed-control", **bindings)
            self.assertFalse((self.root / "changed-control").exists())

    def test_bad_container_never_publishes_and_tail_cancel_quarantines_our_model(self):
        output = self.root / "bad-output"
        with self.export_patches():
            with self.fixed_q4.open("ab") as stream: stream.write(b"bad")
            with self.assertRaisesRegex(ValueError, "trailing"): self.export(output)
        self.assertFalse((output / "model.bin").exists())
        self.assertEqual(json.loads((output / "export-audit.json").read_text())["state"], "failed")
        self.fixed_q4.unlink(); (self.root / "not-executed-quantizer").unlink()
        output = self.root / "tail-cancel"; marker = self.root / "tail.request"
        with self.export_patches():
            update = q4.weights.update_owned_audit
            def cancel_completed(path, value):
                update(path, value)
                if value["state"] == "completed": marker.touch()
            with mock.patch.object(q4.weights, "update_owned_audit", cancel_completed), self.assertRaises(InterruptedError):
                self.export(output, cancel_marker=marker)
        self.assertFalse((output / "model.bin").exists()); self.assertTrue((output / "model.failed.bin").exists())
        self.assertEqual(json.loads((output / "export-audit.json").read_text())["state"], "canceled")

    def test_cli_initialization_fixes_numeric_env_before_any_numpy_import(self):
        script = str(Path(q4.__file__).resolve())
        code = "import os,runpy,sys,json;sys.argv=[sys.argv[1],'--help'];\ntry:runpy.run_path(sys.argv[0],run_name='__main__')\nexcept SystemExit:pass\nprint(json.dumps({k:os.environ[k] for k in " + repr(tuple(q4.NUMERIC_ENVIRONMENT)) + "}))"
        child = subprocess.run([sys.executable, "-c", code, script], capture_output=True, text=True,
                               env={**os.environ, **{key: "9" for key in q4.NUMERIC_ENVIRONMENT}}, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(json.loads(child.stdout.splitlines()[-1]), q4.NUMERIC_ENVIRONMENT)

    def test_owned_group_cancellation_reaps_child_and_preserves_foreign_process(self):
        partial = self.root / "partial.bin"; partial.touch(); ownership = q4.weights.artifact_identity(partial)
        pidfile = self.root / "owned.pid"
        command = [sys.executable, "-c", "import os,time,pathlib;pathlib.Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid()));time.sleep(20)"]
        foreign = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        start = time.monotonic()
        def cancel():
            if pidfile.exists(): raise InterruptedError("Synthetic owned-only cancellation")
            if time.monotonic() - start > 3: raise TimeoutError("Synthetic child did not start")
        try:
            with self.assertRaises(InterruptedError): q4.run_quantizer(command, partial, ownership, self.root / "child.log", cancel)
            self.assertIsNone(foreign.poll())
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        finally:
            foreign.terminate()
            try: foreign.wait(timeout=2)
            except subprocess.TimeoutExpired: foreign.kill(); foreign.wait(timeout=2)


if __name__ == "__main__": unittest.main()
