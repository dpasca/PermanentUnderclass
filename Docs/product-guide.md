# PermanentUnderclass: detailed guide

The Swift package, executable, source directory, stored preference keys, and
bundle identifier retain the shorter `PUnderclass` technical names for
compatibility. The user-facing app and bundle use `PermanentUnderclass`.

A minimal native macOS proof of concept that captures two independent audio
tracks and transcribes them in real time:

- **You** — the Mac's default microphone.
- **Other** — all system audio by default, or one selected call application.

Speaker labels come from the separate audio routes rather than diarization
guesses. With no OpenAI key, on-device voice activity detection buffers each
track and sends completed turns directly to local Whisper (the default) or
Parakeet. With a key, each track also uses an OpenAI Realtime transcription
session for word-by-word partial text and assistant timing. Both local engines
run directly inside PermanentUnderclass and do not use another application's
process, settings, microphone handling, or database.

## Requirements

- macOS 14.2 or newer.
- Apple Silicon when using either local finalizer.
- Xcode command-line tools.
- Wired or USB headphones during the proof of concept.
- API keys are optional. OpenAI is required for `gpt-live-transcribe`, OpenAI
  assistant generation, generated replay scenarios, source preparation, and
  the optional `gpt-transcribe` finalizer. A Gemini key can instead power
  Meeting Assistant and Answer Mirror—not local two-track transcripts. A
  generated replay needs OpenAI for its scenario and the selected provider for
  its live response cues.

## Run

```sh
./scripts/run-app.sh
```

On first use, macOS asks for microphone and system-audio recording permission.
If either permission was previously denied, enable **PermanentUnderclass** under
System Settings → Privacy & Security → Microphone and Screen & System Audio
Recording, then relaunch the app.

The build script uses an installed **Developer ID Application** certificate by
default so the app has a stable designated code requirement across rebuilds.
macOS associates privacy consent with that requirement. The first
certificate-signed build may ask once more because it intentionally replaces
the earlier ad-hoc identity; subsequent rebuilds retain the same identity.
Notarization is needed for distributing a downloaded app through Gatekeeper,
not for retaining local privacy consent. Override the selected certificate with
`PUNDERCLASS_SIGNING_IDENTITY`; without a Developer ID certificate the
script falls back to ad-hoc signing and warns that consent may not persist.

Start a meeting or interview immediately for a local transcript. Both capture
modes use all system audio by default. To limit capture to one app, choose it
from **Audio to transcribe**; it may appear under a helper-process name. To add
live partial words, save an OpenAI key. To add Meeting Assistant or Answer
Mirror, open **API Keys**, choose OpenAI or Google Gemini as the live suggestion
provider, save that provider's key, and start capture.

## Live Assistant companion

PermanentUnderclass embeds an HTTP/SSE gateway and serves the cross-platform
thin display itself. Start the Mac app, open **Meeting** or
**Interview**, choose **Open Setup…** on the prominent preparation card, and
add the session guidance or shared reference folder you need. Then open the
mode's assistant. Its status dot confirms when the display is ready. The
details menu shows the exact LAN IP and selected port and copies that address
for use on another computer on the same Wi-Fi or Ethernet network.
Port `4173` is preferred; if it is already in use, the gateway automatically
publishes another available port. The Mac owns the selected
behavior, local references, provider request, usage tracking, event ordering, and
replay; the browser receives only transcript text, reference status, citations,
and a presentation-ready response outline.

The current manual LAN-address mode uses plain HTTP without pairing. Use it only
on a trusted local network. The gateway accepts direct numeric IP authorities
and rejects named authorities to retain DNS-rebinding protection.

