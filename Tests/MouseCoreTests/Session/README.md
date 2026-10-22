# Session tests

Tests of `Sources/MouseCore/Session`, using in-memory state and synthetic timestamps.

- `WakeSessionTests` covers wake phrases, quoted content, immediate stop, cumulative recognition, and utterances spanning task execution.
- `VoiceControlTests` checks the narrow local stop boundary.
- `CommandContextTests` checks complete chronological history, referents, outcomes, and JSON escaping.
- `TaskSteeringStateTests` checks accepted amendments, replacement goals, dispatch records, and uncertain interrupted actions.
- `CaptureStampTests` checks that a speculative capture cannot cross utterance, task, process, or freshness boundaries.
- `MousePreferencesTests` verifies persisted behavior/audio choices, migration defaults, and invalid sensitivity values using isolated preference suites.

Run all tests with `swift test` from the project root, or focus a type with a filter such as `swift test --filter WakeSessionTests`.

Changes to recognition must preserve the distinction between preview and final command delivery. Context tests should continue to distinguish accepted user intent, an attempted input dispatch, and a verified UI result.
