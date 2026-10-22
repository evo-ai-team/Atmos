# Mouse changelog

This records the app's development from the original Chosen prototype through Mouse. It includes changes that were later replaced or removed, so earlier experiments are not mistaken for current behavior. Git timestamps establish the nine committed milestones on October 18, 2026. Later changes were developed in the local working tree across October 18–20; the sections below group them by topic instead of assigning unsupported exact times.

Current app: `/Users/sameemsaleem/Product/Mouse.app`

Current source: `/Users/sameemsaleem/Product/Mouse`

Current behavior and setup: [README.md](README.md)

## 2026-10-22 — Vertical notch shading and brighter bottom highlights

- Replaced the camera-centered rounded fade with a full-width vertical gradient, clipped to the existing notch silhouette. The tint stays near-black through the hardware camera height and fades downward to a 10% dark backing, with no left/right falloff.
- Brightened the bottom outline and made its opacity decrease continuously as it rises up the sides, reaching zero before the upper corners.
- Kept the hardware camera fully opaque and the glass material separate from text. On displays without a notch, the faint backing also covers the shoulders without dark corner wedges; Reduce Transparency retains opaque charcoal.

Validation: Release build and signature verification passed. Native before/after previews checked active, thinking, the reported short notice, and transcript states over desktop and warm patterned backgrounds. A separate preview checked action and no-notch layouts. No model requests or microphone capture were used.

## 2026-10-21 — Clearer notch glass and finer reflections

- Removed the forced dark material appearance and extra full-panel black wash, and reduced the native glass strength so the background remains visible through the extension.
- Replaced the uniform bright outline with a thinner reflection whose brightness varies across the sides and bottom, still fading out near the top corners.
- Preserved the opaque camera region, full-span smooth fade, text, layout, and Reduce Transparency fallback.

Validation: Release build and signature verification passed. An isolated native comparison checked active and transcript states on desktop and warm patterned backgrounds; a second preview checked loading, action, and no-notch layouts. No model requests or microphone capture were used.

## 2026-10-21 — Extend the notch fade to the panel edges

- Replaced the fixed 20-point camera fade with rounded contours spanning the full visible extension. The transition now reaches the panel's sides and bottom at every presentation size.
- Eased opacity at both ends to soften the hardware seam and the transition into clear glass. Kept the exact camera region black and preserved the glass material and edge highlights.

Validation: Release build and signature verification passed. Live previews verified the active, thinking, working, transcript, and no-notch layouts. This visual-only change does not alter command execution or audio behavior.

## 2026-10-21 — Blend the hardware notch into clear glass

- Replaced the full-width black tint and opaque shoulder cap with a camera-sized black region and a short rounded fade into native clear glass.
- Added a thin side/bottom highlight above the material and content layers, fading before the top corners. Kept the nonactivating, click-through panel and existing resize/motion behavior.
- Kept the light foreground readable in both app appearances, provided opaque charcoal for Reduce Transparency, and avoided a fake black cutout on displays without a notch.

Validation: the Release build and signature verification passed. An isolated live preview confirmed glass transparency, loading-dot glow, and edge highlights across active, thinking, action, transcript, and no-notch layouts. The preview made no API requests and captured no microphone audio.

## 2026-10-21 — Configurable model behavior, audio controls, and timing logs

- Added Settings → Behavior & logs with three persisted routes: Luna Responses only; Decisions with a screenshot and optional Luna fallback; Decisions without an image and optional Luna fallback. The default remains text-only Decisions, and each command retains its selected route through completion.
- Combined command acceptance and first-action selection. Removed the unused separate Responses screening client and its request/parser. A stable accepted first turn is reused without another model call. Ignored speech leaves current work and its AX handles intact; accepted amendments refresh observations if the prior task moved during selection. Unrelated speculative captures are cancelled and drained before sharing the AX controller with a new command.
- Added a separately retained latest accepted command summary with total time, first-input latency, per-stage durations, status, and copyable logs. The ten recent full traces remain available, including ignored speech, request metadata, and overlapping stages.
- Added a sensitivity slider over the existing speech-energy threshold. Its 50% default preserves the former threshold and never changes microphone gain. Added a second-transcription-pass switch, enabled by default; off commits stable first-pass text with the same endpoint, cancellation, and consumed-audio protections.
- Updated directory guides and the root README for the selected-mode input, privacy, and execution boundaries.

Validation: **266 offline tests passed with zero failures**; Release build and signature verification passed. Coverage includes preferences, both Decisions wire formats, first-pass transcript commit boundaries, sensitivity, structured timing snapshots, and existing request/action validation. No live API or microphone accuracy/latency benchmark was performed.

## 2026-10-21 — Make Decisions text only and compact its inputs

- Removed screenshot support from the Decisions client API and wire types. Every Decisions request contains text only. Capture remains available locally for native geometry, progress checks, and the separate image-bearing Responses planner.
- Reduced the selector instructions from 687 to 275 whitespace words. Native choices now look like `Click "Home" (button)` and use short menu-local numbers. Mouse retains the exact original element and AX operation behind each number; fresh menu identities reject stale answers even when a snapshot is reused. The existing 249-native-choice allowance and capture priority remain.
- Replaced the full tree and nested history strings with a compact context: the complete current request/goal, the latest three accepted commands, the latest 12 dispatch summaries, and up to 100 meaningful visible AX text/state rows. Explicit counts report omitted history and evidence. Named ancestors disambiguate repeated controls and their states. IDs, geometry, help text, raw action payloads, and repeated goals are omitted from this projection; the planner retains full context. Continuations send an identical request/goal only once.
- Kept useful non-editable names when an app repeats its label as its value, while preserving field/secure-data protections and the separate redaction rules for notch labels.
- Completion is offered only when current accessibility evidence is available; instructions require positive UI text/state proving the goal, not dispatch success or absent options. Visual uncertainty and unsupported operations use the planner. Speech screening and its prompt are unchanged.
- Updated domain and application documentation to describe the new input and completion boundaries.

