#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace recscribe_probe {
inline std::vector<std::uint8_t> serialize_token_prefix(const std::vector<std::int32_t> & tokens) {
    if (tokens.empty() || tokens.size() > 64) throw std::runtime_error("Invalid prefix token count");
    std::vector<std::uint8_t> bytes;
    bytes.reserve(tokens.size() * 4);
    for (const auto token : tokens) {
        if (token < 0 || token >= 51865) throw std::runtime_error("Invalid multilingual prefix token");
        const auto value = std::uint32_t(token);
        for (int shift = 0; shift < 32; shift += 8) bytes.push_back((value >> shift) & 0xff);
    }
    return bytes;
}

inline std::uint16_t u16(const std::vector<std::uint8_t> & b, std::size_t p) {
    if (p + 2 > b.size()) throw std::runtime_error("Truncated WAV integer");
    return std::uint16_t(b[p]) | (std::uint16_t(b[p + 1]) << 8);
}
inline std::uint32_t u32(const std::vector<std::uint8_t> & b, std::size_t p) {
    if (p + 4 > b.size()) throw std::runtime_error("Truncated WAV integer");
    return std::uint32_t(b[p]) | (std::uint32_t(b[p + 1]) << 8) |
        (std::uint32_t(b[p + 2]) << 16) | (std::uint32_t(b[p + 3]) << 24);
}
inline bool tag(const std::vector<std::uint8_t> & b, std::size_t p, const char * text) {
    return p + 4 <= b.size() && b[p] == text[0] && b[p + 1] == text[1] &&
        b[p + 2] == text[2] && b[p + 3] == text[3];
}

// Accept prepared PCM16 only; do not silently resample, mix, crop or normalize.
inline std::vector<float> pcm16_mono_16k(const std::vector<std::uint8_t> & b) {
    if (b.size() < 44 || b.size() > 2 * 1024 * 1024 || !tag(b, 0, "RIFF") ||
        !tag(b, 8, "WAVE") || std::uint64_t(u32(b, 4)) + 8 != b.size()) {
        throw std::runtime_error("Expected bounded RIFF/WAVE input");
    }
    bool format = false, audio = false;
    std::size_t data_start = 0, data_bytes = 0;
    for (std::size_t p = 12; p < b.size();) {
        if (p + 8 > b.size()) throw std::runtime_error("Truncated WAV chunk header");
        const std::size_t length = u32(b, p + 4);
        const std::size_t end = p + 8 + length;
        if (end > b.size() || end < p) throw std::runtime_error("Truncated WAV chunk");
        if (tag(b, p, "fmt ")) {
            if (format || length < 16 || u16(b, p + 8) != 1 || u16(b, p + 10) != 1 ||
                u32(b, p + 12) != 16000 || u32(b, p + 16) != 32000 ||
                u16(b, p + 20) != 2 || u16(b, p + 22) != 16) {
                throw std::runtime_error("Expected one PCM16 mono 16kHz format chunk");
            }
            format = true;
        } else if (tag(b, p, "data")) {
            if (audio || length == 0 || length % 2 != 0 || length > 30 * 16000 * 2) {
                throw std::runtime_error("Expected one nonempty audio chunk of at most 30 seconds");
            }
            audio = true; data_start = p + 8; data_bytes = length;
        }
        p = end + (length % 2);
        if (p > b.size()) throw std::runtime_error("Missing WAV chunk padding");
    }
    if (!format || !audio) throw std::runtime_error("Missing WAV format/audio chunk");
    std::vector<float> out(data_bytes / 2);
    for (std::size_t i = 0; i < out.size(); ++i) {
        const std::uint16_t raw = u16(b, data_start + 2 * i);
        const std::int32_t signed_value = raw >= 32768 ? std::int32_t(raw) - 65536 : raw;
        out[i] = float(signed_value) / 32768.0f;
    }
    return out;
}

inline bool valid_utf8(const std::vector<std::uint8_t> & bytes) {
    for (std::size_t i = 0; i < bytes.size();) {
        const auto c = bytes[i++];
        if (c == 0) return false;
        if (c < 0x80) continue;
        std::uint32_t value = 0, minimum = 0;
        std::size_t rest = 0;
        if (c >= 0xc2 && c <= 0xdf) { value = c & 0x1f; rest = 1; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { value = c & 0x0f; rest = 2; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { value = c & 0x07; rest = 3; minimum = 0x10000; }
        else return false;
        if (i + rest > bytes.size()) return false;
        while (rest--) {
            const auto next = bytes[i++];
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return !bytes.empty();
}
} // namespace recscribe_probe
