#!/usr/bin/env bash
# postcompact.sh — PostCompact hook.
#
# After a compaction, the orchestrator can forget who its peers are and the
# reports-on-demand protocol. Re-inject the roster + protocol so `main` keeps
# steering the team correctly. Harmless for peers (they just get a short
# reminder of the protocol).
#
# Input: JSON on stdin (unused). Output: additionalContext re-injected.
set -euo pipefail
cat >/dev/null 2>&1 || true   # drain stdin

roster="$(msg list 2>/dev/null | paste -sd, - 2>/dev/null || true)"
me="${AGENT_NAME:-this agent}"

reason="[team protocol — re-injected after compaction]
You are \"${me}\". Live teammates: ${roster:-<run: msg list>}.
- Delegate/report with: msg <name> \"<text>\"
- Peers own one experiment idea each and write full output to \$TEAM_REPORTS/<name>.md,
  pinging one line. Read report files on demand; keep context lean.
- main is the only agent that talks to the human."

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PostCompact",additionalContext:$r}}'
