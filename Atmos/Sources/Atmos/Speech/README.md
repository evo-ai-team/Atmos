# Speech runtime

The macOS microphone and Apple Speech integration. `VoiceInput` exposes status, preview, and finalized-command callbacks to the application. Pure transcript and session decisions live in `AtmosCore/Speech` and `AtmosCore/Session`.

| File | Responsibility |
| --- | --- |
| `VoiceInput.swift` | Owns the microphone lifetime, live recognition, endpoint timer, final replay, and bounded recovery. |
| `SpeechAudioFeed.swift` | Copies microphone buffers, meters raw audio, and converts a bounded stream to the recognizer's format. |
| `SpeechAudioPacket.swift` | Carries owned, immutable audio with analyzer time and monotonic capture time. |
| `SpeechUtteranceFinalizer.swift` | Runs a separate, finite recognition pass and waits for its final results. |
| `SpeechRuntimeSetup.swift` | Selects the English locale and reserves or installs speech assets under an explicit download policy. |
| `KrispMicrophoneCapture.swift` | Keeps a short wake buffer locally, switches the tap on activation, and pairs isolated frames with the original capture times. |
| `KrispVoiceIsolationSession.swift` | Opens a hosted VIVA Pro session using a short-lived token and streams 32 kHz mono signed PCM. |
| `KrispPCMFramer.swift` | Assembles and splits PCM into 30 ms frames across arbitrary buffer boundaries. |

## Data flow

The audio tap copies its buffer before returning. The conversion worker gives each packet to `VoiceInput` for history retention before yielding it to the live analyzer. Live words update the preview and detect wake/stop; ordinary commands wait for silence and, by default, an accurate replay of the retained audio.

### Optional Krisp VIVA Pro isolation

When enabled, standby recognition runs on this Mac and retains up to eight seconds of recent microphone audio in memory. A recognized wake opens a hosted session and seeds it from the beginning of that wake utterance, including a command spoken in the same breath. If Apple attributes the wake to old standby silence, the service receives a bounded interval beginning up to two seconds before the first local wake evidence. The first finalized isolated utterance must then include the complete wake phrase before a command can run. Manual activation starts with fresh audio. A new Apple analyzer receives the isolated samples, and its endpoint detector and final replay share those same samples. The sensitivity threshold applies to isolated audio during the active session.

The sender and receiver stream concurrently. The receiver maps output samples back to capture time, and finalization waits until the service has processed the audio already captured when the turn appeared quiet. Capture loss and isolation stalls are monitored independently. Sleep, microphone pause, credential changes, and transport failures close the socket and discard unfinished work. A new wake or manual activation opens a fresh session.

`VoiceInput.audioSensitivity` accepts 0–1, with 0.5 preserving the original 0.006 RMS activity threshold. Higher sensitivity detects quieter speech. This changes endpoint/activity detection only: it never amplifies or filters microphone samples. The feed updates its threshold under the same lock as the audio meter. `secondPassEnabled` defaults to true and is sampled at each endpoint; switching it never interrupts a replay already running. When off, the current live transcript commits immediately after the same speech-activity, audio catch-up, candidate-identity and lifecycle checks. Both paths advance the independent live analyzer boundary and use the same wake/stop handling.

A replay snapshots its candidate, audio, and provisional text together. Before accepting its result, `VoiceInput` rechecks raw speech activity, conversion progress, retained coverage, and candidate identity. Committing also advances the independent live analyzer boundary so subsequent coarse results cannot hide new words behind consumed audio.

Each endpoint creates a `PipelineTiming` trace starting at the last detected speech activity. It records the actual endpoint wait and whether the second pass ran. Replays also record analyzer setup, analysis, analyzer finalization, any remaining final-results wait, and commit validation; live-only mode records its own fast commit validation without a replay span. `onTimingStarted` runs before speculative-capture callbacks so capture and speech share the same trace. Accepted commands keep it open for screening and computer control; ignored, invalidated, failed, and cancelled utterances close it. The results-wait span measures only the additional wait after analyzer finalization because results are consumed concurrently with analysis.

## Invariants

- Engine callbacks carry a lifecycle ID. Shutdown invalidates it before cancelling work, preventing late results from reviving an old microphone session.
- Captured buffers are never mutated after publication. Only the conversion worker owns the converter; a lock protects meter and stop state shared with the audio tap.
- Analyzer times are relative audio positions. Capture/activity times use system uptime. Their distinct purposes are documented in `SpeechAudioPacket` and `SpeechTranscriptState`.
- Audio overflow or a stale candidate cannot submit text. When replay is enabled, missing replay coverage also rejects the utterance; live-only mode deliberately uses the first recognizer's stable endpoint text.
- Session recognition boundaries reset before command callbacks, which may synchronously change task state.

`Sources/Atmos/Diagnostics` exercises this runtime without starting the normal application. Deterministic state coverage is in `Tests/AtmosCoreTests/Speech` and `Tests/AtmosCoreTests/Session`; microphone permissions, routing, and Apple model behavior require macOS integration checks.
