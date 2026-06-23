#!/usr/bin/env bash
# worktree-link.sh — optional WorktreeCreate hook.
#
# When a new git worktree is created (a peer, or a workflow subagent with
# isolation:worktree), symlink the shared .venv and .env from the main repo
# into it — so you run `uv sync` ONCE, not once per worktree, and every agent
# sees the same keys/cache.
#
# Input: JSON on stdin describing the new worktree. We try a few likely field
# names for its path and fall back to $CLAUDE_WORKTREE_PATH.
set -euo pipefail

input="$(cat 2>/dev/null || true)"
wt="$(printf '%s' "$input" | jq -r '.worktreePath // .worktree_path // .path // empty' 2>/dev/null || true)"
wt="${wt:-${CLAUDE_WORKTREE_PATH:-}}"
[ -z "$wt" ] && exit 0
[ -d "$wt" ] || exit 0

# main repo = the worktree's main working tree.
main_repo="$(git -C "$wt" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
[ -z "$main_repo" ] && exit 0
[ "$main_repo" = "$wt" ] && exit 0   # this IS the main tree; nothing to link

for shared in .venv .env; do
  if [ -e "${main_repo}/${shared}" ] && [ ! -e "${wt}/${shared}" ]; then
    ln -sfn "${main_repo}/${shared}" "${wt}/${shared}" 2>/dev/null || true
  fi
done
exit 0
