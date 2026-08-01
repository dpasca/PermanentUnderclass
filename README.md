# PUnderclass

A minimal native macOS proof of concept that captures two independent audio
tracks and transcribes them in real time:

- **You** — the Mac's default microphone.
- **Other** — audio emitted by one selected meeting application.

Each track is sent to its own OpenAI Realtime transcription session, so speaker
labels come from the audio route rather than diarization guesses. Completed
turns are finalized by `gpt-transcribe` by default. An embedded local Parakeet
model remains available as an offline fallback and evaluation baseline. The
local engine runs directly inside PUnderclass and does not use the
MacParakeet application, process, settings, microphone handling, or database.

## Requirements

- macOS 14.2 or newer.
- Apple Silicon when using the local Parakeet finalizer.
- Xcode command-line tools.
- Wired or USB headphones during the proof of concept.
- An OpenAI API key with access to `gpt-live-transcribe`. The optional OpenAI
  finalizer also requires access to `gpt-transcribe`.

## Run

```sh
./scripts/run-app.sh
```

On first use, macOS asks for microphone and system-audio recording permission.
If either permission was previously denied, enable **PUnderclass** under
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

Open the shared transcription settings from the gear button, paste an API key,
and press **Save to Keychain**. Select the meeting application (it may appear
under a helper-process name), then start listening.

## Live Assistant companion prototype

An interactive cross-platform companion mockup lives in
`Prototypes/LiveAssistant`. It is intentionally a thin display: the Mac owns
the active behavior, local references, model calls, and cost calculation, while
the client renders complete guidance cards, transcript events, connection
state, and the intended resume-and-replay experience after a dropped
connection.

```sh
./scripts/run-companion-prototype.sh
```

Open <http://127.0.0.1:4173>. The prototype uses local mock data and makes no
network or model requests. The proposed HTTP/SSE protocol, retry contract,
pairing boundary, and implementation slices are in
`Docs/live-assistant-architecture.md`.

## Reference material

Expand **References and meeting context** on the Meeting tab and choose one
reference folder. The Swift app restores and ingests that folder at launch,
watches it recursively for changes, and debounces change bursts into a fresh
deterministic revision. It currently reads PDF, RTF, Markdown, plain text,
CSV/TSV, JSON/JSONL, YAML, XML, and HTML files. Unsupported files are counted;
unreadable or truncated files are reported instead of silently disappearing.

Reference contents are owned by the Mac host and are never copied to the thin
display. The prompt builder places stable behavior and reference material
before volatile transcript content and exposes a stable cache key plus an
explicit breakpoint boundary. A future cloud assistant request will send the
selected reference text to its model provider; the current spike builds the
host-side reference snapshot and prompt contract but does not yet issue
assistant model calls.

## Quick Dictation

Enable **Quick Dictation**, then grant Accessibility and Microphone access when
prompted. Accessibility allows both global shortcut monitoring and automatic
paste. macOS may require PUnderclass to be quit and reopened after this
permission changes. Hold the exact modifier-only chord **Command + Option**
while speaking and release either modifier to transcribe with the currently
selected final-pass and Quick Dictation model, then paste into the focused
application. Local Parakeet keeps dictation audio on this Mac; GPT-Transcribe
sends the captured dictation audio to OpenAI. Pressing another keyboard key
while the chord is down cancels the recording, so normal Command-Option
shortcuts do not become dictations.

By default, Quick Dictation shows a small, non-activating preview near the
bottom of the current screen. It displays the live microphone waveform while
recording and periodically sends bounded snapshots to the same selected model
to update the preview text. Quick Dictation does not use the Meeting-only
`gpt-live-transcribe` model. After release, the selected model transcribes the
complete recording once for the pasted and saved result.
The waveform uses adaptive visual gain so quiet microphones still provide clear
feedback. The pipeline's **Screen preview (optional stage)** switch directly
controls the snapshot stage and overlay. Turning it off does not disable the
required final transcription that runs when the shortcut is released.

The focused application's clipboard is used briefly for the paste and restored
afterward if it was not changed by another application. Quick Dictation is
paused while meeting capture is using the microphone.

The main window's **Quick Dictation** tab owns the shortcut, permission,
preview, live microphone, and history controls. Completed text appears there in
newest-first order. Each entry can be copied back to the clipboard or deleted,
and **Erase All** clears the complete history after confirmation. This text is
stored locally in the current user's Application Support folder until it is
erased; dictation audio is never retained in the history.

