# CI validation scope

`Unit tests` and `Release build` keep their existing required check names. Every
run still builds Release and runs source-boundary, PCM ownership, native core and
frozen-reference checks. No branch protection setting is changed.

`scripts/ci-scope.py` chooses the app-test scope using the complete PR diff (merge
base through the tested merge checkout) or the complete push diff (`before` to
HEAD), not just the latest commit. No label or filename alone can opt out of TSan.

The **focused** path is deliberately narrow: at most five modified files and 80
added/removed lines, containing only Markdown documentation or Swift UI edits
recognized as literal label/icon/help changes or simple numeric spacing, frame,
font, foreground and line-limit modifiers. Literal changes preserve all callback
code. Each zero-context hunk is checked independently so moving executable code
cannot masquerade as a label change. This is a conservative syntactic allowlist,
not a general proof that any UI code is harmless.

The **full** path is the default for everything else: capture/recording,
concurrency, buffering, sessions/storage/deletion, transcription, permissions,
models/schemas, dependencies, tests, CI/build configuration, new/deleted/renamed
files, broad edits, unrecognized UI code, missing baselines and diff errors.
In particular, changing `.disabled`, state, event handlers, lifecycle hooks or
async work inside a SwiftUI file requires the full suite and TSan. CI-policy
changes themselves take this full path. Cosmetic edits involving unsupported
Swift syntax also conservatively run full CI; expand the allowlist only with
regression tests and review.

Focused runs execute the existing recording review, menus, routing summaries,
routing controls, bulk-deletion and recording/session contracts, with no UI OCR
or internal view-tree tests. They export the functional result bundle and reject
failed or zero-test runs. Full runs execute the entire functional app suite and
the entire Thread Sanitizer suite, then retain the existing complete, matching,
warning-free evidence gate from #83. A sanitizer failure cannot produce a passing
`Unit tests` result. Focused runs report that TSan was deliberately skipped rather
than claiming a sanitizer pass.

Run classifier and policy regression tests using the artifact wrapper:

```sh
python3 scripts/work-artifacts.py run --label ci-policy test -- \
  python3 -m unittest discover -s scripts/tests
```

Manual review of actual native UI remains necessary for presentation changes;
a focused CI pass is not a claim of visual or VoiceOver acceptance.
