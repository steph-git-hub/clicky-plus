#!/bin/bash
# Auto-push every commit to origin in the background.
# Installed 2026-06-01. Solo private repo — keeps GitHub as an always-current
# backup so work never piles up uncommitted/unpushed (the v15p4 lesson).
# Pushes the CURRENT branch to its matching origin branch. Silent on success;
# logs failures to /tmp/clicky_autopush.log so a dropped network call is
# visible but never blocks or interrupts the commit.
#
# 2026-08-05 — FIX: serialize concurrent pushes.
# The original backgrounded each push with `&` and nothing coordinated them.
# Three commits in quick succession fired three overlapping pushes; two were
# rejected by GitHub with
#   cannot lock ref 'refs/heads/main': is at <X> but expected <Y>
# Everything still landed that time only because the surviving push happened
# to carry all three commits. A different interleaving leaves commits sitting
# unpushed while the hook reports nothing wrong — silently defeating the
# always-current-backup purpose this hook exists for.
#
# Serialized with a mkdir mutex (mkdir is atomic on POSIX; macOS has no
# flock). A queued push may find nothing left to send because an earlier one
# already carried its commits — "Everything up-to-date" is success.
#
# NOTE — no EXIT trap here, deliberately. On macOS's bash an EXIT trap set
# inside a backgrounded `{ ... } &` subshell does NOT fire (verified
# 2026-08-05), so a trap-based release leaks the lock on every single push
# and every later push then stalls and skips. The lock is released by an
# explicit rmdir on the straight-line path instead; the stale-lock reaper
# below covers the only remaining leak path, a hard kill mid-push.
# Still fully backgrounded: the commit itself never blocks.

branch="$(git rev-parse --abbrev-ref HEAD)"
lockdir=/tmp/clicky_autopush.lock
logfile=/tmp/clicky_autopush.log

{
  # Reap a lock orphaned by a killed push (older than 2 min; a normal push
  # is seconds). Without this a hard kill would wedge pushes permanently.
  if [ -d "$lockdir" ] && [ -z "$(find "$lockdir" -maxdepth 0 -mmin -2 2>/dev/null)" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] clearing stale lock"
    rmdir "$lockdir" 2>/dev/null
  fi

  # Acquire — wait up to ~60s for an in-flight push to finish.
  acquired=0
  for _ in $(seq 1 300); do
    if mkdir "$lockdir" 2>/dev/null; then acquired=1; break; fi
    sleep 0.2
  done

  if [ "$acquired" -ne 1 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] push $branch — TIMED OUT waiting for lock; skipped. Run: git push origin $branch"
    exit 0
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] post-commit push: $branch"
  git push origin "$branch" 2>&1

  # Release on the straight-line path — runs whether the push succeeded or
  # failed, since we do not gate it on the exit status.
  rmdir "$lockdir" 2>/dev/null
} >> "$logfile" 2>&1 &
