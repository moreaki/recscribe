// Synthetic, bounded ownership probe for #83. No capture, file audio or TCC.
// "framework" intentionally reproduces an allocator-visibility diagnostic on
// affected runtimes. "fenced" adds reader-completion HB for the same allocator.
// "owned" exercises the actual test fixture's no-copy storage, without that HB.
import Foundation
import AVFoundation
import Synchronization

final class Lifetime: Sendable {
    let released = Atomic(false)
    let readComplete = Atomic(false)
}
final class ObservedPCM: AVAudioPCMBuffer {
    var onRelease: (() -> Void)?
    deinit { onRelease?() }
}
struct Owned: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let lifetime: Lifetime
}
let queue = DispatchQueue(label: "pcm-reader")
let pending = Atomic(0)
let checksum = Atomic<UInt64>(0)
let corruptBuffers = Atomic(0)
var previous: [UInt: Lifetime] = [:]
// Bound history independently of the number of stress iterations. No buffer
// owner is retained here; 512 entries exceed the 64 in-flight reader bound.
var recent = [(life: Lifetime, addresses: [UInt])?](repeating: nil, count: 512)
var peakTrackedSamples = 0
var reused = 0
var violations = 0
let mode = CommandLine.arguments.dropFirst().first ?? "owned"
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let bufferCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 20_000
precondition(["owned", "framework", "fenced"].contains(mode))
precondition((1024...1_000_000).contains(bufferCount))
for index in 0..<bufferCount {
    while pending.load(ordering: .relaxed) >= 64 { Thread.sleep(forTimeInterval: 0.00001) }
    autoreleasepool {
        let slot = index % recent.count
        if let stale = recent[slot] {
            precondition(stale.life.released.load(ordering: .relaxed))
            precondition(stale.life.readComplete.load(ordering: .relaxed))
            for address in stale.addresses where previous[address] === stale.life {
                previous.removeValue(forKey: address)
            }
        }
        var addresses: [UInt] = []
        addresses.reserveCapacity(128)
        let life = Lifetime()
        let pcm: AVAudioPCMBuffer
        if mode == "owned" {
            pcm = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 64, interleaved: false,
                onDeallocate: { life.released.store(true, ordering: .relaxed) }) { _, _ in 0 }
        } else {
            let observed = ObservedPCM(pcmFormat: format, frameCapacity: 64)!
            observed.onRelease = {
                life.released.store(true, ordering: .relaxed)
            }
            pcm = observed
        }
        pcm.frameLength = 64
        let data = pcm.floatChannelData!
        for channel in 0..<2 {
            // Track every sample, not just channel bases: framework pool blocks
            // can be split/reused at different offsets on the next allocation.
            for frame in 0..<64 {
                let address = UInt(bitPattern: data[channel].advanced(by: frame))
                if let prior = previous[address] {
                    reused += 1
                    let released = prior.released.load(ordering: .relaxed)
                    let readComplete = mode == "fenced" ? prior.readComplete.load(ordering: .acquiring) : prior.readComplete.load(ordering: .relaxed)
                    if !released || !readComplete { violations += 1 }
                }
                previous[address] = life
                addresses.append(address)
            }
            for frame in 0..<64 { data[channel][frame] = Float((index + channel + frame) % 32) / 32 }
        }
        recent[slot] = (life, addresses)
        peakTrackedSamples = max(peakTrackedSamples, previous.count)
        let owned = Owned(buffer: pcm, lifetime: life)
        pending.wrappingAdd(1, ordering: .relaxed)
        queue.async {
            autoreleasepool {
                withExtendedLifetime(owned.buffer) {
                    let values = owned.buffer.floatChannelData!
                    var sum: UInt64 = 0
                    var changed = false
                    for channel in 0..<2 {
                        for frame in 0..<64 {
                            let value = values[channel][frame]
                            changed = changed || value != Float((index + channel + frame) % 32) / 32
                            sum += UInt64(value * 32)
                        }
                    }
                    checksum.wrappingAdd(sum, ordering: .relaxed)
                    if changed || sum != 1984 { corruptBuffers.wrappingAdd(1, ordering: .relaxed) }
                    // Publish from the actual reader. The last owner can die on
                    // the producer, so a fence only in deinit is insufficient.
                    if mode == "fenced" { owned.lifetime.readComplete.store(true, ordering: .releasing) }
                    else { owned.lifetime.readComplete.store(true, ordering: .relaxed) }
                }
            }
            pending.wrappingSubtract(1, ordering: .relaxed)
        }
    }
}
queue.sync {}
print("PROBE mode=\(mode) buffers=\(bufferCount) reused_sample_addresses=\(reused) peak_tracked_samples=\(peakTrackedSamples) live_owner_overlap=\(violations) corrupt_buffers=\(corruptBuffers.load(ordering: .relaxed)) checksum=\(checksum.load(ordering: .relaxed))")

precondition(reused > 0, "Probe did not exercise storage reuse")
precondition(violations == 0, "A new allocation overlapped an owner still alive or reading")
precondition(corruptBuffers.load(ordering: .relaxed) == 0)
precondition(checksum.load(ordering: .relaxed) == UInt64(bufferCount) * 1984)
precondition(peakTrackedSamples <= 512 * 128)
