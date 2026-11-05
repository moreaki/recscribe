"""Synthetic byte/math contracts; never reads a real corpus or runs ASR."""
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "quality/affine-bias-recipes.py"
SPEC = importlib.util.spec_from_file_location("quality_affine_bias", SCRIPT)
affine = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = affine
SPEC.loader.exec_module(affine)
weights = affine.weights


class QualityAffineBiasTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.np = affine.numpy_runtime() # Explicit missing dependency fails, never a silent skip.

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "synthetic.bin"
        header = dict(zip(weights.HEADER_FIELDS, [4, 3, 4, 2, 1, 2, 4, 2, 1, 2, 1]))
        with self.source.open("wb") as stream:
            stream.write(struct.pack("<12i", weights.MAGIC, *header.values()))
            stream.write(struct.pack("<2i", 2, 3) + struct.pack("<6f", *([1.] * 6)))
            stream.write(struct.pack("<i", 1) + struct.pack("<i", 3) + b"one")
            for name, (shape, dtype) in weights.expected_tensors(header).items():
                values = [.125] * math.prod(shape)
                if name in ["decoder.blocks.0.cross_attn.out.weight", "decoder.blocks.0.cross_attn.value.weight"]:
                    values = [float(i == j) for i in range(4) for j in range(4)]
                if name == "decoder.blocks.0.cross_attn.value.bias": values = [.1, .2, .01, .02]
                if name == "decoder.blocks.0.cross_attn.out.bias": values = [.3, -.4, .6, -.8]
                encoded = name.encode(); code = "e" if dtype == "f16" else "f"
                stream.write(struct.pack("<3i", len(shape), len(encoded), 1 if dtype == "f16" else 0))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                stream.write(struct.pack("<" + code * len(values), *values))
        self.digest = weights.hash_file(self.source)

    def tearDown(self):
        self.temporary.cleanup()

    def model(self):
        return weights.inspect_model(self.source)

    def arguments(self):
        return [{"id": "tiny", "path": str(self.source), "sha256": self.digest}]

    def prepare_toy(self, output, **kwargs):
        # Production architecture checks remain tested independently. The tiny
        # structural fixture exercises the same generation/retention path cheaply.
        with patch.object(affine, "validate_architecture"):
            return affine.prepare(self.arguments(), output, evidence=["synthetic-development-only"], author="unit-test", **kwargs)

    def test_non_square_serialization_and_exact_head_boundaries(self):
        out = affine.serialized_array(range(1, 13), [4, 3], self.np)
        value = affine.serialized_array([1, 0, 0, 1, 2, 0, 0, 3], [2, 4], self.np)
        bias = self.np.array([1., 2., 3., 4.])
        self.assertEqual(out.tolist(), [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]])
        rows = affine.head_statistics(out, value, bias, 2, self.np)
        for head in range(2):
            columns = range(head * 2, head * 2 + 2)
            product = [[math.fsum(float(out[i, k]) * float(value[k, j]) for k in columns) for j in range(2)] for i in range(3)]
            content = math.sqrt(math.fsum(x*x for row in product for x in row))
            constant = [math.fsum(float(out[i, k]) * float(bias[k]) for k in columns) for i in range(3)]
            self.assertAlmostEqual(rows[head]["head_OV_frobenius"], content)
            self.assertAlmostEqual(rows[head]["head_constant_l2"], math.sqrt(math.fsum(x*x for x in constant)))
        with self.assertRaisesRegex(ValueError, "boundaries"):
            affine.head_statistics(out, value, bias, 3, self.np)
        with self.assertRaisesRegex(ValueError, "element count"):
            affine.serialized_array([1, 2], [2, 2], self.np)

    def test_selection_is_deterministic_and_does_not_mask_or_search_heads(self):
        tied = [{"layer": 1, "head": 0, "ratio": .5}, {"layer": 0, "head": 1, "ratio": .5}, {"layer": 0, "head": 0, "ratio": .5}]
        self.assertEqual(affine.selected_head(tied), tied[-1])
        record, candidate, control = affine.analyze_model(self.model(), "synthetic", ["development"], "test", self.np, weights.no_cancel)
        self.assertEqual((record["selected"]["layer"], record["selected"]["head"]), (0, 0))
        self.assertEqual(candidate["edits"][0]["start"], 0)
        self.assertEqual(candidate["edits"][0]["count"], 2)
        self.assertEqual(candidate["edits"][0]["factor"], .9)
        self.assertEqual(len(candidate["edits"]), 1)
        self.assertEqual(len(control["edits"]), 5)
        self.assertEqual(weights.hash_file(self.source), self.digest)

    def test_f32_compensation_matches_existing_applier_and_leaves_all_other_bytes(self):
        model = self.model()
        record, candidate, control = affine.analyze_model(model, "synthetic", ["development"], "test", self.np, weights.no_cancel)
        original = self.source.read_bytes()
        changed = self.root / "candidate"; compensated = self.root / "control"
        weights.apply_recipe(self.source, candidate, changed)
        weights.apply_recipe(self.source, control, compensated)
        self.assertEqual(self.source.read_bytes(), original)
        vb = model.tensor("decoder.blocks.0.cross_attn.value.bias")
        ob = model.tensor("decoder.blocks.0.cross_attn.out.bias")
        def read(path, tensor):
            with path.open("rb") as stream:
                stream.seek(tensor.offset)
                return struct.unpack("<4f", stream.read(16))
        old_v = read(self.source, vb); new_v = read(compensated / "model.bin", vb)
        old_o = read(self.source, ob); new_o = read(compensated / "model.bin", ob)
        self.assertEqual(new_v[:2], tuple(affine.f32(x * .9) for x in old_v[:2]))
        self.assertEqual(new_v[2:], old_v[2:])
        residual = [math.fsum([new_v[i], -old_v[i], new_o[i], -old_o[i]]) for i in range(4)]
        self.assertLess(math.sqrt(math.fsum(x*x for x in residual)), 1e-5 * record["expected_effect"]["removed_input_independent_offset_l2"])
        for audit_path in [changed, compensated]:
            audit = json.loads((audit_path / "edit-audit.json").read_text())
            self.assertEqual(audit["state"], "completed")
            self.assertEqual(audit["source_sha256"], self.digest)
            self.assertIn("unchanged_regions_sha256", audit)

    def test_nonfinite_zero_norms_noops_and_overflow_are_rejected(self):
        eye = self.np.eye(4); bias = self.np.ones(4)
        for value in [self.np.zeros((4, 4)), self.np.full((4, 4), self.np.nan)]:
            with self.assertRaises(ValueError): affine.head_statistics(eye, value, bias, 2, self.np)
        with self.assertRaisesRegex(ValueError, "representable F32 change"):
            affine.compensation(eye[:, :2], self.np.zeros(2), self.np.ones(4), self.np)
        for value in [float("inf"), float("nan"), 1e100]:
            with self.assertRaises(ValueError): affine.f32(value)
        for rows in [[], [{"layer": 0, "head": 0, "ratio": float("inf")}]]:
            with self.assertRaises(ValueError): affine.selected_head(rows)
        tensor = self.model().tensor("encoder.positional_embedding")
        with self.source.open("r+b") as stream:
            stream.seek(tensor.offset); stream.write(struct.pack("<f", float("nan")))
        self.digest = weights.hash_file(self.source)
        with self.assertRaisesRegex(ValueError, "Non-finite"):
            self.prepare_toy(self.root / "nonfinite")
        self.assertTrue((self.root / "nonfinite/FAILED.json").exists())

    def test_complete_generation_has_exact_hashes_no_models_and_refuses_overwrite(self):
        output = self.root / "recipes"
        result = self.prepare_toy(output)
        self.assertEqual(result["recipe_count"], 2)
        self.assertTrue(result["originals_unchanged"])
        self.assertFalse(result["asr_executed"])
        self.assertFalse(result["weights_modified"])
        self.assertFalse(list(output.rglob("*.bin")))
        for name, digest in result["models"][0]["files"].items():
            self.assertEqual(weights.hash_file(output / "tiny" / name), digest)
        record = json.loads((output / "tiny/selection.json").read_text())
        self.assertEqual(record["provenance"]["generator_sha256"], weights.hash_file(SCRIPT))
        self.assertEqual(record["provenance"]["editor_sha256"], weights.hash_file(Path(weights.__file__)))
        self.assertEqual(record["provenance"]["source_after_sha256"], self.digest)
        with self.assertRaises(FileExistsError): self.prepare_toy(output)

    def test_source_replacement_and_changes_during_publication_fail_closed(self):
        model = self.model()
        self.source.write_bytes(self.source.read_bytes() + b"x")
        with self.assertRaisesRegex(ValueError, "changed after format inspection"):
            affine.analyze_model(model, "test", ["development"], "test", self.np, weights.no_cancel)
        self.source.write_bytes(self.source.read_bytes()[:-1])
        output = self.root / "changed"
        save = weights.write_new_json
        def mutate_after_record(path, value):
            save(path, value)
            if path.name == "selection.json":
                with self.source.open("r+b") as stream:
                    stream.seek(model.tensor("encoder.positional_embedding").offset)
                    stream.write(struct.pack("<f", .5))
        with patch.object(weights, "write_new_json", side_effect=mutate_after_record):
            with self.assertRaisesRegex(ValueError, "changed after format inspection"):
                self.prepare_toy(output)
        self.assertTrue((output / "FAILED.json").exists())
        self.assertFalse((output / "COMPLETED.json").exists())

    def test_partial_outputs_and_cancellation_keep_evidence_never_completion(self):
        output = self.root / "partial"; save = weights.write_new_json
        def fail_recipe(path, value):
            if path.name == "candidate.recipe.json": raise OSError("synthetic full disk")
            return save(path, value)
        with patch.object(weights, "write_new_json", side_effect=fail_recipe):
            with self.assertRaisesRegex(OSError, "full disk"): self.prepare_toy(output)
        self.assertTrue((output / "tiny/selection.json").exists())
        self.assertTrue((output / "FAILED.json").exists())
        self.assertFalse((output / "COMPLETED.json").exists())
        canceled = self.root / "canceled"
        def cancel():
            if (canceled / "tiny/selection.json").exists(): raise InterruptedError("synthetic stop")
        with self.assertRaises(InterruptedError): self.prepare_toy(canceled, check=cancel)
        self.assertEqual(json.loads((canceled / "FAILED.json").read_text())["state"], "cancelled")
        self.assertFalse((canceled / "COMPLETED.json").exists())
        self.assertEqual(weights.hash_file(self.source), self.digest)

    def test_architecture_model_time_dependency_and_cancel_bounds(self):
        with self.assertRaisesRegex(ValueError, "architecture"):
            affine.prepare(self.arguments(), self.root / "bad-architecture", evidence=["development"], author="test")
        for models in [[], self.arguments() * 4, self.arguments() * 2]:
            with self.assertRaises(ValueError):
                affine.prepare(models, self.root / "bad", evidence=["development"], author="test")
        for seconds in [0, 601, float("nan")]:
            with self.assertRaises(ValueError): self.prepare_toy(self.root / "time", seconds=seconds)
        with patch.object(weights.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaises(TimeoutError): self.prepare_toy(self.root / "deadline", seconds=1)
        self.assertFalse((self.root / "deadline").exists())
        flag = self.root / "cancel.request"; flag.touch()
        with self.assertRaises(InterruptedError): self.prepare_toy(self.root / "pre-cancel", cancel=flag)
        self.assertFalse((self.root / "pre-cancel").exists())
        with patch.object(affine.importlib, "import_module", side_effect=ImportError("numpy absent")):
            with self.assertRaisesRegex(ValueError, "requires an explicitly installed NumPy"):
                self.prepare_toy(self.root / "missing-dependency")
        self.assertFalse((self.root / "missing-dependency").exists())
        with patch.object(affine, "MAX_MODEL_BYTES", 10):
            with self.assertRaisesRegex(ValueError, "file-size budget"): self.prepare_toy(self.root / "size")


if __name__ == "__main__":
    unittest.main()
