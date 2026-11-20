# Pipeline timing

`PipelineTiming.swift` records the stages of one typed, spoken, or continued command using monotonic system uptime. The collector is thread safe so speech callbacks, capture work, and inference requests can contribute to one trace without blocking each other on I/O.

Use `begin` and `end` around asynchronous work, `record` for intervals already measured by a callback, and `mark` for zero-duration events. Call `markFirstInput` immediately before dispatching a real input event or accessibility action. It records the first **attempt**, not proof that the UI changed. `finish` closes pending spans and permanently freezes the trace, including when a command fails, is cancelled, or is superseded.

The plain-text `report` shows each stage's start offset, duration, and outcome, together with independently measured total and first-input latency. Parallel stages overlap and their durations must not be added. Keep stage names static and free of command text, screenshots, credentials, or typed content. Each trace retains at most 256 stage records and reports how many additional records were omitted.

The structured `snapshot` supplies the same timing boundaries to the settings summary and per-stage list. Each snapshot uses one clock sample for all running intervals; completed durations stay frozen. Full reports retain metadata and omission counts for export.

Use `annotate` for safe request metadata such as payload byte counts, correlation IDs, and provider-reported processing time. Reports interleave these annotations chronologically as `@+offset · metadata · message`; the offset is when the observation was recorded, not a measured interval. Reported provider time must never be recorded as a fabricated local span. Annotations retain at most 64 single-line messages of 1,024 characters each, independently of the stage limit so metadata cannot crowd out timing evidence. Extra annotations are counted as omitted. Like timed records, annotations cannot change a finished trace.

Tests in `Tests/MouseCoreTests/Diagnostics` use an injected clock to check timeline accounting, lifecycle boundaries, concurrent recording, and invalid timestamps.

## Removable benchmark support

`BenchmarkSession.swift` supplies the opt-in trial deadline, action-batch ceiling, and session-wide request reservation limit. `BenchmarkReport.swift` freezes a terminal trace, this trial's action history, and usage deltas for local export. Both files and their hooks are marked `TESTING`. The app recorder and removal map live in [Mouse/Diagnostics/Benchmark](../../Mouse/Diagnostics/Benchmark/README.md). Benchmark traces request larger bounded capacities; the ordinary timing defaults above remain unchanged.
