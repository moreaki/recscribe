import SwiftUI

struct AudioTestControls: View {
    @ObservedObject var test: AudioTestController
    var enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { status; Spacer(); actions }
                VStack(alignment: .leading, spacing: 8) { status; actions }
            }
            if test.state == .idle && enabled {
                Text("Test audio uses live sources without saving. A fresh sample records up to 10 seconds; capture and monitoring stop before playback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let sample = test.sample {
                Text("\(String(format: "%.1f", sample.entry.session.duration)) s sample · \(sample.sources.joined(separator: " + "))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Temporary · Keep sample saves it to your recording folder. Discarded when this window closes. New gain changes apply to your next take.")
                    .font(.caption2).foregroundStyle(.secondary)
                if !sample.warnings.isEmpty {
                    DisclosureGroup {
                        ForEach(Array(sample.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption2) }
                    } label: {
                        Label("Sample needs review · check source coverage and clipping", systemImage: "exclamationmark.triangle")
                    }.font(.caption).foregroundStyle(.orange)
                }
                SessionPlaybackView(playback: test.playback, showListeningControls: false)
                AudioTestPlaybackError(playback: test.playback)
            }
            if let error = test.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let notice = test.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(WorkspaceStyle.mint.opacity(test.isCapturing ? 0.06 : 0))
    }

    private var status: some View {
        Label {
            switch test.state {
            case .testing: Text("Testing audio · preview only")
            case .sampling: Text(String(format: "Recording test sample · %.1f / 10 s", min(10, test.elapsed)))
            case .starting: Text("Starting audio test…")
            case .stopping: Text("Stopping capture…")
            case .verifying: Text("Verifying sample and source tracks…")
            case .ready: Text(enabled ? "Sample ready · capture is stopped" : "Sample ready · playback waits for recording to finish")
            case .keeping: Text("Saving sample…")
            case .idle: Text(enabled ? "Check your sound before recording" : "Audio testing is unavailable while recording or finishing a take")
            }
        } icon: {
            Image(systemName: test.isCapturing ? "waveform.circle.fill" : "waveform.circle")
        }.font(.callout.weight(.medium)).foregroundStyle(test.isCapturing ? WorkspaceStyle.mint : Color.primary)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch test.state {
            case .idle:
                Button("Test audio", systemImage: "waveform") { Task { await test.startPreview() } }.disabled(!enabled)
                Button("Record 10-second sample", systemImage: "record.circle") { Task { await test.recordSample() } }.disabled(!enabled)
            case .testing:
                Button("Stop test", systemImage: "stop.fill") { Task { await test.stop() } }
                Button("Record 10-second sample", systemImage: "record.circle") { Task { await test.recordSample() } }
            case .sampling:
                Button("Stop sample", systemImage: "stop.fill") { Task { await test.stop() } }
            case .starting:
                ProgressView().controlSize(.small)
                Button("Cancel") { Task { await test.stop() } }
            case .stopping, .verifying, .keeping:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Play sample", systemImage: "play.fill") { test.playSample() }.disabled(!enabled)
                Button("Keep sample", systemImage: "square.and.arrow.down") { Task { await test.keepSample() } }.disabled(!enabled)
                Button("Discard", role: .destructive) { test.discard() }.disabled(!enabled)
            }
        }.controlSize(.small)
    }
}

private struct AudioTestPlaybackError: View {
    @ObservedObject var playback: SessionPlayback
    var body: some View {
        if playback.loading { Text("Loading verified sample…").font(.caption) }
        if let error = playback.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}

struct AudioTestSourceMeterView: View {
    @ObservedObject var test: AudioTestController
    let track: CaptureTrack
    var muted: Bool
    var channels = false

