# Settings

The secondary setup window and local diagnostics live here.

- `MouseView.swift` assembles voice controls, permissions, API-key setup, login
  preferences, usage, and error display.
- `BehaviorSettingsView.swift` groups the three model routes, audio sensitivity,
  second-transcription-pass switch, and timing logs. Bindings go through persisted
  `AppModel.preferences`; an in-flight command keeps its selected route.
- `LatestActionTimingView.swift` shows the latest accepted command's total,
  first input latency, outcome, and individual stage durations. It reads a single
  structured timing snapshot per redraw rather than parsing the exported report.
  This trace is retained separately so ignored speech cannot evict the summary.
- `ActivityDiagnosticsView.swift` shows accepted goals, model selections, actual
  dispatched input, and the controls offered for the latest action. Its search
  and disclosure state remain local to the view.
- `StageTimingsView.swift` expands the ten latest full command timelines in milliseconds
  and copies their reports. Running durations refresh only while expanded;
  completed reports are cached by the collector. These timings stay in memory.
- `NativeGlassSurface.swift` hosts SwiftUI inside AppKit's native glass view and
  keeps the enclosing window transparent.

UI actions go through `AppModel`. Keep selection and dispatch diagnostics
distinct: selecting a control does not establish that input reached the app.
