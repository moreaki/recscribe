#!/usr/bin/env python3
"""Build the bounded offline probe with installed Apple tools; no CMake/install.

Run through work-artifacts.py and the owned research guard. No shell, dependency
download, app install, ASR, original model write or source-tree mutation occurs.
The receipt output and product must be new. Staging uses RECSCRIBE_RUN_DIR.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


COMMIT = "d1be6fde11ac6e0407606b4e42fe72d34add8037"
VERSION = "1.9.5"
GGML_VERSION = "0.27.0"
HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
PRODUCTS = REPOSITORY / "Build/Products/WhisperActivationProbe-v2"


def safe(path, *, directory=False, new=False):
    path = Path(path).expanduser()
    if not path.is_absolute() or ".." in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Use absolute nonsymlink paths without traversal")
    if new:
        if path.exists() or not path.parent.is_dir():
            raise ValueError("Output must be new with an existing parent")
    elif directory and not path.is_dir() or not directory and not path.is_file():
        raise ValueError("Required build input is unavailable")
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def identity(path):
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)}


def capture(command, timeout=10):
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout)
    if len(result.stdout) + len(result.stderr) > 1024 * 1024:
        raise ValueError("Build metadata exceeds its byte bound")
    return result.stdout.strip(), result.stderr.strip()


def source_inventory(upstream, ggml):
    paths = [upstream / name for name in (
        "include/whisper.h", "src/whisper.cpp", "src/whisper-arch.h",
        "src/aneforge/whisper-aneforge.h", "src/aneforge/whisper-aneforge.cpp")]
    paths += sorted(HERE.glob("*.cpp")) + sorted(HERE.glob("*.h")) + [Path(__file__).resolve()]
    paths += sorted((ggml / "include").glob("*.h"))
    if not 10 <= len(paths) <= 100:
        raise ValueError("Unexpected bounded source/header inventory")
    if sum(path.stat().st_size for path in paths) > 16 * 1024 * 1024:
        raise ValueError("Source/header inventory exceeds its size bound")
    return [identity(safe(path)) for path in paths]


def native_inventory(ggml):
    paths = {path.resolve(strict=True) for path in (ggml / "lib").glob("libggml*.dylib")}
    paths.update(path.resolve(strict=True) for path in (ggml / "libexec").glob("*.so"))
    # Retain recursively linked non-system dependencies, including libomp.
    pending = list(paths)
    links = {}
    while pending:
        path = pending.pop()
        text, _ = capture(["/usr/bin/otool", "-L", str(path)])
        links[str(path)] = text
        for line in text.splitlines()[1:]:
            value = line.strip().split(" (", 1)[0]
            if value.startswith("/opt/homebrew/"):
                dependency = Path(value).resolve(strict=True)
                if dependency not in paths:
                    paths.add(dependency); pending.append(dependency)
        if len(paths) > 32:
            raise ValueError("Native dependency inventory exceeds its bound")
    return [identity(path) for path in sorted(paths)], links


def write_receipt(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write("\n"); stream.flush(); os.fsync(stream.fileno())


def build(args):
    upstream = safe(args.upstream_root, directory=True)
    ggml = safe(args.ggml_root, directory=True)
    output = safe(args.output, new=True)
    run = safe(os.environ.get("RECSCRIBE_RUN_DIR", ""), directory=True)
    commit, _ = capture(["git", "-C", str(upstream), "rev-parse", "HEAD"])
    dirty, _ = capture(["git", "-C", str(upstream), "status", "--porcelain", "--untracked-files=no"])
    if commit != COMMIT or dirty:
        raise ValueError("Expected exact clean pinned whisper.cpp source")
    package = ggml / "lib/cmake/ggml/ggml-config.cmake"
    version = ggml / "lib/cmake/ggml/ggml-config-version.cmake"
    if 'set(PACKAGE_VERSION "0.27.0")' not in version.read_text() or 'set(GGML_BACKEND_DL "ON")' not in package.read_text():
        raise ValueError("Expected pinned GGML 0.27.0 with dynamically loaded backends")
    libraries = [safe(ggml / f"lib/lib{name}.{GGML_VERSION}.dylib") for name in ("ggml", "ggml-base")]
    compiler_text, _ = capture(["/usr/bin/xcrun", "--find", "clang++"])
    compiler = Path(compiler_text).resolve(strict=True)
    compiler_version, _ = capture([str(compiler), "--version"])
    sdk_text, _ = capture(["/usr/bin/xcrun", "--show-sdk-path"])
    # Invoking canonical clang directly does not inherit xcrun's SDK injection.
    sdk = Path(sdk_text).resolve(strict=True)
    if not sdk.is_dir() or not (sdk / "usr/include/stdio.h").is_file():
        raise ValueError("The selected Apple SDK is incomplete")
    os_version, _ = capture(["/usr/bin/sw_vers"])
    sources_before = source_inventory(upstream, ggml)
    natives_before, native_links = native_inventory(ggml)
    products = PRODUCTS
    if products.exists(): safe(products, directory=True)
    else:
        safe(products.parent, directory=True)
        products.mkdir()
    binary = safe(products / "recscribe-activation-probe", new=True)
    staged = safe(run / "recscribe-activation-probe.staged", new=True)
    # xcrun's clang++ may resolve to clang; retain C++ linker-driver semantics
    # explicitly after canonicalizing the compiler path for its identity.
    command = [str(compiler), "--driver-mode=g++", "-isysroot", str(sdk),
               "-std=c++17", "-O2", "-DNDEBUG", "-pthread",
               '-DWHISPER_VERSION="' + VERSION + '"',
               '-DRECSCRIBE_WHISPER_SOURCE="' + str(upstream / "src/whisper.cpp") + '"',
               "-I", str(upstream / "include"), "-I", str(upstream / "src"),
               "-I", str(ggml / "include"), str(HERE / "probe.cpp"),
               str(upstream / "src/aneforge/whisper-aneforge.cpp"),
               *(str(path) for path in libraries), "-Wl,-rpath," + str(ggml / "lib"),
               "-o", str(staged)]
    print("Compiling bounded offline activation probe with installed Apple clang++", flush=True)
    subprocess.run(command, check=True, timeout=240)
    # Integration preflight of the actual staged executable, not a source-text
    # assertion. This registers/inspects devices only; no model/audio is opened.
    inspected = subprocess.run([str(staged), "--inspect-backends"], capture_output=True, text=True, timeout=15)
    if len(inspected.stdout) + len(inspected.stderr) > 1024 * 1024:
        raise ValueError("Backend inspection output exceeds its bound")
    stdout_path, stderr_path = run / "backend-inspection.stdout.json", run / "backend-inspection.stderr.log"
    for path, content in ((stdout_path, inspected.stdout), (stderr_path, inspected.stderr)):
        with path.open("x") as stream: stream.write(content)
    if inspected.returncode != 0:
        raise ValueError("Staged native backend inspection failed; retained its stdout/stderr")
    inspection = json.loads(inspected.stdout)
    if inspection.get("schema_version") != "whisper-probe-backend-inspection-v1" or inspection.get("status") != "registered" or \
            inspection.get("metal_gpu_available") is not True or inspection.get("initializer") != "ggml_backend_load_all" or \
            inspection.get("model_loaded") is not False or inspection.get("encoder_passes") != 0 or inspection.get("decoder_passes") != 0:
        raise ValueError("Unexpected staged backend inspection evidence")
    if sources_before != source_inventory(upstream, ggml) or natives_before != native_inventory(ggml)[0]:
        raise ValueError("Frozen source/header/native input changed during build")
    if not staged.is_file() or not os.access(staged, os.X_OK) or staged.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Unexpected diagnostic executable product")
    # Copy rather than replace: an existing retained executable is never lost.
    fd = os.open(binary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755)
    with os.fdopen(fd, "wb") as destination, staged.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""): destination.write(block)
        destination.flush(); os.fsync(destination.fileno())
    os.chmod(binary, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
    binary_links, _ = capture(["/usr/bin/otool", "-L", str(binary)])
    record = {"schema_version": "activation-probe-direct-build-v1", "status": "complete",
              "created_utc": datetime.now(timezone.utc).isoformat(), "upstream_commit": COMMIT,
              "whisper_version": VERSION, "ggml_version": GGML_VERSION,
              "compiler": identity(compiler), "compiler_version": compiler_version,
              "sdk": str(sdk), "os": os_version, "command": command,
              "source_headers": sources_before, "native_files": natives_before,
              "native_dependency_links": native_links, "binary": identity(binary),
              "backend_inspection": inspection, "backend_inspection_stdout_sha256": digest(stdout_path),
              "backend_inspection_stderr_sha256": digest(stderr_path),
              "binary_dependency_links": binary_links, "asr_or_activation_execution": False,
              "no_source_or_installed_app_changes": True}
    write_receipt(output, record)
    (run / ".pin").touch()
    print(json.dumps({"binary": str(binary), "binary_sha256": record["binary"]["sha256"],
                      "receipt_sha256": digest(output), "native_files": len(natives_before),
                      "source_headers": len(sources_before), "asr_or_activation_execution": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-root", required=True, type=Path)
    parser.add_argument("--ggml-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        build(args)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Diagnostic build failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