    var body: some View {
        if !test.health.isEmpty {
            let meter = test.meters[track] ?? .init()
            VStack(alignment: .leading, spacing: 5) {
                if channels {
                    ForEach(meter.raw.peaks.indices, id: \.self) { channel in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Channel \(channel + 1)").font(.caption2).foregroundStyle(.secondary)
                            AudioPeakBar(title: "Before gain", meter: meter.raw, now: test.now, channel: channel)
                            AudioPeakBar(title: "Routed after gain", meter: meter.processed, now: test.now, channel: channel)
                        }
                    }
                } else {
                    AudioPeakBar(title: "Before gain", meter: meter.raw, now: test.now)
                    AudioPeakBar(title: muted ? "Muted contribution" : "Routed after gain", meter: meter.processed, now: test.now)
                    if let item = test.health.first(where: { $0.id == track.rawValue }) {
                        let status = item.health.status(at: test.now)
                        Text(test.isCapturing ? label(status) : item.health.receivedFrames == 0 ? "No data captured in this test" : "Test stopped · last levels and held peaks")
                            .font(.caption2)
                            .foregroundStyle([.noData, .stalled, .failed, .writeStalled].contains(status) ? Color.orange : Color.secondary)
                        if let failure = item.health.failureMessage { Text(failure).font(.caption2).foregroundStyle(.orange) }
                    }
                    if meter.raw.hold.contains(where: { $0 >= 1 }) { Text("Input reached full scale · check hardware level").font(.caption2).foregroundStyle(.orange) }
                    if meter.processed.hold.contains(where: { $0 > 1 }) { Text("Gain exceeded 0 dBFS · reduce gain").font(.caption2).foregroundStyle(.orange) }
                }
            }.padding(.bottom, channels ? 0 : 10)
        }
    }
    private func label(_ status: RecordingHealth.Status) -> String {
        switch status {
        case .waiting: "Waiting for source data"
        case .noData: "No data · check source and permissions"
        case .audio: test.state == .sampling ? "Receiving signal · test sample" : "Receiving signal · preview"
        case .silence: "Source is delivering silence"
        case .stalled: "Source data stopped"
        case .writing: "Receiving data · aligning audio"
        case .writeStalled: "Audio processing stalled"
        case .failed: "Source failed · coverage incomplete"
        }
    }
}

struct AudioTestMixMeterView: View {
    @ObservedObject var test: AudioTestController
    var body: some View {
        if !test.health.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                AudioPeakBar(title: "Mix L", meter: test.mixMeter, now: test.now, channel: 0)
                AudioPeakBar(title: "Mix R", meter: test.mixMeter, now: test.now, channel: 1)
                if test.mixMeter.hold.contains(where: { $0 > 1 }) {
                    Text("Mix clipped · reduce master or source gain").foregroundStyle(.orange)
                } else if test.mixMeter.peaks.isEmpty {
                    Text("Waiting for aligned mix data").foregroundStyle(.secondary)
                } else if test.mixMeter.current(at: test.now).max() ?? 0 < 0.0001 {
                    Text("Mix is silent · check mute, routes and source data").foregroundStyle(.orange)
                }
                Text("Peak markers hold until the next test. Output volume affects listening only.").foregroundStyle(.secondary)
            }.font(.caption2).padding(.bottom, 10)
        }
    }
}

private struct AudioPeakBar: View {
    let title: String
    let meter: CapturePeakMeter
    let now: TimeInterval
    var channel: Int?
    private func value(_ values: [Float]) -> Float {
        if let channel { return values.indices.contains(channel) ? values[channel] : 0 }
        return values.max() ?? 0
    }
    private func fraction(_ value: Float) -> Double { max(0, min(1, (20 * log10(Double(max(0.000001, value))) + 60) / 60)) }
    private func decibels(_ value: Float) -> String { value > 0.000001 ? String(format: "%.1f dBFS", 20 * log10(value)) : "−∞ dBFS" }
    var body: some View {
        let peak = value(meter.current(at: now)), hold = value(meter.hold)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text(decibels(peak)).monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(peak > 1 ? Color.red : peak > 0.8 ? Color.orange : WorkspaceStyle.mint)
                        .frame(width: geometry.size.width * fraction(peak))
                    Rectangle().fill(hold > 1 ? Color.orange : Color.primary.opacity(0.8)).frame(width: 1)
                        .offset(x: max(0, (geometry.size.width - 1) * fraction(hold)))
                }
            }.frame(height: 5)
        }.accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue("\(decibels(peak)), held peak \(decibels(hold))")
    }
}
