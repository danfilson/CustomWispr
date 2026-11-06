# CustomWispr Session Handoff — 2026-06-08

> **Update 2026-11-06:** tidy is now the default style everywhere. **⌘⌥M** is a second record toggle (built-in keyboard; fn+F5 does not reach the Carbon hotkey). It consumes the front app's "Minimize All" shortcut, which is acceptable. **F6** opens a feedback window on the last dictations (tags + notes + optional corrected text → `feedback` on the history entry); every history entry now carries `meta` (app, model, prompt/context size, chunks, timings, warm-up outcome, fallback). `ab_harness.py --list-flagged` / `--promote all` copy flagged entries into a git-ignored real set that the harness sends to Anthropic models only. `TUNING-LOG.md` tracks every change with a baseline; the monthly check fills in follow-ups, reviews flagged entries first and promotes them. See health-check-routine.md §1/§3/§5.

> **Update 2026-11-05:** accuracy/latency review actioned. Whisper now gets a **glossary prompt** (`vocabulary` in settings) on every chunk and a **warm-up request at key-down** (model page-in moved off the paste path). Added a **tidy cleanup style** (now the **default** for every app; verbatim via menu bar → Cleanup style) with app-aware profiles (`cleanupProfiles`), **speaker context**, a refreshed model catalog, and a judge-scored `--mode tidy` in the A/B harness. Cleanup model switched to `anthropic/claude-sonnet-5.5` for both styles (first tidy sweep: 0 hallucinations, 98% name retention, ≈$3/mo). Full write-up: Obsidian → `06-client-knowledge/Bubble Wrap/CustomWispr.md`, "Recent changes (2026-11-05)".

> **Update 2026-07-04:** Open issues A and C below are RESOLVED.
>
> - **Issue C (model not persisted):** confirmed as the cause of the quality regression — a reboot reverted the server to `base.en`. The launchd plist now pins `ggml-large-v3-turbo.bin` with `--threads 8`. Benchmarked: more accurate than base.en on proper nouns AND ~7× faster (Metal); an 83.6s clip transcribes in 9.4s.
> - **Issue A (garbage transcription):** the suspected sample-rate mismatch was right; the `AVAudioConverter` now in `AudioRecorder.swift` downsamples native rate → 16kHz. Resolved before this update.
> - Also fixed today: `WhisperService` idle timeout 30s → 120s (long dictations were being aborted mid-transcription and lost — see `/tmp/whisper-server.log` "client disconnected"); failed dictations now keep their audio file for recovery; `build-arm64.sh` footer no longer recommends the destructive `tccutil reset`.
> - **Issue B (`AXIsProcessTrusted()` false): RESOLVED as of 2026-07-05** — after rebuilds under the stable cert, trust reports true again. The TextInjector gate was intentionally not restored; attempt-then-fallback is more robust than gating on this API.
> - **2026-07-05:** `AudioRecorder` now pre-warms the engine at launch and after each recording (F5 → `engine.start()` only), with a "Starting..."→"Listening..." overlay cue driven by the first real audio buffer. Reduces first-word clipping; full pre-roll ring buffer deliberately deferred.
>
> Details: Obsidian → `06-client-knowledge/Bubble Wrap/CustomWispr.md`, "Recent changes (2026-07-04)".
>
> **Update 2026-07-07: streaming transcription shipped.** Recording is chunked at sustained pauses (15–30s chunks) and each chunk transcribes while the user is still dictating, with prompt chaining across boundaries; only the short final chunk remains after key-up. Live-tested: 48s dictation → text injected 1s after key-up. See the 2026-07-07 section of the Obsidian note for design and gotchas (esp. why cuts require a sustained pause, not a single quiet buffer).

## What was done this session

### 1. Audio engine upgrade (from upstream v1.5.1)
- **Branch:** `upgrade/audio-engine-v1.5` (based off `main`)
- **Commits:** 3 commits on the branch
  - `7d9bac1` — Baseline: fork state before changes
  - `e119b83` — AVAudioEngine upgrade + mic picker + SettingsManager changes
  - `5f052d8` — Fix: WAV for local mode, AAC for cloud; remove AXIsProcessTrusted gate

