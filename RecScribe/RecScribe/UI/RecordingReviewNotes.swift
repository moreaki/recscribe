import SwiftUI

/// Presentation only: retain the original manifest diagnostics for inspection.
nonisolated struct RecordingReviewNotes {
    let messages: [String]
    let originalMessages: [String]

    init(session: RecordingSession) {
        originalMessages = session.issues
        let tracks = session.sourceTracks ?? session.sourceIdentity.map { [$0] } ?? []
        let names = tracks.enumerated().map { index, track in
            let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let opaqueName = track.role.rawValue.hasPrefix("input-") && name.contains(track.role.rawValue)
            let display = name.isEmpty || name == track.role.rawValue || opaqueName
                ? "Audio source \(index + 1)" : name
            return (track.role.rawValue, display)
        }
        func readable(_ text: String) -> String {
            var result = text
            for (role, name) in names { result = result.replacingOccurrences(of: role, with: name) }
            // Legacy manifests can lack the name associated with this opaque ID.
            return result.replacingOccurrences(of: #"input-[0-9a-f]{64}"#,
                                               with: "unidentified audio input", options: .regularExpression)
        }
        let stalled = "A selected source stopped delivering data; review source coverage and silence in the mix."
        let missing = "Recording saved with incomplete coverage: a selected source delivered no audio data. Review the preserved source tracks."
        func isMissing(_ text: String) -> Bool {
            text == missing ||
            (text.hasPrefix("Selected ") && text.hasSuffix(" source delivered no data; coverage is incomplete.")) ||
            (text.contains(" source: Selected ") && text.hasSuffix(" source has no saved audio"))
        }
        func isQualitySummary(_ text: String) -> Bool {
            text == "The recording has clipping, timing gaps or incomplete source coverage. Review the preserved source tracks and mix." ||
            text == "Recording saved with review notes: clipping, timing gaps or incomplete source coverage. Review the preserved source tracks and mix."
        }
        var result: [String] = []
        var coverageShown = false
        var qualityShown = false
        for issue in session.issues {
            if issue == stalled || isMissing(issue) {
                guard !coverageShown else { continue }
                coverageShown = true
                let missingNames = names.filter { role, _ in
                    session.issues.contains { isMissing($0) && $0.contains(role) }
                }.map(\.1)
                var summary = session.issues.contains(stalled)
                    ? "A selected source stopped delivering audio."
                    : "A selected source delivered no audio."
                if !missingNames.isEmpty {
                    summary += " No audio was saved for: \(missingNames.joined(separator: ", "))."
                } else if session.issues.contains(stalled) && session.issues.contains(where: isMissing) {
                    summary += " At least one selected source supplied no audio."
                }
                result.append(summary + " Review the mix and available source tracks.")
            } else if isQualitySummary(issue) {
                guard !qualityShown else { continue }
                qualityShown = true
                result.append("Check this recording for distortion, timing gaps or missing source audio.")
            } else {
                let message = readable(issue)
                if !result.contains(message) { result.append(message) }
            }
        }
        var seen = Set<String>()
        messages = result.filter { seen.insert($0).inserted }
    }
}

struct RecordingReviewNotesView: View {
    let notes: RecordingReviewNotes
    @Environment(\.glassTheme) private var theme
    @State private var expanded = false
    @State private var technicalExpanded = false

    var body: some View {
        if !notes.originalMessages.isEmpty {
            VStack(alignment: .leading, spacing: GlassSpacing.m) {
                Button {
                    expanded.toggle()
                    if !expanded { technicalExpanded = false }
                } label: {
                    Label(expanded ? "Hide review notes" : "Review notes",
                          systemImage: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recording-review-notes")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")

                if expanded {
                    ForEach(notes.messages, id: \.self) { message in
                        Text(message).foregroundStyle(theme.colors.statusWarning)
                    }
                    Button {
                        technicalExpanded.toggle()
                    } label: {
                        Label("Technical details",
                              systemImage: technicalExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recording-review-technical")
                    .accessibilityValue(technicalExpanded ? "Expanded" : "Collapsed")
                    if technicalExpanded {
                        VStack(alignment: .leading, spacing: GlassSpacing.s) {
                            ForEach(Array(notes.originalMessages.enumerated()), id: \.offset) { _, message in
                                Text(message).textSelection(.enabled)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
    }
}