PUnderclass speculatively prepares Local Parakeet in the background at launch,
even when GPT-Transcribe is selected. The model pipeline and shared settings
show the current download/load phase and elapsed time. This warmup does not gate
the selected cloud transcriber, and all local callers share the same in-flight
preparation.

## Current scope

The proof of concept includes:

- Core Audio process-tap capture without a virtual audio driver.
- Default-microphone capture.
- Live monitoring of the macOS default input, with automatic microphone
  capture restart when devices are connected, removed, or reconfigured.
- 24 kHz mono PCM16 conversion and bounded 20 ms audio chunks.
- Two independent `gpt-live-transcribe` WebSocket sessions.
- A shared window bar that names every active model by role: the fixed Meeting
  live model and the selected final-pass/Quick Dictation model. Its pipeline
  popover explains every stage, execution location, transition, and optional
  preview pass; each workflow repeats its own compact stage sequence.
- A selectable final-pass and Quick Dictation engine:
  - **Local Parakeet** embeds FluidAudio and NVIDIA Parakeet TDT 0.6B v3 using
    Core ML. On macOS the large encoder uses the GPU to avoid slow or stalled
    Neural Engine preparation while retaining the same model and recognition
    quality. The first use downloads roughly 483 MB to FluidAudio's
    application-support cache. Each fresh app process warms the cached Core ML
    models and their first inference in the background so later local use does
    not pay the cold-start cost.
  - **OpenAI GPT-Transcribe** runs a persistent committed-turn
    `gpt-transcribe` session for each audio track. The two tracks finalize in
    parallel while retaining deterministic speaker labels. Each turn includes
    the meeting prompt, terminology and language hints, plus recent
    cross-speaker transcript context.
- Client-side audio voice-activity detection with a 300 ms pre-roll, a 3
  second end-of-turn pause, and explicit turn commits. Partial text continues
  streaming during the finalization pause. A **Finish My Turn** button supplies
  a manual boundary for controlled comparisons.
- Context prompt, literal terminology hints, language hints, and delay control.
  The default live pass uses the balanced `medium` accuracy/latency setting.
  Local Parakeet currently uses the first supported language hint; the prompt
  and terminology hints improve both OpenAI transcription passes.
- Per-track waveform, levels, packet/drop counters, live partial text, and a
  combined final transcript. Each finalized turn is labeled **Refining**,
  **Refined**, or **Live only**; when refinement changes the wording, the
  original live result remains visible for comparison.
- An always-visible OpenAI API estimate with a per-model breakdown. It prefers
  server-reported transcription duration and falls back to the submitted PCM
  duration, separates live and final passes, includes cloud Quick Dictation,
  and shows Local Parakeet as zero API cost.
- A host-side reference folder that is restored and scanned at launch, watched
  recursively for changes, and converted into a stable content revision and
  cache-friendly assistant prompt prefix. The display client receives only
  readiness metadata, citations, and presentation-ready assistant results.
- A main-screen audio-device dashboard with explicit microphone and system
  output names. Stream health distinguishes ready, checking, healthy, dropped
  buffers, missing permission/device, and stopped packet flow. The microphone
  and speaker pull-down buttons list compatible devices and change the current
  macOS default input or output without opening System Settings.
- Optional global hold-to-dictate using the selected final transcription model,
  modifier-only Command-Option monitoring, and automatic paste into the focused
  application.

Audio and meeting transcripts remain in memory. Quick Dictation final text is
the exception: it is stored locally for the history tab until the user erases
it. Per-turn PCM is retained only long enough to perform the second pass.
Diagnostic audio recording is not implemented and no meeting or dictation
audio is written to disk.

FluidAudio is Apache-2.0 licensed. NVIDIA Parakeet TDT 0.6B v3 is available
under CC BY 4.0. Distribution attribution is recorded in
`AppBundle/THIRD_PARTY_NOTICES.md` and included in the built application.

## Security note

For this local proof, the API key is stored in the macOS Keychain and used
directly by the app. A deployed company version should obtain short-lived
credentials from an authenticated internal broker rather than distribute a
long-lived OpenAI API key to client Macs.

## Build and test

```sh
swift test
./scripts/build-app.sh release
```

The bundled app is written to `.build/PUnderclass.app`, with its executable at
`.build/PUnderclass.app/Contents/MacOS/punderclass`.
