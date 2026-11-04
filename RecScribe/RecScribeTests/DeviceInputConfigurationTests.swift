import AVFoundation
import Foundation
import os
import Testing
@testable import RecScribe

struct DeviceInputConfigurationTests {
    @Test func establishedStreamIgnoresUnchangedRunningNotificationsButNeverZeroPCM() {
        let policy = DeviceInputConfigurationPolicy()
        for frames: Int64 in [1_024, 96_000] {
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
                running: true, receivedFrames: frames) == .ignore)
        }
        #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
            running: true, receivedFrames: 0) == .noAudio)
        #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
            running: false, receivedFrames: 1024) == .interrupted)
    }
    @Test func realDisconnectDeviceSubstitutionAndFormatChangeAlwaysFail() {
        for running in [false, true] {
            let policy = DeviceInputConfigurationPolicy()
            #expect(policy.evaluate(connected: false, sameDevice: true, sameFormat: true,
                running: running, receivedFrames: 1024) == .disconnected)
            #expect(policy.evaluate(connected: true, sameDevice: false, sameFormat: true,
                running: running, receivedFrames: 1024) == .deviceChanged)
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: false,
                running: running, receivedFrames: 1024) == .formatChanged)
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true, sameAggregateMembers: false,
                running: running, receivedFrames: 1024) == .aggregateChanged)
        }
    }
}

