# Live Assistant companion architecture

Status: loopback vertical slice implemented
Decision date: 2026-08-01

## Decision

Keep PUnderclass as the host, assistant brain, and sole source of truth. The
Swift process owns local reference ingestion, transcript state, assistant model
calls, prompt construction, credentials, usage accounting, and recovery. Add a
small HTTP service inside that process and serve a thin browser display from
the same origin. The display renders presentation-ready state; it does not
index documents, retrieve context, assemble prompts, or call a model.

Stream ordered JSON events from host to display with Server-Sent Events (SSE);
send the small number of presentation actions back as idempotent JSON HTTP
requests.

The implemented gateway binds to `127.0.0.1` only. This lets us prove
the assistant behavior, event contract, recovery, and cost reporting without
turning a prototype into an unauthenticated LAN service. The protocol and web
client are cross-platform. LAN access is a separate hardening milestone (see
Security and pairing).

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
Microphone ────────┼─> PUnderclass macOS host
Reference folder ─┘      ├─ capture + transcription
                         ├─ local document ingestion + change monitoring
                         ├─ prompt assembly + assistant model calls
                         ├─ ordered event hub + replay buffer
                         ├─ OpenAI usage/cost aggregation
                         └─ HTTP/SSE companion gateway
                                     │ presentation-ready events only
                                     └─> Thin browser display
                                          render + small UI commands
```

The OpenAI key stays in the Mac Keychain. The browser never receives it, never
receives the reference corpus, and does not call OpenAI directly. The host
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
  or `interview` purpose, and active host behavior.
- `transcript.partial`: replace the partial for one `turnId`; safe to coalesce.
- `transcript.final`: append or replace the finalized `turnId`.
- `transcript.revised`: replace text after the final transcription pass.
- `assistant.working`: generation started for a transcript watermark.
- `assistant.suggestion`: newest structured answer outline with citation labels.
- `assistant.state`: idle state after a completed model check, including whether
  the latest interviewer moment produced no outline. This prevents silence from
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
  "question": "Tell me about a time you improved a critical system.",
  "beats": [
    {"label": "Context", "point": "I inherited a checkout path whose latency was hurting conversion."},
    {"label": "My move", "point": "I traced the slow path and removed a repeated lookup."},
    {"label": "Proof", "point": "I validated a 41% lower p95 under load."}
  ],
  "citations": [{"label": "Checkout latency", "path": "Projects/Checkout.md"}],
  "grounding": "localReferences",
  "confidence": "high",
  "generationMilliseconds": 640,
  "trigger": "partialTranscript",
  "totalLatencyMilliseconds": 1440
}
```

The host chooses the facts and concise first-person wording. Labels are internal
structure; the teleprompter displays only the self-contained speaking cues.
`assistant.suggestionHistory`
in the atomic snapshot retains the newest four outlines in newest-first order.
The focused display uses that history as a typographic round stack: the current
question and cues are primary, while up to three distinct earlier questions and
their cues remain below at a smaller scale. It may also copy, pin, or dismiss
these objects, but it does not
receive retrieved chunks and does not run a second interpretation step.

An 800 ms audio pause from `Other` schedules a structured shorthand outline
from the current interviewer partial before the 3 second final-turn boundary.
A finalized `Other` turn schedules immediately as the reliable fallback. `You`
turns remain visible in the transcript for comparison but do not schedule or
replace the model outline. Exact partial/final duplicates for one interviewer
turn are coalesced. This is structural speaker routing, not a language
heuristic; there is no keyword or pattern gate in front of the model. A
completed decision that returns no outline leaves the previous suggestion intact and
is retained as assistant state so
the display can distinguish "question checked, not clear enough" from "no
inference happened."

The structured decision labels every displayed outline as either
`localReferences` or `generalKnowledge`. Local grounding requires at least one
validated citation path from the current indexed snapshot. If no indexed file
supports a useful outline, the model may use the live discussion as context and
general model knowledge with an empty citation list. Those cues use hypothetical
first-person language (for example, "I would…") rather than invented past
experience. A grounding warning remains in copied diagnostic output.

The host also writes privacy-safe lifecycle markers under the
`com.permanentunderclass.meetingcopilot` subsystem and `LiveAssistant` category.
They record scheduling, starts, skips, completion outcome, cancellation,
trigger kind, trigger-to-start time, model time, and transcript-to-result time
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

This protects against a companion connection loss. It does not protect against
the PUnderclass process crashing because transcripts are currently in memory.
If crash recovery is in scope, journal the same envelopes to local SQLite in
WAL mode before publishing them, expose retention controls, and update the
product's current in-memory-only privacy promise.

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
| Client is slow | Coalesce partials; disconnect and force snapshot before unbounded buffering |

## Security and pairing

Loopback is the safe default for the spike. Do not bind `0.0.0.0` silently.
The loopback gateway also rejects non-loopback HTTP authorities so DNS
rebinding cannot turn another origin into a reader of local transcript state.

For LAN mode:

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
documents, retrieval indexes, raw audio, prompts, model credentials, and the
OpenAI key do not.

## Reference folder and prompt assembly

The folder is a host-side feature. The user selects one directory in the Swift
app; PUnderclass stores its path for the current non-sandboxed prototype,
rescans it at launch, and watches recursively with FSEvents. File bursts are
debounced into one scan. A failed scan does not discard the previous good
snapshot.