Validation: **266 offline tests passed with zero failures**. Coverage includes text-only wire data, compact-context omissions, duplicate-name state association, exact native lookup after a simulated API response, label/value preservation, stale menus, cancellation, and existing routing behavior. The Release build and signature verification passed; the canonical app bundle was updated without relaunching it. No live API or desktop-control trial was performed, so live latency and selection accuracy are not yet measured.

## 2026-10-21 — Separate HTTP phases and request metadata

- Added per-request URLSession diagnostics for setup/queueing, DNS, connection/TLS, upload, first-response-byte wait, download, and callback/client resumption where available. Connection includes TLS; response wait includes network transit and server work. The gap from the data await's return to client resumption includes diagnostics bookkeeping.
- Record safe payload sizes, HTTP status, protocol/reuse/proxy flags, provider request IDs, and provider-reported processing milliseconds when supplied. Decisions also records image dimensions, question/choice counts, and parsed token counts. No request/response content, credentials, or arbitrary headers enter the reports.
- Added bounded metadata lines independently of stage retention. URLSession phase dates are approximately mapped onto uptime; missing or late metrics never delay a request. Existing payloads, timeouts, cancellation, and no-retry behavior are preserved.
- Documented that the speech timing origin uses the shared audio meter and can predate the current utterance. A long endpoint row can include earlier idle time.

Validation: **248 offline tests passed with zero failures**, including nine new diagnostics tests. After a diagnostic-label clarification, all six HTTP tests and the Release build passed again. The canonical app bundle was updated and its signature verified; the app was not relaunched. No live API measurement was performed. These measurements do not establish a latency improvement; screenshot attachment and action-selection behavior are unchanged.

## 2026-10-21 — Measure command latency at every pipeline stage

- Added a monotonic command trace from the last detected speech audio or typed submission through first input and completion. Separate stages cover the endpoint, local replay, queueing, intent screening, capture/encoding, accessibility reads, focus restoration, cleanup waits, API requests/parsing, action validation/dispatch, settle waits, progress checks, and usage persistence. Background permission/Keychain refreshes are measured while commands are active.
- Split each model request into encoding, HTTP round trip, and parsing. The round trip includes transport and server time; it does not claim to isolate inference latency.
- Record first input immediately before posting a CGEvent or attempting an AX action. Waits, screenshots, and failed validation do not mark input. This is an attempt timestamp, not proof of a visible effect.
- Added Settings → Testing & recent activity → Stage timings, with live milliseconds, start offsets, outcomes, independent totals, and Copy timings. Keep ten in-memory reports and at most 256 stage records per trace; overlapping stages are not added together. No prompts, image data, or credentials are copied into timing labels.
- Preserve trace identity across speculative capture, queued speech, task replacement, and cancellation; late callbacks cannot alter frozen reports. Keep candidate ownership separate from display-history eviction.

Validation: **239 offline tests passed with zero failures**, including 19 new timing tests. Five additional native-input checks used an injected event sink and verified first-event marking, non-input paths, and balanced cancellation cleanup without posting desktop input. The Xcode Release build and app signature passed; the canonical app bundle was updated. No live API or microphone latency measurement was performed, and the app was not relaunched.

## 2026-10-21 — Organize source by domain and simplify responsibilities

- Grouped native application, interface, computer control, speech, security, and diagnostics into domain directories, with matching core and test domains. Kept the existing Swift app/core module boundary.
- Extracted observation and usage persistence from app coordination; split settings diagnostics and notch geometry/presentation into focused components. Kept task replacement, cancellation, and native input cleanup ordering intact.
- Separated model transports, prompts, tool schemas, request policy, and response parsing. Parsing still validates the complete response before accepting any operation; a new regression covers invalid sibling output around otherwise valid actions, pauses, ignores, and completions.
- Named speech setup, endpoint, replay, and commit stages and separated audio packets, replay, activity, and capture-freshness helpers. Extracted display capture and keyboard planning from native event dispatch.
- Added a README to each maintained directory and comments around ownership, trust, cancellation, and timing boundaries. Updated current workspace paths and both build systems for recursive source directories while excluding documentation from compiled resources.
- Shared tool/output selection across shell scripts; generated files remain outside the source tree unless explicitly directed otherwise. Historical log links below describe previous runs; those generated artifacts were removed during workspace cleanup.

Validation: the baseline passed 219 offline tests; the refactor passed **220 tests with zero failures**. The Xcode Release app built and its signature verified in a temporary output directory. The existing runnable app was not replaced or relaunched. No live microphone, model API, or desktop-input test was performed.

## 2026-10-20 — Preserve follow-up context and avoid unnecessary clarification

