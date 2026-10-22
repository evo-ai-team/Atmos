# Mouse

Mouse is a native Mac voice interface for clicking, typing, scrolling, and navigating apps. It lives in the menu bar. Its everyday interface expands from the notch using native Liquid Glass. Only the measured camera cutout is fully black; a smooth rounded fade spans the extension and reaches clear glass at its sides and bottom. The material has reduced strength and no extra black wash, keeping the background visible. Thin, varying side and bottom reflections disappear before the top corners. Small concave shoulders curve into the screen's top edge, with a 6-point radius across active, transcript, and action sizes. During collapse, those insets shrink on the same animation progress as the panel, so the visible left, right, and bottom edges reach the hardware notch together. The panel does not take keyboard focus or intercept clicks. Reduce Transparency uses an opaque charcoal backing, and screens without a camera cutout use glass throughout.

**This is the canonical project README.** It covers current behavior, setup, architecture, data handling, verification, limitations, and proposed work. The proposals at the end are not implemented behavior. Source review date: **2026-10-21**. The descriptive history is in [CHANGELOG.md](CHANGELOG.md).

The app to open is **`/Users/sameemsaleem/Product/Mouse.app`**. This source project is **`/Users/sameemsaleem/Product/Mouse`**. Build and diagnostic intermediates stay in a temporary directory unless an optional workspace `work/` directory or an output override is provided. Source, fixtures, and the runnable app are kept separately.

## Requirements

| Requirement | Current configuration |
|---|---|
| Mac | Apple silicon, macOS 26 or later |
| Build tools | Full Xcode 27; Command Line Tools alone are insufficient |
| Speech | Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`, with supported English (US) model assets |
| Computer-control models | OpenAI API key with Responses access, plus Decisions access for either Decisions mode. Both endpoints currently use the model ID `gpt-6-luna`. The selected behavior uses Responses alone or Decisions with Responses fallback. Intent acceptance and first-action selection share a request; there is no separate speech-screening API call. |
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

Activation persists between commands until you say **“stop”** or choose **Stop Mouse** from the menu. Each completed spoken or typed utterance goes to the selected action model, which accepts or ignores its intent and chooses the next operation in the same request. There is no fixed command vocabulary, app-name list, grammar filter, or separate speech-screening model call.

**Settings → Behavior & logs** offers three persisted modes:

| Chatbot behavior | First request and later steps |
|---|---|
| **Luna only** | Responses receives the screenshot, full captured AX tree, and task context, then generates an action, completes, asks for needed information, or ignores the utterance. Decisions is never called. |
| **Decisions + screenshot** | Decisions receives the screenshot, compact AX context, and simple native options. It selects a native action or control route; Responses handles generation or review when needed. |
| **Decisions · text only** (default) | Decisions receives compact AX text and native options with no image. Responses receives the screenshot only when fallback or review is needed. |

A command keeps the mode selected when it was submitted, including its later steps. Changing the picker affects subsequent submissions. A native option's short number resolves locally to the exact retained control and operation; the model does not reconstruct a target from its label. Requests such as “make this bigger,” “and his store,” and “can you open that?” use accepted-command context and the current observation. The prompts distinguish directed requests from conversation, informational questions, quoted instructions, and hypothetical commands; in mixed speech they use the clear computer request and disregard unrelated conversation. They do not identify the speaker, and model judgments can still be wrong.

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

The only local sleep control is **“stop” as the first word**, ignoring case and ordinary boundary punctuation. It works from provisional text without the quiet endpoint, second pass, or API check: “stop now” and “stop listening” also sleep Mouse. “Stop by later” can therefore sleep it too. Quoted “stop”, “don't stop”, “type stop”, and words such as “stopwatch” do not match. “Cancel” and “go to sleep” are not local controls. While active, Mouse accepts continuations and corrections during model requests and execution. The existing task continues until the selected action model accepts a command and classifies how it relates to the current task. “Hey Mouse” also activates from the live result; ordinary spoken commands wait for a stable endpoint and the optional second transcription pass before that model request.

The notch has no buttons. The menu provides activation, Stop, Settings, microphone pause/resume, and Quit. Typed requests and recent activity are under **Testing & recent activity** in Settings. Settings hides during execution and does not reopen after every task. Previous clicks or typing are not undone by Stop.

### Audio controls and stage timings

Open **Settings → Behavior & logs** to choose the chatbot mode, adjust speech capture, and inspect timings.

- **Audio sensitivity** adjusts the speech-activity energy threshold, not microphone gain. The default **50%** preserves the original 0.006 RMS threshold. Higher sensitivity detects quieter sound and may also count more background noise as speech. The slider updates the activity gate without restarting capture or modifying recorded samples.
- **Second transcription pass** defaults **on**. Turning it off uses the fast live transcript at the same 500 ms quiet/stable endpoint, with the same candidate, audio-progress, cancellation, and consumed-boundary checks. The setting is read at the next endpoint and does not interrupt a replay already running.
- **Latest command** shows the latest accepted command's total elapsed time, first-input time when available, outcome, and per-stage durations. Its trace is retained separately, so ignored or cancelled background utterances do not displace it. The copy button copies that command's detailed timing report.
- **Full timing logs** retains the latest ten traces, including ignored, failed, and cancelled utterances. **Copy timings** copies those reports with stage offsets, durations, outcomes, and transport metadata.

Spoken timing starts at the shared audio meter's last detected speech activity and includes the quiet endpoint. That timestamp can predate the current utterance, so long endpoint rows can include earlier quiet or idle time; they are not necessarily time spent waiting on the current command. Typed timing starts at submission. A continued task has its own trace. First input means the actual CGEvent or accessibility dispatch attempt, not proof of a visible UI response. Total elapsed continues through post-action observation and completion checks.

Stages cover endpoint waiting, optional local replay or fast commit validation, incoming-command queueing, initial intent/action selection, cancelled-input cleanup, focus restoration, screenshot acquisition/JPEG encoding, accessibility capture, request encoding, each API round trip, response parsing, action validation/dispatch, the 1000 ms settle wait, progress checks, and usage saves. Permission/Keychain refreshes during a command are also measured. A queue/screening stage name describes the admission workflow; it does not imply an extra screening API request. Speculative capture and replay can overlap: do not add stage durations to calculate total latency.

HTTP timings include network and server time together, not isolated model inference. Where URLSession provides metrics, request-specific rows also show setup/queueing, DNS, connection/TLS, upload, first-response-byte wait, download, and return to the client. These rows overlap: TLS is inside connection time, and response wait includes network transit and server work. URLSession's wall-clock phase dates are mapped approximately onto the monotonic trace.

Metadata lines record the selected behavior, transcription mode, payload sizes, connection reuse/protocol, HTTP status, request IDs, and provider-reported processing milliseconds when supplied. Decisions additionally records screenshot presence, context byte size, choice counts, and token usage. Metadata offsets show when information was recorded; they are not durations. Traces remain in memory, retain at most 256 stage records and 64 metadata lines each, and exclude prompts, screenshots, credentials, and response content. Missing or late transport metrics do not delay a request or change its result.

## How a command runs

```text
Microphone → normal audio input → live transcript
    ├─ initial “stop” → cancel + standby
    ├─ “Hey Mouse” → activate immediately
    └─ 500 ms quiet/stable endpoint
         ├─ second transcription pass, or fast live text when disabled
         └─ speculative screenshot + AX observation while idle
              → selected model checks intent and chooses the first operation
                   ├─ Luna only → Responses with screenshot/full context
                   ├─ Decisions + screenshot → compact context + image + native options
                   └─ Decisions text only → compact context + native options, no image
                        ├─ ignore or failed request → leave current task alone
                        └─ accept → retire old work and await input cleanup
                             → reuse the selected first turn if still valid
                             → otherwise refresh observation and reselect
                             → validate and dispatch native AX or generated input
                        after execution → wait 1000 ms → fresh observation → same mode
