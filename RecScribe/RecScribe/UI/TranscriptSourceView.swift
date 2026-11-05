import AVKit
import SwiftUI

struct TranscriptSourceView: View {
    @Environment(SessionLibrary.self) private var library
    let source: URL
    let duration: Double?
    let detail: String
    let recording: Bool
    @Bindable var playback: SessionPlayback
    @Binding var pendingSeekSeconds: Double?
    @State private var loadedEntry: SessionEntry?
    @State private var error: String?
    @State private var wavDuration: Double?
    @State private var sourceAvailable = false
    private let sourceAvailabilityChanged: (Bool) -> Void

    private var entry: SessionEntry? {
        library.entries.first(where: { $0.id == source }) ?? loadedEntry
    }

    init(
        source: URL,
        duration: Double?,
        detail: String,
        recording: Bool,
        playback: SessionPlayback,
        pendingSeekSeconds: Binding<Double?> = .constant(nil),
        sourceAvailabilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.source = source
        self.duration = duration
        self.detail = detail
        self.recording = recording
        self.playback = playback
        self._pendingSeekSeconds = pendingSeekSeconds
        self.sourceAvailabilityChanged = sourceAvailabilityChanged
    }

    private var name: String {
        if let entry, entry.session.parts.count == 1 { return entry.session.parts[0].path }
        return source.lastPathComponent
    }

    private func startPlayback() {
        guard sourceAvailable, !library.isDeleting(source) else { return }
        if let entry {
            playback.play(entry)
        } else if source.pathExtension.lowercased() == "wav" {
            playback.playFile(source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.s) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(WorkspaceStyle.mint)
                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    if let entry {
                        SessionTitleView(entry: entry, library: library, allowsEditing: !recording) { updated in
                            if self.entry?.id == updated.id { self.loadedEntry = updated }
                        }
                        Text(name).font(.caption).foregroundStyle(.secondary).help(source.path)
                    } else {
                        Text(name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(source.path)
                    }
                    let seconds = duration ?? entry?.session.duration ?? wavDuration
                    Text([seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" }, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play", systemImage: "play.fill") {
                    startPlayback()
                }.disabled(library.isDeleting(source) || !sourceAvailable || recording || (source.pathExtension.lowercased() != "wav"
                    && (entry?.session.parts.isEmpty != false || entry?.session.parts.allSatisfy { $0.status == .verified } != true)))
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([source]) }.disabled(!sourceAvailable)
            }
            if playback.hasPresentation {
                SessionPlaybackView(playback: playback, showsSourceIdentity: false)
            }
            if let message = error { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: "\(source.path):\(recording)") {
            playback.stop(); loadedEntry = nil; error = nil; wavDuration = nil
            sourceAvailable = false
            sourceAvailabilityChanged(false)
            do {
                try await Task.detached(priority: .utility) { try TranscriptStorage.validateSource(source) }.value
                try Task.checkCancellation()
                if source.lastPathComponent.hasSuffix(".recscribe.json") {
                    let session = try await Task.detached(priority: .utility) { try RecordingSession.read(source) }.value
                    try Task.checkCancellation()
                    loadedEntry = SessionEntry(id: source, session: session)
                } else if duration == nil, source.pathExtension.lowercased() == "wav" {
                    let seconds = try await Task.detached(priority: .utility) {
                        let audio = try AVAudioFile(forReading: source)
                        return Double(audio.length) / audio.fileFormat.sampleRate
                    }.value
                    try Task.checkCancellation()
                    wavDuration = seconds
                }
                try Task.checkCancellation()
                sourceAvailable = true
                sourceAvailabilityChanged(true)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: library.deletionSources) { _, _ in if library.isDeleting(source) { playback.stop() } }
        .onChange(of: pendingSeekSeconds) { _, target in
            guard let target, !recording, !library.isDeleting(source) else { return }
            if playback.player != nil, playback.phase != .failed {
                playback.seek(to: target)
                pendingSeekSeconds = nil
            } else if entry != nil || source.pathExtension.lowercased() == "wav" {
                startPlayback()
            }
        }
        .onChange(of: playback.player != nil) { _, hasPlayer in
            if hasPlayer, let target = pendingSeekSeconds {
                playback.seek(to: target)
                pendingSeekSeconds = nil
            }
        }
        .onChange(of: recording) { _, active in playback.setRecording(active) }
        .onDisappear { playback.stop() }
    }
}