There are two explicit live behaviors. **Meeting Assistant** drafts a concise,
first-person response outline when the other participant asks a clear question,
makes a request, or raises a decision. It prefers local project facts and marks
unsupported factual answers for verification rather than inventing commitments,
metrics, deadlines, or status. **Answer Mirror** defaults to a grounded
interview answer outline. Its explicitly confirmed **Plausible Rehearsal** mode
may attach a draft to a relevant project and extrapolate a
modest incident. Before writing, it maps that incident to one project, an
observed signal, a before-to-after mechanism change, a discriminating check,
and a bounded outcome. Those fields form one causal mini-story across the
preamble and all three beats rather than three unrelated examples. The most
recent assistant-created story is sent to the next full request as continuity
context; the model decides in that same call whether a new question is a
follow-up. A follow-up therefore preserves the project and causal details even
when the candidate did not say the prior cue aloud, while an unrelated question
starts a new story without another model call. Clearly different details the
candidate actually says take precedence over the retained draft. The current
question comes first, followed by concrete candidate speech, reference evidence,
the retained story, and finally broad speaking style. The preparation UI and
assistant display mark
the result as a rehearsal to verify, and the structured result carries the
material assumptions separately. Extreme financial, popularity, and
performance claims remain forbidden.

When Grounded mode lacks support for a requested past incident, it still
returns an immediately usable answer: a compact first-person conditional with
a concrete symptom, likely cause, discriminating check, justified change, and
verification. It does not lecture about source limits, invention, or what story
the candidate should choose.

Inside Plausible Rehearsal, **Early speaking bridge (experimental)** is a
separate opt-in switch. It does not wait for the 800
ms end-of-speech pause. After a short 600 ms partial-transcript collection
window, a Priority `gpt-5.6-luna` request can show one thinking phrase such
as “Let me choose the clearest example for a moment.” It asks for time without
answering, receives no résumé documents, and is forbidden from introducing a
conclusion, action, project, result, or other answer substance. The substantive
cue from the selected provider is generated independently: the bridge text is
never included in its request, and the completed cue simply replaces it. Recent
bridge wording is supplied only to Luna so repeated fillers are less likely.
An unclear fragment produces no bridge, and the host makes at most two early
attempts per interviewer turn. This option can
therefore add model calls and Priority-processing cost, and the UI labels its
output as partial and experimental. Both preferences remain enabled across
interviews and app relaunches until the user explicitly turns them off.

Both behaviors expose their selected provider's hosted web search when current
or public facts would materially improve a cue: OpenAI uses `web_search`, while
Gemini uses `google_search`. Search is model-selected rather than
keyword-triggered and needs no separate search account. A web-grounded cue is
published only when its cited URL is present in the provider's returned search
results or URL annotations, and the display makes that source visible and
clickable. For Gemini's structured-output response shape, the host additionally
requires a successful Google Search timeline step and a Google grounding
redirect; a model-authored arbitrary URL is rejected. The live display renders
Google's associated Search Suggestions widget in a script-disabled sandbox.
Those widgets and Gemini grounding links are transient and are not written to
interview session archives.

With OpenAI live transcription active, an 800 ms pause in the other speaker's
audio can trigger the selected provider from the current partial transcript
before the 3 second final-turn boundary. The OpenAI option uses
`gpt-5.6-terra` at medium reasoning through the Responses API. The Gemini
option uses `gemini-3.7-flash` at high thinking through the Interactions API.
With a Gemini key but no OpenAI key, capture and transcription remain local and
the Gemini request starts when the completed turn's local transcript is ready.
The finalized turn remains a fallback, and an exact partial/final duplicate is
coalesced rather than billed twice. The user's speech stays visible in the
transcript and its concrete details override a conflicting retained draft;
generic wording affects only the final style pass. Explicit speaker and
capture-purpose state provides this routing; there is no keyword or regex gate.
The experimental early bridge is the only pre-pause path. It is available only
when both Plausible Rehearsal and its own switch are active. A new interviewer
turn cancels work for the previous turn, while the early opener and full answer
use independent requests so the fast lane cannot reduce the full cue's quality.
The full interview cue has a six-second usefulness deadline measured from the
end of the interviewer's speech. A late first response or grounding repair is
silently withheld as stale, while an early bridge already on screen remains
available to fill the pause.
Each Answer Mirror result starts with a brief spoken preamble and follows with
two or three labeled beats rather than polished prose; Plausible Rehearsal uses
exactly three. The preamble gives the direct answer or qualifies an important
version, assumption, scope, or contrast; the beats then preserve concrete
evidence, mechanics, caveats, and checks. The wording uses ordinary vocabulary,
short clauses, contractions, and precise technical nouns only where they add
real meaning. When recent candidate speech provides a useful sample, the cue
uses only its broad sentence length and formality as a final style check. It is
explicitly told not to reuse generic framing, slogans, self-description, or a
topic merely because the candidate said it recently, and it still excludes
hesitation, errors, and filler.
Meeting Assistant retains its direct three-to-five beat response outline. This
makes it possible to compare substance without reading a script. The
newest card appears first and the host retains three previous cards in the
snapshot, preserving the stack across browser refreshes and reconnects.
Indexed local files are preferred when they support the outline. If they do
not, the model may still draft an approach-oriented outline from the live
discussion and general model knowledge without claiming unverified personal
experience. The display prefixes it with **NO LOCAL SUPPORTING MATERIAL**.
Public web results are treated as untrusted data and never as instructions.
The stable behavior/reference prefix remains separate from the volatile recent
transcript. OpenAI uses an explicit prompt-cache breakpoint and cache key;
Gemini sends the stable prefix as `system_instruction` so its implicit cache can
reuse the same leading content. Assistant input, cached input, output, and
reasoning/thought usage is counted separately; it is not folded into the dollar
estimate until provider model rates are configured. Hosted web-search tool-call
fees are also not yet folded into that estimate.

