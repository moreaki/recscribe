# Quantized Whisper native compatibility — 10 November 2026

All six fixed Q5_1/Q4_0 artifacts loaded successfully and produced valid canonical
output in known-language and automatic modes on one development clip. All five
unchanged F16 controls did too: **22/22 calls completed with review flags**.
This establishes a bounded native compatibility check, not preserved accuracy
or nine-language coverage. No model/default is promoted.

| Artifact | Valid canonical calls | Exact output matches to its F16 parent |
| --- | ---: | ---: |
| Small Q5_1 | 2/2 | 0/2 |
| Small Q4_0 | 2/2 | 0/2 |
| large-v3-turbo Q5_1 | 2/2 | 0/2 |
| large-v3-turbo Q4_0 | 2/2 | 0/2 |
| large-v3 Q5_1 | 2/2 | 0/2 |
| large-v3 Q4_0 | 2/2 | 0/2 |

Different output hashes do not establish whether wording is better or worse.
No WER/CER, language-ID accuracy or semantic-quality score was produced. The
English source tag is a planning label, not independent language/variety review.
Swiss written-German non-regression, switches, independent channels, regional
coverage and approved references remain pending.

## Fixed execution and limits

The prospective compatibility seal fixes the original eleven model hashes, the
existing matched decoding profile, one 60-second development view, known/auto
modes and one repeat. The CLI source is `517d3440975bd6837c409e6a70c3a23081f947c6`,
SHA-256 `b082ca6dddb9fc1d315d95cb4a9bcc5c06f1b49f94dc9b06b5ec5c32d897eaec`.
The complete staged product includes its three required resource-bundle files;
both schema hashes match the source revision and all five frozen renderer
exports match. The whisper.cpp 1.9.5 binary and actual library identities are
retained in the complete-product build receipt.

Actual commands keep two threads, `-tp 0 -mc 0`, no added VAD/search/fallback
overrides, separate fresh native invocations and no cross-source/channel text
state. Hardware is the M2 Ultra/24-core/64 GB Mac Studio, macOS 26.6.2; the local
CLI build used Xcode 27.1/Swift 6.4 compatibility tooling. Raw commands, native
timers, model/binary/profile identities, source hashes, working audio, raw ASR,
canonical outputs and logs remain protected externally.

Strict resource launches were repeatedly deferred/cancelled by desktop/system
CPU activity. Their 50% foreign-process threshold remains unchanged. This
**separate compatibility-purpose amendment** was sealed before any quantized
compatibility outcome: nice 10, one job at a time, a 900-second deadline and a
1000% foreign-process limit. Capture, uncertain-state, competing build/test/ASR
and VM cancellation remain active. Retained wall/RTF/RSS observations are
**UNCONTROLLED / NOT EVALUATED** for resource acceptance. One repeat is not a
timing stability panel. No speed, runtime-memory, first-result or total unified
GPU-memory improvement follows from this check.

The guard finished with return code zero, its CLI reaped, no owned descendants
and no shutdown errors. The independently verified postflight checks all 22
actual model/runner/source identities, all twelve direct parent comparisons,
no quality scores, and 359 retained output files. It rehashes all eleven models,
121 original source-package files, six original candidate-freeze inputs and
nine critical archived files unchanged. Prior failures and partial/deferred
attempts remain separate; the Tiny Swiss zero-duration failures are not erased
by success on this different English clip.

## Caption preparation correction

The initial preparation requested exact base-language caption tags and downloaded
none. A metadata inventory found an uploaded `en-US` track for the English
development source that exact `en` lookup missed. Preparer 1.2 now inventories
manual regional/script tags and requests explicit selection rather than silently
choosing a convention or calling the source automatic-only. Translated/automatic
tracks still cannot become human references.

The raw `en-US` VTT was acquired separately, preserving its 8,202 bytes and cue
times. SHA-256 is
`5b7ff207383dca5f6984879d604f28b4e2b0fb690cf37a4d0210ae8eedd1c555`.
A pending review packet retains 24 original cues intersecting source seconds
30–90, with two partial boundary cues; no model hypotheses were consulted.
Uploaded captions do not establish audible variety, correctness, timing or source
rights. **Approved references remain zero.** Original v1 audio packages, metadata,
requested-track classifications and manifests are unchanged.

## Validation and remaining work

The regional-tag regression and the complete offline script suite pass:
**154 tests**. Reporter 1.3 explicitly marks resource-only reports unscored,
without suggesting CER or language-ID accuracy was measured. The staged CLI's
frozen renderer check passes all five hashes. Core Swift code and frozen fixtures
are unchanged from the previously validated source.

PR #125 head `edce4ff07b270bfcdeb03b797cc99ff02f7cf30c` passed full
[CI run 42858231598](https://github.com/moreaki/recscribe/actions/runs/42858231598):
native/frozen 92 tests; functional/TSan each 461 tests, 458 passes and three
matching existing opt-in skips, with zero failures/runtime warnings/diagnostics
or unexpected restart. The independent matching-count sanitizer gate and
provider artifact digest audit passed (SHA-256
`79983bbd9cf4152b630bddf52fc2b5862ceb6d2cfa183149276926f298de8369`).
The new caption/report changes require fresh full CI on their publication head;
earlier green evidence never passes a later SHA.

The [size evidence](quantization-readiness-2026-11-10.json) still establishes
61–62% Q5 and 70–71% Q4 same-parent model-file savings. Next acceptance work is
reviewed source/reference coverage in #104/#122 and controlled three-repeat
resource measurements in #105, followed by prospective quality/runtime budgets
and a fresh held-out freeze. No consumed holdout is reused as fresh data. No
automatic merge, weight edit, training, installed-app or model/default change.
