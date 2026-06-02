#!/bin/bash
# v15p4dl (2026-06-02): generate Marin's unified navigation list.
# Sources (curated, high-signal — NOT raw bookmarks, which are 90% stale junk):
#   1. Surge dashboards  → via gen-marin-dashboards.sh (surge list, filtered)
#   2. ClickUp agenda links (the LN<>SP Weekly doc) → written by the ClickUp-side
#      generator (a scheduled/triggered Cowork step using the ClickUp MCP, since
#      surge CLI here can't call ClickUp). This script MERGES whatever those
#      produce into one nav file Marin reads.
#
# Output: Claude Memory/Marin Nav.md  (Marin reads via read_memory_file "Marin Nav")
export PATH="$HOME/.npm-global/bin:$PATH"
MEMDIR="$HOME/Desktop/Claude Cowork/Obsidian/Steph Vault/Claude Memory"
NAV="$MEMDIR/Marin Nav.md"
DASH="$MEMDIR/Marin Dashboards.md"
AGENDA="$MEMDIR/Marin Agenda Links.md"   # written by the ClickUp generator step

# Refresh dashboards first (reuses the existing, working generator).
[ -x "$HOME/clicky-plus/scripts/gen-marin-dashboards.sh" ] && "$HOME/clicky-plus/scripts/gen-marin-dashboards.sh" >/dev/null 2>&1

{
  echo "# Marin Nav (auto-generated — do not hand-edit)"
  echo ""
  echo "_Generated $(date '+%Y-%m-%d %H:%M'). Marin's voice-navigable destinations. Sources: ClickUp LN<>SP agenda (work docs/models) + Surge dashboards. Say 'open my [name]'._"
  echo ""
  echo "## Work docs & models (from ClickUp agenda)"
  if [ -f "$AGENDA" ]; then
    grep -E '^\- ' "$AGENDA" 2>/dev/null
  else
    echo "_(agenda links not yet generated — run the ClickUp agenda-links step)_"
  fi
  echo ""
  echo "## Dashboards (from Surge)"
  if [ -f "$DASH" ]; then
    grep -E '^\- ' "$DASH" 2>/dev/null
  fi
} > "$NAV"

echo "Wrote Marin Nav.md:"
wc -l "$NAV"
