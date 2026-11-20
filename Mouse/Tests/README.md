# Tests

[MouseCoreTests](MouseCoreTests/README.md) is the offline XCTest suite. From the project root, run:

```sh
./Scripts/test.sh
```

The suite uses synthetic observations, explicit state transitions, temporary files, and injected model transports. It does not open a microphone, use a saved API key, or send desktop input. A passing suite verifies these contracts, not live speech/model accuracy or end-to-end desktop behavior.

Opt-in platform integration checks are documented in [Tools](../Tools/README.md) and the master [README](../README.md#verification).
