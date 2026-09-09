# Text-processing latency

## Baseline and cause

The reported text job took 133.7 seconds for ten sequential generation requests.
Its 226 segments were cut into nine 24-segment blocks and one 10-segment block,
despite containing only 700–1,912 source characters per block. Source text was
not needed in diagnostics and is not included here.

## Native Swift change (0.2.6)

- Cloud batches now use the full serialized prompt's UTF-8 size (including IDs,
  flags, and JSON escaping), a source-scalar safety limit, and estimated output
  headroom. The segment limit is a secondary ceiling of 192, not the primary
  24-segment split. Policies are centralized in `IntelligencePolicy`.
- The default prompt limit is 12,000 bytes. Output planning allows two estimated
  UTF-8 bytes per output token, a twofold expansion of the serialized segment
  results, and 1,024 reserved output tokens when requesting summary notes.
  This is a heuristic, **not a model-specific tokenizer or a guarantee that a
  response fits**. Provider output limits and strict validation still reject
  incomplete/invalid output; no automatic paid retries or silent fallback.
- At most two cloud generation requests run concurrently. A completed request
  releases one slot; the implementation does not create a task for every batch
  at once. Local inference remains serial with its existing 24-segment ceiling
  to avoid competing model allocations and preserve its smaller context budget.
- Workers write independent indexed input/raw artifacts. The parent task alone
  updates progress and merges validated results in original source order.
  Cancellation or failure cancels sibling requests and does not publish a final
  transcript. A request already accepted by a provider may still incur charges.
- Original audio, raw ASR, segment IDs, timestamps, and parent transcripts remain
  unchanged. Summaries remain source-linked per-block notes, not a new cross-block
  synthesis. Stereo duplication is a separate issue, not fixed by batching.

## Timing and reproducibility

`ai-batch-plan.json` records batch sizes and concurrency/budget policy without
text. Existing `manifest.json` records completed/total blocks, elapsed time,
completion timings and terminal status; each derivation retains per-request
duration, usage counts, input/raw hashes, and indexed raw-response provenance.
The UI now says “Text blocks: N/M completed”, which remains truthful when requests
finish out of order.

Run the local, no-network comparison with:

```sh
swift test --package-path core -c release --filter TextBatchingTests
```

On the local arm64 development Mac, the initial Release test run used 226
synthetic short segments with 40 ms injected latency per request:

| Policy | Requests | Peak concurrent | Elapsed |
| --- | ---: | ---: | ---: |
| Baseline-shaped: 24 segments, serial | 10 | 1 | 0.539 s |
| Budgeted cloud batches | 3 | 2 | 0.164 s |

These single-run **mock** times include planning/artifact overhead and demonstrate
scheduling, not real cloud latency, token costs, or transcript quality. The
baseline-shaped test retains the new safety checks, so it is not a binary-level
benchmark of the previous release. Run logs remain under ignored `Build/`.

Tests cover Unicode and JSON overhead, output budgets, oversized segments,
out-of-order completion, deterministic text/summary/provenance ordering, monotonic
progress, local serialization, bounded cloud concurrency, cancellation and failure.
Existing canonical-schema and Python-reference export parity tests remain in place.

Real-provider speed and quality comparison requires an explicitly approved new
request. Do not extrapolate the mock ratio to the user's 133.7-second run or
automatically resend private transcripts to benchmark it.

## Local build verification

Release 0.2.6 (206) builds successfully with Swift 6 and complete concurrency
checking. The test candidate is
`Build/TextBatchingRelease/Products/Release/RecScribe.app`; the running installed
copy is not replaced by this build.

- Architecture: 64-bit arm64; bundle: `com.moreaki.recscribe`.
- Team: `CDS4KLP8GT`; authority: Apple Development, Roberto Nibali.
- Hardened runtime present; own-app Keychain group preserved; no
  `com.apple.security.get-task-allow` entitlement.
- Strict/deep code-signature verification passes. This is a local development
  build, **not Developer ID signed or notarized**; the distribution-release
  audit correctly rejects its Apple Development authority. No notarization,
  stapling, distribution zip, or public upload was performed.
- Executable SHA-256:
  `ed404bc1aa3511fbe5d856293825720bfbdbd36ee4d6fa2f47c75133635744bf`.
- Verification: 31 core tests across five suites (including Python-reference
  schema/export parity) and 389 app tests across 56 suites passed. The real
  provider and a manual restart of the user's running app were not exercised.
