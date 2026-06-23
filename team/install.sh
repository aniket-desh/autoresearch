#!/usr/bin/env bash
# install.sh — install the agent-team layer onto a pod. Idempotent.
#
# Run as the non-root user after Claude Code is installed. Fetched + invoked by
# setup.sh (step [6.5/7]), or run by hand.
#
# Two source modes:
#   - remote (default): curl each file from $AGENTS_RAW (raw.githubusercontent…)
#   - local:            if AGENTS_LOCAL=<path-to-agents-checkout> is set, copy
#                       from there instead (used for testing + offline installs)
#
# Installs:
#   ~/.local/bin/{team,msg}                      launchers on PATH
#   $TEAM_DIR/state/names.txt                     name pool (sampled w/o replacement)
#   $CLAUDE_CONFIG_DIR/agents/{main,peer}.md      roles
#   $CLAUDE_CONFIG_DIR/skills/...                 thermonuclear-review
#   $CLAUDE_CONFIG_DIR/hooks/*.sh                 guard/judge/postcompact/mailbox/worktree
#   $CLAUDE_CONFIG_DIR/settings.json             permissions.deny + hook wiring (only if absent)
# and persists CLAUDE_CONFIG_DIR / TEAM_DIR / PATH into the shell rc files so
# you log in ONCE and it survives pod restarts (CLAUDE_CONFIG_DIR is on /workspace).
set -euo pipefail

USER_NAME="$(id -un)"
WORKSPACE="/workspace/${USER_NAME}"
CFG="${CLAUDE_CONFIG_DIR:-${WORKSPACE}/.claude}"
TEAM_DIR="${TEAM_DIR:-${WORKSPACE}/.team}"
BIN="${HOME}/.local/bin"
AGENTS_RAW="${AGENTS_RAW:-https://raw.githubusercontent.com/aniket-desh/agents/main}"
AGENTS_LOCAL="${AGENTS_LOCAL:-}"

# fetch <repo-relative-path> <dest> : copy from local checkout or curl remote.
fetch() {
  local rel="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -n "$AGENTS_LOCAL" ]; then
    cp "${AGENTS_LOCAL}/${rel}" "$dest"
  else
    curl -fsSL "${AGENTS_RAW}/${rel}" -o "$dest"
  fi
}

echo ">> installing agent-team layer"
echo "   source : ${AGENTS_LOCAL:-$AGENTS_RAW}"
echo "   config : ${CFG}"
echo "   team   : ${TEAM_DIR}"

mkdir -p "${CFG}/hooks" "${CFG}/agents" "${CFG}/commands" \
         "${CFG}/skills/thermonuclear-review" \
         "${TEAM_DIR}/state" "${TEAM_DIR}/reports" "${TEAM_DIR}/mailbox" "${BIN}"

# 1. launchers on PATH
fetch team/team.sh "${BIN}/team"; chmod +x "${BIN}/team"
fetch team/msg.sh  "${BIN}/msg";  chmod +x "${BIN}/msg"

# 2. name pool (only seed if missing, so used-name tracking survives reinstalls)
if [ ! -s "${TEAM_DIR}/state/names.txt" ]; then
  fetch team/names.txt "${TEAM_DIR}/state/names.txt"
fi
touch "${TEAM_DIR}/state/used_names"

# 3. roles + skill + slash commands
fetch team/bundle/agents/main.md "${CFG}/agents/main.md"
fetch team/bundle/agents/peer.md "${CFG}/agents/peer.md"
fetch team/bundle/skills/thermonuclear-review/SKILL.md "${CFG}/skills/thermonuclear-review/SKILL.md"
fetch team/bundle/commands/howto.md "${CFG}/commands/howto.md"
fetch team/bundle/commands/peers.md "${CFG}/commands/peers.md"

# 4. hooks
for h in guard judge postcompact mailbox-drain worktree-link; do
  fetch "team/bundle/hooks/${h}.sh" "${CFG}/hooks/${h}.sh"
  chmod +x "${CFG}/hooks/${h}.sh"
done

# 5. settings.json — substitute the real config dir; never clobber an edited one.
if [ ! -f "${CFG}/settings.json" ]; then
  tmp="$(mktemp)"
  fetch team/bundle/settings.json "$tmp"
  sed "s#__CFG__#${CFG}#g" "$tmp" > "${CFG}/settings.json"
  rm -f "$tmp"
  echo "   wrote ${CFG}/settings.json"
else
  echo "   ${CFG}/settings.json exists — left untouched"
fi

# 6. persist env across shells AND pod restarts
add_rc() {
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    grep -qF "$1" "$rc" 2>/dev/null || echo "$1" >> "$rc"
  done
}
add_rc 'export PATH="$HOME/.local/bin:$PATH"'
add_rc "export CLAUDE_CONFIG_DIR=\"${CFG}\""
add_rc "export TEAM_DIR=\"${TEAM_DIR}\""

cat <<DONE

=== agent-team layer installed ===
  CLAUDE_CONFIG_DIR : ${CFG}   (creds + settings on /workspace -> survive restarts)
  TEAM_DIR          : ${TEAM_DIR}
  launchers         : ${BIN}/team , ${BIN}/msg

ONE-TIME LOGIN (subscription — do NOT paste an API key):
  claude                       # complete /login once; creds saved under ${CFG}
THEN:
  cd ${WORKSPACE}/<project> && team
DONE
