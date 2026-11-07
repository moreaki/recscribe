"""Attention gauge algebra and actual serialized GGML preservation contracts.

Only production geometry validation is patched for small two-head files. No
model checkpoint, audio, ASR, quantizer or network is used.
"""
import contextlib
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

SCRIPT = Path(__file__).parents[1] / "quality/attention-rotate.py"
SPEC = importlib.util.spec_from_file_location("attention_rotation_contracts", SCRIPT)
rotate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = rotate
SPEC.loader.exec_module(rotate)
weights = rotate.weights
np = rotate.numpy_module()


def independent_matrix(sha, site, head, pair):
    data = (b"recscribe-whisper-attention-rotation-v1\0" + bytes.fromhex(sha)
            + site.encode("ascii") + b"\0" + head.to_bytes(4, "little") + pair.encode("ascii"))
    digest = hashlib.sha256(data).digest()
    signs = [-1 if (digest[j // 8] >> (j % 8)) & 1 else 1 for j in range(64)]
    # Sylvester entries have the parity of the bitwise row/column intersection.
    matrix = np.asarray([[(-1 if (i & j).bit_count() % 2 else 1) * signs[j] / 8
                          for j in range(64)] for i in range(64)], dtype=np.float64)
    return matrix, digest


class AttentionAlgebraContracts(unittest.TestCase):
    def test_exact_mask_framing_bit_order_and_nonsymmetric_orthogonal_matrix(self):
        for pair in ("qk", "vo"):
            expected, digest = independent_matrix("ab" * 32, "decoder.blocks.2.cross_attn", 1, pair)
            actual, observed = rotate.rotation("ab" * 32, "decoder.blocks.2.cross_attn", 1, pair, np)
            self.assertEqual(observed, digest)
            np.testing.assert_array_equal(actual, expected)
            np.testing.assert_array_equal(actual.T @ actual, np.eye(64))
            self.assertFalse(np.array_equal(actual, actual.T))
            self.assertEqual(set(np.unique(actual)), {-1 / 8, 1 / 8})
        self.assertNotEqual(rotate.mask("ab" * 32, "decoder.blocks.2.cross_attn", 1, "qk")[0],
                            rotate.mask("ab" * 32, "decoder.blocks.2.cross_attn", 1, "vo")[0])

    def attention(self, w, xq, xkv, mask):
        q = (w["q"] @ xq + w["qb"][:, None]).reshape(2, 64, -1)
        k = (w["k"] @ xkv).reshape(2, 64, -1)
        v = (w["v"] @ xkv + w["vb"][:, None]).reshape(2, 64, -1)
        out = []
        for h in range(2):
            logits = q[h].T @ k[h] / 8 + mask
            probabilities = np.exp(logits - logits.max(axis=1, keepdims=True))
            probabilities /= probabilities.sum(axis=1, keepdims=True)
            out.append(v[h] @ probabilities.T)
        return w["o"] @ np.concatenate(out, axis=0) + w["ob"][:, None]

    def transformed(self, original, *, wrong_transpose=False, missing=None):
        out = {name: value.copy() for name, value in original.items()}
        for h in range(2):
            rows = slice(h * 64, (h + 1) * 64)
            r, _ = rotate.rotation("ab" * 32, "decoder.blocks.2.cross_attn", h, "qk", np)
            s, _ = rotate.rotation("ab" * 32, "decoder.blocks.2.cross_attn", h, "vo", np)
            for name in ("q", "k", "qb"):
                if missing != name:out[name][rows] = r @ original[name][rows]
            for name in ("v", "vb"):
                if missing != name:out[name][rows] = s @ original[name][rows]
            if missing != "o":out["o"][:, rows] = original["o"][:, rows] @ (s if wrong_transpose else s.T)
        return out

    def test_masked_cross_attention_two_heads_unequal_lengths_and_nonzero_biases(self):
        rng = np.random.default_rng(20261107)
        w = {k:rng.normal(size=(128, 128)) / 16 for k in ("q", "k", "v", "o")}
        w.update({k:rng.normal(size=128) / 8 for k in ("qb", "vb", "ob")})
        xq, xkv = rng.normal(size=(128, 3)), rng.normal(size=(128, 5))
        mask = np.asarray([[0, 0, 0, -np.inf, -np.inf], [0, 0, 0, 0, -np.inf], [0, 0, 0, 0, 0]])
        expected = self.attention(w, xq, xkv, mask)
        actual = self.attention(self.transformed(w), xq, xkv, mask)
        np.testing.assert_allclose(actual, expected, rtol=2e-12, atol=2e-12)
        for bad in (self.transformed(w, wrong_transpose=True), self.transformed(w, missing="k"),
                    self.transformed(w, missing="qb"), self.transformed(w, missing="vb"), self.transformed(w, missing="o")):
            self.assertGreater(float(np.max(np.abs(self.attention(bad, xq, xkv, mask) - expected))), 1e-4)

    def test_geometry_sites_and_noncommuting_paths_are_not_selected(self):
        for model_id, (state, heads, enc, dec, mels, vocab) in rotate.GEOMETRIES.items():
            geometry = {"n_audio_state":state,"n_text_state":state,"n_audio_head":heads,"n_text_head":heads,
                        "n_audio_layer":enc,"n_text_layer":dec,"n_mels":mels,"n_vocab":vocab,
                        "n_audio_ctx":1500,"n_text_ctx":448,"ftype":1}
            self.assertEqual(rotate.validate_geometry(geometry, model_id), (state, heads, enc, dec))
            self.assertEqual(len(rotate.sites(enc, dec)), enc + 2 * dec)
            for field in ("n_audio_state", "n_audio_head", "n_text_layer", "n_mels", "n_vocab", "ftype"):
                bad = dict(geometry);bad[field] += 1
                with self.subTest(model=model_id, field=field), self.assertRaises(ValueError):rotate.validate_geometry(bad, model_id)
        self.assertEqual(rotate.TARGETS, ("small", "large-v3-turbo"))
        for arguments in (("bad", "encoder.blocks.0.attn", 0, "qk"), ("a"*64,"encoder.blocks.0.mlp",0,"qk"),
                          ("a"*64,"encoder.blocks.0.attn",True,"qk"),("a"*64,"encoder.blocks.0.attn",0,"other")):
            with self.assertRaises(ValueError):rotate.mask(*arguments)

    def test_original_dtype_rounding_rejects_nonfinite_and_overflow(self):
        for values in (np.asarray([np.nan]), np.asarray([np.inf]), np.asarray([70000.])):
            with self.assertRaises(ValueError):rotate.cast_block(struct.pack("<e", 1.), values, "f16", np)
        after, changed, stats = rotate.cast_block(struct.pack("<f", 0.), np.asarray([1 / 3]), "f32", np)
        self.assertEqual(after, struct.pack("<f", 1 / 3))
        self.assertEqual(changed, 1)
        self.assertGreater(stats["max_abs_cast_error"], 0)


class SerializedRotationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "synthetic.bin"
        self.header = dict(zip(weights.HEADER_FIELDS, [4, 3, 128, 2, 1, 2, 128, 2, 1, 2, 1]))
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
                salt = hashlib.sha256(encoded).digest()[0]
                for start in range(0, math.prod(shape), 4096):
                    values = [((j * 17 + salt) % 127 - 63) / 128 for j in range(start, min(start + 4096, math.prod(shape)))]
                    stream.write(struct.pack("<" + code * len(values), *values))
        self.sha = weights.hash_file(self.source)
        self.model = weights.inspect_model(self.source)

    def tearDown(self):self.temporary.cleanup()

    def apply(self, output, **kwargs):
        with patch.object(rotate, "validate_geometry", return_value=(128, 2, 1, 1)):
            return rotate.apply_rotation(self.source, "small", self.sha, output, **kwargs)

    def test_actual_serialized_row_and_column_rotations_preserve_every_other_byte(self):
        output = self.root / "derived"
        with patch.object(weights, "inspect_model", wraps=weights.inspect_model) as inspected:
            audit = self.apply(output)
        self.assertEqual(len(inspected.call_args_list), 2)
        self.assertTrue(all(call.args[1].model_bytes == 4 * 1024**3 for call in inspected.call_args_list))
        self.assertEqual(audit["state"], "completed")
        self.assertEqual((audit["selected_tensor_count"], audit["outside_declared_changed_bytes"]), (18, 0))
        self.assertEqual(weights.hash_file(self.source), self.sha)
        self.assertFalse((output / "model.partial.bin").exists())
        derived = weights.inspect_model(output / "model.bin")
        self.assertEqual(derived.tensors, self.model.tensors)
        self.assertEqual(derived.vocabulary_sha256, self.model.vocabulary_sha256)
        edits = rotate.tensor_plan(self.model, (128, 2, 1, 1))
        self.assertFalse(any(any(word in t.name for word in ("mlp", "_ln", "embedding")) or t.name.endswith("out.bias") for t, *_ in edits))
        with self.source.open("rb") as original, (output / "model.bin").open("rb") as result:
            for tensor, site, operation, pair in edits:
                original.seek(tensor.offset);raw = original.read(tensor.bytes)
                code = "e" if tensor.dtype == "f16" else "f"
                values = list(struct.unpack("<" + code * tensor.elements, raw))
                expected = []
                if operation == "input_columns":
                    for row in range(128):
                        for head in range(2):
                            matrix, _ = independent_matrix(self.sha, site, head, pair)
                            for j in range(64):expected.append(math.fsum(values[row * 128 + head * 64 + k] * matrix[j, k] for k in range(64)))
                else:
                    cols = 1 if operation == "bias" else 128
                    for head in range(2):
                        matrix, _ = independent_matrix(self.sha, site, head, pair)
                        for j in range(64):
                            for col in range(cols):expected.append(math.fsum(matrix[j, k] * values[(head * 64 + k) * cols + col] for k in range(64)))
                result.seek(tensor.offset)
                self.assertEqual(result.read(tensor.bytes), struct.pack("<" + code * len(expected), *expected), tensor.name)
        plan = json.loads((output / "rotation-plan.json").read_bytes())
        self.assertEqual(plan["source_sha256"], self.sha)
        self.assertEqual(len(plan["sites"]), 3)
        self.assertFalse(plan["seed_search"])
        self.assertEqual(weights.hash_file(output / "model.bin"), audit["derived_sha256"])

    def test_wrong_hash_and_preexisting_outputs_never_touch_original(self):
        output = self.root / "new"
        with self.assertRaises(ValueError):rotate.apply_rotation(self.source, "small", "0" * 64, output)
        self.assertFalse(output.exists())
        output.mkdir();(output / "unrelated").write_bytes(b"retain")
        with self.assertRaises(ValueError):self.apply(output)
        self.assertEqual((output / "unrelated").read_bytes(), b"retain")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_foreign_checkout_and_symlink_outputs_are_rejected(self):
        foreign = self.root / "foreign";foreign.mkdir();(foreign / ".git").write_text("gitdir: unused")
        with self.assertRaises(ValueError):rotate.external_output(foreign / "new")
        link = self.root / "link";link.symlink_to(foreign, target_is_directory=True)
        with self.assertRaises(ValueError):rotate.external_output(link / "new")
        with self.assertRaises(ValueError):rotate.external_output(SCRIPT.resolve().parents[2] / "Build/unpublished-rotation")

    def test_cancel_before_or_during_copy_keeps_original_and_owned_partial(self):
        output = self.root / "canceled"
        def cancel():
            if (output / "model.partial.bin").exists():raise InterruptedError("synthetic cancellation")
        with self.assertRaises(InterruptedError):self.apply(output, check=cancel)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertEqual(json.loads((output / "rotation-audit.json").read_bytes())["state"], "canceled")
        self.assertEqual(weights.hash_file(self.source), self.sha)
        fresh = self.root / "never-created"
        with self.assertRaises(InterruptedError):self.apply(fresh, check=lambda:(_ for _ in ()).throw(InterruptedError()))
        self.assertFalse(fresh.exists())

    def test_cancel_after_publication_quarantines_only_owned_output(self):
        output = self.root / "late-cancel"
        def cancel():
            if (output / "model.bin").exists():raise InterruptedError("late synthetic cancellation")
        with self.assertRaises(InterruptedError):self.apply(output, check=cancel)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.failed.bin").exists())
        self.assertEqual(json.loads((output / "rotation-audit.json").read_bytes())["state"], "canceled")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_cancel_during_numerical_work_retains_unpublished_artifact(self):
        output = self.root / "math-cancel"
        cancel = weights.Cancellation(30)
        matrix = rotate.rotation
        def interrupted(*args, **kwargs):
            value = matrix(*args, **kwargs)
            cancel.requested = True
            return value
        with patch.object(rotate, "rotation", side_effect=interrupted), self.assertRaises(InterruptedError):
            self.apply(output, check=cancel.check)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertEqual(json.loads((output / "rotation-audit.json").read_bytes())["state"], "canceled")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_replaced_partial_is_not_published_or_deleted_as_owned(self):
        output = self.root / "replaced"
        apply_tensor = rotate.rotate_tensor
        replaced = False
        def replace(*args):
            nonlocal replaced
            result = apply_tensor(*args)
            if not replaced:
                replaced = True
                (output / "model.partial.bin").unlink()
                (output / "model.partial.bin").write_bytes(b"unrelated replacement")
            return result
        with patch.object(rotate, "rotate_tensor", side_effect=replace), self.assertRaises(ValueError):self.apply(output)
        self.assertFalse((output / "model.bin").exists())
        self.assertEqual((output / "model.partial.bin").read_bytes(), b"unrelated replacement")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_actual_cli_metadata_write_succeeds_with_the_real_parser_and_publisher(self):
        output = self.root / "cli-success"
        args = ["apply", str(self.source), "--model-id", "small", "--sha256", self.sha, "--output", str(output), "--timeout", "30"]
        with patch.object(rotate, "validate_geometry", return_value=(128, 2, 1, 1)), \
             patch.object(rotate, "peak_rss_bytes", return_value=0), contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(rotate.main(args), 0)
        result = json.loads(printed.getvalue())
        self.assertEqual(result["state"], "completed")
        self.assertEqual(result["source_sha256"], self.sha)
        self.assertEqual(result["derived_sha256"], weights.hash_file(output / "model.bin"))
        self.assertEqual(json.loads((output / "rotation-audit.json").read_bytes())["state"], "completed")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_undeclared_edit_is_detected_and_never_published(self):
        output = self.root / "bad"
        apply_tensor = rotate.rotate_tensor
        bias = self.model.tensor("encoder.blocks.0.attn.out.bias")
        def damaged(original, target, *args):
            value = apply_tensor(original, target, *args)
            target.seek(bias.offset);target.write(struct.pack("<f", 123.))
            return value
        with patch.object(rotate, "rotate_tensor", side_effect=damaged), self.assertRaises(ValueError):self.apply(output)
        self.assertFalse((output / "model.bin").exists())
        self.assertEqual(json.loads((output / "rotation-audit.json").read_bytes())["state"], "failed")
        self.assertEqual(weights.hash_file(self.source), self.sha)

    def test_cli_cancel_timeout_and_peak_memory_bounds_fail_before_writes(self):
        output = self.root / "cli"
        args = ["apply", str(self.source), "--model-id", "small", "--sha256", self.sha, "--output", str(output)]
        for timeout in ("0", "601", "nan"):
            with self.assertRaises(ValueError):rotate.main(args + ["--timeout", timeout])
        marker = self.root / "cancel.request";marker.touch()
        with self.assertRaises(InterruptedError):rotate.main(args + ["--cancel-file", str(marker)])
        with patch.object(rotate, "peak_rss_bytes", return_value=rotate.MAX_RSS_BYTES + 1), self.assertRaises(MemoryError):rotate.main(args)
        self.assertFalse(output.exists())


if __name__ == "__main__":unittest.main()
