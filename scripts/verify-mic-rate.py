#!/usr/bin/env python3
"""Measure a known microphone reference tone in a PCM16 WAV recording.

REF_HZ chooses the reference frequency (default 1000 Hz). This developer check
uses only Python's standard library and never edits the recording being measured.
"""
import argparse
from array import array
import math
import os
from pathlib import Path
import statistics
import struct
import sys
import wave


def write_tone(path, frequency):
    # Exclusive creation protects existing recordings and earlier reference files.
    with path.open("xb") as raw, wave.open(raw, "wb") as output:
        rate = 48_000
        output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        for first in range(0, 75 * rate, 4_800):
            values = [round(3_276 * math.sin(2 * math.pi * frequency * frame / rate))
                      for frame in range(first, min(first + 4_800, 75 * rate))]
            output.writeframes(struct.pack("<" + "h" * len(values), *values))
    print(f"Reference tone created: {path} ({frequency:g} Hz, 75 seconds)")


def inspect(path):
    with wave.open(str(path), "rb") as source:
        if source.getsampwidth() != 2 or source.getcomptype() != "NONE":
            raise ValueError("Expected a PCM16 WAV recording")
        rate, channels, frames = source.getframerate(), source.getnchannels(), source.getnframes()
        if not frames or not channels or not rate:
            raise ValueError("No PCM frames to measure")
        # Retain at most six seconds from the middle; accumulate whole-file level
        # statistics in blocks rather than loading long recordings into memory.
        window_count = min(frames, rate * 6)
        window_start = max(0, (frames - window_count) // 2)
        retained, peak, energy, measured, position = [], 0, 0.0, 0, 0
        while data := source.readframes(8_192):
            integers = array("h")
            integers.frombytes(data)
            if sys.byteorder != "little":
                integers.byteswap()
            if len(integers) % channels:
                raise ValueError("Incomplete PCM frame")
            for frame in range(len(integers) // channels):
                offset = frame * channels
                sample = sum(integers[offset:offset + channels]) / channels / 32_768
                peak = max(peak, abs(sample))
                energy += sample * sample
                if window_start <= position < window_start + window_count:
                    retained.append(sample)
                position += 1
                measured += 1
        if measured != frames:
            raise ValueError("WAV payload is shorter than its declared duration")
        return rate, frames / rate, peak, math.sqrt(energy / measured), retained


def estimate_frequency(samples, rate):
    center = statistics.fmean(samples)
    threshold = max(abs(value - center) for value in samples) * 0.1
    armed, crossing, previous = False, None, samples[0] - center
    events = []
    for index, raw in enumerate(samples[1:], 1):
        value = raw - center
        if value <= -threshold:
            armed = True
        if armed and previous <= 0 < value:
            crossing = index - 1 + (-previous / (value - previous))
        if armed and value >= threshold and crossing is not None:
            events.append(crossing)
            crossing = None
            armed = False
        previous = value
    periods = [right - left for left, right in zip(events, events[1:]) if right > left]
    if len(periods) < 4:
        raise ValueError("Not enough stable tone cycles to measure pitch")
    return rate / statistics.median(periods)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", nargs="?", type=Path)
    parser.add_argument("wall_clock_seconds", nargs="?", type=float)
    parser.add_argument("--tone", action="store_true")
    options = parser.parse_args()
    try:
        reference = float(os.environ.get("REF_HZ", "1000"))
        if not math.isfinite(reference) or not 20 <= reference < 20_000:
            raise ValueError("REF_HZ must be between 20 and 20000 Hz")
        if options.tone:
            write_tone(options.recording or Path(f"recscribe-{reference:g}hz-reference.wav"), reference)
            return 0
        if options.recording is None:
            parser.error("Supply a recording, or use --tone [output.wav]")
        rate, duration, peak, rms, samples = inspect(options.recording)
        if peak < 0.001:
            raise ValueError("Recording is silent or below -60 dBFS")
        measured = estimate_frequency(samples, rate)
        ratio = measured / reference
        print(f"Declared rate: {rate} Hz; duration: {duration:.3f} s")
        print(f"Peak: {20 * math.log10(peak):.1f} dBFS; RMS: {20 * math.log10(rms):.1f} dBFS")
        print(f"Measured tone: {measured:.2f} Hz ({ratio:.5f}x reference)")
        failures = []
        if abs(ratio - 1) > 0.01:
            failures.append("reference pitch differs by more than 1%")
        if options.wall_clock_seconds is not None:
            wall = options.wall_clock_seconds
            if not math.isfinite(wall) or wall <= 0:
                raise ValueError("Wall-clock duration must be finite and positive")
            print(f"Duration ratio: {duration / wall:.5f}x wall clock")
            if abs(duration / wall - 1) > 0.02:
                failures.append("recorded duration differs by more than 2%")
        if failures:
            print("FAIL: " + "; ".join(failures))
            return 1
        print("PASS")
        return 0
    except (OSError, ValueError, wave.Error) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
