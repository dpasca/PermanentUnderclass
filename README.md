# PUnderclass

A minimal native macOS proof of concept that captures two independent audio
tracks and transcribes them in real time:

- **You** — the Mac's default microphone.
- **Other** — all system audio by default, or one selected meeting application.

Each track is sent to its own OpenAI Realtime transcription session, so speaker
labels come from the audio route rather than diarization guesses. Completed
turns are finalized by `gpt-transcribe` by default. A compressed Whisper Large
v3 model is the high-accuracy on-device option and cloud emergency fallback;
Parakeet remains available as a faster, lighter evaluation baseline. Both local
engines run directly inside PUnderclass and do not use another application's
process, settings, microphone handling, or database.

## Requirements

- macOS 14.2 or newer.
- Apple Silicon when using either local finalizer.
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
and press **Save to Keychain**, then start listening. Meeting capture uses all
system audio by default. To limit capture to one app, choose it from **Audio to
transcribe**; it may appear under a helper-process name.

## Live Assistant companion

PUnderclass now embeds a loopback-only HTTP/SSE gateway and serves the
cross-platform thin display itself. Start the Mac app, expand **References and
meeting context**, choose a reference folder, then press **Open Live
Assistant** or open <http://127.0.0.1:4173>. The Mac owns the active behavior,
local references, OpenAI request, usage tracking, event ordering, and replay;
the browser receives only transcript text, reference status, citations, and a
presentation-ready comparison outline.

The first real behavior is **Answer Mirror**. An 800 ms pause in the
interviewer's audio can trigger a structured `gpt-5.6-luna` Responses API
outline from the current partial transcript before the 3 second final-turn
boundary. The final interviewer turn remains a fallback, and an exact
partial/final duplicate is coalesced rather than billed twice. Candidate
speech stays visible in the transcript but does not replace the model outline,
so the two can be compared in real time. Speaker identity provides this
routing; there is no keyword or regex gate.
Each result is three to five labeled, telegraphic beats rather than polished
prose, using plain conversational wording instead of corporate interview
language. This makes it possible to compare substance without reading a script. The
newest card appears first and the host retains three previous cards in the
snapshot, preserving the stack across browser refreshes and reconnects.
Indexed local files are preferred when they support the outline. If they do
not, the model may still draft an approach-oriented outline from the live
discussion and general model knowledge without claiming unverified personal
experience. The display prefixes it with **NO LOCAL SUPPORTING MATERIAL**.
The stable behavior/reference prefix uses an explicit prompt-cache breakpoint
and cache key, while recent transcript stays in the volatile suffix. Assistant
token and cache usage is counted separately; it is not folded into the dollar
estimate until a model rate is configured.

To view the same client without starting the native host, run the standalone
preview:

```sh
./scripts/run-companion-prototype.sh
```

The standalone server falls back to simulated data and makes no model request.
The live host exposes an atomic snapshot, a replayable composite SSE cursor,
and idempotent pause/pin/dismiss commands. The protocol, retry contract,
pairing boundary, and follow-up durability work are in
`Docs/live-assistant-architecture.md`.

## Synthetic interview replay

The Meeting tab includes a **Document-grounded replay**. Choose a reference
folder and wait for indexing, then press **Run Interview**. On the first run for
a reference revision, the host uses a structured model call to create five
question/answer exchanges grounded in exact indexed paths. The final two probe
CUDA in depth when that subject is supported by the references; otherwise they
use the deepest supported technical topic. Two macOS voices speak the resulting
ten turns while the host streams their known words as
partial transcript events. After every interviewer question, the real Answer
Mirror independently drafts the shorthand model outline shown beside the generated
candidate response. The companion reports both model time and end-to-end
`transcript → card` time.

The generated scenario is stored locally in Application Support and reused
while the reference revision and scenario format match, making latency reruns
repeatable without another scenario-generation call. **New Questions** forces
a fresh document-grounded scenario. Changing any indexed document naturally
produces a new revision and invalidates the cached scenario.

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

## Reference material

Expand **References and meeting context** on the Meeting tab and choose one
reference folder. The Swift app restores and ingests that folder at launch,
watches it recursively for changes, and debounces change bursts into a fresh
deterministic revision. It currently reads PDF, RTF, Markdown, plain text,
CSV/TSV, JSON/JSONL, YAML, XML, and HTML files. Unsupported files are counted;
unreadable or truncated files are reported instead of silently disappearing.

Reference contents are owned by the Mac host and are never copied to the thin
display. The prompt builder places stable behavior and reference material
before volatile transcript content and sends that exact prefix to OpenAI with
an explicit cache breakpoint. Recent transcript is appended afterward. The
browser never receives the reference corpus, assembled prompt, or API key.

