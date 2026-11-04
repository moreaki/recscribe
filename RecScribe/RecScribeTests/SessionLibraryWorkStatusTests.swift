import Foundation
import os
import Testing
@testable import RecScribe

@MainActor
struct SessionLibraryWorkStatusTests {
    enum Gate: CaseIterable {
        case recording, liveTranscription

        var label: String { self == .recording ? "recording" : "live transcription" }

        @MainActor func set(_ active: Bool, on library: SessionLibrary) {
            switch self {
            case .recording: library.setRecording(active)
            case .liveTranscription: library.setLiveWork(active)
            }
        }
    }

    private nonisolated final class Worker: Sendable {
        let started = AsyncStream<URL>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: [URL]())

        func process(_ manifest: URL, _ ffmpeg: URL, _ token: WorkCancellation,
                     _ recover: Bool, _ issue: String?) throws -> RecordingSession {
            calls.withLock { $0.append(manifest) }
            started.continuation.yield(manifest)
            guard release.wait(timeout: .now() + 30) == .success else { throw POSIXError(.ETIMEDOUT) }
            try token.check()
            var result = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mono"], options: .init())
            result.status = .completed
            return result
        }

        func waitForStart() async {
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func library(worker: Worker) -> SessionLibrary {
        SessionLibrary(settings: {
            var values = AppSettings.Values()
            values.autoTranscribe = false
            return values
        }, processSession: worker.process, readSessions: { _ in SessionSnapshot() })
    }

    @Test(arguments: Gate.allCases)
    func captureWithoutJobsNeverClaimsWorkIsPaused(_ gate: Gate) async {
        let library = SessionLibrary()
        #expect(library.activity == "Ready")
        #expect(!library.workInProgress)
        #expect(!library.canCancelWork)
        gate.set(true, on: library)
        #expect(library.activity == "Ready")
        #expect(!library.workInProgress)
        #expect(!library.canCancelWork)
        gate.set(false, on: library)
        library.cancel() // An idle Cancel is a no-op, not a fake cancellation.
        #expect(library.activity == "Ready")
        #expect(!library.workInProgress)
        #expect(!library.canCancelWork)
        await library.shutdown()
    }

    @Test(arguments: Gate.allCases)
    func queuedWorkNamesItsGateAndCanBeCancelledWithoutAWorker(_ gate: Gate) async {
        let worker = Worker()
        // No process may be admitted while capture has priority.
        let observed = self.library(worker: worker)
        gate.set(true, on: observed)
        observed.enqueue(URL(fileURLWithPath: "/synthetic/first.recscribe.json"), recover: true)
        observed.enqueue(URL(fileURLWithPath: "/synthetic/second.recscribe.json"))
        #expect(observed.activity == "Recording verification/recovery queued (2) · waiting for \(gate.label)")
        #expect(!observed.workInProgress)
        #expect(observed.canCancelWork)
        #expect(worker.calls.withLock { $0.isEmpty })
        observed.cancel()
        #expect(observed.activity == "Cancelled; originals retained")
        #expect(!observed.canCancelWork)
        gate.set(false, on: observed)
        await settle()
        #expect(worker.calls.withLock { $0.isEmpty })
        #expect(!observed.workInProgress)
        await observed.shutdown()
    }

    @Test(arguments: Gate.allCases)
    func queuedWorkResumesAndRetainsItsTerminalStatus(_ gate: Gate) async {
        let worker = Worker(), library = library(worker: worker)
        defer { worker.release.signal() }
        gate.set(true, on: library)
        library.enqueue(URL(fileURLWithPath: "/synthetic/first.recscribe.json"))
        gate.set(false, on: library)
        await worker.waitForStart()
        #expect(library.activity == "Verifying recording and archive…")
        #expect(library.workInProgress)
        #expect(library.canCancelWork)
        worker.release.signal()
        await waitUntil("verification completed") { library.canDeleteRecording }
        #expect(library.activity == "Recording verified; originals retained")
        #expect(!library.workInProgress)
        #expect(!library.canCancelWork)
        gate.set(true, on: library)
        gate.set(false, on: library)
        #expect(library.activity == "Recording verified; originals retained")
        await library.shutdown()
    }

    @Test(arguments: Gate.allCases, [false, true])
    func captureInterruptionRequeuesUnlessTheUserCancels(_ gate: Gate, cancel: Bool) async {
        let worker = Worker(), library = library(worker: worker)
        defer { worker.release.signal() }
        let first = URL(fileURLWithPath: "/synthetic/first.recscribe.json")
        library.enqueue(first, recover: true)
        await worker.waitForStart()
        gate.set(true, on: library)
        library.enqueue(URL(fileURLWithPath: "/synthetic/second.recscribe.json"))
        #expect(!library.workInProgress)
        #expect(library.canCancelWork)
        if cancel { library.cancel() }
        worker.release.signal()
        if cancel {
            await waitUntil("cancelled worker drained") { library.activity == "Cancelled; originals retained" }
            gate.set(false, on: library)
            await settle()
            #expect(worker.calls.withLock { $0 } == [first])
            #expect(!library.canCancelWork)
            #expect(!library.workInProgress)
        } else {
            await waitUntil("interrupted job requeued") {
                library.activity == "Recording verification/recovery queued (2) · waiting for \(gate.label)"
            }
            gate.set(false, on: library)
            await worker.waitForStart()
            #expect(library.activity == "Recovering recording parts…")
            #expect(library.workInProgress)
            worker.release.signal()
            await worker.waitForStart()
            worker.release.signal()
            await waitUntil("queue drained") { library.canDeleteRecording }
            #expect(worker.calls.withLock { $0.count } == 3)
            #expect(library.activity == "Recording verified; originals retained")
            #expect(!library.canCancelWork)
        }
        await library.shutdown()
    }

    @Test(arguments: Gate.allCases)
    func quickCaptureCycleStillResumesTheInterruptedWorker(_ gate: Gate) async {
        let worker = Worker(), library = library(worker: worker)
        defer { worker.release.signal() }
        let manifest = URL(fileURLWithPath: "/synthetic/quick-cycle.recscribe.json")
        library.enqueue(manifest)
        await worker.waitForStart()
        gate.set(true, on: library)
        #expect(library.canCancelWork)
        gate.set(false, on: library) // The original worker has not drained yet.
        worker.release.signal()
        await worker.waitForStart()
        #expect(library.activity == "Verifying recording and archive…")
        worker.release.signal()
        await waitUntil("resumed job finished") { library.canDeleteRecording }
        #expect(worker.calls.withLock { $0 } == [manifest, manifest])
        #expect(library.activity == "Recording verified; originals retained")
        #expect(!library.canCancelWork)
        #expect(!library.workInProgress)
        await library.shutdown()
    }

    @Test func failureRemainsVisibleWithoutFakeProgressOrCancellation() async {
        let library = SessionLibrary(processSession: { _, _, _, _, _ in throw POSIXError(.ENOSPC) },
                                     readSessions: { _ in SessionSnapshot() })
        library.enqueue(URL(fileURLWithPath: "/synthetic/failed.recscribe.json"))
        await waitUntil("failure released worker") { library.canDeleteRecording }
        #expect(library.activity == "Needs attention")
        #expect(library.errorMessage != nil)
        #expect(!library.workInProgress)
        #expect(!library.canCancelWork)
        library.setRecording(true)
        library.setRecording(false)
        #expect(library.activity == "Needs attention")
        await library.shutdown()
    }
}