To view the same client without starting the native host, run the standalone
preview:

```sh
./scripts/run-companion-prototype.sh
```

The standalone server falls back to simulated data and makes no model request.
Press **Preview web result** there to inspect the public-source treatment
without spending anything. For the real hosted path, open the native app's
Interview tab and press **Test Web Search** in the generated replay panel. It
opens Answer Mirror, speaks one deliberately time-sensitive question, requires
one hosted search for that test run, and leaves the sourced cue on screen with
clickable links. Ordinary meeting and interview requests still let the model
decide whether searching is useful.
The live host exposes an atomic snapshot, a replayable composite SSE cursor,
and idempotent pause/pin/dismiss commands. The protocol, retry contract,
pairing boundary, and follow-up durability work are in
`Docs/live-assistant-architecture.md`.

## Generated meeting and interview replays

Both capture tabs include a generated replay. Meeting creates five realistic
working-meeting questions or requests and grounded participant responses;
Interview creates five interview question/answer exchanges and probes CUDA in
depth when the references support it, otherwise using the deepest supported
technical topic. Choose a reference folder, wait for indexing, and press **Run
Replay**. On the first run for a reference revision, the host grounds every
exchange in exact indexed paths. Two macOS voices speak the resulting ten turns
while the host streams their known words as partial transcript events. After
every question, the active Meeting Assistant or Answer Mirror independently
drafts the response outline shown beside the generated reply. The companion
reports both assistant-generation time and end-to-end `transcript → card` time.
Scenario generation requires OpenAI. Each independent assistant outline uses
the selected live-suggestion provider, so a Gemini replay needs both keys.

Meeting and interview scenarios have separate local caches in Application
Support. Each is reused while the reference revision and scenario format match,
making latency reruns repeatable without another generation call. **New
Scenario** or **New Questions** forces a fresh document-grounded replay.
Changing any indexed document naturally invalidates the matching cache.

This mode deliberately bypasses microphone capture and speech recognition. It
isolates answer cadence and model latency so the same conversation can be
compared after every prompt, model, or scheduling change. Live capture and the
existing optional network ASR tests continue to cover the audio/transcription
path separately.

For a one-command visible and audible run:

```sh
./scripts/run-app.sh --synthetic-interview
```

The built-in voices require no external account and keep repeated runs free.
An ElevenLabs clone can later replace the candidate speech renderer without
changing the deterministic transcript timeline; that requires the ElevenLabs
voice ID and an API key, and should cache generated audio so test replays do not
incur repeated synthesis calls.

## Meeting and interview preparation

Use the **Prepare Meeting** or **Prepare Interview** card in the capture
dashboard. It opens one full-size preparation window directly on the selected
mode; a large segmented control switches modes without closing it.
All setup controls live in this window instead of a collapsed control at the
bottom of the capture tab.