## Quick Dictation

Enable **Quick Dictation**, then grant Accessibility and Microphone access when
prompted. Accessibility allows both global shortcut monitoring and automatic
paste. macOS may require PUnderclass to be quit and reopened after this
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
bottom of the current screen. It displays the live microphone waveform while
recording and periodically sends bounded snapshots to the selected model to
update the preview text. With GPT-Transcribe selected, preview and final work use
independent connections, so a slow preview cannot queue in front of the final
recording. Quick Dictation does not use the Meeting-only `gpt-live-transcribe`
model. After release, the selected model transcribes the complete recording once
for the pasted and saved result. Neither recording nor local transcription has
a duration deadline. For cloud transcription, the response watchdog starts only
after every audio byte and the commit have been sent. An explicit OpenAI failure
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
Accessibility value, its successful paste is treated as intentionally
unverifiable instead of generating a false failure warning.
If the original target closes or can no longer be focused, Quick Dictation saves
the completed text in history instead of pasting it into a different window.
Quick Dictation is paused while meeting capture is using the microphone.

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

PUnderclass speculatively prepares Local Whisper in the background at launch,
even when GPT-Transcribe is selected. The model pipeline and shared settings
show the current download/load phase and elapsed time. This warmup does not gate
the selected cloud transcriber, and all local callers share the same in-flight
preparation. The first run after the download—or after macOS invalidates its
Core ML cache—can spend additional time specializing the model for the Mac;
later launches reuse that cached specialization.

## Headless mode

Press the global shortcut **Control + Command + H** to enter headless
mode. PUnderclass hides all of its windows, including the Quick Dictation
preview, and removes itself from both the Dock and the application switcher.
Capture, transcription, Quick Dictation, and the Live Assistant host continue
running.

Press the same shortcut again to restore the main window and Dock icon. The
shortcut is registered independently of Quick Dictation and does not require
Accessibility permission. There is deliberately no menu-bar fallback while
headless; if the shortcut becomes unavailable, quit PUnderclass from Activity
Monitor and relaunch it.

Launching PUnderclass again reuses the existing process instead of starting a
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
  capture restart when devices are connected, removed, or reconfigured.
- 24 kHz mono PCM16 conversion and bounded 20 ms audio chunks.
- Two independent `gpt-live-transcribe` WebSocket sessions.
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
    the meeting prompt, terminology and language hints, plus recent
    cross-speaker transcript context.
- Client-side audio voice-activity detection with a 300 ms pre-roll, a 3
  second end-of-turn pause, and explicit turn commits. Partial text continues
  streaming during the finalization pause. A **Finish My Turn** button supplies
  a manual boundary for controlled comparisons.
- Answer Mirror checks an interviewer partial after an 800 ms audio pause,
  immediately checks a new finalized interviewer turn, and coalesces an
  unchanged partial/final pair. Candidate turns never replace the comparison
  answer.
  Privacy-safe lifecycle logs include trigger-to-start, model, and total
  transcript-to-result timings.
- Context prompt, literal terminology hints, language hints, and delay control.
  The default live pass uses the balanced `medium` accuracy/latency setting.
  Local Parakeet currently uses the first supported language hint; the prompt
  and terminology hints improve both OpenAI transcription passes. Quick
  Dictation shares the literal terminology and expected-language settings;
  Local Whisper uses the expected-language setting and otherwise decodes
  verbatim so a failed cloud cleanup cannot discard spoken content.
- Per-track waveform, levels, packet/drop counters, live partial text, and a
  combined final transcript. Each finalized turn is labeled **Refining**,
  **Refined**, or **Live only**; when refinement changes the wording, the
  original live result remains visible for comparison.
- An always-visible OpenAI API estimate with a per-model breakdown. It prefers
  server-reported transcription duration and falls back to the submitted PCM
  duration, separates live and final passes, includes cloud Quick Dictation,
  and shows both local engines as zero API cost.
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
  modifier-only Command-Option monitoring, and automatic paste into the app,
  window, and control that were focused when recording began.

Meeting audio and transcripts remain in memory. Quick Dictation final text is
stored locally for the history tab until the user erases it. Quick Dictation WAV
audio is also stored temporarily while transcription is pending or recoverable;
it is removed after text is safely saved or the user explicitly deletes it.
Continuous meeting or diagnostic audio recording is not implemented.

FluidAudio is Apache-2.0 licensed, Argmax OSS and OpenAI Whisper are MIT
licensed, and NVIDIA Parakeet TDT 0.6B v3 is available under CC BY 4.0.
Distribution attribution is recorded in
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