- **Investigated the reported follow-ups and collection click.** Visible activity showed “put in Hello World” asking where after a request to clear search text, and “delete it” asking which item after an explicit search-box entry. The Cloudsurfer attempt used Responses fallback to click `(870, 317)`; a later foreground change stopped work. The saved candidate list lacked the collection link, but the previous assignment timing meant it could belong to a later, post-click observation. Separate native inspection exposed “Remove Cloudsurfer collection.” These observations identify context and diagnostic gaps; they do not prove the original click's cause or that the exact collection target is now fixed.
- **Keep referent context after a task ends.** Session history now retains each full accepted command, its accepted goal, and its latest dispatched input description, alongside status and outcome. Finishing or replacing an entry preserves that metadata. A completed native task can still have an original fragment as its goal because native selection does not generate rewritten text; its dispatch description adds target context. Speech screening receives the last three accepted entries without truncating their text, plus the current goal, pending fragments, and pending clarification; action requests still receive the full session history. Descriptions record dispatched input, not proof of its visible effect. History remains in memory and does not automatically replay or resume old tasks.
- **Resolve short requests before asking.** Screening, selection, and generation prompts interpret task-directed fragments and question-shaped requests with accepted context and the current screen. Completed tasks can supply referents; pending clarification is passed explicitly to action inference. Ordinary conversation and informational questions remain instructed to produce no action. These prompt changes do not guarantee the model will resolve every follow-up correctly.
- **Separate uncertainty from forced review.** Ordinary target uncertainty selects generation, which can resolve a referent and act. Review remains a pause-only route for missing authorization, irreversible-action confirmation, or authentication/security UI. Clearing recently entered search text is distinguished from permanent deletion, so “delete it” does not automatically imply a destructive action or require another question.
- **Classify amendments in the existing Decisions request.** A new amendment to an active task adds a second finite-choice question: `revise`, `replace`, or `needs_planner`. It no longer withholds all native and completion choices. A resolved native revision keeps the base goal and ordered accepted amendments locally, with newer requirements overriding only conflicts; replacement abandons old pending intent while retaining physical effects as background. An unresolved relationship uses generation. Generated complete goals reset the composition base, avoiding recursive duplication of amendments. A generated completion of a new active-task amendment must use `complete_task` with `task_update` and a message so changed intent is recorded before completion.
- **Remove the shallow accessibility depth cutoff.** Traversal can continue through more than 14 levels while the existing 600-node, 750 ms, 48-child, and per-message budgets remain. It uses an iterative queue. This can expose deeply nested controls but does not guarantee a complete tree or the specific Cloudsurfer link.
- **Keep candidate evidence attached to its dispatch attempt.** “Controls offered for last action” now updates only after foreground/observation validation at the dispatch attempt. A subsequent failed observation or foreground check cannot overwrite the previous attempt's list. The list remains diagnostic evidence, not proof of successful input.

Validation: **219 offline tests passed with zero failures**; Release build and signature verification succeeded at the canonical app path. No relaunch, permission refresh, or live API/desktop-execution test was performed for these changes. This verifies the state, serialization, routing, and capture-budget regressions, not the specific Cloudsurfer target or live model interpretation. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-context-routing-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-context-routing-build.log).

## 2026-10-20 — Diagnose actual input and pause unchanged-state loops

- **Inspected the reported loop.** For “click on ivory,” the visible activity showed steps 26–30 using Responses fallback with repeated inspection/return labels. The earlier log lacked raw action summaries; a label alone cannot prove a click happened. Separate native inspection exposed the visible “Add Ivory” link. The exact cause of that past loop remains unconfirmed.
- **Separate labels from execution.** Settings now shows the last accepted goal and actual dispatched input, including action types, coordinates, non-text shortcuts, typing counts, and explicit wait/screenshot no-input markers. Native traces include operation, generated target ID, and role. Typed text and AX values are excluded. All 20 retained activity entries are visible, and choice counts distinguish presses from context menus.
- **Clarify primary versus context actions.** AXPress means ordinary activation; AXShowMenu means context-menu/right-click, never following a link or ordinary activation. Primary activation/adjustment choices receive capacity before generic context-menu choices, with capture order preserved within groups.
- **Pause a narrow, provable replay pattern.** Three consecutive identical dispatched batches on byte-identical before/after screenshots pause while preserving the accepted task. Process/display geometry and cross-batch image continuity must match. Native snapshot IDs do not define target identity. Changed images/actions/targets reset the streak; explicit waits and native increments/decrements are exempt. Tasks still have no overall step/request cap. This cannot detect every loop: animation, JPEG/cursor differences, alternating actions, and waits can evade it. No ambiguous AX action is automatically replayed as a click.
- **Use the image already supplied.** The fallback prompt explicitly identifies the attached screenshot as the current observation and directs the model to reassess or ask for clarification instead of repeating inspection, focus, or clicking loops.

Validation: **202 offline tests passed; Release build and signature verification passed**. A prior-build new-tab trial was not confirmed successful. The new canonical app was opened, but macOS reported permissions and saved-key authorization unavailable; no permission refresh was performed and the updated route was not verified live. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-stalled-action-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-stalled-action-build.log).

## 2026-10-20 — Reach nested content controls and expose exact choices

- **Investigated real fallback activity.** Mouse reported Responses fallback for Gaming/Pokémon with 160/157 native choices and a 220-element partial tree. Native actions were not withheld for task revision. Separate native inspection found those topic controls at depth 11. Replaying traversal over that inspected hierarchy missed both controls at 220 nodes, even after removing menu competition; increasing the allowance reached them.
- **Increase capture coverage across apps.** The default node allowance is now 600, still bounded by 750 ms, 48 children per node, and depth 14. Standard web, scroll, table, outline, and editor content regions take priority over ordinary window descendants, while top-level menus remain available. There is no Chrome-specific integration. More captured nodes can increase input size/read work; this does not promise lower latency or complete coverage of every app.
- **Identify native choices directly.** Each choice now contains a bounded, quoted control label and role beside its action/ID. Exact executable IDs and validation remain unchanged. Editable-field contents, echoed values, and help are excluded from choice descriptions. This removes an unnecessary ID lookup; it is not proof of improved model selection.
- **Preserve capture priority at the choice cap.** The 249-native-choice cap is applied before canonical ID sorting. Alphabetic IDs such as `e100` can no longer crowd out earlier captured controls such as `e4` solely because of their names.
- **Preserve pre-action evidence.** Settings → Testing & recent activity → Controls offered for last action shows searchable exact native choices and capture-limit reasons from the last action selection, retained after completion. It distinguishes missing controls from a model choosing fallback despite an available match, without extra API calls or disk logging.

Validation: **184 offline tests passed with zero failures**; Release build and signature verification passed. The sanitized 441-node topology fixture reproduces the missed controls and verifies coverage at the production allowance, alongside generic traversal, choice-cap priority, description/redaction, and existing regression tests. Live before-fix routing counts were inspected; the topology fixture is not a full native-reader/model/action test. No permissions were changed. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-content-routing-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-content-routing-build.log).

## 2026-10-20 — Make native accessibility choices reachable

