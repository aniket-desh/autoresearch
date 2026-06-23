#!/usr/bin/env bash
# judge.sh — Stop hook. OPT-IN goal loop with a decorrelated LLM judge.
#
# Prefer the native `/goal` command for most cases. Use THIS only when you want
# a *different model* judging on the *autointerp API key* (off your subscription
# pool) — e.g. a cheap Haiku judge grinding a peer to spec overnight.
#
# Only fires when a SPEC.md exists in the agent's cwd, so casual sessions are
# never forced to loop. Re-injects "keep working" with a punch-list until the
# spec's acceptance criteria are met.
#
# Input: JSON on stdin (.stop_hook_active, .cwd)
# Output: allow stop -> exit 0; block stop -> {decision:"block",reason} on stdout
set -euo pipefail

input="$(cat)"

# break infinite loops: if we already blocked this turn, let it stop.
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

proj="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
proj="${proj:-$PWD}"
spec="${proj}/SPEC.md"
[ -f "$spec" ] || exit 0

# judge runs on the autointerp key (separate billing), NOT the subscription.
key="${AUTOINTERP_ANTHROPIC_API_KEY:-}"
[ -z "$key" ] && exit 0

# --bare = skip CLAUDE.md/settings/MCP discovery -> ~10x faster headless start.
verdict="$(cd "$proj" && ANTHROPIC_API_KEY="$key" \
  claude -p --bare --model "${JUDGE_MODEL:-claude-haiku-4-5-20251001}" \
  --allowedTools "Bash,Read,Grep,Glob" \
  "You are a strict completion judge. Task spec:
$(cat "$spec")

Inspect the repo (git diff, read changed files, run the tests named in the spec).
Reply EXACTLY 'DONE' on the first line if every acceptance criterion is met.
Otherwise reply 'NOT_DONE' then a short, specific punch-list of what is missing." \
  2>/dev/null || true)"

# empty verdict (judge failed) -> don't trap the agent; allow the stop.
[ -z "$verdict" ] && exit 0

printf '%s' "$verdict" | grep -q '^DONE' && exit 0

reason="$(printf '%s' "$verdict" | sed 's/^NOT_DONE//')"
[ -z "${reason// /}" ] && exit 0
jq -n --arg r "Judge: not finished — keep working.${reason}" '{decision:"block",reason:$r}'
