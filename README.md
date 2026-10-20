# Mouse

Mouse is a native Mac voice interface for clicking, typing, scrolling, and navigating apps. It lives in the menu bar. Its everyday interface expands from the notch using native Liquid Glass, a black-to-glass gradient, and small concave shoulders that curve into the screen's top edge. The shoulder radius stays at 6 points across active, transcript, and action sizes. During collapse, those insets shrink on the same animation progress as the panel, so the visible left, right, and bottom edges reach the hardware notch together. The panel does not take keyboard focus or intercept clicks.

**This is the canonical project README.** It covers current behavior, setup, architecture, data handling, verification, limitations, and proposed work. The proposals at the end are not implemented behavior. Source review date: **2026-10-20**. The descriptive history is in [CHANGELOG.md](CHANGELOG.md).

The app to open is **`/Users/sameemsaleem/Product/outputs/Mouse.app`**. This source project is **`/Users/sameemsaleem/Product/outputs/Mouse`**. Bundles under `work/`, including the old `Mouse-Morph.app`, are test/build artifacts, not the canonical app.

## Requirements

| Requirement | Current configuration |
|---|---|
| Mac | Apple silicon, macOS 26 or later |
| Build tools | Full Xcode 27; Command Line Tools alone are insufficient |
| Speech | Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`, with supported English (US) model assets |
| Computer-control models | OpenAI API key with access to `gpt-6-luna` through Responses, using `fast` service and `low` reasoning. No Decisions request or thinking-model handoff. |
| Permissions | Microphone for voice; Screen Recording and Accessibility for computer control |

Local speech transcription needs no OpenAI key or API usage fees. The key is used for interpreting completed utterances and deciding computer actions. Apple speech assets may need to be downloaded during setup.

## Build and run

From this folder:

```sh
./Scripts/build.sh
open ../Mouse.app
```

The default output is the sibling `Mouse.app` bundle. To choose another destination:

```sh
./Scripts/build.sh /path/to/Mouse.app
```

The destination must end in `.app`. The build script creates an Apple silicon Release app and verifies its ad-hoc signature. The executable, Xcode project, and Swift package are named **Mouse**. Use the packaged app for normal operation so macOS can associate its permission declarations and identity with the executable.

Scripts respect `DEVELOPER_DIR`; otherwise they use the selected full Xcode, falling back to `/Applications/Xcode.app`. They do not change global `xcode-select` settings. Build and test products use the workspace's `work/` directory when available, otherwise a temporary directory. Override these locations with `MOUSE_BUILD_DIR` and `MOUSE_TEST_BUILD_DIR`.

The bundle identifier, `com.chosen.mac`, and Keychain service intentionally remain stable after the rename from Chosen. This preserves the saved connection and app identity. Mouse copies an existing Chosen usage file into its own support directory on first use without overwriting an existing Mouse counter; the legacy file is retained.

## First-time setup

Open **Settings…** from Mouse's menu-bar icon. Settings also opens on launch when setup is incomplete.

1. Enter an OpenAI API key and select **Save key**. Mouse stores it in macOS Keychain. If an updated build shows **Needs authorization**, select **Reconnect saved key** and approve the macOS Keychain prompt, or supply another key.
2. Use **Allow** to grant Screen Recording and Accessibility in System Settings. Reopen Mouse if macOS requests it.
3. Select **Enable voice** and grant Microphone access. Mouse checks speech support and prepares Apple's model, showing progress if assets need downloading. This engine does not request the legacy Speech Recognition permission.
4. Optionally enable **Open Mouse at login**, which uses macOS's login-item service.

On subsequent launches, Mouse starts local wake-phrase monitoring automatically when Microphone access is already authorized. Setup failures are shown; the app does not silently fall back to the older recognizer.

## Everyday use

Say **“Hey Mouse, open Chrome.”** The wake phrase is **“Hey Mouse”**, at the beginning of the utterance. Brief prefixes such as “please” or “okay” are accepted. “Hey Chosen” is not a wake phrase.

Activation persists between commands until you say **“stop”** or choose **Stop Mouse** from the menu. Silence does not expire the session. Each finalized spoken utterance first goes to a separate **text-only Luna check**, which extracts a clearly directed computer command or amendment and ignores surrounding chatter. There is no fixed command vocabulary, app-name list, or grammar filter.

Only extracted command text reaches the action request, with a screenshot and accepted-command context. Luna then interprets requests such as “make this bigger” or “organize my files” and returns structured computer actions or requests required information or authorization. The speech check is instructed to ignore conversation, informational questions, ambiguous intent, quoted instructions, and hypothetical commands. It does not identify the speaker, and model judgments can still be wrong.

| State or control | Visible behavior and effect |
|---|---|
| Standby | No overlay; local wake-phrase monitoring continues. |
| Active and ready | A slightly expanded, empty gradient notch indicates readiness. |
| Speaking while idle | Provisional text wraps at a constrained width and grows downward. Apple may revise tentative words. |
| Speaking during a task | The current action or loading presentation stays visible while speech is transcribed and checked. Only an accepted command interrupts the task. |
| Acting | The panel shrinks to one short description of the current operation. |
| Finished, or speech ignored while idle | The panel returns to the small active indicator. |
| Speech ignored during a task | Work and the current action/loading presentation continue unchanged. |
| Required input or error | A brief notice appears; details are available in Settings. |
| Initial recognized “stop” | Cancels pending work and returns to standby as soon as the live recognizer reports it. Say “Hey Mouse” to activate again. |
| **Stop Mouse** in the menu | Cancels work and returns to standby without waiting for speech recognition. |
| **Pause microphone** | Stops microphone capture and wake-phrase monitoring. |

The only local sleep control is **“stop” as the first word**, ignoring case and ordinary boundary punctuation. It works from provisional text without the quiet endpoint, second pass, or API check: “stop now” and “stop listening” also sleep Mouse. “Stop by later” can therefore sleep it too. Quoted “stop”, “don't stop”, “type stop”, and words such as “stopwatch” do not match. “Cancel” and “go to sleep” are not local controls. While active, Mouse accepts continuations and corrections during model requests and execution. The existing task continues until the text-only check accepts a command; the action model then decides whether it revises the existing task or replaces it. “Hey Mouse” also activates from the live result; ordinary spoken commands still require accurate final transcription and screening.

The notch has no buttons. The menu provides activation, Stop, Settings, microphone pause/resume, and Quit. Typed requests and recent activity are under **Testing & recent activity** in Settings. Settings hides during execution and does not reopen after every task. Previous clicks or typing are not undone by Stop.

## How a command runs

```text
Microphone → normal audio input → live transcript
    ├─ initial “stop” → cancel + standby
    ├─ “Hey Mouse” → activate immediately
    └─ 500 ms quiet endpoint
         ├─ accurate second transcription pass
         └─ speculative screenshot in parallel, only while idle
              → finalized text → separate text-only Luna check
                   ├─ ignore or failed check → leave current task alone
                   └─ extracted command → interrupt old work and await input cleanup
                        → fresh/validated screenshot + extracted command → Luna Responses
                             ├─ revision/replacement + actions + short description → execute
                             │    → wait 1000 ms → fresh screenshot → same Responses chain
                             └─ ignore, verified completion, or request user input
