import SwiftUI

struct OnboardingView: View {
    @Environment(RecorderViewModel.self) private var recorder
    var body: some View {
        VStack(spacing: 20) {
            StudioBrandMark(size: 72)
            Text("Welcome to RecScribe").workspaceFont(.heroTitle).multilineTextAlignment(.center)
            Text("Capture playback from your Mac, a selected app, or your input devices. Choose the recording folder in Settings.")
                .workspaceFont(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                help("Playback capture uses macOS Screen Recording access. RecScribe saves audio; screen frames are discarded.", icon: "speaker.wave.2")
                help("Input devices use Microphone access. RecScribe requests it when you start capturing an input.", icon: "mic")
                help(PermissionKind.screenCapture.navigationHint, icon: "lock.shield")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if recorder.canRecord {
                Label("You're ready to record", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).workspaceFont(.sectionTitle)
            } else {
                Button("Open System Settings") { recorder.openSystemSettings() }.buttonStyle(.bordered)
            }
            Button(recorder.permissionStatus == .granted ? "Get started" : "Done") { recorder.completeOnboarding() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .fixedSize(horizontal: false, vertical: true).padding(32).frame(width: 420)
        .background(WorkspaceStyle.background).studioThemeAdaptingToContrast()
    }
    private func help(_ explanation: String, icon: String) -> some View {
        Label(explanation, systemImage: icon).workspaceFont(.detail)
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
