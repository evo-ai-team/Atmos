# Speech tests

Deterministic tests of `Sources/MouseCore/Speech`. Audio and activity times are supplied directly; no microphone, network, or Apple speech model is required.

- `SpeechTranscriptStateTests` checks volatile range replacement, silence endpoints, delayed conversion, and invalidated candidates.
- `SpeechAudioHistoryPolicyTests` checks retention and replay coverage, including quiet missing command prefixes.
- `SpeechActivityGateTests` checks raw activity visibility and when idle activity may be consumed.
- `SpeechBoundarySynchronizerTests` checks serialized boundary advancement, coalescing, cancellation, and failure.
- `SpeechRecoveryStateTests` checks retry limits and enable-generation invalidation.
- `SpeechScreeningQueueTests` checks ordered acceptance and stale results, including callbacks that cancel or enqueue work. Controlled-clock checks distinguish queue wait from screening and verify cancellation freezes old traces without closing a newly accepted command's trace.

Run the complete suite with `swift test` from the project root. To focus on this domain, use `swift test --filter Speech`.

The asynchronous tests control completion explicitly where order matters. Keep assertions about observable callbacks and state rather than assuming task scheduling order or adding arbitrary sleeps. Hardware capture and final Apple recognition are exercised by the diagnostic tools in `Sources/Mouse/Diagnostics`.
