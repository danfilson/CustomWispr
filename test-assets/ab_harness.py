#!/usr/bin/env python3
"""Cleanup-model A/B harness for the monthly CustomWispr health check.

Committed on 2026-08-11. Before that this was rewritten from scratch every run,
which is how the 2026-08 check billed for three sweeps instead of two: the module
was re-imported for the stability run and re-executed its top-level sweep. Hence
the entry-point guard and the run-lock below — both exist for that reason, do not
remove them.

Usage:
    python3 test-assets/ab_harness.py --dry-run           # cost estimate, no calls
    python3 test-assets/ab_harness.py                     # single sweep, catalog models
    python3 test-assets/ab_harness.py --reps 3 --models anthropic/claude-haiku-4-5,...
    python3 test-assets/ab_harness.py --budget 0.50       # abort ceiling (default 0.50)

Privacy: this harness reads ONLY test-assets/cleanup-ab-set.json. It must never be
pointed at ~/.custom-wispr-history.json — real dictation content does not go to
non-Anthropic models (health-check-routine.md, Guardrails).
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AB_SET = REPO / "test-assets" / "cleanup-ab-set.json"
CLEANUP_SRC = REPO / "Sources" / "AICleanupService.swift"
SETTINGS_SRC = REPO / "Sources" / "SettingsWindow.swift"
ENV_FILE = Path.home() / ".custom-wispr.env"
RUN_LOCK = Path("/tmp/customwispr-ab-harness.lock")

FILLERS = {"um", "umm", "uh", "er", "ah", "hmm"}
API = "https://openrouter.ai/api/v1"

# ggml-large-v3-turbo is the multilingual model and emits British forms, more so with
# Daniel's accent: across 503 history entries `colour` survived into cleaned output 9/9
# times and -ise verbs were normalized only 5 of 14. The cleanup prompt now asks for
# American spelling, so the scorer must (a) not count an obeyed normalization as a word
# substitution, and (b) measure whether it happened at all.
BRITISH = {
    "colour": "color", "colours": "colors", "coloured": "colored",
    "favourite": "favorite", "behaviour": "behavior", "behaviours": "behaviors",
    "honour": "honor", "labour": "labor", "neighbour": "neighbor",
    "centre": "center", "centres": "centers", "metre": "meter", "theatre": "theater",
    "licence": "license", "defence": "defense", "offence": "offense",
    "grey": "gray", "programme": "program", "programmes": "programs",
    "catalogue": "catalog", "dialogue": "dialog",
    "analyse": "analyze", "analysed": "analyzed", "analysing": "analyzing",
    "organise": "organize", "organised": "organized", "organising": "organizing",
    "organisation": "organization", "realise": "realize", "realised": "realized",
    "recognise": "recognize", "recognised": "recognized",
    "summarise": "summarize", "summarised": "summarized",
    "optimise": "optimize", "optimised": "optimized",
    "maximise": "maximize", "minimise": "minimize",
    "apologise": "apologize", "apologising": "apologizing",
    "prioritise": "prioritize", "prioritised": "prioritized",
    "customise": "customize", "emphasise": "emphasize", "specialise": "specialize",
    "travelled": "traveled", "cancelled": "canceled", "modelling": "modeling",
    "labelled": "labeled", "fulfil": "fulfill", "enrol": "enroll",
    "practise": "practice", "sceptical": "skeptical",
}


# ---------------------------------------------------------------- extraction

def system_prompt() -> str:
    '''Reproduce the Swift multiline literal exactly as the compiler would.

    A Swift multiline string literal strips the indentation of its closing
    delimiter from every line, and a trailing backslash joins the next line
    without emitting a newline.
    '''
    src = CLEANUP_SRC.read_text()
    m = re.search(r'private let systemPrompt = """\n(.*?)\n(\s*)"""', src, re.S)
    if not m:
        raise SystemExit("could not locate systemPrompt in AICleanupService.swift")
    body, indent = m.group(1), m.group(2)
    out = []
    for line in body.split("\n"):
        out.append(line[len(indent):] if line.startswith(indent) else line.lstrip())
    text, joined = "", ""
    for line in out:
        if line.endswith("\\"):
            joined += line[:-1]
        else:
            text += joined + line + "\n"
            joined = ""
    return (text + joined).strip()


def catalog_models() -> list:
    """Read the model IDs the Settings UI actually offers, so the harness can't
    drift from the shipped catalog (a stale ID here is how a dead model survived
    two health checks)."""
    src = SETTINGS_SRC.read_text()
    return re.findall(r'modelId:\s*"([^"]+)"', src)


def api_key() -> str:
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("OPENAI_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"\'')
    raise SystemExit(f"no OPENAI_API_KEY in {ENV_FILE}")


def pricing() -> dict:
    with urllib.request.urlopen(f"{API}/models", timeout=30) as r:
        data = json.load(r)["data"]
    out = {}
    for m in data:
        p = m.get("pricing") or {}
        try:
            out[m["id"]] = (float(p.get("prompt", 0)), float(p.get("completion", 0)))
        except (TypeError, ValueError):
            pass
    return out


# ------------------------------------------------------------------- scoring

def tokens(text: str) -> list:
    return [t for t in re.findall(r"[a-z0-9']+", text.lower()) if t]


def collapse(seq: list, max_run: int = 6) -> list:
    """Drop adjacent verbatim repeats, whole phrases included.

    Per scoring v2 (2026-08-11) an immediately repeated word or phrase is not a
    paraphrase failure, so both sides are collapsed before comparison and the
    difference stops being counted. The repeat is a run, not a single word --
    "not the / not the" is the case that mattered -- so a word-level collapse is
    not enough. 6 words matches AppDelegate.joinDedupingOverlap's seam cap.
    """
    out = list(seq)
    i = 0
    while i < len(out):
        for k in range(min(max_run, (len(out) - i) // 2), 0, -1):
            if out[i:i + k] == out[i + k:i + 2 * k]:
                del out[i + k:i + 2 * k]
                break
        else:
            i += 1
    return out


def lcs_len(a: list, b: list) -> int:
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(cur[j], prev[j + 1]))
        prev = cur
    return prev[-1]


def americanize(seq: list) -> list:
    return [BRITISH.get(t, t) for t in seq]


NUMBER_WORDS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
    "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
    "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
}


def normalize_spoken(seq: list) -> list:
    """Fold the transcription conventions every model applies, so they stop being
    scored as word substitutions.

    Dictation says "large v three turbo" and "WCAG two point two double A"; every
    model writes "v3" and "2.2 AA". Counting that as content loss puts a constant
    offset in the preservation column for every model at once, which is exactly
    what the passage-12 false-start rule used to do -- it hides real regressions
    behind noise that never varies.
    """
    out = [NUMBER_WORDS.get(t, t) for t in seq]
    res = []
    i = 0
    while i < len(out):
        # "double A" -> "aa", "triple X" -> "xxx" (spoken letter convention)
        if out[i] in ("double", "triple") and i + 1 < len(out) and len(out[i + 1]) == 1:
            res.append(out[i + 1] * (2 if out[i] == "double" else 3))
            i += 2
            continue
        # "two point two" -> "2" "2": drop the decimal connector between digits
        if (out[i] == "point" and res and res[-1].isdigit()
                and i + 1 < len(out) and out[i + 1].isdigit()):
            i += 1
            continue
        res.append(out[i])
        i += 1
    return res


def merge_compounds(ref: list, got: list, max_span: int = 3) -> list:
    """Let a single output token stand for consecutive input tokens it concatenates.

    "weed maps" -> "Weedmaps" is the model writing a proper noun correctly, not
    dropping a word.
    """
    joined = set(got)
    out = []
    i = 0
    while i < len(ref):
        for span in range(min(max_span, len(ref) - i), 1, -1):
            if "".join(ref[i:i + span]) in joined:
                out.append("".join(ref[i:i + span]))
                i += span
                break
        else:
            out.append(ref[i])
            i += 1
    return out


def score(raw: str, cleaned: str) -> dict:
    src, out = tokens(raw), tokens(cleaned)
    # Normalize spelling on BOTH sides before comparing, so a model that obeys the
    # American-spelling rule isn't scored as having substituted a word.
    ref = collapse(normalize_spoken(americanize([t for t in src if t not in FILLERS])))
    got = collapse(normalize_spoken(americanize([t for t in out if t not in FILLERS])))
    ref = merge_compounds(ref, got)
    preservation = lcs_len(ref, got) / len(ref) if ref else 1.0
    in_fill = sum(1 for t in src if t in FILLERS)
    out_fill = sum(1 for t in out if t in FILLERS)
    return {
        "preservation": preservation,
        "fillers_in": in_fill,
        "fillers_left": out_fill,
        "paraphrase_fail": preservation < 1.0,
        "british_in": sum(1 for t in src if t in BRITISH),
        "british_left": sum(1 for t in out if t in BRITISH),
    }


# --------------------------------------------------------------------- calls

def clean_once(model: str, prompt: str, passage: str, key: str) -> tuple:
    body = json.dumps({
        "model": model,
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": f"<transcription>{passage}</transcription>"},
        ],
    }).encode()
    req = urllib.request.Request(
        f"{API}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=90) as r:
        data = json.load(r)
    latency = (time.time() - t0) * 1000
    text = data["choices"][0]["message"]["content"].strip()
    usage = data.get("usage") or {}
    return text, latency, usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)


def sweep(models, passages, prompt, key, price, reps, budget, verbose=False):
    spent, rows = 0.0, []
    for model in models:
        pin, pout = price.get(model, (0.0, 0.0))
        agg = {"preservation": [], "latency": [], "fails": 0, "fill_in": 0,
               "fill_left": 0, "brit_in": 0, "brit_left": 0, "errors": 0, "cost": 0.0}
        for _ in range(reps):
            for p in passages:
                if spent >= budget:
                    print(f"!! budget ${budget:.2f} reached — aborting sweep", file=sys.stderr)
                    return rows, spent
                try:
                    text, ms, ti, to = clean_once(model, prompt, p["text"], key)
                except Exception as e:  # noqa: BLE001 — one bad passage must not kill the sweep
                    agg["errors"] += 1
                    print(f"   {model} passage {p['id']}: {e}", file=sys.stderr)
                    continue
                cost = ti * pin + to * pout
                spent += cost
                agg["cost"] += cost
                s = score(p["text"], text)
                if verbose and s["preservation"] < 1.0:
                    print(f"    passage {p['id']:>2} {s['preservation'] * 100:6.2f}%\n"
                          f"      in : {p['text']}\n      out: {text}")
                agg["preservation"].append(s["preservation"])
                agg["latency"].append(ms)
                agg["fails"] += int(s["paraphrase_fail"])
                agg["fill_in"] += s["fillers_in"]
                agg["fill_left"] += s["fillers_left"]
                agg["brit_in"] += s["british_in"]
                agg["brit_left"] += s["british_left"]
        n = len(agg["preservation"]) or 1
        rows.append({
            "model": model,
            "preservation": 100 * sum(agg["preservation"]) / n,
            "filler_removal": 100 * (1 - agg["fill_left"] / agg["fill_in"]) if agg["fill_in"] else 100.0,
            "spelling_fixed": 100 * (1 - agg["brit_left"] / agg["brit_in"]) if agg["brit_in"] else None,
            "paraphrase_fails": agg["fails"] / max(reps, 1),
            "latency_ms": sum(agg["latency"]) / n,
            "errors": agg["errors"],
            "cost_per_1k": 1000 * agg["cost"] / n if n else 0.0,
            "spend": agg["cost"],
        })
        r = rows[-1]
        sp = "  n/a" if r["spelling_fixed"] is None else f"{r['spelling_fixed']:5.1f}%"
        print(f"  {model:42s} {r['preservation']:6.2f}%  fill {r['filler_removal']:5.1f}%  "
              f"spell {sp}  {r['latency_ms']:7.0f}ms  ${r['cost_per_1k']:.3f}/1k  err {r['errors']}")
    return rows, spent


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="CustomWispr cleanup-model A/B")
    ap.add_argument("--models", help="comma-separated; defaults to the Settings catalog")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--budget", type=float, default=0.50, help="abort ceiling in USD")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json-out", help="write full results here")
    ap.add_argument("--force", action="store_true", help="ignore the run-lock")
    ap.add_argument("--verbose", action="store_true",
                    help="print the input and output of every passage scoring below 100%%")
    a = ap.parse_args(argv)

    data = json.loads(AB_SET.read_text())
    passages = data["passages"]
    prompt = system_prompt()
    models = a.models.split(",") if a.models else [m for m in catalog_models()]

    print(f"set v{data['version']}: {len(passages)} passages x {len(models)} models "
          f"x {a.reps} rep(s) = {len(passages) * len(models) * a.reps} calls")
    print(f"prompt: {len(prompt)} chars extracted from AICleanupService.swift")
    if a.dry_run:
        print("\n".join(f"  - {m}" for m in models))
        return 0

    # Run-lock: a second invocation inside 10 minutes is almost certainly the
    # accidental re-run that doubled the 2026-08 A/B spend.
    if RUN_LOCK.exists() and not a.force:
        age = time.time() - RUN_LOCK.stat().st_mtime
        if age < 600:
            print(f"refusing: this harness ran {age / 60:.1f} min ago "
                  f"({RUN_LOCK}). Use --force if that was intentional.", file=sys.stderr)
            return 2
    RUN_LOCK.write_text(str(time.time()))

    key, price = api_key(), pricing()
    unknown = [m for m in models if m not in price]
    if unknown:
        print(f"!! not in the OpenRouter catalog, will 404: {', '.join(unknown)}", file=sys.stderr)

    rows, spent = sweep(models, passages, prompt, key, price, a.reps, a.budget, a.verbose)
    rows.sort(key=lambda r: (-r["preservation"], r["latency_ms"]))

    print(f"\n{'model':42s} {'preserv':>8s} {'filler':>7s} {'spell':>7s} {'fails':>6s} "
          f"{'latency':>9s} {'$/1k':>8s}")
    for r in rows:
        sp = "    n/a" if r["spelling_fixed"] is None else f"{r['spelling_fixed']:6.1f}%"
        print(f"{r['model']:42s} {r['preservation']:7.2f}% {r['filler_removal']:6.1f}% {sp} "
              f"{r['paraphrase_fails']:6.1f} {r['latency_ms']:8.0f}ms {r['cost_per_1k']:8.3f}")
    print(f"\nsweep spend: ${spent:.4f} of ${a.budget:.2f} ceiling")

    if a.json_out:
        Path(a.json_out).write_text(json.dumps(
            {"set_version": data["version"], "reps": a.reps, "spend_usd": spent, "results": rows},
            indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
