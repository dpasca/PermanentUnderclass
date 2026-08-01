# Live Assistant interactive prototype

Run from the repository root:

```sh
./scripts/run-companion-prototype.sh
```

Then open <http://127.0.0.1:4173>. The prototype uses local mock data and makes
no network or model requests.

This is deliberately a thin display. The behavior and reference-folder status
are read-only projections from the Mac host. In the real transport, the Mac
ingests documents, calls the assistant model, and sends complete cards and
citation metadata; source files, prompts, audio, and credentials do not cross
into the display client.

Useful interactions:

- **Next mock moment** cycles through three kinds of live guidance.
- **Test reconnect** demonstrates the intended resume-and-replay contract.
- The connection chip shows stream health and protocol details.
- The session estimate opens a cost breakdown.
- Suggestions can be paused, pinned, copied, or shortened.

The transport and recovery decision is documented in
[`Docs/live-assistant-architecture.md`](../../Docs/live-assistant-architecture.md).
