"""Independent GELU algebra and real serialized, synthetic GGML byte contracts.

Only the production architecture gate is patched for tiny files. No checkpoint,
recognition, quantizer, audio or network is used.
"""
import contextlib
from dataclasses import replace
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "quality/mlp-permute.py"
SPEC = importlib.util.spec_from_file_location("mlp_permutation_contracts", SCRIPT)
permute = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = permute
SPEC.loader.exec_module(permute)
weights = permute.weights
np = permute.numpy_module()


class PermutationAlgebraContracts(unittest.TestCase):
    def test_nonsymmetric_permutation_commutes_with_gelu_and_requires_both_compensations(self):
        rng = np.random.default_rng(20261109)
        first, bias, inputs = rng.normal(size=(4, 3)), rng.normal(size=4), rng.normal(size=(3, 5))
        last = np.asarray([[4., 1., 3., 2.], [-4., 1., -3., 2.]])
        order = np.asarray([1, 3, 2, 0])
        self.assertFalse(np.array_equal(order, np.argsort(order)))
        def gelu(x):
            return .5 * x * (1 + np.vectorize(math.erf)(x / math.sqrt(2)))
        expected = last @ gelu(first @ inputs + bias[:, None])
        actual = last[:, order] @ gelu(first[order] @ inputs + bias[order, None])
        np.testing.assert_allclose(actual, expected, rtol=2e-14, atol=2e-14)
        wrong_last = last[:, np.argsort(order)] @ gelu(first[order] @ inputs + bias[order, None])
        wrong_bias = last[:, order] @ gelu(first[order] @ inputs + bias[:, None])
        self.assertGreater(float(np.max(np.abs(wrong_last - expected))), .01)
        self.assertGreater(float(np.max(np.abs(wrong_bias - expected))), .01)

    def test_f64_maxabs_order_ties_signed_zero_and_u32le_hash(self):
        values = np.asarray([[2., -0., -2., 1., 0., -1.], [-2., 0., 1., -1., -0., 1.]], dtype="<f4")
        raw = values.tobytes()
        tensor = weights.Tensor("test", (6, 2), "f32", 0, 0, 12, len(raw))
        stream = io.BytesIO(raw)
        order, evidence = permute.column_order(stream, tensor)
        self.assertEqual(order.tolist(), [1, 4, 3, 5, 0, 2])
        self.assertEqual(evidence["permutation_sha256"], hashlib.sha256(struct.pack("<6I", 1, 4, 3, 5, 0, 2)).hexdigest())
        self.assertEqual((evidence["zero_scale_channels"], evidence["column_max_abs_max"]), (2, 2.))
        self.assertEqual(stream.getvalue(), raw)
        zero = weights.Tensor("zero", (3, 1), "f16", 1, 0, 3, 6)
        self.assertEqual(permute.column_order(io.BytesIO(struct.pack("<3e", -0., 0., -0.)), zero)[0].tolist(), [0, 1, 2])

    def test_geometry_selection_and_numeric_bounds_fail_closed(self):
        for name, (state, heads, enc, dec, mels, vocab) in permute.GEOMETRIES.items():
            h = dict(n_audio_state=state, n_text_state=state, n_audio_head=heads, n_text_head=heads,
                     n_audio_layer=enc, n_text_layer=dec, n_mels=mels, n_vocab=vocab,
                     n_audio_ctx=1500, n_text_ctx=448, ftype=1)
            self.assertEqual(permute.validate_geometry(h, name), (state, enc, dec))
            self.assertEqual(len(permute.sites(enc, dec)), enc + dec)
            for field in h:
                with self.subTest(model=name, field=field), self.assertRaises(ValueError):
                    permute.validate_geometry({**h, field: h[field] + 1}, name)
        with self.assertRaises(ValueError):permute.validate_geometry({}, "tiny")
        with self.assertRaises(ValueError):permute.workspace(permute.MAX_NUMERIC_WORKSPACE_BYTES + 1)
        for order in ([0, 0], [-1, 1], [0, 2], [[0, 1]], [0., 1.], [False, True]):
            with self.assertRaises(ValueError):permute.checked_order(order, 2, np)
        bad = weights.Tensor("bad", (1, 1), "f32", 0, 0, 1, 4)
        for number in (float("nan"), float("inf")):
            with self.assertRaises(ValueError):permute.column_order(io.BytesIO(struct.pack("<f", number)), bad)


class SerializedPermutationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "synthetic.bin"
        self.state, hidden = 8, 32
        self.header = dict(zip(weights.HEADER_FIELDS, [3, 3, 8, 1, 1, 4, 8, 1, 1, 2, 1]))
        with self.source.open("wb") as stream:
            stream.write(struct.pack("<12i", weights.MAGIC, *self.header.values()))
            stream.write(struct.pack("<2i", 2, 3) + struct.pack("<6f", *([1.] * 6)))
            tokens = [b"one", b"", b"\xff"]
            stream.write(struct.pack("<i", len(tokens)))
            for token in tokens:stream.write(struct.pack("<i", len(token)) + token)
            for name, (shape, dtype) in weights.expected_tensors(self.header).items():
                encoded = name.encode();code = "e" if dtype == "f16" else "f"
                stream.write(struct.pack("<3i", len(shape), len(encoded), 1 if dtype == "f16" else 0))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                values = [((i * 11 + len(name)) % 61 - 30) / 64 for i in range(math.prod(shape))]
                if name.endswith("mlp.2.weight"):
                    values = [((col * 13) % hidden + 1) / 64 * (-1 if row % 2 else 1) for row in range(self.state) for col in range(hidden)]
                if name.endswith("mlp.0.weight"):
                    values[:6] = [0., -0., 2**-24, -2**-24, 65504., -65504.]
                if name.endswith("mlp.0.bias"):
                    values[:3] = [-0., 0., 1.25]
                stream.write(struct.pack("<" + code * len(values), *values))
        self.sha = weights.hash_file(self.source)
        self.model = weights.inspect_model(self.source)

    def tearDown(self):
        self.temporary.cleanup()

    def apply(self, output, **kwargs):
        with patch.object(permute, "validate_geometry", return_value=(8, 1, 1)):
            return permute.apply_permutation(self.source, "small", self.sha, output, **kwargs)

    def read(self, path, tensor):
        with path.open("rb") as stream:
            stream.seek(tensor.offset)
            return stream.read(tensor.bytes)

    def test_actual_serialized_permutation_and_inverse_preserve_all_scalar_bits(self):
        output = self.root / "success"
        with patch.object(weights, "inspect_model", wraps=weights.inspect_model) as inspected:
            audit = self.apply(output)
        self.assertEqual(len(inspected.call_args_list), 2)
        self.assertTrue(all(call.args[1].model_bytes == 4 * 1024**3 for call in inspected.call_args_list))
        self.assertEqual(audit["state"], "completed")
        self.assertEqual(audit["selected_tensor_count"], 6)
        self.assertEqual(audit["outside_declared_changed_bytes"], 0)
        self.assertFalse(audit["no_op"])
        self.assertFalse((output / "model.partial.bin").exists())
        result = weights.inspect_model(output / "model.bin")
        self.assertEqual((result.architecture, result.tensors, result.vocabulary_sha256),
                         (self.model.architecture, self.model.tensors, self.model.vocabulary_sha256))
        plan = json.loads((output / "permutation-plan.json").read_bytes())
        self.assertEqual(plan["ordering"]["index_semantics"], "new_position_to_original_hidden_index")
        for site in plan["sites"]:
            tensor = self.model.tensor(site["site"] + ".2.weight")
            old = struct.unpack("<" + "e" * tensor.elements, self.read(self.source, tensor))
            maxima = [max(abs(old[row * 32 + col]) for row in range(8)) for col in range(32)]
            order = sorted(range(32), key=lambda i: (maxima[i], i))
            self.assertEqual(order, site["permutation"])
            for suffix in (".0.weight", ".0.bias", ".2.weight"):
                t = self.model.tensor(site["site"] + suffix)
                width = 2 if t.dtype == "f16" else 4
                raw = self.read(self.source, t)
                atoms = [raw[i:i+width] for i in range(0, len(raw), width)]
                if suffix == ".0.weight":expected = b"".join(atoms[old * 8 + col] for old in order for col in range(8))
                elif suffix == ".0.bias":expected = b"".join(atoms[old] for old in order)
                else:expected = b"".join(atoms[row * 32 + old] for row in range(8) for old in order)
                self.assertEqual(self.read(output / "model.bin", t), expected, t.name)
        for edit in audit["edits"]:
            self.assertTrue(edit["inverse_permutation_equal"])
            self.assertEqual(edit["inverse_permutation_sha256"], edit["before_sha256"])
        self.assertEqual(weights.hash_file(self.source), self.sha)
        self.assertEqual(weights.hash_file(output / "model.bin"), audit["derived_sha256"])
        self.assertEqual(weights.hash_file(output / "permutation-plan.json"), audit["permutation_plan_sha256"])

    def test_wrong_shape_and_nonfinite_unselected_values_are_rejected(self):
        tensor = self.model.tensor("encoder.blocks.0.mlp.0.weight")
        bad = replace(self.model, tensors=tuple(replace(t, shape=tuple(reversed(t.shape))) if t == tensor else t for t in self.model.tensors))
        with self.assertRaises(ValueError):permute.tensor_plan(bad, (8, 1, 1))
        untouched = self.model.tensor("encoder.blocks.0.attn.out.bias")
        with self.source.open("r+b") as stream:
            stream.seek(untouched.offset);stream.write(struct.pack("<f", float("inf")))
        self.sha = weights.hash_file(self.source)
        with self.assertRaises(ValueError):self.apply(self.root / "nonfinite")
        self.assertFalse((self.root / "nonfinite").exists())

    def test_already_sorted_model_is_a_valid_explicit_no_op_without_reselection(self):
        for site in permute.sites(1, 1):
            tensor = self.model.tensor(site + ".2.weight")
            values = [float(col + 1) / 64 for row in range(8) for col in range(32)]
            with self.source.open("r+b") as stream:
                stream.seek(tensor.offset);stream.write(struct.pack("<" + "e" * len(values), *values))
        self.sha = weights.hash_file(self.source)
        output = self.root / "no-op"
        audit = self.apply(output)
        self.assertTrue(audit["no_op"])
        self.assertEqual(audit["changed_elements"], 0)
        self.assertEqual(audit["derived_sha256"], self.sha)
        self.assertTrue((output / "model.bin").exists())

    def test_hash_existing_checkout_and_symlink_output_refusals(self):
        output = self.root / "new"
        with self.assertRaises(ValueError):permute.apply_permutation(self.source, "small", "0" * 64, output)
        self.assertFalse(output.exists())
        output.mkdir();(output / "foreign").write_bytes(b"retain")
        with self.assertRaises(ValueError):self.apply(output)
        self.assertEqual((output / "foreign").read_bytes(), b"retain")
        foreign = self.root / "checkout";foreign.mkdir();(foreign / ".git").write_text("gitdir: unused")
        with self.assertRaises(ValueError):permute.external_output(foreign / "new")
        link = self.root / "link";link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):permute.external_output(link / "other")
        with self.assertRaises(ValueError):permute.external_output(SCRIPT.resolve().parents[2] / "Build/unsafe")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_cancel_before_during_copy_and_after_publication_retains_owned_evidence(self):
        for stage in ("before", "copy", "published"):
            with self.subTest(stage=stage):
                output = self.root / stage
                def check():
                    if stage == "before" or (output / ("model.partial.bin" if stage == "copy" else "model.bin")).exists():
                        raise InterruptedError("Synthetic cancellation")
                with self.assertRaises(InterruptedError):self.apply(output, check=check)
                self.assertFalse((output / "model.bin").exists())
                if stage == "before":self.assertFalse(output.exists())
                else:
                    self.assertTrue((output / ("model.partial.bin" if stage == "copy" else "model.failed.bin")).exists())
                    self.assertEqual(json.loads((output / "permutation-audit.json").read_bytes())["state"], "canceled")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_cancel_during_permutation_and_changed_original_fail_without_repair(self):
        original = permute.permute_tensor
        output = self.root / "editing-cancel"
        def cancel(*args):
            original(*args)
            raise InterruptedError("Synthetic edit cancellation")
        with patch.object(permute, "permute_tensor", side_effect=cancel), self.assertRaises(InterruptedError):self.apply(output)
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertEqual(weights.hash_file(self.source), self.sha)
        touched = self.model.tensor("encoder.blocks.0.attn.out.bias")
        def mutate(*args):
            value = original(*args)
            with self.source.open("r+b") as stream:
                stream.seek(touched.offset);stream.write(struct.pack("<f", 123.))
            return value
        changed = self.root / "changed-original"
        with patch.object(permute, "permute_tensor", side_effect=mutate), self.assertRaises(ValueError):self.apply(changed)
        self.assertFalse((changed / "model.bin").exists())
        self.assertNotEqual(weights.hash_file(self.source), self.sha)

    def test_selected_or_unselected_corruption_is_not_published(self):
        original = permute.permute_tensor
        for selected in (False, True):
            with self.subTest(selected=selected):
                tensor = self.model.tensor("encoder.blocks.0.mlp.0.weight" if selected else "encoder.blocks.0.attn.out.bias")
                def corrupt(source, target, *args):
                    value = original(source, target, *args)
                    target.seek(tensor.offset);target.write(b"\x01\x01")
                    return value
                output = self.root / ("corrupt-selected" if selected else "corrupt-unselected")
                with patch.object(permute, "permute_tensor", side_effect=corrupt), self.assertRaises(ValueError):self.apply(output)
                self.assertFalse((output / "model.bin").exists())
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_replaced_partial_and_foreign_final_are_never_deleted_or_overwritten(self):
        original = permute.permute_tensor
        output = self.root / "replaced"
        replaced = False
        def replace_partial(*args):
            nonlocal replaced
            value = original(*args)
            if not replaced:
                replaced = True
                (output / "model.partial.bin").unlink();(output / "model.partial.bin").write_bytes(b"foreign partial")
            return value
        with patch.object(permute, "permute_tensor", side_effect=replace_partial), self.assertRaises(ValueError):self.apply(output)
        self.assertEqual((output / "model.partial.bin").read_bytes(), b"foreign partial")
        other = self.root / "foreign-final"
        def add_foreign_final():
            audit = other / "permutation-audit.json"
            if audit.exists() and json.loads(audit.read_bytes())["state"] == "verified" and not (other / "model.bin").exists():
                (other / "model.bin").write_bytes(b"foreign final")
        with self.assertRaises(FileExistsError):self.apply(other, check=add_foreign_final)
        self.assertEqual((other / "model.bin").read_bytes(), b"foreign final")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_mutated_plan_or_replaced_audit_is_not_accepted_or_overwritten(self):
        for document in ("plan", "audit"):
            with self.subTest(document=document):
                output = self.root / ("foreign-" + document)
                altered = False
                def alter():
                    nonlocal altered
                    path = output / ("permutation-plan.json" if document == "plan" else "permutation-audit.json")
                    if path.exists() and (output / "model.partial.bin").exists() and not altered:
                        altered = True
                        if document == "plan":
                            with path.open("ab") as stream:stream.write(b" ")
                        else:
                            path.unlink();path.write_bytes(b"foreign audit")
                with self.assertRaises(ValueError):self.apply(output, check=alter)
                self.assertFalse((output / "model.bin").exists())
                if document == "audit":self.assertEqual((output / "permutation-audit.json").read_bytes(), b"foreign audit")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_real_cli_metadata_publication_and_finite_operating_bounds(self):
        output = self.root / "cli"
        args = ["apply", str(self.source), "--model-id", "small", "--sha256", self.sha, "--output", str(output)]
        with patch.object(permute, "validate_geometry", return_value=(8, 1, 1)), patch.object(permute, "peak_rss_bytes", return_value=0), contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(permute.main(args + ["--timeout", "30"]), 0)
        self.assertEqual(json.loads(printed.getvalue())["state"], "completed")
        for timeout in ("0", "601", "nan"):
            with self.assertRaises(ValueError):permute.main(args + ["--timeout", timeout])
        marker = self.root / "cancel.request";marker.touch()
        with self.assertRaises(InterruptedError):permute.main(args + ["--cancel-file", str(marker)])
        with patch.object(permute, "peak_rss_bytes", return_value=permute.MAX_RSS_BYTES + 1), self.assertRaises(MemoryError):permute.main(args)


if __name__ == "__main__":
    unittest.main()