- **Corrected the selection prompt's fallback bias.** An incomplete tree previously instructed Decisions to use generation even when the requested control was already offered. It now prefers matching native actions, tolerates unrelated truncation, and judges the immediate next operation instead of later unsupported steps in a larger goal. Native descriptions are generated locally and do not require a Responses call.
- **Prevent unopened menus from consuming the window's capture budget.** The bounded traversal retains top-level menu controls, prioritizes window descendants over deeper menu contents, and allows newly discovered window nodes to replace pending lower-priority menu nodes. IDs remain unique and all omissions are reported. The existing element/depth/time limits and secure-field protection remain.
- **Initialize and prioritize browser accessibility reads.** Read the application's AX role before its roots and prefer `AXVisibleChildren` where supported, falling back to ordinary children when necessary. This helps reach visible webpage controls instead of spending the child prefix on offscreen items; it does not change browser preferences or Mac permissions.
- **Show routing in Settings.** Testing & recent activity now shows the latest Decisions selection, offered native-choice count, captured element count, partial/unavailable-tree status, and the separate goal-revision gate. Completed step entries retain Native accessibility or Responses fallback. The diagnostics add no API calls and distinguish selection from successful dispatch.

Validation: **179 offline tests passed with zero failures**; Release build and signature verification succeeded at the canonical app path. A separate native UI inspection confirmed that Chrome exposes New Tab and New Arrivals. The standalone reader probe could not capture a tree because that diagnostic process lacked AX permission; no permission change was requested. The rebuilt app was not relaunched, and no live model selection or action-dispatch test was performed. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-routing-fix-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-routing-fix-build.log).

## 2026-10-20 — Decisions selection, accessibility, and project cleanup

- **Committed the existing app before migration:** `681789a` preserves the working voice, speech-screening, session-memory, and notch baseline.
- **Replaced the live screenshot-only action loop with Decisions selection.** Every step sends the current screenshot, a bounded accessibility snapshot, the accepted goal, dispatched progress, and session history to `/v1/decisions`. The selector can choose a concrete native action, request generated actions or review, or verify completion. It cannot invent action arguments. Both endpoints currently use the provider's model ID `gpt-6-luna`; this is an API-routing change, not a promise to use a different underlying model.
- **Kept a generative fallback with the user's approval.** Responses still supplies typing, pointer coordinates, scrolling, dragging, keys, free-form clarification, and full revised/replacement goals. Each generated operation returns to Decisions after execution and observation. Fresh fallback calls receive explicit task/progress context instead of continuing a hidden Responses chain that omits intervening native actions. The Responses protocol diagnostic retains its separate continuation check.
- **Read the foreground app's accessibility tree.** Capture includes focused/main-window and menu-bar descendants, relationships, readable roles/labels/values/help, enabled state, supported actions, and global/screenshot bounds. Capture is bounded to 220 elements, 48 children per node, depth 14, a 750 ms traversal budget, and 50 ms per AX message. Truncation/unavailability is explicit. Secure field text and descendants are excluded. This is not browser DOM access or an OS-wide catalog.
- **Offer concrete native targets.** Decisions receives at most 249 supported, enabled, visible-target actions: `AXPress`, `AXShowMenu`, `AXIncrement`, and `AXDecrement`. Local short labels describe the control without displaying field values. Unavailable, offscreen, disabled, uncertain, or unsupported targets use the generator rather than a guessed native action.
- **Validate before semantic dispatch.** AX stays off the main actor. Dispatch verifies snapshot identity, process, focused window, retained element, label, role, bounds, enabled state, and supported action. Each attempted native action consumes its snapshot. An ambiguous AX result stops without a blind coordinate retry; input may already have taken effect.
- **Keep review and continuation contracts explicit.** A review selection can only yield a pause response, never generated actions. Continuations do not offer the ignore option because there is no new utterance to classify. Corrections to an active goal require a generated `task_update` so unaffected requirements and actual progress can survive the change.
- **Preserve existing interaction features.** Text-only speech extraction still filters chatter before interruptions. The 500 ms endpoint, accurate second replay, parallel idle observation, live preview, immediate recognized Stop, persistent activation, session memory, six-dot notch animation, mouse/keyboard support, 1000 ms settling wait, and uncapped tasks/requests remain.
- **Account for mixed API rates.** Decisions input is estimated at $0.10 per million tokens, with no output charge; Responses retains its existing rate. Per-request long-context adjustments apply. Saved totals and accumulated past estimates are not reset or repriced. Actual provider billing can differ.
- **Remove confirmed dead state and plumbing.** Removed unused activity metadata, AppModel display state, duration bookkeeping, an unused privacy helper, unassigned raw-audio callbacks, an unused voice-state wrapper, and the always-empty legacy `safetyChecks` field. Actual `pause_for_user` handling remains. Corrected comments around audio bookkeeping, cancellation ownership, and physical input.
- **Remove generated clutter.** Deleted the ignored 281 MB repository build cache, 20 obsolete workspace build-cache folders, and 27 historical app bundles. Kept the canonical app, current build/test caches, unique design work, diagnostics, regression fixtures, and compatibility migrations. No live source feature was removed merely to reduce the file count; Git holds the previous implementation instead of commented-out duplicate code.

Validation: **176 offline tests passed with zero failures**; Release build and signature verification succeeded at the canonical app path. Coverage includes Decisions wire protocol, bounded target choices, geometry/redaction, unavailable/stale decisions, review-only and continuation contracts, mixed-rate persistence, and existing voice/session behavior. No app launch, live API/desktop test, or permission refresh was performed. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-decisions-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-decisions-build.log).

## 2026-10-20 — Loading proportions and white dots

- Narrowed the loading notch by 24 points and increased its height by 8 points. Its body now extends 16 points beyond the hardware notch's width and 56 points below its height.
- Enlarged the ring view from 26 to 30 points, the dot orbit radius from 9 to 10.5 points, and the dots from 4 to 4.5 points.
- Replaced the dots' gradient, rim, and glint with solid white fills and a faint white glow. The six-dot entrance, rotation, pulse, and exit timings are unchanged.

