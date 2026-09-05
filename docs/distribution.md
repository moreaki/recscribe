# Distribution status

RecScribe has no public release channel yet. Development builds use automatic signing
with Apple Developer Team `CDS4KLP8GT`.

For a local signed Release build without opening Xcode, run
`scripts/build-app.sh`. It uses the checked-in automatic-signing configuration and
writes `Build/Products/Release/RecScribe.app`. Use `--ad-hoc` only when an Apple
development identity is unavailable.

Before the first external release, the project needs its own:

- Developer ID Application certificate and notarization credentials;
- release workflow and reproducible DMG packaging;
- semantic version and build-number release checks;
- optional Sparkle key pair and HTTPS appcast, if automatic updates are restored;
- privacy policy and release acceptance checklist.

Never reuse Home Rec's signing identity, Sparkle key, appcast, download URLs, or
notarization credentials. Secrets belong in the local Keychain or the CI secret store,
not in the repository.
