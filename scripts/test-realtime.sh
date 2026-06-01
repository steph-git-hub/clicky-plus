#!/bin/bash
# =============================================================================
# test-realtime.sh — Marin (OpenAI) vs Gemini (Sulafat) A/B comparison helper
#
# The actual test plan lives in Obsidian:
#   ~/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/Marin vs Gemini Tests.md
# Open it in Obsidian and fill in as you go. This script is the live-tooling
# companion — log tails, screenshot inspection, relaunches.
#
# Usage:
#   ./scripts/test-realtime.sh                # default = print menu, then tail
#   ./scripts/test-realtime.sh plan           # open the comparison plan in Obsidian
#   ./scripts/test-realtime.sh tail           # tail BOTH providers' lines from diag log
#   ./scripts/test-realtime.sh tail-marin     # tail just Marin lines
#   ./scripts/test-realtime.sh tail-gemini    # tail just Gemini lines
#   ./scripts/test-realtime.sh shots          # open the last screenshot of each provider
#   ./scripts/test-realtime.sh obsidian       # pretty-print today's transcript log
#   ./scripts/test-realtime.sh diff           # show last turn of each side-by-side
# =============================================================================

DIAG_LOG="/tmp/clicky_realtime_diag.log"
TODAY_OBSIDIAN="/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/transcripts/$(date +%Y-%m-%d).jsonl"
COMPARISON_DOC="/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/Marin vs Gemini Tests.md"
GEMINI_SHOT="/tmp/clicky_last_gemini_screenshot.jpg"
MARIN_SHOT="/tmp/clicky_last_marin_screenshot.jpg"

print_menu() {
cat << 'EOF'
================================================================================
MARIN vs GEMINI COMPARISON HELPER
================================================================================

  The test plan lives in Obsidian as a side-by-side template:
    Clicky Logs/Marin vs Gemini Tests.md

  Workflow:
    1. Open the test plan         → ./scripts/test-realtime.sh plan
    2. Flip provider to Marin in Clicky panel
    3. Run all tests, fill in Marin column
    4. Flip provider to Gemini
    5. Run all tests again, fill in Gemini column
    6. Fill in the summary scorecard at the bottom

  Live tooling while you work:
    ./scripts/test-realtime.sh tail         (both providers)
    ./scripts/test-realtime.sh tail-marin   (just Marin)
    ./scripts/test-realtime.sh tail-gemini  (just Gemini)
    ./scripts/test-realtime.sh shots        (open the last screenshot of each)
    ./scripts/test-realtime.sh obsidian     (today's Obsidian transcripts)
    ./scripts/test-realtime.sh diff         (last turn from each, side by side)

================================================================================
EOF
}

case "${1:-}" in
    plan)
        echo "Opening the Marin vs Gemini test plan in Obsidian..."
        open "obsidian://open?file=Clicky%20Logs%2FMarin%20vs%20Gemini%20Tests" 2>/dev/null \
            || open -a Obsidian "$COMPARISON_DOC" 2>/dev/null \
            || open "$COMPARISON_DOC"
        ;;
    tail)
        echo "Tailing $DIAG_LOG — Marin + Gemini lines (Ctrl-C to exit)"
        echo "────────────────────────────────────────────────────────────────"
        tail -f "$DIAG_LOG" | grep --line-buffered -iE "gemini|marin|realtime|turn logged|session|tool|vision|hotkey"
        ;;
    tail-marin)
        echo "Tailing $DIAG_LOG — Marin lines only (Ctrl-C to exit)"
        echo "────────────────────────────────────────────────────────────────"
        # Marin's diag lines don't have a [marin] prefix — filter for everything that's NOT [gemini]
        tail -f "$DIAG_LOG" | grep --line-buffered -v "\[gemini\]"
        ;;
    tail-gemini)
        echo "Tailing $DIAG_LOG — Gemini lines only (Ctrl-C to exit)"
        echo "────────────────────────────────────────────────────────────────"
        tail -f "$DIAG_LOG" | grep --line-buffered "\[gemini\]"
        ;;
    shots)
        echo "Last screenshots:"
        if [ -f "$GEMINI_SHOT" ]; then
            echo "  Gemini: $GEMINI_SHOT ($(stat -f '%Sm' "$GEMINI_SHOT"))"
            open "$GEMINI_SHOT"
        else
            echo "  Gemini: (none)"
        fi
        if [ -f "$MARIN_SHOT" ]; then
            echo "  Marin:  $MARIN_SHOT ($(stat -f '%Sm' "$MARIN_SHOT"))"
            open "$MARIN_SHOT"
        else
            echo "  Marin:  (none)"
        fi
        ;;
    obsidian)
        echo "Today's Obsidian transcript log: $TODAY_OBSIDIAN"
        echo "────────────────────────────────────────────────────────────────"
        if [ -f "$TODAY_OBSIDIAN" ]; then
            tail -10 "$TODAY_OBSIDIAN" | while IFS= read -r line; do
                echo "$line" | python3 -m json.tool 2>/dev/null || echo "$line"
                echo "---"
            done
        else
            echo "(no transcript log yet for today)"
        fi
        ;;
    diff)
        echo "Last turn from each provider, from today's Obsidian log:"
        echo "────────────────────────────────────────────────────────────────"
        if [ -f "$TODAY_OBSIDIAN" ]; then
            echo ""
            echo "MARIN — most recent turn:"
            # Marin entries don't have a 'provider' field; we'll just take the last
            # mode=realtime entry that was logged from a Marin session. We don't have
            # an explicit marker so this is a best-effort: most recent realtime turn.
            tail -50 "$TODAY_OBSIDIAN" | grep '"mode":"realtime"' | tail -1 | python3 -m json.tool 2>/dev/null
            echo ""
            echo "(If Marin and Gemini both write mode=realtime, this just shows the most"
            echo "recent — flip providers between tests to keep them distinguishable.)"
        else
            echo "(no transcript log yet)"
        fi
        ;;
    *)
        print_menu
        echo ""
        echo "Now tailing diag log for both providers (Ctrl-C to exit)..."
        echo "────────────────────────────────────────────────────────────────"
        tail -f "$DIAG_LOG" | grep --line-buffered -iE "gemini|marin|realtime|turn logged|session|tool|vision|hotkey"
        ;;
esac
