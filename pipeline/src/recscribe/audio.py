"""Streaming integer PCM WAV inspection; FFmpeg only writes working copies."""

import math
import wave
from pathlib import Path

import numpy as np

from .process import Cancellation, run_local
from .storage import sha256
from .channel_windows import CHANNEL_POLICY


def inspect_wav(path: Path, cancel: Cancellation) -> dict:
    initial = path.stat()
    source_hash = sha256(path, cancel.check)
    with wave.open(str(path), "rb") as wav:
        channels, width, rate, frames = (wav.getnchannels(), wav.getsampwidth(),
                                        wav.getframerate(), wav.getnframes())
        if wav.getcomptype() != "NONE" or width not in (1, 2, 3, 4):
            raise ValueError("Only integer PCM WAV (8/16/24/32-bit) is supported")
        if not 1 <= channels <= 32 or rate <= 0 or frames <= 0:
            raise ValueError("WAV must contain audio frames and 1–32 channels")
        peaks, squares = (np.zeros(channels, dtype=np.float64) for _ in range(2))
        clipped, nonzero = (np.zeros(channels, dtype=np.int64) for _ in range(2))
        counts = 0
        identical = True
        window_frames = rate * CHANNEL_POLICY.window_seconds
        window_start, window_equal, windows = 0, True, []
        scale = 2 ** (8 * width - 1)
        while data := wav.readframes(min(65536, window_frames - (counts - window_start))):
            cancel.check()
            if len(data) % (channels * width):
                raise ValueError("Truncated PCM frame")
            if width == 1:
                samples = np.frombuffer(data, dtype=np.uint8).astype(np.int16) - 128
            elif width == 3:
                octets = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
                samples = octets[:, 0] | (octets[:, 1] << 8) | (octets[:, 2] << 16)
                samples = (samples ^ 0x800000) - 0x800000
            else:
                samples = np.frombuffer(data, dtype=f"<i{width}")
            samples = samples.reshape(-1, channels)
            equal = bool(np.all(samples == samples[:, :1]))
            identical = identical and equal
            window_equal = window_equal and equal
            floating = samples.astype(np.float64)
            peaks = np.maximum(peaks, np.max(np.abs(floating), axis=0))
            squares += np.sum(floating * floating, axis=0)
            clipped += np.count_nonzero((samples == -scale) | (samples == scale - 1), axis=0)
            nonzero += np.count_nonzero(samples, axis=0)
            counts += len(data) // (channels * width)
            if counts - window_start == window_frames or counts == frames:
                windows.append({"start_frame": window_start, "end_frame": counts, "bit_identical": window_equal})
                window_start, window_equal = counts, True
        if counts != frames:
            raise ValueError("WAV data is truncated: frame count does not match header")
    final = path.stat()
    if (initial.st_size, initial.st_mtime_ns) != (final.st_size, final.st_mtime_ns):
        raise ValueError("Source changed while being inspected; finalize recording first")
    return {"path": str(path), "sha256": source_hash, "size_bytes": initial.st_size,
            "container": "WAV", "codec": "PCM", "sample_rate": rate,
            "bit_depth": width * 8, "channels": channels, "frames": frames,
            "duration_ms": math.ceil(frames * 1000 / rate),
            "channel_layout": "unspecified; channel indices preserved",
            "channels_bit_identical": identical,
            "channel_windows": {"policy": "exact_pcm_equality_v1", "window_seconds": CHANNEL_POLICY.window_seconds,
                                "windows": windows},
            "mono_policy": "separate_channels_preserved; no downmix",
            "channel_metrics": [
                {"channel": c, "peak": float(peaks[c] / scale),
                 "rms": math.sqrt(squares[c] / frames) / scale,
                 "clipped_samples": int(clipped[c]), "digital_silence": bool(nonzero[c] == 0)}
                for c in range(channels)],
            "speech_detection": "digital-silence-only; not a learned VAD"}


def prepare_channel(source: Path, channel: int, working: Path, ffmpeg: Path,
                    cancel: Cancellation) -> dict:
    command = [str(ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
               "-protocol_whitelist", "file", "-i", str(source), "-map", "0:a:0",
               "-af", f"pan=mono|c0=c{channel}", "-ar", "16000", "-c:a", "pcm_s16le",
               str(working)]
    elapsed = run_local(command, working.with_suffix(".log"), cancel)
    with wave.open(str(working), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
            raise ValueError("Normalizer produced an unexpected WAV format")
    return {"channel": channel, "path": working.name,
            "sha256": sha256(working, cancel.check), "command": command,
            "duration_seconds": elapsed, "sample_rate": 16000, "bit_depth": 16}
