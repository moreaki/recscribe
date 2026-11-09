# Round 4 execution record

The campaign and final audits are complete. Both rotation families are rejected
under the frozen quality gates; see the [measured report](weight-space-round4-report-2026-11-09.md).
Earlier pending statements below describe their dated execution checkpoints.

The [November 7 protocol](weight-space-round4-protocol.md) and
[artifact/corpus checkpoint](weight-space-round4-artifacts-2026-11-07.md) remain
unchanged. This record describes execution admission and validation follow-ups.
It changes no candidate, dataset, setting, scorer, gate or planned inference cell.

## Admission on November 9

A fresh native RecScribe inspection showed **Ready when you are**, **Start
recording**, a new session at 00:00, no channel data, and **Live transcription off**.
The exact running app was `/Applications/RecScribe.app`, bundle identifier
`com.moreaki.recscribe`. No app replacement or recording interruption occurred.
The immutable idle attestation is
`240204d0e680595462a018c6710868b964102825d062a66ba93e7197a3e84ad2`.

All six derived artifacts then passed the separately frozen native-load check:
two rotated F16 controls and four Q4 artifacts, serially on the pinned native
binary. Each initialized context/state with GPU and Flash Attention enabled,
then rejected an intentionally empty, newly created invalid input before the
transcription call. Exact expected exit 11, input-read failure, Metal backend and
state-allocation witnesses were required. The wrapper and outer owned-session
guard completed successfully, with all model/native hashes unchanged.

This was model initialization, **not ASR or quality measurement**. Printed
compute times were zero at the native timer's precision; displayed run counts
are clamped to at least one by the pinned source and do not reveal actual counts.
The no-inference conclusion follows the pinned read-failure control flow. Full
ASR compatibility is tested by the canonical grid. These six initialization
checks add zero quality cells and are excluded from quality/resource cohorts.

| Admission record | SHA-256 |
| --- | --- |
| Native-load source | `99e17c61ac61f6776c62237e3f113fa1009c638265632d829bd838797c400edd` |
| Prospective native-load freeze | `3f3fb3fbb01b564f487fba22c4eaf118c1bf779db471746de15732b76f5243b1` |
| Load-only synthetic contract receipt | `1a8ddc7418229dfed0f653e7c6ea39b674aa891be830ffecadcae5bc7bdcbaa4` |
| Initial fifteen-stage family seal | `8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2` |
| Additional execution-admission capsule | `1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153` |
| Independent preflight audit | `e7d168e824f0d2ae9c629e1b543abc04746f3e94e7062b9e22ab9fd07ad82858` |

The additional capsule binds actual load receipts, clean guard closure, source
and contract hashes, the fresh UI observation and exact controller command.
It supplements the original family seal without changing its bytes or any of
the fifteen preplans. Independent preflight verified 586 bound files totaling
8,882,736,045 bytes, all eleven artifacts, 2,132 actual Q4 tensor payloads,
2,464 deterministic mask records, and acquisition/source chronology.

Actual-launch host/software checks match the preparation fingerprint: Mac14,14,
64 GiB/24 CPU cores, macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), Swift 6.4.
This remains a shared desktop with uncontrolled resource observations.

## Fixed campaign

The serial campaign started **2026-11-09 08:53:32 UTC** under controller
`c0fc46a4e51895b8c1587ccf61c9e28f9c7b86ad67e2d3bdee0b9fccea1a6cc4`
and sealer
`cf97523a03e6843fb8fcb4fec2151b41db4f6c08fddf69e65c77fddc20346dad`.
It plans 4,554 calls, 2,484 native parent pairs, 828 derived Q4 contrasts and
1,242 separately unpaired reference placeholders. All fixed artifacts advance
regardless of development direction. No measured cell is selectively retried.

