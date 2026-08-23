#!/usr/bin/env python3
"""
harvest_nav.py — v1.0 (2026-08-23)

Builds the HOT tier of Marin's voice-navigation list from Chrome history.

Design (see Obsidian: Projects/Marin Nav Launcher.md):
  - Source: Chrome "Profile 2" (Kombo work). NEVER the personal Default profile.
  - History RANKS. Bookmark folders only TAG (intersect, never union).
  - Pins are hand-owned and live elsewhere; this script never reads or writes them.

Output: Claude Memory/Marin Hot Links.md  as "- Name → url  [category]" lines.

Exits non-zero WITHOUT writing if anything looks wrong, so gen-marin-nav.sh
keeps the last good file rather than publishing an empty list.
"""

import datetime
import json
import math
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from urllib.parse import urlsplit, urlunsplit

HOME = os.path.expanduser("~")
PROFILE = "Profile 2"                      # Kombo work profile — verified 2026-08-23
CHROME = os.path.join(HOME, "Library/Application Support/Google/Chrome", PROFILE)
CONFIG = os.path.join(HOME, "clicky-plus/config")
VAULT = os.path.join(HOME, "Desktop/Claude Cowork/Obsidian/Steph Vault/Claude Memory")
OUT = os.path.join(VAULT, "Marin Hot Links.md")

WINDOW_DAYS = 60          # how far back to look
HALFLIFE_DAYS = 21        # recency decay constant
MIN_DISTINCT_DAYS = 3     # stability floor: ignore one-day research binges
TOP_N = 25
MIN_EXPECTED = 8          # sanity floor; below this we assume something broke

# Query params are stripped by default (kills the 401k access token, collapses
# ?gid= noise). These hosts genuinely need their params to resolve.
KEEP_QUERY_HOSTS = ("sellercentral.amazon.com",)


def log(msg):
    print(f"[harvest_nav] {msg}", file=sys.stderr)


def die(msg):
    log(f"ABORT: {msg}")
    sys.exit(1)


# ---------------------------------------------------------------- config load

def load_deny():
    """Returns (url_patterns, title_patterns)."""
    path = os.path.join(CONFIG, "marin-nav-deny.txt")
    urls, titles = [], []
    if not os.path.exists(path):
        log("WARNING: no deny-list found; nothing will be filtered")
        return urls, titles
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("title:"):
            titles.append(re.compile(line[6:].strip(), re.I))
        else:
            urls.append(re.compile(line, re.I))
    return urls, titles


def load_folders():
    """Returns (allow, deny) as lists of (path_prefix, include_subfolders, category)."""
    path = os.path.join(CONFIG, "marin-nav-folders.txt")
    allow, deny = [], []
    if not os.path.exists(path):
        log("WARNING: no folder allowlist; categories will be blank")
        return allow, deny
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n").strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("!"):
            # Exclusion: no category field. Take the whole rest as the path —
            # required because folder names themselves contain " | "
            # (e.g. "GM | Amazon"), which would otherwise be mis-split.
            raw = line[1:].strip()
            sub = raw.endswith("/**")
            deny.append((raw[:-3].rstrip("/") if sub else raw, sub, None))
        else:
            # Allow: category is the LAST " | "-separated field.
            if " | " in line:
                raw, cat = line.rsplit(" | ", 1)
            else:
                raw, cat = line, ""
            raw, cat = raw.strip(), cat.strip()
            sub = raw.endswith("/**")
            allow.append((raw[:-3].rstrip("/") if sub else raw, sub, cat))
    return allow, deny


# ------------------------------------------------------------ canonicalisation

GDOC = re.compile(r"^(https://docs\.google\.com/(?:spreadsheets|document|presentation)/d/[A-Za-z0-9_-]+)")
CLICKUP = re.compile(r"^(https://app\.clickup\.com/[0-9]+/(?:v/dc/[A-Za-z0-9-]+|docs/[A-Za-z0-9-]+|t/[A-Za-z0-9]+))")


def canon(url):
    """One destination -> one key. Collapses #gid= fragment explosion."""
    if not url:
        return ""
    m = GDOC.match(url)
    if m:
        return m.group(1) + "/edit"
    m = CLICKUP.match(url)
    if m:
        return m.group(1)
    parts = urlsplit(url)
    if parts.netloc.endswith("surge.sh"):
        return f"https://{parts.netloc}/"
    query = parts.query if parts.netloc in KEEP_QUERY_HOSTS else ""
    return urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/"), query, ""))


TITLE_JUNK = re.compile(r"\s*[-–|]\s*(Google Sheets|Google Docs|Google Slides|ClickUp|Google Drive)\s*$", re.I)
UNREAD = re.compile(r"\s*\(\d+\)\s*")


def clean_title(t):
    if not t:
        return ""
    t = UNREAD.sub(" ", t)
    for _ in range(3):
        new = TITLE_JUNK.sub("", t)
        if new == t:
            break
        t = new
    return t.strip()


# Titles Chrome gives that identify nothing — Seller Central labels every page
# "Amazon", so several destinations arrive with the same useless name.
GENERIC = {"amazon", "google", "home", "dashboard", "untitled", "sign in", "loading"}


