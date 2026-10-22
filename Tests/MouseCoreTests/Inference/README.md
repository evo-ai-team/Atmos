# Inference tests

These tests use injected transports and in-memory JSON fixtures. They do not read saved API keys, contact a model, or operate the Mac.

| Suite | Coverage |
| --- | --- |
| `OpenAIClientTests` | Planner input, fresh screenshots, task amendments, review-only constraints, closed action schemas, complete-response validation, sanitized errors, and cancellation. |
| `DecisionsClientTests` | The separate text-only Decisions wire contract, absence of image fields, question limits, ordered closed-choice answers, probabilities, refusals, and transport failures. |
| `CompactDecisionsRequestTests` | Compact context and numbered options through the real client with an offline reply, resolving back to the exact native target while excluding images and local-only metadata. |
| `SpeechIntentFilterTests` | Text-only speech extraction, original transcript/context preservation, strict command/ignore judgments, and cancellation that leaves current work alone. |
| `HTTPRequestTimingTests` | URLSession phase conversion, overlapping TLS/connect intervals, missing/invalid dates, provider-header allowlisting, and intercepted transport completion/cancellation. |

Run the repository's `Scripts/test.sh` from the project root for the full suite. With Swift Package Manager, `swift test --filter OpenAIClientTests` runs the planner tests alone; the other suite names can be used the same way.

Assert observable requests and returned results rather than private helper structure. In particular, a valid operation inside a response is only provisional: any invalid sibling output must reject the whole response before the caller can dispatch an action.

Timing checks exercise the public request paths with injected transports: network time is distinct from encoding/parsing, cancellation closes the active stage, and diagnostic traces contain stage names rather than transcript or request data. The Decisions timing test uses a controlled clock; no wall-clock sleeps or live requests are required.

HTTP diagnostics integration tests install a private `URLProtocol` that intercepts every request, so no fixture can contact the network. Synthetic metric snapshots exercise phase math separately because URLProtocol loads may have no network transaction metrics. Provider durations are metadata, connection/TLS overlap is explicit, and unavailable phases must not become invented zero-duration work.
