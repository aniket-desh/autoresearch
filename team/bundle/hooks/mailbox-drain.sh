#!/usr/bin/env bash
# mailbox-drain.sh — optional Stop hook for fully-autonomous (unattended) runs.
#
# OFF by default. The default messaging path is `msg` (tmux send-keys), which
# wakes an idle interactive agent immediately. But a headless/autonomous agent
# with no TTY won't receive send-keys, so for overnight unattended teams use a
# file mailbox instead: senders append a line to $TEAM_MAILBOX/<recipient>, and
# this hook delivers queued mail as the agent's next turn before it rests.
#
# Enable by (a) launching with TEAM_AUTONOMOUS=1 and (b) adding this script to
# the Stop hooks array. Paired sender:
#     echo "[from <me>] <text>" >> "$TEAM_MAILBOX/<recipient>"
#
# Input: JSON on stdin (.stop_hook_active). Output: block w/ queued msgs, or exit 0.
set -euo pipefail

[ "${TEAM_AUTONOMOUS:-0}" = "1" ] || exit 0

input="$(cat)"
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

box="${TEAM_MAILBOX:-/workspace/$(id -un)/.team/mailbox}/${AGENT_NAME:-unknown}"
[ -s "$box" ] || exit 0

msgs="$(cat "$box")"
: > "$box"   # drain atomically enough for our purposes
jq -n --arg r "Queued messages from teammates:
${msgs}" '{decision:"block",reason:$r}'
