# Speech state and policies

Speech decisions that do not depend on microphone hardware or Apple's recognition objects. The macOS adapters in `Sources/Mouse/Speech` provide text, audio positions, and monotonic timestamps.

| File | Responsibility |
| --- | --- |
| `SpeechTranscriptState.swift` | Replaces volatile result ranges, tracks consumed audio, and validates endpoint candidates. |
| `SpeechAudioHistoryPolicy.swift` | Retains speech and leading context; rejects final replays with uncertain coverage. |
| `SpeechActivityGate.swift` | Tracks captured speech not yet consumed by recognition and clears idle activity. |
| `SpeechBoundarySynchronizer.swift` | Serializes advancement of a live analyzer's boundary and coalesces newer requests. |
| `SpeechRecoveryState.swift` | Limits retries within one microphone-enable generation. |
| `SpeechScreeningQueue.swift` | Screens finalized utterances in order and ignores results from cancelled generations. |

## Boundaries

A transcript candidate is a proposal, not a command. Any new text or speech invalidates it, and only the exact current candidate may commit. Audio positions (`start`, `end`, `through`) and wall-clock-independent activity times (`startedAt`, `lastSpeechAt`) must not be interchanged.

Raw activity does not authorize interruption of a computer task. `SpeechScreeningQueue` delivers accepted speech only after the checker resolves its intent. Cancellation invalidates generations as well as tasks because external work may return after cancellation.

An optional `PipelineTiming` follows each queued utterance. Queue wait and intent screening are separate spans; `onCheckStarted` associates the checker with its trace after queue wait ends. Accepted traces pass to the command pipeline without closing. Ignored or failed checks close their trace, and cancellation immediately closes both current and queued traces even if an old transport returns later. A reentrant acceptance callback cannot accidentally cancel the trace it has just received.

The synchronizer's `awaitIdle()` means requested boundary operations have finished; it does not mean a separate results consumer has caught up. Audio history independently retains detected speech while waiting for delayed recognition.

Tests are in `Tests/MouseCoreTests/Speech`. They use synthetic timestamps and controlled asynchronous completions so timing, cancellation, and ordering can be checked without a microphone or speech-model download.
