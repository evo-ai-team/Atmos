# Computer control

These adapters observe and operate macOS. They receive validated intent from the application coordinator and do not call models.

- `NativeComputer` owns the selected display and balanced keyboard/mouse event dispatch. Whole actions are validated before the first input; cancellation still releases keys and buttons already pressed.
- `DisplayCapture` captures a pinned display, excludes Atmos's own windows, encodes JPEG data, and checks that display geometry stayed stable during capture.
- `KeyboardInputPlan` resolves shortcut keys using the current keyboard layout and splits text into Unicode packets plus Return/Tab events. It builds a plan without posting input.
- `AccessibilityController` reads a bounded AX tree on its own actor and retains native handles locally. Handles are snapshot-specific and revalidated against the foreground app/window before use. Every attempted AX action consumes that snapshot, including uncertain timeouts.

Coordinates are Quartz global points with a top-left origin. Model coordinates are screenshot pixels; the core's `ScreenshotFrame` maps between them. Secure fields must never contribute values, help text, or descendant content to a model observation.

An optional `PipelineTiming` trace separates display discovery/configuration, screenshot acquisition, JPEG encoding, AX tree capture, action validation, and dispatch. The first-input marker is recorded immediately before the first CGEvent post or `AXUIElementPerformAction` attempt, after validation. A wait or screenshot-only action never sets that marker. Timing is passed through event helpers per action, so cancellation and interleaved commands retain balanced key/button releases and correct trace ownership.
