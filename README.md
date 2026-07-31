# Meeting Copilot

A minimal native macOS proof of concept that captures two independent audio
tracks and transcribes them in real time:

- **You** — the Mac's default microphone.
- **Other** — audio emitted by one selected meeting application.

Each track is sent to its own OpenAI Realtime transcription session, so speaker
labels come from the audio route rather than diarization guesses. Completed
turns are finalized by an embedded local Parakeet model by default. The local
engine runs directly inside Meeting Copilot and does not use the MacParakeet
application, process, settings, microphone handling, or database.

## Requirements

- macOS 14.2 or newer.
- Apple Silicon for the local Parakeet finalizer.
- Xcode command-line tools.
- Wired or USB headphones during the proof of concept.
- An OpenAI API key with access to `gpt-live-transcribe`. The optional OpenAI
  finalizer also requires access to `gpt-realtime-2.1`.

## Run

```sh
./scripts/run-app.sh
```

On first use, macOS asks for microphone and system-audio recording permission.
If either permission was previously denied, enable **Meeting Copilot** under
System Settings → Privacy & Security → Microphone and Screen & System Audio
Recording, then relaunch the app.

The build script uses an installed **Developer ID Application** certificate by
default so the app has a stable designated code requirement across rebuilds.
macOS associates privacy consent with that requirement. The first
certificate-signed build may ask once more because it intentionally replaces
the earlier ad-hoc identity; subsequent rebuilds retain the same identity.
Notarization is needed for distributing a downloaded app through Gatekeeper,
not for retaining local privacy consent. Override the selected certificate with
`MEETING_COPILOT_SIGNING_IDENTITY`; without a Developer ID certificate the
script falls back to ad-hoc signing and warns that consent may not persist.

Paste an API key into the app and press **Save to Keychain**. Select the
meeting application (it may appear under a helper-process name), then start
listening.

## Quick Dictation

Enable **Quick Dictation**, then grant Accessibility and Microphone access when
prompted. Accessibility allows both global shortcut monitoring and automatic
paste. macOS may require Meeting Copilot to be quit and reopened after this
permission changes. Hold the exact modifier-only chord **Command + Option**
while speaking and release either modifier to transcribe locally with Parakeet
and paste into the currently focused application. Pressing another keyboard key
while the chord is down cancels the recording, so normal Command-Option
shortcuts do not become dictations.

The focused application's clipboard is used briefly for the paste and restored
afterward if it was not changed by another application. Quick Dictation is
paused while meeting capture is using the microphone.

## Current scope

The proof of concept includes:

- Core Audio process-tap capture without a virtual audio driver.
- Default-microphone capture.
- Live monitoring of the macOS default input, with automatic microphone
  capture restart when devices are connected, removed, or reconfigured.
- 24 kHz mono PCM16 conversion and bounded 20 ms audio chunks.
- Two independent `gpt-live-transcribe` WebSocket sessions.
- A selectable final-transcript engine:
  - **Local Parakeet** embeds FluidAudio and NVIDIA Parakeet TDT 0.6B v3 using
    Core ML. On macOS the large encoder uses the GPU to avoid slow or stalled
    Neural Engine preparation while retaining the same model and recognition
    quality. The first use downloads roughly 483 MB to FluidAudio's
    application-support cache and each fresh app process performs a short
    Core ML preparation before Quick Dictation becomes ready.
  - **OpenAI audio second pass** retains the existing serialized,
    out-of-band `gpt-realtime-2.1` worker for comparison.
- Client-side audio voice-activity detection with a 300 ms pre-roll, a 3
  second end-of-turn pause, and explicit turn commits. Partial text continues
  streaming during the finalization pause. A **Finish My Turn** button supplies
  a manual boundary for controlled comparisons.
- Context prompt, literal terminology hints, language hints, and delay control.
  The default live pass uses the balanced `medium` accuracy/latency setting.
  Local Parakeet currently uses the first supported language hint; the prompt
  and terminology hints still improve the OpenAI live pass.
- Per-track waveform, levels, packet/drop counters, live partial text, and a
  combined final transcript. Each finalized turn is labeled **Refining**,
  **Refined**, or **Live only**; when refinement changes the wording, the
  original live result remains visible for comparison.
- Optional global hold-to-dictate using the same embedded Parakeet model,
  modifier-only Command-Option monitoring, and automatic paste into the focused
  application.

Audio and transcripts remain in memory. Per-turn PCM is retained only long
enough to perform the second pass. Diagnostic audio recording is not
implemented and no meeting audio is written to disk.

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

The bundled app is written to `.build/MeetingCopilot.app`.
