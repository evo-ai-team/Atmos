# Inference

This directory translates observations and recognized speech into validated model results. It does not capture the screen, choose accessibility candidates, dispatch native input, or change task state; callers own those responsibilities.

| Files | Responsibility |
| --- | --- |
| `OpenAIComputerClient.swift` | Sends planner requests, preserves cancellation, and applies the request policy to the returned turn. |
| `ComputerRequest.swift` | Builds screenshot/context input and keeps offered tools, extra instructions, and response constraints together in `ComputerRequestPolicy`. |
| `ComputerPrompt.swift`, `ComputerTools.swift` | Define the planner's instructions and closed tool schemas. |
| `ComputerResponseParser.swift` | Validates the complete response, task updates, and every action argument before returning any operation. |
| `DecisionsClient.swift`, `DecisionModels.swift` | Ask closed-choice questions with text and an explicitly optional screenshot and verify that ordered answers name only the choices offered for that observation. |
| `APIRequest.swift` | Supplies the shared ephemeral session and authenticated JSON request setup. |
| `HTTPRequestTiming.swift` | Observes per-request URLSession metrics and emits safe transport phases and provider metadata. |

The Decisions endpoint and Responses endpoint have different contracts. Keep their payloads and validation separate. Only HTTP setup is shared; each client retains its own errors and cancellation behavior. Server bodies and arbitrary transport errors must not appear in user-facing messages because they can contain private request data.

The app freezes one behavior mode per incoming command. Luna-only sends screenshot and command to Responses for intent plus action in one request; no Decisions request occurs. The other modes use Decisions with or without a screenshot and invoke Responses only for unsupported input or clarification. Omitting `frame` encodes strictly text-only Decisions content. Every mode can ignore irrelevant new speech without an additional screening request.

No client retries requests. An uncertain timeout must not select or replay an operation against an outdated screen. Planner input starts with the caller's latest image and dispatched history. Every screenshot request offers `complete_task` and requires exactly one tool: the planner must finish immediately when the current image and actual dispatched history establish that the entire goal is satisfied. Completion includes the full current goal, including amendments; ordinary final messages cannot finish a task. The parser rejects messages, multiple operations, incomplete output, and invalid arguments. Review requests offer only pause and completion, so they can recognize an already-achieved goal but cannot dispatch further input or invent authorization. Accepted-task continuations cannot silently ignore the task, including the chained `continueTurn` path.

New utterances can use `answer_question` for questions addressed to Mouse, including general, how-to, screen, and task-context questions. The answer is a separate `ModelTurn.answer`, at most 4,000 characters with multiline text allowed. It carries no actions, task update, or completion message and cannot change an accepted task. Action-shaped questions such as “Can you open Chrome?” still request input; background conversation remains ignored. Answers are unavailable and rejected during accepted-task continuation and required review. Raw model messages remain invalid, keeping answers distinct from verified task completion.

Action descriptions request 1–2 words, at most 40 characters, without ellipses. The parser retains its 64-character tolerance so an otherwise valid operation is not rejected for label styling; the app formats the compact loading label while keeping the returned description in action history.

Tests live in `Tests/MouseCoreTests/Inference`. They inject offline transports and exercise the actual public client calls; changing a prompt, schema, or parser should be checked against those wire-contract tests.

Each public request accepts an optional `PipelineTiming` trace. Request preparation/encoding, the HTTP round trip, and response parsing have separate intervals, including failures and cancellation. HTTP duration includes networking and server work; it does not isolate model inference. Labels never include request or response content.

Production transports additionally use a per-request task delegate without changing `URLSession.data(for:delegate:)` completion, cancellation, timeouts, or retry behavior. Every request has a short local ID. Its diagnostic rows distinguish setup/queue time, DNS, connection establishment, TLS, upload, wait for the first response byte, download, delivery of metrics, return from the data await, and client actor resumption when those boundaries are available. The final interval includes diagnostic bookkeeping as well as Swift scheduling. Connection time includes TLS; both overlap the enclosing HTTP timer. Waiting for the first response byte includes transit and server work, not just inference. Redirects or other URLSession transactions have separate numbered rows.

URLSession reports phase dates in wall time. A request-local wall-time/uptime anchor places them approximately within the monotonic trace; large detected clock corrections omit those date-based phases. Missing, unfinished, or reversed phase boundaries are omitted. Metrics callbacks are never awaited, so a late callback may be unavailable when the trace finishes. The outer HTTP timer remains the complete observed await.

Metadata contains JSON request bytes, decoded response bytes, available transferred-byte counts, HTTP status, negotiated protocol, connection reuse/proxy flags, a bounded identifier from `x-request-id`, and a valid numeric `openai-processing-ms` if supplied. The provider processing value is reported as metadata, not fabricated as a timestamped interval. Decisions also records whether image or text-only evidence was sent, context UTF-8 bytes, choice counts, and parsed token counts; byte counts are not token estimates. No URLs, request bodies, screenshots, credentials, arbitrary headers, or response text are copied into diagnostics. Existing single-argument injected transports remain supported and offline.
