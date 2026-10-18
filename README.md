# Mouse

A native Mac voice interface for clicking, typing, scrolling, and navigating apps. Mouse lives in the menu bar; its everyday interface expands directly from the notch using native Liquid Glass, a black-to-glass gradient, and filled upper corners. The panel does not take keyboard focus or intercept clicks.

Requires an Apple silicon Mac running macOS 26 or later, full Xcode 27 to build, and an OpenAI API key with access to GPT-6 Luna. Voice uses Apple's on-device **SpeechAnalyzer / SpeechTranscriber** with English (US) model assets. Speech transcription needs no API key or usage fees; the OpenAI key is only for Luna. The action model configuration remains GPT-6 Luna, Fast service, and low reasoning.

## Build and open

From this folder:

```sh
./Scripts/build.sh
open ../Mouse.app
```

The app, executable, Xcode project, and Swift package are named **Mouse**. The default build destination is `Mouse.app`; pass another `.app` path to the build script to change it. The existing bundle identifier and Keychain service remain stable to preserve the saved connection. Usage history is copied into Mouse's support directory on first launch without overwriting an existing counter.

The scripts respect `DEVELOPER_DIR`, otherwise use the selected full Xcode or `/Applications/Xcode.app`. They do not change global `xcode-select` settings. Build products use the workspace's `work/` folder when available, otherwise a temporary directory. Override with `MOUSE_BUILD_DIR` or `MOUSE_TEST_BUILD_DIR`.

## Setup and use

Open **Settings…** from Mouse's menu-bar icon. Settings also opens on launch when setup is incomplete.

1. Enter your OpenAI API key and select **Save key**. The key stays in macOS Keychain. If an updated build shows **Needs authorization**, select **Reconnect saved key** and approve macOS's Keychain authorization prompt, or supply another key.
2. Use **Allow** to grant Screen Recording and Accessibility in System Settings. Reopen Mouse if macOS requests it.
3. Select **Enable voice** and grant Microphone access. Mouse prepares Apple's speech model and downloads its assets if needed, showing setup status. The newer engine does not require the legacy Speech Recognition permission. On subsequent launches, Mouse starts local wake-word monitoring automatically when microphone access is already authorized. **Open Mouse at login** is optional.

Say **“Hey Mouse, open Chrome.”** The only wake phrase is **“Hey Mouse”**. Activation persists between commands until you say **“stop”**; silence does not expire the session.

While active and ready, Mouse displays the live transcript and sends every completed utterance with the screen context to Luna. There is no local command vocabulary, app-name list, or grammar filter. Luna interprets natural requests such as “make this bigger” or “organize my files” and decides whether to return structured actions, ask for required task information, or silently ignore the utterance. Conversation and informational questions should produce no answer or desktop action. This intent decision happens in the normal model request, with no separate classifier call.

The only local voice control is the complete word **“stop”**, matched after the utterance is finalized. It cancels work and returns to wake-word standby without an API call. “Cancel”, “stop listening”, and “go to sleep” are not special local commands; they go to Luna like any other utterance while ready. During execution, new speech does not start parallel requests; “stop” remains available.

| State or command | Behavior |
|---|---|
| Standby | No overlay; local wake-word monitoring continues. |
| Active | A slightly expanded, empty gradient notch indicates readiness. |
| Speaking | The live transcript wraps at a constrained width and grows downward. |
| Acting | The panel shrinks smoothly to one short description for the current operation. |
| Finished | The panel returns to the small active indicator, ready for another command. |
| “Stop” | Cancels the current action and returns to wake-word standby. Say “Hey Mouse” to activate again. Earlier clicks or typing are not undone. |
| **Pause microphone** in the menu | Stops microphone capture and wake-word monitoring. |

The notch has no buttons. The menu provides activation, stop, Settings, microphone pause, and quit. Typed requests and recent activity are available under **Testing & recent activity** in Settings. Settings hides during execution without reopening after every task.

Voice runs through Apple's on-device `SpeechAnalyzer` and `SpeechTranscriber`; it is continuous local recognition, not a dedicated low-power wake detector. Mouse checks hardware and locale support and prepares the model through Apple's `AssetInventory`. It reports setup failures rather than silently switching to the older recognizer. Wake-word standby uses no OpenAI requests. Once active, completed utterances and screenshots are sent to OpenAI for intent and action decisions, including utterances Luna ignores; microphone audio is never sent. Captures exclude Mouse's own windows but can include other visible apps.