### 2. Changes made
- **AudioRecorder.swift** — Replaced `AVAudioRecorder` with `AVAudioEngine` + tap. Records WAV (16kHz mono PCM) when `Config.transcriptionMode == .local`, AAC when cloud. Added CoreAudio device selection APIs (mic locking, built-in fallback, device enumeration).
- **SettingsManager.swift** — Added `selectedMicUID` persistence. Made JSON loading resilient (doesn't crash if `replacements` key missing).
- **SettingsWindow.swift** — Added Microphone tab (tab 3) with live device picker via CoreAudio listener. Conforms to `NSWindowDelegate` now.
- **WhisperService.swift** — Local whisper path sends `audio.wav` / `Content-Type: audio/wav` (unchanged from original).
- **TextInjector.swift** — Removed `AXIsProcessTrusted()` gate on CGEvent paste. Now attempts CGEvent regardless and falls back to AppleScript.

### 3. Whisper server model change
- Changed from `ggml-base.en.bin` to `ggml-small.en.bin` by restarting the server process manually.
- **This is NOT persisted** — if the whisper server restarts (reboot, launchd), it will revert to whatever the launchd plist or startup script specifies. Need to update that.

## Open issues — MUST FIX

### A. Transcription quality is poor
The user reports whisper.cpp is returning garbage like "(mumbling)", "(muffled voice)", "[Growling]", "(sighs)" instead of actual transcribed text. This was NOT a problem before the audio engine upgrade.

**Root cause investigation needed:**
- The old `AVAudioRecorder` recorded at fixed 16kHz mono — exactly what whisper.cpp expects.
- The new `AVAudioEngine` records WAV but at the mic's **native sample rate** (likely 48kHz on MacBook Air M4). whisper.cpp may struggle with non-16kHz input even though it technically accepts it.
- Check: does `AVAudioFile` with 16kHz WAV settings actually downsample from the engine's native rate? Or does it fail/produce garbage? The engine tap delivers buffers in the input node's output format — writing those to a 16kHz file may cause a format mismatch.
- **Likely fix:** Add an `AVAudioConverter` to downsample from native rate to 16kHz before writing to the WAV file, OR use `AVAudioEngine`'s `inputNode.installTap` with a converted format.

### B. AXIsProcessTrusted() returns false
- System Settings shows CustomWispr toggle ON in Accessibility
- `AXIsProcessTrusted()` still returns `false`
- The stable signing cert (`CustomWispr Dev`) is present and being used
- We ran `tccutil reset Accessibility com.personal.custom-wispr` earlier which may have corrupted the TCC state
- Paste currently works because we removed the gate, but this is a workaround
- **Try:** Remove CustomWispr from Accessibility list, rebuild (which re-deploys to /Applications), then re-add `/Applications/CustomWispr.app` specifically

### C. Whisper server startup not persisted
- Server was manually restarted with `small.en` model
- Check for a launchd plist or startup script that starts whisper-server and update the model path there

## Key files and paths
- **Source:** `~/Projects/BW/customwispr/`
- **Installed:** `/Applications/CustomWispr.app`
- **Config:** `~/.custom-wispr.env`
- **Settings:** `~/.custom-wispr-settings.json`
- **Whisper models:** `~/.local/share/whisper-models/`
- **Obsidian doc:** Search "CustomWispr" in vault — comprehensive troubleshooting guide
- **Memory files:** `~/.claude/projects/-Users-danielfilson-Projects/memory/` — see `feedback_customwispr_*.md`

## Rollback

> **Updated 2026-08-11:** `upgrade/audio-engine-v1.5` has been merged into `main`, so
> `git checkout main` no longer reverts anything. The pre-merge state is preserved as the
> tag `pre-streaming`.

```bash
cd ~/Projects/BW/customwispr
git checkout pre-streaming
bash build-arm64.sh
```
This fully reverts to the pre-upgrade state with the old AVAudioRecorder engine.
Return with `git checkout main && bash build-arm64.sh`.

To revert only the cleanup model without a rebuild, edit `CLEANUP_MODEL` in
`~/.custom-wispr.env` (back to `anthropic/claude-haiku-4-5`) and restart the app —
Settings → API Key does the same thing from the UI.

## Context from Obsidian doc (key points)
- Carbon `RegisterEventHotKey` is the correct hotkey approach for Tahoe (CGEvent tap and NSEvent monitor are broken)
- Stable code signing cert `CustomWispr Dev` preserves TCC across rebuilds — do NOT run `tccutil reset` with this cert
- The build script deploys to `/Applications/` and relaunches from there
- `build-arm64.sh` has the full source file list including `HistoryManager.swift` and `HistorySuggester.swift`
