import Darwin
import Foundation
import Observation

nonisolated struct LiveDraftInventory: Sendable {
    struct Entry: Identifiable, Sendable {
        var id: URL { url }
        let url: URL
        let bytes: Int64
        let modified: Date
        let containsRecording: Bool
    }
    var entries: [Entry] = []
    var bytes: Int64 = 0
    var incomplete = false
    var errors: [String] = []
}

/// Metadata only: never loads audio, transcripts or raw recognizer output.
nonisolated enum LiveDraftStorage {
    static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024
    static let maximumDrafts = 100
    static let maximumEntries = 20_000

    static func scan(_ root: URL, cancel: WorkCancellation, maximumEntries: Int = maximumEntries, only selected: URL? = nil) throws -> LiveDraftInventory {
        var inventory = LiveDraftInventory(), visited = 0
        func info(_ url: URL) throws -> stat? {
            try cancel.check()
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard value.st_uid == getuid(), value.st_mode & S_IFMT != S_IFLNK else {
                throw SessionError.invalid("Live draft contains a link or belongs to another user")
            }
            return value
        }
        func children(_ url: URL, visit: (URL) throws -> Void) throws {
            guard let directory = opendir(url.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { closedir(directory) }
            while true {
                try cancel.check()
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                guard visited < maximumEntries else { inventory.incomplete = true; return }
                visited += 1
                try visit(url.appendingPathComponent(name))
            }
        }
        func size(_ url: URL, depth: Int, recording: inout Bool) throws -> Int64 {
            guard depth <= 8 else { inventory.incomplete = true; return 0 }
            guard let value = try info(url) else { return 0 }
            if value.st_mode & S_IFMT == S_IFREG {
                if url.lastPathComponent.hasSuffix(".recscribe.json") { recording = true }
                return max(0, value.st_size)
            }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw SessionError.invalid("Unexpected live draft file type") }
            var bytes: Int64 = 0
            try children(url) {
                let addition = bytes.addingReportingOverflow(try size($0, depth: depth + 1, recording: &recording))
                if addition.overflow { inventory.incomplete = true; bytes = Int64.max }
                else { bytes = addition.partialValue }
            }
            return bytes
        }
        guard let rootInfo = try info(root) else { return inventory }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw SessionError.invalid("Live storage is not a directory") }
        func inspect(_ draft: URL) throws {
            guard UUID(uuidString: draft.lastPathComponent) != nil else { return }
            guard inventory.entries.count < 256 else { inventory.incomplete = true; return }
            do {
                guard let value = try info(draft), value.st_mode & S_IFMT == S_IFDIR else { return }
                var recording = false
                let bytes = try size(draft, depth: 0, recording: &recording)
                let total = inventory.bytes.addingReportingOverflow(bytes)
                if total.overflow { inventory.incomplete = true; inventory.bytes = Int64.max }
                else { inventory.bytes = total.partialValue }
                inventory.entries.append(.init(url: draft, bytes: bytes,
                    modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec)), containsRecording: recording))
            } catch is CancellationError { throw CancellationError() }
            catch { inventory.incomplete = true; if inventory.errors.count < 10 { inventory.errors.append(error.localizedDescription) } }
        }
        if let selected {
            guard managed(selected, in: root) else { throw SessionError.invalid("Not a managed live draft") }
            try inspect(selected)
        } else { try children(root, visit: inspect) }
        inventory.entries.sort { $0.modified < $1.modified }
        return inventory
    }

    static func permits(_ inventory: LiveDraftInventory, draft: URL, maximumBytes: Int64 = maximumBytes,
                        maximumDrafts: Int = maximumDrafts) -> Bool {
        !inventory.incomplete && inventory.bytes < maximumBytes &&
            (inventory.entries.count < maximumDrafts || inventory.entries.contains { $0.url.standardizedFileURL.path == draft.standardizedFileURL.path })
    }

    static func lease(_ draft: URL, in root: URL) throws -> LiveDraftLease {
        guard managed(draft, in: root) else { throw SessionError.invalid("Not a managed live draft") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid() else {
            throw SessionError.invalid("Live storage is not an owned directory")
        }
        if lstat(draft.path, &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid() else { throw SessionError.invalid("Live draft is not an owned directory") }
        } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try lockExistingRoot(root)
    }

    static func lockExistingRoot(_ root: URL) throws -> LiveDraftLease {
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid() else {
            throw SessionError.invalid("Live storage is not an owned directory")
        }
        return try LiveDraftLease(root)
    }

    static func managed(_ draft: URL, in root: URL) -> Bool {
        UUID(uuidString: draft.lastPathComponent) != nil && draft.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
    }
}

