# Live Assistant interactive prototype

The native PermanentUnderclass app serves these assets at <http://127.0.0.1:4173> and
connects them to its snapshot/SSE/command protocol. For a UI-only standalone
preview, run from the repository root:

```sh
./scripts/run-companion-prototype.sh
```

The standalone server automatically falls back to mock data and makes no model
request. The page labels that state prominently so simulated answers cannot be
mistaken for live inference.

This is deliberately a thin display. Both Meeting Assistant and Interview's
Answer Mirror use the teleprompter-style display: the Mac ingests documents,
selects the explicit mode-specific behavior, calls the assistant model, and
sends presentation-ready suggestion data. The opt-in Instant Text experiment
may send a replaceable, prominently unverified draft while OpenAI text is still
streaming;
source files, prompts, audio, and credentials do not cross into the display
client. The display reduces that data to a connection light and a stack of
conversation rounds. The current question and its first-person cues stay large
at the top, with a stable topic number and an elapsed timer based on when that
topic first produced a cue. Up to three earlier cues remain immediately below
at a smaller, quieter scale. When a finalized transcript revises the same
question, each pause-time point appears inline beneath its newer counterpart;
earlier questions from the back-and-forth remain in the separate history
stack. Each new suggestion resets the teleprompter to the new current cue, even
if the previous cue had been scrolled.

Useful interactions:

- **Preview web result** appears only in standalone mode and jumps to a
  simulated web-grounded cue with a clickable public source. It makes no API
  call. **Next example** cycles all sample cues.
- The corner light is green only for a live host connection and red when the
  display is disconnected or reconnecting. Clicking it reveals transport
  diagnostics and the reconnect test.
- The host still retains suggestion history, citations, inference state, and
  usage diagnostics. The focused display uses history to keep earlier rounds
  readable below the active cue without bringing back answer cards or metadata.
- An `Other` pause or final turn is eligible for the host model's structured
  outline decision. Meeting mode asks for a cautious, grounded response to a
  question, request, or decision; Interview mode asks for an answer outline.
  Each Interview result contains a concise spoken preamble followed by two or
  three first-person cues that can be read aloud without visible labels or a
  context card. Meeting results retain three to five direct response cues. `You`
  turns do not replace the current result. The browser itself never decides via
  text matching.
- In grounded interviews, **Instant text stream (experimental)** can replace
  a slow verified partial with a finalized-turn plain-text hedge. Both requests
  remain live until one completes a cue, then the loser is cancelled. Instant
  Text uses no JSON schema and displays words after the model's `SHOW` control
  line. The draft is marked `LIVE TEXT DRAFT · VERIFY`; every unsupported
  context falls back to the structured path automatically.
- Approach-oriented cues remain available when local files do not support the
  topic, but they use hypothetical phrasing such as "I would…" rather than
  inventing personal history.

For an end-to-end hosted-search check, open the native app's Interview tab and
press **Test Web Search** in the generated replay panel. The app opens Answer
Mirror, speaks one time-sensitive CUDA question, and requires the Responses API
to run web search for that explicit test. A successful result is labeled as
public-web grounding and exposes clickable source links. Normal meeting and
interview traffic continues to use automatic tool choice.

The transport and recovery decision is documented in
[`Docs/live-assistant-architecture.md`](../../Docs/live-assistant-architecture.md).
