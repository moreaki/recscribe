# RecScribe design system

RecScribe uses the dark glass SwiftUI design foundation inherited from Home Rec. The
components now belong to RecScribe and live under:

```text
RecScribe/RecScribe/DesignSystem/
  Core/       tokens, primitives, and reusable components
  Adapters/   application-specific composition
```

The previous byte-for-byte vendoring relationship with the separate
`ui-explorations` repository has been removed. This avoids presenting RecScribe-owned
brand changes as untouched upstream files and lets the design evolve with the product.

## Conventions

- `WorkspaceStyle` defines the shared dark workspace chrome (background, panel, card, icon, and tab treatments), while `Glass*` names identify the retained control primitives (`GlassPillButton`, `GlassIconButton`, `GlassBrandLockup`, `GlassLiveWaveform`) and tokens (`GlassColors`, `GlassSpacing`, `GlassRadius`, `GlassMetrics`, `GlassMotionToken`, `GlassTypography`).
- Typography standardises on native macOS San Francisco and SF Mono across all windows, sheets, and the menu-bar popover (no bundled third-party `.ttf` fonts).
- Application-specific composition belongs in `Adapters/` or `UI/`.
- Red is reserved for recording, destructive actions, or failure states.
- The interface is dark-only until a complete light palette is designed and tested.
- Accessibility labels, contrast, reduced motion, and Dynamic Type remain part of the
  component contract.

The original Home Rec attribution remains in `NOTICE` and the repository history.
