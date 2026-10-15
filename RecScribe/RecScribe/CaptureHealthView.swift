import SwiftUI

struct CaptureHealthView: View {
    @ObservedObject var recorder: RecorderViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.sm) {
            Text(recorder.captureSourceHint).font(.caption).foregroundStyle(.secondary)
            if recorder.isRecording {
                ForEach(recorder.sourceHealth) { source in
                    let status = source.health.status(at: recorder.healthTime)
                    VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                        Text("\(source.name): \(status.label)")
                            .foregroundStyle([.noData, .stalled, .writeStalled, .failed].contains(status) ? Color.orange : Color.secondary)
                        if let rate = source.health.sampleRate, let channels = source.health.channels {
                            Text("\(channels) input channels · \(rate.formatted(.number.precision(.fractionLength(0)))) Hz · \(source.health.peak >= 1 ? "clipping" : "peak " + String(format: "%.1f dBFS", 20 * log10(max(0.000_001, source.health.peak))))")
                                .foregroundStyle(.secondary)
                            if let post = source.health.postPeak {
                                Text(String(format: "After fader: %.1f dBFS · saved mix: %.1f dBFS", 20 * log10(max(0.000_001, post)), 20 * log10(max(0.000_001, source.health.mixPeak ?? post))))
                                    .foregroundStyle(source.health.clipped ? Color.orange : Color.secondary)
                                if source.health.clipped { Text("Clipping detected · reduce recording gain").foregroundStyle(.orange) }
                            }
                            ProgressView(value: Double(min(1, source.health.peak))).accessibilityLabel("\(source.name) level")
                        }
                        Text("\(source.health.receivedFrames) frames received · \(source.health.writtenFrames) written")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.font(.caption).help(source.detail ?? source.name).accessibilityElement(children: .combine)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
