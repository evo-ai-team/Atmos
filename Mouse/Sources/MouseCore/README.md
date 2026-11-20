# Testable core

MouseCore contains value types, state transitions, and model clients. It does not capture a screen, open a microphone, press a key, or own native accessibility handles.

| Directory | Responsibility |
|---|---|
| [Accessibility](Accessibility/README.md) | Bounded tree traversal, serializable elements, and geometry. |
| [Actions](Actions/README.md) | Action/result data, native choices, and dispatch summaries. |
| [Diagnostics](Diagnostics/README.md) | Bounded command timelines, stage durations, and first-input latency. |
| [Inference](Inference/README.md) | Selection, action planning, and speech-screening protocols. |
| [Session](Session/README.md) | Wake/Stop behavior, accepted history, and task amendments. |
| [Speech](Speech/README.md) | Transcript assembly, audio-retention policy, screening order, and recovery. |
| [Usage](Usage/README.md) | Usage counters and storage migration. |

Directories share one module so domain types remain simple values rather than service wrappers. Network clients accept injected transports for offline tests. Time-sensitive state takes explicit timestamps or cancellation identities where needed. Tests mirror these domains under [Tests/MouseCoreTests](../../Tests/MouseCoreTests/README.md).