@MainActor struct DeviceInputStartupTests {
    final class Engine: DeviceInputEngine {
        var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var selected = true
        var connected = true
        var hardwareFormatMatches = true
        var running = false
        var changes: (@MainActor @Sendable () -> Void)?
        var savedChanges: (@MainActor @Sendable () -> Void)?
        var block: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        var bound = false
        var starts = 0
        var stops = 0
        var sendAudio = false
        var startError = false
        var snapshot: DeviceInputEngineSnapshot {
            .init(connected: connected, selected: selected, format: format, aggregateMembers: [], running: running, hardwareFormatMatches: hardwareFormatMatches)
        }
        func observe(_ changed: @escaping @MainActor @Sendable () -> Void) { changes = changed; savedChanges = changed }
        func bind() throws { #expect(changes != nil); bound = true }
        func installAndStart(format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
            #expect(bound && selected && format == self.format)
            starts += 1; self.block = block
            if startError { throw SessionError.invalid("Synthetic pending configuration") }
            running = true
            if sendAudio { emit() }
        }
        func emit() {
            let buffer = SampleBufferFixtures.makePCMBuffer(channels: Int(format.channelCount), frames: 32, sampleRate: format.sampleRate, interleaved: false) { _, _ in 0.2 }
            block?(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        }
        func stop() { running = false; changes = nil; stops += 1 }
    }
    @Test func waitsForStableSelectedDeviceAndNativeFormatBeforeTap() async throws {
        let engine = Engine(); engine.selected = false
        let received = OSAllocatedUnfairLock(initialState: [CapturedAudioSample]())
        var sleeps = 0
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { sample in received.withLock { $0.append(sample) } },
            onFailure: { failures.append($0) }, engineFactory: { engine }, sleep: { _ in
                sleeps += 1
                if sleeps == 1 {
                    #expect(engine.starts == 0)
                    engine.selected = true
                    engine.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
                    engine.changes?()
                }
                engine.sendAudio = true
                await Task.yield()
            })
        try input.start()
        await waitUntil("native tap delivers PCM") { !received.withLock { $0.isEmpty } }
        await settle()
        #expect(engine.starts == 1)
        #expect(received.withLock { $0.first?.buffer.format.sampleRate } == 44_100)
        #expect(received.withLock { $0.first?.buffer.format.channelCount } == 2)
        #expect(failures.isEmpty)
        input.stop()
    }
    @Test func selectedUIDWithStaleFormatCannotInstallTapUntilHardwareAgrees() async throws {
        let engine = Engine(); engine.hardwareFormatMatches = false; engine.sendAudio = true
        var sleeps = 0
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in }, onFailure: { failures.append($0) },
            engineFactory: { engine }, sleep: { _ in
                sleeps += 1
                if sleeps <= 4 { #expect(engine.starts == 0) }
                if sleeps == 4 {
                    engine.format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                    engine.hardwareFormatMatches = true
                    engine.changes?()
                }
                await Task.yield()
            })
        try input.start()
        await waitUntil("hardware format settles") { engine.starts == 1 }
        await settle()
        #expect(sleeps >= 5 && failures.isEmpty)
        input.stop()
    }
    @Test func runningWithoutPCMRebuildsTapAndSealsOldCallbacks() async throws {
        let first = Engine(), second = Engine(); second.sendAudio = true
        var engines = [first, second]
        let received = OSAllocatedUnfairLock(initialState: 0)
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in received.withLock { $0 += 1 } },
            onFailure: { failures.append($0) }, engineFactory: { engines.removeFirst() }, sleep: { _ in await Task.yield() })
        try input.start()
        await waitUntil("replacement tap") { second.starts == 1 }
        await settle()
        #expect(first.starts == 1 && first.stops == 1)
        let count = received.withLock { $0 }
        first.emit(); first.savedChanges?()
        await settle()
        #expect(received.withLock { $0 } == count)
        #expect(second.stops == 0 && failures.isEmpty)
        input.stop()
    }
    @Test func noPCMTimesOutOnceWithoutUnboundedEngineRetries() async throws {
        var engines: [Engine] = []
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in Issue.record("Unexpected PCM") },
            onFailure: { failures.append($0) }, engineFactory: { let engine = Engine(); engines.append(engine); return engine },
            sleep: { _ in await Task.yield() })
        try input.start()
        await waitUntil("bounded no-audio failure") { !failures.isEmpty }
        await settle()
        #expect(engines.count == 3)
        #expect(engines.allSatisfy { $0.starts == 1 && $0.stops == 1 })
        #expect(failures.count == 1 && failures[0].contains("no audio"))
        for engine in engines { engine.savedChanges?() }
        await settle()
        #expect(failures.count == 1 && engines.count == 3)
        input.stop()
    }
    @Test func stopDuringConfigurationWaitCannotInstallLateTapOrReportFailure() async throws {
        let engine = Engine()
        var gate: CheckedContinuation<Void, Never>?
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in Issue.record("Late PCM") },
            onFailure: { failures.append($0) }, engineFactory: { engine }, sleep: { _ in
                await withCheckedContinuation { gate = $0 }
            })
        try input.start()
        await waitUntil("startup wait") { gate != nil }
        input.stop(); gate?.resume(); gate = nil
        engine.savedChanges?()
        await settle()
        #expect(engine.starts == 0 && engine.stops == 1 && failures.isEmpty)
    }
    @Test func pendingConfigurationAndThrownStartBothRecoverWithinBudget() async throws {
        let pending = Engine(); pending.selected = false
        let throwing = Engine(); throwing.startError = true
        let ready = Engine(); ready.sendAudio = true
        var engines = [pending, throwing, ready]
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in }, onFailure: { failures.append($0) },
            engineFactory: { engines.removeFirst() }, sleep: { _ in await Task.yield() })
        try input.start()
        await waitUntil("third engine starts") { ready.starts == 1 }
        await settle()
        #expect(pending.starts == 0 && pending.stops == 1)
        #expect(throwing.starts == 1 && throwing.stops == 1)
        #expect(ready.stops == 0 && failures.isEmpty)
        input.stop()
    }
    @Test func stopWhileAwaitingFirstPCMCancelsRecoveryAndSealsTap() async throws {
        let engine = Engine()
        var gate: CheckedContinuation<Void, Never>?
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in Issue.record("Late PCM") },
            onFailure: { failures.append($0) }, engineFactory: { engine }, sleep: { duration in
                if duration == .milliseconds(500) { await withCheckedContinuation { gate = $0 } }
                else { await Task.yield() }
            })
        try input.start()
        await waitUntil("waiting for first PCM") { gate != nil }
        input.stop(); gate?.resume(); gate = nil
        engine.emit(); engine.savedChanges?()
        await settle()
        #expect(engine.starts == 1 && engine.stops == 1 && failures.isEmpty)
    }
    @Test func establishedStreamFailureDoesNotRestartOrSubstituteDevice() async throws {
        let engine = Engine(); engine.sendAudio = true
        var failures: [String] = []
        let input = DeviceInputCapture(uid: "synthetic", callback: { _ in }, onFailure: { failures.append($0) },
            engineFactory: { engine }, sleep: { _ in await Task.yield() })
        try input.start()
        await waitUntil("initial PCM") { engine.starts == 1 }
        await settle()
        engine.selected = false; engine.changes?()
        await settle()
        #expect(failures.count == 1 && engine.starts == 1 && engine.stops == 1)
        input.stop()
    }
}