The first implementation reads PDF, RTF, Markdown, and common UTF-8 text or
structured-text files. Files are ordered by relative path, line endings are
normalized, limits and truncation are explicit, and a SHA-256 revision is based
on path, type, and normalized content—not timestamps. Touching a file without
changing its contents therefore does not create a new prompt prefix. A future
sandboxed build must persist a security-scoped bookmark rather than a raw path.

For a reasonably small reference folder, build model input in this order:

```text
1. Behavior instructions + structured output schema        stable
2. Reference-data safety policy                            stable
3. Deterministically ordered reference pack + revision     stable until edit
4. Recent finalized transcript                             changes often
5. Current partial / immediate request                     changes constantly
```

OpenAI prompt-cache hits require exact prefix matches, so durable material goes
first and volatile transcript state goes last. The whole reference pack can be
reused until its content revision changes. Do not insert a timestamp, scan
time, or changing relevance score into the stable prefix.

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
privacy boundary.

## Assistant behavior boundary

Behaviors are model-backed structured configurations, not keyword triggers.
The user selects the behavior boundary explicitly: Meeting capture is
transcript-only, while Interview capture enables Answer Mirror. The host never
tries to infer that a meeting is an interview from its words.
Each behavior defines:

- goal and audience;
- allowed source collection;
- structured outline schema;
- cadence and latency budget;
- minimum confidence for showing an outline;
- expiry/replacement policy;
- a model choice and per-session spend ceiling.

The host passes the cached stable reference prefix, recent finalized turns,
the current partial, and an explicit interviewer response target to a fast
model and requires structured output. It converts the model result into three
to five concise, first-person speaking cues in plain, conversational language
before publishing it. Each cue stands on its own because the teleprompter hides
the internal labels. It should cancel or
supersede stale generations when a newer interviewer moment arrives. No regex
or keyword gate should decide whether the meeting "looks like" an interview.

### Initial model hypothesis

Start the measured prototype with `gpt-5.6-luna` through the Responses API. It
is the efficient, high-volume member of the current GPT-5.6 family and fits the
frequent short-generation shape better than using the flagship model for every
transcript change. The latency harness currently uses `reasoning.effort: none`
and a 350-token output ceiling with the compact outline schema. Compare that
configuration against `low` on the same cached interview moments before trading
latency for more reasoning.

Treat this as an eval hypothesis, not a permanent routing rule. Measure
time-to-first-useful-card, grounded-fact accuracy, stale-card rate, output
tokens, and cost. If Luna misses the quality bar, test `gpt-5.6-terra` at the
same effort before increasing reasoning. A user-requested “deeper answer” can
use that slower tier without putting it on the live critical path.

## Usage and cost

OpenAI transcription completion events include a `usage` object. Prefer its
reported audio duration when present; fall back to PCM duration actually sent
and label the result as estimated. Aggregate by model and emit only cumulative
totals to the client.

The initial meter covers:

- `gpt-live-transcribe` for each live audio track;
- `gpt-transcribe` for the optional final pass and cloud Quick Dictation;
- Local Parakeet as `$0.00 API`;
- `gpt-5.6-luna` scenario-generation and Answer Mirror calls from each model
  response's own token usage (tracked separately until a dollar rate is
  configured).

For GPT-5.6 assistant calls, record uncached input, cached input, cache writes,
output, and reasoning tokens separately. This makes a folder edit's one-time
cache-write cost visible instead of hiding it inside the session total.

Price tables must carry an `effectiveAt` date and remain a replaceable
configuration. The UI always says "estimate" and treats the provider invoice as
the source of truth.

## Delivery slices

1. **Completed foundation:** interactive thin-display mock, transport decision,
   host-side reference-folder ingestion/watch, deterministic prompt prefix
   builder, and host-side transcription cost meter.
2. **Completed loopback vertical slice:** Hummingbird service, event hub,
   snapshot, real transcript/reference/usage events, structured Answer Mirror
   behavior, idempotent commands, and reconnect/replay tests.
3. **Completed synthetic latency slice:** a structured model generates five
   grounded exchanges from the indexed document revision, with two deep CUDA
   questions when the references support that subject. A versioned local cache
   keeps reruns stable, two audible macOS voices replay the ten turns, and independent
   Answer Mirror output is shown beside the generated candidate response with
   visible end-to-end timings.
4. **Reliability:** durable replay across host restarts, app-sleep tests, fault
   injection, and an optional SQLite journal decision. The loopback slice
   already bounds replay and disconnects slow consumers so they recover from a
   fresh snapshot.
5. **LAN:** explicit sharing toggle, Bonjour, pairing/revocation, transport
   encryption, and mobile/tablet validation.

## Acceptance tests for the loopback slice

- Drop the SSE connection for 30 seconds while both speakers produce turns;
  after reconnect the client shows every final turn once and reports caught up.
- Reload during an assistant generation; the snapshot and subsequent event
  preserve the newest four outlines in order without duplicates.
- Force the cursor outside the ring; the client replaces state from a snapshot
  without mixing old and new stream IDs.
- Repeat a pin/dismiss command after timing out; it is applied once.
- Stop all clients; capture and transcript finalization continue unaffected.
- Switch finalization to Parakeet; the cloud-finalization cost stops increasing
  while live-transcription cost continues.
- Run the document-grounded synthetic interview; each interviewer partial can
  start inference before its simulated final boundary, candidate turns leave
  the outline stack intact, the unchanged final does not create a duplicate
  generation, and the display reports model and transcript-to-card milliseconds.