Validation: Release build and signature verification passed at the canonical app path. Geometry review confirmed clearance for the larger ring's pulse and glow below the hardware notch. No live visual session was run; the app was not launched and permissions were not changed. Log: [build](/Users/sameemsaleem/Product/work/mouse-loading-refinement-build.log).

## 2026-10-20 — Screen speech before interrupting work

- **Added a separate text-only Luna check for finalized speech.** It extracts clearly directed computer commands or amendments from mixed chatter, preserving the command's targets and constraints. Conversation, informational questions, quoted/hypothetical instructions, and ambiguous intent are instructed to produce an ignore result. There is no fixed command vocabulary.
- **Keep the current task running during recognition and screening.** Raw audio, live partial words, the accurate replay, and a pending or ignored check no longer cancel action requests or replace the busy notch presentation. A failed check also leaves existing work alone.
- **Interrupt only after command intent is accepted.** Mouse cancels old work, waits for input cleanup, and captures a fresh screen before forwarding extracted text to the action model. That model still chooses a targeted revision or replacement using the current goal and dispatched progress; actions already posted cannot be undone.
- **Separate screening from action context.** The check uses Luna Fast with low reasoning and strict structured output, without images, action tools, or a previous-response chain. Accepted extracted commands retain their full text in action context and, after action-model acceptance, session history. Surrounding background words are excluded.
- **Serialize speech checks independently of computer execution.** Utterances remain in arrival order. Stop or deactivation cancels pending screening and invalidates queued results. First-word Stop still acts locally on provisional recognition, bypassing both final transcription and the API check.
- **Retained the 500 ms endpoint, accurate second pass, and 1000 ms step wait.** Speculative capture still overlaps replay while idle, but never goes to the speech filter. No speculative capture is started for background speech during a task.
- **Count both request types.** Ignored speech uses text-only screening tokens; accepted spoken commands add a screening round trip before action inference. This is intent screening, not noise suppression or speaker recognition, and does not guarantee rejection of background commands.

Validation: **134 offline tests passed with zero failures**, including text-only request construction, strict extraction parsing, serial screening, ignored/failed checks, and Stop invalidating late results. Release build and signature verification succeeded at the canonical app path. No live speech-filter accuracy or microphone-to-desktop test was run. The app was rebuilt without launching it or changing permissions. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-speech-filter-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-speech-filter-build.log).

## 2026-10-20 — Six-dot loading animation

- **Replaced the notch's “Thinking…” label with six glowing white dots** while waiting for the first model response and subsequent decisions. Each dot has a translucent gradient, fine rim, and soft glow.
- **Introduced a simultaneous center-out entrance.** All six dots grow, fade from zero to full opacity, and move from the center to their ring positions over the same 400 ms. Slow rotation starts immediately and completes one orbit every 11 seconds.
- **Added a traveling size pulse.** Adjacent pulses overlap as each dot grows and settles, completing a circuit every 1.2 seconds.
- **Shrink the dots away sequentially when a response arrives.** The complete exit lasts 255 ms and affects presentation only; computer actions do not wait for it. New speech or loading states supersede stale presentation callbacks without restarting an exit already underway.
- **Respect Reduce Motion.** The ring stays stationary and appears/disappears immediately when that preference is enabled.

Validation: Release build and signature verification succeeded at the canonical app path. The new indicator was confirmed in the built executable, and interrupted entrance/exit handling was reviewed. No live visual or microphone test was run; the app was not launched and privacy/Keychain permissions were not changed. Build log: [mouse-loading-build.log](/Users/sameemsaleem/Product/work/mouse-loading-build.log).

## 2026-10-20 — Forgiving endpoint and task steering

- **Changed the endpoint from 150 ms to 500 ms** of quiet audio and stable recognition text. The accurate second pass and parallel screenshot capture remain.
- **Kept live speech available during thinking and execution.** Execution-state transitions no longer clear unfinished words or audio. Accurate replay advances the recognition boundary so a short correction after a long request is not swallowed.
- **Suspend stale work when speech resumes.** Raw activity and pre-action checks cancel pending requests and queued input. A replacement waits for cancelled input cleanup before capture; stale generations cannot dispatch or update the new task. Text-free noise can release the hold, while ignored conversation preserves the accepted goal.
- **Let Luna choose targeted revisions versus new tasks.** Strict `task_update` metadata (`revise` or `replace`, plus the complete goal) accompanies action and pause responses without another classification call. Active context includes full accepted utterances and actions actually dispatched. Revisions retain progress; replacements abandon the old goal while retaining physical effects as background. Partial inputs are marked uncertain, never silently replayed as unfinished steps.
- **Keep continuations received before the first acceptance.** Finalized fragments accumulate until Luna interprets them together. Accepted amendments enter session memory; superseded entries are marked paused with a revision/replacement outcome.
- **Show “Thinking…” after submission.** The notch no longer displays a transcription state throughout the API wait. New speech returns it to live wrapped text.
- **Rebuilt only, without permission work.** The canonical app remains `/Users/sameemsaleem/Product/outputs/Mouse.app`; this update did not launch it or modify/check privacy permissions or saved-key authorization.

Validation: **118 offline tests passed**, Release build and signature verification succeeded. No live microphone, API, desktop-action, or semantic rerouting test was run. Existing macOS simulator/deprecated Keychain build diagnostics do not represent tests of voice or permissions. Logs: [tests](/Users/sameemsaleem/Product/work/mouse-steering-tests.log), [build](/Users/sameemsaleem/Product/work/mouse-steering-build.log).

## 2026-10-20 — Session memory for accepted commands

