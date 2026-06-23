#!/usr/bin/env bash
# guard.sh — PreToolUse(Bash) guard.
#
# Protects REMOTE + PERSISTENT + SECRET state on the pod. Local-ephemeral
# destruction is intentionally allowed: the pod's container fs is disposable,
# so `rm` of a scratch dir is fine, but deleting /workspace (persistent),
# force-pushing (remote), or exfiltrating .env (secret) is not.
#
# Fires even under auto mode / --dangerously-skip-permissions: a PreToolUse
# hook that returns a "deny" decision blocks the call before permission rules
# are evaluated.
#
# Input: JSON on stdin with .tool_input.command
# Output: deny -> JSON decision on stdout (exit 0); allow -> exit 0, no output
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

shopt -s nocasematch

# --- persistent volume -------------------------------------------------------
case "$cmd" in
  *"rm "*"-rf"*"/workspace"*|*"rm "*"-fr"*"/workspace"*|*"rm -r "*"/workspace"*)
    deny "blocked: /workspace is the persistent volume — refusing to delete it" ;;
esac

# --- remote git state --------------------------------------------------------
case "$cmd" in
  *"git push"*"--force"*|*"git push"*" -f"*)
    deny "blocked: force-push to remote" ;;
  *"git push"*"--delete"*|*"git push"*" :"*)
    deny "blocked: deleting a remote branch" ;;
esac

# --- destroying tracked experiment state -------------------------------------
case "$cmd" in
  *wandb*delete*)
    deny "blocked: deleting wandb runs/artifacts" ;;
  *"gh repo delete"*|*"gh release delete"*)
    deny "blocked: deleting a GitHub repo/release" ;;
esac

# --- secret exfiltration: reading .env / dumping env, piped to the network ---
reads_secret=0
case "$cmd" in
  *.env*|*printenv*|*"env |"*|*"env|"*) reads_secret=1 ;;
esac
hits_network=0
case "$cmd" in
  *curl*|*wget*|*" nc "*|*netcat*|*"/dev/tcp/"*) hits_network=1 ;;
esac
if [ "$reads_secret" = 1 ] && [ "$hits_network" = 1 ]; then
  deny "blocked: looks like secret/.env exfiltration over the network"
fi

exit 0
