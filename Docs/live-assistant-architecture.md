# Live Assistant companion architecture

Status: manual LAN-address vertical slice implemented
Decision date: 2026-08-01

## Decision

Keep PermanentUnderclass as the host, assistant brain, and sole source of truth. The
Swift process owns local reference ingestion, transcript state, assistant model
calls, prompt construction, credentials, usage accounting, and recovery. Add a
small HTTP service inside that process and serve a thin browser display from
the same origin. The display renders presentation-ready state; it does not
index documents, retrieve context, assemble prompts, or call a model.

Stream ordered JSON events from host to display with Server-Sent Events (SSE);
send the small number of presentation actions back as idempotent JSON HTTP
requests.

The implemented gateway binds to all IPv4 interfaces. The Mac UI confirms that
the server is running and publishes a directly usable LAN IP and runtime-selected
port. It prefers port `4173` and asks the operating system for an available port
if that port is occupied. This manual-address mode is intentionally limited to
trusted LANs until the pairing and transport-encryption hardening milestone is
complete (see Security and pairing).

### Recommended stack

- Host/server: Swift plus Hummingbird 2.x. Hummingbird is small enough to
  embed, uses Swift concurrency, and can write a streaming response body. Do
  not add the WebSocket extension for v1.
- Client: standards-based HTML/CSS/JavaScript static assets. The prototype
  deliberately has no runtime framework or package install.
- Discovery later: Bonjour service `_punderclass._tcp` plus a manual URL/QR
  fallback.
- Persistence: an in-memory event ring for the first loopback slice. A local
  SQLite WAL journal is the recommended follow-up if surviving a producer-app
  crash becomes a requirement.

## Why SSE, not a WebSocket

The ongoing traffic is overwhelmingly host-to-display: transcript deltas,
final turns, answer outlines, source matches, usage, and health. SSE gives this
shape ordered delivery over HTTP, native browser reconnects, and a standard
`Last-Event-ID` resume cursor. Commands such as pin, dismiss, or pause are
ordinary short requests and do not need a permanent upstream channel.

A WebSocket still needs sequence numbers, replay, snapshots, authentication,
heartbeats, and retry policy. It adds another state machine without removing
any of the failure handling that matters here. Reconsider it only if the
client later sends a sustained high-rate stream (for example, audio or
collaborative editing), not merely because interaction is bidirectional.

gRPC-Web, MQTT, and a message broker are larger operational commitments and
do not improve this single-producer/local-client case.

## Topology and responsibilities

```text
System/app audio ──┐
Microphone ────────┼─> PermanentUnderclass macOS host
Reference folder ─┘      ├─ capture + transcription
                         ├─ local document ingestion + change monitoring
                         ├─ prompt assembly + assistant model calls
                         ├─ ordered event hub + replay buffer
                         ├─ aggregate usage/cost tracking
                         └─ HTTP/SSE companion gateway
                                     │ presentation-ready events only
                                     └─> Thin browser display
                                          render + small UI commands
```

OpenAI and Gemini keys stay in the Mac Keychain. The browser never receives
them, never receives the reference corpus, and does not call either provider
directly. The host
continues capture, indexing, and assistant work when no display is connected.

## HTTP surface

All routes are same-origin and versioned.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/` | Static companion client |
| `GET` | `/v1/snapshot` | Atomic current state plus stream watermark |
| `GET` | `/v1/events` | SSE stream; resumes from `Last-Event-ID` |
| `POST` | `/v1/commands` | Pin, dismiss, pause/resume presentation |
| `POST` | `/v1/pair` | LAN-only pairing exchange; not needed on loopback |
| `GET` | `/v1/health` | Protocol version, producer identity, readiness |

Every command includes an `Idempotency-Key`. Repeating a command after a
timeout returns the original result and does not apply the action twice.

## Event envelope

SSE's `id` is the ordered cursor. The JSON repeats it so recorded fixtures and
non-browser clients remain self-contained.

```text
id: 01J...:2487
event: transcript.final
data: {"v":1,"streamId":"01J...","sequence":2487,"emittedAt":"2026-08-01T01:24:42Z","name":"transcript.final","payload":{"id":"Other-item-91","speaker":"other","text":"Tell me about a time...","startedAt":"2026-08-01T01:24:39Z","endedAt":"2026-08-01T01:24:42Z","isRefined":false}}

