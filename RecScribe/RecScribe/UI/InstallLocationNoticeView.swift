import SwiftUI

struct InstallLocationNoticeView: View {
    let message: String
    var onReveal: () -> Void
    var onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move RecScribe to Applications").workspaceFont(.sectionTitle)
            Text(message).workspaceFont(.detail)
            ViewThatFits(in: .horizontal) {
                HStack {
                    reveal
                    Spacer(minLength: 8)
                    dismiss
                }
                VStack(alignment: .leading, spacing: 8) { reveal; dismiss }
            }
        }
        .fixedSize(horizontal: false, vertical: true).padding(18).frame(width: 340)
        .background(WorkspaceStyle.background).studioThemeAdaptingToContrast()
    }
    private var reveal: some View { Button("Reveal in Finder", action: onReveal).buttonStyle(.borderedProminent) }
    private var dismiss: some View { Button("Close", action: onDismiss).buttonStyle(.borderless) }
}
