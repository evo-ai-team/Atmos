# Speech state and policies

Speech decisions that do not depend on microphone hardware or Apple's recognition objects. The macOS adapters in `Sources/Mouse/Speech` provide text, audio positions, and monotonic timestamps.

| File | Responsibility |
| --- | --- |
| `SpeechTranscriptState.swift` | Replaces volatile result ranges, tracks consumed audio, and validates endpoint candidates. |
| `SpeechSensitivity.swift` | Maps the sensitivity slider to a bounded speech-activity threshold without changing audio gain. |
| `SpeechAudioHistoryPolicy.swift` | Retains speech and leading context; rejects final replays with uncertain coverage. |
| `SpeechActivityGate.swift` | Tracks captured speech not yet consumed by recognition and clears idle activity. |
| `SpeechBoundarySynchronizer.swift` | Serializes advancement of a live analyzer's boundary and coalesces newer requests. |
| `SpeechRecoveryState.swift` | Limits retries within one microphone-enable generation. |
| `SpeechScreeningQueue.swift` | Screens finalized utterances in order and ignores results from cancelled generations. |

## Boundaries

A transcript candidate is a proposal, not a command. Any new text or speech invalidates it, and only the exact current candidate may commit. Audio positions (`start`, `end`, `through`) and wall-clock-independent activity times (`startedAt`, `lastSpeechAt`) must not be interchanged.

When the optional second recognition pass is disabled, `commitLiveTranscript` commits the current endpoint text only after checking the raw microphone activity watermark, converted-audio progress, and candidate identity. It consumes the same audio boundary as replay mode, so late results cannot resubmit old words. Sensitivity defaults to 0.5 (the original 0.006 RMS threshold); higher values lower the threshold logarithmically to detect quieter audio. Nonfinite settings restore the default and out-of-range values clamp to 0–1.

Raw activity does not authorize interruption of a computer task. `SpeechScreeningQueue` delivers accepted speech only after the checker resolves its intent. Cancellation invalidates generations as well as tasks because external work may return after cancellation.

An optional `PipelineTiming` follows each queued utterance. `Incoming command queue` and `Intent and first-action selection` are separate spans; the selected model checks intent and prepares the first operation together. `onCheckStarted` associates that work with its trace after queue wait ends. Accepted traces pass to the command pipeline without closing. Ignored or failed checks close their trace, and cancellation immediately closes both current and queued traces even if an old transport returns later. A reentrant acceptance callback cannot accidentally cancel the trace it has just received.

The synchronizer's `awaitIdle()` means requested boundary operations have finished; it does not mean a separate results consumer has caught up. Audio history independently retains detected speech while waiting for delayed recognition.

Tests are in `Tests/MouseCoreTests/Speech`. They use synthetic timestamps and controlled asynchronous completions so timing, cancellation, and ordering can be checked without a microphone or speech-model download.
