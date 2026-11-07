# Round 4 frozen artifacts and execution provenance

Status at this checkpoint: six actual derived artifacts exported; quality and
native numerical results **pending**. This is not evidence of an accuracy gain.
The [prospective protocol](weight-space-round4-protocol.md), committed at
`6c43510b0f168e9ded973d7f2dffc5096dc930f2` before inference, fixes the method and gates.
Earlier round artifacts, scores, gates and consumed datasets remain unchanged.

## Actual artifacts

All sizes below are actual model-file bytes. Original files remain read-only.
Each rotation edits only the declared attention Q/K/V rows, Q/V biases and
compensating O columns; headers, vocabulary and unselected byte regions are exact.
Official Q4 export validates header 2002, type 2, finite scales, every tensor's
shape/order/type/offset, and passthrough rules independently of the F16 parser.
Plain and rotated Q4 have identical layouts/sizes and identical unselected tensor
payloads. Rotation adds no parameter reduction or additional file saving.

| Family | Arm | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| Tiny | Untouched F16 reference | 77,691,713 | `be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21` |
| Base | Untouched F16 reference | 147,951,465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| Small | Original F16 | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| Small | Rotated F16 | 487,601,967 | `5ca99bcafe04287b475f318bfc3ec310bed1d7fad39b3fc8eb089c4021643ace` |
| Small | Plain Q4 | 145,458,015 | `f6099c17a4305c6d173ef90ab6f15150dcbb85332b7831313bf36a378d7c5a85` |
| Small | Rotated Q4 | 145,458,015 | `b5d141d1638f07ccca730cf918d37db95656caaf026fab73f09e271eb59b6931` |
| Turbo | Original F16 | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| Turbo | Rotated F16 | 1,624,555,275 | `28821c38bf056593f46af223424406b975464c7c3ee7bafd348e4bdd832f9b09` |
| Turbo | Plain Q4 | 473,992,235 | `2ceb779ca61ce46ed6e9aa43c4a0f8a89a37f683df3c0ba3119238fcd5852155` |
| Turbo | Rotated Q4 | 473,992,235 | `73229e9eedd0160c34cd4464ea3fa5682c8f6b25a4f20d5208642dae7011fb35` |
| Large-v3 | Untouched F16 reference | 3,095,033,483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |

Q4 saves **70.1687% Small /70.8233% Turbo** versus each original F16. Turbo Q4
is 13,609,732 bytes below Small F16, but its quality, runtime and memory tradeoff
still requires measurement. Actual download packaging, dependency/bundle
increments, startup/first-result latency and unified GPU memory remain unmeasured.
Untouched multilingual Tiny, Base and full Large-v3 remain separately hashed
references at 77,691,713 /147,951,465 /3,095,033,483 bytes.

## Tool and control identities

| Component | Exact identity |
| --- | --- |
| Rotation source | `fcf21056cc0c0b1b39d21d43139398efbcf794e948d8c89a78e5f260832bae30` |
| Official-export wrapper | `bf3f2ef5e00a4c06ef7fd4912c46dd2a0d50f7a381d45fff7cef6c5fae93c4e0` |
| GGML F16 parser | `11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3` |
| Attention assessor | `deda764f8f498849ea573e225bb2cdcc27cab338a85e6f78e8ca829cacdea61e` |
| Official whisper-quantize | `2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd` |
| Official whisper-cli v1.9.5 | `e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16` |
| Native source | `d1be6fde11ac6e0407606b4e42fe72d34add8037` |
| Untouched original control revision | `c214a8ed03f972a5a9cab64105145a67371b97b4` |
| Original control CLI | `9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6` |
| Unchanged comparison CLI revision | `a55b9ef1c3a5ab4ede43659e8c35c89001d0fc0f` |
| Comparison CLI | `5190e4d3849b8f5aa37ef7031d9557d6ebd17866c798b9c6412cba64b587c1c4` |
| Inspected owned-session guard | `7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c` |

Exports completed serially under the recording-priority guard, with six clean
owned-session shutdown records, finite 600-second limits, one numeric worker,
original pre/post hashes and retained plan/audit/log evidence. The generation
freeze precedes model edits. All eleven model files, eleven native files and both
CLIs were subsequently rehashed against their retained identities. No ASR or
model initialization occurred during these exports/inventory checks.

Host: Mac14,14 /Apple M2 Ultra, 24 CPU and 60 GPU cores, 64 GiB unified memory;
macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), Swift 6.4, Python 3.15.0,
NumPy 2.5.4. Detailed binary/library/software fingerprints remain protected with
the source/manifest receipts. Shared-desktop resource acceptance is uncontrolled.

## Fresh corpus completion and immutable records

