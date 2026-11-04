import AVKit
import SwiftUI

struct TranscriptSourceView: View {
    let source: URL
    let duration: Double?
    let detail: String
    let recording: Bool
    @ObservedObject var playback: SessionPlayback
    @Binding var pendingSeekSeconds: Double?
    @State private var entry: SessionEntry?
    @State private var error: String?
    @State private var wavDuration: Double?

    init(
        source: URL,
        duration: Double?,
        detail: String,
        recording: Bool,
        playback: SessionPlayback,
        pendingSeekSeconds: Binding<Double?> = .constant(nil)
    ) {
        self.source = source
        self.duration = duration
        self.detail = detail
        self.recording = recording
        self.playback = playback
        self._pendingSeekSeconds = pendingSeekSeconds
    }

    private var name: String {
        if let entry, entry.session.parts.count == 1 { return entry.session.parts[0].path }
        return source.lastPathComponent
    }

    private func startPlayback() {
        if let entry {
            playback.play(entry)
        } else if source.pathExtension.lowercased() == "wav" {
            playback.playFile(source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.s) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(WorkspaceStyle.mint)
                VStack(alignment: .leading, spacing: GlassSpacing.xxs) {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(source.path)
                    let seconds = duration ?? entry?.session.duration ?? wavDuration
                    Text([seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" }, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play", systemImage: "play.fill") {
                    startPlayback()
                }.disabled(recording || (source.pathExtension.lowercased() != "wav" && entry == nil))
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
            }
            if playback.loading { ProgressView("Loading audio…").controlSize(.small) }
            if playback.player != nil {
                SessionPlaybackView(playback: playback)
            }
            if let message = error ?? playback.errorMessage { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: "\(source.path):\(recording)") {
            playback.stop(); entry = nil; error = nil; wavDuration = nil
            do {
                if source.lastPathComponent.hasSuffix(".recscribe.json") {
                    let session = try await Task.detached(priority: .utility) { try RecordingSession.read(source) }.value
                    try Task.checkCancellation()
                    entry = SessionEntry(id: source, session: session)
                } else if duration == nil, source.pathExtension.lowercased() == "wav" {
                    let seconds = try await Task.detached(priority: .utility) {
                        let audio = try AVAudioFile(forReading: source)
                        return Double(audio.length) / audio.fileFormat.sampleRate
                    }.value
                    try Task.checkCancellation()
                    wavDuration = seconds
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: pendingSeekSeconds) { _, target in
            guard let target, !recording else { return }
            if playback.player != nil {
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
