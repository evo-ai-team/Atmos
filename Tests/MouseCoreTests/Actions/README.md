# Action tests

`ActionLabelTests` checks the two-word display boundary, ellipsis removal, article
handling, whitespace normalization, and overly long token fallbacks.

These tests cover menu-bound native choices (`ComputerDecisionTests`), pixel-to-screen mapping (`CoordinateTests`), and redacted descriptions of attempted input (`ActionDispatchSummaryTests`). Compact numeric choices must resolve to the exact original element and operation; answers from another menu fail even if it uses the same snapshot ID. Choice tests also cover capture priority, repeated names with ancestor context, malformed/cyclic ancestry, quoting, and field-content redaction.

`ComputerDecisionContextTests` verify bounded history and UI evidence without truncating accepted intent, preserving dispatch uncertainty and task ownership, excluding private payloads and protected fields, and retaining section context for identical labels with different states.

Assertions distinguish selection from execution and attempted input from observed success. Decisions receives no image and may complete only from positive current accessibility evidence. A missing, partial, or unchanged tree must not silently become a completion signal. No tests in this directory post native events.
