# Application

This directory composes the macOS app and coordinates a command from accepted
speech through observation, selection, input dispatch, and completion.

- `MouseApp.swift` starts the app or a command-line diagnostic mode, declares the
  settings window, and installs the menu bar item.
- `AppModel.swift` owns published UI state and the lifetime of a command. Its
  private helpers separate startup, speech screening, task replacement, model
  selection, dispatch, accepted-goal history, and completion.
- `ScreenObservation.swift` pairs a screenshot with the accessibility tree of
  the same foreground process and validates that evidence before acting.
- `StageMeasurement.swift` closes synchronous and asynchronous stage timers on
  success, error, or cancellation without changing the operation's result.
- `SelectedAction.swift` converts a validated Decisions answer into a native,
  generated, completion, or ignored operation and its diagnostic descriptions.
- `UsageHistory.swift` loads and saves local usage, backs up unreadable counters,
  and falls back to counting in memory after a storage failure.

`AppModel` stays on the main actor. Its generation token owns both input and UI
changes: a retired asynchronous request may finish, but cannot dispatch input or
finish its replacement. Replacement work waits for canceled input cleanup before
capturing a new screen. Speech screening runs separately and cannot retire work
until it accepts a command. Keep these checks around every asynchronous boundary
when changing the execution loop.

Decisions is always text only. `AppModel` supplies `ComputerDecisionContext` with
the full current request/goal, pending clarification, last three accepted
commands, latest 12 dispatch summaries, and up to 100 meaningful AX text/state
rows. Omitted history and UI evidence are explicit. Simple numbered options map
locally to retained exact AX elements/actions; they do not expose the full tree,
native IDs, help, or geometry. The existing 249-native-choice cap and candidate
coverage remain. Completion is unavailable without current AX evidence and is
permitted only when explicit UI text/state establishes the entire goal.

Screenshot capture remains part of the local observation for geometry, native
validation, and progress checks. A screenshot is never attached to Decisions;
visual inspection, uncertain targets, and unsupported actions use the Responses
planner with the screenshot, full captured AX tree, and full history. Speech
screening is unchanged. Smaller payloads are not a measured speed guarantee.

Each command carries a `PipelineTiming` reference from speech replay or typed
submission through screening and execution. Queued and retired tasks retain
their own references, so late callbacks cannot alter a replacement's report.
The latest ten reports appear in Settings. Candidate-to-trace handoff mappings
outlive display retention and are removed on submission or invalidation.
Timers include background permission/Keychain polling, usage persistence,
speculative capture reuse, focus restoration, API stages, input, and settle
waits. First-input latency stops at the actual CGEvent or AX dispatch attempt;
completion latency continues through post-action observation and model checks.

The low-level implementations are in the sibling `Speech`, `ComputerControl`,
and `Security` directories. Platform-independent policies and network contracts
live in `Sources/MouseCore`; presentation belongs in `Interface`.
