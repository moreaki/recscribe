import Darwin
import Foundation
import Observation
import RecScribeCore

nonisolated struct SegmentAcousticReference: Codable, Equatable, Sendable {
    let id: UUID
    let classifier: String
    let startMs: Int64
    let endMs: Int64
    let channel: Int
    let audioSHA256: String
    let reportSHA256: String
    var valid: Bool {
        classifier == "SoundAnalysis.version1" && startMs >= 0 && endMs > startMs && endMs - startMs >= 3_000
            && endMs - startMs <= 120_000 && (0..<32).contains(channel)
            && [audioSHA256, reportSHA256].allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
    }
}

nonisolated struct SegmentAcousticCandidate: Sendable {
    let selection: SegmentCloudSelection
    let report: LocalSoundClassifier.Report
    let reference: SegmentAcousticReference
    let evidence: URL
    var correction: TranscriptCorrection? {
        guard report.assessment.outcome == .instrumentalMusicCandidate, reference.valid else { return nil }
        return .init(kind: .musicOnly, text: nil, acoustic: reference)
    }
}

nonisolated struct SegmentAcousticReview: Sendable {
    let root: URL
    init(root: URL = AppSettings.supportDirectory.appendingPathComponent("AcousticReview", isDirectory: true)) {
        self.root = root
    }

    @concurrent func run(_ selection: SegmentCloudSelection) async throws -> SegmentAcousticCandidate {
        guard selection.endMs - selection.startMs >= 3_000 else {
            throw SessionError.invalid("Local sound analysis needs a passage of at least three seconds.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("recscribe-acoustic-\(UUID())")
        guard mkdir(temporary.path, 0o700) == 0 else { throw SessionError.invalid("Cannot prepare local sound analysis") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("passage.wav")
        try selection.copy(to: audio)
        let report = try LocalSoundClassifier.assess(audio) { try Task.checkCancellation() }
        try selection.validate()
        let bytes = try JSONEncoder().encode(report)
        guard bytes.count <= 1_024 * 1_024 else { throw SessionError.invalid("Local sound evidence exceeds its limit") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw SessionError.invalid("Local sound evidence storage is unavailable") }
        try Task.checkCancellation()
        let id = UUID(), evidence = root.appendingPathComponent(id.uuidString)
        guard mkdir(evidence.path, 0o700) == 0 else { throw SessionError.invalid("Cannot retain local sound evidence") }
        let selectionRecord: JSONValue = ["version": 1, "transcript_revision": .string(selection.revision),
            "segment_id": .string(selection.segmentID), "job": .string(selection.job.path),
            "start_ms": .integer(selection.startMs), "end_ms": .integer(selection.endMs),
            "channel": .integer(Int64(selection.channel)), "sample_rate": .integer(Int64(selection.sampleRate)),
            "first_frame": .integer(selection.firstFrame), "end_frame": .integer(selection.endFrame),
            "scope": "local_selected_channel_and_interval; no_upload; confirmation_required"]
        try selectionRecord.encoded().write(to: evidence.appendingPathComponent("selection.json"), options: .withoutOverwriting)
        try bytes.write(to: evidence.appendingPathComponent("report.json"), options: .withoutOverwriting)
        let reference = SegmentAcousticReference(id: id, classifier: report.classifier, startMs: selection.startMs,
            endMs: selection.endMs, channel: selection.channel, audioSHA256: report.sourceSHA256,
            reportSHA256: SegmentCloudRecognition.digest(bytes))
        return .init(selection: selection, report: report, reference: reference, evidence: evidence)
    }
}

/// One local passage at a time. Acoustic scores alone never overwrite words.
@MainActor @Observable
final class SegmentAcousticState {
    typealias Analyze = @Sendable (SegmentCloudSelection) async throws -> SegmentAcousticCandidate
    private(set) var result: SegmentAcousticCandidate?
    private(set) var busy = false
    private(set) var blocked = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let analyze: Analyze

    init(analyze: @escaping Analyze = { try await SegmentAcousticReview().run($0) }) { self.analyze = analyze }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        result = nil; busy = false; error = nil
    }
    func setBlocked(_ value: Bool) { blocked = value; if value { reset() } }

    func request(job: URL, document: TranscriptPreview, segmentID: String) {
        guard !blocked, !busy else { return }
        reset()
        let token = generation
        busy = true
        task = Task { [weak self, analyze] in
            defer { if self?.generation == token { self?.busy = false; self?.task = nil } }
            do {
                let selection = try await SegmentCloudSelection.prepare(job: job, document: document, segmentID: segmentID)
                let candidate = try await analyze(selection)
                try Task.checkCancellation()
                guard candidate.selection == selection, candidate.reference.valid,
                      candidate.reference.startMs == selection.startMs, candidate.reference.endMs == selection.endMs,
                      candidate.reference.channel == selection.channel,
                      candidate.reference.audioSHA256 == candidate.report.sourceSHA256 else {
                    throw SessionError.invalid("Local sound evidence no longer matches this passage")
                }
                guard let self, self.generation == token, !self.blocked else { return }
                self.result = candidate
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.error = error.localizedDescription } }
        }
    }

    func confirmMusicOnly(in review: TranscriptReviewState) {
        guard !blocked, !busy, !review.loading, !review.saving,
              let result, let correction = result.correction, let context = review.context else { return }
        guard context.job == result.selection.job, context.revision == result.selection.revision,
              review.corrections[result.selection.segmentID] == result.selection.baseline else {
            error = "This passage changed. Analyze it again before marking it as music only."
            return
        }
        let token = generation
        busy = true; error = nil
        task = Task { [weak self, weak review] in
            defer { if self?.generation == token { self?.busy = false; self?.task = nil } }
            do {
                try await result.selection.revalidate()
                try Task.checkCancellation()
                guard let self, self.generation == token, !self.blocked else { return }
                guard let review, review.context == context, !review.saving else {
                    throw SessionError.invalid("This passage changed while checking the sound result.")
                }
                review.setCorrection(correction, for: result.selection.segmentID)
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.error = error.localizedDescription } }
        }
    }

    deinit { task?.cancel() }
}
