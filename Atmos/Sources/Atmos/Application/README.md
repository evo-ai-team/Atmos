# Application

This directory composes the macOS app and coordinates a command from accepted
speech through observation, selection, input dispatch, and completion.

- `AtmosApp.swift` starts the app or a command-line diagnostic mode and installs
  the menu bar item. The menu opens Settings in the expanded panel.
- `AppModel.swift` owns published UI state and the lifetime of a command. Its
  private helpers separate startup, speech screening, task replacement, model
  selection, dispatch, accepted-goal history, and completion.
- `ScreenObservation.swift` pairs a screenshot with the accessibility tree of
  the same foreground process and validates that evidence before acting.
- `StageMeasurement.swift` closes synchronous and asynchronous stage timers on
  success, error, or cancellation without changing the operation's result.
- `SelectedAction.swift` converts a validated Decisions answer or Luna response into a native,
  generated, completion, or ignored operation and its diagnostic descriptions.
- `UsageHistory.swift` loads and saves local usage, backs up unreadable counters,
  and falls back to counting in memory after a storage failure.
- `QuestionAnswer.swift` retains each question and full reply under a stable session ID.

`AppModel` stays on the main actor. Its generation token owns both input and UI
changes: a retired asynchronous request may finish, but cannot dispatch input or
finish its replacement. Replacement work waits for canceled input cleanup before
capturing a new screen. Speech screening runs separately and cannot retire work
until it accepts a command. Keep these checks around every asynchronous boundary
when changing the execution loop.

`AtmosPreferences` supplies three per-command modes: Responses Luna alone, Decisions with
an image, or Decisions with text only. The chosen mode is frozen when input is submitted
and appears in timing metadata. Voice sensitivity and second-pass recognition settings
are also persisted and applied to `VoiceInput`.

The incoming-command queue runs the selected model's intent check and first action
selection together. There is no separate SpeechIntentFilter call. Accepted results carry
their observation into execution, avoiding a repeat model request. Ignored speech leaves
active work running. Concurrent checks use their own AX controller so capturing a new
tree cannot replace a running action's retained handles. If existing work dispatched or
changed task state during selection, or input was in flight, acceptance retires that work
and takes a fresh observation before selecting again. Cancellation invalidates both paths.

Decisions receives compact context with the complete request/goal, last three accepted
commands, twelve dispatch summaries, and up to 100 useful AX state rows. Numbered choices
map locally to exact native targets. Text-only completion requires current AX evidence;
image mode may additionally establish completion from the screenshot. Unsupported actions
use the screenshot-capable Responses planner. Luna-only uses that planner directly on
every step, including ignore, completion, and amendments, without calling Decisions.

Luna can select an observed native control through `perform_accessibility_action`, both in Luna-only mode and after a Decisions fallback. `SelectedAction` resolves that request to the same native dispatch path as Decisions while preserving Luna's task update. Prepared turns retain the controller that captured their handles. Native dispatch performs exactly one operation, logs its actual target and source in Actions, and captures a new observation before the next model step. Failed or uncertain AX dispatch never silently retries as a coordinate click.

Every Luna screenshot request offers `complete_task`: when the current screen and
dispatch history establish that the accepted goal is achieved, it completes in
that response. There is no loop detector. Input validation, explicit user pauses,
request timeouts, and immediate cancellation remain part of execution.

`AppModel.actionHistory` publishes the same dispatch IDs recorded in task history
to the Actions tab. It captures model descriptions and exact generated/native
payloads immediately before execution, then records dispatch completion or an
uncertain result. Retiring a command marks its in-flight entries uncertain before
changing generations; a late completion cannot make them successful. This local
session log survives task completion and Stop and is not written to disk.

Questions use the selected model route and return `answer_question` without input
or task updates. Admission publishes these replies before launching or retiring
computer work, so an answer cannot replace or complete an existing task. If a
refreshed accepted turn becomes an answer, the previous task resumes. The pill displays complete, compact answers. A detailed answer leaves a clickable checkmark until its full-screen reader opens or the user dismisses the notch with a display tap. Menu submissions remember the originating size, and the active menu can display an answer in place.

`presentAnswerTurn` records each question and reply in session context before checking whether the notch is available. `SelectionHistory` freezes that context for both initial and refreshed selections: Luna receives full answers, while Decisions gets the latest three question/brief-answer pairs. This lets “Why?”, “Explain that”, and references to earlier options reach the question-answer path without changing the current task. Suggestions in a stored reply establish references, not permission to execute them. Memory lasts until app exit.

Each command carries a `PipelineTiming` reference from speech replay or typed
submission through screening and execution. Queued and retired tasks retain
their own references, so late callbacks cannot alter a replacement's report.
The latest ten reports appear in Settings. The latest accepted command is retained
separately, so ignored background speech cannot evict its summary. Candidate-to-trace handoff mappings
outlive display retention and are removed on submission or invalidation.
Timers include background permission/Keychain polling, usage persistence,
speculative capture reuse, focus restoration, API stages, input, and settle
waits. First-input latency stops at the actual CGEvent or AX dispatch attempt;
completion latency continues through post-action observation and model checks.

The low-level implementations are in the sibling `Speech`, `ComputerControl`,
and `Security` directories. Platform-independent policies and network contracts
live in `Sources/AtmosCore`; presentation belongs in `Interface`.
