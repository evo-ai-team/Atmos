# Voice sessions and accepted task context

State shared across speech recognition and computer-task execution. These types have no UI, networking, or microphone dependencies.

| File | Responsibility |
| --- | --- |
| `WakeSession.swift` | Tracks standby, wake activation, cumulative recognition, and completed utterances. |
| `VoiceControl.swift` | Recognizes an initial, unquoted `stop` as the immediate local sleep control. |
| `CommandContext.swift` | Keeps accepted commands, resolved goals, dispatch descriptions, outcomes, and question/answer exchanges for conversational follow-ups. |
| `TaskSteeringState.swift` | Tracks the current accepted goal, amendments, and actions actually dispatched. |
| `ActionHistory.swift` | Keeps session-local diagnostic rows with the model's description, exact computer or native accessibility payload, and dispatch status for the Actions tab. |
| `CaptureStamp.swift` | Restricts speculative screenshot reuse to the originating utterance, task generation, foreground process, and freshness window. |
| `MousePreferences.swift` | Persists the model pipeline, speech sensitivity, and optional second transcription pass in local preferences. |

## State boundaries

`WakeSession.receive` can activate, deactivate, or update preview text. It does not emit ordinary commands; `finishUtterance` is called after the speech layer has completed its final pass. Task execution changes metadata without splitting an unfinished utterance. Recognition restarts must explicitly choose whether to preserve pending words.

Accepted context is history, not new authorization. `CommandContext` retains exact accepted words, and `TaskSteeringState` records only dispatched actions. A completed dispatch does not prove its intended UI effect. When a goal is replaced, uncertain old dispatches remain physical-state context rather than pending work.

`CommandContext.recordAnswer` stores each question with both the brief and full reply, including answers received during an active task. Exchanges remain ordered and record how many commands preceded them; recording one never alters command state. Luna receives full session replies so a follow-up can reference details omitted from the notch. Decisions receives the last three questions and brief answers to recognize and route follow-ups. History stays in memory until exit and participates in the benchmark context's existing save/restore.

`ActionHistory` is a separate, in-memory inspection log retained across tasks. It includes observation and wait actions, preserves full text and coordinates, and records native accessibility operations with their actual snapshot-scoped target. `Dispatched` confirms only that the executor returned; interrupted actions stay `Uncertain` even if a late return arrives. It does not detect loops or authorize further actions.

Tests in `Tests/MouseCoreTests/Session` cover wake/control parsing, utterance continuity, chronological context, goal amendments, interruption, and capture freshness.
