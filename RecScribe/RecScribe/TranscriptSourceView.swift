import AVKit
import SwiftUI

struct TranscriptSourceView: View {
    let source: URL
    let duration: Double?
    let detail: String
    let recording: Bool
    @StateObject private var playback = SessionPlayback()
    @State private var entry: SessionEntry?
    @State private var error: String?
    @State private var wavDuration: Double?
    private var name: String {
        if let entry, entry.session.parts.count == 1 { return entry.session.parts[0].path }
        return source.lastPathComponent
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
                    if let entry { playback.play(entry) }
                    else if source.pathExtension.lowercased() == "wav" { NSWorkspace.shared.open(source) }
                }.disabled(recording || (source.pathExtension.lowercased() != "wav" && entry == nil))
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
            }
            if playback.loading { ProgressView("Loading audio…").controlSize(.small) }
            if let player = playback.player {
                VideoPlayer(player: player).frame(height: GlassTheme.standard.metrics.controlHeightLarge * 2)
                Button("Stop playback") { playback.stop() }
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
        .onChange(of: recording) { _, active in playback.setRecording(active) }
        .onDisappear { playback.stop() }
    }
}
