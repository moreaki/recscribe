# Recording foundation replacement — issue #51

The review baseline is commit `2f9c42dd92dad72cb7e1d29ce555c2ee48967e53`.
The replacement branch starts at `5dda6302efc3a06490f19769004ef72949b16b25`.
The initial audit identified 105 tracked files with matching historical material;
52 were production source/asset metadata entries. Another 239 files had no direct
matching ancestry. These are starting observations, not independence certificates.

## Implementations and behavior contracts

| Area | Replacement and evidence |
| --- | --- |
| PCM decoding | Explicit endian/container decoding and packet bounds validation. Planar owned Float32 output; integer formats, truncated input and channel-distinct values are tested. |
| Normalization | Converter sessions follow the incoming format; explicit channel selection prevents interface loopback channels entering microphone audio. Native-rate/channel matrices exercise the complete path. |
| WAV writing | Exclusive descriptor creation, positional writes, bounded RIFF payload, partial-write retry and descriptor-bound finalization. Literal quantization/header vectors and an independent AVAudioFile decoder preserve the file contract. |
| Capture and recording lifecycle | Replaced inherited configuration/output processing and controller/view-model flows. RecScribe's later device-input recovery, queued-buffer ownership, multi-source synchronization and session preservation remain. Capture stops before writers drain and seal. |
| Permissions and timers | Single-flight request state, user-intent gating, finite cancellable grant observation and stale-response protection. Independent tests cover shared requests, timeout, cancellation, owner release and grant ordering. |
| Monitoring and discovery | New monitoring service and typed Core Audio property reader; RecScribe's later device-control/routing system remains. Menu discovery uses a cache and requires permission before app enumeration. |
| Menus, support and preferences | New menu renderer/callback ownership, native status-item lifecycle, panel host, folder resolution, installation classification, disk checks, diagnostics and preferences implementation. |
| Native controls | Removed the imported DesignSystem directory. Studio controls use native focus/button behavior, Canvas waveform rendering, native typography and semantic macOS colors. Compatibility measurements and role names remain where existing RecScribe screens depend on them. |
| Tests and fixtures | Re-expressed inherited behavioral cases as independent contracts and parameter matrices. Removed empty generated test scaffolds. PCM ownership and allocation-churn regressions added by RecScribe remain; optional visual-artifact rendering has a new implementation and environment variable. |
| Development tooling | Staged-blob secret hook, microphone-rate tool and CI definitions reauthored. Existing blocking CI job names retained. Reference guard checks the tracked tree and built app. |
| Assets and dependencies | All current icon PNGs and the SVG derive from RecScribe's branding commit `dfaa501`; none matches a baseline asset blob. Earlier bundled fonts were removed in #39. Swift core, transcription/runtime and current vendor notices retain their separate provenance. |
| Build metadata | Xcode-generated workspace/catalog schemas, standard compiler settings, SDK method signatures, imports/braces, file-format constants and existing saved-data/API contracts can match the baseline. These are not concealed by arbitrary renaming. Signing identity, identifiers and entitlement values deliberately remain unchanged. |

`reviewed-components.json` records the reviewed matching paths, decision and content
hash at this stage. `scripts/audit-source-provenance.py` compares exact Git blobs
and line ancestry; modifications after review are reported as requiring review.
A hash or lack of matching lines cannot prove that an implementation was never
adapted. Review the actual replacement commits as well as the inventory.

## Final component and notice disposition

The current implementation tree no longer integrates the retired control library,
upstream workflow or contributor-specific developer configuration. The obsolete
local upstream remote was removed. Builds use this repository and its pinned core.

Each matched component is classified in `reviewed-components.json`. Inspection
of the replacement commits and residual matching lines found no retained authored
operational implementation, inherited test implementation or original media/font
asset. Remaining matches are standard SDK declarations/calls, generated project
and catalog schemas, file-format constants, language syntax, saved-data keys and
public compatibility contracts. Those matches do not identify a remaining authored
baseline component for which the former product attribution would apply.

