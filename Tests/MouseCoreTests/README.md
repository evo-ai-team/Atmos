# Core regression tests

The test directories mirror [MouseCore](../../Sources/MouseCore/README.md): [Accessibility](Accessibility/README.md), [Actions](Actions/README.md), [Diagnostics](Diagnostics/README.md), [Inference](Inference/README.md), [Session](Session/README.md), [Speech](Speech/README.md), and [Usage](Usage/README.md).

Use `./Scripts/test.sh` from the project root for the full suite, or `./Scripts/test.sh --filter TestClassName` for focused iteration. Keep tests about observable contracts and failure behavior, especially cancellation, stale results, protocol rejection, protected content, and preserving earlier progress.

Each test should be deterministic and independent of live permissions or provider behavior. Model clients use injected transports; never embed credentials in a fixture.
