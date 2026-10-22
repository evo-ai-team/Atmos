# Speech fixtures

`mouse-command.wav` contains synthetic command audio for the streaming integration harness. `live-transcript-events.json` contains deterministic transcript events used to reproduce state transitions.

Keep fixtures small, reproducible, and free of credentials or private recordings. These are source inputs, not disposable build products. The [parent guide](../README.md) describes the integration harness; ordinary state/protocol regressions belong in the offline test suite.
