# MyFluidVoice

<p align="center">
  <a href="https://github.com/Liooo/MyFluidVoice/stargazers"><img src="https://img.shields.io/github/stars/Liooo/MyFluidVoice?style=social" alt="GitHub stars"/></a>
  <br />
  <a href="https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1"><img src="https://img.shields.io/badge/Models-Nemotron%20Speech%203.5%20%7C%20Parakeet%20Flash%20%7C%20Parakeet%20v3%20%26%20v2%20%7C%20Cohere%20%7C%20Apple%20Speech%20%7C%20Whisper-blue" alt="Supported Models"/></a>
  <br /><br />
</p>

Open source voice-to-text dictation app for macOS with local speech recognition
and optional AI enhancement through user-configured providers.

Build MyFluidVoice from source while fork release infrastructure is being prepared.


> [!IMPORTANT]
> This project is free and open source under GPLv3. If MyFluidVoice is useful to you, please star the repository — it helps visibility and keeps development going.

---

## Support MyFluidVoice

If MyFluidVoice helps you, please star the [repository](https://github.com/Liooo/MyFluidVoice).

---

## Fork Highlights

- **IME-aware dictation** — assign a speech locale and model to each installed keyboard input source; the selection is frozen for each recording session
- **Double-modifier shortcuts** — configure clean double taps such as Double Shift for toggle or push-to-talk dictation
- **Configurable exit policies** — choose independently whether Escape and outside clicks do nothing, discard, or finish and paste during toggle dictation
- **Recording feedback** — enable, preview, and select independent start and end sounds, including no sound
- **Safe clipboard fallback** — optionally copy the final processed transcript only when no writable text target is focused

The public fork does not ship or require the private Fluid Intelligence runtime.
Core dictation works without AI enhancement; optional enhancement, Command Mode,
and Write Mode use a configured cloud or OpenAI-compatible provider.

---

## Features

- **Command Mode** — control your Mac by voice: launch apps, run shortcuts, trigger system actions, and automate workflows without touching the keyboard
- **Write Mode** — write or rewrite text directly in any text field across any app. Select text and rewrite it, or dictate new content inline
- **Live Preview** — real-time transcription overlay with notch support, so you see words appear as you speak
- **Multiple Speech Models** — Nemotron Speech 3.5, Parakeet Flash, Parakeet TDT v3 & v2, Cohere Transcribe, Apple Speech, and Whisper. Pick the model that fits your language and latency needs
- **AI Enhancement** — optional post-processing via OpenAI, Groq, or a custom OpenAI-compatible provider for cleaner, more accurate transcripts
- **Audio History** — optional local recording history with budget controls and ZIP export, so you can review past dictations without cloud storage
- **Today-Usage Stats** — daily usage tracking at a glance with a stats header card and toolbar pill
- **Adaptive Theming** — light/dark theme that follows your system, with a compact toolbar switcher
- **Global Hotkey** — instant voice capture from anywhere, no app switching needed
- **Smart Typing** — direct insertion into any app via accessibility APIs for reliable, app-independent text entry
- **Menu Bar Integration** — quick access, status, and settings from the menu bar
- **Per-App Configuration** — assign different prompt sets to different apps, so your dictation adapts to whatever you're working in. Fully optional
- **Notch-Aware Overlay** — transcription overlay that fits cleanly around the MacBook notch, or use a standard overlay if your Mac doesn't have one
- **Local-First** — choose on-device speech models to keep audio on your Mac; Apple Speech and configured AI providers may use their respective services
- **Fastest Parakeet on Mac** — one of the fastest native implementations of Parakeet on macOS, with near-instant transcription and minimal latency
- **Configurable Overlay** — choose from pill-shaped to large overlay sizes to show live preview, or keep it minimal. Everything is optional
- **Everything is Optional** — AI enhancement and audio history are opt-in. The core dictation experience works without an AI provider

---

## Supported Models

| Model | Best for | Language support | Download size | Hardware |
| --- | --- | --- | --- | --- |
| Nemotron Speech 3.5 — Ultra Fast Low Latency | Streaming-capable multilingual dictation | ~40 languages | ~670 MB | Apple Silicon |
| Nemotron 3.5 Multilingual | Higher-accuracy multilingual dictation | ~40 languages | ~530 MB | Apple Silicon |
| [Parakeet Flash (Beta)](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1) | Lowest-latency live English dictation | English | ~250 MB | Apple Silicon |
| Parakeet TDT v3 | Fast default multilingual dictation | [25 languages](#parakeet-tdt-v3-languages) | ~500 MB | Apple Silicon |
| Parakeet TDT v2 | Fastest English-only dictation | [English](#parakeet-tdt-v2-languages) | ~500 MB | Apple Silicon |
| Cohere Transcribe | High-accuracy multilingual dictation | [14 languages](#cohere-transcribe-languages) | ~1.4 GB | Apple Silicon |
| Apple Speech | Zero-download native macOS speech | [System languages](#apple-speech-languages) | Built-in | Apple Silicon + Intel |
| Whisper Tiny / Base / Small / Medium / Large | Broad compatibility, including Intel Macs | [99 languages](#whisper-language-support) | ~75 MB to ~2.9 GB | Apple Silicon + Intel |

### Parakeet TDT v3 Languages

Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, and Ukrainian.

### Parakeet TDT v2 Languages

English.

### Cohere Transcribe Languages

English, French, German, Italian, Spanish, Portuguese, Greek, Dutch, Polish, Mandarin, Japanese, Korean, Vietnamese, and Arabic.

### Apple Speech Languages

System language support depends on the macOS speech recognition languages available on your machine.

### Whisper Language Support

Whisper supports up to 99 languages, depending on the model size you choose.

---

## Quick Start

1. **Build from source** using [Xcode or the signed build script](#building-from-source). Fork release packages are not available yet.

2. **Grant permissions** — MyFluidVoice will ask for microphone and accessibility access. Both are required for dictation and typing into other apps.

3. **Set your hotkey** — pick a global hotkey in settings that triggers voice capture from anywhere.

4. **Go through onboarding** — choose your voice model based on your language and latency needs. Models range from zero-download Apple Speech to high-accuracy Nemotron and Whisper.

5. **(Optional) Bring your own AI provider** — add an OpenAI, Groq, or custom OpenAI-compatible provider API key for cloud-based enhancement. Keys are stored securely in macOS Keychain. Select "Always allow" for key access.

---

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon Mac for all models
- Intel Macs supported via Whisper models
- ~1 GB disk space for a voice model
- Microphone access
- Accessibility permissions for typing

---

## Building from Source

```bash
git clone https://github.com/Liooo/MyFluidVoice.git
cd MyFluidVoice
open Fluid.xcodeproj
```

Build and run in Xcode. All dependencies are managed via Swift Package Manager.

The public repository does not include the private Fluid Intelligence runtime or
its build tooling. It is not required for speech recognition, transcription,
typing, or enhancement through a supported external provider.

Run a signed Debug build using the script:

```bash
./build.sh
```

The signed build is written to `DerivedData/Build/Products/Debug/MyFluidVoice Debug.app`.
Keep launching that product after each rebuild so macOS can preserve its Accessibility
authorization.

For CI or contributors who do not have a signing identity, use the explicit unsigned
fallback:

```bash
./build.sh unsigned
```

Unsigned builds are tied to a specific executable version and may require Accessibility
permission to be removed and granted again after rebuilding.

---

## Contributing

Contributions are welcome! Please create an issue first to discuss major changes before submitting a pull request.

### Development Setup

1. Clone and open in Xcode as above.
2. **Signing:** `MyFluidVoice → Signing & Capabilities → Automatically manage signing → pick your Team` (Personal Team is fine). If you have certificates for multiple teams, select one without changing the project by running `FLUIDVOICE_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./build.sh`.
3. Build and run — SPM handles dependencies.
4. **(Optional) Pre-commit hook** to prevent accidental team ID commits:
   ```bash
   cp scripts/check-team-id.sh .git/hooks/pre-commit
   chmod +x .git/hooks/pre-commit
   ```

### Pull Request Guidelines

- **One feature or fix per PR** — keep changes focused and atomic
- **Create an issue first** so work is trackable before review
- **Discuss non-trivial changes** before opening a PR
- **Follow the PR template**
- **Test thoroughly** on your machine
- **Never commit personal team IDs or API keys**
- **Check `git diff`** before committing

---

## Run Integration Tests

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS'
```

CI uses unsigned builds:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

---

## Privacy & Analytics

MyFluidVoice is **local-first**. On-device speech models keep audio on your Mac.
Apple Speech may use Apple's speech service according to macOS availability and
settings. Soniox speech recognition is opt-in, bring-your-own-key (BYOK), and can
be selected as the global dictation model or assigned per IME. Its API key is
stored only in the macOS Keychain.

When Soniox is selected, audio and transcripts travel directly from your Mac to
the selected regional Soniox endpoint, and Soniox bills the associated account
for usage. Japan data residency requires a Japan-region Soniox project, API key,
and endpoint. Soniox states that realtime audio and transcripts are not retained
or used for model training; see Soniox's current
[Security and Privacy documentation](https://soniox.com/docs/security-and-privacy)
for the provider's policy. These are Soniox's claims, not a MyFluidVoice guarantee.

File transcription, Meeting mode, dictionary training, and the Local API use the
displayed local fallback model and do not use Soniox. If you configure a cloud or
OpenAI-compatible AI enhancement provider, the text and context needed for that
requested enhancement are sent to the selected provider separately.

Analytics transmission is disabled in this fork. MyFluidVoice does not send app-health or feature-usage events. Update checks are also disabled until the fork has its own release infrastructure.

**Not transmitted to an analytics service by MyFluidVoice:**

- Voice, raw audio, or transcribed text
- Selected text, prompts, or AI responses
- Terminal commands, window titles, file paths, clipboard, or typed content
- Any personal or private information

MyFluidVoice stores transcription history locally, including raw and processed
text plus app and window context. Optional audio history stores recordings locally
when enabled. Local diagnostic logs can contain operational context such as
transcripts, app or window names, and file or media paths and titles. These local
history, audio-history, and diagnostic features are separate from Soniox cloud
processing. These local records are not sent through an analytics transport.
History can be reviewed and cleared from the app.

---

## Community

Use [GitHub Issues](https://github.com/Liooo/MyFluidVoice/issues) for reproducible bugs and feature proposals. Do not attach private transcripts, API keys, or sensitive debug logs.

---

## License

From 2026-02-23 onward, this project is licensed under the [GNU General Public License, Version 3.0 (GPLv3)](LICENSE).

Versions published before this date were licensed under Apache License 2.0.

MyFluidVoice is a modified fork of [FluidVoice](https://github.com/altic-dev/FluidVoice). Fork-specific modifications began in August 2026; the Git history preserves upstream authorship and modification history.

Licenses and attribution for bundled dependencies are provided in the
[third-party notices](Sources/Fluid/Resources/THIRD_PARTY_NOTICES.txt).
