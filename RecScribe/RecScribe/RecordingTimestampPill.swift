import SwiftUI

/// Recording metadata, independent of the filename or the file's modification time.
struct RecordingTimestampPill: View {
    let date: Date
    var tint: Color = .accentColor
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private func format(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> Date.FormatStyle {
        .init(date: date, time: time, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(tint).accessibilityHidden(true)
            Text(date, format: format(date: .abbreviated, time: .omitted))
            Text("·").foregroundStyle(.secondary)
            Text(date, format: format(date: .omitted, time: .shortened))
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.1), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1) }
        .fixedSize(horizontal: false, vertical: true)
        .help(Text("Recorded \(date, format: format(date: .complete, time: .complete))"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recorded \(date, format: format(date: .complete, time: .complete))"))
    }
}
