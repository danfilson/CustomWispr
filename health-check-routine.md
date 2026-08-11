# CustomWispr Monthly Health Check — Procedure

Followed by the scheduled monthly routine. Keep this file as the single source of truth
for what the routine does; edit here, not in the scheduled-task prompt.

## Context

- Source: `~/Projects/BW/customwispr/` (fork of `beausterling/CustomWispr`)
- Installed: `/Applications/CustomWispr.app`, config `~/.custom-wispr.env` (contains the OpenRouter key as OPENAI_API_KEY)
- History: `~/.custom-wispr-history.json` (raw + cleaned text, newest first)
- Whisper server: launchd `com.personal.whisper-server` → whisper.cpp on port 8090, model pinned in `~/Library/LaunchAgents/com.personal.whisper-server.plist` (must be `ggml-large-v3-turbo.bin`)
- Server log: `/tmp/whisper-server.log`
- State between runs: `~/Projects/BW/customwispr/.health-check-state.json` (last upstream release tag seen, last run date)
- Fork knowledge: Obsidian → `06-client-knowledge/Bubble Wrap/CustomWispr.md`
- Fork customizations upstream does NOT have: streaming chunked transcription with prompt chaining + seam dedupe, pre-warmed audio engine, Carbon RegisterEventHotKey (Tahoe fix), stable `CustomWispr Dev` signing cert, local whisper + configurable cleanup models, find/replace + history suggester.

## Guardrails

- READ-ONLY toward app config and system: propose changes in the report; do not apply them.
- NEVER run `tccutil reset` (destroys the TCC entry — see vault note).
- Only restart the whisper-server if it is actually down (`curl -s http://127.0.0.1:8090` fails): `launchctl kickstart gui/501/com.personal.whisper-server`.
- A/B test budget: abort the A/B section if estimated spend exceeds $0.50.
- Real dictation content stays in this session's analysis only — never send history text to non-Anthropic models. The A/B test uses ONLY `test-assets/cleanup-ab-set.json`.

## Sections (all results go in the report)

### 1. Infrastructure check
- whisper-server: process up, correct model in plist AND in `ps` output, port 8090 healthy.
- Speed regression test: transcribe a ~10s generated clip (`say` → `afconvert` to 16kHz mono WAV → POST /inference); flag if it takes > 4s (baseline ~2s).
- App: CustomWispr running, signed by `CustomWispr Dev` (`codesign -dvv`).
- Orphaned `custom-wispr_*` files in the app's temp dir = failed dictations since last launch — count and flag.
- Disk: models dir size, history file size (2000-entry cap means it self-limits — raised from 500 on 2026-08-11 so the file holds ~6 months rather than ~6 weeks).

### 2. Upstream release review
- `curl -s https://api.github.com/repos/beausterling/CustomWispr/releases` — releases newer than `last_seen_tag` in the state file.
- For each: summarize changes, then assess against the fork customizations listed above. Verdict per release: **adopt** (cherry-pick worth it), **port** (idea worth reimplementing), or **skip** (conflicts with or is inferior to our fork). Be skeptical — most upstream changes will conflict with the streaming pipeline.
- Update the state file with the newest tag seen.

### 3. Usage & accuracy analysis (real history — this session only)
- Load history entries from the last month. Compute: dictation count, total words, avg words/dictation, empty-transcription count.
- Scan raw texts for: recurring misrecognitions (same wrong word ≥2 times → propose a find/replace rule, checking it isn't already in `~/.custom-wispr-settings.json` replacements); garbled runs (candidate chunk-boundary artifacts — note timestamps); sentences that end mid-thought (trailing-off signal).
- Propose find/replace additions in the report — do NOT edit the settings file.
- **Silent-cleanup canary (report this every run, even when it is 0%).** For every entry ≥30 chars, check whether `cleanedText` is byte-identical to `rawText` **and** the raw text has a defect a working cleanup must fix (starts lowercase, or ends with no terminal punctuation). Identical *with* an unfixed defect proves the LLM never touched that dictation. Report the rate for the current month and the previous one.
  - Healthy is **0%** — that is the observed value in every known-working window.
  - **>5% ⇒ 🔴 action needed**, cleanup is silently failing. A dead API key produced a 7-week outage (late May → 2026-07-14, ~300 dictations, ~30k words) that went unnoticed because nothing surfaced it. This single check is what would have caught it in week one; the overlay reporting added in `d814d4d` only covers failures the app itself sees.

### 4. Cleanup spend
- `GET https://openrouter.ai/api/v1/auth/key` with the OpenRouter key → usage figures.
- **Key expiry — escalate, don't just note it.** Read `expires_at` from that response and report days remaining.
  - **< 60 days ⇒ 🔴 action needed** and it leads the Actions table. A dead key is the single highest-consequence failure this app has (see the canary in §3); an expiry date is the one form of it that is knowable in advance, so it must never be reported as a passive observation. Current key expires **2026-10-12**.
  - Also `GET /api/v1/credits` for the account balance — flag under $5, since an exhausted balance fails identically to a dead key.
- Cross-estimate: last month's history volume × current cleanup model pricing (input ≈ raw chars/4 tokens + ~350-token system prompt per call; output ≈ cleaned chars/4).
- Report monthly spend and $/dictation.

### 5. Cleanup model A/B (synthetic set only)
- **Use the committed harness — do not write a new one.** `python3 test-assets/ab_harness.py` reads the frozen set, extracts the system prompt verbatim from `Sources/AICleanupService.swift`, reads the model list from the Settings catalog in `SettingsWindow.swift` (so a dead catalog entry surfaces here), scores per the JSON `scoring` block, and enforces the budget ceiling itself.
  - `--dry-run` first for the call count and cost estimate; then a plain run; then `--reps 3` on the top 2–3 only.
  - It holds a 10-minute run-lock. If it refuses, the sweep already ran — read the output rather than passing `--force`. The 2026-08 run billed for three sweeps instead of two because a re-import silently re-executed the whole thing.
  - Add candidate models with `--models`; if one is worth keeping, add it to the Settings catalog rather than to the harness.
- Add newly cheap notable OpenRouter models to the candidate list each run.
- Table + recommendation. Only recommend switching if a model beats the current one on cost with ≥ equal preservation (preservation is the priority). **State the margin and the set size** — on 25 passages a sub-0.5pp preservation gap is not a result, and latency or cost should carry the decision instead.
- Scoring set is at **v2** (2026-08-11): `umm` counts as filler, and dropping an adjacent verbatim repeat is not a paraphrase failure. **Paraphrase-failure counts do not compare across the v1/v2 boundary**; preservation and filler-removal percentages do. Never edit an existing passage — add new ones with new ids.

### 6. Speech-pattern observations (coaching, not judgment)
- From the same history sample: disfluency rate trend vs previous report, dictation-length distribution, any pattern in where content seems weakest (e.g., ends of long dictations → trailing off quietly; Whisper drops mumbled trailing speech at the model level).
- 1–2 concrete, actionable observations max.

### 7. Deliver the report
- Full report → Obsidian note `06-client-knowledge/Bubble Wrap/CustomWispr Health Checks/<YYYY-MM>.md` (create folder if missing). Frontmatter: `type: health-check, project: CustomWispr, date: <run date>`.
- Email summary (5–10 lines: verdicts + anything needing action) to danielfilson@gmail.com via the google-workspace MCP. If only drafting is available, create the draft and say so in the note.
- Lead the report with a one-line status: 🟢 all good / 🟡 attention suggested / 🔴 action needed.