One fresh UI observation admitted this fixed campaign. Per-stage capture,
uncertainty and competing-work checks continue under the frozen owned-session
guard. Capture takes priority; cancellation, setup/hash failure, timeout or
unclassified failure stops owned research. Known finite native-format failures
remain raw and unscored under the predeclared forensic contract. Metadata
reporting and preparation are separate from model execution.

The ten panel/development partitions must be terminally attempted and assessed
before the five final held-out plans seal together. A terminal attempt count
does not prove complete counted quality. Missing rates remain null, observed
partial counts stay separate, and repeated panel calls are not extra speech.

The new metadata-only reporting tools were frozen before held-out evaluation:
summary source
`9638db9ee4cf02b15dafc854bdcbfce74c523de04757115ba5eb358226ddd870`,
projector
`ce29043f8c7ba02d550069cf18f7efc57e8517cae43570da2a84a94b8fe19f38`,
reporting freeze
`af57d0e45eb51155f8eec6d8bc3f4b8955b22f0b556529bf9f81481bf0188075`.
They require all fifteen terminal grids before reading outcomes, preserve frozen
assessor decisions and nulls, and project 495 language cohorts/55 macro rows.
Nine synthetic contracts and full fifteen-stage CLI write smokes passed without
opening actual outcomes. Synthetic fixture root/hash overrides are explicit;
the real source, argument parsing, metadata rebuilding and write paths ran.

## CI evidence and diagnostic follow-up

Required full CI on the previous heads failed:

- PR #117, `d5e853d`: [run 42386269494](https://github.com/moreaki/recscribe/actions/runs/42386269494).
- PR #118, `35bbe8e`: [run 42388934938](https://github.com/moreaki/recscribe/actions/runs/42388934938).

Both Release builds passed. Both native suites timed out at the fixed 240-second
limit, with incomplete whole-suite summaries. The GoldenReference subset passed,
but this does not pass the native suite. Offline/PCM/functional/TSan steps were
unexecuted after the failure; the complete sanitizer evidence gate failed.
Earlier green implementation runs and local passes do not pass these heads.

The retained diagnostics contained no eligible sampled test-host PID and no
stack samples. Several contracts remained unfinished; the exact hang cause is
unresolved. Follow-up `08584bd` adds recognition of an owned macOS `xctest` host
and a bounded 64-entry process snapshot at stalls, including unknown host names.
It retains the same owned-session checks, maximum three samples, two-second
sampler timeout, 240-second suite bound, full test command and pass/count gates.
Fifteen focused supervisor contracts passed. This improves diagnostics and does
not claim to fix the hang.

Exact logs, uploaded artifacts and source/hash audit are protected externally;
CI audit receipt:
`2f56910a7937f1874812c03862b64656dfb6a03a8ee44cd7ac169454041afed1`.
No fixtures were rebaselined or acceptance checks bypassed. All research PRs
include newest fetched origin/main `e9a6273`; no automatic merge is authorized.