The window keeps related setup in one place while making the distinction
explicit:

- **Interview preparation** follows **Resume → Prepare → Ready**. The selected
  resume is explicit and authoritative. The interview description starts as
  the visible text `A job interview.`; when OpenAI is available, selecting the
  resume also requests a more specific editable draft grounded in its recent
  work. No unseen generic interview description is substituted, and an empty
  field blocks evidence preparation.
- **Session Guidance** is a short, mode-specific brief. Meeting and Interview
  retain separate text, and the selected brief guides transcription plus the
  corresponding live assistant. Interview spoken language remains a separate
  speech-recognition setting and is not inferred from the resume.
- **Reference Library** is the durable, shared document folder used for
  grounding Meeting Assistant, Answer Mirror, and both generated replays.
- **Speech Recognition Hints** contains exact terminology, expected languages,
  and the live accuracy/latency choice. These hints are shared with Quick
  Dictation and both capture modes.

The Reference Library section shows indexed documents, revision, ignored files,
and warnings with full-size controls for changing, revealing, rescanning, or
disconnecting the folder. The Swift app restores and ingests it at launch,
watches it recursively for changes, and debounces change bursts into a fresh
deterministic revision. It currently reads PDF, RTF, Markdown, plain text,
CSV/TSV, JSON/JSONL, YAML, XML, and HTML files. Unsupported files are counted;
unreadable or truncated files are reported instead of silently disappearing.

Reference contents are owned by the Mac host and are never copied to the thin
display. The prompt builder places stable behavior and reference material
before volatile transcript content and sends that exact prefix to OpenAI with
an explicit cache breakpoint. Recent transcript is appended afterward. The
browser never receives the reference corpus, assembled prompt, or API key.
When OpenAI features are available, the resume picker discloses that resume
text is sent once to draft the editable interview description; evidence
preparation later sends the configured source text.

## Quick Dictation

Enable **Quick Dictation**, then grant Accessibility and Microphone access when
prompted. Accessibility allows both global shortcut monitoring and automatic
paste. macOS may require PermanentUnderclass to be quit and reopened after this
permission changes. Hold the exact modifier-only chord **Command + Option**
while speaking and release either modifier to transcribe with the currently
selected final-pass and Quick Dictation model. Quick Dictation captures the
focused application, window, and control when recording begins, then returns
to that original target before pasting—even if another process takes focus
while recording or transcribing. Local Whisper and Local Parakeet keep
dictation audio on this Mac; GPT-Transcribe sends the captured dictation audio
to OpenAI. Pressing
another keyboard key while the chord is down cancels the recording, so normal
Command-Option shortcuts do not become dictations.

By default, Quick Dictation shows a small, non-activating preview near the
bottom of the current screen, displaying the live microphone waveform while
recording. The preview says **Starting microphone** until the first audio buffer
actually arrives. If another call or a Bluetooth profile change stops buffer
delivery, it switches to **Recovering microphone** and rebuilds capture twice.
If recovery fails, it keeps any audio already captured and shows an explicit
failure instead of silently treating the recording as empty. Audio packets that
contain only digital silence are also reported rather than shown as healthy.

With GPT-Transcribe selected, audio streams to the transcription session **while
the user speaks** rather than being uploaded after the shortcut is released. The
stream remains one transcription turn for the entire shortcut hold and is
committed only when the shortcut is released. Brief hesitations and microphone
level differences therefore cannot manufacture intermediate turn boundaries or
their associated punctuation. Streaming still keeps the release-time upload
limited to the unsent tail. If the stream breaks at any point, the complete
recording is still buffered locally and is uploaded through the original
one-shot path at release, so a broken stream costs latency rather than the
dictation.

