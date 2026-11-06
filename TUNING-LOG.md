# Tuning log

Every deliberate change to the dictation pipeline, with the number it was meant to move and
what that number did afterwards. The monthly health check fills in the **Follow-up** column
(read `health-check-routine.md` §3, "Tuning log follow-ups"); an entry without a follow-up
after two reports is a change nobody verified. Keep rows terse; the full story is in the
Obsidian note (`06-client-knowledge/Bubble Wrap/CustomWispr.md`).

Columns: Date · Change · Metric to watch (how it is measured) · Baseline (before) · Follow-up (date: value → verdict)

| Date | Change | Metric to watch | Baseline | Follow-up |
|---|---|---|---|---|
| 2026-11-05 | Whisper glossary prompt (`vocabulary`, 24 terms) on every chunk | Proper-noun misspellings: F6 `wrong-words` flags per 100 dictations; capitalized-token proposals in §3 | Live 5-name test 2/5 correct before, 5/5 after | |
| 2026-11-05 | Key-down warm-up of the whisper model (`warmup.wav`) | p90 `meta.totalSec` by idle gap (>1 h bucket) | p90 15 s after >1 h idle vs 3 s otherwise (log, Oct–Nov) | |
| 2026-11-05 | Cleanup model → `anthropic/claude-sonnet-5.5` (both styles) | Harness: verbatim preservation / tidy judge axes, hallucinations; monthly real-sample judge | v5 set: verbatim 100/100/100; tidy fid 9.8 cmp 9.7 int 9.8 cln 9.7 voice 9.3, 0 hallucinations | |
| 2026-11-05 | Hesitation-ellipsis normalizer + verbatim prompt rule | Residual `...` in cleaned text per month (target 0) | Ellipses passed through verbatim output in live tests on 11-05 | |
| 2026-11-05 | Tidy style + app profiles + retraction rules in the tidy prompt | Real-sample judge completeness/intent for tidy; F6 `over-cleaned` + `dropped-content` flags | Synthetic v5 only (above); no real-sample baseline yet | |
| 2026-11-05 | Speaker context incl. speaking-style profile (903 chars) | Judge voice + completeness, with vs without context | Harness A/B a wash overall; passage 29 completeness +3, voice +4 | |
| 2026-11-05 | Tidy is the default style for every app | F6 `dropped-content` / `over-cleaned` flags per 100 dictations in the first month; tidy share of dictations | Tidy was email-only; ~0 % of dictations | |
| 2026-11-06 | F6 feedback window + per-dictation `meta` in history | Flags per 100 dictations (any tag); share of entries with `meta` | 0 flagged entries; no entry has `meta` before 2026-11-06 14:51 | |