Full CI subsequently **passed on exact head `08584bd`** in
[run 42590578978](https://github.com/moreaki/recscribe/actions/runs/42590578978):
native/frozen 87 tests in 15 suites; functional and TSan each 461 tests in 86
matching suites (458 passed, three matching existing opt-in skips, zero failures),
the complete no-runtime-diagnostics evidence gate, and Release. The native
supervisor exited normally with its owned session reaped and no retry. No stall
or sampling occurred, so the earlier hang cause remains unresolved. The retained
independent CI audit is
`2474cf279c0531c398417042974d5aec94a4d3a5f673938830ca74e7d68620ad`.

The same two-file diagnostic patch was backported without alteration to parent
PR #117 as `19d52c1`, directly after its permission-test fix `d5e853d`. This is a
fast-forward source improvement, with no timeout, command, count gate or retry
change. Its required [full CI](https://github.com/moreaki/recscribe/actions/runs/42606094494)
is pending at this checkpoint. The passing `08584bd` run does not pass another
SHA; the final publication head likewise requires its own checks. The backport
used an isolated managed checkout, archived after preserving its evidence;
round-four execution sources and inference were unchanged.

The cached regular local native/frozen run on `08584bd` also passed all 87 tests
in 15 suites, with a fully reaped supervisor and no retry. Its receipt is
`b49a11aa27165f9fc5c98ad86953632b8188068d18694491d67c2debe5fb5ad3`.
This healthy local run neither reproduced the CI stall nor exercised sampling.

Subsequent parent CI failures remain separate from the passing `08584bd` run:

| Parent head | Full CI run | Retained independent audit SHA-256 |
| --- | --- | --- |
| `19d52c1` | [42606094494](https://github.com/moreaki/recscribe/actions/runs/42606094494) | `40fbcbdaf630dd0c64e3e7c7c115fe5ea9d741276a385ee19af7647d30417753` |
| `b7bfb33` | [42610969764](https://github.com/moreaki/recscribe/actions/runs/42610969764) | `6c9f8151591215763ab2713d04a38feb4113d411cb2c471e6c6c7530186bb154` |

Both reached the unchanged 240-second native bound; Release passed, later
functional/TSan validation was unexecuted and the complete evidence gate failed.
Owned processes were reaped, with no retry and no complete native-suite summary.
The first showed an owned `swiftpm-testing-helper` excluded from sampling.
Exact-basename recognition in `b7bfb33` corrected that gap, with 17 mocked
contracts and independent source review. Its next failure selected the helper,
but the collector exceeded its two-second total bound during symbol processing
after completing one second of capture. No usable stack report survived, so the
underlying native hang remains unknown.

A separately bounded owned-child diagnostic trial found that the documented
`spindump -onlyTarget -noSymbolicate` alternative requires root. No privilege or
privacy change was made. The preceding synthetic setup stop and this actual
exit-77 trial remain immutable, with both owned targets reaped and no ASR.

Prospective parent follow-up `02ee557` retains the unprivileged `sample` tool
and one-second capture, but permits **one shared ten-second diagnostic batch**
for inventory, startup, all at-most-three targets and bounded cleanup. This
budget is established once and clipped to the original 240-second suite deadline;
it is not reset per target. Explicit owned sampler sessions, interruption polling,
a cleanup reserve and immediate native-deadline rechecking prevent an unbounded
symbol-processing wait. Cleanup uncertainty fails supervision. OS spawn/reap
uncertainty is not presented as a hard real-time guarantee.

Thirty-one mocked contracts and independent lifecycle/source review passed.
The native command, suite/count/pass gates, native owned cleanup and no-retry
policy remain unchanged. This is a diagnostic amendment, not a hang fix or a
change to any scientific setting. [Full CI on `02ee557`](https://github.com/moreaki/recscribe/actions/runs/42616254880)
is pending: native/frozen and functional steps show success, but TSan and its
final matching-count/diagnostic evidence gate are not yet established at this
checkpoint. No completed stack or causal-fix claim follows from a healthy run.

Quality results, final per-language/resource evidence and final preservation
audits are pending at this execution checkpoint. No adaptation success, bundled
default or distribution change is established by preparation or file compression.

## Retained metadata stop after Base development

The first seven inference grids reached **738 terminal attempts: 737 completed
and one failed**. The five panels and Tiny development had already been assessed.
Base development finished 71/72 calls; one native result assigned speech a
zero-length interval. Its raw output remains unchanged and unscored.

At **09:37:11 UTC**, orchestration stopped while invoking the frozen classifier.
The controller requested `natural-failures.json`; the unchanged classifier CLI
requires `natural-failures.attempted-v2.json`. Its filename check rejected the
call before classification. All later inference remained unstarted.

The original journal is retained byte-for-byte under
`72a096b9b51912569c9b37ddc8c4ac7098b4040eea1be96e337335c4b13196e5`.
The same classifier was then run once with its required output filename. It
classified the single failure as the existing `zero_duration_speech` branch,
with zero unknown failures and no emitted transcript text. No failure class,
error-message contract, transcript timing or score was changed.

| Retained recovery evidence | SHA-256 |
| --- | --- |
| Exact classifier receipt | `5d16335ece3d7072aa762d692d37f96c499bfbf3c30eaa8d1b4a51900193456c` |
| Independent frozen terminal/stop proof | `c986411c22d70ec379659648a24422eef02478b98e89479b4c144d63b933f3fd` |

The unchanged terminal validator confirmed 72 attempts, 71 successes, one
unscored failure and 72 separately unpaired reference placeholders. The stopped
journal, models, initial seal, preplans and all completed inference remain intact.

A prospective continuation was prepared after the stop to finish Base metadata and run
only the eight unstarted grids: **3,816 calls**, comprising 648 development and
3,168 held-out calls. It must preserve both raw journals and an explicitly
verified logical projection, retain the stop provenance, and prohibit repeated
inference. The filename adapter may create a new byte-identical metadata receipt
under the consumer's canonical name after the unchanged classifier succeeds.
It may not alter raw transcripts or broaden failure admission. The original
ten-development-to-five-held-out barrier and all scientific gates still apply.

The continuation was sealed under
`081fef424c87316422758d49d5b6abb9324f56e0fc52d1c3457d0604f07ff4dd`.
Its actual read-only preflight verified all seven retained grids and source/hash
bindings before execution, without creating a receipt alias or starting ASR.
Launch seal
`4819733cb98728b71fae53f7c4aea514cea923267003e4e3663a1059d38ee258`
admitted only the unstarted grids at 10:02 UTC. No measured call was repeated.
The controller's real inherited classifier branch, unchanged classifier CLI,
byte-identical exclusive metadata alias and 7+8-grid accounting passed synthetic
integration checks before resumption.

Continuation-aware reporting and preservation wrappers retain the old tools
unchanged and record both actual executing sources and reused numerical cores.
All 41 scientific functions in the independent audit remain byte-identical.
Their joint freeze is
`b29333161b0131a986e23c971e57b901aafeca1c2e8039a425828a42c5554e93`;
the opaque preservation-adapter freeze is
`0f447d4f89e7e30a08c140b596a1dd66b1f33b56d209be3019e02e07a4cdab24`.
These records precede resumed inference. The logical final journal is explicitly
derived from two unchanged raw journals, with the actual stop retained as a
verified event and provenance. It is not a replacement for either raw journal.

## Joint held-out release

All ten preceding grids reached **1,386 terminal attempts: 1,385 completed and
one unscored failure** and were assessed before the held-out release. All eleven
artifacts advanced under the original fixed plan.

All five final held-out plans sealed together under
`24ef35dc480aa3817ac9298e72cb86480623119b1e85f26f069877a0e060902c`:

- Freeze created: 2026-11-09 **10:45:08.659947 UTC**.
- Family freeze accepted: **10:45:12.647935 UTC**.
- First held-out command: **10:45:12.663388 UTC**.

Held-out inference was in progress at this checkpoint. The failed Base development
call remains unscored, with its full planned aggregate coverage pending. No
candidate, setting, scorer, gain threshold or language floor changed after
development observations or the metadata stop.

## Completion and actual post-run audits

The final assessment closed at **2026-11-09 13:51:28.991494 UTC**; the continuation
journal's final event is **13:51:34.101796 UTC**. All fifteen unique grids are
terminal and assessed: **4,554 attempted, 4,553 successful, one failed/unscored**.
All **3,168 held-out calls succeeded**. Native parent pairs are **2,484/2,484**,
derived Q4 contrasts **828/828**, and **1,242** reference placeholders remain
separately unpaired. No inference was repeated. Base development German has
7/8 scored sources; its full CER/WER and corresponding full macros remain null.
Held-out family coverage is complete despite this incomplete development control.

The frozen journal projector verified both raw histories and published a new,
explicitly derived logical journal, retaining the original stop. The guarded
opaque preservation audit rehashed **1,029 frozen inputs** and inventoried
**72,969 retained output files**. Its outer guard closed normally in 20.926 seconds,
with exit zero, its owned session absent, no cancellation and no cleanup error.
Original model/native/CLI, audio/reference, timing and raw transcript evidence
remains intact; no reference or transcript semantic decoding occurred in hashing.

The actual summary adapter called the unchanged numerical builder; the old
builder's `main` was not executed. The original table projector produced all
495 language cohorts and 55 macro rows. The independent continuation-aware audit
passed **21,416 count/rate checks and 327 gate observations**: 279 true, 47 false
and one unknown, without coercing false/unknown results into passes. Both Small
and Turbo have frozen family decision **REJECT**, with rejection in known and
automatic modes. Detailed per-language quality, latency, RSS, load, workload RTF,
file sizes and remaining acceptance limits are published in the measured report.

| Completed protected evidence | SHA-256 |
| --- | --- |
| Original stopped raw journal | `72a096b9b51912569c9b37ddc8c4ac7098b4040eea1be96e337335c4b13196e5` |
| Final continuation raw journal | `c8b184bbaf4266899aaa11ad2bef025b8395ea7f7060ab885ef24417485237e2` |
| Derived logical journal | `604012932eec90b6e2ac6f1be0a2613bae5fa08afbe4d1c9846476a09e554882` |
| Journal projection receipt | `cfb3b333d24cdea3a93b6fa9a10b150d44d20b8a73ae1a90c2067aa4b7b6efc5` |
| Opaque preservation authority | `82149a50ce679bde1f18777d834d4430cfc6c9d9670095951765e4e876fe83d3` |
| Closed preservation guard | `ec271b760510c896b8d02b95b8441b8706cf2785849f1fe0393f2fc9f2ef7ce0` |
| Retained numeric summary | `6861461fadfaec0207d650da5ff04ce5a19e08f592e74c0f27c9cb948ac01e15` |
| Table-projection audit | `d304eb1c8b5cec1d28ca88c0963ce6e320aa2e55de0319b45ad7d4672ccd2728` |
| Independent count/gate/provenance audit | `69bd834cfd96dde4ddf8b1fd31335d200b8b63c33cabb465b6034dd8b834322d` |

Parent `02ee557` subsequently **passed full CI** in
[run 42616254880](https://github.com/moreaki/recscribe/actions/runs/42616254880):
native/frozen 87 tests in 15 suites; functional and TSan each 461 tests in 86
matching suites (458 passed, three existing matching opt-in skips, zero failures),
complete sanitizer evidence and Release. Its retained independent CI audit is
`c536986423071c9d54ec662e7759cbc41de01ec2fac5b465144d8a2c6a02204d`.
The supervisor fully reaped its owned group, with no retry. The healthy run
exercised no stall sampling; the intermittent hang is not proven fixed.

After all scientific audits, the updated parent was integrated into the round-4
branch while preserving `08584bd`, `6c43510` and the actual experimental history.
The conflict in the CI supervisor was resolved to the exact parent files already
reviewed and tested; publication files and all protected experiment inputs stayed
intact. Latest fetched origin/main remains `e9a6273`. Final publication still
requires current-head full CI; earlier tested SHAs do not pass a later head.
No GitHub PR merge, installed-app replacement, default or distribution change
occurred. The round-4 data is now consumed evaluation evidence, not fresh data
for selecting or tuning another recipe.

Publication checks verified local links, table widths, numeric displays, copy
hashes and ancestry. The whitespace check reports only three extra EOF blank
lines retained from byte-identical historical tool sources; those findings are
documented in the archive README. Curated reports and other added files pass
their whitespace check. No historical source was reformatted to obtain a pass,
and all mandatory validation gates remain unchanged.
