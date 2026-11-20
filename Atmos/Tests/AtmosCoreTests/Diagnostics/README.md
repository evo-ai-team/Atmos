# Pipeline timing tests

`PipelineTimingTests.swift` verifies the monotonic timing collector in `Sources/AtmosCore/Diagnostics` with a controllable clock. Coverage includes overlapping spans, first-input attempt latency, cancellation and failure, immutable completed traces, independent commands, concurrent recording, bounded retention, and invalid or backward timestamps.

Metadata tests check chronological placement without fabricated durations, separate annotation and stage retention limits, bounded single-line messages, concurrent annotation recording, and ignored late annotations both before and after the completed report is cached.

Structured-snapshot coverage checks live totals, stage durations, first-input latency, and frozen values after completion.

Run `Scripts/test.sh --filter PipelineTimingTests` from the project root. These tests validate timing accounting; they do not measure live API, microphone, capture, or accessibility latency.

`BenchmarkTests.swift` contains removable `TESTING` coverage for session-wide request limits, trial deadlines, batch limits, stale-trial rejection, isolated immutable action/usage reports, cutoff reasons, and larger benchmark-only timing capacity. Run with `--filter BenchmarkTests`. App focus, native cancellation cleanup, and actual export files additionally need live verification through the regular app's opt-in Benchmark section.
