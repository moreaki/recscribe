"""Native diagnostic contracts; no GGML, model, audio files or ASR execution."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "scripts" / "quality" / "activation-probe"


class ActivationProbeContracts(unittest.TestCase):
    def test_native_statistics_and_input_boundaries(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler, "A native C++ compiler is required for this contract")
        with tempfile.TemporaryDirectory(prefix="recscribe-activation-contract-") as temporary:
            binary = Path(temporary) / "activation-contract"
            compiled = subprocess.run(
                [compiler, "-std=c++17", "-O2", "-UNDEBUG", str(PROBE / "activation_stats_test.cpp"),
                 "-o", str(binary)], capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            checked = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == "__main__":
    unittest.main()