```

### Live speech and final text

`VoiceInput` keeps the microphone stream and live analyzer running between commands. `SpeechAudioFeed` copies and converts incoming audio through bounded queues. Microphone callbacks do not perform model requests. The live transcriber uses volatile, faster results and audio time ranges. These results drive provisional notch text while idle; they are not the text authorized for execution.

After **500 ms of quiet audio and stable text**, checked every **10 ms**, Mouse starts a separate local final transcription pass over retained utterance audio. It retains leading audio and trailing silence so words at the boundaries are not intentionally clipped. The microphone and live analyzer continue during this pass. Mouse waits for the complete final result stream before submitting a command. New audio or transcript revisions invalidate an unfinished finalization candidate and its speculative capture.

The 500 ms value is an endpoint threshold, not total command latency. Final transcription and speculative screenshot capture overlap while idle; screening adds a text-only API round trip before an accepted spoken command reaches the action model. Action inference and execution still add time. A longer pause can still split a request; subsequent speech is screened as a possible continuation. Finalization has a 12-second timeout. Audio retention is bounded: a processing backlog, stalled input, or an unfinished utterance longer than roughly a minute discards the incomplete utterance and initiates recovery rather than submitting partial audio.

Wake and Stop act on live recognition; other provisional words only update the interface. The accurate second pass still determines the submitted command. Continuous local recognition is not a dedicated low-power wake detector.

Mouse uses the microphone's normal audio input. The added `AVAudioEngine` voice-processing, bypass, and other-audio ducking configuration was removed after a report of missing microphone audio. Mouse does not enable app-level noise suppression or enroll a voice profile. Nearby people and background speech can still be recognized.

### Speech screening, continuations, and changes of mind

The live recognizer and accurate replay remain available while a task is running. Raw audio activity, provisional words, and a pending speech check do **not** suspend the task or replace its notch presentation. `SpeechIntentFilter` makes a separate Luna Fast request with text only: no screenshot, action tools, or `previous_response_id`. It must extract only the directed command or amendment, preserving requested targets and constraints without importing surrounding conversation. Ambiguous speech is ignored rather than promoted into instructions.

Finalized utterances are screened serially in arrival order, independently of the action request's cancellation generation. The check receives the current goal, accepted pending fragments, any pending clarification, and the last accepted command and resolved goal as text context. Ignored speech or a failed check leaves existing work running. Stop, microphone deactivation, and leaving the active session cancel pending checks and invalidate queued results, so a late result cannot reactivate Mouse.

Only an accepted extracted command interrupts existing work. Cancellation invalidates the action request's generation, and the replacement waits for old input cleanup before capturing a fresh screen. A partially dispatched click, drag, or typing operation is recorded as uncertain; already posted input cannot be undone by interruption. The existing task can continue making progress while a possible correction is transcribed and checked.

Before the action model first accepts a request, screened fragments accumulate in order without truncation. After acceptance, extracted amendments are supplied alongside the current goal, all accepted amendments, and a record of actions actually dispatched. The action model returns a structured `task_update` with `kind: revise` or `replace` and the complete updated `goal`, in the same response as actions or a pause. “Actually, search MKBHD instead” can change one part while retaining the rest; “forget that, open Calculator” can replace the sequence. The speech check identifies directed intent; it does not plan actions or choose the final revision strategy. These examples express intended model behavior, not guaranteed semantic accuracy.

Revisions retain completed progress. Replacement abandons the former goal but retains its physical effects as background; Mouse starts from the current screen rather than assuming the computer reset. Background speech still costs a text-only screening request, but an ignored result does not cancel or restart the existing action request. Cancelling any API request does not guarantee the provider stops processing or billing it.

While waiting for an action-model response, the notch shows a compact **ring of six solid-white dots with a faint glow**. The loading body is 16 points wider and 56 points taller than the hardware notch, plus the existing 6-point outer shoulders on each side, with a 30-point ring view. All six simultaneously grow, fade from zero to full opacity, and move from the center to their ring positions over 400 ms, with the slow rotation already running. An overlapping size pulse then passes around the ring. When the response arrives, they shrink away in quick sequence before the next presentation. This visual transition does not delay execution. Reduce Motion uses a stationary ring and immediate removal. While busy, additional speech leaves that presentation or the current short action description intact until accepted as a command.

### Retained audio and recovery

Audio retention follows detected speech independently of the recognizer's first text result. This keeps leading speech while Apple is still preparing its first words, rather than dropping it with an eight-second idle-silence buffer. Coarse recognizer ranges that start in trimmed silence no longer automatically imply missing speech. If timestamps cannot prove that the replay covers the whole utterance, the replay must match the normalized live words; an uncertain shortened or revised replay is discarded rather than executed.

Recoverable stream/device/finalization failures discard unfinished audio and text, cancel current computer work, and restart in **standby**. Mouse attempts at most three restarts in a rolling 60-second window, delayed by 0.3, 0.8, and 1.5 seconds. A successful restart requires “Hey Mouse” again and a repeated command. Exhausted recovery reports the specific failure and leaves the microphone disabled until explicitly enabled. Pausing the microphone invalidates pending restarts.

### Live-transcript boundary fix

The live analyzer and accurate replay pass maintain independent audio boundaries. Previously, after Mouse consumed a wake phrase or utterance, Apple could return a coarse provisional segment starting before that consumed boundary but also containing new words. Mouse's filter rejected the whole overlapping segment, hiding the new command's live text until the analyzer naturally closed the segment. This was conditional: longer gaps could let the engine close the segment by itself.

`SpeechBoundarySynchronizer` advances the live analyzer through Mouse's consumed-audio boundary after commits, resets, and discards. It serializes finalization calls, combines pending requests into the newest boundary, and retires with its analyzer lifecycle so late callbacks cannot affect a replacement stream. A boundary-finalization failure enters the bounded recovery path. The strict old-audio filter remains intact, and repeated identical preview text is not republished.

This boundary fix supports growing live previews across consumed boundaries. The newer endpoint, parallel capture, session command history, and immediate Stop changes are separate mechanisms described here; the historical preview benchmark below does not measure those changes.

### Capture and focus

While idle, **capture starts alongside the accurate second transcription pass** at an active utterance's quiet endpoint. The image remains local during text-only screening; ignored speech never sends it to the filter. The result is reusable only for the same finalization-candidate ID and command generation, the same foreground process, unchanged display geometry, and an age of at most **1.5 seconds**. Revisions, cancellation, changed focus, an expired capture, or a failed capture cause it to be discarded; Mouse captures again before action inference. Speculative capture is skipped while a task is running and when Mouse itself is frontmost. An accepted redirect waits for interrupted input cleanup and then captures a fresh screen.

If a typed request has put Mouse Settings in front, `AppModel` attempts to reactivate the previously active application and waits 220 ms. It hides Mouse's visible key/main windows. The nonactivating, click-through notch can remain visible, but ScreenCaptureKit excludes all windows owned by Mouse from the image sent to the model.

At the start of a command, `NativeComputer` chooses the display under the pointer, with the main display as a fallback. That display stays selected throughout the command. Capture uses logical display dimensions, capped at **1600 image pixels wide**, preserving aspect ratio, and encodes JPEG at **78% quality** in memory. There is no additional 40% scaling. The cursor and menu bar are included.

Screenshot coordinates map back to global display coordinates, including scaled screens and negative display origins. Display geometry and the foreground process are checked before actions. Capture also checks that the foreground process did not change while the screenshot was gathered, with one fresh attempt if it did. These checks do not prove that the same app's content or internal keyboard focus stayed unchanged during inference.

After each action batch, Mouse waits a nominal **1000 ms**, then captures a fresh screenshot before asking Luna for the next step. Scheduling may make the wait longer, and capture, network, and model time are additional; the full step is not promised to finish in one second. This replaces the earlier 350 ms wait and deliberately adds settling time between steps. The wait is cancellable by Stop or an accepted new command, not raw speech alone. The model is instructed to end a batch after navigation or a screen transition so it can inspect another image before continuing. Screen content can still change after the fixed delay. **Every action-inference turn includes a screenshot; speech screening never does.** Selective image omission from action requests is not implemented.

Mouse does not currently read an accessibility tree, offer native AX target choices, or send accessibility labels/values to the model. macOS **Accessibility permission remains required** to post mouse and keyboard input. The screenshot supplies visual context; returned coordinates determine where input is sent. There is no browser DOM integration or operating-system app catalog.

### Model protocol and execution

`SpeechIntentFilter` first screens finalized speech through a separate text-only Responses request using `gpt-6-luna`, Fast service, and low reasoning. Its structured result either supplies an extracted command or ignores the utterance; it cannot execute actions. `OpenAIComputerClient` then sends accepted extracted text, the app session's accepted-command history, and a screenshot to the same model/service configuration. The action client uses strict custom function schemas. There is no Decisions API selection pass, AX-target route, Astra escalation, or general shell/scripting tool.

| Model result | Meaning |
|---|---|
| `execute_actions` | One coherent operation with required `task_update`, short `description`, and 1–12 actions. |
| `pause_for_user` | Required target information, authorization, authentication, or review is missing. Includes `task_update`; no actions run with the question. |
| `ignore_utterance({})` | Silently finish a non-action utterance. No answer, notice, or desktop action. |
| Final message | Report completion after inspecting the resulting screen. |

Generated descriptions aim for 3–6 words, at most 64 characters, such as “Searching Linus Tech Tips…”. Descriptions represent the current operation rather than claiming completion. The parser rejects malformed, incomplete, refused, mixed, or multiple operations. The controller validates every generated action in a batch before posting its first desktop event.

Supported actions are click, double-click, pointer move, scroll, drag, Unicode typing, keypress, wait, and screenshot. Pointer actions support Command, Control, Option/Alt, and Shift modifiers. Keypress supports common navigation keys, Enter, Escape, Space, Tab, F1–F20, and supported printable keys. Unsupported keys, invalid fields, nonfinite/out-of-bounds coordinates, and invalid action sizes fail explicitly. Typing uses Unicode keyboard events and does not change the clipboard.

After an executed batch and the 1000 ms wait, Mouse returns the fresh screenshot as `function_call_output`, tied to the same call ID, and continues through `previous_response_id`. The original task and the earlier operations remain in that Responses chain. Requests time out after 30 seconds and are not replayed automatically. **There is no per-command step limit and no cumulative request cap.** The loop ends on completion, a request for user input, an error, or cancellation.

Model instructions treat screen text as untrusted data and require pauses before unauthorized sensitive or irreversible actions and authentication/security prompts. These are instructions to the model, not a guarantee that it will always recognize a sensitive situation. Local validation checks the structure and executability of returned actions.

### Cancellation

Stop invalidates the current command generation, cancels its task, and separately cancels pending speech screening and queued results. Late responses cannot resume that command or reactivate the session. Execution checks cancellation between actions and within typing and drag loops. Cleanup releases synthesized mouse buttons and modifier keys when an operation is interrupted.

Already posted input cannot be recalled: previous clicks, text, scrolling, or application side effects are not undone. Spoken Stop now bypasses endpoint/finalization once its initial word is recognized, but it still depends on recognition and callback scheduling. Cancellation is cooperative rather than a hard real-time guarantee. The menu's **Stop Mouse** avoids recognition delay, but does not undo input either.

## Context, privacy, and storage

### What Mouse remembers

Within an uninterrupted task, Luna Responses preserves its conversation through the previous response ID, including the original command, operations, and returned screenshots. A newly screened command starts a fresh action-response chain with explicit active-task context; Luna decides whether to revise that task or start a different one. Accepted amendments are also recorded in session history. Superseded history entries are marked paused with a revision/replacement outcome, not completed. Speech screening has no previous-response chain.

Between commands, Mouse keeps **every command the action model accepts during the current app session**, in order and with its full extracted text. Background words removed by screening do not enter this history. Each record tracks whether the task is running, completed, paused, stopped, or failed, together with the available result, pause reason, or interruption/error information. Each new action request receives the complete history of prior accepted commands as background context. The current extracted command is supplied separately.

Admission happens only after the action model returns a valid response accepting computer-action intent; passing speech screening alone does not add a history entry. Ignored utterances, and requests cancelled or failed before action-model admission, are not added. If an accepted task later stops or fails, its record remains with that outcome; it is not presented as completed. This is a record of accepted computer commands, not a transcript of everything heard. Luna's intent judgment can still be wrong.

History lives **only in the running app's memory**. Stop, sleep, and microphone pause preserve it; quitting or restarting Mouse clears it. Mouse does not write a command-history text file or restore commands from disk. This history does not replay actions or skip Luna calls. Earlier instructions are background, not new commands or fresh authorization; Luna may use them to resolve a follow-up target only after current action intent is clear.

There is no local command-count cap, character truncation, or automatic summary. Longer sessions therefore send more input text and can increase token usage and latency. Provider context limits still apply; Mouse does not silently trim history to fit them.

The separate activity list holds up to 20 entries in memory, and Settings shows the most recent entries. That display limit does not limit the accepted-command history sent to Luna. Neither is restored after quitting. Screenshots and the complete operation-by-operation Responses transcript are not copied into the cross-command history.

### Data boundaries

| Data | Current handling |
|---|---|
| Microphone audio | Processed locally by Apple's speech engine; bounded in-memory queues and retained utterance audio. Mouse does not save recordings or send microphone audio to OpenAI. |
| Apple speech assets | Prepared through Apple's `AssetInventory`; a model download may occur during setup. |
| Standby speech | Used locally for wake-phrase detection; no OpenAI request. |
| Completed active utterance | Sent to the text-only OpenAI speech check, including speech it ultimately ignores. Only an extracted command is forwarded to action inference with the accepted-command history and screenshot. Ignored background words are not added to that history. |
| Screenshots | Captured and JPEG-encoded in memory; sent to OpenAI for action inference, never speech screening. Idle speculative captures may be taken before intent is known but remain local unless reused for an accepted command. Mouse's own windows are excluded; other visible apps can be included. Mouse does not write these captures to disk. |
| Accessibility permission | Used for mouse/keyboard control. Mouse does not gather or transmit an accessibility tree. |
| API key | Stored in macOS Keychain under the stable service `com.chosen.mac.openai`; not written to the repository or usage JSON. Routine reads do not intentionally prompt; explicit reconnect can ask macOS to authorize access. |
| Accepted-command history | Full command text, task status, and outcome kept in RAM and sent as background for later commands. Survives Stop/microphone pause; cleared when the app exits. No transcript file is written. |
| Recent activity | Up to 20 entries in memory; cleared when the app exits. Separate from the complete accepted-command history. |
| Request/token counters | Persisted to `~/Library/Application Support/Mouse/usage.json`. No transcripts, screenshots, or API key are stored in this file. |
| Login preference | Managed through macOS `SMAppService`. |

The app does not configure or promise zero retention by OpenAI. Data sent to the API is subject to the account's provider-side policies and settings.

### Usage accounting

The persisted counter records request attempts and returned input/output token totals for both speech screening and action inference. Attempts are counted immediately before networking, so a request that subsequently fails or is cancelled still counts. Cancelling before a request reaches that stage does not create an API attempt. An ignored spoken utterance costs one text-only check and no action request or uploaded screenshot. Accepted speech adds that check before the normal action requests.

Displayed cost uses Luna Fast constants in `DemoBudget`. Existing request/token totals and the accumulated estimate are preserved, including charges estimated during the earlier Decisions/Astra experiment; they are not reset or repriced by returning to the single-model loop. The estimate excludes cache discounts/writes and regional premiums; it is not a live pricing lookup or a billing cap. OpenAI reports actual billing. Usage migration/read/write problems do not block requests: Mouse reports a warning and continues counting in memory. An unreadable prior file is preserved in a backup when possible.

Counters are not coordinated between multiple running processes. Quit the GUI before running the API smoke check to avoid competing usage-file updates.

## Source map and architecture

The Swift package separates testable core state/protocol logic from the native app. The Xcode app target compiles the same sources together; conditional `SWIFT_PACKAGE` imports keep both builds supported. `AppModel`, native input, and UI coordination run on the main actor. The API client uses a separate actor, and audio conversion uses a separate task.

| File or directory | Responsibility |
|---|---|
| [`Sources/Mouse/MouseApp.swift`](Sources/Mouse/MouseApp.swift) | App entry point, menu-bar controls, Settings scene, diagnostic/check modes. |
| [`Sources/Mouse/AppModel.swift`](Sources/Mouse/AppModel.swift) | Permissions/status, speech-screening and capture handoff, Luna action loop, independent screening/action cancellation, accepted-command history, activity, usage persistence. |
| [`Sources/Mouse/MouseView.swift`](Sources/Mouse/MouseView.swift) | Settings, connection/permissions, usage, typed testing, recent activity. |
| [`Sources/Mouse/MouseNotchController.swift`](Sources/Mouse/MouseNotchController.swift) | Nonactivating notch panel, state transitions, layout and visual presentation. |
| [`Sources/Mouse/NativeGlassSurface.swift`](Sources/Mouse/NativeGlassSurface.swift) | Native AppKit glass surface hosting SwiftUI content. |
| [`Sources/Mouse/VoiceInput.swift`](Sources/Mouse/VoiceInput.swift) | Normal microphone input, live previews and controls, quiet endpoint, accurate replay, capture-candidate callbacks, bounded recovery. |
| [`Sources/Mouse/SpeechAudioFeed.swift`](Sources/Mouse/SpeechAudioFeed.swift) | Owned PCM buffers, format conversion, bounded audio queues and timing. |
| [`Sources/Mouse/SpeechRuntimeSetup.swift`](Sources/Mouse/SpeechRuntimeSetup.swift) | Hardware/locale checks, asset reservation/download, setup progress. |
| [`Sources/Mouse/NativeComputer.swift`](Sources/Mouse/NativeComputer.swift) | ScreenCaptureKit capture, coordinate conversion, permission preflights, action validation and CGEvent input. |
| [`Sources/Mouse/KeychainStore.swift`](Sources/Mouse/KeychainStore.swift) | Save, noninteractive load, explicit authorization of the saved API key. |
| [`Sources/Mouse/APICheck.swift`](Sources/Mouse/APICheck.swift) | Opt-in model/protocol check with generated images and no desktop input. |
| [`Sources/Mouse/MicrophoneCheck.swift`](Sources/Mouse/MicrophoneCheck.swift) | Finite production-input diagnostic reporting signal and preview counts without saving audio/text or executing commands. |
| [`Sources/Mouse/VoiceFileCheck.swift`](Sources/Mouse/VoiceFileCheck.swift) | Local speech check on a supplied audio file. |
| [`Sources/MouseCore/WakeSession.swift`](Sources/MouseCore/WakeSession.swift) | Immediate live wake/Stop, persistent activation, busy-state handling, finalized ordinary-command routing. |
| [`Sources/MouseCore/VoiceControl.swift`](Sources/MouseCore/VoiceControl.swift) | Initial-word local Stop control. |
| [`Sources/MouseCore/SpeechTranscriptState.swift`](Sources/MouseCore/SpeechTranscriptState.swift) | Time-aligned transcript revisions, endpoint candidates, invalidation and consumed-audio boundaries. |
| [`Sources/MouseCore/SpeechAudioHistoryPolicy.swift`](Sources/MouseCore/SpeechAudioHistoryPolicy.swift) | 500 ms endpoint constant, speech-aware retention, and replay completeness check. |
| [`Sources/MouseCore/SpeechRecoveryState.swift`](Sources/MouseCore/SpeechRecoveryState.swift) | Bounded restart attempts and invalidation when microphone capture is disabled. |
| [`Sources/MouseCore/SpeechBoundarySynchronizer.swift`](Sources/MouseCore/SpeechBoundarySynchronizer.swift) | Serialized, coalescing advancement of the live analyzer's consumed boundary; lifecycle cancellation and failure handling. |
| [`Sources/MouseCore/OpenAIComputerClient.swift`](Sources/MouseCore/OpenAIComputerClient.swift) | Responses requests, instructions, strict tool schemas, parsing, continuation, offline transport injection. |
| [`Sources/MouseCore/SpeechIntentFilter.swift`](Sources/MouseCore/SpeechIntentFilter.swift) | Text-only Luna screening, directed-command extraction, strict response parsing, and usage. |
| [`Sources/MouseCore/SpeechScreeningQueue.swift`](Sources/MouseCore/SpeechScreeningQueue.swift) | Ordered utterance screening and invalidation of pending/queued results independently of action execution. |
| [`Sources/MouseCore/TaskSteeringState.swift`](Sources/MouseCore/TaskSteeringState.swift) | Accepted goal, amendments, actual dispatched inputs, partial effects, and revision/replacement context. |
| [`Sources/MouseCore/CommandContext.swift`](Sources/MouseCore/CommandContext.swift) | Full accepted-command history, task outcomes, background-context serialization, and speculative-capture identity/freshness validation. |
| [`Sources/MouseCore/ComputerModels.swift`](Sources/MouseCore/ComputerModels.swift) | Screenshot geometry, actions, model results, shared errors. |
| [`Sources/MouseCore/DemoBudget.swift`](Sources/MouseCore/DemoBudget.swift) | Request/token counters and cost estimate; its historical name does not imply a cap. |
| [`Sources/MouseCore/UsageStorage.swift`](Sources/MouseCore/UsageStorage.swift) | Usage location and non-overwriting migration from Chosen. |
| [`Tests/MouseCoreTests/`](Tests/MouseCoreTests/) | Offline state, protocol, usage, and geometry tests. |
| [`Package.swift`](Package.swift), [`Mouse.xcodeproj/`](Mouse.xcodeproj/) | Swift package/test graph and native app build configuration. |
| [`Scripts/`](Scripts/) | Build/test scripts and icon-generation tooling. |
| [`Tools/LiveTranscriptCheck.swift`](Tools/LiveTranscriptCheck.swift), [`Tools/Fixtures/`](Tools/Fixtures/) | Real Apple streaming-engine integration check, synthetic audio, and deterministic transcript fixtures. |
| [`Resources/`](Resources/) | App metadata, entitlements, and icon. |

## Verification

The **2026-10-20 speech-screening update** passed **134 offline tests with zero failures**, including text-only request construction, strict extraction parsing, serialized checks, ignored/failed results, and Stop invalidating late callbacks. Release build and signature verification succeeded at `/Users/sameemsaleem/Product/outputs/Mouse.app`. These checks use mocked responses and do not establish real-model classification accuracy or live microphone-to-desktop behavior. The app was rebuilt without launching it or changing permissions. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-speech-filter-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-speech-filter-build.log).

The **2026-10-20 six-dot loading update** passed the Release build and signature verification at `/Users/sameemsaleem/Product/outputs/Mouse.app`, with the new indicator confirmed in the executable. Entrance/exit interruption handling was reviewed. This UI change was not checked in a live visual or microphone session; the app was not launched and privacy/Keychain permissions were not changed. Log: [build](/Users/sameemsaleem/Product/work/mouse-loading-build.log).

The **2026-10-20 continuation/steering update** passed **118 offline tests with zero failures**, including the 500 ms endpoint, speech during execution, recognition boundaries, raw-audio gating, strict task-update parsing, and preservation of dispatched progress. The Release build and signature verification succeeded at `/Users/sameemsaleem/Product/outputs/Mouse.app`. This rebuild did not launch the app or change, refresh, or check any permissions or Keychain access, as requested. No live microphone-to-desktop or semantic rerouting test was performed. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-steering-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-steering-build.log).

The session-history update was built, installed, and opened at `/Users/sameemsaleem/Product/outputs/Mouse.app` on **2026-10-20**. Its full offline suite passed **100 tests with zero failures**; the Release build and signature verification passed. Settings showed the new session-history explanation and preserved **1,198-request counter**. Mac permission and saved-key renewal were still in progress at that check, so this records successful installation, not readiness for live control. The update has not been verified with live semantic follow-ups, microphone input, or an end-to-end desktop task.

The single-Luna change and 1000 ms delay were built and installed at `/Users/sameemsaleem/Product/outputs/Mouse.app` on **2026-10-19**. That version's offline suite passed **94 tests with zero failures**; the Release build and signature verification passed. Settings confirmed existing Screen Recording/Accessibility/Microphone access, the saved-key connection, and the preserved 1,099-request counter before the isolated live API check. That check added two requests; it did not run desktop actions. These recorded checks predate the 2026-10-20 session-history change.

Recorded checks provide the following evidence, with their limits:

| Check | Recorded result and scope |
|---|---|
| 2026-10-20 offline suite | **100 tests passed, zero failures.** Mocked transport and deterministic state checks; no live requests. Log: [`mouse-session-memory-tests.log`](/Users/sameemsaleem/Product/work/mouse-session-memory-tests.log). |
| 2026-10-20 Release app | **Build and signature verification succeeded; installed and opened at the canonical app path.** Settings displayed session-history guidance and the preserved 1,198-request counter. Permission/key renewal and live operation were not established by this check. Build log: [`mouse-session-memory-build.log`](/Users/sameemsaleem/Product/work/mouse-session-memory-build.log). |
| 2026-10-19 offline suite | **94 tests passed, zero failures.** Mocked transport; no live requests. Log: [`mouse-lean-luna-tests.log`](/Users/sameemsaleem/Product/work/mouse-lean-luna-tests.log). The earlier 111-test count included now-removed route modules. |
| 2026-10-19 Release app | **Build and signature verification succeeded; installed at the canonical app path.** Settings showed permissions allowed and the saved key connected. This does not establish live microphone quality. |
| Apple streaming-speech fixture | All three wake-gap cases passed: 0.25, 0.8, and 1.5 seconds. Real Apple analyzer with synthetic recorded audio; no microphone or API. |
| 2026-10-19 live Luna Responses API | **Passed** structured image-grounded click and function-result screenshot continuation. Two requests, 5,241 input and 52 output tokens, 3.46 seconds total. Log: [`mouse-lean-luna-api-check.log`](/Users/sameemsaleem/Product/work/mouse-lean-luna-api-check.log). Generated images only; no desktop action. This fixture bypasses `AppModel`, so its duration excludes the new one-second settling pause and is not a voice-to-action benchmark. |
| Microphone after removing voice processing | The direct signal check remained incomplete. Engine startup or permission checks alone do not establish that audible input or live recognition works. |

### Offline tests

```sh
./Scripts/test.sh
./Scripts/test.sh --filter OpenAIClientTests
```

Tests use mocked API transport and do not make live OpenAI requests. They cover unrestricted utterance forwarding, immediate initial-word Stop and wake, transcript revisions and finalization invalidation, 500 ms endpoints, speech-aware history and replay coverage, recovery limits, accepted-command history and outcomes, capture-candidate freshness, persistent activation, strict schemas, description/action parsing, screenshot continuations, pause/ignore handling, cancellation, usage migration/counting, and coordinate mapping.

Responses transport tests check the single-model configuration, complete session-history context, strict structured output, and screenshot-bearing continuations. Boundary-synchronizer tests check coalescing, absence of overlapping finalization calls, invalid/old targets, cancellation, late completions, and failure retirement.

A passing suite does not establish microphone recognition quality, semantic intent accuracy, compositor appearance, or end-to-end Mac control. It also does not prove that an application will accept a posted input event.

### Real streaming-speech integration check

```sh
./Scripts/check-live-transcript.sh
./Scripts/check-live-transcript.sh --gaps 0.25,0.8,1.5
./Scripts/check-live-transcript.sh --without-boundary-sync
```

This check feeds the bundled synthetic recording through the real Apple analyzer at playback speed, using production audio conversion, transcript assembly, wake state, accurate finalization, and the shared boundary synchronizer. It inserts different pauses after “Hey Mouse” and requires at least two growing provisional previews during the command's first three seconds. Speech assets must already be installed; it does not download them, open the microphone, call OpenAI, or execute desktop actions.

The default report is `work/live-transcript-check/results.json` in this workspace. `MOUSE_TRANSCRIPT_CHECK_DIR` changes the build/report directory; `--output /path/to/results.json` changes the report path. Each run records timings and transcript events. `--without-boundary-sync` is a diagnostic comparison mode that deliberately disables the fix and can fail the preview check; it does not change the app.

The earlier speech-validation run passed all three gaps (0.25, 0.8, and 1.5 seconds), with growing provisional updates in each case. Its report is [`mouse-streaming-speech-results.json`](/Users/sameemsaleem/Product/work/mouse-streaming-speech-results.json). This verifies the synthetic streaming fixture's checks, not microphone recognition quality or total voice-to-action latency. The report explicitly records `microphoneUsed: false` and `apiUsed: false`.

Historical live-preview results observed on this Mac on 2026-10-19, before the newer endpoint/capture/routing changes:

| Gap after wake phrase | Fixed check | First command preview after command audio starts |
|---|---|---|
| 0.25 s | Pass | 0.982 s |
| 0.8 s | Pass | 1.352 s |
| 1.5 s | Pass | 0.657 s |

With boundary synchronization disabled, the 0.25 s case failed: its first preview arrived 6.006 s after stream start, versus 2.552 s with the fix. The longer-gap baseline cases passed because the engine naturally closed the old segment. These are sample-specific measurements, not latency guarantees. The fixture uses a known wake boundary and does not test microphone endpoint detection, the complete `VoiceInput` lifecycle, notch rendering, or end-to-end voice control.

### Local UI and speech checks

Preview the notch without microphone capture, API requests, or desktop input:

```sh
../Mouse.app/Contents/MacOS/Mouse --notch-preview active
../Mouse.app/Contents/MacOS/Mouse --notch-preview transcript
../Mouse.app/Contents/MacOS/Mouse --notch-preview action
../Mouse.app/Contents/MacOS/Mouse --notch-preview thinking
../Mouse.app/Contents/MacOS/Mouse --notch-preview cycle
```

`standby` and `notice` are also supported. Preview mode remains running until the process is quit; `cycle` returns to the active indicator after showing sample states.

```sh
../Mouse.app/Contents/MacOS/Mouse --diagnostics
../Mouse.app/Contents/MacOS/Mouse --voice-check /path/to/audio.aiff
```

Diagnostics reports saved-key availability, permissions, model configuration, and the speech engine without printing credentials. It is not an API connectivity test.

A finite microphone signal check is also available:

```sh
../Mouse.app/Contents/MacOS/Mouse --microphone-check
```

It uses Mouse's existing microphone permission and the production voice path for eight seconds. It reports audio level and live-preview counts without saving recordings or transcripts, loading the API key, or executing desktop actions. It does not request permission. A direct terminal invocation can have different permission attribution from a normal app launch; use the installed app identity when diagnosing permissions. A permission-only result is not a successful signal check.

The voice check locally transcribes a supplied recording of “Hey Mouse, open Chrome” using installed speech assets. It waits for finalized text and reports engine, locale, asset state, and timing. It does not capture microphone audio, request permissions, call OpenAI, or execute the command. Prepare speech assets through the app first if they are missing.

### Opt-in API smoke check

```sh
../Mouse.app/Contents/MacOS/Mouse --api-check
```

`--api-check` uses the saved key and makes **up to three billable Responses requests**, counted in usage. It validates a structured click against a generated TEST button, then returns a generated DONE screenshot to verify the function-result continuation.

The check neither captures nor controls the desktop. It verifies provider behavior against synthetic fixtures, not live microphone recognition or real app interaction. Quit the GUI before running it so only one process updates usage. Adding a check mode does not itself establish that its live API run has passed.

Settings is preferred for key entry. `--import-key` accepts a key on standard input and stores it in Keychain. `--api-check --key-stdin` accepts one for that check. Never put credentials in command arguments.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Build/test script cannot find Xcode | Install full Xcode and select its `Contents/Developer` through `DEVELOPER_DIR` if needed. Scripts do not modify global Xcode selection. |
| Saved key exists but shows **Needs authorization** | Use **Reconnect saved key** in Settings. An ad-hoc rebuild may require fresh Keychain authorization. |
| Screenshot or input permission error | Check Mouse's Screen Recording and Accessibility permissions in System Settings; reopen it if macOS requests a restart. |
| Voice cannot start | Check Microphone access, English (US) speech support, asset setup status, and the specific Settings error. There is no legacy recognizer fallback. |
| Voice reconnects after a device change, stall, or backlog | Incomplete audio and the current task are discarded. After recovery, say “Hey Mouse” and repeat the command. If three restarts in 60 seconds fail, resolve the specific Settings error and enable the microphone again. |
| Background sound is still transcribed | Mouse uses normal microphone input without app-level noise suppression or speaker identification. Text-only screening can ignore it before interrupting work, but cannot guarantee rejection of every background command. |
| No notch is visible | Standby deliberately has no overlay. Say “Hey Mouse” or choose **Activate Mouse**; ensure the microphone is running. |
| Words change while speaking | Faster live results are provisional. Only the separate finalized transcript is used for a command. |
| Live words are delayed after a wake phrase or completed command | Rebuild with the boundary-synchronization fix and run the streaming check. It distinguishes consumed-boundary suppression from the speech engine's own latency; passing it does not prove microphone or UI behavior. |
| A command starts before the whole sentence is spoken | The 500 ms threshold is not semantic end-of-turn detection. Further speech is screened as a continuation; existing work continues until a command is accepted. Already dispatched input cannot be undone. |
| Spoken Stop is delayed | It acts when the recognizer reports the initial word; it no longer waits for the final pass. Recognition and callback scheduling still take time. **Stop Mouse** in the menu sends a direct cancellation request. |
| A follow-up loses earlier details | Accepted commands are retained for the current app process, with full text and outcomes. Restarting clears them; ignored utterances and requests stopped before Luna accepts them are not recorded. Luna can still fail to use the supplied context correctly. |
| Model request fails or times out | Check the displayed error and Luna/model-service access. Requests have a 30-second timeout and are not automatically retried or routed to another model. |
| Usage cannot be loaded/saved | The warning explains whether the app is counting only in memory. Requests remain enabled. Avoid running the GUI and API check together. |
| Notch placement is wrong in another Space, fullscreen app, or display | These presentation cases remain deferred; capture's display coordinate support does not imply complete overlay-placement support. |

## Current limits and deliberate decisions

- The app targets this Mac's native notch workflow. Spaces, fullscreen behavior, and multiple-display overlay placement need further work.
- Speech currently targets English (US) on supported Apple silicon hardware. Wake monitoring continuously runs the local recognizer.
- Live text and final command text have different roles. Wake and initial-word Stop use volatile recognition; ordinary computer actions still require the separate accurate final pass.
- Standby is local. Once active, even speech ultimately ignored by Luna sends text and uses a screening request. Accepted speech adds a separate text-only round trip before action inference.
- Speculative capture overlaps final speech only while idle and has candidate/focus/display/freshness checks. It is not sent to the speech filter. Same-app content and keyboard focus can still change during model inference; the screen is not locked.
- Target selection is screenshot-based. There is no accessibility-tree reader, native AX-action route, DOM reader, browser extension, or OS-wide catalog of apps and clickables.
- Follow-up context preserves every Luna-accepted command for the running app session, with full text and outcomes. There is no persistent memory, full conversational transcript, or automatic history compression. Large histories increase input size and can reach provider context limits.
- Stop acts on a recognized initial word, which can create false positives such as “stop by later.” Cancellation is cooperative and cannot reverse events already sent to another app.
- Mouse has no app-level noise suppression, Krisp integration, or speaker verification. Background voices can still produce text, and a background command may be mistaken for directed intent. The separate text check reduces unwanted interruptions; it does not authenticate the speaker.
- A deliberate 1000 ms settling delay follows every executed batch before capture and the next action-model request. It is separate from the 500 ms speech endpoint; total latency also includes transcription, speech screening, capture, network, inference, and input.
- Strict action validation rejects malformed input, but does not guarantee correct intent, correct targets, or safe application behavior.
- Action batches are bounded to 12, but the number of batches and total request count are uncapped.
- This local app is ad-hoc signed and not sandboxed. Rebuilds can require renewed permissions or Keychain authorization. Distribution requires Developer ID signing, notarization, and further testing.

## Deferred or excluded work

These are design directions, not current behavior. The latest changes retain the second transcription pass, exclude speaker-specific recognition, and keep an image in every action-model request. The separate speech check uses text only.

| Proposal | Intended change and decisions still required |
|---|---|
| Remove the separate final pass | Assess whether the continuous analyzer's finalized results can provide equally complete, timely utterance boundaries. Measure omissions, revisions, leading/trailing words, and latency before replacing the current accuracy-oriented handoff. This is independent of making provisional text appear promptly. |
| Speaker-specific recognition | Requires enrollment and speaker verification; ordinary noise processing does not distinguish the owner from nearby speakers. Not included. |
| Selectively omit screenshots from action inference | Not included. Every action request keeps the image to avoid an image-needed follow-up round trip. Speech screening is always text only. |
| Browser DOM integration | A browser extension or other supported integration could expose richer page structure beyond AX; no DOM reader is installed. |
| On-device Apple decision model | Remains an alternative to benchmark; no local decision inference path is implemented. |
| Additional screenshot downsizing | The proposed 40% mode is not implemented. Existing capture dimensions and coordinate mapping remain in use. |
| Spaces/fullscreen/multiple-display overlay behavior | Presentation work remains deferred; capture geometry support is separate from notch-placement support. |

Changes to live preview should be verified against actual streaming speech as well as deterministic state tests. Changes to capture, context, or Stop should have their own explicit behavior and regression checks rather than being assumed to follow from a transcript-display fix.
