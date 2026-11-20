# Speech tests

Deterministic tests of `Sources/AtmosCore/Speech`. Audio and activity times are supplied directly; no microphone, network, or Apple speech model is required.

- `SpeechTranscriptStateTests` checks volatile range replacement, silence endpoints, delayed conversion, and invalidated candidates. Live-only commits are checked for new speech, late revisions, pending conversion, lifecycle resets, and duplicate delivery.
- `SpeechSensitivityTests` checks the unchanged default activity threshold, slider direction and bounds, and recovery from invalid persisted values.
- `SpeechAudioHistoryPolicyTests` checks retention and replay coverage, including quiet missing command prefixes.
- `SpeechActivityGateTests` checks raw activity visibility and when idle activity may be consumed.
- `SpeechBoundarySynchronizerTests` checks serialized boundary advancement, coalescing, cancellation, and failure.
- `SpeechRecoveryStateTests` checks retry limits and enable-generation invalidation.
- `SpeechScreeningQueueTests` checks ordered acceptance and stale results, including callbacks that cancel or enqueue work. Controlled-clock checks distinguish queue wait from screening and verify cancellation freezes old traces without closing a newly accepted command's trace.

Run the complete suite with `swift test` from the project root. To focus on this domain, use `swift test --filter Speech`.

The asynchronous tests control completion explicitly where order matters. Keep assertions about observable callbacks and state rather than assuming task scheduling order or adding arbitrary sleeps. Hardware capture and final Apple recognition are exercised by the diagnostic tools in `Sources/Atmos/Diagnostics`.