The initial frozen acquisition produced all 72 development sources but only
142/144 held-out sources: Italian reached its 32 MiB archive-prefix limit.
Its original manifests, accepted sources and error list remain unchanged.
A separate prospective amendment selected exactly two new Italian held-out cases,
excluding the original seven consumed manifests plus both new partial manifests.
It allowed only the Italian test archive, a 64 MiB stream prefix, 128 MiB additional
network, 32 MiB output and 600 seconds. It used 36,198,400 network bytes; combined
actual acquisition was 408,135,060 bytes, within the initial 512 MiB aggregate.

The final metadata-only view contains **72 development +144 held-out sources**,
eight/sixteen per language. It references original protected paths and preserves
all accepted case objects, raw/prepared audio, reference bytes, timing and
provenance. No audio/reference copies, links or rewrites were created. Independent
opaque checks verified 216 unique source/reference identities, 432 unique
original/prepared audio hashes, all planned counts and source/resampling timing.
The 24 new published Swiss speaker/client IDs are disjoint across splits and from
46 consumed IDs. These metadata exclusions do not prove real-world participant
independence. FLEURS speakers and all sessions remain unknown.

Swiss published canton labels are development: BL 2, SG 2, AG 1, ZH 1, GR 1,
BE 1; held-out: SO 2, SG 4, ZH 2, BE 2, ZG 3, LU 1, TG 1, AG 1. These are
source metadata, without native dialect adjudication. Swiss speech targets
published written Standard German (Latin script); dialect spelling is separate
and unmeasured. FLEURS coverage is `de_de`/Latin, `fr_fr`/Latin, `it_it`/Latin,
`en_us`/Latin, `ar_eg`/Arabic, `cmn_hans_cn`/Simplified Chinese, `es_419`/Latin
and `pt_br`/Latin. Egyptian locale does not establish audible dialect approval;
Chinese here covers Mandarin/Simplified, Spanish Latin America, and Portuguese
Brazil. Broader regions/scripts remain pending.

| Protected record | SHA-256 |
| --- | --- |
| Initial acquisition freeze | `ff441bf4e1f055467af8ba2d9c54d9a89dc6d2ce3ec2d57d8e56bca8a27f118c` |
| Initial acquisition stop | `e17d3bd59b6fdeb8e4bdfdbb3a4a73d410cbf326cf8f1973bcba2bd2703b01c5` |
| Italian completion freeze | `7d0cfbcded8af2e6dc51e95b91fc5a8f04903faf7889c1d297e44756cdf73620` |
| Final development manifest | `4cbb275b0f440babe8ad993449f447db473e3fdf9929d6371061aabb41fbd670` |
| Final held-out manifest | `fd6e77f9b61967e30d8d3a6a18f67205eb79da7a77bc3eecda2fbab43bb3e4af` |
| Opaque integrity receipt | `557a1cbbd409c1bbe000d5a1f5584195112ae259537329046dbab5e89b4013ae` |
| Corpus-source receipt | `b95af38f5c55a1b9b896e8db47ed1ab9f3ccc92c7fdfdec13db7bef5dfdfba1c` |
| Artifact-family receipt | `2a393b2935f00defa275cdf935d737188b7fa4ee7605fae4d0af58c931966cab` |
| Eleven-model/runtime inventory | `5e1a251b7b43fb2f92ce7ce6bf5b126de8e2d89e739e4f780866664a26556c93` |
| Fifteen-stage pre-inference seal | `8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2` |

Held-out reference text remained semantically uninspected during candidate
preparation. The all-five final held-out settings freeze is still pending the
ten terminal panel/development assessments. Corpus v2/native/critical-content,
broader region/script/natural/switch/live/independent-channel and controlled
resource/product gates remain pending. No default, distribution or installed-app
change, and no automatic merge.

## Local validation at this checkpoint

Passed: rotation/algebra/ownership contracts 14, Q4 export/container/lifecycle
contracts 13, assessment contracts 32; all 197 offline quality contracts plus
12 GGML and 45 boundary/artifact/scope/supervisor/sanitizer-evidence contracts
(254 Python tests total). Source-boundary self/full checks and the scoped PCM
TSan probe passed: 20,000 buffers, zero owner overlap/corruption or diagnostics.
The scoped probe is not the full functional-app TSan suite.

The cached native/frozen suite passed 87 tests in 15 suites without rebaselining.
Both permission suites passed 15 tests (18 parameterized executions), zero failures
or runtime warnings. This validates the test-only watcher-completion follow-up to
the earlier failed CI assertion; production permission behavior is unchanged.
Private orchestration contracts passed 37; native-load-only contracts passed 8
using synthetic children, without initializing a real model. Actual packaged
assessor CLI writes passed for Turbo and Base; actual comparison-CLI dry runs
accepted all 216 Turbo and 54 Base panel cells without inference.

Actual native model initialization, numerical/quality inference and required
current-head full functional/TSan/Release CI remain pending. The previous green
implementation head does not pass this head. Full offline evidence is protected
under `offline-validation-v1`, receipt
`59286fc666d498d16cc7f9cf5e975d99c860f87fac6285634ebf23112e63a6e5`.
