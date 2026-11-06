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
- Fork customizations upstream does NOT have: streaming chunked transcription with prompt chaining + seam dedupe, pre-warmed audio engine, Carbon RegisterEventHotKey (Tahoe fix), stable `CustomWispr Dev` signing cert, local whisper + configurable cleanup models, find/replace + history suggester, **whisper glossary prompt** (`vocabulary` in settings), **key-down warm-up** of the whisper model, **two cleanup styles** (verbatim / tidy; **tidy is the default everywhere since 2026-11-05**, verbatim only via the menu-bar override) chosen via `cleanupProfiles` (the email rules are now redundant but kept), **speaker context** (`speakerContext`, includes a speaking-style profile), hesitation-ellipsis normalization, judge-scored tidy harness, **F6 feedback window** (Daniel's own notes on a dictation, stored as `feedback` on the history entry) and per-dictation pipeline **`meta`** (app, model, prompt/context size, chunk count, timings, warm-up outcome, fallback) on every history entry since 2026-11-06, a git-ignored **real passage set** for the harness (`test-assets/cleanup-ab-real.json`, Anthropic models only) and a **`TUNING-LOG.md`** of every deliberate change with its baseline. Cleanup model is `anthropic/claude-sonnet-5.5` for both styles since 2026-11-05 (≈$3/month). Background: Obsidian note, "Recent changes (2026-11-05)".

## Guardrails

- READ-ONLY toward app config and system: propose changes in the report; do not apply them.
- NEVER run `tccutil reset` (destroys the TCC entry — see vault note).
- Only restart the whisper-server if it is actually down (`curl -s http://127.0.0.1:8090` fails): `launchctl kickstart gui/501/com.personal.whisper-server`.
- A/B test budget: abort the A/B section if estimated spend exceeds $0.50 for verbatim and $1.50 for tidy ($2.00 combined).
- Real dictation content stays in this session's analysis only — never send history text to non-Anthropic models. The A/B test uses ONLY `test-assets/cleanup-ab-set.json`.

## Sections (all results go in the report)

### 1. Infrastructure check
- whisper-server: process up, correct model in plist AND in `ps` output, port 8090 healthy.
- VAD: `--vad --vad-model …/ggml-silero-v5.1.2.bin --vad-speech-pad-ms 250` present in the plist AND in `ps` (added 2026-09-11 — without it large-v3-turbo returns "Thank you." for silent audio; verify with a 1.5s noise clip → `{"text":""}`).
- Speed regression test: transcribe a ~10s generated clip (`say` → `afconvert` to 16kHz mono WAV → POST /inference); flag if it takes > 4s (baseline ~2s).
- App: CustomWispr running, signed by `CustomWispr Dev` (`codesign -dvv`).
- Orphaned `custom-wispr_*` files in the app's temp dir = failed dictations since last launch — count and flag.
- Disk: models dir size, history file size (2000-entry cap means it self-limits — raised from 500 on 2026-08-11 so the file holds ~6 months rather than ~6 weeks).
- **Glossary + warm-up alive (added 2026-11-05):** every dictation in `~/Library/Logs/CustomWispr.log` should have a `Whisper glossary: N terms` line and most key-downs a `Whisper warm-up done in X.Xs`. Report the warm-up time distribution (p50/p90) and any `warm-up failed`. Zero glossary lines ⇒ 🔴 (the vocabulary isn't reaching whisper).
- **Latency by idle gap (the real slowness signal):** prefer `meta.totalSec` / `meta.whisperWaitSec` / `meta.cleanupSec` / `meta.warmUp` from history (exact, per dictation); fall back to the log for entries without `meta`. From the log, for each dictation compute key-up→`Injecting text` latency, the whisper share (stop → last `Chunk N transcribed`) and the idle gap since the previous dictation. Report p50/p90 in buckets <2 min / 2–15 / 15–60 / >1 h. Baseline before the warm-up: >1 h bucket p90 15 s vs 3 s otherwise. After: all buckets should be ≤5 s p90. Also list dictations whose whisper share exceeded 10 s with their timestamp — check whether a build or other heavy job was running (those are contention, not app faults).
- **Feedback + meta liveness:** count history entries this month with `meta` (should be ~100 %; a drop means a build regressed the history writer) and with `feedback` (any number is fine; zero for a whole month means F6 is not registering — check the log for `Feedback hot key registered (F6)` at the last launch).
- **Style resolution:** count dictations by `Cleanup style:` line (verbatim/tidy) and by bundle id; flag `url unreadable` or `title unreadable` if they recur for a browser (the Accessibility read is failing).

### 2. Upstream release review
- `curl -s https://api.github.com/repos/beausterling/CustomWispr/releases` — releases newer than `last_seen_tag` in the state file.
- For each: summarize changes, then assess against the fork customizations listed above. Verdict per release: **adopt** (cherry-pick worth it), **port** (idea worth reimplementing), or **skip** (conflicts with or is inferior to our fork). Be skeptical — most upstream changes will conflict with the streaming pipeline.
- Update the state file with the newest tag seen.

### 3. Usage & accuracy analysis (real history — this session only)
- Load history entries from the last month. Compute: dictation count, total words, avg words/dictation, empty-transcription count.
- Scan raw texts for: recurring misrecognitions (same wrong word ≥2 times → propose a find/replace rule, checking it isn't already in `~/.custom-wispr-settings.json` replacements); garbled runs (candidate chunk-boundary artifacts — note timestamps); sentences that end mid-thought (trailing-off signal).
- Propose find/replace additions in the report — do NOT edit the settings file.
- **Flagged dictations first (the correction signal, added 2026-11-06).** Entries with `feedback` are the only ground truth about what Daniel actually wanted; everything else in this section is a proxy. For each flagged entry this month (all of them if ≤20, else the 20 most recent): read `rawText`, `cleanedText`, `feedback.tags`, `feedback.note`, `feedback.correctedText` and `meta`; say which stage failed (whisper mis-hearing → glossary / find-replace proposal; cleanup dropped or changed something → quote the raw vs cleaned vs corrected span and name the prompt rule that should have caught it; `choppy` → chunk count and seam; `slow`/`hung` → `meta` timings and the log around that timestamp). Table: tag → count this month vs last, flags per 100 dictations. Then **promote every flagged entry not yet promoted** with `python3 test-assets/ab_harness.py --promote all` (local, no network; the real set is git-ignored and the harness only ever sends it to Anthropic models) and report how many the real set now holds. The next harness run scores the current prompt against those real failures; a passage whose judge scores are still low two months running is a prompt bug, not noise.
- **Tuning log follow-ups (added 2026-11-06):** open `TUNING-LOG.md`. For every row whose Follow-up cell is empty and whose change is ≥14 days old, measure the metric named in the row with this month's data and append `YYYY-MM-DD: <value> → held / improved / regressed / inconclusive` to that cell (this file is documentation, not app config, so writing to it is allowed). A regression goes in the Actions table. Say in the report which rows were filled.
- **Vocabulary & style proposals (the "learns over time" loop, added 2026-11-05):** from the month's raw texts, list (a) capitalized / non-dictionary tokens with ≥3 occurrences that are not in `vocabulary` or in a find/replace target → propose glossary additions; (b) retraction phrases and verbal tics per 1k words (scratch that / no wait / sorry, I meant / or rather / no, not / you know / kind of / I mean / right? / yeah, / "..." etc.) vs the previous report → propose additions to the tidy prompt's lists only if a new phrase appears ≥5 times; (c) anything in `speakerContext` that has gone stale; (d) for every flagged entry with `correctedText`, diff it against `cleanedText` word by word — a consistent substitution (a name, a product, a client) is a find/replace or glossary proposal with the evidence quoted. Propose only; Daniel applies. This step replaces the Settings → "Suggest from History" button for the loop; that button still works but nobody presses it.
- **Real-sample output quality (judge, added 2026-11-05):** sample 20 dictations ≥40 words from the month (stratified by style, newest-weighted) and score `cleanedText` against `rawText` with the harness judge rubric (`JUDGE_SYSTEM` + `JUDGE_MODEL` in `test-assets/ab_harness.py`, i.e. an Anthropic model via OpenRouter — the same route the cleanup itself already takes, so no new exposure; never a non-Anthropic model). Report per style: fidelity / completeness / intent / cleanliness / voice means, hallucination count, dropped-items list. Any hallucination ⇒ 🔴 with the passage quoted in the report (report only, never emailed). Cost ≈ $0.10.
- **Ellipsis check:** residual "..." per 1k words in `cleanedText` (normalizer + prompt rule added 2026-11-05; raw baseline was 21/1k, cleaned should be ≈0).
- **Split every accuracy metric by `style`** (history entries carry it from 2026-11-05); tidy is expected to shrink text ~15–20% and that is not content loss.
- **Silent-cleanup canary (report this every run, even when it is 0%).** For every entry ≥30 chars, check whether `cleanedText` is byte-identical to `rawText` **and** the raw text has a defect a working cleanup must fix (starts lowercase, or ends with no terminal punctuation). Identical *with* an unfixed defect proves the LLM never touched that dictation. Report the rate for the current month and the previous one.
  - Healthy is **0%** — that is the observed value in every known-working window.
  - **Canary v2 (per-day rule, added 2026-11-05):** also flag any single day with ≥10 entries where ≥90% are identical-with-defect — the aggregate rule under-read a 100%-identical two-day outage in October.
  - **>5% ⇒ 🔴 action needed**, cleanup is silently failing. A dead API key produced a 7-week outage (late May → 2026-07-14, ~300 dictations, ~30k words) that went unnoticed because nothing surfaced it. This single check is what would have caught it in week one; the overlay reporting added in `d814d4d` only covers failures the app itself sees.

### 4. Cleanup spend
- `GET https://openrouter.ai/api/v1/auth/key` with the OpenRouter key → usage figures.
- **Key expiry — escalate, don't just note it.** Read `expires_at` from that response and report days remaining.
  - **< 60 days ⇒ 🔴 action needed** and it leads the Actions table. A dead key is the single highest-consequence failure this app has (see the canary in §3); an expiry date is the one form of it that is knowable in advance, so it must never be reported as a passive observation. Current key expires **2027-01-12** (re-minted 2026-10-13).
  - Also `GET /api/v1/credits` for the account balance — flag under $5, since an exhausted balance fails identically to a dead key.
- **Exact spend from history (since 2026-11-06):** sum `meta.costUSD` over the month's entries; report cache hit rate (`meta.cachedTokens > 0` share) and the cost per dictation with and without a cache hit. Prompt caching (Anthropic, 1 h TTL) was enabled 2026-11-06; a hit rate under 85 % or a write share over 15 % means dictations are spaced out more than expected and the TTL choice should be revisited. Fallback cross-estimate for older entries: raw chars/4 + ~1,530-token tidy system prompt (measured 2026-11-06 incl. the speaker context) per call; output ≈ cleaned chars/4.
- Report monthly spend and $/dictation.

### 5. Cleanup model A/B (synthetic set only)
- **Use the committed harness — do not write a new one.** `python3 test-assets/ab_harness.py` reads the frozen set, extracts the system prompt verbatim from `Sources/AICleanupService.swift`, reads the model list from the Settings catalog in `SettingsWindow.swift` (so a dead catalog entry surfaces here), scores per the JSON `scoring` block, and enforces the budget ceiling itself.
  - `--dry-run` first for the call count and cost estimate; then a plain run; then `--reps 3` on the top 2–3 only.
  - **Tidy mode too (added 2026-11-05):** `python3 -u test-assets/ab_harness.py --mode tidy` — judge-scored (fidelity / completeness / intent / cleanliness / voice, hallucinations, proper-noun retention), default candidates are the catalog, default budget $1.50, prices read live from OpenRouter. The harness appends `speakerContext` exactly as the app does (`--no-context` / `--context-file` to A/B a context change). Rank by hallucinations first; a model with any hallucination is disqualified for tidy regardless of cost. Combined A/B ceiling for the run: **$2.00**. Both modes also load `test-assets/cleanup-ab-real.json` (promoted F6 entries) and skip those passages for non-Anthropic candidates automatically; report real-passage scores separately from synthetic ones (`--no-real` for a pure synthetic run). A real passage with a `reference` (Daniel's corrected text) is judged against that reference.
  - It holds a 10-minute run-lock. If it refuses, the sweep already ran — read the output rather than passing `--force`. The 2026-08 run billed for three sweeps instead of two because a re-import silently re-executed the whole thing.
  - Add candidate models with `--models`; if one is worth keeping, add it to the Settings catalog rather than to the harness.
- Add newly cheap notable OpenRouter models to the candidate list each run.
- Table + recommendation. Only recommend switching if a model beats the current one on cost with ≥ equal preservation (preservation is the priority). **State the margin and the set size** — on 27 passages a sub-0.5pp preservation gap is not a result, and latency or cost should carry the decision instead.
- Scoring set is at **v4** (all three bumps 2026-08-11; only v4 has produced a recorded result).
  - **v2** — `umm` counts as filler; dropping an adjacent verbatim repeat is not a paraphrase failure.
  - **v3** — `spelling_fixed %` axis for the American-English rule, scored separately from preservation, with spelling normalized on both sides so obeying the rule is never scored as a word substitution.
  - **v4** — spoken numerals (`v three` → `v3`, `two point two double A` → `2.2 AA`) and compound proper nouns (`weed maps` → `Weedmaps`) are folded before comparison. These produced 3 false failures out of 27 on the first live run.
  - **Comparability:** paraphrase-failure counts do not compare across the v1/v2 or v3/v4 boundaries. Preservation and filler-removal compare throughout; `spelling_fixed` starts at v3.
  - Never edit an existing passage — add new ones with new ids.
- **The recurring failure mode in this benchmark is a constant offset.** Three times now a scoring rule has penalised every model identically — false starts (v2), obeyed spelling normalization (v3), spoken numerals (v4). A metric that fails the whole field tells you nothing and hides real regressions behind noise that never varies. When every model fails the same passage, suspect the rule before the models.
- **Report `spelling_fixed` per model.** The models handle this rule inconsistently — before it was added to the prompt, cleanup left `colour` untouched 9/9 times and normalized `-ise` verbs only 5 of 14. A model that scores well on preservation but poorly here is not a good default.

### 6. Speech-pattern observations (coaching, not judgment)
- From the same history sample: disfluency rate trend vs previous report, dictation-length distribution, any pattern in where content seems weakest (e.g., ends of long dictations → trailing off quietly; Whisper drops mumbled trailing speech at the model level).
- 1–2 concrete, actionable observations max.

### 7. Deliver the report
- Full report → Obsidian note `06-client-knowledge/Bubble Wrap/CustomWispr Health Checks/<YYYY-MM>.md` (create folder if missing). Frontmatter: `type: health-check, project: CustomWispr, date: <run date>`.
- Email summary (5–10 lines: verdicts + anything needing action) to danielfilson@gmail.com via the google-workspace MCP. If only drafting is available, create the draft and say so in the note.
- Lead the report with a one-line status: 🟢 all good / 🟡 attention suggested / 🔴 action needed.
- **Run metadata (added 2026-11-05):** state the model that ran this check (from the session), the run date, total A/B + judge spend, and which sections were skipped and why. This is how Daniel audits the checker itself.
