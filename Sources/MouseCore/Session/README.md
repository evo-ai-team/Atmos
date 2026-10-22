# Voice sessions and accepted task context

State shared across speech recognition and computer-task execution. These types have no UI, networking, or microphone dependencies.

| File | Responsibility |
| --- | --- |
| `WakeSession.swift` | Tracks standby, wake activation, cumulative recognition, and completed utterances. |
| `VoiceControl.swift` | Recognizes an initial, unquoted `stop` as the immediate local sleep control. |
| `CommandContext.swift` | Keeps chronological accepted commands, resolved goals, dispatch descriptions, and outcomes for follow-up context. |
| `TaskSteeringState.swift` | Tracks the current accepted goal, amendments, and actions actually dispatched. |
| `CaptureStamp.swift` | Restricts speculative screenshot reuse to the originating utterance, task generation, foreground process, and freshness window. |

## State boundaries

`WakeSession.receive` can activate, deactivate, or update preview text. It does not emit ordinary commands; `finishUtterance` is called after the speech layer has completed its final pass. Task execution changes metadata without splitting an unfinished utterance. Recognition restarts must explicitly choose whether to preserve pending words.

Accepted context is history, not new authorization. `CommandContext` retains exact accepted words, and `TaskSteeringState` records only dispatched actions. A completed dispatch does not prove its intended UI effect. When a goal is replaced, uncertain old dispatches remain physical-state context rather than pending work.

Tests in `Tests/MouseCoreTests/Session` cover wake/control parsing, utterance continuity, chronological context, goal amendments, interruption, and capture freshness.
