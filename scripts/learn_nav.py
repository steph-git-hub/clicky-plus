#!/usr/bin/env python3
"""
learn_nav.py — v1.0 (2026-08-24)

Closes the loop on Marin's nav list: finds the times Steph had to ask more than
once to reach a destination, works out where he ACTUALLY ended up, and writes an
alias so the phrase that failed works next time.

Fully autonomous by design — Steph explicitly does not want a review queue
(2026-08-24). Safety comes from three properties instead:

  1. ADDITIVE ONLY. Aliases never remove or rewrite anything. A bad alias makes
     one phrase route oddly; the next run sees that thrash and corrects it.
  2. SEPARATE FILE. Writes ONLY marin-nav-aliases.yaml. It never opens
     marin-nav-pins.yaml, which is hand-owned by Steph.
  3. GIT IS THE BACKSTOP. config/ is committed, so every autonomous change is a
     reviewable diff — available if he wants it, ignorable if he doesn't.

THE KEY IDEA — dwell time, not sequence order.
Naive "the last URL he opened is the right one" breaks on the case Steph called
out: if Marin keeps missing, he gives up and opens it himself, and her last wrong
guess would get learned as correct. So the winner is the destination with the
LONGEST DWELL in the window, no matter who opened it. Measured on the real
2026-08-24 planogram episode: wrong answers dwelled 2.0s / 11.6s / 21.2s, the
right one 406.7s. Not a subtle gap.

Three outcomes, never two:
  CONVERGED  — winner is Marin's last open. Learn the failed phrases -> winner.
  MANUAL_FIX — winner is a URL Marin never opened, i.e. he gave up and did it
               himself. Still learn it; this is the most valuable signal there
               is, because it names the destination Marin couldn't reach at all.
  ABANDONED  — nothing dwelled long enough. Learn NOTHING. Logged, not acted on.
"""

import datetime
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, "clicky-plus/config")
LOGDIR = os.path.join(HOME, "Library/Application Support/Clicky/action-log")
TOOLS_LOG = os.path.join(LOGDIR, "marin-tools.log")
ACTIONS_LOG = os.path.join(LOGDIR, "marin-actions.log")
CHROME = os.path.join(HOME, "Library/Application Support/Google/Chrome/Profile 2")
VAULT = os.path.join(HOME, "Desktop/Claude Cowork/Obsidian/Steph Vault")
TRANSCRIPTS = os.path.join(VAULT, "Clicky Transcripts")
ALIASES = os.path.join(CONFIG, "marin-nav-aliases.yaml")
JOURNAL = os.path.join(CONFIG, "marin-nav-learning.log")

LOOKBACK_DAYS = 8          # a week plus a day of overlap
EPISODE_GAP_S = 90         # two nav attempts inside this = one episode
TAIL_S = 90                # how far past the last attempt to look for the winner
                           # Deliberately SHORT. At 300s the 2026-08-24 planogram
                           # episode was lost: he resolved it at 17:30:42, moved on
                           # to the Amazon dashboard at 17:34, and that unrelated
                           # background tab's 1406s dwell outranked the real answer
                           # (406s). A long tail doesn't find more truth, it finds
                           # the NEXT task.
MIN_DWELL_S = 60           # winner must hold attention this long
DOMINANCE = 5.0            # ...and beat the runner-up by this factor
ALIAS_TTL_DAYS = 90        # an alias unused this long is dropped

EPOCH = datetime.datetime(1601, 1, 1)


def log(msg):
    print(f"[learn_nav] {msg}", file=sys.stderr)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


# ------------------------------------------------------------------ log parsing

TS = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z\]\s*(.*)$")
SET_URL = re.compile(r'set URL of .*? to "([^"]+)"')
NAV_TOOLS = ("run_applescript", "open_drive_file", "read_memory_file")


def parse_tools_log(since):
    """[(dt_utc, tool, detail)] — nav-relevant tool calls only."""
    out = []
    if not os.path.exists(TOOLS_LOG):
        log(f"WARNING: no {TOOLS_LOG}")
        return out
    for line in open(TOOLS_LOG, encoding="utf-8", errors="replace"):
        m = TS.match(line.strip())
        if not m:
            continue
        when = datetime.datetime.fromisoformat(m.group(1))
        if when < since:
            continue
        rest = m.group(2)
        tool = rest.split(" ", 1)[0].split("=", 1)[0].strip()
        if tool not in NAV_TOOLS:
            continue
        out.append((when, tool, rest))
    return out


