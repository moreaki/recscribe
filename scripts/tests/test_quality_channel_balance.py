"""Fixed-rule algebra, probe provenance and actual GGML byte-preservation tests.

Structural fixtures are deliberately small and make no recognition claim. Only
the pinned production geometry check is patched for end-to-end fixture tests;
the real format parser, float casts, source/audit checks and publisher all run.
"""
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "quality/channel-balance.py"
SPEC = importlib.util.spec_from_file_location("quality_channel_balance", SCRIPT)
balance = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = balance
SPEC.loader.exec_module(balance)
weights = balance.weights


class ChannelBalanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "synthetic.bin"
        self.header = dict(zip(weights.HEADER_FIELDS, [4, 3, 4, 2, 1, 2, 4, 2, 1, 2, 1]))
        self.write_model()
        self.digest = weights.hash_file(self.source)
        self.calibration = self.make_calibration()
        self.calibration_path = self.root / "calibration.json"
        self.save_calibration()

    def tearDown(self):
        self.temporary.cleanup()

    def write_model(self):
        with self.source.open("wb") as stream:
            stream.write(struct.pack("<12i", weights.MAGIC, *self.header.values()))
            stream.write(struct.pack("<2i", 2, 3) + struct.pack("<6f", *([1.] * 6)))
            tokens = [b"one", b"", b"\xff"]
            stream.write(struct.pack("<i", len(tokens)))
            for token in tokens:
                stream.write(struct.pack("<i", len(token)) + token)
            for name, (shape, dtype) in weights.expected_tensors(self.header).items():
                code = "e" if dtype == "f16" else "f"
                # Nonconstant receivers detect row-vs-column mistakes; nonzero
                # LN beta makes an omitted bias compensation observable.
                values = [(j % 7 + 1) / 16 for j in range(math.prod(shape))]
                encoded = name.encode()
                stream.write(struct.pack("<3i", len(shape), len(encoded), 1 if dtype == "f16" else 0))
                stream.write(struct.pack("<" + "i" * len(shape), *shape) + encoded)
                stream.write(struct.pack("<" + code * len(values), *values))

    def make_calibration(self):
        sites = {value["site"]: [1., 1., 4., 4.] for value in balance.site_specs(4, 1)}
        cases = []
        for language in balance.LANGUAGES:
            for index in range(3):
                total = [1, 60, 120][index]
                reference_sha = hashlib.sha256(f"reference-{language}-{index}".encode()).hexdigest()
                cases.append({"id": f"{language}-{index}", "language": language,
                    "source_sha256": hashlib.sha256(f"audio-{language}-{index}".encode()).hexdigest(),
                    "reference_sha256": reference_sha, "reference_input_sha256": reference_sha,
                    "probe_sha256": "a" * 64, "reference_tokens_total": total,
                    "reference_tokens_used": min(total, 60), "prefix_positions": 4 + min(total, 60),
                    "source_audio_samples": 16_000, "sites": copy.deepcopy(sites),
                    "prefix_sha256": "f" * 64, "prefix_hash_encoding": "u32-le-token-ids-v1",
                    "probe_runtime": dict(balance.PROBE_RUNTIME)})
        return {"schema_version": balance.CALIBRATION_VERSION, "status": "complete", "split": "development",
            "model_id": "tiny", "model_sha256": self.digest, "development_manifest_sha256": balance.DEVELOPMENT_SHA,
            "geometry": self.header, "statistic": "equal_case_mean_of_post_affine_ln_mean_absolute_activation",
            "prefix_policy": "four_special_positions_then_first_at_most_60_published_reference_tokens",
            "maximum_prefix_positions": 64, "training_used": False, "scale_search_used": False,
            "wrapper_sha256": "b" * 64, "probe": {"executable_sha256": "c" * 64, "source_sha256": "d" * 64,
                "native_source_commit": balance.NATIVE_SOURCE_COMMIT}, "cases": cases}

    def save_calibration(self):
        self.calibration_path.write_bytes(weights.json_bytes(self.calibration))
        self.calibration_sha = weights.hash_file(self.calibration_path)

    def toy_geometry(self):
        return patch.object(balance, "validate_geometry", return_value=(4, 1))

    def apply(self, output, **kwargs):
        with self.toy_geometry():
            return balance.apply_balance(self.source, self.digest, self.calibration_path,
                                         self.calibration_sha, output, **kwargs)

    def read_tensor(self, path, tensor):
        code = "e" if tensor.dtype == "f16" else "f"
        with path.open("rb") as stream:
            stream.seek(tensor.offset)
            return struct.unpack("<" + code * tensor.elements, stream.read(tensor.bytes))

    def native_probe(self, case):
        positions = case["prefix_positions"]
        return {"schema_version": "whisper-ln-activation-probe-v1", "status": "complete", "native_version": "1.9.5",
            "source_commit": balance.NATIVE_SOURCE_COMMIT, "geometry": self.header,
            "conditioning": {"method": "published-development-reference-prefix", "reference_tokens_total": case["reference_tokens_total"],
                "reference_tokens_used": case["reference_tokens_used"], "prefix_positions": positions,
                "source_audio_samples": 16_000, "explicit_language": case["language"].split("-")[0],
                "prefix_sha256": case["prefix_sha256"], "prefix_hash_encoding": "u32-le-token-ids-v1",
                "reference_input_sha256": case["reference_sha256"], **balance.PROBE_RUNTIME},
            "identity": {"bitwise_equal": True, "max_abs_logit_difference": 0, "argmax_mismatch_positions": 0,
                "compared_logits": positions * self.header["n_vocab"]},
            "targets": [{"site": name, "channels": 4, "observations": 1, "count": positions,
                "sum_abs": [x * positions for x in vector], "sum_squares": [x*x*positions for x in vector],
                "max_abs": vector, "mean_abs": vector, "rms": vector} for name, vector in case["sites"].items()]}

    def test_fixed_geometric_rule_handles_zeros_clamps_and_fails_on_invalid_stats(self):
        record = balance.channel_scales([0., 1., 4.])
        self.assertAlmostEqual(record["positive_geometric_mean"], 2.)
        self.assertEqual(record["zero_channels"], 1)
        for actual, expected in zip(record["scales"], [1., 1 / math.sqrt(2), math.sqrt(2)]):
            self.assertAlmostEqual(actual, expected)
        extreme = balance.channel_scales([1e-300, 1e300])
        self.assertEqual(extreme["scales"], [.25, 4.])
        self.assertEqual((extreme["clamped_low"], extreme["clamped_high"]), (1, 1))
        for invalid in [[], [0, 0], [-1, 1], [True], [math.nan], [math.inf], [10 ** 1000], [1] * 769]:
            with self.subTest(invalid_type=type(invalid[0]).__name__ if invalid else "empty"):
                with self.assertRaises(ValueError): balance.channel_scales(invalid)

    def test_equal_case_weighting_does_not_pool_prefix_tokens(self):
        name = next(iter(self.calibration["cases"][0]["sites"]))
        for index, case in enumerate(self.calibration["cases"]):
            case["sites"][name] = [float(index + 1), 1., 4., 4.]
        with self.toy_geometry(): plan = balance.scale_plan(self.calibration)
        self.assertEqual(plan["sites"][name]["mean_abs"][0], 14.)
        token_weighted = sum((i+1) * case["prefix_positions"] for i, case in enumerate(self.calibration["cases"])) / sum(case["prefix_positions"] for case in self.calibration["cases"])
        self.assertNotAlmostEqual(plan["sites"][name]["mean_abs"][0], token_weighted)
        self.assertEqual((plan["alpha"], plan["scale_min"], plan["scale_max"]), (.5, .25, 4.))

    def test_production_geometry_and_exact_fanout_are_pinned(self):
        for model_id, (state, heads, layers) in balance.GEOMETRIES.items():
            geometry = {"n_text_state": state, "n_text_head": heads, "n_text_layer": layers, "n_vocab": 51865}
            self.assertEqual(balance.validate_geometry(geometry, model_id), (state, layers))
            specs = balance.site_specs(state, layers)
            self.assertEqual(len(specs), 3 * layers)
            self.assertEqual(sum(len(value["receivers"]) for value in specs), 5 * layers)
            for site in specs:
                if site["site"].endswith("cross_attn_ln"):
                    self.assertEqual(len(site["receivers"]), 1)
                    self.assertTrue(site["receivers"][0].endswith("cross_attn.query.weight"))
            for field, value in [("n_vocab", 51864), ("n_text_state", state + 1), ("ftype", 8), ("n_audio_layer", layers + 1)]:
                with self.assertRaises(ValueError): balance.validate_geometry({**geometry, field: value}, model_id)
        with self.assertRaises(ValueError): balance.validate_geometry(self.header, "tiny")
        with self.assertRaises(ValueError): balance.validate_geometry({}, "large-v3")

    def test_retained_external_helper_accepts_protected_output_but_rejects_real_checkout(self):
        retained = self.root / "frozen-helper"; retained.mkdir()
        copied = retained / SCRIPT.name
        shutil.copyfile(SCRIPT, copied)
        shutil.copyfile(Path(weights.__file__), retained / "ggml_weights.py")
        specification = importlib.util.spec_from_file_location("retained_channel_balance_test", copied)
        module = importlib.util.module_from_spec(specification)
        # Import the actual copied source without running its CLI or touching
        # model/audio/reference inputs. Restore its private parser module entry.
        with patch.dict(sys.modules):
            sys.modules[specification.name] = module
            specification.loader.exec_module(module)
            protected_output = self.root / "protected-calibration.json"
            self.assertEqual(module.external(protected_output), protected_output)
            self.assertFalse(protected_output.exists())
            checkout = SCRIPT.parents[2]
            self.assertTrue((checkout / ".git").exists(), "This contract requires the real Git checkout/worktree")
            with self.assertRaisesRegex(ValueError, "outside every Git checkout"):
                module.external(checkout / "never-create-calibration.json")
        self.assertFalse((SCRIPT.parents[2] / "never-create-calibration.json").exists())

    def test_source_archive_boundary_is_used_only_for_verified_project_layout(self):
        archive = self.root / "archive"; quality = archive / "scripts/quality"; quality.mkdir(parents=True)
        copied = quality / SCRIPT.name
        shutil.copyfile(SCRIPT, copied)
        shutil.copyfile(Path(weights.__file__), quality / "ggml_weights.py")
        (archive / "AGENTS.md").write_text("Synthetic source archive boundary; no model inputs")
        with patch.object(balance, "__file__", str(copied)):
            with self.assertRaisesRegex(ValueError, "outside the source checkout"):
                balance.external(archive / "never-create-calibration.json")
            self.assertEqual(balance.external(self.root / "external-calibration.json"), self.root / "external-calibration.json")

    def test_real_algebra_preserves_nonzero_beta_with_every_receiving_linear(self):
        # This independently computes the real arithmetic identity; binary tests
        # below explicitly require original-dtype rounding rather than bitwise logits.
        x, gamma, beta, scales = [1., -.5, .25, 2.], [1., 2., .5, 3.], [.3, -.4, .7, .2], [.25, .5, 2., 4.]
        original = [x[j]*gamma[j] + beta[j] for j in range(4)]
        balanced = [x[j]*gamma[j]/scales[j] + beta[j]/scales[j] for j in range(4)]
        for rows in [4, 16]:
            matrix = [[(row*4 + col + 1) / 32 for col in range(4)] for row in range(rows)]
            for row in matrix:
                self.assertAlmostEqual(math.fsum(a*b for a, b in zip(row, original)),
                    math.fsum(row[j]*scales[j]*balanced[j] for j in range(4)))

    def test_input_axis_conversion_tracks_global_block_offset_and_dtype_rounding(self):
        scales = [.25, .5, 2., 4.]
        for dtype, code in [("f16", "e"), ("f32", "f")]:
            original = struct.pack("<" + code * 11, *[(i+1)/32 for i in range(11)])
            for operation in ["divide", "multiply_input_columns"]:
                actual, changed = balance.converted_block(original, dtype, scales, 3, operation)
                expected = b"".join(struct.pack("<"+code, x / scales[(3+i)%4] if operation == "divide" else x * scales[(3+i)%4])
                    for i, (x,) in enumerate(struct.iter_unpack("<"+code, original)))
                self.assertEqual(actual, expected)
                self.assertEqual(changed, 11)
                try: import numpy as np
                except ImportError: np = None
                if np is not None:
                    self.assertEqual(balance.converted_block(original, dtype, scales, 3, operation, np), (actual, changed))
        for args in [(b"x", "f16", scales, 0, "divide"), (b"\0\0", "q5_1", scales, 0, "divide"),
                     (b"\0\0", "f16", scales, -1, "divide"), (b"\0\0", "f16", [0.], 0, "divide")]:
            with self.assertRaises(ValueError): balance.converted_block(*args)
        with self.assertRaisesRegex(ValueError, "overflows"):
            balance.converted_block(struct.pack("<e", 65504.), "f16", [4.], 0, "multiply_input_columns")
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            balance.converted_block(struct.pack("<f", math.nan), "f32", [1.], 0, "divide")

    def test_complete_streaming_edit_preserves_original_layout_and_other_bytes(self):
        original = self.source.read_bytes(); output = self.root / "balanced"
        # Force chunks across matrix row boundaries, including rectangular MLP0.
        with patch.object(balance, "BLOCK_ELEMENTS", 7): audit = self.apply(output)
        self.assertEqual(audit["state"], "completed")
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(audit["file_bytes"], len(original))
        self.assertEqual((audit["selected_f16_elements"], audit["selected_f32_elements"]), (128, 24))
        self.assertFalse(audit["inference_or_quantization_executed"])
        self.assertFalse(audit["training_used"])
        derived = weights.inspect_model(output / "model.bin"); model = weights.inspect_model(self.source)
        self.assertEqual((derived.architecture, derived.tensors, derived.vocabulary_sha256), (model.architecture, model.tensors, model.vocabulary_sha256))
        self.assertEqual(audit["derived_sha256"], weights.hash_file(derived.path))
        self.assertNotEqual(audit["source_sha256"], audit["derived_sha256"])
        self.assertEqual(len(audit["edits"]), 11)
        with self.toy_geometry(): plan = balance.scale_plan(self.calibration); selected = balance.tensor_plan(model, plan)
        edited_names = {tensor.name for tensor, _, _ in selected}
        for tensor in model.tensors:
            old, new = self.read_tensor(self.source, tensor), self.read_tensor(derived.path, tensor)
            if tensor.name not in edited_names:
                self.assertEqual(old, new, tensor.name)
            else:
                _, scales, operation = next(row for row in selected if row[0].name == tensor.name)
                code = "e" if tensor.dtype == "f16" else "f"
                expected = tuple(struct.unpack("<"+code, struct.pack("<"+code,
                    x/scales[j%4] if operation == "divide" else x*scales[j%4]))[0] for j, x in enumerate(old))
                self.assertEqual(new, expected, tensor.name)
        self.assertNotIn("decoder.blocks.0.cross_attn.key.weight", edited_names)
        self.assertNotIn("decoder.blocks.0.cross_attn.value.weight", edited_names)
        self.assertNotIn("decoder.blocks.0.mlp.2.weight", edited_names)
        self.assertFalse((output / "model.partial.bin").exists())
        self.assertEqual(json.loads((output / "balance-audit.json").read_text())["state"], "completed")
        with self.assertRaisesRegex(ValueError, "Output must be new"): self.apply(output)

    def test_probe_assembler_binds_all27_sources_without_opening_private_paths(self):
        source_cases = [{"id": c["id"], "language": c["language"], "sha256": c["source_sha256"],
            "reference_sha256": c["reference_sha256"], "audio": "/DO-NOT-OPEN.wav", "reference": "/DO-NOT-OPEN.txt"} for c in self.calibration["cases"]]
        manifest = self.root / "manifest.json"; manifest.write_bytes(weights.json_bytes({"schema_version": "1.0", "cases": source_cases}))
        manifest_sha = weights.hash_file(manifest)
        wrapper = {"schema_version": "channel-balance-probe-manifest-v1", "model": {"id": "tiny", "sha256": self.digest},
            "probe": self.calibration["probe"], "development_manifest": {"path": str(manifest), "sha256": manifest_sha}, "cases": []}
        for index, case in enumerate(self.calibration["cases"]):
            probe = self.root / f"probe-{index}.json"; probe.write_bytes(weights.json_bytes(self.native_probe(case)))
            wrapper["cases"].append({key: case[key] for key in ("id", "language", "source_sha256", "reference_sha256")})
            wrapper["cases"][-1]["probe"] = {"path": str(probe), "sha256": weights.hash_file(probe)}
        wrapper_path = self.root / "wrapper.json"; wrapper_path.write_bytes(weights.json_bytes(wrapper))
        output = self.root / "assembled.json"
        with self.toy_geometry(), patch.object(balance, "DEVELOPMENT_SHA", manifest_sha):
            result = balance.calibrate(wrapper_path, output)
        self.assertEqual(len(result["cases"]), 27)
        self.assertEqual(result["development_manifest_sha256"], manifest_sha)
        self.assertEqual(result["wrapper_sha256"], weights.hash_file(wrapper_path))
        self.assertEqual(result["cases"][0]["sites"], self.calibration["cases"][0]["sites"])
        self.assertEqual(result["generator_sha256"], weights.hash_file(SCRIPT))
        # A reference/source mismatch must fail before a new calibration exists.
        wrapper["cases"][0]["reference_sha256"] = "0" * 64
        wrapper_path.write_bytes(weights.json_bytes(wrapper))
        with self.toy_geometry(), patch.object(balance, "DEVELOPMENT_SHA", manifest_sha):
            with self.assertRaisesRegex(ValueError, "identity differs"):
                balance.calibrate(wrapper_path, self.root / "not-published.json")
        self.assertFalse((self.root / "not-published.json").exists())

    def test_probe_prefix_hook_identity_reductions_and_complete_sites_are_required(self):
        case = self.calibration["cases"][0]
        mutations = [lambda p: p["conditioning"].update(prefix_positions=65),
            lambda p: p["conditioning"].update(reference_tokens_used=0),
            lambda p: p["conditioning"].update(reference_tokens_total=0),
            lambda p: p["conditioning"].update(explicit_language="en"),
            lambda p: p["conditioning"].update(source_audio_samples=480001),
            lambda p: p["conditioning"].update(threads=1),
            lambda p: p["conditioning"].update(use_gpu=False),
            lambda p: p["conditioning"].update(flash_attention=True),
            lambda p: p["conditioning"].update(encoder_passes=2),
            lambda p: p["conditioning"].update(decoder_passes=1),
            lambda p: p["conditioning"].update(prefix_sha256=""),
            lambda p: p["conditioning"].update(prefix_hash_encoding="other"),
            lambda p: p["conditioning"].update(reference_input_sha256="0"*64),
            lambda p: p["identity"].update(bitwise_equal=False),
            lambda p: p["identity"].update(compared_logits=1),
            lambda p: p["targets"].pop(), lambda p: p["targets"].append(p["targets"][0]),
            lambda p: p["targets"][0].update(observations=2),
            lambda p: p["targets"][0]["mean_abs"].__setitem__(0, 2.),
            lambda p: p["targets"][0]["sum_squares"].__setitem__(0, math.nan)]
        for mutate in mutations:
            probe = self.native_probe(case); mutate(probe)
            with self.toy_geometry(), self.assertRaises(ValueError):
                balance.validate_probe(probe, case, balance.NATIVE_SOURCE_COMMIT, "tiny")
        swiss = next(c for c in self.calibration["cases"] if c["language"] == "de-CH")
        with self.toy_geometry():
            _, record = balance.validate_probe(self.native_probe(swiss), swiss, balance.NATIVE_SOURCE_COMMIT, "tiny")
        self.assertEqual(record["prefix_positions"], 5)

    def test_calibration_denominators_and_nonfinite_metadata_fail_closed(self):
        mutations = [lambda c: c.update(split="held_out"), lambda c: c.update(scale_search_used=True),
            lambda c: c["cases"].pop(), lambda c: c["cases"][0].update(language="en"),
            lambda c: c["cases"][0].update(id=c["cases"][1]["id"]),
            lambda c: c["cases"][0].update(prefix_positions=65),
            lambda c: c["cases"][0].update(prefix_sha256=""),
            lambda c: c["cases"][0].update(reference_input_sha256="0"*64),
            lambda c: c["cases"][0].update(probe_runtime={}),
            lambda c: c["cases"][0]["sites"].pop(next(iter(c["cases"][0]["sites"])))]
        for mutate in mutations:
            calibration = copy.deepcopy(self.calibration); mutate(calibration)
            with self.toy_geometry(), self.assertRaises(ValueError): balance.validate_calibration(calibration)
        for index, text in enumerate(['{"a":1,"a":2}', '{"a":NaN}']):
            path = self.root / f"bad-{index}.json"; path.write_text(text)
            with self.assertRaises(ValueError): balance.metadata(path)
        with self.assertRaisesRegex(ValueError, "size bound"): balance.metadata(self.calibration_path, maximum=1)
        link = self.root / "link.json"; link.symlink_to(self.calibration_path)
        with self.assertRaisesRegex(ValueError, "nonsymlink"): balance.metadata(link)

    def test_wrong_hash_nonfinite_original_and_noop_never_publish(self):
        output = self.root / "refused"
        with self.assertRaisesRegex(ValueError, "checksum differs"):
            balance.apply_balance(self.source, self.digest, self.calibration_path, "0"*64, output)
        with self.toy_geometry(), self.assertRaisesRegex(ValueError, "another original"):
            balance.apply_balance(self.source, "0"*64, self.calibration_path, self.calibration_sha, output)
        self.assertFalse(output.exists())
        # Nonfinite unselected encoder values are rejected by the whole-model scan.
        tensor = weights.inspect_model(self.source).tensor("encoder.positional_embedding")
        with self.source.open("r+b") as stream:
            stream.seek(tensor.offset); stream.write(struct.pack("<f", math.nan))
        self.digest = weights.hash_file(self.source); self.calibration["model_sha256"] = self.digest; self.save_calibration()
        with self.assertRaisesRegex(ValueError, "Non-finite"): self.apply(output)
        self.assertFalse(output.exists())
        self.write_model(); self.digest = weights.hash_file(self.source); self.calibration["model_sha256"] = self.digest
        for case in self.calibration["cases"]:
            for site in case["sites"]: case["sites"][site] = [1.] * 4
        self.save_calibration()
        with self.assertRaisesRegex(ValueError, "no representable"): self.apply(output)
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertFalse((output / "model.bin").exists())
        self.assertEqual(json.loads((output / "balance-audit.json").read_text())["state"], "failed")

    def test_cancellation_retains_owned_partial_and_preserves_original(self):
        output = self.root / "canceled"; original = self.source.read_bytes()
        def check():
            if (output / "model.partial.bin").exists(): raise InterruptedError("synthetic user cancellation")
        with self.assertRaisesRegex(InterruptedError, "user cancellation"): self.apply(output, check=check)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertTrue((output / "model.partial.bin").exists())
        self.assertFalse((output / "model.bin").exists())
        self.assertEqual(json.loads((output / "balance-audit.json").read_text())["state"], "canceled")

    def test_failed_completion_quarantines_only_owned_artifact(self):
        output = self.root / "audit-failed"; save = weights.update_owned_audit
        def fail_completed(path, value):
            if value["state"] == "completed": raise OSError("synthetic final-audit disk failure")
            save(path, value)
        with patch.object(weights, "update_owned_audit", side_effect=fail_completed):
            with self.assertRaisesRegex(OSError, "disk failure"): self.apply(output)
        self.assertFalse((output / "model.bin").exists())
        self.assertTrue((output / "model.failed.bin").exists())
        self.assertEqual(json.loads((output / "balance-audit.json").read_text())["state"], "failed")
        foreign = self.root / "foreign-final"; save_json = weights.write_new_json
        def introduce_foreign(path, value):
            save_json(path, value)
            if path.name == "balance-audit.json" and value["state"] == "verified":
                (foreign / "model.bin").write_bytes(b"unrelated artifact")
        with patch.object(weights, "write_new_json", side_effect=introduce_foreign):
            with self.assertRaises(FileExistsError): self.apply(foreign)
        self.assertEqual((foreign / "model.bin").read_bytes(), b"unrelated artifact")
        self.assertFalse((foreign / "model.failed.bin").exists())
        self.assertEqual(weights.hash_file(self.source), self.digest)


if __name__ == "__main__":
    unittest.main()
