#!/bin/bash
# v15p4dg (2026-06-02): auto-generate Marin's dashboard destination list from
# the LIVE Surge deployments — no manual list to maintain. Pulls `surge list`,
# strips ANSI, filters out non-dashboard noise (mocks/dev/versioned/dated/
# diagnostics/proposals), and writes a clean markdown file Marin reads at runtime.
# Runs from the surge-deploy skill (post-deploy) + a periodic scheduled task.
export PATH="$HOME/.npm-global/bin:$PATH"
OUT="$HOME/Desktop/Claude Cowork/Obsidian/Steph Vault/Claude Memory/Marin Dashboards.md"
# Fallback to a stable local path if the vault path isn't present.
[ -d "$(dirname "$OUT")" ] || OUT="$HOME/clicky-plus/marin-dashboards.md"

raw="$(surge list 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g')"
# Extract the *.surge.sh hostnames.
hosts="$(echo "$raw" | grep -oE '[A-Za-z0-9-]+\.surge\.sh' | sort -u)"

# Noise filter: drop mockups, dev, versioned, originals, diagnostics, proposals,
# date-stamped snapshots, and known scratch words.
clean="$(echo "$hosts" | grep -viE -- '-(mock|mockup|dev|v[0-9]+|original|diagnostic|proposals?|cohorts|method)(\.|-)' \
  | grep -viE -- '(mockup|proposals?|diagnostic|-[0-9]{4}-[0-9]{2}-[0-9]{2}\.)' )"

{
  echo "# Marin Dashboards (auto-generated — do not hand-edit)"
  echo ""
  echo "_Generated $(date '+%Y-%m-%d %H:%M') from \`surge list\`. Live dashboards Steph opens by voice. Noise (mocks/dev/versions/dated) filtered out._"
  echo ""
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    echo "- https://$h"
  done <<< "$clean"
} > "$OUT"

echo "Wrote $(echo "$clean" | grep -c . ) dashboards to: $OUT"
echo "--- preview ---"
cat "$OUT"