The Apache-2.0 license terms remain unchanged, as do the current project notice,
Apple framework notice and unrelated dependency notices. The superseded product
attribution and old application-owner statement are retired from current LICENSE
and NOTICE under the exclusions for notices no longer pertaining to a remaining
part in [sections 4(c) and 4(d)](https://www.apache.org/licenses/LICENSE-2.0).
This is the recorded disposition for the reviewed current tree, not a claim of
clean-room development or a deduction from test results alone.

Historical commit `2f9c42d` and its original notices remain accessible in Git.
Previously published releases and discussions are unchanged. The history boundary
in #51 is preserved; this disposition concerns current sources and future artifacts.

All five former file exceptions are removed:

| File | Final disposition |
| --- | --- |
| LICENSE | Standard license terms retained; current project copyright statement. No retired attribution exception. |
| NOTICE | Current project and Apple framework notices retained; superseded product attribution removed. No exception. |
| This assessment | Component evidence and notice rationale retained without retired product/contributor identifiers. No exception. |
| History audit script | Discover historical contributor identities from the pinned Git snapshot rather than storing old names in current source. No exception. |
| Boundary guard | Discover historical project, repository, bundle, contributor and environment identities from the same snapshot. Check every tracked file and the built bundle. No exception. |

The baseline-discovery code stores no alternate encoded registry. Required Git
history is explicit: CI checks out complete repository history, and the guard fails
if it cannot load the baseline. Positive/negative cases include license, notice,
assessment and tool paths to prevent reintroducing a file-level bypass.

The current-tree boundary has zero file exceptions and no literal retired product,
contributor or namespace markers. A generated audit report can still identify
historical original paths from Git; it is not tracked or shipped in the app.
Historical ancestry and matching lines are not hidden or rewritten.

## Validation and manual review

- Before replacing the test implementations, the broad existing behavioral suite
  passed: 562 Swift Testing cases. This records compatibility with the original
  acceptance contracts before the independent test-source migration.
- Focused new PCM, writer, controller, menu and permission contracts passed.
- The final native core run passed 51 tests in 9 suites. Mandatory frozen references
  were not changed or rebaselined.
- The final app suite passed 393 tests in 82 suites; inherited one-case tests
  are consolidated into parameter matrices, so test-function counts differ from
  the earlier suite. Focused Thread Sanitizer validation passed 49 tests in 10
  suites without a reported race. Required remote CI is reported separately.
- Signed Release candidate installed at `/Applications/RecScribe.app`; previous
  installed app is recoverable at `Build/InstalledBackups/RecScribe-before-51-final.app`.
  Bundle identifier, designated signing requirement, team and entitlement values
  matched before replacement. Normal startup and the actual UI were inspected.
- The owner confirmed recording, stopping and playback on the first candidate and
  reported that the expanded candidate's basic functions work without new issues.
  This does not imply a manual test of every device/permission combination.

One earlier short combined-source take reported incomplete end coverage. Both
individual source tracks completed with zero registered timestamp gaps, no mix
clipping and no reported PCM conversion failure. The warning comes from the
unchanged multi-source review calculation; a causal relationship to replacement
was not established. The finding remains documented and the preservation warning
was not suppressed.

PR #86 was merged as `9fd85c9`, with the tree identical to its validated head
`d4e6153`. Integrated CI passed 51 core tests, 393 functional app tests and 393 app
tests under Thread Sanitizer, the strict raw-log/result gate, PCM probe and Release
bundle boundary. Three environment-dependent integrations were skipped per app
run (signed-host entitlement, opt-in Keychain and tool/model smoke); those are not
claimed as executed passes. The remaining change is limited to notice disposition,
audit/guard tooling and documentation, with focused boundary checks and required
CI recorded in the follow-up PR before #51 closes.

## Integration review: main sanitizer correction (#87)

The integration with main at `eafd7cf` preserves the replacement implementations
and this source-boundary assessment. Two inventory entries changed and were
reviewed against their exact new contents: the CI workflow now retains the
blocking PCM/evidence checks, complete sanitizer log and strict result gate from
#87; the replacement PCM fixture publishes its observational retirement callback
before freeing samples. Neither change restores a retired implementation. Their
content hashes and specific integration rationale are recorded in the inventory.

The combined fixture passed a bounded 100,000-buffer TSan probe with no live-owner
overlap or changed samples (checksum `198400000`). A separate synthetic queued
run through the replacement WAV writer passed 2,000 buffers / 128,000 frames /
512,000 exact PCM bytes with all 2,000 owners released and no TSan diagnostic.
The seven sanitizer-evidence regressions and the tree reference guard passed.
These targeted checks are separate from the complete combined CI run, which is
reported with its final revision in PR #86. The installed app remains the
previously manually tested production implementation; no installation, permission
or signing change is part of this integration.