- **Expanded follow-up context from one previous task to the full app session.** Mouse retains every Luna-accepted computer command in order, with its entire text. Each new command receives the prior accepted-command history; the current utterance remains separate.
- **Record only accepted computer commands.** An ignored utterance is not added to memory. Neither is a request cancelled or failed before Luna returns a valid accepting response. This uses the same Luna request that chooses the action, without an extra classification call or a fixed local command vocabulary.
- **Track outcomes instead of treating attempted work as finished.** Records distinguish running, completed, paused, stopped, and failed tasks. An accepted task remains in history after Stop or failure, together with the available outcome, so a later request can refer to it without implying it completed.
- **Keep session memory in RAM.** No command-history text file is written. Stop, sleep, and microphone pause preserve history; quitting or restarting Mouse clears it. The separate 20-entry activity display does not cap the history sent to Luna.
- **Preserve the execution loop.** Session history supplies background context for a new task. It does not replay stored actions, skip a model request, or reuse a prior task's Responses chain. Within a task, `previous_response_id` still carries its actions and screenshots.
- **Keep full text without silent trimming.** There is no command-count limit, character truncation, or automatic summary. Long sessions send more input tokens and may add latency or reach the provider's context limit. Earlier commands are background, not fresh authorization.

The full offline suite passed **100 tests with zero failures**, and the Release build and signature verification passed. The update was installed and opened at the canonical app path; Settings displayed its session-history explanation and preserved the **1,198-request counter**. Mac permission and saved-key renewal were still in progress at that check. This verifies the tested state/protocol behavior and installation, not live semantic recall, microphone quality, or end-to-end desktop control. Logs: [offline tests](/Users/sameemsaleem/Product/work/mouse-session-memory-tests.log), [Release build](/Users/sameemsaleem/Product/work/mouse-session-memory-build.log).

## 2026-10-19 — Return to Luna + screenshot

- **Removed the Decisions API selection step.** A completed command now goes directly to `gpt-6-luna` through Responses, using Fast service and low reasoning. Luna decides whether to act, ask for required input, finish, or ignore the utterance in that same request.
- **Removed the accessibility-tree/native-target route.** Mouse no longer collects AX roles, labels, values, element bounds, or supported native actions for the model. It no longer tries an AX press before using coordinates. Accessibility permission is still necessary for synthesized mouse and keyboard input.
- **Removed the Astra escalation route.** Difficult or long tasks stay in the same Luna Responses loop; there is no separate thinking-model handoff between steps.
- **Preserved screenshot context on every inference turn.** After executing a batch, Mouse sends the resulting screenshot back with the matching function-call ID and continues the same Responses chain. The screenshot supplies target appearance and position without a routing request in between.
- **Changed the between-step wait from 350 ms to a nominal 1000 ms.** Mouse waits after an executed action batch, then takes the fresh screenshot and asks Luna for the next step. Scheduling can extend the wait, and capture/network/inference add time beyond it. This gives the target application more time to settle. Stop can cancel the wait. This is separate from the 150 ms speech endpoint and does not delay the first request by an extra second.
- **Preserved the other recent improvements.** The accurate second transcription pass, parallel screenshot capture, full previous command, live previews, immediate recognized Stop, structured descriptions, speech recovery, persistent activation, and uncapped total steps/requests remained. The previous-command record was expanded into session history on 2026-10-20.
- **Preserved usage history.** Returning to Luna does not reset counters or reprice the accumulated estimate from earlier model routes. New usage is estimated with Luna Fast rates.
- **Removed obsolete routing code and checks.** Decisions and AX fixture modes and their route-specific tests are no longer part of the simplified app. The screenshot/Responses smoke check remains.

The simplified implementation passed **94 offline tests with zero failures**, a Release build, and signature verification, and was installed at the canonical app path. The live Luna fixture passed in two requests using generated images; it verified structured clicking and screenshot continuation without sending a real screen or executing desktop input. Its 3.46-second duration excludes the app’s one-second settling pause. The existing 1,099-request counter was preserved, and the fixture added two requests. These checks do not establish microphone quality or end-to-end desktop control.

## 2026-10-19 — Hybrid control experiment, subsequently removed

- Added a Luna Decisions request ahead of execution. It could choose a native AX action, request generated Luna actions, delegate to Astra, request user input, ignore speech, or declare completion.
- Added a bounded accessibility snapshot of the foreground app's focused/main window and menu bar. It provided snapshot-scoped element IDs, roles, readable labels/values, supported actions, and bounds mapped into screenshot coordinates. Unlabeled controls could be matched to their visual appearance. Secure text values were excluded.
- Limited traversal to keep it bounded: up to 120 targets, a 300 ms traversal budget, per-read timeouts, and depth/node/child limits. This was a best-effort foreground snapshot, not a complete list of every OS control or installed application.
- Added pre-dispatch checks for target identity, foreground app, geometry, age, enabled state, and available action. An uncertain AX dispatch paused without blindly repeating the operation as a click.
- Kept screenshots in both Decisions and Responses requests. Generated actions needed an additional Responses call after selection; therefore this experiment did not guarantee lower latency for every task.
- Added Astra Responses with medium reasoning for selected difficult tasks, preserving its continuation chain once delegated.
- Added per-route cost accounting and generated-image API checks. The live Decisions fixture passed target selection, completion, and ignore cases; the Luna fixture passed structured click and screenshot continuation. These were synthetic checks, not full voice-to-desktop benchmarks.
- The native AX fixture observed its synthetic button receive one press, but macOS then returned an ambiguous AX error. Its full success/replay checks did not pass. The fixture was not evidence of reliable AX action acknowledgment.

**Current status:** all three extra routes—Decisions, native AX targets, and Astra—are removed by the current single-Luna change.

## 2026-10-18–19 — Speech responsiveness and reliability

### Earlier text and a shorter endpoint

