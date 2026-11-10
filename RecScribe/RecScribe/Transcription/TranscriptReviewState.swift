import Foundation
import Observation
import RecScribeCore

/// One bounded save at a time. Only confirmed disk writes update the UI.
@MainActor @Observable
final class TranscriptReviewState {
    private(set) var checked: Set<String> = []
    private(set) var corrections: [String: TranscriptCorrection] = [:]
    private(set) var context: TranscriptReviewContext?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var error: String?
    private(set) var automaticBusy = false
    private(set) var automaticNotice: String?
    private(set) var automaticRemaining = 0
    private(set) var automaticDismissals: Set<String> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var automaticGeneration = UUID()
    private var automaticVisited: Set<String> = []
    private var automaticBlocked = false
    typealias AutomaticAnalyze = @Sendable (SegmentCloudSelection, ContinuousClock.Instant) async throws -> SegmentAcousticCandidate
    private let automaticAnalyze: AutomaticAnalyze
    private let store: TranscriptReviewStore

    init(store: TranscriptReviewStore = .shared,
         automaticAnalyze: @escaping AutomaticAnalyze = { try await SegmentAcousticReview().run($0, deadline: $1, automatic: true) }) {
        self.store = store; self.automaticAnalyze = automaticAnalyze
    }

    func reset() {
        stopAutomatic()
        saveTask?.cancel(); saveTask = nil
        generation = UUID(); context = nil; checked = []; corrections = [:]
        automaticDismissals = []; automaticVisited = []; automaticRemaining = 0; automaticNotice = nil
        loading = false; saving = false; error = nil
    }

    func load(job: URL, document: TranscriptPreview) async {
        reset()
        let token = generation
        loading = true
        defer { if generation == token { loading = false } }
        do {
            var context = try TranscriptReviewContext(job: job, document: document)
            let snapshot = try await store.loadSnapshot(context)
            try Task.checkCancellation()
            guard generation == token else { return }
            context.corrections = snapshot.corrections
            self.context = context; self.checked = snapshot.checked; self.corrections = snapshot.corrections
            self.automaticDismissals = snapshot.automaticDismissals
        } catch is CancellationError { }
        catch {
            if generation == token && !Task.isCancelled { self.error = "Could not load review status. " + error.localizedDescription }
        }
    }

    func setChecked(_ item: TranscriptReading.ReviewItem, checked: Bool) {
        guard let context, context.keys.contains(item.key), !loading, !saving else { return }
        let token = generation
        saving = true; error = nil
        saveTask = Task { [weak self, store] in
            do {
                let result = try await store.setChecked(item.key, checked: checked, in: context)
                try Task.checkCancellation()
                if self?.generation == token { self?.checked = result }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.error = "Review change was not saved. " + error.localizedDescription }
            }
            if self?.generation == token { self?.saving = false; self?.saveTask = nil }
        }
    }

    func setCorrection(_ correction: TranscriptCorrection?, for segmentID: String) {
        stopAutomatic()
        guard let context, context.segmentIDs.contains(segmentID), !loading, !saving else { return }
        let token = generation
        saving = true; error = nil
        saveTask = Task { [weak self, store] in
            do {
                let result = try await store.setCorrection(correction, for: segmentID, in: context)
                try Task.checkCancellation()
                if self?.generation == token {
                    var nextContext = context
                    nextContext.corrections = result.corrections
                    self?.context = nextContext
                    self?.checked = result.checked; self?.corrections = result.corrections
                    self?.automaticDismissals = result.automaticDismissals
                }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.error = "Correction was not saved. " + error.localizedDescription }
            }
            if self?.generation == token { self?.saving = false; self?.saveTask = nil }
        }
    }

    func setAutomaticBlocked(_ blocked: Bool) {
        automaticBlocked = blocked
        if blocked { stopAutomatic() }
    }

    func stopAutomatic() {
        automaticGeneration = UUID()
        automaticTask?.cancel(); automaticTask = nil
        if automaticBusy { automaticNotice = "Music check stopped. Remaining recognition is kept." }
        automaticBusy = false
    }

    /// One utility analysis at a time; each activation is bounded by 32 passages,
    /// two minutes of selected audio and 30 cooperative seconds. Resuming is explicit.
    func suppressMusicAutomatically(in document: TranscriptPreview) {
        guard !automaticBlocked, !automaticBusy, !loading, !saving, let context,
              context.revision == document.revision, document.source != nil else { return }
        let pending = document.segments.filter { segment in
            guard let start = segment.startMs, let end = segment.endMs, start >= 0, end > start,
                  end <= document.source!.durationMs else { return false }
            return (3_000...120_000).contains(end - start)
                && corrections[segment.id] == nil && !automaticDismissals.contains(segment.id)
                && !automaticVisited.contains(segment.id)
                && (context.reviewKeysBySegment[segment.id].map { !checked.contains($0) } ?? true)
        }
        automaticRemaining = pending.count
        guard !pending.isEmpty else { automaticNotice = nil; return }
        let token = automaticGeneration, revisionToken = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        automaticBusy = true; automaticNotice = "Checking music-only passages locally…"
        automaticTask = Task { [weak self, automaticAnalyze, store] in
            var duration: Int64 = 0, attempts = 0, failures = 0
            for segment in pending {
                guard let self, self.automaticGeneration == token, self.generation == revisionToken,
                      !Task.isCancelled, !self.automaticBlocked, ContinuousClock.now < deadline else { break }
                let milliseconds = segment.endMs! - segment.startMs!
                guard attempts < 32, duration + milliseconds <= 120_000 else { break }
                attempts += 1; duration += milliseconds
                do {
                    if self.corrections[segment.id] == nil && !self.automaticDismissals.contains(segment.id) {
                        let selection = try await SegmentCloudSelection.prepare(job: context.job,
                            document: document.applying(self.corrections), segmentID: segment.id)
                        let candidate = try await automaticAnalyze(selection, deadline)
                        try Task.checkCancellation()
                        guard self.automaticGeneration == token, self.generation == revisionToken,
                              !self.automaticBlocked, ContinuousClock.now < deadline else { break }
                        if AutomaticMusicEvidence.permits(candidate.report), !self.saving,
                           let current = self.context {
                            self.saving = true
                            do {
                                let snapshot = try await store.suppressAutomatically(candidate, in: current)
                                try Task.checkCancellation()
                                if self.generation == revisionToken {
                                    var updated = current; updated.corrections = snapshot.corrections
                                    self.context = updated; self.corrections = snapshot.corrections
                                    self.checked = snapshot.checked; self.automaticDismissals = snapshot.automaticDismissals
                                }
                            } catch {
                                if self.generation == revisionToken { self.saving = false }
                                throw error
                            }
                            if self.generation == revisionToken { self.saving = false }
                        }
                    }
                } catch is CancellationError { break }
                catch { failures += 1 } // Any missing/failed evidence keeps recognition.
                guard self.automaticGeneration == token else { break }
                self.automaticVisited.insert(segment.id)
                self.automaticRemaining -= 1
            }
            guard let self, self.automaticGeneration == token, self.generation == revisionToken else { return }
            self.automaticBusy = false; self.automaticTask = nil
            self.automaticNotice = self.automaticRemaining > 0
                ? "Music check paused · \(self.automaticRemaining) passages remain. Recognition is kept until checked."
                : failures > 0 ? "Music check finished · \(failures) passages could not be checked. Their recognition is kept."
                : "Music check finished. Uncertain passages keep their recognition."
        }
    }
}
