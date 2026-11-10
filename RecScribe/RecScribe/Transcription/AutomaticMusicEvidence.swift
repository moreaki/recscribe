import Darwin
import Foundation
import RecScribeCore

/// Reversible automatic display suppression requires the complete current policy,
/// retained report and unchanged selected source files. No language is inferred.
nonisolated struct AutomaticMusicEvidence: Codable, Equatable, Sendable {
    static let policy = "soundanalysis-strong-music-v1"
    let policy: String
    let segmentID: String
    let revision: String
    let source: URL
    let manifestIdentity: SegmentCloudSelection.Identity?
    let parts: [SegmentCloudSelection.Part]
    let report: URL

    init(_ candidate: SegmentAcousticCandidate) {
        policy = Self.policy
        segmentID = candidate.selection.segmentID
        revision = candidate.selection.revision
        source = candidate.selection.source
        manifestIdentity = candidate.selection.manifestIdentity
        parts = candidate.selection.parts
        report = candidate.evidence.appendingPathComponent("report.json")
    }

    var valid: Bool {
        policy == Self.policy && !segmentID.isEmpty && segmentID.utf8.count <= 1_024
            && revision.count == 64 && revision.allSatisfy(\.isHexDigit)
            && source.isFileURL && report.isFileURL && !parts.isEmpty && parts.count <= 10_000
            && parts.allSatisfy { $0.url.isFileURL && $0.frames > 0 && $0.sourceFrames > 0 && $0.startFrame >= 0 }
    }

    static func permits(_ report: LocalSoundClassifier.Report) -> Bool {
        report.classifier == "SoundAnalysis.version1" && report.windowSeconds == 3
            && abs(report.overlap - 2.0 / 3.0) < 0.000_001
            && report.minimumMusicScore == MusicOnlyAssessment.minimumMusicScore
            && report.maximumVoiceScore == MusicOnlyAssessment.maximumVoiceScore
            && report.voiceGuardWindowSeconds == 1 && report.voiceGuardOverlap == 0.5
            && report.assessment.musicOnlyConfirmationAllowed
    }

    func validate(_ reference: SegmentAcousticReference) throws {
        try Task.checkCancellation()
        guard valid, reference.valid else { throw SessionError.invalid("Automatic music evidence is unsupported") }
        if let manifestIdentity, try SegmentCloudSelection.Identity.read(source) != manifestIdentity {
            throw SessionError.invalid("Automatic music source changed")
        }
        for part in parts {
            try Task.checkCancellation()
            guard try SegmentCloudSelection.Identity.read(part.url) == part.identity else {
                throw SessionError.invalid("Automatic music source changed")
            }
        }
        let fd = Darwin.open(report.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw SessionError.invalid("Automatic music report unavailable") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 1_024 * 1_024 else {
            throw SessionError.invalid("Automatic music report is not a bounded regular file")
        }
        let data = try file.read(upToCount: 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 1_024 * 1_024, SegmentCloudRecognition.digest(data) == reference.reportSHA256 else {
            throw SessionError.invalid("Automatic music report changed")
        }
        let decoded = try JSONDecoder().decode(LocalSoundClassifier.Report.self, from: data)
        guard Self.permits(decoded), decoded.sourceSHA256 == reference.audioSHA256,
              abs(decoded.assessment.duration - Double(reference.endMs - reference.startMs) / 1_000) < 0.001 else {
            throw SessionError.invalid("Automatic music evidence does not support suppression")
        }
        try Task.checkCancellation()
    }
}
