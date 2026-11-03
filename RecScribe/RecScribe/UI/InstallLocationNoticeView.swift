//
//  InstallLocationNoticeView.swift
//  RecScribe
//
//  Contents of the install-location panel (BL-082).
//
//  Deliberately terse and physical: the whole message is an action the user has
//  to take in Finder, and there is no in-app remedy to offer instead. "Reveal in
//  Finder" exists because the app's real location is randomised and unguessable —
//  the user cannot drag what they cannot find.
//

import SwiftUI

struct InstallLocationNoticeView: View {

    let message: String
    var onReveal: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move RecScribe to Applications")
                .workspaceFont(.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .workspaceFont(.detail)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack {
                    GlassPillButton(
                        "Reveal in Finder",
                        emphasis: .primaryNeutral,
                        size: .small,
                        action: onReveal
                    )
                    Spacer()
                    GlassPillButton(
                        "Close",
                        emphasis: .tertiary,
                        size: .small,
                        action: onDismiss
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    GlassPillButton(
                        "Reveal in Finder",
                        emphasis: .primaryNeutral,
                        size: .small,
                        isFullWidth: true,
                        action: onReveal
                    )
                    GlassPillButton(
                        "Close",
                        emphasis: .tertiary,
                        size: .small,
                        isFullWidth: true,
                        action: onDismiss
                    )
                }
            }
        }
        .padding(18)
        .frame(width: 340)
        // Same ground as every other surface. Still not a glass *panel* — this
        // sits inside a titled NSPanel, and a rounded card here would put a
        // second set of corners inside the panel's own square ones.
        .background(WorkspaceStyle.background)
        .glassThemeAdaptingToContrast()
    }
}
