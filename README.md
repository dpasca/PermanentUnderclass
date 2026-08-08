<p align="center">
  <img
    src="Design/AppIcon/punderclass-app-icon-master.png"
    width="160"
    alt="PermanentUnderclass application icon"
  >
</p>

<h1 align="center">PermanentUnderclass</h1>

PermanentUnderclass is an experimental native macOS app for local-first quick
dictation, two-track meeting and interview transcription, and optional live
response cues grounded in your own reference material.

It changes quickly, but tagged releases provide a signed and notarized build for
Apple silicon Macs.

Every screenshot below is generated with the app's synthetic documentation
mode. It does not load Keychain credentials, saved dictations, reference
folders, audio devices, or running-process names.

![Quick Dictation with synthetic history](Docs/screenshots/quick-dictation.png)

## What it does

- **Quick Dictation:** hold Command–Option, speak, and paste the final text into
  the app that was focused when you started. Local Whisper is the default, so
  this works without an account or API key.
- **Meeting:** capture the microphone and system audio as separate speakers,
  keep a live transcript, and optionally show grounded response cues in a
  loopback-only browser display.
- **Interview:** use the same two-track capture with an Answer Mirror that
  suggests concise answer beats without inventing personal experience.

## Download

The [latest GitHub release](https://github.com/dpasca/PermanentUnderclass/releases/latest)
contains `PermanentUnderclass-macOS-arm64.zip`. Expand it, move
`PermanentUnderclass.app` to Applications, and launch it normally. The archive
is Developer ID signed, notarized, stapled, and accompanied by a SHA-256
checksum. Intel Macs and non-macOS systems are not supported.

## More screenshots

| Meeting | Interview |
| --- | --- |
| ![Meeting capture with a synthetic transcript](Docs/screenshots/meeting.png) | ![Interview capture with a synthetic transcript](Docs/screenshots/interview.png) |

## Privacy at a glance

| Feature | What stays local | What may leave the Mac |
| --- | --- | --- |
| Quick Dictation | Local-model audio processing, saved final-text history, and temporary recoverable audio | Audio only when OpenAI GPT-Transcribe is explicitly selected |
| Meeting and interview capture | UI state and in-memory transcript | Live audio is sent to OpenAI for realtime transcription |
| Final transcript pass | Whisper or Parakeet can run on-device | Audio when the OpenAI finalizer is selected |
| Meeting Assistant and Answer Mirror | Reference indexing and the browser gateway | Relevant reference text and transcript context sent to OpenAI to generate cues |

The API key is stored in macOS Keychain. The companion display is served only
on the loopback interface and never receives the API key or full reference
corpus. A **Never contact OpenAI** privacy switch disables hosted features.
Meeting and interview audio is not continuously recorded to disk; Quick
Dictation retains audio only while a transcription is pending or recoverable.

## Requirements

- macOS 14.2 or newer.
- Apple Silicon for the local Whisper and Parakeet engines.
- Headphones for meeting or interview capture, to avoid feedback and speaker
  leakage.
- An OpenAI API key for meeting/interview live transcription and assistant
  features. It is not required for local Quick Dictation.

## Build and run

Building from source requires the Xcode command-line tools and Swift 5.10 or
newer. Clone the repository, then run:

```sh
swift test
./scripts/run-app.sh
```

The first run asks for the relevant macOS microphone, accessibility, and system
audio permissions as features need them. For an explicit release build:

```sh
./scripts/build-app.sh release
```

The app bundle is written to `.build/PermanentUnderclass.app`. The script uses an
installed Developer ID Application certificate when available and otherwise
falls back to ad hoc signing. Tagged releases use a separate workflow that
requires Developer ID signing and Apple notarization before publishing.

## Documentation

- [Detailed product and operating guide](Docs/product-guide.md)
- [Live assistant architecture](Docs/live-assistant-architecture.md)
- [Open-source publication checklist](Docs/open-source-checklist.md)
- [Release engineering](Docs/release-engineering.md)
- [Third-party dependency notices](AppBundle/THIRD_PARTY_NOTICES.md)

## Project policy

This is a utility that I constantly change to suit specific needs, so it is not
accepting external code contributions or pull requests. Bug reports are welcome,
and anyone is free to fork and modify it for their own use. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before opening
a report.

## License

PermanentUnderclass is available under the [MIT License](LICENSE). That license
covers the project-owned source code and artwork in this repository, including
the application icon. Third-party code and downloaded models remain under
their respective licenses, recorded in
[AppBundle/THIRD_PARTY_NOTICES.md](AppBundle/THIRD_PARTY_NOTICES.md).
