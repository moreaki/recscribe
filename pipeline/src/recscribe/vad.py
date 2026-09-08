"""Bounded model-family preflight, not a substitute for a verified download.

Layout: whisper.cpp models/convert-silero-vad-to-ggml.py (v1.9.2).
Whisper recognition models share the GGML magic but NOT this header.
"""
import struct

GGML_MAGIC = 0x67676D6C
SILERO_FAMILY = b"silero-16k"
PREFIX = struct.pack("<II", GGML_MAGIC, len(SILERO_FAMILY)) + SILERO_FAMILY
HEADER_PARAMETERS = struct.Struct("<6i")  # version, window, context, encoder layers
SILERO_LAYOUT = (512, 64, 4)


def validate_vad(path):
    if path is None:
        return
    with path.open("rb") as stream:
        prefix = stream.read(len(PREFIX))
        parameters = stream.read(HEADER_PARAMETERS.size)
    if (prefix != PREFIX or len(parameters) != HEADER_PARAMETERS.size
            or HEADER_PARAMETERS.unpack(parameters)[3:] != SILERO_LAYOUT):
        raise ValueError("Invalid VAD model: select a whisper.cpp Silero 16-kHz VAD model, "
                         "not a Whisper transcription model. Clear optional VAD in Settings to run without it.")
