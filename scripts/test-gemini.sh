#!/bin/bash
# =============================================================================
# test-gemini.sh — Test plan + live log tail for Gemini Live integration
#
# Usage:
#   ./scripts/test-gemini.sh          # Print test plan, then tail diag log
#   ./scripts/test-gemini.sh plan     # Just print the test plan
#   ./scripts/test-gemini.sh tail     # Just tail the diag log (filtered)
#   ./scripts/test-gemini.sh relaunch # Kill + relaunch Clicky from new build
#   ./scripts/test-gemini.sh obsidian # Show today's transcript log from Obsidian
#
# Before testing: flip Marin provider to "Gemini" in the Clicky panel.
# Each test below assumes you've already pressed and released the
# push-to-talk hotkey at least once so a session is active.
# =============================================================================

DIAG_LOG="/tmp/clicky_realtime_diag.log"
CLICKY_APP="/Users/stephenpierson/Library/Developer/Xcode/DerivedData/leanring-buddy-amdmxzhjcgcykyczzznhsfjoxcix/Build/Products/Debug/Clicky.app"
TODAY_OBSIDIAN="/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/transcripts/$(date +%Y-%m-%d).jsonl"

print_plan() {
cat << 'EOF'
================================================================================
GEMINI LIVE TEST PLAN
================================================================================

PREREQ: Flip Marin provider to "Gemini" in Clicky panel.
        Run `./scripts/test-gemini.sh relaunch` to load the latest build.

────────────────────────────────────────────────────────────────────────────────
TEST 1 — v15p3ea — Basic connectivity (regression check)
────────────────────────────────────────────────────────────────────────────────
ACTION: Hold hotkey, say "Hello", release.
EXPECT: Sulafat responds within ~1 second. Pink spinner clears when done.
DIAG: Look for these lines in order:
  [gemini] received setupComplete
  [gemini] sent activity_start
  [gemini] sent X audio chunks
  [gemini] sent activity_end
  [gemini] turn-end signal
  [gemini] turn logged: user=N chars, asst=M chars
FAIL MODE: "receive loop ended — code=1007" = pre-setup send (regression)

────────────────────────────────────────────────────────────────────────────────
TEST 2 — v15p3du — Manual VAD (push-to-talk semantics)
────────────────────────────────────────────────────────────────────────────────
ACTION: Hold hotkey. Say "Tell me a story about" — pause 3 full seconds —
        say "a tiny robot named Pip", release.
EXPECT: She does NOT jump in during your pause. She only starts after release.
FAIL MODE: She responds during the pause = manual VAD didn't engage.

────────────────────────────────────────────────────────────────────────────────
TEST 3 — v15p3dv — Contractions
────────────────────────────────────────────────────────────────────────────────
ACTION: Ask "Are you ready to help?" Release.
EXPECT: Response uses "I'm", "you're", "don't", etc. Not "I am" / "do not".
FAIL MODE: Robotic formal speech = system prompt didn't take.

────────────────────────────────────────────────────────────────────────────────
TEST 4 — v15p3dw — Live transcripts in Obsidian
────────────────────────────────────────────────────────────────────────────────
ACTION: Complete one full turn (any question).
WAIT: ~2 seconds after Sulafat finishes.
VERIFY: Run `./scripts/test-gemini.sh obsidian` — last line should be a JSON
        entry with mode="realtime" containing your raw and her response.
FAIL MODE: No new entry or empty rawTranscript/claudeResponse = transcript
        opt-in not honored, or writeGeminiTurnToTranscriptLog not firing.

────────────────────────────────────────────────────────────────────────────────
TEST 5 — v15p3dy — Vision (THIS IS THE BIG ONE)
────────────────────────────────────────────────────────────────────────────────
ACTION: Open any app with visible text. Hover your cursor near a specific
        element (a button, a heading, a paragraph). Hold hotkey and ask
        "What am I looking at right now? What's near my cursor?"
EXPECT: Sulafat describes what's actually on screen, mentions the element
        near your cursor.
DIAG: Look for "[gemini] vision: sent full screenshot (XYZ bytes) + fovea="
VERIFY: /tmp/clicky_last_gemini_screenshot.jpg should exist and show what
        was on your screen at press time:
        open /tmp/clicky_last_gemini_screenshot.jpg
FAIL MODE: She says "I can't see your screen" = the realtime_input.video
        payload format is wrong for this Gemini model.

────────────────────────────────────────────────────────────────────────────────
TEST 6 — v15p3dx — History seeding from Marin
────────────────────────────────────────────────────────────────────────────────
SETUP: Flip provider back to "Marin", have a quick exchange ("My favorite
        color is blue, remember that"). Wait 30 sec.
ACTION: Flip provider to "Gemini". Hold hotkey, say "What did I just tell
        Marin my favorite color was?", release.
EXPECT: Sulafat says "blue" (with contractions and warmth).
DIAG: Look for "[gemini] seeded N prior turns from Marin history"
FAIL MODE: She says she doesn't know = seed payload didn't take or Marin's
        JSON file wasn't populated.

────────────────────────────────────────────────────────────────────────────────
TEST 7 — Session reuse (15-min memory)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, say "My favorite snack is pretzels." Release. Wait 60 sec.
        Press again, say "What's my favorite snack?", release.
EXPECT: She says "pretzels" — same WebSocket session, full context.
DIAG: Look for "[gemini] resumed existing session — context preserved"
FAIL MODE: She doesn't know = session got torn down + memory lost.

────────────────────────────────────────────────────────────────────────────────
TEST 8 — v15p3dz — Tools (local: research)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, say "What scheduled tasks do I have?", release.
EXPECT: She lists tasks (morning briefing, monthly forecast review, etc.)
DIAG: Look for "[gemini] toolCall: list_scheduled_tasks"
                 "[gemini] tool_response sent for list_scheduled_tasks"

────────────────────────────────────────────────────────────────────────────────
TEST 9 — v15p3dz — Tools (Obsidian search)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, "Search my Obsidian vault for 'Clicky roadmap'", release.
EXPECT: She mentions the roadmap file with a snippet.
DIAG: Look for "[gemini] toolCall: search_obsidian"

────────────────────────────────────────────────────────────────────────────────
TEST 10 — v15p3dz — Tools (worker-backed: Gmail / Calendar / Slack)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, ask "What's my next meeting?" — release.
EXPECT: She names the next calendar event.
DIAG: Look for "[gemini] toolCall: find_next_event"
              + "[gemini] tool_response sent for find_next_event"
FAIL MODE: If she says "error" / "couldn't reach Calendar" — the worker
        route is intact but Gemini may not be auth'd. Cloud-side check.

────────────────────────────────────────────────────────────────────────────────
TEST 11 — v15p3dz — Tools (clipboard write)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, "Put 'test from Sulafat' on my clipboard." Release.
EXPECT: She confirms. Run `pbpaste` and verify the text is there.

────────────────────────────────────────────────────────────────────────────────
TEST 12 — v15p3dz — Tools (on-demand screenshot refresh)
────────────────────────────────────────────────────────────────────────────────
ACTION: Press, "Take a fresh screenshot and tell me what's on my screen
        now." Release.
EXPECT: New screenshot fired mid-conversation, then she describes it.
DIAG: Look for "[gemini] toolCall: get_current_screenshot"
              + "[gemini] vision: sent full screenshot"

────────────────────────────────────────────────────────────────────────────────
TEST 13 — 15-min memory cap (the bug fix you asked for)
────────────────────────────────────────────────────────────────────────────────
SETUP: Have an exchange ("Tomorrow I'm flying to Boston"). Wait 16+ minutes
        with NO further presses (so the auto-close timer fires).
ACTION: Press, "Where am I flying tomorrow?", release.
EXPECT: She does NOT know — fresh session, no cross-session bleed.
DIAG: Should see a fresh "websocket task.resume() called" rather than
       "resumed existing session". Seed should bring 0 prior turns if no
       turns fell within the 15-min window.

================================================================================
EOF
}

case "${1:-}" in
    plan)
        print_plan
        ;;
    relaunch)
        echo "Killing running Clicky..."
        killall Clicky 2>/dev/null || true
        sleep 1
        echo "Launching new build from $CLICKY_APP"
        open "$CLICKY_APP"
        ;;
    tail)
        echo "Tailing $DIAG_LOG (gemini lines only — Ctrl-C to exit)"
        echo "─────────────────────────────────────────────────────────────────"
        tail -f "$DIAG_LOG" | grep --line-buffered -E "gemini|markOtherMode"
        ;;
    obsidian)
        echo "Today's Obsidian transcript log: $TODAY_OBSIDIAN"
        echo "─────────────────────────────────────────────────────────────────"
        if [ -f "$TODAY_OBSIDIAN" ]; then
            # Show last 10 entries pretty-printed
            tail -10 "$TODAY_OBSIDIAN" | while IFS= read -r line; do
                echo "$line" | python3 -m json.tool 2>/dev/null || echo "$line"
                echo "---"
            done
        else
            echo "(no log file yet — Sulafat hasn't logged a turn today)"
        fi
        ;;
    *)
        print_plan
        echo ""
        echo "================================================================================"
        echo "Now tailing diag log (gemini lines only — Ctrl-C to exit)..."
        echo "================================================================================"
        tail -f "$DIAG_LOG" | grep --line-buffered -E "gemini|markOtherMode"
        ;;
esac
