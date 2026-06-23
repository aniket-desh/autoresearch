#!/usr/bin/env bash
# msg — deliver a message into another agent's Claude Code session.
#
#   msg <agent> <text...>     inject text as a user turn in that agent's session
#   msg list                  list live agents (tmux sessions + windows)
#
# This is the agent-to-agent primitive: `msg gauss "verify the eigenvector step"`
# lands in Gauss's prompt as a user message, so peers actually respond to each
# other instead of ignoring messages. Wakes an idle interactive agent.
set -euo pipefail

SESSION_PREFIX="${SESSION_PREFIX:-}"

list() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null || { echo "no team running"; return; }
}

if [ "${1:-}" = "list" ] || [ -z "${1:-}" ]; then
  list; exit 0
fi

target="$1"; shift || true
[ -n "${1:-}" ] || { echo "usage: msg <agent|list> <text...>" >&2; exit 1; }
from="${AGENT_NAME:-human}"

# resolve target -> a tmux send-keys target.
# 1) a session whose name is <target> or <prefix><target>
# 2) a window named <target> in any session -> session:window
resolve() {
  local t="$1"
  for cand in "$t" "${SESSION_PREFIX}${t}"; do
    if tmux has-session -t "=${cand}" 2>/dev/null; then echo "${cand}"; return 0; fi
  done
  local hit
  hit="$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
        | awk -v n="$t" '$2==n{print $1; exit}')"
  [ -n "$hit" ] && { echo "$hit"; return 0; }
  return 1
}

tgt="$(resolve "$target")" || { echo "msg: no such agent '${target}' (try: msg list)" >&2; exit 1; }

# send the text, then Enter separately: TUIs drop a fused paste+submit, so we
# split them with a short pause.
tmux send-keys -t "$tgt" "[from ${from}] $*"
sleep 0.2
tmux send-keys -t "$tgt" C-m
