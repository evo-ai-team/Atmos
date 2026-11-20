# Session tests

Tests of `Sources/MouseCore/Session`, using in-memory state and synthetic timestamps.

- `WakeSessionTests` covers wake phrases, quoted content, immediate stop, cumulative recognition, and utterances spanning task execution.
- `VoiceControlTests` checks the narrow local stop boundary.
- `CommandContextTests` checks complete chronological history, referents, outcomes, and JSON escaping.
- `QuestionMemoryTests` covers full Q&A retention, command isolation, history snapshots, short follow-up input to Luna, and the compact answer projection used by Decisions. Transport fixtures are offline; they verify context delivery, not live model intent judgment.
- `TaskSteeringStateTests` checks accepted amendments, replacement goals, dispatch records, and uncertain interrupted actions.
- `ActionHistoryTests` checks exact payloads alongside descriptions, observation actions, native target details, and dispatch/cancellation transitions scoped to their execution.
- `CaptureStampTests` checks that a speculative capture cannot cross utterance, task, process, or freshness boundaries.
- `MousePreferencesTests` verifies persisted behavior/audio choices, migration defaults, and invalid sensitivity values using isolated preference suites.

Run all tests with `swift test` from the project root, or focus a type with a filter such as `swift test --filter WakeSessionTests`.

Changes to recognition must preserve the distinction between preview and final command delivery. Context tests should continue to distinguish accepted user intent, an attempted input dispatch, and a verified UI result.
