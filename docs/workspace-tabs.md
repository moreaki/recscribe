# Lightweight workspace tabs (0.2.7)

All page-tab navigation now uses `WorkspaceTabs`: Live/Transcript/Summary/Review
and Recording/Transcription/Models/Intelligence/Diagnostics. Feature selection
remains a binding owned by the existing view; recording and processing behavior
is unchanged. Value pickers (provider, archive format, processing location, chunk
duration, text mode) remain distinct from page navigation.

References inspected locally: Quantivane's `SettingsView.sectionPicker` and
Modex's `ModexMenuView.tabBar`. The common design uses compact SF Symbols, quiet
inactive labels, hover feedback, and a selected underline instead of filled
segmented-control chrome. Spacing, size, color, and corner values reuse existing
RecScribe design tokens. There are no new dependencies or AppKit bridges.

The layout adapts from icon-and-title to title-only to icon-only. Buttons retain
accessible names, selected traits, identifiers, and tooltips in every layout.
Selection has a shape cue as well as color; no motion is required.

Verification: 390 app tests passed. Opt-in snapshots cover all four transcript
selections at 560/340/220-point widths, all five settings selections, and complete
workspace/settings views. Representative wide/narrow and integrated snapshots
were visually inspected for clipping, alignment, and consistent selection styling.
Outputs: ignored `Build/TabSnapshots`; log: `Build/all-tabs-ui-tests.log`.

Signed local candidate: `Build/LightTabsRelease/Products/Release/RecScribe.app`,
version 0.2.7 (207), 64-bit arm64, Swift 6 complete concurrency. Bundle ID
`com.moreaki.recscribe`, team `CDS4KLP8GT`, authority Apple Development: Roberto
Nibali (6RA9887B6U). Strict/deep signature validation passes; hardened runtime and
own-app Keychain group are retained, with no get-task-allow entitlement.
Executable SHA-256:
`9847ebbfc1f98b6e9343361107b7913bdd565184ea830c659d4027fd5a4a5216`.

This is not Developer ID signed or notarized. The distribution audit correctly
rejects the development authority; no stapling, distribution zip, or public upload
was performed. The running app was not replaced or restarted, and its data was not
used for the synthetic snapshots. Keyboard/VoiceOver interaction in the user's
running instance was not manually exercised.
