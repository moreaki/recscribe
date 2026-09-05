//
//  GlassPreviewFixtures.swift
//  RecScribe
//
//  App-owned. Supplies the sample data the vendored `#Preview` blocks reference.
//
//  ⚠️ NOT `#if DEBUG`, and the reason is the whole point of this file.
//
//  It was, at first. Upstream keeps this data `internal` to the GlassKit package
//  precisely so it "can never ship in a release build", and `#if DEBUG` looked
//  like the way to restore that guarantee once vendoring dissolved the module
//  boundary. It does not work: `#Preview` is a macro that expands into ordinary
//  code in *every* configuration, so a Release build still compiles the vendored
//  previews and still needs the symbols they reference. Under `#if DEBUG` the
//  fixtures disappear and the archive fails with "cannot find
//  'GlassSampleWaveforms' in scope" — which is exactly how it was found, on the
//  first Release build anyone ran, after the tag had already been cut.
//
//  So the choice is: ship a few hundred bytes of obviously-synthetic floats, or
//  patch the vendored file to delete its previews. Shipping the floats is the
//  cheaper of the two — it keeps `Vendor/` byte-identical, which is the property
//  the whole vendoring arrangement rests on, and the preview scaffolding is
//  compiled into Release either way.
//
//  Nothing here is reachable from the app: no shipping code path calls it, and
//  the only references are the vendored `#Preview` blocks.
//

import Foundation

/// Deterministic synthetic waveforms for previews only.
///
/// Values are obviously fake — they are shaped to exercise the renderer's range,
/// not to resemble any real recording. Signatures match the upstream gallery's so
/// the vendored previews compile unmodified.
enum GlassSampleWaveforms {

    /// A take's identity shape: a slow envelope with per-bar variation, so the
    /// preview shows something with structure rather than a uniform band.
    static func identity(seed: UInt64, count: Int = 96) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { index in
            let position = Double(index) / Double(max(1, count - 1))
            // A single arch keeps the shape readable at thumbnail size; the noise
            // term stops it looking like a generated curve.
            let envelope = sin(position * .pi)
            let jitter = 0.55 + 0.45 * rng.nextUnit()
            return Float(min(1, max(0.04, envelope * jitter)))
        }
    }

    /// A live capture window: no envelope, because every bar is current.
    static func live(count: Int, seed: UInt64 = 7) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            Float(min(1, max(0.04, 0.15 + 0.75 * rng.nextUnit())))
        }
    }
}

/// Seeded generator so a preview renders identically on every rebuild —
/// `Float.random` would make the previews flicker on each recompile.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