```

Initial event set:

- `GET /v1/snapshot`: full replaceable state and its `watermark`.
- `session.status`: listening/stopped, capture health, the explicit `meeting`
  or `interview` purpose, active host behavior, and whether the display should
  render AI cues or the local transcript-only surface.
- `transcript.partial`: replace the partial for one `turnId`; safe to coalesce.
- `transcript.final`: append or replace the finalized `turnId`.
- `transcript.revised`: replace text after the final transcription pass.
- `assistant.bridge`: ephemeral, non-substantive thinking phrase generated from
  a still-forming interviewer partial, the first short speech pause, or the
  finalized-turn fallback. It is never added to the four-card display history,
  but every accepted bridge is retained in the local interview archive.
- `assistant.working`: generation started for a transcript watermark.
- `assistant.suggestion`: newest structured answer outline with citation labels.
- `assistant.state`: idle state after a completed model check, including whether
  the latest other-speaker moment produced no outline. This prevents silence from
  being confused with a disconnected assistant.
- `usage.updated`: cumulative reported usage and estimated USD by model.
- `reference.status`: folder display name, document count, revision, and
  readiness; never document contents.
- `stream.reset`: client must discard local state and request a snapshot.

An `assistant.suggestion` payload is already a view model, for example:

```json
{
  "id": "sg_01J...",
  "basedOnSequence": 2487,
  "topicID": "Other-item-91",
  "topicNumber": 3,
  "question": "Tell me about a time you improved a critical system.",
  "preamble": "The clearest example is the checkout path, where latency was hurting conversion.",
  "beats": [
    {"label": "My move", "point": "I traced the slow path and removed a repeated lookup."},
    {"label": "Proof", "point": "I validated a 41% lower p95 under load."}
  ],
  "citations": [{"label": "Checkout latency", "path": "Projects/Checkout.md"}],
  "grounding": "localReferences",
  "confidence": "high",
  "generatedAt": "2026-08-09T07:40:00Z",
  "generationMilliseconds": 640,
  "trigger": "partialTranscript",
  "totalLatencyMilliseconds": 1440
}
```

When the remembered experimental switch is active for an interview,
`assistant.bridge`
publishes a smaller object before the full suggestion:

```json
{
  "id": "bridge_01J...",
  "topicID": "Other-item-91",
  "sourceText": "How did you verify that you found the right bottleneck?",
  "text": "Let me choose the clearest example for a moment.",
  "generatedAt": "2026-08-09T07:39:58Z",
  "generationMilliseconds": 1276
}
```

The display temporarily hides the previous answer, shows this thinking phrase,
and then replaces it with `assistant.suggestion`. The bridge and full request
run independently: bridge text is never inserted into the full prompt, so its
early interpretation cannot steer or constrain the substantive cue.

The host chooses the facts and concise first-person wording. For Answer Mirror,
the teleprompter shows the spoken preamble first; labels remain internal
structure for the supporting cues. Meeting Assistant suggestions omit the
preamble field and retain their direct three-to-five-beat shape.
Answer Mirror uses ordinary vocabulary, short clauses, and contractions while
keeping exact technical nouns when they carry the substance. The prompt rejects
report-like signposting and abstract noun stacks, but it does not add fake
hesitation or filler to simulate speech. Recent candidate turns provide a style
sample for sentence length and formality, with fillers, mistakes, and abandoned
phrases explicitly excluded. Candidate wording is used only for broad sentence
length and formality after the answer substance is chosen; generic framing,
slogans, self-description, and recently mentioned topics are not copied merely
because they appeared in the candidate's last turn. For substance, the prompt
orders evidence as: current interviewer request, concrete candidate speech,
reference evidence, an applicable cached rehearsal story, and only then generic
candidate style. A concrete correction, denial, project, mechanism, check,
constraint, or result in candidate speech therefore wins field by field.
For an unsupported past-incident request in Grounded mode, the spoken cue uses
a worked `If` scenario rather than claiming that the event happened. It names a
specific symptom, competing causes, controlled check, resulting change, and
verification. The structured model output also reports whether the spoken cue
contains answer-mode or grounding commentary. A positive report is rejected as
invalid grounding and enters the existing one-retry correction path instead of
being shown to the candidate.
Plausible Rehearsal also requires a structured substance map: project anchor,
observed signal, before-to-after mechanism change, discriminating check, and
bounded outcome. All five form one causal mini-story across the spoken preamble
and three beats. The host retains the most recent assistant-created map and cue
and includes them in the next full request as non-factual continuity context.
The model decides in that same response whether the question is a follow-up; if
so it preserves the story and deepens it, and otherwise ignores it and creates a
new story. Intervening candidate speech that clearly establishes a different
account overrides the retained draft. This adds no preliminary model call. The
map remains machine-readable for evaluation and diagnostics, while the display
shows the cue and its separate verify-before-use warning rather than a second
block of planning prose.
Suggestions generated from the pause-time partial and finalized text of the
same transcript turn share one `topicID` and `topicNumber`. The newest cue is
primary while each point from the latest earlier version appears directly
beneath its corresponding new point in smaller, dimmer type. Earlier topics
remain in the separate cue history. A transcript correction therefore does
not erase useful context or reset the topic timer.
`assistant.suggestionHistory`
in the atomic snapshot retains the newest four outlines in newest-first order.
The focused display uses that history as a typographic round stack: the current
question, its session-stable `topicNumber`, and an elapsed timer derived from
`generatedAt` are primary. The connection state sits in the same compact topic
context cluster instead of consuming a separate row. On tablet-sized displays,
the current topic and all of its current and inline-earlier points form a
viewport-sized stage; the browser measures that stage after rendering and
reduces its type and spacing when necessary. Up to three distinct earlier
questions and their cues start below that first viewport and remain available
by scrolling. The display may also copy, pin, or dismiss these objects, but it
does not receive retrieved chunks and does not run a second interpretation
step.

An 800 ms audio pause from `Other` schedules a structured shorthand outline
from the current other-speaker partial before the 3 second final-turn boundary.
A finalized `Other` turn schedules immediately as the reliable fallback. `You`
turns remain visible in the transcript for comparison but do not schedule or
replace the model outline. Exact partial/final duplicates for one other-speaker
turn are coalesced. This is structural speaker routing, not a language
heuristic; there is no keyword or pattern gate in front of the model. A
completed decision that returns no outline leaves the previous suggestion intact and
is retained as assistant state so
the display can distinguish "question checked, not clear enough" from "no
inference happened."

Plausible Rehearsal can optionally start an independent early-bridge lane 600
ms after the first `Other` partial arrives, without waiting for silence. It
uses `gpt-5.6-luna`, no reasoning, a strict one-string schema, and Priority
processing. The model—not a keyword or regex gate—decides whether the partial
already establishes a stable request. If so it returns a five-to-twelve-word
request for thinking time without any answer substance; an unclear fragment
returns an empty string. If the partial grew while that request ran, the host
may try once more after 200 ms; the speculative limit is two calls per
interviewer turn.

Those speculative attempts do not consume the reliable opportunities. A
separate 400 ms silence callback starts a zero-delay bridge request from the
latest partial, while the structured full-cue check retains its 800 ms
threshold.
Voice resumption can re-arm this opportunity for up to three distinct pauses,
so a mid-question pause does not consume the end-of-question chance. If those
pause requests return no bridge, the finalized transcript receives one
independent zero-delay fallback. Each request is told whether its input is
forming, paused, or finalized so the model can be conservative without
treating a completed question as perpetually unfinished. An inconclusive
partial full-cue check does not erase a useful bridge; the finalized check or
full suggestion retires it.

Interview cues have a six-second usefulness deadline measured from the end of
the interviewer's speech, including host delay, the first request, and any
grounding repair. The first request and repair share one absolute deadline. A
late result is recorded as `timedOut` and is not published or shown as an error;
an already visible early bridge remains in place. Meeting Assistant keeps its
existing request timeout because its interaction cadence is different.

A bridge may only ask for a brief moment to think, lightly adapting to whether
the request calls for an example, explanation, comparison, or decision. It uses
short clauses and ordinary words rather than formal coaching language. It
receives recent dialogue, session context, and the last four accepted bridge
phrases so it can vary its wording, but no reference documents. It cannot state
a conclusion, approach, mechanism, action, fact, opinion, project, result, or
other answer substance. A new
interviewer turn cancels the older full and bridge generations so a stale result
cannot erase the new bridge. Raw `Other` speech is still unclassified, though,
so it cannot remove a usable cue from the focused display by itself. The display
marks that cue as held while the models check the interruption. Only an accepted
`assistant.bridge` or `assistant.suggestion` moves the new turn into the speaking
position; an acknowledgment or other no-answer result leaves the cue in place.

### Realtime audio-to-text answer lane

The current audio WebSocket is a Realtime transcription session. A separate
prototype can instead use a full Realtime conversation session for the remote
speaker track, keep VAD, and request text-only model output with
`output_modalities: ["text"]`. OpenAI's Realtime API also emits
`response.output_text.delta`, so the companion could render the opening words
without waiting for a complete response. VAD can retain speech boundaries while
automatic response creation is disabled, and an out-of-band text response can
be identified with metadata. See the official
[Realtime conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations).

The first experiment should replace only the Luna bridge, not the structured
full cue. Feed the remote audio track to the Realtime conversation, keep its context
small, stream one plain-text opening, and compare speech-end-to-first-text,
answerability, acknowledgement false positives, and bridge/full independence
against the existing lane. This isolates native audio latency without asking the
Realtime response to reproduce the full citation and rehearsal-plan contract.

The structured decision labels every displayed outline as `localReferences`,
`webSearch`, or `generalKnowledge`. Local grounding requires at least one
validated citation path from the current indexed snapshot. Meeting Assistant
exposes the selected provider's hosted search tool with automatic tool choice:
OpenAI uses `web_search` with low search context, while Gemini uses
`google_search` through the Interactions API. Ordinary Answer Mirror requests
omit tools, tool choice, and search-source inclusion so the fast path uses local
references and general model knowledge. The explicit web-search test temporarily
requires the selected provider's search tool. Web grounding requires at least
one HTTP(S) citation whose
URL appears in that provider's response annotations or complete hosted-search
result list; the display presents the source as a visible, clickable link.
Gemini structured output can put citations in the JSON answer without repeating
them as text annotations. The adapter accepts that shape only when the timeline
contains a matching successful `google_search_call` / `google_search_result` and
the citation is a Google-issued HTTPS redirect under the
`vertexaisearch.cloud.google.com/grounding-api-redirect/` path. Arbitrary URLs
authored inside the JSON answer remain untrusted. The companion also renders the
returned `search_suggestions` HTML in a script-disabled sandbox next to the
grounded result. Search suggestion widgets and their associated Gemini links
remain transient live-display data and are removed from interview archives. If
neither an indexed file nor a web source supports a useful outline, the model
may use the live discussion as context and general model knowledge with an
empty citation list. Public results are untrusted data and cannot override the
assistant behavior. Interview cues use
hypothetical first-person language (for example, "I would…") rather than
invented past experience. Meeting cues explicitly mark unsupported facts for
verification and never invent commitments, metrics, deadlines, decisions, or
status. A grounding warning remains in copied diagnostic output.

The host also writes privacy-safe lifecycle markers under the
`com.newtypekk.punderclass` subsystem and `LiveAssistant` category.
They record scheduling, starts, skips, completion outcome, cancellation,
trigger kind, trigger-to-start time, assistant-generation time, and transcript-to-result time
without recording transcript content or credentials.

Event names and payload keys are language-level identifiers, not user-facing
copy. Unknown event names must be ignored so a v1 client can coexist with a
newer producer.

## Reconnect and no-loss contract

1. The producer assigns a strictly increasing sequence before publishing an
   event and retains recent events in an actor-owned ring buffer.
2. The browser applies an event only when its `(streamId, sequence)` is newer
   than the last applied cursor. Replayed delivery is therefore harmless.
3. Native `EventSource` reconnects and supplies `Last-Event-ID`. The server
   emits `retry: 1000` and a comment heartbeat every 10 seconds.
4. When the cursor is present in the same stream, the server replays
   `cursor + 1 ... head` and then switches atomically to live delivery.
5. When the cursor is absent, expired, or belongs to an old stream, the server
   emits `stream.reset`. The client requests `/v1/snapshot`, replaces state at
   its watermark, and then resumes events newer than that watermark.
6. The UI distinguishes `connected`, `reconnecting`, `replaying`, and
   `caught up`. It never equates a green TCP connection with complete data.

Recommended initial buffer: the larger of 10,000 events or two hours. Partial
transcript events may be coalesced in the buffer, but final/revised transcript,
suggestion, command-result, and usage events must not be dropped.

This protects against a companion connection loss. Separately, every interview
is incrementally written as a plain JSON file under
`~/Library/Application Support/com.newtypekk.punderclass/InterviewSessions/`.
The archive upserts finalized and revised transcript turns and appends every
accepted bridge and every published suggestion, including partial cues later
replaced by a final cue. It stores session metadata and assistant structure but
no audio, reference corpus, API key, or raw model prompt. Meeting sessions and
in-flight partial transcript fragments remain memory-only. The interview
transcript header can reveal the latest archive in Finder.

## Failure behavior

| Failure | Required behavior |
| --- | --- |
| Client Wi-Fi loss / sleep | Producer continues; client reconnects and replays |
| Browser reload | Snapshot, then stream from snapshot watermark |
| Duplicate event | Client ignores by sequence |
| Command response lost | Client retries same idempotency key |
| Replay window exceeded | Atomic snapshot, then live events |
| Producer restarts | New `streamId`; client performs a full snapshot |
| No heartbeat for 15 s | UI shows reconnecting; do not discard visible help |
| Assistant model fails | Transcript continues; emit a dismissible error card |
| Interview cue exceeds 6 s | Suppress it as stale; keep any early bridge visible |
| Client is slow | Coalesce partials; disconnect and force snapshot before unbounded buffering |

## Security and pairing

LAN availability is visible in the Mac UI rather than being a silent bind. The
gateway accepts `localhost` and direct numeric IP authorities, but rejects named
HTTP authorities so DNS rebinding cannot turn another origin into a reader of
local transcript state. Manual LAN access is currently unauthenticated plain
HTTP and must be used only on a trusted network.

For hardened LAN mode:

1. The user explicitly enables Companion Access in the Mac app.
2. The app advertises a Bonjour service and shows a short-lived six-digit code
   plus a manual URL/QR code.
3. Successful pairing exchanges the code for a random 256-bit client token;
   the code expires after two minutes and attempts are rate-limited.
4. The session token is held in an `HttpOnly`, `SameSite=Strict` cookie. All
   non-GET commands also require a CSRF token.
5. Pairings are visible and revocable in the Mac app. Stopping Companion Access
   closes streams and stops advertising immediately.

Pairing over plain HTTP prevents accidental access but not eavesdropping on an
untrusted Wi-Fi network. A LAN product must add transport encryption before it
ships. The least surprising choices are either a packaged cross-platform client
with certificate pinning/TOFU or a trusted HTTPS certificate provisioned during
device setup. A self-signed certificate that every browser warns about is not a
good product flow.

Only transcript text, complete answer-outline cards, citation metadata, health,
reference status, and aggregate usage cross the companion boundary. Source
documents, retrieval indexes, raw audio, prompts, and provider API keys do not.

## Reference folder and prompt assembly

The folder is a host-side feature. The user selects one directory in the Swift
app; PermanentUnderclass stores its path for the current non-sandboxed prototype,
rescans it at launch, and watches recursively with FSEvents. File bursts are
debounced into one scan. A failed scan does not discard the previous good
snapshot.

The first implementation reads PDF, RTF, Markdown, and common UTF-8 text or
structured-text files. Files are ordered by relative path, line endings are
normalized, limits and truncation are explicit, and a SHA-256 revision is based
on path, type, and normalized content—not timestamps. Touching a file without
changing its contents therefore does not create a new prompt prefix. A future
sandboxed build must persist a security-scoped bookmark rather than a raw path.

The native UI exposes this through a single prominent preparation flow rather
than a small disclosure at the bottom of each capture tab. The window separates
three concepts: purpose-specific Session Guidance, shared speech-recognition
hints, and the shared Reference Library. Opening it from Meeting or Interview
selects that purpose automatically, while a large segmented control permits an
explicit switch. This keeps all pre-session setup reachable without implying
that a short meeting brief and a durable document corpus are the same data.

For a reasonably small reference folder, build model input in this order:

```text
1. Behavior instructions + structured output schema        stable
2. Reference-data safety policy                            stable
3. Deterministically ordered reference pack + revision     stable until edit
4. Recent finalized transcript                             changes often
5. Current partial / immediate request                     changes constantly
```

The provider adapters preserve the same durable-prefix/volatile-suffix split.
OpenAI prompt-cache hits require exact prefix matches, while the Gemini request
places the durable portion in `system_instruction` and the current turn in
`input`. The whole reference pack can be reused until its content revision
changes. Do not insert a timestamp, scan time, or changing relevance score into
the stable prefix.

For the proposed GPT-5.6 integration, ordering is necessary but not sufficient:

- put the stable prefix in its own content block and add an explicit
  `prompt_cache_breakpoint` at its end;
- reuse a stable `prompt_cache_key` derived from that exact behavior/reference
  revision;
- put transcript state in later blocks and use
  `prompt_cache_options.mode: explicit` so the changing suffix is not written;
- log `cached_tokens` and `cache_write_tokens` with each assistant generation.

Keep a single cache key near or below 15 requests per minute. That is a useful
initial upper bound for the answer-outline cadence; a higher measured cadence needs
a stable key-partitioning strategy and cache-hit evaluation.

GPT-5.6 caching has a strict 1,024-token minimum, and cache writes are billed at
1.25 times the uncached input-token rate. Caching is therefore a measured
amortization strategy, not “free context”: it pays off when enough generations
reuse a reference revision. See the official guide for
[requirements](https://developers.openai.com/api/docs/guides/prompt-caching#requirements)
and [GPT-5.6 breakpoint behavior](https://developers.openai.com/api/docs/guides/prompt-caching#caching-behavior-changes-when-migrating-to-gpt-56).

If the folder grows beyond the live model's latency or context budget, retain a
stable catalog or summary in the prefix and append semantically retrieved
excerpts after that prefix. Retrieval or relevance classification remains
model/embedding based with structured outputs; it is not a keyword or regex
gate. Reference content is treated as untrusted data so instructions embedded
in a document cannot override the assistant behavior.

Reference files stay off the display device. If the configured assistant uses
a cloud model, the host necessarily sends the prompt's selected reference text
to that model provider; the product must state that separately from the display
privacy boundary. When hosted web search is selected, OpenAI or Gemini derives
and runs the public query inside the same model request. No additional search
credential is stored by PermanentUnderclass. The privacy lock disables the
assistant request and therefore disables hosted search as well.

## Assistant behavior boundary

Behaviors are model-backed structured configurations, not keyword triggers.
When cloud enhancements are available, the user selects the behavior boundary
explicitly: Meeting capture enables Meeting Assistant, while Interview capture
enables Answer Mirror. Without the selected assistant provider's key, the same
selections produce only the local transcript. Meeting Assistant handles clear
questions, requests, and decisions from the other participant using project-safe
grounding rules; Answer Mirror handles interviewer questions using interview-safe
grounding rules. The host never tries to infer one behavior from the transcript's
words.
Each behavior defines:

- goal and audience;
- allowed source collection;
- structured outline schema;
- cadence and latency budget;
- minimum confidence for showing an outline;
- expiry/replacement policy;
- a model choice and per-session spend ceiling.

The host passes the stable reference prefix, recent finalized turns, the current
partial, and an explicit other-speaker response target to the selected assistant
model and requires structured output. Meeting Assistant also exposes that
provider's hosted web search with automatic tool choice. Ordinary Answer Mirror
requests explicitly disable and omit hosted search. The visible Interview
**Test Web Search** harness runs one audible, time-sensitive question with search
required so the end-to-end tool and citation path can be verified on demand.
It converts the model result into three
to five concise, first-person speaking cues in plain, conversational language
before publishing it. Each cue stands on its own because the teleprompter hides
the internal labels. It should cancel or
supersede stale generations when a newer other-speaker moment arrives. No regex
or keyword gate decides whether the moment needs a response; the selected
behavior's model makes that structured decision.

### Measured model selection

The user can select either Priority `gpt-5.6-luna` at
`reasoning.effort: none` through OpenAI's Responses API or
`gemini-3.7-flash` at `thinking_level: medium` through Google's Interactions
API. Both adapters feed the same structured schema,
grounding validator, retry policy, and display model. OpenAI remains the stored
default for existing installs; selecting Gemini changes only the substantive
full-cue provider. The speculative early bridge still requires OpenAI and Luna.

Gemini 3.7 Flash is a stable model with configurable thinking levels, and the
Interactions API is Google's recommended agentic interface. See Google's
[Gemini 3.7 Flash model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.7-flash)
and [Interactions API overview](https://ai.google.dev/gemini-api/docs/interactions-overview).
Cross-vendor headline ratios are not used as product latency measurements. The
repository includes both a non-personal, same-fixture provider matrix and an
external-fixture benchmark that records structured quality, generation latency,
timeouts, incomplete responses, and grounding retries without committing
personal interview material.

On August 26, 2026, the public matrix used five synthetic interview cases, the
same reference snapshot, product prompt, structured schema, 4,096-token cap,
and disabled web search. Each confirmed contender received 15 candidate calls
across the broad and focused runs; 12 substantive answers per contender were
scored by the same 13-dimension judge. `Acceptable` requires the structural case
expectation and, for substantive answers, at least 4/5 on every judge dimension.
The timings include generation after request start and use the service setting
shown, so this is a deployed-configuration comparison rather than a
price-normalized service-tier comparison.

| Configuration | Calls | Mean | p95 | Maximum | Mean quality | Acceptable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Luna, no reasoning, Priority | 15 | 2.13 s | 2.80 s | 3.01 s | 4.72/5 | 14/15 |
| Luna, low reasoning, Priority | 15 | 2.62 s | 3.68 s | 3.73 s | 4.71/5 | 14/15 |
| Terra, medium reasoning, Priority | 15 | 2.91 s | 4.50 s | 4.81 s | 4.76/5 | 14/15 |
| Gemini 3.7 Flash, medium thinking | 15 | 4.01 s | 6.05 s | 7.56 s | 4.63/5 | 11/15 |

All 60 confirmed candidate requests succeeded and matched their structural
expectation without a grounding repair. A one-repetition sweep also measured
Gemini Low at 4.47 seconds mean and 7.07 seconds maximum, and Gemini High at
6.79 seconds mean and 11.53 seconds maximum. Medium is therefore the practical
Gemini setting for this workload, but Luna without reasoning is the measured
latency/quality sweet spot and remains the default. The suite is intentionally
small and synthetic, so it should be rerun after material prompt, model, or
provider changes rather than treated as a universal model ranking.

An August 2026 model-routing run used two plausible-rehearsal performance
questions. Terra/low averaged 4.43/5 quality at roughly 3.54 seconds; Luna/low
averaged 4.36/5 at roughly 3.27 seconds. Luna/xhigh took 8.35–10.58 seconds on
its two successful cells and failed two others, once by timeout and once by
exhausting a 1,200-token response budget.

A later substance-focused run strengthened both the prompt contract and judge
around before-to-after mechanics and discriminating verification. On three
private rendering fixtures, including a profiling follow-up, Terra/low passed
3/3 with 4.48/5 mean quality, 4.58 seconds median generation, and 4.71 seconds
maximum generation. Its then-nine-dimension rubric was stricter than the earlier
seven-dimension run, so the scores are not directly comparable. The current
rubric adds plain spoken language and answer-mode usefulness for eleven scores
in total. Both are small internal
samples, not a universal model ranking.

The experimental early lane has its own public, non-personal hosted eval. Before
the lane changed from a structural answer opening to a non-substantive thinking
phrase, two consecutive August 2026 runs over the same three partials withheld
a bridge for both unfinished-fragment trials and returned openings in all four
complete-request trials. Those runs remain a latency baseline, not a validation
of the current wording contract. Priority Luna/no reasoning measured
0.95–1.77 seconds across the six calls, with a 1.35 second overall median. A
later pre-redesign run covering forming, paused, and finalized speech returned the
expected decision in all three cases at 1.684, 1.250, and 1.424 seconds, for a
1.424 second median. The same small request measured roughly 4.5–5.5 seconds on
the default service tier, so Priority processing is part of the prototype's
latency contract rather than a cosmetic setting. These numbers measure model
generation after request start; the speculative collection window or 400 ms
pause occurs before it.

## Usage and cost

OpenAI transcription completion events include a `usage` object. Prefer its
reported audio duration when present; fall back to PCM duration actually sent
and label the result as estimated. Aggregate by model and emit only cumulative
totals to the client.

The initial meter covers:

- `gpt-live-transcribe` for each live audio track when cloud enhancements are
  enabled; local-only capture uses on-device turn buffering instead;
- `gpt-transcribe` for the optional final pass and cloud Quick Dictation;
- Local Parakeet as `$0.00 API`;
- `gpt-5.6-luna` scenario generation, experimental Priority early-bridge calls,
  and selected-provider full-assistant calls (`gpt-5.6-luna` or
  `gemini-3.7-flash`), from each model response's own token usage (tracked
  separately until a dollar rate is configured).

For assistant calls, record uncached input, cached input, output, and reasoning
tokens separately; OpenAI additionally reports cache writes. The Gemini adapter
maps `total_cached_tokens` and `total_thought_tokens` into the same internal
usage fields. This makes cache behavior and reasoning overhead visible instead
of hiding them inside the session total. Hosted web-search tool-call fees are
not part of the current dollar estimate until a dated search-price configuration
and a persisted search-call counter are added.

Price tables must carry an `effectiveAt` date and remain a replaceable
configuration. The UI always says "estimate" and treats the provider invoice as
the source of truth.

## Delivery slices

1. **Completed foundation:** interactive thin-display mock, transport decision,
   host-side reference-folder ingestion/watch, deterministic prompt prefix
   builder, and host-side transcription cost meter.
2. **Completed loopback vertical slice:** Hummingbird service, event hub,
   snapshot, real transcript/reference/usage events, structured Meeting
   Assistant and Answer Mirror behaviors, idempotent commands, and
   reconnect/replay tests.
3. **Completed synthetic latency slice:** a structured model generates five
   grounded exchanges for either a working meeting or an interview from the
   indexed document revision. Interview replays include two deep CUDA questions
   when the references support that subject. Separate versioned local caches
   keep reruns stable, two audible macOS voices replay the ten turns, and the
   purpose-specific live assistant is shown beside the generated response with
   visible end-to-end timings.
4. **Reliability:** durable replay across host restarts, app-sleep tests, fault
   injection, and an optional SQLite journal decision. The loopback slice
   already bounds replay and disconnects slow consumers so they recover from a
   fresh snapshot.
5. **Manual LAN address completed; hardening remains:** the app publishes the
   selected LAN IP and port and falls back automatically when the preferred
   port is occupied. Remaining work is an explicit sharing toggle, Bonjour,
   pairing/revocation, transport encryption, and mobile/tablet validation.

## Acceptance tests for the loopback slice

- Drop the SSE connection for 30 seconds while both speakers produce turns;
  after reconnect the client shows every final turn once and reports caught up.
- Reload during an assistant generation; the snapshot and subsequent event
  preserve the newest four outlines in order without duplicates.
- Force the cursor outside the ring; the client replaces state from a snapshot
  without mixing old and new stream IDs.
- Repeat a pin/dismiss command after timing out; it is applied once.
- Stop all clients; capture and transcript finalization continue unaffected.
- Switch finalization to Parakeet with cloud enhancements active; the
  cloud-finalization cost stops increasing while live-transcription cost
  continues. Repeat without a key and verify both costs remain unchanged.
- Run each document-grounded generated replay; every question partial can start
  its purpose-specific assistant before the simulated final boundary, generated
  response turns leave the outline stack intact, the unchanged final does not
  create a duplicate generation, and the display reports model and
  transcript-to-card milliseconds.
- Run **Test Web Search** from Interview; the companion opens, the question is
  audible, the assistant visibly enters its working state, and the completed
  cue is labeled as public-web grounding with at least one clickable source.
