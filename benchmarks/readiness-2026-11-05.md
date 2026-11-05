# Whisper quality readiness — 2026-11-05

> Historical preparation snapshot: this records the initial dry run and local
> checks before corpus acquisition. Later on 2026-11-05, a 27-utterance public
> development pilot completed 810/810 measured cells across all five models.
> See the [measured pilot baseline](pilot-baseline-2026-11-05.md) for results,
> current provenance and limitations. The missing inputs, zero-score tables and
> pending-check statements below describe the earlier snapshot, not the later
> pilot. Representative v2 coverage and held-out acceptance remain pending.

This is an implementation/readiness report for #103–#108, not a recognition
quality result. No corpus audio was downloaded, approved or scored. No model
weights were changed and no candidate was promoted.

## Retained control and host

The unchanged source is `c214a8ed03f972a5a9cab64105145a67371b97b4`, retained as
`codex/whisper-quality-untouched-control`. Its Release CLI was built from an
isolated clean worktree using the existing SwiftPM cache; the temporary worktree
was removed afterward. Binary and build record remain under
`Build/Products/WhisperControl-c214a8e/`. CLI SHA-256:
`9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6`.

The host is a Mac Studio Mac14,14, M2 Ultra, 24 CPU cores (16 performance and
8 efficiency), 60 GPU cores, 64 GiB memory, macOS 26.6.2 (25G83), Xcode 27.1
(27A9275), Swift 6.4 (swiftlang-6.4.0.34.1). Private host/power reports are retained
with readiness evidence. The unrelated Docker VM was stopped gracefully at the
user's request and no VM guest process remained. Functional tests/builds ran
during preparation; their times are not controlled ASR benchmark measurements.

Installed whisper.cpp is 1.9.5. Executable SHA-256:
`e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16`.
The control inherits its search/fallback defaults and passes `-tp 0 -mc 0`.
Automatic language remains `auto`; known-language controls pass the base tag.
The readiness plan has no VAD. Model file headers have raw GGML ftype 1; this
records the inspected file type without claiming every tensor has one precision.

| Multilingual control | Local SHA-256 | Readiness |
| --- | --- | --- |
| tiny | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` | File present; corpus pending |
| base | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` | File present; corpus pending |
| small | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | File present; corpus pending |
| large-v3-turbo | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` | File present; corpus pending |
| full large-v3 | — | Model and corpus pending |

No local Silero model was found. Model checkpoint provenance beyond retained
file identity and hashes still needs review before a published quality claim.

## Executed readiness and quality gaps

The native command executed a development dry run covering five models, known
and automatic language, final and live-replay paths, and three repeats. It
retained **1,800 pending cells, zero measured cells** in the protected external
directory `~/Library/Application Support/RecScribe/Benchmarks/quality-20261105-readiness-d4124448/`.
That directory contains the exact experiment/corpus snapshots, binary/model
hashes, host evidence, gaps and `matrix/matrix.json`. It is outside disposable
retention. A pending live-replay cell explicitly names its unsupported adapter;
it is not counted as a successful replay.

| Language/output coverage | Eligible scored samples | Quality | ASR latency/resources |
| --- | --- | --- | --- |
| Swiss German dialect wording | 0 | Pending dialect/spelling review | Unmeasured |
| Swiss speech → Standard German rendering | 0 | Separate task; not verbatim ASR WER | Unmeasured |
| German | 0 | Pending | Unmeasured |
| French | 0 | Pending | Unmeasured |
| Italian | 0 | Pending | Unmeasured |
| English | 0 | Pending | Unmeasured |
| Arabic | 0 | MSA/dialect and strict/secondary orthography coverage pending | Unmeasured |
| Chinese | 0 | Variety/script coverage pending; CER only | Unmeasured |
| Spanish | 0 | Regional coverage pending | Unmeasured |
| Portuguese | 0 | Brazilian/European coverage pending | Unmeasured |

The [corpus contract](corpus-contract.md) records source candidates, license and
selection limits, missing independent speakers/sessions and adverse coverage.
WER/CER, critical content, dialect fidelity, language-ID confusion, confidence,
timestamp accuracy, live delay/backlog and total unified GPU memory are not
measured by this readiness run. No quality/runtime tradeoff can yet be selected.

## Implemented controls and outstanding implementation

Versioned scoring, hash/split/channel validation, bounded/cancellable scoring,
the serial matrix, failed/pending cells, repeat summaries, paired comparisons,
configuration provenance and held-out hash locks are implemented. Native final
jobs accept bounded capability-checked search/fallback/context/terminology,
Silero and language policies through opt-in profiles. Live arguments and private
attempt evidence use the same policies; ordinary saved settings keep the control.

Stateful previous-window text conditioning remains unavailable. The real app
offline live-replay adapter and startup binary/model identity capture for live
experimental callers remain pending. VAD uses inspected upstream padding/time
mapping; machine-readable rejected-region intervals and quiet-speech/source-range
acceptance still need implementation/evaluation. Speech-aware auto is the
VAD-before-language interaction in pinned 1.9.5, not an independent trained
detector or measured confidence selector. No preference API, permanent language
lock or new within-file redetection algorithm is claimed.

Baseline-derived budgets, isolated development comparisons, candidate selection,
freeze and combined held-out evaluation remain pending. A hash-lock mechanism
is available, but no evidence-supported winning profile has been frozen. Keep
all issue acceptance items requiring those results open.

## Validation evidence

- Native core: 75 tests in 13 suites passed, including existing frozen-reference
  contracts. Frozen captures were not modified.
- Changed live/profile app contracts: 34 tests in 2 suites passed, including
  interval ownership, cancellation/retry, original hashes and private evidence.
- Source-boundary and PCM ownership checks passed.
- Release compilation passed; the final incremental Release validation is
  recorded with the stacked PR. No installed app was replaced by this work.
- Complete local functional app run: 441 tests, one failure in the unchanged
  `SessionPlaybackAcceptanceTests.narrowTransportHasSpokenPositionAndKeyboardControlsWithoutDuplicateActions`.
  Its fixture could not acquire the key window (`active=false`, `keyWindow=nil`).
  This run is failed, not a complete functional pass. An earlier Release test
  invocation stopped before tests because Release lacks `-enable-testing`;
  subsequent functional/focused invocations used Debug.
- Full hosted functional/Thread Sanitizer and Release checks remain required
  on each current PR head. TSan is pending, not passed or skipped by policy.

Managed validation logs/result bundles are retained under `Build/Artifacts/test/`
with `issue-103-*` labels and explicit pins for required evidence. Pending CI
must not be reported as passed and neither PR is authorized for automatic merge.