```

In either Decisions mode, a generation/review selection adds a Responses request with the screenshot and full context. The initial accepted turn is cached, so normal admission does not call the model again just to repeat its selection. If input was already in flight or existing work advances while a concurrent utterance is being assessed, the accepted request can require a new observation and selection after interrupted input has cleaned up.

### Live speech and final text

`VoiceInput` keeps the microphone stream and live analyzer running between commands. `SpeechAudioFeed` copies and converts incoming audio through bounded queues. Microphone callbacks do not perform model requests. The live transcriber uses volatile, faster results and audio time ranges. These results drive provisional notch text while idle. With the second pass disabled, their stable endpoint text is also the text submitted for model acceptance.

After **500 ms of quiet audio and stable text**, checked every **10 ms**, Mouse either starts the enabled second transcription pass or commits the live text directly. The default replay retains leading audio and trailing silence so words at the boundaries are not intentionally clipped. The microphone and live analyzer continue during this pass, and Mouse waits for its complete final result stream. Fast-only mode skips that replay; it rechecks raw speech activity, converted-audio progress, and candidate identity before committing. New audio or transcript revisions invalidate an unfinished candidate and its speculative capture in both modes.

The 500 ms value is an endpoint threshold, not total command latency. Optional final transcription and speculative screenshot capture overlap while idle. The selected action model combines intent acceptance with action inference; there is no additional screening model round trip. Capture, networking, model execution, and desktop input still add time. A longer pause can still split a request; subsequent speech is assessed as a possible continuation. The second pass has a 12-second timeout. Audio retention is bounded: a processing backlog, stalled input, or an unfinished utterance longer than roughly a minute discards the incomplete utterance and initiates recovery rather than submitting partial audio.

Wake and Stop act on live recognition. Other words wait for the stable endpoint; the second pass determines submitted text when enabled, and the live transcript supplies it when disabled. Continuous local recognition is not a dedicated low-power wake detector.

Mouse uses the microphone's normal audio input. The added `AVAudioEngine` voice-processing, bypass, and other-audio ducking configuration was removed after a report of missing microphone audio. Mouse does not enable app-level noise suppression or enroll a voice profile. Nearby people and background speech can still be recognized.

### Intent acceptance, continuations, and changes of mind

The live recognizer and optional replay remain available while a task is running. Raw audio activity, provisional words, and a pending admission request do **not** suspend the task or replace its notch presentation. The selected action model assesses directed intent and chooses the next operation together. The normal command path does not call `SpeechIntentFilter`; that earlier separate Responses screening round trip is gone. Both typed submissions and completed speech use this combined path.

Incoming utterances are assessed serially in arrival order, independently of the running task's cancellation generation. The request receives the current goal, pending accepted fragments, clarification, progress, and accepted-command history. Decisions uses the full current request and goal, the last three accepted commands, and the latest 12 dispatch summaries; Responses uses full session history and task context. In image-bearing modes, the screenshot is supplied before intent is known, including to requests that eventually ignore the utterance. Ignored speech or a failed admission request leaves existing work running. Stop, microphone deactivation, and leaving the active session cancel pending checks and invalidate queued results, so a late response cannot reactivate Mouse.

An accepted model result interrupts existing work. Cancellation invalidates the running task's generation, and the replacement waits for old input cleanup. Mouse retains the selected first turn and its observation; it reuses them when still valid rather than asking the model to select again. If input was in flight or existing work progressed while a concurrent input was assessed, Mouse refreshes the observation and reselects after cleanup. A partially dispatched click, drag, or typing operation is recorded as uncertain; already posted input cannot be undone. The existing task may continue making progress while a possible correction is transcribed and assessed.

Pending accepted fragments accumulate in order without truncation. For an active-task amendment, either Decisions mode asks a second finite-choice question in the same selection request: `revise`, `replace`, or `needs_planner`. Native and completion choices remain available. If a native operation or completion is accepted with a resolved relationship, Mouse records the change locally: revisions retain a separate base goal and ordered amendments, with later amendments overriding only conflicting requirements; replacements abandon the previous pending goal. A generated structured `task_update` supplies a complete resolved goal when free-form planning is needed and resets that composition base. If generation concludes that a new active-task amendment is already satisfied, `complete_task` must include that update before completing it. `needs_planner` routes to generation before action or completion. Luna-only mode uses generated task updates directly and never invokes Decisions.

“Actually, search MKBHD instead” can change one part while retaining the rest; “forget that, open Calculator” can replace the sequence. The action prompts resolve short follow-ups from recent accepted context and the current screen. A pending clarification is supplied explicitly so “the second one” can address it. These are intended model behaviors, not guarantees of semantic accuracy. The full accepted utterance is retained; the prompt disregards unrelated words in a mixed utterance, but no separate extractor removes them from the stored text.

Revisions retain completed progress. Replacement abandons the former goal but retains its physical effects as background; Mouse starts from the current screen rather than assuming the computer reset. Background speech still uses the selected mode's admission request, but an ignored result does not cancel or restart existing work. Cancelling an API request does not guarantee the provider stops processing or billing it.

While waiting for an action-model response, the notch shows a compact **ring of six solid-white dots with a faint glow**. The loading body is 16 points wider and 56 points taller than the hardware notch, plus the existing 6-point outer shoulders on each side, with a 30-point ring view. All six simultaneously grow, fade from zero to full opacity, and move from the center to their ring positions over 400 ms, with the slow rotation already running. An overlapping size pulse then passes around the ring. When the response arrives, they shrink away in quick sequence before the next presentation. This visual transition does not delay execution. Reduce Motion uses a stationary ring and immediate removal. While busy, additional speech leaves that presentation or the current short action description intact until accepted as a command.

### Retained audio and recovery

Audio retention follows detected speech independently of the recognizer's first text result. This keeps leading speech while Apple is still preparing its first words, rather than dropping it with an eight-second idle-silence buffer. Coarse recognizer ranges that start in trimmed silence no longer automatically imply missing speech. If timestamps cannot prove that the replay covers the whole utterance, the replay must match the normalized live words; an uncertain shortened or revised replay is discarded rather than executed.

Recoverable stream/device/finalization failures discard unfinished audio and text, cancel current computer work, and restart in **standby**. Mouse attempts at most three restarts in a rolling 60-second window, delayed by 0.3, 0.8, and 1.5 seconds. A successful restart requires “Hey Mouse” again and a repeated command. Exhausted recovery reports the specific failure and leaves the microphone disabled until explicitly enabled. Pausing the microphone invalidates pending restarts.

### Live-transcript boundary fix

The live analyzer and accurate replay pass maintain independent audio boundaries. Previously, after Mouse consumed a wake phrase or utterance, Apple could return a coarse provisional segment starting before that consumed boundary but also containing new words. Mouse's filter rejected the whole overlapping segment, hiding the new command's live text until the analyzer naturally closed the segment. This was conditional: longer gaps could let the engine close the segment by itself.

`SpeechBoundarySynchronizer` advances the live analyzer through Mouse's consumed-audio boundary after commits, resets, and discards. It serializes finalization calls, combines pending requests into the newest boundary, and retires with its analyzer lifecycle so late callbacks cannot affect a replacement stream. A boundary-finalization failure enters the bounded recovery path. The strict old-audio filter remains intact, and repeated identical preview text is not republished.

This boundary fix supports growing live previews across consumed boundaries. Endpoint timing, parallel capture, session memory, and immediate Stop are separate mechanisms; a preview test does not measure their end-to-end behavior.

### Capture and focus

While idle, **observation capture starts at an active utterance's quiet endpoint**, alongside the second transcription pass when enabled. Mouse takes the screenshot and then reads the foreground accessibility tree against its geometry. The selected model receives the resulting context while deciding whether to accept the utterance; screenshot upload follows the selected behavior mode, even when the result is ignore. The observation is reusable only for the same finalization-candidate ID and command generation, the same foreground process, unchanged display geometry, and an age of at most **1.5 seconds**. Revisions, cancellation, changed focus, an expired capture, or a failed capture cause it to be discarded; Mouse captures again before action inference. Speculative capture is skipped while a task is running and when Mouse itself is frontmost. Assessment during a task uses an independent AX owner so a background utterance cannot replace the native handles used by current work. An accepted redirect waits for interrupted input cleanup; if input was in flight or current work progressed during assessment, it captures a fresh screen and reselects.

If a typed request has put Mouse Settings in front, `AppModel` attempts to reactivate the previously active application and waits 220 ms. It hides Mouse's visible key/main windows. The nonactivating, click-through notch can remain visible, but ScreenCaptureKit excludes all windows owned by Mouse from the captured image, including any image later sent to the Responses planner.

At the start of a command, `NativeComputer` chooses the display under the pointer, with the main display as a fallback. That display stays selected throughout the command. Capture uses logical display dimensions, capped at **1600 image pixels wide**, preserving aspect ratio, and encodes JPEG at **78% quality** in memory. There is no additional 40% scaling. The cursor and menu bar are included.

Screenshot coordinates map back to global display coordinates, including scaled screens and negative display origins. Display geometry and the foreground process are checked before actions. Capture also checks that the foreground process did not change while the screenshot was gathered, with one fresh attempt if it did. These checks do not prove that the same app's content or internal keyboard focus stayed unchanged during inference.

After each native operation or generated action batch, Mouse waits a nominal **1000 ms**, then captures a fresh screenshot and AX tree before asking the same selected model mode for the next step. Scheduling may make the wait longer, and capture, network, and model time are additional; the full step is not promised to finish in one second. The wait is cancellable by Stop or an accepted new command, not raw speech alone. The planner is instructed to end a batch after navigation or a screen transition so the next step uses a fresh observation. Screen content can still change after the fixed delay. **Decisions · text only never attaches a screenshot to Decisions.** Decisions + screenshot attaches one; Luna-only and Responses fallback also receive it. Capture supplies local geometry and progress checks in every mode.

### Accessibility capture and native actions

`AccessibilityController` first reads the application's AX role to initialize native accessibility in browsers such as Chrome, then reads the foreground app’s focused/main window and menu bar. It retains top-level menu controls, prioritizes standard content regions (`AXWebArea`, `AXScrollArea`, `AXOutline`, `AXTable`, `AXTextArea`) over ordinary window descendants, and puts deeper menu contents last. Order is breadth-first within each priority; pending lower-priority work can be replaced by newly discovered content. This prevents wide navigation branches from reserving every capture slot before deeply nested page/list/editor controls are reached. Where supported, visible children are preferred to the ordinary child list. It exposes snapshot-local IDs, parent/child links, roles, labels, bounded values/help, enabled state, supported actions, and screen/screenshot bounds. This uses standard macOS accessibility roles across apps, with no Chrome extension, DOM reader, or browser-specific automation API.

The read runs on its own actor with a **750 ms capture budget**, **50 ms per-message timeout**, and limits of **600 nodes**, **48 children per node**, and **320 characters per exposed text attribute**. There is no separate depth cutoff: nested wrapper nodes can be traversed while node and time budgets remain. The iterative traversal does not grow the call stack with tree depth. The larger node allowance can increase read work and model input; it does not increase the time budget or the 249-native-choice limit. The snapshot explicitly reports unavailable data and truncation. Large or slow app trees can therefore be incomplete. Offscreen elements may appear in the tree, but only enabled, non-secure controls with valid visible screenshot bounds can become native action choices. A missing element does not prove that no such control exists.

Secure text fields expose no text or action choices, and their descendants are not traversed. Other readable values can contain private content and are sent as UI evidence. Screenshots can still show sensitive information. Native action labels use control names or generic role names, never field values or help text.

A native choice maps to exactly one of **`AXPress`**, **`AXShowMenu`**, **`AXIncrement`**, or **`AXDecrement`** on a retained native handle. Immediately before dispatch, Mouse checks the snapshot, foreground process/window, target identity, role, label, geometry, enabled state, and supported operation. A failed or ambiguous AX operation is not blindly retried as a mouse click because its effect may already have occurred. Mouse/keyboard input remains available through the generative fallback.

### Model protocol and execution

The selected mode determines which endpoint assesses intent and chooses operations:

| Request | Input and output |
|---|---|
| Luna only: `OpenAIComputerClient` → Responses | Screenshot, full captured AX tree, complete accepted-command history, and explicit task context. Accept or ignore new intent while generating a structured operation, task update, completion, or clarification. No Decisions call. |
| Selection: `DecisionsClient` → Decisions | Current request/full accepted goal, clarification, last three accepted commands, latest 12 dispatch summaries, up to 100 meaningful AX text/state rows, and simple native options. A screenshot is included only in **Decisions + screenshot**. Choose a native option, generation, review, evidence-backed completion, or ignore for new speech. An active-task amendment adds a revise/replace/needs_planner question in the same request. |
| Generative fallback/review: `OpenAIComputerClient` → Responses | Screenshot, full captured AX tree, complete accepted-command history, and explicit task context. Supply the structured operation, resolved goal, or user-facing clarification that Decisions cannot generate. Review permits only a pause for user input. |

**Both endpoints currently use the identifier `gpt-6-luna`; their capabilities and schemas differ.** Decisions is a closed-choice classifier and cannot invent coordinates, typing text, a new goal, or a clarification question. It has no `fast` service-tier flag, reasoning-effort flag, or tool-generation schema. Responses continues to request the existing `fast` service tier and `low` reasoning in Luna-only and fallback mode. Intent acceptance adds no separate Responses request ahead of the selected mode.

`ComputerDecisionOptions` offers at most 249 concrete native operations, plus fixed routes, within Decisions’ 255-choice limit. Candidate coverage is unchanged; the prompt, option descriptions, and context are shorter. Snapshot-qualified question names and exact choice validation reject stale, mismatched, refused, or invented selections. Continued tasks have no ignore option because there is no new utterance to classify. Unsupported operations and uncertain targets go to generation instead of being approximated by an unrelated native click. Text-only Decisions also routes visual inspection to generation. In text-only mode, completion requires explicit current AX text/state proving the entire goal and is unavailable when that evidence is empty; image-bearing Decisions can additionally use explicit screenshot evidence. Missing options and past dispatches are not completion evidence. Active-task amendments retain eligible native and completion choices while the same request classifies their relationship to the accepted goal. A `needs_planner` relationship prevents native dispatch or completion and routes to generation; ordinary revisions do not automatically require another round trip. These payload reductions do not establish a measured latency or accuracy improvement.

Selection instructions prefer an offered native action that matches the immediate next operation. Truncation elsewhere in the tree does not disqualify a valid visible target, and a later unsupported step in a multi-step goal does not force the current step to generation. **Settings → Testing & recent activity** shows the latest selected route, native-choice and element counts, unavailable/partial-tree status, and task relationship when classified. Completed step entries retain the route used: **Native accessibility**, **Responses fallback**, or **Luna Responses** (Luna-only mode). Review uses **Responses clarification**. A latest selection alone does not prove dispatch succeeded. **Actual input** separately shows the executor route and action types, screenshot coordinates, non-text shortcuts, typing character counts, or explicit `screenshot (no input)` / `wait (no input)`. Native traces identify the AX operation, snapshot-local ID, and role. Typed text and AX values are omitted. All 20 recent entries and the last accepted goal are visible in Settings; these diagnostics are local, in memory, and add no API calls.

Each native choice has a short numeric value and a description such as `Click "Home" (button)`, with up to two bounded, named ancestors to distinguish repeated controls. The returned number maps locally to the exact retained AX element/action; Mouse never reconstructs a target from the label. Field contents and help are excluded from these descriptions. The 249-choice cap admits primary activation/adjustment actions before context-menu actions, retaining capture priority within each group. The verbs are **Click**, **Open menu for**, **Increase**, and **Decrease**; opening a context menu is distinct from ordinary activation. The compact UI summary retains up to 100 useful text/state rows, prioritizes landmarks and control state, avoids repeating ordinary option labels, and explicitly reports unavailable, incomplete, omitted, and redacted evidence. It sends no full hierarchy, element IDs, geometry, or help text. **Controls offered for last action** retains the exact native choices and capture-limit reasons associated with the latest dispatch attempt. It updates after foreground/observation validation, so a later failed observation or foreground check does not overwrite the previous attempt's evidence. The list survives completion and does not prove the attempted action succeeded. Search it for an expected control to distinguish a missing candidate from a model-selection issue; a large total count alone does not show that the required control was available.

A **review** selection remains distinct from ordinary generation. Its Responses request must return `pause_for_user`; executable actions are forbidden and rejected. Review is reserved for missing authorization, irreversible-action confirmation, or authentication/security UI. Ordinary target uncertainty goes to generation, which may resolve the referent and act from the supplied context rather than being forced to ask a question. The prompts distinguish permanent deletion from clearing recently entered search text; a pronoun such as “delete it” is not by itself a reason for review. If material ambiguity remains after consulting context and the current screen, generation can still request clarification.

| Generative result | Meaning |
|---|---|
| `execute_actions` | One coherent operation with required `task_update`, short `description`, and 1–12 actions. |
| `pause_for_user` | Required target information, authorization, authentication, or review is missing. Includes `task_update`; no actions run with the question. |
| `complete_task` | Completion of a new amendment to an active task, with required `task_update` and `message`, and no actions. Only offered in that amendment context so the changed intent is recorded before completion. |
| `ignore_utterance({})` | Silently reject a new non-action utterance without a conversational reply or desktop action. |
| Final message | Report completion after inspecting the resulting screen when no new active-task amendment requires a goal update. |

Generated descriptions aim for 3–6 words and at most 64 characters, such as “Searching Linus Tech Tips…”. Native operations use short local descriptions. Both describe work in progress. The generative parser rejects malformed, incomplete, refused, mixed, or multiple operations, and the controller validates every action in a batch before posting its first desktop event.

Luna-only mode and Responses fallback support click, double-click, pointer move, scroll, drag, Unicode typing, keypress, wait, and screenshot actions. Pointer actions support Command, Control, Option/Alt, and Shift modifiers. Keypress supports common navigation keys, Enter, Escape, Space, Tab, F1–F20, and supported printable keys. Invalid fields, unsupported keys, nonfinite/out-of-bounds coordinates, and invalid action sizes fail explicitly. Typing uses Unicode events without changing the clipboard. There is no shell or scripting tool.

After an operation, the app asks **the same selected mode with a fresh observation and explicit context**. Luna-only stays on Responses; either Decisions mode returns to Decisions after a generated fallback. The live action loop no longer uses a `previous_response_id` Responses chain; native operations between generative calls would make that chain incomplete. The Responses continuation helper remains for the isolated API diagnostic only. Requests time out after 30 seconds and are not automatically replayed. **There is no per-command step limit or cumulative request cap.** The loop ends on verified completion, a request for user input, an error, cancellation, or a detected unchanged-state replay. `ActionProgressGuard` pauses while retaining the accepted task after three consecutive identical dispatched batches whose before/after screenshots are byte-for-byte identical, including continuity between batches, matching process, and matching display geometry. Native identity uses role/label/bounds/action rather than snapshot-local IDs. A changed image, target, batch, process, or display breaks the streak; explicit waits and native increments/decrements are exempt. This is a conservative loop safeguard, not a global step cap or proof that nothing happened internally. Animation, cursor movement, JPEG variation, alternating actions, and wait loops can evade it. It does not automatically retry input through another route. The fallback prompt also states that its attached image is already the fresh observation and that repeatedly requesting another screenshot is not progress.

Both model prompts treat screen and AX text as untrusted evidence and require review before unauthorized sensitive or irreversible actions and authentication/security prompts. Prompt instructions and structural validation do not guarantee correct intent, correct targets, or safe application behavior.

### Cancellation

Stop invalidates the current command generation, cancels its task, and separately cancels pending intent/action assessments and queued results. Late responses cannot resume that command or reactivate the session. Execution checks cancellation between actions and within typing and drag loops. Cleanup releases synthesized mouse buttons and modifier keys when an operation is interrupted.

Already posted input cannot be recalled: previous clicks, text, scrolling, or application side effects are not undone. Spoken Stop now bypasses endpoint/finalization once its initial word is recognized, but it still depends on recognition and callback scheduling. Cancellation is cooperative rather than a hard real-time guarantee. The menu's **Stop Mouse** avoids recognition delay, but does not undo input either.

## Context, privacy, and storage

### What Mouse remembers

Mouse supplies explicit accepted-goal, amendment, dispatched-action, and pending-clarification context on each Decisions request and each Responses planning request. Decisions receives the full current request and accepted goal, the last three accepted commands, and the latest 12 dispatch summaries, with explicit omitted counts. The planner retains complete history and action details. There is no live server-side Responses chain. Native dispatch records describe the semantic operation and target; old snapshot IDs are not reused as future targets. A new amendment receives the accepted goal and progress during combined intent/action selection. Decisions classifies revision versus replacement alongside its operation selection, with unresolved relationships delegated to generation. Local native revisions preserve the base goal and ordered amendments; a generated complete goal replaces that composition base. Superseded history entries are marked paused with a revision/replacement outcome, not completed. The first selection is retained for admission and execution when still valid; it is not a separate stateless screening call.

Between commands, Mouse keeps **every command the action model accepts during the current app session**, in order and with its full accepted utterance text. Ignored utterances do not enter this history. Unrelated words within an accepted mixed utterance can remain in that text, although prompts instruct the model to disregard them. Each record also retains its accepted goal and last dispatched input description when available, plus running/completed/paused/stopped/failed status and the available result, pause reason, or interruption/error information. These fields survive completion when active task state is cleared. A native selection does not generate a rewritten goal, so its stored goal can still be the original fragment; its dispatched target description provides additional referent context. Neither field guarantees a fully resolved entity. Dispatch descriptions are evidence of attempted input, not proof that the intended UI effect occurred. Each Responses planner request receives the complete history as background context; Decisions receives the latest three entries without clipping their command text. The current utterance is supplied separately.

Admission happens only after the selected action model returns a valid response accepting computer-action intent. The same response also supplies the first selected or generated operation. Ignored utterances, and requests cancelled or failed before action-model admission, are not added. If an accepted task later stops or fails, its record remains with that outcome; it is not presented as completed. This is a record of accepted computer commands, not a transcript of everything heard. Luna's intent judgment can still be wrong.

History lives **only in the running app's memory**. Stop, sleep, and microphone pause preserve it; quitting or restarting Mouse clears it. Mouse does not write a command-history text file or restore commands from disk. This history does not replay actions or skip model calls. The models interpret a new utterance together with relevant accepted context to recognize task-directed fragments and resolve their referents. Earlier commands are background, not new instructions or fresh authorization: completed, stopped, or failed goals must not automatically resume, and context must not turn ordinary conversation or informational questions into tasks.

The locally retained history has no command-count cap, character truncation, or automatic summary. Longer sessions therefore increase planner input and can increase its token usage and latency. Decisions bounds the number of historical commands and dispatch summaries, reports omissions, and preserves the full current request and goal. Provider context limits still apply; the full planner history is not silently trimmed to fit them.

The separate activity list holds up to 20 entries in memory, and Settings shows the most recent entries. That display limit is independent of the accepted-command history and each model's context projection. Neither is restored after quitting. Screenshots, AX snapshots, and raw API responses are not copied into the cross-command history.

### Data boundaries

| Data | Current handling |
|---|---|
| Microphone audio | Processed locally by Apple's speech engine; bounded in-memory queues and retained utterance audio. Mouse does not save recordings or send microphone audio to OpenAI. |
| Apple speech assets | Prepared through Apple's `AssetInventory`; a model download may occur during setup. |
| Standby speech | Used locally for wake-phrase detection; no OpenAI request. |
| Completed active utterance | Sent to the selected model for combined intent acceptance and action selection, including utterances it ultimately ignores. Decisions receives compact text/AX context and optionally the screenshot; Responses receives the full captured observation and task context. Ignored utterances are not added to history; accepted utterances retain their full text. |
| Screenshots | Captured and JPEG-encoded in memory for local geometry/progress checks. Sent to Luna-only Responses requests, Decisions + screenshot requests, and Responses fallback/review. Never attached to Decisions in text-only mode. Image-bearing admission requests include the image before intent is known, even when the utterance is ultimately ignored. Mouse's own windows are excluded; other visible apps can be included. Mouse does not write these captures to disk. |
| Accessibility tree | Foreground window/menu tree read in memory. Decisions receives simple native options and up to 100 meaningful non-secure text/state rows, with omission/capture status; no full tree, element IDs, help, or geometry. Responses receives the full captured tree, which can include non-secure labels, values, help, roles, hierarchy, actions, and bounds. Secure text is excluded. Native handles remain local. |
| Accessibility permission | Used to read the tree, invoke offered native AX operations, and post mouse/keyboard input. |
| API key | Stored in macOS Keychain under the stable service `com.chosen.mac.openai`; not written to the repository or usage JSON. Routine reads do not intentionally prompt; explicit reconnect can ask macOS to authorize access. |
| Accepted-command history | Full command text, accepted goal, latest dispatched input description, task status, and outcome kept in RAM when available. Full history goes to the Responses planner; the latest three entries go to Decisions. Decisions also receives the full current goal and latest 12 dispatch summaries with omitted counts. Survives Stop/microphone pause; cleared when the app exits. No transcript file is written. |
| Recent activity | Up to 20 entries in memory; cleared when the app exits. Separate from the complete accepted-command history. |
| Request/token counters | Persisted to `~/Library/Application Support/Mouse/usage.json`. No transcripts, screenshots, or API key are stored in this file. |
| Behavior/audio preferences | Mode, audio sensitivity, and second-pass choice persist locally in UserDefaults. Defaults are Decisions text only, 50%, and second pass on. No command text or credentials are stored with these settings. |
| Login preference | Managed through macOS `SMAppService`. |

The app does not configure or promise zero retention by OpenAI. Data sent to the API is subject to the account's provider-side policies and settings.

### Usage accounting

The persisted counter records request attempts and returned input/output token totals for Decisions and Responses. Attempts are counted immediately before networking, so a request that fails or is cancelled still counts. Cancelling before that stage does not create an API attempt. There is no extra screening request: a new utterance's selected-mode request both assesses intent and supplies its first operation. An ignored result usually costs that one request, including an image in image-bearing modes; a Decisions fallback/review route adds a Responses request and can itself return ignore. A native step needs one selection request, including an active-task relationship in that same request. Luna-only steps use Responses directly. A stale first selection after concurrent task progress can require another selection after cleanup. Revisions with a resolved relationship and native operation do not automatically require generation.

The estimate in `DemoBudget` uses separate endpoint rates: **Decisions $0.10 per million input tokens, no output charge; Responses Fast $0.20 input / $1.00 output per million tokens**. Requests above 272,000 input tokens use the configured long-context premiums: 2× input and, for Responses, 1.5× output. Earlier totals and accumulated estimates are preserved rather than repriced when routes change. These are local constants, not a live pricing lookup; cache discounts/writes and regional premiums are excluded. The estimate is not a billing cap. OpenAI reports actual billing. Usage migration/read/write problems do not block requests: Mouse reports a warning and continues counting in memory. An unreadable prior file is preserved in a backup when possible.

Counters are not coordinated between multiple running processes. Quit the GUI before running the API smoke check to avoid competing usage-file updates.

## Source map and architecture

The Swift package separates testable core state/protocol logic from the native app. The Xcode app target compiles the same sources together; conditional `SWIFT_PACKAGE` imports keep both builds supported. `AppModel`, native input, and UI coordination run on the main actor. Network clients and AX reads use separate actors, and audio conversion uses a separate task.

Start with [Sources/README.md](Sources/README.md). Each maintained directory has its own README with responsibilities, entry points, and constraints. Domain directories organize the existing two modules; they do not add framework layers.

| Directory | Responsibility |
|---|---|
| [Application](Sources/Mouse/Application/README.md) | App/menu startup, accepted-task coordination, screen observations, and usage persistence. |
| [Interface](Sources/Mouse/Interface/README.md) | Settings and activity diagnostics, notch presentation, layout, and animation. |
| [Native speech](Sources/Mouse/Speech/README.md) | Audio input, live transcription, accurate replay, and engine recovery. |
| [Computer control](Sources/Mouse/ComputerControl/README.md) | Display capture, bounded AX reads/actions, keyboard planning, and balanced native input. |
| [Security](Sources/Mouse/Security/README.md) | Keychain storage and explicit key authorization. |
| [Diagnostics](Sources/Mouse/Diagnostics/README.md) | Opt-in API, microphone, and audio-file checks. |
| [Core accessibility](Sources/MouseCore/Accessibility/README.md) | Snapshot data, geometry, protected-field redaction, and traversal priority. |
| [Core actions](Sources/MouseCore/Actions/README.md) | Action/result types, native-choice routing, dispatch summaries, and progress guards. |
| [Inference](Sources/MouseCore/Inference/README.md) | Model transports, prompts, schemas, request policies, and strict response parsers. |
| [Session](Sources/MouseCore/Session/README.md) | Wake/Stop behavior, accepted-command history, task amendments, and capture freshness. |
| [Core speech](Sources/MouseCore/Speech/README.md) | Transcript state, audio-retention policy, ordered screening, and recovery rules. |
| [Usage](Sources/MouseCore/Usage/README.md) | Counters, estimates, and non-overwriting storage migration. |
| [Tests](Tests/README.md) | Offline regression tests organized by core domain. |
| [Scripts](Scripts/README.md) | Shared tool selection, builds, tests, transcript-check compilation, and icon generation. |
| [Tools](Tools/README.md) | Streaming speech integration harness and versioned synthetic fixtures. |
| [Resources](Resources/README.md) | App metadata, entitlements, and icon. |
| [Xcode project](Mouse.xcodeproj/README.md), [Package.swift](Package.swift) | Recursive source discovery and documentation exclusions for both builds. |

## Verification

The **2026-10-21 configurable behavior/audio update** passed **266 offline tests with zero failures**, including persisted preferences, both Decisions wire formats, first-pass commit boundaries, sensitivity, and structured timing snapshots. The Release build and signature verification passed. The settings layout was rendered with sample timings. No live API or microphone accuracy/latency benchmark was performed for these modes.

The earlier **2026-10-21 text-only Decisions update** passed **266 offline tests with zero failures**. The Release build and signature verification passed, and the canonical app was updated without relaunching it. Tests cover image-free requests, compact evidence, exact numbered-choice mapping, stale menus, and duplicate-name/state preservation. Live model accuracy and latency have not yet been measured for this update.

The **2026-10-21 source cleanup** passed **220 offline tests with zero failures**, following a 219-test baseline. The Xcode Release build and signature check passed with the domain directory layout. Build products and logs were kept in temporary storage; the runnable app was not replaced or relaunched. This verifies source integration and the covered state/protocol contracts, not live microphone, model, or desktop-input behavior.

The **2026-10-20 follow-up and routing correction** passed **219 offline tests with zero failures**. The canonical Release app built and its signature verified. The original generated logs were removed during workspace cleanup. Coverage includes accepted-goal/dispatch context, contextual screening wire data, two-question Decisions classification and stale-answer rejection, native revision/replacement state, structured amendment completion, and the deeper traversal fixture. Live inspection of the previous build confirmed the reported search-field clarification failures and a Cloudsurfer coordinate fallback. The retained native candidate list lacked the collection link, but could have belonged to the next observation; the diagnostic timing is corrected in this build. The new app was not relaunched and no permissions were refreshed. No live API or desktop-execution test of this build was performed, so the specific Cloudsurfer native click and model interpretation improvements remain unverified. Earlier validation records are in [CHANGELOG.md](CHANGELOG.md).

### Offline tests

```sh
./Scripts/test.sh
./Scripts/test.sh --filter 'DecisionsClientTests|ComputerDecisionTests|OpenAIClientTests'
```

Tests use mocked API transport and do not make live OpenAI requests. Settings tests cover preference defaults/persistence, sensitivity bounds, fast-only transcript commit protections, and structured timing snapshots. They cover unrestricted utterance forwarding, immediate initial-word Stop and wake, transcript revisions and finalization invalidation, 500 ms endpoints, speech-aware history and replay coverage, recovery limits, accepted-command history and outcomes, capture-candidate freshness, persistent activation, strict schemas, description/action parsing, native candidate bounds, stale selections, secure/disabled/offscreen exclusion, task continuation, review/pause/ignore handling, cancellation, endpoint-specific usage, and coordinate mapping.

Decisions transport tests check text-only and explicitly image-bearing request/answer contracts, absence of image fields in text-only mode, refusals, invalid probabilities, cancellation, and no retries. Router tests check the native candidate limit, partial-tree eligibility, short option IDs resolving to exact local targets/actions, snapshot identity, and disabled completion/ignore routes. Context tests cover bounded history/progress and AX evidence, explicit omissions, redaction, and preservation of current intent. Traversal tests exercise menu starvation, top-level menu retention, pending-node replacement, and the processed-plus-pending cap. Responses tests cover fresh explicit context, review-only generation, strict structured output, and the diagnostic continuation protocol. Boundary-synchronizer tests check coalescing, absence of overlapping finalization calls, invalid/old targets, cancellation, late completions, and failure retirement.

Follow-up regressions check retained goal/input metadata, full command text, explicit pending-clarification payloads, task-relationship contracts, and ordered native amendments across revision, replacement, and planner resolution. These deterministic tests verify state and request construction, not the model's live reference-resolution accuracy.

A passing suite does not establish microphone recognition quality, semantic intent accuracy, compositor appearance, or end-to-end Mac control. It also does not prove that an application will accept a posted input event.

### Real streaming-speech integration check

```sh
./Scripts/check-live-transcript.sh
./Scripts/check-live-transcript.sh --gaps 0.25,0.8,1.5
./Scripts/check-live-transcript.sh --without-boundary-sync
```

This check feeds the bundled synthetic recording through the real Apple analyzer at playback speed, using production audio conversion, transcript assembly, wake state, accurate finalization, and the shared boundary synchronizer. It inserts different pauses after “Hey Mouse” and requires at least two growing provisional previews during the command's first three seconds. Speech assets must already be installed; it does not download them, open the microphone, call OpenAI, or execute desktop actions.

The default report is `results.json` in the script's scratch directory (a temporary directory, or `work/live-transcript-check/` when the workspace has a `work/` directory). `MOUSE_TRANSCRIPT_CHECK_DIR` changes the build/report directory; `--output /path/to/results.json` changes the report path. Each run records timings and transcript events. `--without-boundary-sync` is a diagnostic comparison mode that deliberately disables the fix and can fail the preview check; it does not change the app.

The recorded streaming fixture passed the 0.25, 0.8, and 1.5 second wake-gap cases with growing provisional updates. This is a synthetic-audio integration check, not a microphone-quality or total voice-to-action benchmark. It uses a known wake boundary and does not test microphone endpoint detection, the complete `VoiceInput` lifecycle, notch rendering, or desktop control. Earlier behavior and validation are recorded in [CHANGELOG.md](CHANGELOG.md).

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

This is a **Responses-only protocol diagnostic**; it does not exercise the live Decisions/AX route. It neither captures nor controls the desktop, and verifies generated fixtures rather than microphone recognition or real app interaction. Quit the GUI before running it so only one process updates usage. Adding a check mode does not itself establish that its live API run has passed.

Settings is preferred for key entry. `--import-key` accepts a key on standard input and stores it in Keychain. `--api-check --key-stdin` accepts one for that check. Never put credentials in command arguments.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Build/test script cannot find Xcode | Install full Xcode and select its `Contents/Developer` through `DEVELOPER_DIR` if needed. Scripts do not modify global Xcode selection. |
| Saved key exists but shows **Needs authorization** | Use **Reconnect saved key** in Settings. An ad-hoc rebuild may require fresh Keychain authorization. |
| Screenshot or input permission error | Check Mouse's Screen Recording and Accessibility permissions in System Settings; reopen it if macOS requests a restart. |
| Voice cannot start | Check Microphone access, English (US) speech support, asset setup status, and the specific Settings error. There is no legacy recognizer fallback. |
| Voice reconnects after a device change, stall, or backlog | Incomplete audio and the current task are discarded. After recovery, say “Hey Mouse” and repeat the command. If three restarts in 60 seconds fail, resolve the specific Settings error and enable the microphone again. |
| Background sound is still transcribed | Mouse uses normal microphone input without app-level noise suppression or speaker identification. The selected model can ignore it before interrupting work, but cannot guarantee rejection of every background command. Lowering audio sensitivity raises the activity threshold; it does not filter audio sent to Apple's recognizer. |
| No notch is visible | Standby deliberately has no overlay. Say “Hey Mouse” or choose **Activate Mouse**; ensure the microphone is running. |
| Words change while speaking | Faster live results are provisional. With the second pass enabled, its final transcript is submitted; with it disabled, stable first-pass text is submitted after the quiet endpoint. |
| Live words are delayed after a wake phrase or completed command | Rebuild with the boundary-synchronization fix and run the streaming check. It distinguishes consumed-boundary suppression from the speech engine's own latency; passing it does not prove microphone or UI behavior. |
| A command starts before the whole sentence is spoken | The 500 ms threshold is not semantic end-of-turn detection. Further speech is assessed as a continuation; existing work continues until a command is accepted. Already dispatched input cannot be undone. |
| Spoken Stop is delayed | It acts when the recognizer reports the initial word; it no longer waits for the final pass. Recognition and callback scheduling still take time. **Stop Mouse** in the menu sends a direct cancellation request. |
| A follow-up loses earlier details | Accepted commands retain full text, resolved goals, latest input descriptions and outcomes for the current app process. Restarting clears them; ignored utterances and requests stopped before action-model acceptance are not recorded. Pending questions are supplied explicitly. The models can still fail to use this context correctly. |
| Model request fails or times out | Check the displayed error and project access to both Decisions and Responses. Requests time out after 30 seconds and are not automatically retried. Generative fallback is a deliberate selection route, not an automatic retry of a failed request. |
| Usage cannot be loaded/saved | The warning explains whether the app is counting only in memory. Requests remain enabled. Avoid running the GUI and API check together. |
| Notch placement is wrong in another Space, fullscreen app, or display | These presentation cases remain deferred; capture's display coordinate support does not imply complete overlay-placement support. |

## Current limits and deliberate decisions

- The app targets this Mac's native notch workflow. Spaces, fullscreen behavior, and multiple-display overlay placement need further work.
- Speech currently targets English (US) on supported Apple silicon hardware. Wake monitoring continuously runs the local recognizer.
- Wake and initial-word Stop use live recognition. Ordinary computer commands wait for a stable endpoint and, by default, the accurate second pass. Fast-only mode deliberately trades replay correction for the stable live transcript while preserving endpoint and consumed-audio protections.
- Standby is local. Once active, even speech ultimately ignored uses the selected model for combined intent/action selection. Luna-only and Decisions + screenshot upload an image during that assessment. There is no separate screening API call.
- Speculative capture overlaps optional final speech only while idle and has candidate/focus/display/freshness checks. Its image is sent according to the selected mode. Same-app content and keyboard focus can still change during model inference; the screen is not locked. Concurrent task progress can invalidate a prepared selection and require reselection after cleanup.
- Decisions selects from native options and a compact foreground AX summary, with an image only in Decisions + screenshot mode. Some apps expose incomplete or inaccurate accessibility data; offscreen targets are not native choices. Uncertain targets and operations outside the four supported AX actions go to Responses. Text-only Decisions also routes visual inspection to Responses; Luna-only uses Responses for every step. There is no DOM reader, browser extension, or OS-wide app/clickable catalog.
- Follow-up context preserves every action-model-accepted command for the running app session, with full text, resolved goals, latest input descriptions and outcomes when available. Decisions receives the latest three commands and 12 dispatch summaries; its current request and goal remain complete. The planner receives full history. This does not guarantee correct reference resolution. There is no persistent memory, full conversational transcript, or automatic history compression. Large planner histories can reach provider context limits.
- Stop acts on a recognized initial word, which can create false positives such as “stop by later.” Cancellation is cooperative and cannot reverse events already sent to another app.
- Mouse has no app-level noise suppression, Krisp integration, or speaker verification. Background voices can still produce text, and a background command may be mistaken for directed intent. Combined intent assessment reduces unwanted interruptions; it does not authenticate the speaker.
- A deliberate 1000 ms settling delay follows every executed batch before capture and the next action-model request. It is separate from the 500 ms speech endpoint; total latency also includes transcription, queueing, capture, network, combined intent/action inference, and input.
- Strict action validation rejects malformed input, but does not guarantee correct intent, correct targets, or safe application behavior.
- Generated action batches are bounded to 12; native selections perform one AX operation. Candidate/read budgets limit one observation, not task length. The number of steps and total request count remain uncapped.
- This local app is ad-hoc signed and not sandboxed. Rebuilds can require renewed permissions or Keychain authorization. Distribution requires Developer ID signing, notarization, and further testing.

## Deferred or excluded work

These are design directions, not current behavior. The current implementation already offers a second-pass toggle and three model routes; speaker-specific recognition remains excluded.

| Proposal | Intended change and decisions still required |
|---|---|
| Evaluate the fast-only transcription option | Compare omissions, revisions, leading/trailing words, and latency with the default second pass on real streaming speech. The toggle is implemented; equivalent recognition quality has not been established. |
| Speaker-specific recognition | Requires enrollment and speaker verification; ordinary noise processing does not distinguish the owner from nearby speakers. Not included. |
| Browser DOM integration | A browser extension or other supported integration could expose richer page structure beyond AX; no DOM reader is installed. |
| On-device Apple decision model | Remains an alternative to benchmark; no local decision inference path is implemented. |
| Additional screenshot downsizing | The proposed 40% mode is not implemented. Existing capture dimensions and coordinate mapping remain in use. |
| Spaces/fullscreen/multiple-display overlay behavior | Presentation work remains deferred; capture geometry support is separate from notch-placement support. |

Changes to live preview should be verified against actual streaming speech as well as deterministic state tests. Changes to capture, context, or Stop should have their own explicit behavior and regression checks rather than being assumed to follow from a transcript-display fix.
