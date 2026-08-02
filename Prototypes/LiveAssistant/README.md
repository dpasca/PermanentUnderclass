# Live Assistant interactive prototype

The native PUnderclass app serves these assets at <http://127.0.0.1:4173> and
connects them to its snapshot/SSE/command protocol. For a UI-only standalone
preview, run from the repository root:

```sh
./scripts/run-companion-prototype.sh
```

The standalone server automatically falls back to mock data and makes no model
request. The page labels that state prominently so simulated answers cannot be
mistaken for live inference.

This is deliberately a thin display. The behavior and reference-folder status
are read-only projections from the Mac host. The Mac ingests documents, calls
the assistant model, and sends complete cards and
citation metadata; source files, prompts, audio, and credentials do not cross
into the display client.

Useful interactions:

- **Next mock answer** appears only in standalone mode and cycles six sample
  comparisons, including two CUDA performance-debugging questions.
- **Test reconnect** closes the real SSE stream in live mode and resumes from
  its composite cursor; in standalone mode it runs a visual simulation.
- The connection chip shows stream health and protocol details.
- The session estimate opens a cost breakdown.
- Answer outlines can be paused, pinned, copied, or dismissed. The newest card
  stays on top, with up to three previous cards below it; host snapshots retain
  that history across reloads and reconnects.
- The inference panel distinguishes preview-only, blocked, paused, armed,
  working, checked-without-answer, ready, and failed states.
- An `Other` interviewer pause or final turn is eligible for the host model's
  structured outline decision. Each outline contains three to five labeled,
  conversational beats rather than polished corporate phrasing. `You` turns
  remain visible for comparison and do not
  replace it. The browser itself never decides via text matching.
- File-backed outlines show their citations. Approach-oriented outlines based on
  the live discussion and general model knowledge remain available when local
  files do not support the topic, with a **NO LOCAL SUPPORTING MATERIAL** prefix.

The transport and recovery decision is documented in
[`Docs/live-assistant-architecture.md`](../../Docs/live-assistant-architecture.md).
