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

## Scope and notice decision

The current implementation tree no longer integrates the original control library,
upstream workflow or assistant-specific developer configuration. The local upstream
remote was removed; an older clone can remove its own obsolete remote with
`git remote remove upstream`. Builds use this repository and its pinned local core.

The original repository was Home Rec, with historical contributions associated
with Melissa de Britto (`melissa-pereira-deel`) and Claude/Anthropic. All 94 history
entries mentioning Claude/Anthropic are ancestors of the baseline. Historical Git
commits, releases and discussions are intentionally preserved and outside #51.

**Literal zero references is not claimed.** LICENSE and NOTICE retain the original
copyright/source attribution conservatively for this repository's source history
and distribution. This implementation review is not a clean-room or legal
certification and does not establish that every historical notice is inapplicable.
The Apache license and unrelated dependency notices are unchanged. Deleting a
copyright notice is not treated as evidence of replacement.

The reference guard's only reviewed exceptions are LICENSE, NOTICE, this assessment,
the history-audit script and the guard's own identifier definitions. No application,
test, asset, CI configuration or built-bundle exception is allowed. The built-app
scan passed with no exceptions. The guard is a regression check, not a provenance
or license determination.

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

Keep #51 open and PR #86 in draft until final review and required CI are complete.
