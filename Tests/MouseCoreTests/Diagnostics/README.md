# Pipeline timing tests

`PipelineTimingTests.swift` verifies the monotonic timing collector in `Sources/MouseCore/Diagnostics` with a controllable clock. Coverage includes overlapping spans, first-input attempt latency, cancellation and failure, immutable completed traces, independent commands, concurrent recording, bounded retention, and invalid or backward timestamps.

Metadata tests check chronological placement without fabricated durations, separate annotation and stage retention limits, bounded single-line messages, concurrent annotation recording, and ignored late annotations both before and after the completed report is cached.

Run `Scripts/test.sh --filter PipelineTimingTests` from the project root. These tests validate timing accounting; they do not measure live API, microphone, capture, or accessibility latency.
