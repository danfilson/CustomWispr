# CustomWispr

A customizable, open-source speech-to-text app for macOS. This is Daniel Filson's fork of
[beausterling/CustomWispr](https://github.com/beausterling/CustomWispr); it has diverged a
long way from upstream (see **Fork differences** below) and tracks its own history in
`SESSION-HANDOFF.md`, `TUNING-LOG.md` and an Obsidian note.

Press **F5** to start recording, press it again to stop. Audio is transcribed by a local
whisper.cpp server, cleaned up by an LLM, and pasted into the focused text field.

## Features

- **Global F5 hotkey** via Carbon `RegisterEventHotKey` (works on macOS 26 Tahoe), plus **⌘⌥Space** for the built-in MacBook keyboard whose top row sends media functions; menu-bar toggle as a fallback
- **Local transcription** with whisper.cpp (`ggml-large-v3-turbo`, Metal, Silero VAD) — nothing leaves the machine until cleanup
- **Streaming chunks**: long dictations are cut at pauses and transcribed while you are still talking, with prompt chaining and seam de-duplication, so only the last few seconds remain after key-up
- **Whisper glossary**: your `vocabulary` terms are passed as the whisper prompt on every chunk so names and jargon come out spelled right
- **Key-down warm-up**: a short clip pages the model back into RAM while you speak, so the first dictation after an idle hour is no slower than the rest
- **Two cleanup styles**: *tidy* (default — removes fillers, false starts and retractions, resolves self-corrections, keeps every fact and your voice) and *verbatim* (fillers only). Per-app rules in `cleanupProfiles`, a menu-bar override, and a speaker-context block so the model understands your references
- **Hesitation-ellipsis normalization** before cleanup, find/replace rules after
- **F6 feedback window**: tag and annotate any of the last 8 dictations, optionally with the text you actually wanted. This is the correction signal the monthly health check and the A/B harness learn from
- **History with pipeline metadata**: every entry records the app, style, model, prompt and context size, chunk count, per-stage timings, warm-up outcome and any fallback, so a bad output can be traced to a stage
- **Floating overlay** for status, **clipboard-safe paste**, **menu-bar controls**, pure Swift with no dependencies beyond system frameworks

## Requirements

- macOS 13.0 or later (Apple Silicon build is the one in use; `build.sh` targets Intel)
- Xcode Command Line Tools (`xcode-select --install`)
- whisper.cpp `whisper-server` (Homebrew) with a model in `~/.local/share/whisper-models/`, run by launchd (`~/Library/LaunchAgents/com.personal.whisper-server.plist`, port 8090)
- An OpenRouter key (or any OpenAI-compatible endpoint) for cleanup; cleanup can also run locally via Ollama or be switched off
- Microphone and Accessibility permissions

## Build and deploy

```bash
cd ~/Projects/BW/customwispr
bash build-arm64.sh      # compile, copy resources, sign as "CustomWispr Dev", deploy to /Applications, relaunch
```

The stable `CustomWispr Dev` signing certificate means Accessibility permission survives
rebuilds. Never run `tccutil reset` for this app. A rebuild stalls whisper for 30–50 s, so
do not dictate while one is running.

## Configuration

`~/.custom-wispr.env` (mode 600):

```
OPENAI_API_KEY=<OpenRouter key>
OPENAI_BASE_URL=https://openrouter.ai/api/v1
CLEANUP_MODE=cloud            # cloud | local | off
CLEANUP_MODEL=anthropic/claude-sonnet-5.5
LOCAL_WHISPER_URL=http://127.0.0.1:8090
```

`~/.custom-wispr-settings.json` (mode 600, edited through Settings or by hand):

| Key | What it holds |
|---|---|
| `replacements` | find/replace rules, applied after hesitation normalization and before the LLM |
| `vocabulary` | whisper glossary terms (names, products, jargon) |
| `cleanupProfiles` | `default` style plus `rules[{style, bundleIds, titleContains, urlContains}]` |
| `cleanupStyleOverride` | `auto` / `verbatim` / `tidy` — the menu-bar override |
| `speakerContext` | who the speaker is and how they speak; appended to the cleanup prompt inside `<context>` |
| `selectedMicUID` | input device |

Other files: history `~/.custom-wispr-history.json` (2000 entries; entries carry `style`,
`meta`, and `feedback` when you pressed F6), log `~/Library/Logs/CustomWispr.log`,
whisper-server log `/tmp/whisper-server.log`.

## Usage

1. Press **F5** (or **⌘⌥Space**), talk, press it again. The overlay shows Listening → Transcribing → Cleaning up, then the text is pasted.
2. **Cleanup style** in the menu bar switches between Auto (rules + default), Verbatim and Tidy.
3. **F6** (or menu bar → *Report issue with last dictation…*) opens the feedback window: pick the dictation, tick what went wrong, add notes, optionally paste the corrected text. ⌘↩ saves. Nothing leaves the machine; the log records only tags and lengths.
4. **Settings** holds find/replace rules (with *Suggest from History*), the mic picker and the cleanup-model catalog.

## Improvement loop

The app does not tune itself. The loop is: F6 flags (your ground truth) → monthly health
check reads them first, diagnoses the stage, proposes glossary / rule / prompt changes, and
promotes flagged dictations into a git-ignored real test set → `TUNING-LOG.md` records every
applied change with its baseline, and the next check fills in the follow-up. Applying
changes is manual on purpose.

- `health-check-routine.md` — the monthly procedure, run by a local Claude Code scheduled task
- `test-assets/ab_harness.py` — cleanup A/B harness (`--mode verbatim|tidy`, `--list-flagged`, `--promote all`); the synthetic set is `test-assets/cleanup-ab-set.json`, real passages live in `test-assets/cleanup-ab-real.json` (git-ignored, Anthropic models only, enforced in code)
- `TUNING-LOG.md` — change ↔ metric ↔ baseline ↔ follow-up

## Architecture

| File | Purpose |
|---|---|
| `main.swift` | App entry point |
| `AppDelegate.swift` | Pipeline orchestration: hotkeys, style resolution, recording, chunk chain, cleanup, history, paste |
| `Config.swift` | Reads `~/.custom-wispr.env`: modes, model, endpoints |
| `KeyMonitor.swift` | F5 / ⌘⌥Space record and F6 feedback hotkeys (Carbon) |
| `AudioRecorder.swift` | AVAudioEngine capture, pre-warm, pause-based chunk rotation |
| `WhisperService.swift` | whisper.cpp server client with glossary prompt and key-down warm-up (or OpenAI Whisper in cloud mode) |
| `AICleanupService.swift` | Verbatim and tidy prompts, speaker context, hesitation normalizer, refusal/rewrite guards, result metadata |
| `SettingsManager.swift` | Settings file: replacements, vocabulary, profiles, override, speaker context |
| `SettingsWindow.swift` | Settings UI and the cleanup-model catalog |
| `FeedbackWindow.swift` | F6 feedback window |
| `HistoryManager.swift` | History entries with `meta` and `feedback` |
| `HistorySuggester.swift` | "Suggest from History" find/replace candidates |
| `TextInjector.swift` | Paste via CGEvent Cmd+V with AppleScript fallback |
| `OverlayWindow.swift` | Floating status overlay |
| `WelcomeWindow.swift`, `UpdateChecker.swift` | Onboarding; update check is disabled in this fork |

## Fork differences from upstream

Upstream v1.6.0 is the last release reviewed. This fork adds everything under **Features**
above except the overlay and clipboard handling, replaces the fn-key CGEvent tap with a
Carbon hotkey, uses a local whisper.cpp server instead of the OpenAI Whisper API, and routes
cleanup through OpenRouter with a configurable model. Upstream releases are reviewed by the
monthly health check; most are "skip" or "port", not "adopt".

## Troubleshooting

**⌘⌥Space opens a Finder search window as well** — untick System Settings → Keyboard → Keyboard Shortcuts → Spotlight → "Show Finder search window"; macOS delivers that shortcut to both.

**F5 does nothing** — check the log for `Key monitor started successfully`; if two instances are running, quit both and relaunch. Make sure Accessibility is granted.

**First dictation after a long idle is slow** — the warm-up should cover it (`Whisper warm-up done in …` in the log). If every dictation is slow, check whether a build or another heavy job is running; whisper shares the GPU.

**Pasted text is raw / overlay shows ⚠** — cleanup fell back; the reason is in the overlay and the log (`API key rejected`, `out of credit`, `rate limited`, `cleanup timed out`). Check the key in `~/.custom-wispr.env` and the OpenRouter balance.

**Names come out wrong** — add them to `vocabulary` (whisper glossary) or as a find/replace rule, and press F6 so the monthly check sees it.

**Text doesn't paste** — Accessibility permission, and a focused text field.

**Build fails** — Xcode Command Line Tools; the `CustomWispr Dev` certificate must be in the login keychain or the script falls back to ad-hoc signing (and Accessibility will have to be re-granted).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Note that this fork is tuned for one user; upstream is the place for general features.

## License

[MIT](LICENSE)
