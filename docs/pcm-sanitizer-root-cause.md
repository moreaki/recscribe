# PCM storage reuse and Thread Sanitizer (#83)

The PR78 diagnostic is reproducible without `AudioRecorder`, `WAVWriter`, capture,
audio files, or permissions. It arises when AVFoundation-managed PCM sample storage is
reused for a **new buffer lifetime** after the previous reader and owner have
finished, while TSan retains the preceding lifetime's sample-read history.

## Controlled reproduction

`scripts/diagnostics/pcm-storage/main.swift` fills synthetic stereo Float32 PCM
on the producer and reads it on one serial queue. A strong transferred owner and
`withExtendedLifetime` cover all raw reads. Separate observational atomic flags
record reader completion and object/storage release. The address history checks
every sample, including partially overlapping pool allocations, before reuse.
History retains no PCM owners, is bounded to 512 generations / 65,536 sample
addresses, and exceeds the 64-reader admission bound.

The program validates every read sample against its submitted generation and
checks the aggregate checksum. It asserts that storage is never assigned to a
new buffer while the previous owner or reader is alive.

Three modes run the same producer/reader workload:

| Mode | Allocation | Reader-completion synchronization | Result |
| --- | --- | --- | --- |
| `framework` | `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` | Observational relaxed flags | Reproduces the same producer-write / previous-reader TSan warning despite zero live-owner overlaps and zero changed samples |
| `fenced` | Same framework constructor | Release/acquire on the **reader's** completion flag before address reuse | No diagnostic, with storage reuse still exercised |
| `owned` | Actual `SampleBufferFixtures.makePCMBuffer` from PR85 | Observational relaxed flags, no additional hand-off fence | No diagnostic, with storage reuse still exercised |

The acquire/release control must publish completion on the reader. The final
object release may occur on the producer after the reader drops its reference;
putting a synchronization marker only in the deinitializer does not necessarily
publish the reader's accesses.

The constructor comparison identifies an allocation/lifetime visibility boundary
in AVFoundation-managed sample reuse, rather than a concurrent read/write of a
live recording buffer. The synchronization control independently establishes
that making the retired reader visible removes the diagnostic without changing
the allocator. This conclusion concerns this reproduced diagnostic; it does not
identify a private AVFoundation allocator implementation.

This is consistent with [TSan's documented limitation for non-instrumented
libraries](https://github.com/google/sanitizers/wiki/ThreadSanitizerCppManual#non-instrumented-code):
missing synchronization/lifetime visibility can produce false positives. The
[no-copy PCM initializer](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/init%28pcmformat%3Abufferlistnocopy%3Adeallocator%3A%29-9iwe7)
lets the fixture make its sample allocation and release explicit. PR85 already
applies that fix and verifies queued-owner lifetime and exact WAV bytes.

The investigation reproduced locally on macOS 26.6.2 with Xcode 27.2. The original
CI report was on macOS 27.0.1, so an OS-version difference is not required to
trigger it. No SDK upgrade, production serialization, extra capture-path copy,
suppression, or reference rebaseline is needed.

Observed bounded 100,000-buffer runs (each checksum `198400000`):

| Mode | Reused sample addresses | Live-owner overlaps | Changed buffers | TSan warnings |
| --- | ---: | ---: | ---: | ---: |
| `framework` | 12,799,648 | 0 | 0 | 1 |
| `fenced` | 12,777,368 | 0 | 0 | 0 |
| `owned` | 12,766,976 | 0 | 0 | 0 |

Counts of reused addresses vary with scheduling; the invariants and warning
classification are the relevant results. Peak tracked addresses in these runs
were 304, 3,120 and 10,368 respectively, below the fixed 65,536 limit.

## Repeating the experiment

```sh
# Positive regression: actual fixed fixture, also run in CI.
python3 scripts/check-pcm-storage.py --mode owned --buffers 100000 --output-dir /tmp/pcm-owned

# Synchronization control: framework allocation remains unchanged.
python3 scripts/check-pcm-storage.py --mode fenced --buffers 100000 --output-dir /tmp/pcm-fenced

# Diagnostic negative control: intentionally exits nonzero if the warning recurs.
python3 scripts/check-pcm-storage.py --mode framework --buffers 100000 --output-dir /tmp/pcm-framework
```

The negative control is a diagnostic experiment, never a passing production CI
test or a sanitizer suppression. Each positive mode must exit zero, observe
address reuse, and report `live_owner_overlap=0`, `corrupt_buffers=0`, and
`checksum=198400000` for 100,000 buffers. A runtime that does not reproduce the
framework warning does not invalidate the positive fixture regression.

## Preventing misleading green CI

PR78's full sanitizer host emitted the warning, restarted, and printed a later
partial-suite pass. `xcodebuild` nevertheless returned zero. CI now captures the
complete sanitizer log, makes the sanitizer run blocking, and checks its exported
summary against the functional run. Warnings, host restarts, failed/missing
results, missing completion markers, and differing test counts all fail the job.
The raw log and diagnostics are retained as artifacts. The gate's regression
tests include the original warning and a restarted partial-suite pass.

These checks run after local UI preview availability; they do not alter the fast
manual-review workflow in `AGENTS.md`.
