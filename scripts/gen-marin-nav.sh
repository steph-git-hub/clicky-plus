#!/bin/bash
# v16a (2026-08-23): generate Marin's unified navigation list.
# Three tiers, merged here:
#   1. PINNED       → config/marin-nav-pins.yaml. HAND-OWNED by Steph.
#                     This script only READS it. Never written by any script.
#   2. HOT          → harvest_nav.py (Chrome "Profile 2" history, decay-ranked,
#                     deny-listed, tagged with bookmark-folder categories).
#                     Replaced the hand-curated ClickUp agenda step on 8/23.
#   3. DASHBOARDS   → gen-marin-dashboards.sh (surge list, filtered). Unchanged.
#
# Output: Claude Memory/Marin Nav.md  (Marin reads via read_memory_file "Marin Nav")
#
# SAFETY: if a generator fails, its tier is skipped and the PREVIOUS Marin Nav.md
# is left in place. Never publish an empty or half-built nav list.
export PATH="$HOME/.npm-global/bin:$PATH"
MEMDIR="$HOME/Desktop/Claude Cowork/Obsidian/Steph Vault/Claude Memory"
NAV="$MEMDIR/Marin Nav.md"
DASH="$MEMDIR/Marin Dashboards.md"
HOT="$MEMDIR/Marin Hot Links.md"
PINS="$HOME/clicky-plus/config/marin-nav-pins.yaml"
# NOTE: "Marin Agenda Links.md" is DEPRECATED as of 2026-08-23 — no longer read.
# Left on disk deliberately as a rollback. Do not delete.

# Refresh dashboards first (reuses the existing, working generator).
[ -x "$HOME/clicky-plus/scripts/gen-marin-dashboards.sh" ] && "$HOME/clicky-plus/scripts/gen-marin-dashboards.sh" >/dev/null 2>&1

# Refresh the hot tier from browser history.
if [ -f "$HOME/clicky-plus/scripts/harvest_nav.py" ]; then
  python3 "$HOME/clicky-plus/scripts/harvest_nav.py" || echo "WARN: harvester failed; reusing previous hot links" >&2
fi

# Hard gate: pins are the floor. If we can't read them, don't touch the nav file.
if [ ! -f "$PINS" ]; then
  echo "ABORT: pins file missing ($PINS). Leaving existing Marin Nav.md untouched." >&2
  exit 1
fi

TMP="$(mktemp)"
{
  echo "# Marin Nav (auto-generated — do not hand-edit)"
  echo ""
  echo "_Generated $(date '+%Y-%m-%d %H:%M'). Marin's voice-navigable destinations._"
  echo "_Pinned = Steph's hand-picked list. Working on now = what he's actually opened lately._"
  echo "_On an ambiguous request, match against these entries ONLY. Say 'open my [name]'._"
  echo ""

  echo "## Pinned (always available)"
  python3 - "$PINS" <<'PY'
import re, sys
name = url = cat = None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r'\s*- name:\s*"(.*)"', line)
    if m:
        name, url, cat = m.group(1), None, None
        continue
    m = re.match(r'\s*url:\s*"(.*)"', line)
    if m:
        url = m.group(1)
        continue
    m = re.match(r'\s*category:\s*"(.*)"', line)
    if m and name and url:
        cat = m.group(1)
        print(f"- {name} → {url}" + (f"  [{cat}]" if cat else ""))
        name = url = cat = None
PY

  echo ""
  echo "## Working on now (from browser history, last 60 days)"
  if [ -f "$HOT" ]; then
    # Skip anything already pinned — pins win, their hand-written name is better.
    grep -E '^\- ' "$HOT" 2>/dev/null | while IFS= read -r line; do
      u="${line##*→ }"; u="${u%%  [*}"; u="$(echo "$u" | xargs)"
      # Match on the Google file id / host so gid variants still dedupe.
      id="$(echo "$u" | grep -oE '/d/[A-Za-z0-9_-]+' | head -1)"
      [ -z "$id" ] && id="$(echo "$u" | grep -oE '://[^/]+' | head -1)"
      if [ -n "$id" ] && grep -qF "$id" "$PINS"; then continue; fi
      echo "$line"
    done
  else
    echo "_(hot links unavailable this run)_"
  fi

  echo ""
  echo "## Dashboards (from Surge)"
  if [ -f "$DASH" ]; then
    grep -E '^\- ' "$DASH" 2>/dev/null
  fi
} > "$TMP"

# Only publish if the merge actually produced a usable list.
if [ "$(grep -cE '^\- ' "$TMP")" -lt 20 ]; then
  echo "ABORT: merged nav had <20 entries. Keeping previous Marin Nav.md." >&2
  rm -f "$TMP"; exit 1
fi
mv "$TMP" "$NAV"

echo "Wrote Marin Nav.md:"
echo "  pinned:     $(sed -n '/## Pinned/,/## Working/p' "$NAV" | grep -cE '^\- ')"
echo "  hot:        $(sed -n '/## Working on now/,/## Dashboards/p' "$NAV" | grep -cE '^\- ')"
echo "  dashboards: $(sed -n '/## Dashboards/,$p' "$NAV" | grep -cE '^\- ')"
