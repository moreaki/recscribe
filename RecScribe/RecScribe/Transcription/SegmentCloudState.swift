import Foundation
import Observation

/// One selection, one approval, one attempt. Late work cannot replace another passage.
@MainActor @Observable
final class SegmentCloudState {
    typealias Prepare = @Sendable (URL, TranscriptPreview, String) async throws -> SegmentCloudSelection
    typealias Recognize = @Sendable (SegmentCloudSelection, Data, Date) async throws -> SegmentCloudCandidate
    private(set) var pending: SegmentCloudSelection?
    private(set) var result: SegmentCloudCandidate?
    private(set) var preparing = false
    private(set) var busy = false
    private(set) var blocked = false
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let readKey: @MainActor () throws -> Data
    private let prepare: Prepare
    private let recognize: Recognize

    init(readKey: @escaping @MainActor () throws -> Data = { try IntelligenceCredentials().key() },
         prepare: @escaping Prepare = { try await SegmentCloudSelection.prepare(job: $0, document: $1, segmentID: $2) },
         recognize: @escaping Recognize = { try await SegmentCloudRecognition().run($0, key: $1, approvedAt: $2) }) {
        self.readKey = readKey; self.prepare = prepare; self.recognize = recognize
    }

    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        pending = nil; result = nil; preparing = false; busy = false; error = nil; notice = nil
    }

    func setBlocked(_ value: Bool) {
        blocked = value
        if value { reset() }
    }

    func cancel() {
        let uploading = busy
        reset()
        notice = "Cloud re-recognition cancelled." + (uploading ? " Audio already uploaded cannot be recalled." : "")
    }

    func dismissApproval() { pending = nil }

    func request(job: URL, document: TranscriptPreview, segmentID: String) {
        guard !blocked, !busy, !preparing, pending == nil else { return }
        reset()
        let token = generation
        preparing = true
        task = Task { [weak self, prepare] in
            do {
                let selection = try await prepare(job, document, segmentID)
                try Task.checkCancellation()
                guard let self, self.generation == token, !self.blocked else { return }
                self.pending = selection
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.error = error.localizedDescription } }
            if self?.generation == token { self?.preparing = false; self?.task = nil }
        }
    }

    func approve() {
        guard !blocked, !busy, !preparing, let selection = pending else { return }
        pending = nil // Approval is consumed even if credentials or the request fail.
        let key: Data
        do { key = try readKey() }
        catch { self.error = error.localizedDescription; return }
        let token = generation, approvedAt = Date()
        busy = true; error = nil; notice = nil
        task = Task { [weak self, recognize] in
            do {
                let candidate = try await recognize(selection, key, approvedAt)
                try Task.checkCancellation()
                guard candidate.selection == selection, candidate.reference.valid,
                      candidate.reference.startMs == selection.startMs, candidate.reference.endMs == selection.endMs,
                      candidate.reference.channel == selection.channel else {
                    throw SessionError.invalid("Cloud response no longer matches this passage")
                }
                guard let self, self.generation == token, !self.blocked else { return }
                self.result = candidate
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.error = error.localizedDescription } }
            if self?.generation == token { self?.busy = false; self?.task = nil }
        }
    }

    func apply(to review: TranscriptReviewState) {
        guard !blocked, !busy, !preparing, !review.loading, !review.saving,
              let result, let correction = result.correction, correction.valid else { return }
        guard let context = review.context, context.job == result.selection.job, context.revision == result.selection.revision,
              review.corrections[result.selection.segmentID] == result.selection.baseline else {
            error = "This passage was edited or changed. Request new recognition before replacing it."
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
                    throw SessionError.invalid("This passage changed while checking the result. Review it before applying recognition.")
                }
                review.setCorrection(correction, for: result.selection.segmentID)
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.error = error.localizedDescription } }
        }
    }

    deinit { task?.cancel() }
}