Engines that cannot stream keep the bounded-snapshot preview loop, and any
preview still in flight is cancelled when the shortcut is released so it cannot
compete with the transcription the user is waiting for. Quick Dictation does not
use the live-capture-only `gpt-live-transcribe` model. Neither recording nor local
transcription has a duration deadline. For cloud transcription, the response
watchdog starts only after every audio byte and the commit have been sent —
for a streamed dictation, that is at release. An explicit OpenAI failure
starts Local Whisper immediately; otherwise, Local Whisper starts after 30
seconds without a response. The first successful result wins without cancelling
valid work merely because it is slow. Once Local Whisper is ready, Quick
Dictation also remains usable while the OpenAI connection is unavailable or
reconnecting.
That final transcription runs in the background, so another Quick Dictation can
start immediately. Each completed recording retains the app and field that were
focused when its capture began, even while provider work overlaps in the
background.
While recording overlaps an earlier final pass, the overlay keeps the live
waveform in its own card and shows the background transcription in a second card
above it. The app's synthesized paste event does not cancel the active recording.
The waveform uses adaptive visual gain so quiet microphones still provide clear
feedback. The pipeline's **Screen preview (optional stage)** switch directly
controls the snapshot stage and overlay. Turning it off does not disable the
required final transcription that runs when the shortcut is released.
The **Clean final dictation** switch gives GPT-Transcribe an explicit instruction
to omit hesitation fillers, abandoned starts, and immediate repetitions while
preserving meaning and technical terms. Local fallback always prefers returning
its safest transcript over failing because that optional style could not be
applied.

The system clipboard is used briefly for the paste. Quick Dictation snapshots
all of its available contents and restores them after the target consumes the
paste, whether or not the target exposes enough Accessibility information to
verify the insertion. If another application changes the clipboard during that
brief interval, Quick Dictation leaves the newer clipboard contents untouched.
Because iTerm does not expose its terminal buffer as an ordinary editable
Accessibility value, its paste cannot be checked against the value/range model
used for text fields. It is verified by visible content instead: the paste
counts as delivered if the text appears on screen, or — for a TUI that renders
a pasted-text placeholder rather than the literal text — if the visible screen
changed at all. An idle terminal's Accessibility value is byte-stable, so a
screen that did not change is real evidence that nothing arrived. Only that
case leaves the overlay on screen offering **Copy** and **Dismiss**.

If the user switched to a different application while the transcription was
finishing, Quick Dictation does **not** paste and does not pull focus back.
Instead the overlay keeps the text on screen with **Copy** and **Dismiss**
actions, so a stray transcript cannot land in the frontmost window or overwrite
the clipboard. The same applies when the original target closes or can no
longer be focused. In every one of these cases the text is also saved to
history, so nothing is lost.

While a dictation is being transcribed, the overlay reports what it is waiting
on — streamed text as it arrives, upload percentage on the fallback path, then
`Transcribing…` — so a slow provider is never indistinguishable from a hang.
Quick Dictation is paused during meeting or interview capture and during either
generated replay.

The main window's **Quick Dictation** tab owns the shortcut, permission,
preview, live microphone, and history controls. Completed text appears there in
newest-first order. Each entry can be copied back to the clipboard or deleted,
and **Erase All** clears the complete history after confirmation. This text is
stored locally in the current user's Application Support folder until it is
erased. Before a provider request begins, each completed recording is written as
a standard WAV file in Application Support. It is removed only after transcript
text is safely saved. A provider failure or app restart leaves the WAV in the
Quick Dictation **Recovery** panel, where it can be retried with the selected
provider, revealed in Finder, or explicitly deleted.

PermanentUnderclass speculatively prepares Local Whisper in the background at launch,
even when GPT-Transcribe is selected. The model pipeline and shared settings
show the current download/load phase and elapsed time. This warmup does not gate
the selected cloud transcriber, and all local callers share the same in-flight
preparation. The first run after the download—or after macOS invalidates its
Core ML cache—can spend additional time specializing the model for the Mac;
later launches reuse that cached specialization.

## Headless mode

Press the global shortcut **Control + Command + H** to enter headless
mode. PermanentUnderclass hides all of its windows, including the Quick Dictation
preview, and removes itself from both the Dock and the application switcher.
Capture, transcription, Quick Dictation, and the Live Assistant host continue
running.

Press the same shortcut again to restore the main window and Dock icon. The
shortcut is registered independently of Quick Dictation and does not require
Accessibility permission. There is deliberately no menu-bar fallback while
headless; if the shortcut becomes unavailable, quit PermanentUnderclass from Activity
Monitor and relaunch it.