- Enabled faster provisional results alongside volatile results so the notch can display tentative words while speech is still in progress. These words may be revised by Apple's recognizer.
- Reduced the quiet endpoint to 50 ms during latency experiments, then changed it to **150 ms of quiet audio and stable text** at the user's request. Endpoint checks run every 10 ms; UI audio-level updates remain limited to every 100 ms.
- Kept the **second accurate local transcription pass**. Live text drives display and immediate controls; the finalized replay determines the ordinary command sent for execution. Removing the replay was discussed and explicitly excluded from implementation.
- Separated the endpoint threshold from total latency. Recognition, finalization, capture, model requests, and execution still take time; the threshold alone does not establish a voice-to-action benchmark.

### Fixed live text after activation or a prior command

- Investigated the report that words appeared only after the whole command, even when Mouse was already active.
- Found a consumed-boundary interaction: Apple's provisional segment could begin before a previously consumed wake phrase/utterance while also containing new words. The old filter discarded that overlapping segment, hiding the fresh words.
- Added `SpeechBoundarySynchronizer` to advance the live analyzer through consumed audio after commits, resets, and discards. Calls are serialized and coalesced, and callbacks from retired analyzer instances cannot affect a new stream.
- Kept the old-audio rejection rule, preventing previously consumed speech from being executed again. The fix changes how the live stream advances instead of broadly accepting stale segments.
- Added deterministic boundary tests and a real Apple streaming fixture using synthetic speech at playback speed. Wake gaps of 0.25, 0.8, and 1.5 seconds passed growing-preview checks. Those results validate the fixture, not microphone quality or the rendered notch.

### Immediate wake and Stop

- Moved **“Hey Mouse” activation and initial-word “stop”** onto provisional recognition. They no longer wait for the quiet endpoint or accurate replay to take effect.
- A recognized first word such as “stop” in “stop now” cancels current work and returns to standby. “Type stop,” “don't stop,” and “stopwatch” do not trigger that local control. An ordinary phrase beginning “stop,” such as “stop by later,” can still sleep Mouse.
- Stop cancels pending capture/model work, checks cancellation between actions and during longer input operations, and prevents late responses from resuming a cancelled command. Already-posted clicks or typing cannot be undone.
- Recognition still has latency: immediate handling means immediately after the recognizer reports the word, not an instantaneous acoustic guarantee. The menu's Stop control bypasses recognition.

### Audio retention and recovery

- Changed audio retention to follow detected speech independently of when the recognizer emits its first words. This protects the beginning of an utterance when recognition startup is slow.
- Added replay-completeness checks for coarse audio ranges and trimmed silence. Mouse discards an uncertain shortened replay rather than executing a potentially incomplete command.
- Added bounded handling for audio backlog, stalled input, device changes, long unfinished utterances, and finalization failures. Retained utterance audio is bounded to roughly a minute, and finalization has a 12-second timeout.
- Added up to three automatic restarts in a rolling 60-second window, with 0.3, 0.8, and 1.5 second delays. Recovery discards unfinished speech and current work, then returns to standby; the user wakes Mouse and repeats the command. Exhausted recovery reports the specific error.
- **Tried and removed native microphone voice processing.** An `AVAudioEngine` voice-processing/noise/echo path and other-audio ducking were added, then removed after the report of missing audio. The app currently uses normal microphone input. It does not use Krisp or identify the owner's voice.
- Added a finite eight-second microphone diagnostic that counts signal and previews without saving recordings/transcripts, calling the API, or controlling the desktop. The post-removal live signal verification remained incomplete; a running engine alone was not counted as proof that audio worked.

## 2026-10-18–19 — Capture, task context, usage, and project organization

- **Overlapped capture with final transcription.** At the quiet endpoint, a screenshot can begin while the accurate replay finishes. Candidate identity, command generation, foreground process, display geometry, and a 1.5-second freshness limit determine whether that image can be reused. Revisions, cancellation, changed focus, or expiry discard it and trigger a fresh capture.
- Preserved focus handling for typed commands: restore the previously active app when possible, hide Mouse's normal windows, and exclude Mouse-owned windows from capture. The command keeps its selected display; coordinates account for image/display ratios and global display origins.
- Investigated capture versus separate resizing timings and the proposed 40% image mode. **No extra 40% resize was shipped.** Existing capture uses logical display dimensions, capped at 1600 pixels wide with proportional height, and JPEG quality 0.78. Capture already selects output dimensions; native physical-pixel screenshots are not sent unchanged by default.
- **Removed the eight-turn per-command guard.** The earlier cumulative request cap had already been replaced by counters, but the separate execution guard remained until this later change. Total task steps and requests are now uncapped. Each structured action batch still permits 1–12 actions.
- **Retained the entire previous completed or paused command and result.** Removed the character trimming used for follow-up context. At this stage it was one in-memory task record, not persistent memory or a full chat history; ignored, cancelled, and failed tasks did not replace it. The 2026-10-20 change superseded this with session-wide accepted-command history.
- Expanded accounting checks so existing totals remain intact and read/write problems warn without disabling execution. Request attempts count before networking; returned token usage is recorded when available. The estimate is not an API spending limit or authoritative bill.
- Created and expanded the master README with current flow, setup, privacy/storage boundaries, source map, diagnostics, testing limits, and deferred work.
- Moved the workspace into `/Users/sameemsaleem/Product`. The canonical source is `outputs/Mouse`, and the app is `outputs/Mouse.app`. Older bundles such as `work/Mouse-Morph.app` are build/test artifacts; they are not additional app features or the current release.

## 2026-10-18–19 — Notch shape refinement after the initial redesign

- Added small **concave upper shoulders** where the left and right sides meet the screen edge, matching the hardware notch's curved junction rather than forming a straight 90-degree attachment.
- Kept the expanded shoulder radius at 6 points across ready, transcript, and action sizes. The shoulders extend the contour without changing the existing body/text widths.
- Corrected the collapse timing so the visible **left, right, and bottom edges reach the hardware notch together**. Shoulder insets now follow the same resize progress as the panel and continue from the actual shape if an animation is interrupted.
- Retained native glass on the body and lower corners, the black upper cap, click-through behavior, and text layout from the earlier notch implementation.