/// Immutable descriptor ownership can cross to the worker; closing releases flock.
nonisolated final class LiveDraftLease: @unchecked Sendable {
    private let fd: Int32
    init(_ root: URL) throws {
        fd = Darwin.open(root.appendingPathComponent(".live-storage.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw SessionError.invalid("Live storage lease is not an owned regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
    deinit { Darwin.close(fd) }
}

@MainActor
@Observable final class LiveDraftStore {
    let root: URL
    private(set) var inventory = LiveDraftInventory()
    private(set) var busy = false
    private(set) var errorMessage: String?
    var onRemoved: (URL) -> Void = { _ in }
    var canManage: () -> Bool = { true }
    private let isActive: @Sendable (URL) -> Bool
    private let gate: CaptureSessionGate
    private let owner = UUID()
    private var scanTask: Task<LiveDraftInventory, Error>?

    init(root: URL, gate: CaptureSessionGate = CaptureSessionGate(), isActive: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        self.root = root; self.gate = gate; self.isActive = isActive
    }

    func isProtected(_ entry: LiveDraftInventory.Entry) -> Bool { entry.containsRecording || isActive(entry.url) }

    private func scan(cancel: WorkCancellation) async throws -> LiveDraftInventory {
        if let scanTask { return try await scanTask.value }
        let root = root
        let task = Task.detached(priority: .utility) { try LiveDraftStorage.scan(root, cancel: cancel) }
        scanTask = task
        defer { scanTask = nil }
        let result = try await task.value
        try cancel.check()
        inventory = result
        return result
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let cancel = WorkCancellation()
        await withTaskCancellationHandler {
            do { _ = try await scan(cancel: cancel); errorMessage = nil }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        } onCancel: { cancel.cancel() }
    }

    func checkBudget(_ draft: URL, cancel: WorkCancellation) async throws {
        let snapshot = try await scan(cancel: cancel)
        guard LiveDraftStorage.permits(snapshot, draft: draft) else {
            throw SessionError.invalid("Live draft storage reached its 1 GiB / 100 draft limit, or could not be fully inspected. Recording continues. Review live drafts in Settings → Storage and move unwanted drafts to Trash.")
        }
    }

    func admit(_ draft: URL, cancel: WorkCancellation) async throws -> LiveDraftLease {
        try await checkBudget(draft, cancel: cancel)
        let root = root
        return try await Task.detached(priority: .utility) {
            try cancel.check()
            return try LiveDraftStorage.lease(draft, in: root)
        }.value
    }

    @discardableResult
    func trash(_ entry: LiveDraftInventory.Entry,
               move: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async -> Bool {
        guard !busy, canManage(), !isProtected(entry) else { return false }
        do { try gate.acquire(owner) } catch { errorMessage = "Wait for recording or audio testing to finish."; return false }
        busy = true
        defer { busy = false; gate.release(owner) }
        let root = root, isActive = isActive, cancel = WorkCancellation()
        do {
            let worker = Task.detached(priority: .utility) {
                guard LiveDraftStorage.managed(entry.url, in: root) else { throw SessionError.invalid("Not a managed live draft") }
                let lease = try LiveDraftStorage.lease(entry.url, in: root)
                defer { withExtendedLifetime(lease) {} }
                let snapshot = try LiveDraftStorage.scan(root, cancel: cancel, only: entry.url)
                guard !snapshot.incomplete, let current = snapshot.entries.first(where: { $0.url.standardizedFileURL.path == entry.url.standardizedFileURL.path }),
                      !current.containsRecording, !isActive(entry.url) else { throw SessionError.invalid("Draft is active, contains a recording, or cannot be safely inspected") }
                guard !isActive(entry.url) else { throw SessionError.invalid("Draft became active") }
                try cancel.check()
                try move(entry.url)
            }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { cancel.cancel() }
            onRemoved(entry.url)
            do { inventory = try await scan(cancel: cancel); errorMessage = nil }
            catch { errorMessage = "Draft moved to Trash; refresh storage to check the remaining drafts." }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
