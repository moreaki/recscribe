import Foundation
import Observation

/// One bounded save at a time. Only confirmed disk writes update the UI.
@MainActor @Observable
final class TranscriptReviewState {
    private(set) var checked: Set<String> = []
    private(set) var corrections: [String: TranscriptCorrection] = [:]
    private(set) var context: TranscriptReviewContext?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var error: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let store: TranscriptReviewStore

    init(store: TranscriptReviewStore = .shared) { self.store = store }

    func reset() {
        saveTask?.cancel(); saveTask = nil
        generation = UUID(); context = nil; checked = []; corrections = [:]
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
                }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.error = "Correction was not saved. " + error.localizedDescription }
            }
            if self?.generation == token { self?.saving = false; self?.saveTask = nil }
        }
    }
}
