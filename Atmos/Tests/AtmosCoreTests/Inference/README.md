# Inference tests

These tests use injected transports and in-memory JSON fixtures. They do not read saved API keys, contact a model, or operate the Mac.

| Suite | Coverage |
| --- | --- |
| `OpenAIClientTests` | Planner input, fresh screenshots, structured completion on every request path, text answers and their bounds, task amendments, review constraints, closed action schemas, complete-response validation, sanitized errors, and cancellation. |
| `LunaAccessibilityTests` | Native tool input/output and action history, all four AX operations, snapshot/element binding, invalid or ineligible targets, partial trees, fresh-task continuation, and rejection during review or image-only continuation. |
| `DecisionsClientTests` | The separate text-only Decisions wire contract, absence of image fields, question limits, ordered closed-choice answers, probabilities, refusals, and transport failures. |
| `CompactDecisionsRequestTests` | Compact context and numbered options through the real client with an offline reply, resolving back to the exact native target while excluding images and local-only metadata. |
| `HTTPRequestTimingTests` | URLSession phase conversion, overlapping TLS/connect intervals, missing/invalid dates, provider-header allowlisting, and intercepted transport completion/cancellation. |

Run the repository's `Scripts/test.sh` from the project root for the full suite. With Swift Package Manager, `swift test --filter OpenAIClientTests` runs the planner tests alone; the other suite names can be used the same way.

Assert observable requests and returned results rather than private helper structure. In particular, a valid operation inside a response is only provisional: any invalid sibling output must reject the whole response before the caller can dispatch an action.

Completion checks cover initial requests, accepted-task continuations, amendments, review requests, and chained function-result screenshots. Every path offers `complete_task` and requires a tool, preserves the full goal, and rejects plain final messages. Review still cannot execute input or ignore the task; continuations cannot ignore accepted work. These offline checks validate the wire contract and parser, not a live model's judgment of screenshot contents.

Question checks cover paired brief/full `answer_question` replies on new utterances with or without an active task, the 160-character single-line brief and 4,000-character multiline text boundaries, malformed payloads, and rejection when mixed with actions, completion, or raw messages. Continuation and review paths both hide and reject the answer tool. Prompt/schema checks distinguish questions from action-shaped requests and keep loading labels short; they do not claim to test the model's live intent judgment.

Timing checks exercise the public request paths with injected transports: network time is distinct from encoding/parsing, cancellation closes the active stage, and diagnostic traces contain stage names rather than transcript or request data. The Decisions timing test uses a controlled clock; no wall-clock sleeps or live requests are required.

HTTP diagnostics integration tests install a private `URLProtocol` that intercepts every request, so no fixture can contact the network. Synthetic metric snapshots exercise phase math separately because URLProtocol loads may have no network transaction metrics. Provider durations are metadata, connection/TLS overlap is explicit, and unavailable phases must not become invented zero-duration work.

Decisions wire checks cover both the default strictly text-only payload and explicitly requested screenshot evidence, including rejection of empty images before transport. Luna request tests retain same-call intent/ignore, active-task amendments, and continuation policies.
