import CryptoKit
import Foundation

/// Streaming integer PCM inspection. Channel reuse requires exact sample equality,
/// never text similarity, correlation, or an implicit stereo-to-mono mix.
public enum WAVAudio {
    public enum Policy {
        public static let readFrames = 65_536
        public static let windowSeconds = 30
        public static let contextSeconds = 2
        public static let maximumRegions = 8
        public static let maximumChannelWindows = 16_384
    }
    public struct Layout: Sendable {
        public let channels: Int
        public let rate: Int
        public let width: Int
        public let frames: Int64
        public let dataOffset: UInt64
        public let fileBytes: Int64
    }
    public struct Inspection: Sendable {
        public let layout: Layout
        public let report: JSONValue
    }
    public static func hash(_ url: URL, check: () throws -> Void = {}) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            try check()
            guard let bytes = try file.read(upToCount: 1_024 * 1_024), !bytes.isEmpty else { break }
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func layout(_ url: URL, check: () throws -> Void = {}) throws -> Layout {
        try check()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        func read(_ count: Int) throws -> [UInt8] {
            let bytes = Array(try file.read(upToCount: count) ?? Data())
            guard bytes.count == count else { throw CoreFailure("Truncated WAV header") }
            return bytes
        }
        let header = try read(12)
        guard String(bytes: header[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: header[8..<12], encoding: .ascii) == "WAVE" else {
            throw CoreFailure("Only RIFF integer PCM WAV is supported")
        }
        let riffEnd = UInt64(number(header, 4, 4)) + 8
        guard riffEnd <= size else { throw CoreFailure("Truncated WAV container") }
        var format: (Int, Int, Int)?
        var payload: (UInt64, Int64)?
        while try file.offset() + 8 <= riffEnd {
            try check()
            let chunk = try read(8), count = number(chunk, 4, 4)
            let offset = try file.offset(), end = offset + UInt64(count)
            guard end <= riffEnd else { throw CoreFailure("Truncated WAV chunk") }
            let tag = String(bytes: chunk[0..<4], encoding: .ascii)
            if tag == "fmt " {
                guard format == nil, count >= 16 else { throw CoreFailure("Invalid WAV format chunk") }
                let bytes = try read(Int(min(count, 40)))
                let kind = number(bytes, 0, 2), channels = Int(number(bytes, 2, 2))
                let rate = Int(number(bytes, 4, 4)), bits = Int(number(bytes, 14, 2))
                let pcmGUID: [UInt8] = [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113]
                let extensible = kind == 0xfffe && bytes.count == 40 && number(bytes, 16, 2) >= 22
                    && number(bytes, 18, 2) == bits && Array(bytes[24..<40]) == pcmGUID
                guard (kind == 1 || extensible), (1...32).contains(channels),
                      (1...384_000).contains(rate), [8,16,24,32].contains(bits),
                      number(bytes, 12, 2) == channels * (bits / 8),
                      number(bytes, 8, 4) == rate * channels * (bits / 8) else {
                    throw CoreFailure("WAV must be integer PCM, 8/16/24/32-bit, with 1–32 channels")
                }
                format = (channels, rate, bits / 8)
            } else if tag == "data" {
                guard payload == nil else { throw CoreFailure("Multiple WAV data chunks are unsupported") }
                payload = (offset, count)
            }
            try file.seek(toOffset: end + UInt64(count & 1))
        }
        guard let (channels, rate, width) = format, let (offset, bytes) = payload,
              bytes > 0, bytes % Int64(channels * width) == 0 else { throw CoreFailure("WAV has no complete audio frames") }
        return Layout(channels: channels, rate: rate, width: width,
                      frames: bytes / Int64(channels * width), dataOffset: offset, fileBytes: Int64(size))
    }
    private static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int64 {
        (0..<count).reduce(0) { $0 | Int64(bytes[offset + $1]) << ($1 * 8) }
    }
    public static func inspect(_ url: URL, check: () throws -> Void = {}) throws -> Inspection {
        let initial = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let digest = try hash(url, check: check), layout = try layout(url, check: check)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: layout.dataOffset)
        let channels = layout.channels, width = layout.width, scale = Double(Int64(1) << (width * 8 - 1))
        var peaks = [Double](repeating: 0, count: channels), squares = peaks
        var clipped = [Int64](repeating: 0, count: channels), nonzero = clipped
        var frames: Int64 = 0, windowStart: Int64 = 0, equal = true, windowEqual = true
        var windows: [JSONValue] = []
        let windowFrames = Int64(layout.rate * Policy.windowSeconds)
        let retainWindows = (layout.frames + windowFrames - 1) / windowFrames <= Policy.maximumChannelWindows
        while frames < layout.frames {
            try check()
            let count = Int(min(Int64(Policy.readFrames), layout.frames - frames, windowFrames - (frames - windowStart)))
            let data = try file.read(upToCount: count * channels * width) ?? Data()
            guard data.count == count * channels * width else { throw CoreFailure("Truncated PCM frames") }
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for frame in 0..<count {
                    var first: Int64 = 0
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * width
                        var sample: Int64 = 0
                        for byte in 0..<width { sample |= Int64(bytes[offset + byte]) << (byte * 8) }
                        if width == 1 { sample -= 128 }
                        else if sample & (Int64(1) << (width * 8 - 1)) != 0 { sample -= Int64(1) << (width * 8) }
                        if channel == 0 { first = sample }
                        else if sample != first { equal = false; windowEqual = false }
                        let value = Double(sample)
                        peaks[channel] = max(peaks[channel], abs(value))
                        squares[channel] += value * value
                        if sample != 0 { nonzero[channel] += 1 }
                        if value == -scale || value == scale - 1 { clipped[channel] += 1 }
                    }
                }
            }
            frames += Int64(count)
            if frames - windowStart == windowFrames || frames == layout.frames {
                if retainWindows { windows.append(["start_frame": .integer(windowStart), "end_frame": .integer(frames), "bit_identical": .bool(windowEqual)]) }
                windowStart = frames; windowEqual = true
            }
        }
        let final = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard initial.fileSize == final.fileSize, initial.contentModificationDate == final.contentModificationDate,
              (initial.fileResourceIdentifier as? NSObject) == (final.fileResourceIdentifier as? NSObject) else {
            throw CoreFailure("Source changed during inspection; finalize recording first")
        }
        let report: JSONValue = ["path": .string(url.path), "sha256": .string(digest), "size_bytes": .integer(layout.fileBytes),
            "container": "WAV", "codec": "PCM", "sample_rate": .integer(Int64(layout.rate)), "bit_depth": .integer(Int64(width * 8)),
            "channels": .integer(Int64(channels)), "frames": .integer(frames), "duration_ms": .integer((frames * 1000 + Int64(layout.rate) - 1) / Int64(layout.rate)),
            "channel_layout": "unspecified; channel indices preserved", "channels_bit_identical": .bool(equal),
            "channel_windows": ["policy": "exact_pcm_equality_v1", "window_seconds": .integer(Int64(Policy.windowSeconds)), "windows": .array(windows)],
            "mono_policy": "separate_channels_preserved; no downmix", "speech_detection": "digital-silence-only; not a learned VAD",
            "channel_metrics": .array((0..<channels).map { c in
                ["channel": .integer(Int64(c)), "peak": .number(peaks[c] / scale), "rms": .number(sqrt(squares[c] / Double(frames)) / scale),
                 "clipped_samples": .integer(clipped[c]), "digital_silence": .bool(nonzero[c] == 0)]
            })]
        return Inspection(layout: layout, report: report)
    }

    /// Only channel 1 may reuse channel 0 outside exact-equality stereo windows.
    public static func recognitionRegions(_ report: JSONValue, channel: Int) throws -> [Range<Int64>]? {
        guard report["channels"] == 2, channel == 1, report["channels_bit_identical"] == false,
              let windows = report["channel_windows"]["windows"].array, !windows.isEmpty,
              let frames = report["frames"].integer, let rate = report["sample_rate"].integer else { return nil }
        var cursor: Int64 = 0, regions: [Range<Int64>] = []
        for window in windows {
            guard window["start_frame"].integer == cursor, let end = window["end_frame"].integer,
                  end > cursor, end <= frames, let identical = window["bit_identical"].bool else { throw CoreFailure("Invalid channel analysis coverage") }
            if !identical {
                let start = max(0, cursor - rate * Int64(Policy.contextSeconds)), stop = min(frames, end + rate * Int64(Policy.contextSeconds))
                if let last = regions.last, start <= last.upperBound { regions[regions.count - 1] = last.lowerBound..<stop }
                else { regions.append(start..<stop) }
            }
            cursor = end
        }
        guard cursor == frames else { throw CoreFailure("Incomplete channel analysis coverage") }
        return regions.isEmpty || regions.count > Policy.maximumRegions || regions == [0..<frames] ? nil : regions
    }

    /// Lossless slicing of an already normalized channel; no whole-file allocation.
    public static func copyFrames(_ source: URL, range: Range<Int64>, to output: URL,
                                  check: () throws -> Void) throws {
        let layout = try layout(source, check: check)
        guard layout.channels == 1, layout.width == 2, layout.rate == 16_000,
              range.lowerBound >= 0, !range.isEmpty, range.upperBound <= layout.frames else {
            throw CoreFailure("Invalid working-audio slice")
        }
        let bytes = (range.upperBound - range.lowerBound) * 2
        guard bytes <= Int64(UInt32.max) - 36 else { throw CoreFailure("Working slice exceeds RIFF limit") }
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func integer(_ value: Int64, _ width: Int) {
            for byte in 0..<width { header.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        text("RIFF"); integer(bytes + 36, 4); text("WAVEfmt "); integer(16, 4)
        integer(1, 2); integer(1, 2); integer(16_000, 4); integer(32_000, 4)
        integer(2, 2); integer(16, 2); text("data"); integer(bytes, 4)
        try header.write(to: output, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: source), target = try FileHandle(forWritingTo: output)
        defer { try? input.close(); try? target.close() }
        try input.seek(toOffset: layout.dataOffset + UInt64(range.lowerBound * 2))
        try target.seekToEnd()
        var remaining = bytes
        while remaining > 0 {
            try check()
            let count = Int(min(remaining, Int64(Policy.readFrames * 2)))
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw CoreFailure("Working channel changed during slicing") }
            try target.write(contentsOf: data); remaining -= Int64(count)
        }
    }
}
