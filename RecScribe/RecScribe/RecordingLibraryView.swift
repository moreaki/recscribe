import AVKit
import SwiftUI

struct RecordingLibraryView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @ObservedObject private var library = SessionLibrary.shared
    @State private var player: AVPlayer?
    @State private var playing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Your recordings").font(.title2.bold())
                    Text("One session. Every part. A continuous timeline.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import WAV / session…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { library.transcribe(url) }
                }.disabled(library.recordingActive)
                Button("Refresh") { reload() }
            }
            if let player { VideoPlayer(player: player).frame(height: 80) }
            List(library.entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.purple)
                        Text(entry.id.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")).font(.headline)
                        Spacer()
                        Text(entry.session.status == "recording" && !library.recordingActive ? "Not finalized — verify / recover" : entry.session.status.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(entry.session.parts.count) parts · \(entry.session.duration.formatted(.number.precision(.fractionLength(1)))) s · \(entry.session.channels) channels · \(entry.session.sampleRate) Hz PCM")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(playing == entry.session.id ? "Restart" : "Play session") { Task { await play(entry) } }
                        Button("Transcribe") { library.transcribe(entry.id) }
                        Button("Verify / Recover") { library.enqueue(entry.id, recover: true) }
                        Button("Export…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                Task { do { let result = try await library.export(entry.id, to: url); NSWorkspace.shared.activateFileViewerSelecting([result]) }
                                    catch is CancellationError { /* Cancellation is shown by the library, not an error alert. */ }
                                    catch { library.errorMessage = error.localizedDescription } }
                            }
                        }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                    }.buttonStyle(.borderless).disabled(library.recordingActive)
                    ForEach(entry.session.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 8)
            }.listStyle(.inset).overlay {
                if library.entries.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "waveform", description: Text("New recordings appear here. Existing WAV files can be imported for optional transcription.")) }
            }
            HStack {
                ProgressView(value: library.progress).frame(width: 120)
                Text(library.activity).font(.caption)
                Spacer()
                if let job = library.latestJob { Button("Job artifacts") { NSWorkspace.shared.activateFileViewerSelecting([job]) } }
                Button("Cancel work") { library.cancel() }
            }
            if let error = library.errorMessage { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
        }.padding(24).frame(minWidth: 780, minHeight: 500)
            .background(GlassWindowGround()).glassThemeAdaptingToContrast().onAppear { reload() }
            .onDisappear { player?.pause() }
            .onChange(of: library.recordingActive) { _, active in if active { player?.pause() } }
    }
    private func reload() { library.load(URL(fileURLWithPath: recorder.saveLocationPath)) }
    private func play(_ entry: SessionLibrary.Entry) async {
        do {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            for part in entry.session.parts {
                guard part.status == "verified" else { throw SessionError.invalid("Verify all parts before playback") }
                let asset = AVURLAsset(url: try RecordingSession.safeURL(part.path, beside: entry.id))
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw SessionError.invalid("Missing audio track") }
                let rate = Int32(entry.session.sampleRate)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: part.frames, timescale: rate)),
                                          of: source, at: CMTime(value: part.startSample, timescale: rate))
            }
            guard !library.recordingActive else { return }
            player?.pause(); player = AVPlayer(playerItem: AVPlayerItem(asset: composition)); playing = entry.session.id; player?.play()
        } catch { library.errorMessage = error.localizedDescription }
    }
}
