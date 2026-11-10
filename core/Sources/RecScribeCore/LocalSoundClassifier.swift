import AVFoundation
import Foundation
import SoundAnalysis
import Synchronization

/// Offline evaluation of one already extracted mono passage. Not connected to capture or ASR.
public enum LocalSoundClassifier {
    public struct Report: Codable, Sendable {
        public let sourceSHA256: String
        public let classifier: String
        public let windowSeconds: Double
        public let overlap: Double
        public let assessment: MusicOnlyAssessment
    }

    public static func assess(_ source: URL, check: @Sendable () throws -> Void = {}) throws -> Report {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        func checkpoint() throws {
            try check()
            guard ContinuousClock.now < deadline else { throw CoreFailure("Acoustic analysis timed out") }
        }
        try checkpoint()
        let layout = try WAVAudio.layout(source, check: checkpoint)
        let duration = Double(layout.frames) / Double(layout.rate)
        guard layout.channels == 1, layout.fileBytes <= 24_000_000, (3...120).contains(duration) else {
            throw CoreFailure("Acoustic analysis requires a 3–120 second mono PCM WAV, at most 24 MB")
        }
        let digest = try WAVAudio.hash(source, check: checkpoint)
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length == layout.frames, file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate == Double(layout.rate) else {
            throw CoreFailure("Acoustic input format changed")
        }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard MusicOnlyAssessment.requiredLabels.isSubset(of: Set(request.knownClassifications)) else {
            throw CoreFailure("Acoustic classifier taxonomy is unsupported")
        }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        let observer = Observer()
        let analyzer = SNAudioStreamAnalyzer(format: file.processingFormat)
        try analyzer.add(request, withObserver: observer)
        defer { analyzer.removeAllRequests() }
        var position: AVAudioFramePosition = 0
        while position < file.length {
            try checkpoint()
            // The framework may retain a buffer until asynchronous analysis finishes.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                throw CoreFailure("Cannot allocate acoustic analysis buffer")
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - position)))
            guard buffer.frameLength > 0 else { throw CoreFailure("Truncated acoustic input") }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
            if observer.state.withLock({ $0.failed }) { throw CoreFailure("Acoustic classifier failed") }
        }
        analyzer.completeAnalysis()
        while !observer.state.withLock({ $0.completed || $0.failed }) {
            try checkpoint()
            _ = observer.terminal.wait(timeout: .now() + 0.05)
        }
        try checkpoint()
        let state = observer.state.withLock { $0 }
        guard !state.failed else { throw CoreFailure("Acoustic classifier failed") }
        guard try WAVAudio.hash(source, check: checkpoint) == digest else {
            throw CoreFailure("Acoustic input changed during analysis")
        }
        return Report(sourceSHA256: digest, classifier: "SoundAnalysis.version1", windowSeconds: 1,
                      overlap: 0.5, assessment: .evaluate(duration: duration, windows: state.windows,
                                                       completed: state.completed))
    }

    private final class Observer: NSObject, SNResultsObserving, Sendable {
        struct State: Sendable {
            var windows: [MusicOnlyAssessment.Window] = []
            var failed = false
            var completed = false
        }
        let state = Mutex(State())
        let terminal = DispatchSemaphore(value: 0)

        func request(_ request: SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else {
                fail()
                return
            }
            var scores: [String: Double] = [:]
            for label in MusicOnlyAssessment.requiredLabels {
                scores[label] = result.classification(forIdentifier: label)?.confidence
            }
            let window = MusicOnlyAssessment.Window(start: result.timeRange.start.seconds,
                                                    end: CMTimeRangeGetEnd(result.timeRange).seconds, scores: scores)
            state.withLock {
                guard !$0.failed, !$0.completed else { return }
                guard $0.windows.count < MusicOnlyAssessment.maximumWindows else { $0.failed = true; return }
                $0.windows.append(window)
            }
        }

        func request(_ request: SNRequest, didFailWithError error: any Error) { fail() }
        func requestDidComplete(_ request: SNRequest) {
            state.withLock { $0.completed = true }
            terminal.signal()
        }
        private func fail() {
            state.withLock { $0.failed = true }
            terminal.signal()
        }
    }
}