def display_name(title, url, limit=58):
    """A name Steph could actually say out loud."""
    name = title
    if name.strip().lower() in GENERIC:
        # Fall back to the URL path: /performance/dashboard -> "Amazon · Performance Dashboard"
        path = [p for p in urlsplit(url).path.split("/") if p]
        if path:
            tail = " ".join(w.capitalize() for w in re.split(r"[-_]", path[-1]) if w)
            host = urlsplit(url).netloc.split(".")[0].replace("sellercentral", "Seller Central")
            name = f"{host.title()} · {tail}" if tail else name
    if len(name) <= limit:
        return name
    # Truncate on a word boundary, not mid-word.
    cut = name[:limit].rsplit(" ", 1)[0]
    return (cut if len(cut) > limit * 0.6 else name[:limit]).rstrip(" ,-–|(") + "…"


# -------------------------------------------------------------------- sources

EPOCH = datetime.datetime(1601, 1, 1)


def to_dt(chrome_ts):
    return EPOCH + datetime.timedelta(microseconds=int(chrome_ts or 0))


def read_history():
    src = os.path.join(CHROME, "History")
    if not os.path.exists(src):
        die(f"no History DB at {src}")
    # Chrome holds a write lock while running — always query a copy.
    tmp = os.path.join(tempfile.gettempdir(), "marin_nav_history.db")
    shutil.copy(src, tmp)
    con = sqlite3.connect(tmp)
    cutoff = int((datetime.datetime.now() - datetime.timedelta(days=WINDOW_DAYS) - EPOCH).total_seconds() * 1_000_000)
    try:
        rows = con.execute(
            "SELECT u.url, u.title, v.visit_time "
            "FROM urls u JOIN visits v ON v.url = u.id "
            "WHERE v.visit_time > ? AND u.url LIKE 'http%'",
            (cutoff,),
        ).fetchall()
    except sqlite3.Error as e:
        die(f"history schema changed? {e}")
    finally:
        con.close()
        try:
            os.remove(tmp)
        except OSError:
            pass
    return rows


def read_bookmark_categories(allow, deny):
    """canonical url -> category, for allowed folders only."""
    src = os.path.join(CHROME, "Bookmarks")
    out = {}
    if not os.path.exists(src):
        log("WARNING: no Bookmarks file; categories will be blank")
        return out
    data = json.load(open(src, encoding="utf-8"))

    def matches(rules, path):
        for prefix, sub, cat in rules:
            if path == prefix or (sub and path.startswith(prefix + "/")):
                return True, cat
        return False, None

    def walk(node, path):
        if node.get("type") == "folder":
            for child in node.get("children", []):
                walk(child, path + "/" + node["name"])
            return
        excluded, _ = matches(deny, path)
        if excluded:
            return
        ok, cat = matches(allow, path)
        if ok:
            out.setdefault(canon(node.get("url", "")), cat)

    for root in ("bookmark_bar", "other", "synced"):
        node = data.get("roots", {}).get(root)
        if node:
            walk(node, "")
    return out


# ----------------------------------------------------------------------- main

def main():
    deny_url, deny_title = load_deny()
    allow, folder_deny = load_folders()
    categories = read_bookmark_categories(allow, folder_deny)
    log(f"{len(categories)} bookmark URLs in allowed folders")

    rows = read_history()
    if not rows:
        die("history query returned zero rows")
    log(f"{len(rows)} visits in last {WINDOW_DAYS}d")

    now = datetime.datetime.now()
    agg = {}
    for url, title, visit_time in rows:
        if any(p.search(url) for p in deny_url):
            continue
        if title and any(p.search(title) for p in deny_title):
            continue
        key = canon(url)
        if not key:
            continue
        # A credential could still hide in a kept query string.
        if re.search(r"[?&](token|access_token|key|api_key|secret|session|sid|auth)=", key, re.I):
            continue
        when = to_dt(visit_time)
        age = max((now - when).days, 0)
        entry = agg.setdefault(key, {"score": 0.0, "days": set(), "titles": {}})
        entry["score"] += math.exp(-age / HALFLIFE_DAYS)
        entry["days"].add(when.date())
        clean = clean_title(title)
        if clean:
            entry["titles"][clean] = entry["titles"].get(clean, 0) + 1

    ranked = [
        (k, v) for k, v in agg.items()
        if len(v["days"]) >= MIN_DISTINCT_DAYS and v["titles"]
    ]
    ranked.sort(key=lambda kv: -kv[1]["score"])
    ranked = ranked[:TOP_N]

    if len(ranked) < MIN_EXPECTED:
        die(f"only {len(ranked)} destinations survived filtering (expected >= {MIN_EXPECTED}) — not overwriting")

    lines = [
        "# Marin Hot Links (auto-generated — do not hand-edit)",
        "",
        f"_Generated {now:%Y-%m-%d %H:%M} from Chrome '{PROFILE}' history, last {WINDOW_DAYS} days._",
        f"_Ranked by recency-weighted visits. Seen on >= {MIN_DISTINCT_DAYS} distinct days._",
        "",
    ]
    for key, val in ranked:
        name = display_name(max(val["titles"], key=val["titles"].get), key)
        cat = categories.get(key, "")
        suffix = f"  [{cat}]" if cat else ""
        lines.append(f"- {name} → {key}{suffix}")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    tagged = sum(1 for k, _ in ranked if categories.get(k))
    log(f"wrote {len(ranked)} hot links ({tagged} category-tagged) to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