def parse_actions_log(since):
    """{dt_utc: url} — what Marin actually opened, so we can tell her opens from his."""
    out = {}
    if not os.path.exists(ACTIONS_LOG):
        return out
    pending = None
    for line in open(ACTIONS_LOG, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        m = TS.match(line.strip())
        if m:
            when = datetime.datetime.fromisoformat(m.group(1))
            pending = when if when >= since else None
            continue
        if pending:
            u = SET_URL.search(line)
            if u:
                out[pending] = u.group(1)
                pending = None
    return out


def canon(url):
    """Same collapsing rule harvest_nav.py uses — one destination, one key."""
    m = re.match(r"^(https://docs\.google\.com/(?:spreadsheets|document|presentation)/d/[A-Za-z0-9_-]+)", url or "")
    if m:
        return m.group(1) + "/edit"
    m = re.match(r"^(https://app\.clickup\.com/[0-9]+/(?:v/dc/[A-Za-z0-9-]+|docs/[A-Za-z0-9-]+|t/[A-Za-z0-9]+))", url or "")
    if m:
        return m.group(1)
    from urllib.parse import urlsplit, urlunsplit
    p = urlsplit(url or "")
    if p.netloc.endswith("surge.sh"):
        return f"https://{p.netloc}/"
    keep = p.query if p.netloc == "sellercentral.amazon.com" else ""
    return urlunsplit((p.scheme, p.netloc, p.path.rstrip("/"), keep, ""))


# ---------------------------------------------------------------- chrome dwell

def chrome_visits(start_utc, end_utc):
    """[(dt_utc, canon_url, title, dwell_seconds)] in the window."""
    src = os.path.join(CHROME, "History")
    if not os.path.exists(src):
        log("WARNING: no Chrome History DB")
        return []
    tmp = os.path.join(tempfile.gettempdir(), "marin_learn_history.db")
    shutil.copy(src, tmp)          # Chrome write-locks the live file
    con = sqlite3.connect(tmp)
    lo = int((start_utc - EPOCH).total_seconds() * 1_000_000)
    hi = int((end_utc - EPOCH).total_seconds() * 1_000_000)
    rows = []
    try:
        for vt, url, title, dur in con.execute(
            "SELECT v.visit_time, u.url, u.title, v.visit_duration "
            "FROM visits v JOIN urls u ON u.id = v.url "
            "WHERE v.visit_time BETWEEN ? AND ? AND u.url LIKE 'http%'",
            (lo, hi),
        ):
            rows.append((EPOCH + datetime.timedelta(microseconds=vt),
                         canon(url), title or "", (dur or 0) / 1_000_000))
    except sqlite3.Error as e:
        log(f"history read failed: {e}")
    finally:
        con.close()
        try:
            os.remove(tmp)
        except OSError:
            pass
    return rows


# ------------------------------------------------------------- transcript join

SAID = re.compile(r"^## (\d{2}:\d{2}:\d{2}) — (.+?)\n\n\*\*Said:\*\* (.+?)$", re.M)

# Only utterances aimed AT MARIN count. The same transcript also carries
# "VTT (toggle) (Claude)" lines — Steph dictating to Cowork — and on the first
# dry run those got learned as nav aliases ("okay fix surge deploy hook").
MARIN_MODE = re.compile(r"Realtime \(Marin\)", re.I)

# ...and of those, only ones that are actually asking to GO somewhere. Marin also
# answers questions ("how many SKUs in Dune?") which must never become aliases.
NAV_INTENT = re.compile(
    r"^\s*(open|go to|goto|pull up|bring up|take me to|show me|launch|navigate)\b", re.I)

# A correction says what the destination ISN'T. It is never its name.
# Real example, 2026-08-24: Clicky transcribed "Open No, it's not a sheet. It's
# a site." — the leading "Open" satisfied NAV_INTENT, and without this guard the
# alias "no it's not sheet it's site" got attached to the planogram builder.
CORRECTION = re.compile(
    r"\b(no it'?s not|not a |not the |i meant|nope|wrong one|that'?s not|never ?mind"
    r"|try again|different one|the other)", re.I)


def transcript_phrases(day_local, lo_local, hi_local):
    """[(local_time, said)] — Marin-directed navigation requests only."""
    path = os.path.join(TRANSCRIPTS, f"{day_local:%Y-%m-%d}.md")
    if not os.path.exists(path):
        return []
    text = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for m in SAID.finditer(text):
        if not MARIN_MODE.search(m.group(2)):
            continue
        said = m.group(3).strip()
        if not NAV_INTENT.match(said) or CORRECTION.search(said):
            continue
        t = datetime.datetime.strptime(m.group(1), "%H:%M:%S").time()
        when = datetime.datetime.combine(day_local.date(), t)
        if lo_local <= when <= hi_local:
            out.append((when, said))
    return out


def local_offset():
    """Seconds local is behind UTC (PDT -> 25200)."""
    now = datetime.datetime.now()
    utc = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    return round((utc - now).total_seconds())


# ------------------------------------------------------------------- episodes

def build_episodes(events):
    """Group nav tool calls into episodes separated by >EPISODE_GAP_S."""
    episodes, cur = [], []
    for ev in sorted(events):
        if cur and (ev[0] - cur[-1][0]).total_seconds() > EPISODE_GAP_S:
            episodes.append(cur)
            cur = []
        cur.append(ev)
    if cur:
        episodes.append(cur)
    # An episode is only interesting if he had to ask more than once.
    return [e for e in episodes if len(e) >= 2]


def load_deny():
    pats = []
    p = os.path.join(CONFIG, "marin-nav-deny.txt")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and not line.startswith("title:"):
                try:
                    pats.append(re.compile(line, re.I))
                except re.error:
                    pass
    return pats


def classify(episode, marin_opens, deny):
    """Return (verdict, winner_url, winner_title, dwell, runner_up_dwell)."""
    start = episode[0][0]
    end = episode[-1][0] + datetime.timedelta(seconds=TAIL_S)
    visits = chrome_visits(start - datetime.timedelta(seconds=15), end)
    if not visits:
        return "ABANDONED", None, None, 0, 0

    # Sum dwell per destination — a page revisited twice still counts once.
    totals = {}
    titles = {}
    for _, url, title, dur in visits:
        if any(p.search(url) for p in deny):
            continue
        totals[url] = totals.get(url, 0) + dur
        if title and url not in titles:
            titles[url] = title
    if not totals:
        return "ABANDONED", None, None, 0, 0

    ranked = sorted(totals.items(), key=lambda kv: -kv[1])
    winner, dwell = ranked[0]
    runner = ranked[1][1] if len(ranked) > 1 else 0.0

    # The whole anti-poisoning guard: a winner must genuinely dominate.
    if dwell < MIN_DWELL_S or (runner > 0 and dwell < runner * DOMINANCE):
        return "ABANDONED", None, None, dwell, runner

    opened_by_marin = {canon(u) for t, u in marin_opens.items() if start <= t <= end}
    verdict = "CONVERGED" if winner in opened_by_marin else "MANUAL_FIX"
    return verdict, winner, titles.get(winner, ""), dwell, runner


# --------------------------------------------------------------- alias store

STOP = {"open", "my", "the", "up", "go", "to", "for", "please", "hey", "marin",
        "can", "you", "pull", "show", "me", "at", "a", "and", "on", "in", "let's"}


def phrase_key(said):
    """Normalize a spoken request into a matchable alias phrase."""
    s = said.lower().strip().rstrip(".?!")
    s = re.sub(r"[^a-z0-9\s'-]", " ", s)
    words = [w for w in s.split() if w and w not in STOP]
    return " ".join(words).strip()


def load_aliases():
    if not os.path.exists(ALIASES):
        return {}
    out, cur = {}, None
    for line in open(ALIASES, encoding="utf-8"):
        m = re.match(r'\s*- url:\s*"(.*)"', line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, {"phrases": {}, "name": ""})
            continue
        m = re.match(r'\s*name:\s*"(.*)"', line)
        if m and cur:
            out[cur]["name"] = m.group(1)
            continue
        m = re.match(r'\s*- phrase:\s*"(.*)"\s*#\s*last:(\S+)\s*hits:(\d+)', line)
        if m and cur:
            out[cur]["phrases"][m.group(1)] = {"last": m.group(2), "hits": int(m.group(3))}
    return out


def save_aliases(store):
    today = datetime.date.today()
    lines = [
        "# Marin Nav — LEARNED ALIASES. Written automatically by learn_nav.py.",
        "# Do not hand-edit: this file is regenerated and your edits will be lost.",
        "# Steph's hand-owned favorites live in marin-nav-pins.yaml, which this",
        "# script never opens. Aliases are additive only — nothing is ever removed",
        "# from the nav list by anything in here.",
        "#",
        "# Each phrase is something Steph actually said that did NOT reach the",
        f"# destination on the first try. Unused for {ALIAS_TTL_DAYS} days -> dropped.",
        "aliases:",
    ]
    kept = dropped = 0
    for url, rec in sorted(store.items()):
        live = {}
        for phrase, meta in rec["phrases"].items():
            try:
                age = (today - datetime.date.fromisoformat(meta["last"])).days
            except ValueError:
                age = 0
            if age <= ALIAS_TTL_DAYS:
                live[phrase] = meta
            else:
                dropped += 1
        if not live:
            continue
        lines.append(f'  - url: "{url}"')
        lines.append(f'    name: "{rec["name"]}"')
        lines.append("    phrases:")
        for phrase, meta in sorted(live.items()):
            lines.append(f'      - phrase: "{phrase}"  # last:{meta["last"]} hits:{meta["hits"]}')
            kept += 1
    os.makedirs(CONFIG, exist_ok=True)
    with open(ALIASES, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return kept, dropped


# ------------------------------------------------------------------------ main

def main():
    dry = "--dry-run" in sys.argv
    since = utc_now() - datetime.timedelta(days=LOOKBACK_DAYS)
    offset = local_offset()

    events = parse_tools_log(since)
    marin_opens = parse_actions_log(since)
    deny = load_deny()
    episodes = build_episodes(events)
    log(f"{len(events)} nav events, {len(episodes)} multi-attempt episodes in last {LOOKBACK_DAYS}d")

    store = load_aliases()
    learned = skipped = 0
    journal = []

    for ep in episodes:
        verdict, winner, wtitle, dwell, runner = classify(ep, marin_opens, deny)
        lo_utc, hi_utc = ep[0][0], ep[-1][0]
        lo_loc = lo_utc - datetime.timedelta(seconds=offset)
        hi_loc = hi_utc - datetime.timedelta(seconds=offset) + datetime.timedelta(seconds=30)
        said = transcript_phrases(lo_loc, lo_loc - datetime.timedelta(seconds=20), hi_loc)
        stamp = f"{lo_loc:%Y-%m-%d %H:%M}"

        if verdict == "ABANDONED" or not winner:
            skipped += 1
            journal.append(f"[{stamp}] ABANDONED  attempts={len(ep)} "
                           f"best_dwell={dwell:.0f}s runner={runner:.0f}s — learned nothing")
            continue
        if not said:
            skipped += 1
            journal.append(f"[{stamp}] {verdict}  no transcript phrases found — learned nothing")
            continue

        # CONSERVATIVE BY DESIGN — Steph does not review these, so a wrong alias
        # is worse than a missed one. Two guards, both added after the 2026-08-23
        # 17:34 dry run attached four unrelated phrases ("amazon model", "alta
        # revenue model", ...) to Seller Central. That episode wasn't one request
        # retried — it was several DIFFERENT requests fired inside 90 seconds,
        # and episode grouping can't tell those apart on timing alone.
        #
        # Guard 1: learn only the ONE phrase immediately before the resolution.
        # That is the actual retry; anything earlier in a long chain is probably
        # a different destination.
        candidates = [p for _, p in said[:-1]] if verdict == "CONVERGED" else [p for _, p in said]
        failed = candidates[-1:]

        # Guard 2: the phrase must share a real word with where he landed.
        # "alta revenue model" shares nothing with "Amazon" -> not learned.
        # "planogram retail" shares "planogram" with "Virtual Planogram Builder" -> learned.
        title_words = {w for w in re.findall(r"[a-z]{4,}", (wtitle or "").lower())}
        if title_words:
            failed = [p for p in failed
                      if title_words & {w for w in re.findall(r"[a-z]{4,}", p.lower())}]
        rec = store.setdefault(winner, {"phrases": {}, "name": wtitle[:60]})
        if wtitle and not rec["name"]:
            rec["name"] = wtitle[:60]
        added_here = []
        for raw in failed:
            key = phrase_key(raw)
            if len(key) < 4:
                continue
            meta = rec["phrases"].get(key)
            if meta:
                meta["hits"] += 1
                meta["last"] = f"{lo_loc:%Y-%m-%d}"
            else:
                rec["phrases"][key] = {"last": f"{lo_loc:%Y-%m-%d}", "hits": 1}
                added_here.append(key)
                learned += 1
        journal.append(f"[{stamp}] {verdict}  dwell={dwell:.0f}s (runner {runner:.0f}s) "
                       f"-> {rec['name'] or winner}  +{len(added_here)} alias(es): "
                       + "; ".join(f'"{a}"' for a in added_here))

    if dry:
        print("\n".join(journal) if journal else "(nothing to learn)")
        log(f"DRY RUN — would learn {learned}, skip {skipped}")
        return 0

    kept, dropped = save_aliases(store)
    with open(JOURNAL, "a", encoding="utf-8") as f:
        for line in journal:
            f.write(line + "\n")
    log(f"learned {learned} new alias(es); {kept} live, {dropped} expired; "
        f"{skipped} episode(s) deliberately ignored")
    print("\n".join(journal) if journal else "(no multi-attempt episodes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