Live, provisional results update the notch. After about one second of quiet audio and stable text, a separate local transcription pass finalizes the retained utterance, including audio before the first word and trailing silence. Mouse waits for that complete result stream before submitting text. New speech or revisions invalidate an unfinished pass. The microphone and live analyzer keep running between commands. Audio retention is bounded; a processing backlog or an unfinished utterance longer than about a minute pauses voice with an explanation instead of submitting incomplete text.

## Action protocol and capture

The Responses API uses a strict custom `execute_actions` function with required `description` and `actions` fields. Each response describes one operation and contains 1–12 actions. A short label such as “Searching Linus Tech Tips…” stays visible while that batch executes. Actions are validated before desktop events are posted. The next request returns a fresh screenshot in `function_call_output`, tied to the same call ID.

A separate `pause_for_user` function requests missing information, authorization, or review without executing actions. Invalid, incomplete, refused, mixed, or multiple operations are rejected. Completion is requested only after the model inspects the resulting screen. Requests time out after 30 seconds and are not automatically retried; each command retains an 8-model-turn execution guard.

Luna returns `ignore_utterance({})` when the utterance does not call for computer control. This silently ends the turn and returns to the active indicator without an answer or action. Ignoring cannot be combined with an action batch, clarification, or message, and earlier commands cannot turn new conversation into an instruction. An ignored utterance still uses one normal screenshot/request and counts toward usage.

Screenshot sizing is unchanged: ScreenCaptureKit captures at the selected display's logical dimensions, capped at 1600 pixels wide, then encodes JPEG at 78% quality. Existing coordinate mapping converts image coordinates to display coordinates. No additional 40% scaling was introduced.

This iteration focuses on the notch UI on the current Mac. Spaces, fullscreen behavior, and multiple-display overlay placement remain deferred.

## Usage and verification

There is **no cumulative API request cap**. The counter persists request attempts and returned input/output token totals in `~/Library/Application Support/Mouse/usage.json`. Failed and cancelled attempts count as requests. The displayed cost is an estimate that excludes cache pricing; OpenAI reports actual billing. Accounting failures do not block requests.

Run offline tests with:

```sh
./Scripts/test.sh
./Scripts/test.sh --filter OpenAIClientTests
```

Coverage includes unrestricted utterance forwarding, the local stop control, transcript revisions and finalization invalidation, strict schemas, description/action parsing, screenshot continuations, pause/ignore handling, cancellation, persistent activation, usage counting, and coordinate mapping. Tests make no live API requests. A passing suite does not establish microphone quality, semantic intent accuracy, or end-to-end Mac control.

Preview the notch without microphone capture, API requests, or desktop input:

```sh
../Mouse.app/Contents/MacOS/Mouse --notch-preview active
../Mouse.app/Contents/MacOS/Mouse --notch-preview transcript
../Mouse.app/Contents/MacOS/Mouse --notch-preview action
../Mouse.app/Contents/MacOS/Mouse --notch-preview cycle
```

`--diagnostics` reports key availability, permissions, and the speech engine without printing credentials. `--voice-check /path/to/audio.aiff` locally checks a recording of “Hey Mouse, open Chrome” using the newer SpeechTranscriber and installed model assets. It waits for finalized text and reports the engine, locale, assets, and timing; it does not capture microphone audio, request permissions, call OpenAI, or execute the command.

The opt-in `--api-check` uses the saved key and makes up to three billable requests, counted in usage. It validates a structured click against a generated TEST button, then returns a generated DONE screenshot to verify the function-result continuation. It neither captures nor controls the desktop. Quit the GUI before this check so two processes do not update the counter simultaneously.

Settings is preferred for key entry. `--import-key` accepts a key on standard input; `--api-check --key-stdin` accepts one for that check. Never put credentials in command arguments.

This local build is ad-hoc signed. Rebuilds can require renewed macOS permissions or Keychain authorization. Distribution to other users requires Developer ID signing, notarization, and further testing.
