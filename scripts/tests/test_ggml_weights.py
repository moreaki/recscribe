import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "quality/ggml_weights.py"
SPEC = importlib.util.spec_from_file_location("ggml_weights", SCRIPT)
weights = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = weights
SPEC.loader.exec_module(weights)


class GGMLWeightTests(unittest.TestCase):
    """Small structural fixtures exercise byte contracts, not ASR capability."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "synthetic-model.bin"
        self.header = dict(zip(weights.HEADER_FIELDS, [4, 3, 4, 2, 1, 2, 4, 2, 1, 2, 1]))
        self.write_model(self.source)

    def tearDown(self):
        self.temporary.cleanup()

    def write_model(self, path, value=0.25):
        with path.open("wb") as stream:
            stream.write(struct.pack("<12i", weights.MAGIC, *self.header.values()))
            stream.write(struct.pack("<2i", 2, 3) + struct.pack("<6f", *([1.0] * 6)))
            tokens = [b"one", b"", b"\xff"]
            stream.write(struct.pack("<i", len(tokens)))
            for token in tokens:
                stream.write(struct.pack("<i", len(token)) + token)
            for name, (shape, dtype) in weights.expected_tensors(self.header).items():
                code = "e" if dtype == "f16" else "f"
                encoded = name.encode()
                stream.write(struct.pack("<3i", len(shape), len(encoded), 1 if dtype == "f16" else 0))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                stream.write(struct.pack("<" + code, value) * __import__("math").prod(shape))

    def model(self):
        return weights.inspect_model(self.source)

    def recipe(self):
        tensor = self.model().tensor("decoder.blocks.0.attn.value.weight")
        return {"schema_version": "1.0", "format": weights.FORMAT,
                "input_sha256": weights.hash_file(self.source),
                "hypothesis": "Synthetic serialization control; no recognition claim",
                "development_evidence": ["synthetic-test"], "author": "unit-test fixture",
                "edits": [{"tensor": tensor.name, "shape": list(tensor.shape), "dtype": tensor.dtype,
                           "op": "scale", "start": 4, "count": 4, "factor": 2.0}]}

    def test_parser_retains_exact_vocab_shapes_offsets_and_precision(self):
        model = self.model()
        self.assertEqual(model.architecture, self.header)
        self.assertEqual(model.mel_shape, (2, 3))
        self.assertEqual([model.token(i) for i in range(3)], [b"one", b"", b"\xff"])
        self.assertEqual(model.architecture["n_vocab"], 4)  # Missing special token is runtime-synthesized.
        self.assertEqual(model.tensor("encoder.conv1.bias").shape, (1, 4))
        self.assertEqual(model.tensor("decoder.token_embedding.weight").dtype, "f16")
        self.assertEqual(model.tensor("decoder.positional_embedding").dtype, "f32")
        report = weights.model_report(model, statistics=True, include_vocabulary=True)
        self.assertEqual(report["stored_tensor_elements"], sum(t.elements for t in model.tensors))
        self.assertTrue(all(s["mean"] == 0.25 and s["finite_elements"] > 0 for s in report["statistics"]))
        self.assertEqual(report["stored_vocabulary"][2]["base64"], "/w==")

    def test_parser_rejects_truncation_quantization_and_incompatible_tensor_layout(self):
        original = self.source.read_bytes()
        for length in [0, 4, 48, 60, len(original) - 1]:
            damaged = self.root / f"truncated-{length}"
            damaged.write_bytes(original[:length])
            with self.assertRaises(ValueError):
                weights.inspect_model(damaged)
        for label, offset, value in [("magic", 0, 0), ("quantized", 44, 2), ("bad-heads", 16, 3)]:
            damaged = bytearray(original); struct.pack_into("<i", damaged, offset, value)
            path = self.root / label; path.write_bytes(damaged)
            with self.assertRaises(ValueError):
                weights.inspect_model(path)
        tensor = self.model().tensors[0]
        damaged = bytearray(original)
        # First tensor name is immediately before its payload, with unchanged byte length.
        damaged[tensor.offset - len(tensor.name):tensor.offset] = b"x" * len(tensor.name)
        path = self.root / "unknown-name"; path.write_bytes(damaged)
        with self.assertRaises(ValueError):
            weights.inspect_model(path)

    def test_inspection_limits_and_cancellation_are_enforced(self):
        with self.assertRaises(ValueError):
            weights.inspect_model(self.source, weights.Limits(model_bytes=10))
        with self.assertRaises(ValueError):
            weights.inspect_model(self.source, weights.Limits(tokens=2))
        with self.assertRaises(InterruptedError):
            weights.inspect_model(self.source, check=lambda: (_ for _ in ()).throw(InterruptedError("stop")))

    def test_recipe_json_rejects_duplicate_and_nonfinite_fields(self):
        for index, text in enumerate(['{"edits":[],"edits":[]}', '{"factor":NaN}']):
            recipe = self.root / f"bad-recipe-{index}.json"
            recipe.write_text(text)
            with self.assertRaises(ValueError):
                weights.read_json(recipe)

    def test_report_rejects_a_model_changed_or_replaced_after_parsing(self):
        model = self.model()
        self.write_model(self.source, value=0.5)
        with self.assertRaisesRegex(ValueError, "changed after format inspection"):
            weights.model_report(model)
        model = self.model()
        replacement = self.root / "replacement.bin"
        self.write_model(replacement, value=0.5)
        os.replace(replacement, self.source)
        with self.assertRaisesRegex(ValueError, "changed after format inspection"):
            weights.model_report(model, include_vocabulary=True)

    def test_scale_and_set_edit_only_declared_serialized_elements(self):
        original = self.source.read_bytes()
        recipe = self.recipe()
        second = copy.deepcopy(recipe["edits"][0])
        second.update(op="set", index=0, value=-0.5)
        for key in ["start", "count", "factor"]:
            second.pop(key)
        recipe["edits"].append(second)
        output = self.root / "derived"
        audit = weights.apply_recipe(self.source, recipe, output)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(audit["state"], "completed")
        self.assertEqual(sum(e["changed_elements"] for e in audit["edits"]), 5)
        derived = weights.inspect_model(output / "model.bin")
        self.assertEqual(derived.tensors, self.model().tensors)
        self.assertEqual(derived.bytes, len(original))
        tensor = derived.tensor(recipe["edits"][0]["tensor"])
        with derived.path.open("rb") as stream:
            stream.seek(tensor.offset)
            values = struct.unpack("<16e", stream.read(32))
        self.assertEqual(values, (-0.5, 0.25, 0.25, 0.25) + (0.5,) * 4 + (0.25,) * 8)
        self.assertEqual(audit["derived_sha256"], weights.hash_file(derived.path))
        self.assertNotEqual(audit["derived_sha256"], audit["source_sha256"])
        self.assertFalse((output / "model.partial.bin").exists())
        self.assertEqual(json.loads((output / "edit-audit.json").read_text())["recipe"], recipe)

    def test_invalid_recipe_ranges_shapes_hashes_and_overlap_fail_before_copy(self):
        for field, value in [("shape", [2, 8]), ("dtype", "f32"), ("start", -1), ("count", 17),
                             ("start", True), ("factor", float("inf")), ("factor", 10 ** 1000), ("op", "arbitrary-code")]:
            recipe = self.recipe(); recipe["edits"][0][field] = value
            with self.assertRaises(ValueError):
                weights.apply_recipe(self.source, recipe, self.root / "invalid")
            self.assertFalse((self.root / "invalid").exists())
        recipe = self.recipe(); recipe["edits"].append(copy.deepcopy(recipe["edits"][0]))
        with self.assertRaises(ValueError):
            weights.apply_recipe(self.source, recipe, self.root / "overlap")
        recipe = self.recipe(); recipe["input_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            weights.apply_recipe(self.source, recipe, self.root / "hash-mismatch")

    def test_no_overwrite_noop_and_overflow_keep_original_and_failure_evidence(self):
        digest = weights.hash_file(self.source)
        with self.assertRaises(FileExistsError):
            weights.apply_recipe(self.source, self.recipe(), self.source)
        for label, factor in [("noop", 1.0), ("overflow", 1e100)]:
            recipe = self.recipe(); recipe["edits"][0]["factor"] = factor
            output = self.root / label
            with self.assertRaises(ValueError):
                weights.apply_recipe(self.source, recipe, output)
            self.assertFalse((output / "model.bin").exists())
            self.assertTrue((output / "model.partial.bin").exists())
            self.assertEqual(json.loads((output / "edit-audit.json").read_text())["state"], "failed")
        self.assertEqual(weights.hash_file(self.source), digest)

    def test_audit_write_failure_cannot_publish_a_completed_model(self):
        output = self.root / "audit-failure"
        with patch.object(weights, "write_new_json", side_effect=OSError("synthetic full disk")):
            with self.assertRaises(OSError):
                weights.apply_recipe(self.source, self.recipe(), output)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.partial.bin").exists())

    def test_final_audit_replace_failure_quarantines_artifact_and_records_original_error(self):
        output = self.root / "final-audit-failure"
        original_hash = weights.hash_file(self.source)
        replace = os.replace
        attempts = []
        def fail_first_replace(source, destination):
            attempts.append(Path(source).name)
            if len(attempts) == 1:
                raise OSError("synthetic final audit replace failure")
            return replace(source, destination)
        with patch.object(weights.os, "replace", side_effect=fail_first_replace):
            with self.assertRaisesRegex(OSError, "synthetic final audit replace failure"):
                weights.apply_recipe(self.source, self.recipe(), output)
        self.assertEqual(weights.hash_file(self.source), original_hash)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.failed.bin").exists())
        audit = json.loads((output / "edit-audit.json").read_text())
        self.assertEqual(audit["state"], "failed")
        self.assertEqual(audit["artifact"], "model.failed.bin")
        self.assertIn("synthetic final audit replace failure", audit["error"])
        self.assertEqual(audit["derived_sha256"], weights.hash_file(output / "model.failed.bin"))
        self.assertEqual(len(attempts), 2)
        self.assertNotEqual(attempts[0], attempts[1])
        self.assertFalse(list(output.glob(".edit-audit.*.tmp")))

    def test_persistent_audit_update_failure_retains_separate_failure_manifest(self):
        output = self.root / "persistent-audit-failure"
        with patch.object(weights, "update_owned_audit", side_effect=OSError("synthetic audit update unavailable")):
            with self.assertRaisesRegex(OSError, "synthetic audit update unavailable"):
                weights.apply_recipe(self.source, self.recipe(), output)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.failed.bin").exists())
        failure = json.loads((output / "edit-failure.json").read_text())
        self.assertEqual(failure["state"], "failed")
        self.assertEqual(failure["retained_artifacts"], ["model.failed.bin"])

    def test_nonfinite_input_is_rejected_and_cancellation_retains_partial_evidence(self):
        tensor = self.model().tensors[0]
        with self.source.open("r+b") as stream:
            stream.seek(tensor.offset); stream.write(struct.pack("<f", float("nan")))
        with self.assertRaises(ValueError):
            weights.apply_recipe(self.source, self.recipe(), self.root / "nonfinite")
        self.write_model(self.source)
        output = self.root / "canceled"
        def check():
            if (output / "model.partial.bin").exists():
                raise InterruptedError("synthetic cancellation")
        with self.assertRaises(InterruptedError):
            weights.apply_recipe(self.source, self.recipe(), output, check=check)
        self.assertEqual(json.loads((output / "edit-audit.json").read_text())["state"], "canceled")
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertFalse((output / "model.bin").exists())


if __name__ == "__main__":
    unittest.main()