Launching PermanentUnderclass again reuses the existing process instead of starting a
second copy. If that process is headless, relaunching restores its main window
and Dock icon. The development run script replaces an existing build, including
one launched from another worktree, so the requested worktree is always the one
being tested.

## Current scope

The proof of concept includes:

- Core Audio global or app-specific process-tap capture without a virtual audio
  driver. All system audio is the default source.
- Default-microphone capture.
- Live monitoring of the macOS default input, with automatic microphone
  capture restart when devices are connected, removed, reconfigured, or stop
  delivering audio buffers. Meeting and interview capture keep remote audio
  running while microphone recovery retries with capped backoff.
- 24 kHz mono PCM16 conversion and bounded 20 ms audio chunks.
- Two independent local turn buffers. When an OpenAI key is active, two
  `gpt-live-transcribe` WebSocket sessions additionally provide live partials.
- A shared window bar that names every active model by role: the fixed Meeting
  live model and the selected final-pass/Quick Dictation model. Its pipeline
  popover explains every stage, execution location, transition, and optional
  preview pass; each workflow repeats its own compact stage sequence.
- A selectable final-pass and Quick Dictation engine:
  - **Local Whisper** embeds Argmax WhisperKit and the compressed OpenAI Whisper
    Large v3 Core ML model recommended by Argmax for maximum multilingual
    accuracy. The first use downloads roughly 626 MB. Long recordings use VAD
    chunking; one expected language pins decoding while multiple expected
    languages enable automatic language detection. It preserves a verbatim
    transcript as the already-warmed emergency fallback for GPT-Transcribe.
  - **Local Parakeet** embeds FluidAudio and NVIDIA Parakeet TDT 0.6B v3 using
    Core ML. On macOS the large encoder uses the CPU to avoid a crash-prone
    asynchronous Metal tensor bridge. The first use downloads roughly 483 MB to FluidAudio's
    application-support cache. Each fresh app process warms the cached Core ML
    models and their first inference in the background so later local use does
    not pay the cold-start cost.
  - **OpenAI GPT-Transcribe** runs a persistent committed-turn
    `gpt-transcribe` session for each audio track. The two tracks finalize in
    parallel while retaining deterministic speaker labels. Each turn includes
    the declared meeting or interview context, terminology and language hints,
    plus recent
    cross-speaker transcript context.
- Client-side audio voice-activity detection with a 300 ms pre-roll, a 3
  second end-of-turn pause, and explicit turn commits. With OpenAI configured,
  partial text continues streaming during that pause. In local mode, text
  appears after the completed turn is transcribed. A **Finish My Turn** button
  supplies a manual boundary for controlled comparisons.
- Meeting Assistant and Answer Mirror check an other-speaker partial after an
  800 ms audio pause when OpenAI live transcription supplies partial text,
  immediately check a new finalized turn, and coalesce an unchanged
  partial/final pair. In Gemini-only mode, the check starts after local
  transcription returns the completed turn. The selected capture purpose
  chooses the model-backed behavior explicitly; the user's turns never replace
  the current response outline.
  Privacy-safe lifecycle logs include trigger-to-start, model, and total
  transcript-to-result timings.
- Plausible Rehearsal can optionally run a Priority Luna early bridge from the
  still-forming interviewer partial. It shows one non-substantive thinking
  phrase while the selected full-cue provider independently drafts the complete
  cue, varies against the last few accepted bridges, limits itself to two
  attempts per turn, and records separate `assistant_bridge_*` lifecycle
  timings. This lane requires OpenAI live partial text even when Gemini is
  selected for the full cue.
- Context prompt, literal terminology hints, language hints, and delay control.
  The default live pass uses the balanced `medium` accuracy/latency setting.
  Local Parakeet currently uses the first supported language hint; the prompt
  and terminology hints improve both OpenAI transcription passes. Quick
  Dictation shares the literal terminology and expected-language settings;
  Local Whisper uses the expected-language setting and otherwise decodes
  verbatim so a failed cloud cleanup cannot discard spoken content.
