# Mouse

A native Mac voice interface for clicking, typing, scrolling, and navigating apps. Mouse lives in the menu bar; its everyday interface expands directly from the notch using native Liquid Glass, a black-to-glass gradient, and filled upper corners. The panel does not take keyboard focus or intercept clicks.

Requires an Apple silicon Mac running macOS 26 or later, full Xcode 27 to build, and an OpenAI API key with access to GPT-6 Luna. Voice uses on-device English (US) speech recognition. The model configuration remains GPT-6 Luna, Fast service, and low reasoning.

## Build and open

From this folder:

```sh
./Scripts/build.sh
open ../Chosen.app
```

The app displays as **Mouse**. Its existing bundle identity, executable name, support directory, and default build destination remain `Chosen` for continuity. To choose another destination, pass an `.app` path to the build script.

The scripts respect `DEVELOPER_DIR`, otherwise use the selected full Xcode or `/Applications/Xcode.app`. They do not change global `xcode-select` settings. Build products use the workspace's `work/` folder when available, otherwise a temporary directory. Override with `CHOSEN_BUILD_DIR` or `CHOSEN_TEST_BUILD_DIR`.

## Setup and use

Open **Settings…** from Mouse's menu-bar icon. Settings also opens on launch when setup is incomplete.

1. Enter your OpenAI API key and select **Save key**. The key stays in macOS Keychain. If an updated build shows **Needs authorization**, select **Reconnect saved key** and approve macOS's Keychain authorization prompt, or supply another key.
2. Use **Allow** to grant Screen Recording and Accessibility in System Settings. Reopen Mouse if macOS requests it.
3. Select **Enable voice** and grant Microphone and Speech Recognition access. On subsequent launches, Mouse starts local wake-word monitoring automatically when voice permissions are already authorized. **Open Mouse at login** is optional.

Say **“Hey Mouse, open Chrome.”** The legacy **“Hey Chosen”** phrase also works. Activation persists between commands until you explicitly put Mouse to sleep; silence does not expire the session.

Mouse accepts clear computer instructions and silently ignores conversation, informational questions, and unclear phrases. A conservative local filter runs before transcription is displayed or a task starts. Rejected speech triggers no screen capture, API request, answer, or desktop action; Mouse remains active. “Open Chrome” and “Can you open Chrome?” are commands; “How do I open Chrome?”, “I told him to open Chrome”, and “don't open Chrome” are ignored. Unknown phrasing may need to be restated as a direct instruction.

Spoken stop and sleep controls are matched as complete phrases at the existing silence boundary (about 700 ms), so “stop by later” or “cancel my dinner reservation” does not cancel a computer task.

| State or command | Behavior |
|---|---|
| Standby | No overlay; local wake-word monitoring continues. |
| Active | A slightly expanded, empty gradient notch indicates readiness. |
| Speaking a clear command | The live transcript wraps at a constrained width and grows downward. |
| Acting | The panel shrinks smoothly to one short description for the current operation. |
| Finished | The panel returns to the small active indicator, ready for another command. |
| “Stop”, “stop listening”, or “go to sleep” | Cancels the current action and returns to wake-word standby. Say “Hey Mouse” to activate again. |
| “Cancel” | Cancels queued actions and retains activation. Earlier clicks or typing are not undone. |
| **Pause microphone** in the menu | Stops microphone capture and wake-word monitoring. |

The notch has no buttons. The menu provides activation, sleep, cancellation, Settings, microphone pause, and quit. Typed commands and recent activity are available under **Testing & recent activity** in Settings. Settings hides during execution without reopening after every task.

Voice runs through Apple's on-device `SFSpeechRecognizer`; it is continuous local recognition, not a dedicated low-power wake detector. Idle monitoring uses no OpenAI requests. Only submitted commands and screenshots are sent to OpenAI, never microphone audio. Captures exclude Mouse's own windows but can include other visible apps.

## Action protocol and capture

The Responses API uses a strict custom `execute_actions` function with required `description` and `actions` fields. Each response describes one operation and contains 1–12 actions. A short label such as “Searching Linus Tech Tips…” stays visible while that batch executes. Actions are validated before desktop events are posted. The next request returns a fresh screenshot in `function_call_output`, tied to the same call ID.

A separate `pause_for_user` function requests missing information, authorization, or review without executing actions. Invalid, incomplete, refused, mixed, or multiple operations are rejected. Completion is requested only after the model inspects the resulting screen. Requests time out after 30 seconds and are not automatically retried; each command retains an 8-model-turn execution guard.

For command-like phrasing that passes the local filter, the model can return `ignore_utterance({})` as a second check on intent. This silently ends the turn without an answer or action. Ignoring cannot be combined with an action batch, clarification, or message, and earlier commands cannot turn new conversation into an instruction. This model fallback still uses the normal screenshot/request; the local filter rejects ordinary chat before either is created.

Screenshot sizing is unchanged: ScreenCaptureKit captures at the selected display's logical dimensions, capped at 1600 pixels wide, then encodes JPEG at 78% quality. Existing coordinate mapping converts image coordinates to display coordinates. No additional 40% scaling was introduced.

This iteration focuses on the notch UI on the current Mac. Spaces, fullscreen behavior, and multiple-display overlay placement remain deferred.

## Usage and verification

There is **no cumulative API request cap**. The counter persists request attempts and returned input/output token totals in `~/Library/Application Support/Chosen/usage.json`. Failed and cancelled attempts count as requests. The displayed cost is an estimate that excludes cache pricing; OpenAI reports actual billing. Accounting failures do not block requests.

Run offline tests with:

```sh
./Scripts/test.sh
./Scripts/test.sh --filter OpenAIClientTests
```

Coverage includes local command intent filtering, ignored conversation, strict schemas, description/action parsing, screenshot continuations, pause/ignore handling, cancellation, persistent activation, stop-versus-sleep behavior, usage counting, and coordinate mapping. Tests make no live API requests. A passing suite does not establish microphone quality or end-to-end Mac control.

Preview the notch without microphone capture, API requests, or desktop input:

```sh
../Chosen.app/Contents/MacOS/Chosen --notch-preview active
../Chosen.app/Contents/MacOS/Chosen --notch-preview transcript
../Chosen.app/Contents/MacOS/Chosen --notch-preview action
../Chosen.app/Contents/MacOS/Chosen --notch-preview cycle
```

`--diagnostics` reports key availability and permissions without printing credentials. `--voice-check /path/to/audio.aiff` locally checks a recording of “Hey Mouse, open Chrome” with existing Speech authorization; it does not execute the command.

The opt-in `--api-check` uses the saved key and makes up to three billable requests, counted in usage. It validates a structured click against a generated TEST button, then returns a generated DONE screenshot to verify the function-result continuation. It neither captures nor controls the desktop. Quit the GUI before this check so two processes do not update the counter simultaneously.

Settings is preferred for key entry. `--import-key` accepts a key on standard input; `--api-check --key-stdin` accepts one for that check. Never put credentials in command arguments.

This local build is ad-hoc signed. Rebuilds can require renewed macOS permissions or Keychain authorization. Distribution to other users requires Developer ID signing, notarization, and further testing.
