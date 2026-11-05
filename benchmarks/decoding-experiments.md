# Decoding and terminology experiments

The unchanged control is the source revision named by the experiment manifest,
run with its retained CLI binary and hash. It passes `-tp 0 -mc 0`; search and
temperature fallback otherwise inherit the selected whisper.cpp runtime. In the
inspected installed runtime, whisper.cpp 1.9.5, help advertises beam size 5, best
of 5 and temperature increment 0.2. Do not describe this control as greedy or as
having no fallback. Retain the actual runtime help/version and hashes with each
experiment; newer binaries may have different defaults.

`--whisper-profile /absolute/private/profile.json` opts a native final job into
the validated profile. The experiment matrix accepts that file through a
candidate's `settings` path. A missing profile preserves the control. Existing
saved app settings select the control; this phase does not migrate them to an
unmeasured candidate. Live callers can supply the same profile plus capabilities
and version captured at worker startup; ordinary app live preview uses the
control. Live replay in the matrix remains unsupported until its real adapter
is connected; an arguments test is not a replay quality measurement.

For isolated development comparisons, change one intervention at a time:

```json
{"schema_version":"1.0","beam_size":3}
```

```json
{"schema_version":"1.0","no_fallback":true}
```

```json
{"schema_version":"1.0","context_tokens":64}
```

These are executable experiment examples, not selected settings or claimed
improvements. `beam_size` and `best_of` accept 1–8, temperature and its increment
accept 0–1, and `context_tokens` accepts 0–224. Unsupported help flags, unknown
fields and conflicting fallback controls fail before recognition. Every profile
retains exact effective overrides, inherited-default status and private command
arguments in the job evidence. The exact profile and its hash are retained.

Optional `terminology` is exact user-supplied text, at most 1024 UTF-8 bytes,
with a positive `context_tokens` value. It is a hint, never recognized speech;
the adapter does not prepend it to the transcript. whisper.cpp 1.9.5 conditions
on prompts only with positive max-context. Test terms absent from the audio to
measure invented content, alongside terms that are spoken. Private terminology
belongs in the private profile and local job evidence, never application logs.

Context is bounded within one native invocation. No previous-window text is
carried between invocations, so previous recordings, independent final channels,
failed attempts, changed models or changed language decisions cannot contribute
hidden text state. Stateful cross-window conditioning is **pending**, including
source/channel/cursor reset integration and isolated multilingual evaluation.
Within a final long invocation, upstream history is not a language-switch
detector; context candidates therefore need explicit code-switching review.

Before selecting any candidate, run paired development cases for all nine
languages and the required five-model matrix. Review omissions/insertions,
repetition, names, numbers, negation, invented speech, dialect preservation and
latency/resource budgets separately. Freeze profile bytes and predeclared budgets
before held-out evaluation. No default promotion or quality claim is supported
by synthetic configuration tests or missing corpus rows.

The pinned upstream behavior was checked in [CLI parameter
mapping](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/examples/cli/cli.cpp#L1136)
and [prompt context
handling](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp#L6499).
Preserve original references and frozen contracts; never rebaseline for a
candidate. See [speech/language experiments](speech-language-experiments.md) for
the independent policies composed through the same profile.
