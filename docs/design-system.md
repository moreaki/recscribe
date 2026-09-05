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

- `Glass*` names identify reusable visual building blocks.
- Application-specific composition belongs in `Adapters/`.
- Red is reserved for recording, destructive actions, or failure states.
- The interface is dark-only until a complete light palette is designed and tested.
- Accessibility labels, contrast, reduced motion, and Dynamic Type remain part of the
  component contract.

The original Home Rec attribution remains in `NOTICE` and the repository history.