## 2026-10-18 — Committed milestones

### 19:46 — Mouse becomes the sole name · `a352bc5`

- Renamed the executable, Swift package/modules, source directories, Xcode project/scheme, build scripts, resources, visible labels, and checks from Chosen to Mouse.
- Made **“Hey Mouse”** the only wake phrase. “Hey Chosen” no longer activates the app.
- Migrated legacy usage into Mouse's support directory without overwriting an existing Mouse history. Kept the old usage file.
- Intentionally retained the stable bundle identifier and Keychain service to preserve the saved connection and app identity. Those internal compatibility names do not make Chosen an alternate product name.

### 19:39 — Modern on-device Apple speech · `793ef8a`

- Replaced legacy `SFSpeechRecognizer` with **SpeechAnalyzer and SpeechTranscriber** on supported Apple silicon/macOS 26 hardware.
- Added speech support/locale checks, model-asset preparation and download progress, owned audio-buffer conversion, and timestamp-based transcript assembly.
- Kept local speech processing; microphone audio is not sent to OpenAI and speech recognition needs no separate paid transcription API key.
- Removed the legacy Speech Recognition permission request. Microphone permission remains required. Setup failures are reported instead of silently falling back to the old recognizer.
- Updated the local recorded-audio diagnostic and transcript-state tests for the new engine.

### 18:57 — Let Luna interpret unrestricted commands · `30d29fa`

- Removed the recently added local command-intent allowlist. Natural requests no longer have to match a predefined verb/app grammar before reaching the model.
- Sent completed active utterances to Luna, which can return structured actions or `ignore_utterance`. Casual conversation and informational questions are instructed to produce no desktop action or conversational response.
- Kept only the dedicated local Stop control. “Cancel” was removed as a local cancellation word.

### 18:49 — Stop means sleep · `1e1045a`

- Changed Stop from merely interrupting the current operation to ending the active session and returning to wake-phrase standby.
- Kept microphone pause as a separate control: sleep still permits wake detection; microphone pause disables capture entirely.

### 18:46 — Initial non-command filtering experiment · `aae3d90`

- Added an initial local intent filter and model-side ignore handling to avoid acting on ordinary conversation or questions.
- The local filter was too restrictive for real-world phrasing and was removed in the 18:57 commit. Model-side structured ignore behavior remains.

### 18:32 — Morph into the real notch · `ed1b9e9`

- Changed hiding from fading away to shrinking into the hardware notch's bounds before removing the overlay.
- Refined the notch geometry and text placement so the label sits higher and is less visually dominant.

### 18:09 — Attach to the physical top edge · `cc98739`

- Corrected panel placement so it touches the physical screen edge rather than floating underneath the menu-bar region.

### 17:43 — Compact Mouse interface and structured actions · `b1902ae`

- Replaced the large control-window experience with a small, nonactivating **notch interface**. The app continues to live in the menu bar; Settings handles configuration/testing.
- Introduced the black-to-native-glass treatment and filled upper area. Ready state uses a slightly expanded empty notch rather than a generic status dot.
- Added constrained-width transcript presentation that wraps and grows downward, then shrinks into a short current-action label. The panel itself has no Stop button.
- Changed the 20-second follow-up session into **persistent activation**. Mouse stays ready between tasks until explicitly stopped; inactivity does not expire the session.
- Added required short action descriptions to strict structured output. Labels such as “Searching YouTube…” arrive with the actual action batch rather than requiring a second description request.
- Added structured execution and pause-for-user responses; validated generated actions before executing a batch. Structured ignore behavior followed in the intent-filtering work.
- Kept Settings hidden after a task instead of restoring a large control window every time. Added menu access to activation, Stop, microphone controls, and settings, plus preview modes for checking notch states.

### 17:27 — Preserve the original Chosen prototype · `346b9fe`

The first Git checkpoint already contained work from the initial prototype; Git does not provide separate dates for each preceding edit.

- Built a native Mac menu-bar/background voice interface with **“Hey Chosen”**, typed testing, optional launch at login, and an initial 20-second follow-up session.
- Used Apple on-device legacy speech recognition for voice input; Whisprflow and Jev were discussed but were not dependencies of the implemented app.
- Implemented the screen → Luna → mouse/keyboard input → fresh screen loop through OpenAI Responses, using Fast service and low reasoning.
- Supported clicks, pointer movement, scrolling, dragging, typing, key combinations, waits, and screenshot verification. Used global coordinate mapping rather than assuming image pixels equal native display pixels.
- Used native macOS glass in the control interface, ScreenCaptureKit for captures, Keychain for the API key, and explicit Mac permissions for microphone, speech, screen capture, and input.
- Replaced the early cumulative API limiter with a persistent request/token counter and estimated cost. An independent eight-turn guard still existed at this checkpoint and was removed later.
- Added offline tests, a synthetic-image live API check, recorded-speech diagnostics, release build tooling, and ad-hoc signing for local installation.

## Design exploration and proposals that are not shipped features

- Explored several visual directions before the implemented notch: floating glass cards, a notch/island attachment, filled upper corners, a subtle ready state, wrapping transcripts, and short action labels. Concept images illustrated the intended behavior; they were not themselves functioning UI.
- Explored the **Mouse** brand and logo: a cursor with a top-down animal-mouse cutout, geometric form studies, yellow/color variants, nose/ear refinements, and iPhone home-screen mockups. These are design concepts, not evidence of an iPhone build or a finalized installed icon.
- Discussed speaker-specific recognition, Krisp-like filtering, removing the accurate second pass, selectively omitting images, more aggressive resizing, browser DOM access, richer OS/app catalogs, and an on-device Apple decision model. These are not current features.
- Spaces, fullscreen presentation, and multiple-display notch placement remain deferred. Capture coordinate support is separate from complete overlay behavior in those environments.
