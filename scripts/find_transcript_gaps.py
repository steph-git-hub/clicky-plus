#!/usr/bin/env python3
"""
find_transcript_gaps.py — v16r23 (2026-08-10)

Steph reports that toggle dictations sometimes come back with a chunk
missing from the MIDDLE, rather than simply stopping at the cut point.
This scans the Clicky transcript log for signatures of a mid-capture gap
so the claim can be settled with evidence instead of memory.

Read-only. Run:  python3 scripts/find_transcript_gaps.py
"""
import json
import glob
import os
import re
import sys
from collections import Counter

LOG_DIR = ("/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/"
           "Steph Vault/Clicky Logs/transcripts")

# Signatures of "something was removed from the middle".
SIGNATURES = {
    "empty straight quotes":  re.compile(r'"\s*"'),
    "empty smart quotes":     re.compile(r'[“]\s*[”]'),
    "empty single quotes":    re.compile(r"'\s*'"),
    "double+ space":          re.compile(r"\S {2,}\S"),
    "ellipsis remnant":       re.compile(r"\.\.\.|…"),
    # A word cut mid-token then text resuming — the '...Because-' shape.
    "mid-word hyphen break":  re.compile(r"\w-\s+[A-Z]"),
    # Sentence ends with no terminal punctuation, next starts capitalised:
    # the seam you'd get if a middle chunk vanished.
    "lowercase->Capital seam": re.compile(r"[a-z]{3,}\s+[A-Z][a-z]{3,}"),
}

def load(path):
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out

def main():
    files = sorted(glob.glob(os.path.join(LOG_DIR, "*.jsonl")))
    if not files:
        print(f"No logs found at {LOG_DIR}")
        return 1

    totals = Counter()
    per_day_toggle = Counter()
    hits = []

    for path in files:
        day = os.path.basename(path)[:-6]
        for entry in load(path):
            if entry.get("mode") != "vtt_toggle":
                continue
            per_day_toggle[day] += 1
            raw = (entry.get("rawTranscript") or "")
            final = (entry.get("finalOutput") or "")
            for name, rx in SIGNATURES.items():
                m = rx.search(raw)
                if m:
                    totals[name] += 1
                    if name != "lowercase->Capital seam":
                        s = max(0, m.start() - 45)
                        e = min(len(raw), m.end() + 45)
                        hits.append((day, entry.get("timestamp"), name,
                                     raw[s:e], len(raw), len(final)))

    print(f"Scanned {len(files)} days, "
          f"{sum(per_day_toggle.values())} toggle dictations "
          f"({min(per_day_toggle) if per_day_toggle else '?'} .. "
          f"{max(per_day_toggle) if per_day_toggle else '?'})\n")

    print("SIGNATURE COUNTS across all toggle dictations:")
    for name in SIGNATURES:
        c = totals.get(name, 0)
        pct = 100.0 * c / max(sum(per_day_toggle.values()), 1)
        print(f"  {c:5d}  ({pct:5.1f}%)  {name}")

    print("\nCONCRETE HITS (excluding the noisy seam heuristic):")
    if not hits:
        print("  none")
    for day, ts, name, ctx, rawlen, finlen in hits[:60]:
        ctx = ctx.replace("\n", "\\n")
        print(f"  {ts}  [{name}]  raw={rawlen} final={finlen}")
        print(f"      ...{ctx}...")

    print(f"\n  total concrete hits: {len(hits)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