- Per-track waveform, levels, packet/drop counters, optional live partial text,
  and a combined final transcript. Local-only turns show a transcription
  progress state until their first text is ready; failures remain explicit.
  When a hosted live result is refined, the original remains visible for
  comparison.
- When OpenAI is enabled, an API estimate with a per-model breakdown. Without a
  key, the same header location prominently says that OpenAI is not configured. It prefers
  server-reported transcription duration and falls back to the submitted PCM
  duration, separates live and final passes, includes cloud Quick Dictation,
  and shows both local engines as zero API cost. The running total is stored on
  disk and accumulates across launches, labelled with the date it started and
  how long it has been running, so a day's spend stays legible across many
  restarts. **Reset Counter** is the only thing that clears it.
- **Local-first onboarding.** A fresh install needs no account, no API key, and
  no configuration: Quick Dictation and completed-turn meeting/interview
  transcripts run on this Mac with Whisper out of the box. The app opens on the
  Quick Dictation tab while no key is saved. OpenAI and Gemini keys are
  presented as optional enhancements, not prerequisites.
- **Capability-based gating.** Live partial words and generated replay scenarios
  require OpenAI. Meeting Assistant, Answer Mirror, and their hosted search use
  the selected assistant provider's key; a replay therefore also requires that
  provider for its live cues. Each unavailable surface opens Settings at the
  API-key section, while Meeting and Interview Start controls remain enabled for
  local two-track transcripts.
- A **Never contact cloud services** switch in Settings › Privacy provides a
  hard guarantee even when one or more keys are saved. It is an override, not
  the primary gate.
- Settings live in one standard ⌘, window (General, Dictation, API Keys, Privacy,
  How It Works) rather than three header popovers, so each control has exactly
  one home. Model choices are presented by outcome — **Fast**, **Accurate**,
  **Best** — with the underlying model identifier shown but not shouted.
- A host-side reference folder that is restored and scanned at launch, watched
  recursively for changes, and converted into a stable content revision and
  cache-friendly assistant prompt prefix. The display client receives only
  readiness metadata, citations, and presentation-ready assistant results.
- A main-screen audio-device dashboard with explicit microphone and system
  output names. Stream health distinguishes ready, checking, healthy, dropped
  buffers, digital silence, missing permission/device, and stopped packet flow.
  The microphone and speaker pull-down buttons list compatible devices and
  change the current macOS default input or output without opening System
  Settings.
- Optional global hold-to-dictate using the selected final transcription model,
  modifier-only Command-Option monitoring, and automatic paste into the app,
  window, and control that were focused when recording began.

Meeting audio and transcripts remain in memory. Each interview is incrementally
saved as a plain JSON archive under
`~/Library/Application Support/com.newtypekk.punderclass/InterviewSessions/`.
The archive contains session metadata, finalized and revised transcript turns,
every accepted thinking bridge, and every assistant suggestion that was
published—including an interim cue later replaced by a finalized one. **Show
Archive** beside the interview transcript reveals the latest file. Clearing the
visible transcript does not silently erase this analysis record. Interview
audio is not included. Quick Dictation final text is stored locally for the
history tab until the user erases it. Quick Dictation WAV
audio is also stored temporarily while transcription is pending or recoverable;
it is removed after text is safely saved or the user explicitly deletes it.
Continuous meeting, interview, or diagnostic audio recording is not implemented.

FluidAudio is Apache-2.0 licensed, Argmax OSS and OpenAI Whisper are MIT
licensed, and NVIDIA Parakeet TDT 0.6B v3 is available under CC BY 4.0.
Distribution attribution is recorded in
`AppBundle/THIRD_PARTY_NOTICES.md` and included in the built application.

## Security note

For this local proof, API keys are stored in the macOS Keychain and used
directly by the app. A deployed company version should obtain short-lived
credentials from an authenticated internal broker rather than distribute a
long-lived provider API key to client Macs.

## Build and test

```sh
swift test
./scripts/build-app.sh release
```

The bundled app is written to `.build/PermanentUnderclass.app`, with its
executable at `.build/PermanentUnderclass.app/Contents/MacOS/punderclass`.
