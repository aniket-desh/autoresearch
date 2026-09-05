#!/usr/bin/env bash
# setup.sh — generic runpod bootstrap for mech-interp / ai research projects.
#
# Bootstraps a fresh runpod from absolute zero (root ssh, blank
# /workspace volume) to "tmux + an agent CLI running as a non-root user
# inside a uv venv", in one curl-pipe-bash invocation.
#
# usage (as root, from a fresh pod):
#
#     curl -fsSL https://raw.githubusercontent.com/aniket-desh/agents/main/setup.sh \
#       | REPO=https://github.com/<owner>/<repo>.git \
#         BRANCH=<branch> \
#         USER_NAME=<user> \
#         bash
#
# configurable env vars (each has a sensible default unless marked required):
#   REPO            REQUIRED        repo to clone (e.g. https://github.com/me/proj.git)
#   BRANCH          REQUIRED        branch to check out
#   USER_NAME       'researcher'    non-root user to create + run the agent CLI as
#   TMUX_SESSION    "${USER_NAME}"  tmux session name printed in instructions
#   KICKOFF_PROMPT  ''              first prompt to paste into the agent CLI
#                                    (printed at end if set)
#   REPO_DIR_NAME   <repo basename> directory to clone into under /workspace/<user>
#   PROJECT_SUBDIR  ''              python project path inside the cloned repo
#   AGENT_CLI       'codex'         codex or claude
#   INSTALL_TEAM    '0'             install the legacy Claude team layer (0 or 1)
#
# If the project ships scripts/runpod_{setup,activate}.sh, they are used.
# Otherwise the generic helpers from this repo run from outside the checkout,
# so bootstrapping never dirties the research tree.
#
# idempotent: re-running on a half-set-up pod is safe.
#
# bugs hit on real pods that this script handles:
#   - mkdir /workspace/.cache eacces — pre-create as root with chmod 777
#   - LANG='' in current root shell after script — also export here
#   - npm install -g eacces /usr/lib/node_modules — set npm prefix first
#   - agent CLI not found in tmux — print loud "switch to user FIRST" warning
#   - PATH not inherited by non-interactive shells — write to both .bashrc + .profile

set -euo pipefail

USER_NAME="${USER_NAME:-researcher}"
BRANCH="${BRANCH:-}"
REPO="${REPO:-}"
TMUX_SESSION="${TMUX_SESSION:-${USER_NAME}}"
KICKOFF_PROMPT="${KICKOFF_PROMPT:-}"
PROJECT_SUBDIR="${PROJECT_SUBDIR:-}"
AGENT_CLI="${AGENT_CLI:-codex}"
INSTALL_TEAM="${INSTALL_TEAM:-0}"
WORKSPACE="/workspace/${USER_NAME}"

# base raw URL for THIS repo (the agents setup repo). every fetch below derives
# from it, so renaming the GitHub repo is a one-line change here (or override
# AGENTS_RAW in the environment to point at a fork/branch).
AGENTS_RAW="${AGENTS_RAW:-https://raw.githubusercontent.com/aniket-desh/agents/main}"

case "${AGENT_CLI}" in
    codex)
        AGENT_PACKAGE=""
        AGENT_INSTALL_HINT="curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        AGENT_AUTH_HINT="codex login --device-auth"
        AGENT_LAUNCH="codex --sandbox workspace-write --approve-for-me"
        ;;
    claude)
        AGENT_PACKAGE="@anthropic-ai/claude-code"
        AGENT_INSTALL_HINT="npm config set prefix \"\$HOME/.npm-global\" && npm install -g @anthropic-ai/claude-code"
        AGENT_AUTH_HINT="claude  # complete subscription login, then exit"
        AGENT_LAUNCH="claude --dangerously-skip-permissions"
        ;;
    *)
        echo "ERROR: AGENT_CLI must be 'codex' or 'claude' (got '${AGENT_CLI}')." >&2
        exit 1
        ;;
esac

case "${PROJECT_SUBDIR}" in
    /*|../*|*/../*|*/..)
        echo "ERROR: PROJECT_SUBDIR must be a relative path within the repository." >&2
        exit 1
        ;;
esac

case "${INSTALL_TEAM}" in
    0|1) ;;
    *)
        echo "ERROR: INSTALL_TEAM must be 0 or 1 (got '${INSTALL_TEAM}')." >&2
        exit 1
        ;;
esac

if [ "${INSTALL_TEAM}" = "1" ] && [ "${AGENT_CLI}" != "claude" ]; then
    echo "ERROR: the legacy team layer requires AGENT_CLI=claude." >&2
    exit 1
fi

if [ -z "${REPO}" ] || [ -z "${BRANCH}" ]; then
    cat <<EOM >&2
ERROR: REPO and BRANCH env vars are required. example:

    curl -fsSL https://raw.githubusercontent.com/aniket-desh/agents/main/setup.sh \\
      | REPO=https://github.com/me/myproject.git \\
        BRANCH=main \\
        USER_NAME=me \\
        bash
EOM
    exit 1
fi

# infer repo dir from URL basename (strip .git).
REPO_DIR_NAME="${REPO_DIR_NAME:-$(basename "${REPO}" .git)}"
REPO_DIR="${WORKSPACE}/${REPO_DIR_NAME}"
PROJECT_DIR="${REPO_DIR}${PROJECT_SUBDIR:+/${PROJECT_SUBDIR}}"
PROVISION_DIR="${WORKSPACE}/.agents/provision"

if [ "$(id -u)" -ne 0 ]; then
    cat <<EOM >&2
ERROR: this script must run as root (runpod's ssh lands as root by default).

if you've already done the root-side bits, finish manually as the user:

    su - ${USER_NAME}
    cd ${PROJECT_DIR}
    export RUNPOD_PROJECT_DIR=${PROJECT_DIR}
    bash ${PROVISION_DIR}/runpod_setup.sh
    nano .env
    source ${PROVISION_DIR}/runpod_activate.sh
    ${AGENT_INSTALL_HINT}
    ${AGENT_AUTH_HINT}
    tmux new-session -A -s ${TMUX_SESSION}
    ${AGENT_LAUNCH}
EOM
    exit 1
fi

echo "=== [1/7] system packages (as root) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
# locales gives us en_US.UTF-8 so the agent CLI's box-drawing + emoji
# render. fonts-noto-color-emoji covers the emoji glyphs the CLI
# uses for status icons. both required for symbols not to appear as ?.
# jq is required by the agent-team hooks (guard/judge/postcompact parse the
# hook JSON on stdin with it).
apt-get install -y curl ca-certificates gnupg tmux vim nano less git gh jq ripgrep \
    locales fonts-noto-color-emoji >/dev/null

# generate en_US.UTF-8 + set as system default. note: only takes effect
# for FUTURE shells (login shells read /etc/default/locale). the current
# root shell will still show LANG='' until you export manually or
# re-login. we export below for THIS script + write to root's bashrc so
# future root sessions get it.
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM="${TERM:-xterm-256color}"
add_root_bashrc() {
    grep -qF "$1" /root/.bashrc 2>/dev/null || echo "$1" >> /root/.bashrc
}
add_root_bashrc 'export LANG=en_US.UTF-8'
add_root_bashrc 'export LC_ALL=en_US.UTF-8'
add_root_bashrc 'export TERM=xterm-256color'

if [ "${AGENT_CLI}" = "claude" ] && ! command -v node >/dev/null 2>&1; then
    echo "  installing node.js 22 from nodesource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null
fi
if [ "${AGENT_CLI}" = "claude" ]; then
    echo "  node $(node --version), npm $(npm --version)"
fi

echo
echo "=== [2/7] create non-root user '${USER_NAME}' ==="
if id "${USER_NAME}" >/dev/null 2>&1; then
    echo "  user already exists"
else
    useradd -m -s /bin/bash "${USER_NAME}"
    echo "  created"
fi

# mirror ssh keys so direct `ssh ${USER_NAME}@<pod>` works next time.
if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p "/home/${USER_NAME}/.ssh"
    cp /root/.ssh/authorized_keys "/home/${USER_NAME}/.ssh/authorized_keys"
    chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.ssh"
    chmod 700 "/home/${USER_NAME}/.ssh"
    chmod 600 "/home/${USER_NAME}/.ssh/authorized_keys"
fi

# per-user workspace dir.
mkdir -p "${WORKSPACE}"
chown "${USER_NAME}:${USER_NAME}" "${WORKSPACE}" 2>/dev/null || true

echo
echo "=== [3/7] pre-create shared dirs as root (so user-side mkdirs don't eacces) ==="
# /workspace/.cache (hf model cache) needs to exist BEFORE the user-side
# runpod_setup.sh runs `mkdir -p` on it, because /workspace is sometimes
# owned by an account that doesn't include the new user. world-writable
# so any user can populate them.
mkdir -p /workspace/.cache /workspace/.cache/huggingface
chmod 777 /workspace /workspace/.cache /workspace/.cache/huggingface 2>/dev/null || true
echo "  /workspace/.cache → $(ls -ld /workspace/.cache | awk '{print $1, $3}')"

echo
echo "=== [4/7] clone + checkout ${BRANCH} as ${USER_NAME} ==="
# This repo's generic helper scripts are installed outside the cloned checkout.
# A project-specific helper under PROJECT_DIR/scripts still takes precedence.
PROVISION_RAW="${AGENTS_RAW}/provision"

su - "${USER_NAME}" <<EOF
set -euo pipefail
cd "${WORKSPACE}"
if [ ! -d "${REPO_DIR}/.git" ]; then
    git clone "${REPO}" "${REPO_DIR}"
fi
cd "${REPO_DIR}"
git fetch origin
git checkout "${BRANCH}"
git pull --ff-only origin "${BRANCH}"

# Keep generic bootstrap files outside the repo so a fresh checkout stays clean.
mkdir -p "${PROVISION_DIR}"
for f in runpod_setup.sh runpod_activate.sh; do
    curl -fsSL "${PROVISION_RAW}/\$f" -o "${PROVISION_DIR}/\$f"
done
chmod +x "${PROVISION_DIR}/runpod_setup.sh" "${PROVISION_DIR}/runpod_activate.sh"
EOF

echo
echo "=== [5/7] project setup as ${USER_NAME} (uv sync + .env template) ==="
su - "${USER_NAME}" <<EOF
set -euo pipefail
cd "${PROJECT_DIR}"
export RUNPOD_PROJECT_DIR="${PROJECT_DIR}"
if [ -f "${PROJECT_DIR}/scripts/runpod_setup.sh" ]; then
    bash "${PROJECT_DIR}/scripts/runpod_setup.sh"
else
    bash "${PROVISION_DIR}/runpod_setup.sh"
fi
EOF

if [ -f "${PROJECT_DIR}/scripts/runpod_activate.sh" ]; then
    ACTIVATE_SCRIPT="${PROJECT_DIR}/scripts/runpod_activate.sh"
else
    ACTIVATE_SCRIPT="${PROVISION_DIR}/runpod_activate.sh"
fi

echo
echo "=== [6/7] per-user shell env + ${AGENT_CLI} install (as ${USER_NAME}) ==="
su - "${USER_NAME}" -c "bash -s -- '${AGENT_CLI}' '${WORKSPACE}' '${AGENT_PACKAGE}' '${AGENTS_RAW}'" <<'EOF'
set -euo pipefail

AGENT_CLI="$1"
WORKSPACE="$2"
AGENT_PACKAGE="$3"
AGENTS_RAW="$4"

# persist env across all future shells (interactive + login + tmux).
# we write to BOTH .bashrc and .profile so non-interactive su/ssh
# sessions also inherit the correct PATH/locale.
add_to_rcs() {
    for rc in "$HOME/.bashrc" "$HOME/.profile"; do
        touch "$rc"
        grep -qF "$1" "$rc" 2>/dev/null || echo "$1" >> "$rc"
    done
}
add_to_rcs 'export PATH=$HOME/.local/bin:$HOME/.npm-global/bin:$PATH'
add_to_rcs 'export LANG=en_US.UTF-8'
add_to_rcs 'export LC_ALL=en_US.UTF-8'
# tmux strips box-drawing chars unless TERM is xterm-256color
# (or tmux-256color, set via .tmux.conf below).
add_to_rcs 'export TERM=xterm-256color'
if [ "$AGENT_CLI" = "codex" ]; then
    mkdir -p "${WORKSPACE}/.codex"
    add_to_rcs "export CODEX_HOME=${WORKSPACE}/.codex"
    export CODEX_HOME="${WORKSPACE}/.codex"
fi

# tmux config: force utf-8, 256-color + truecolor passthrough, scrollback.
cat > "$HOME/.tmux.conf" <<'TMUX'
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc,xterm*:Tc"
set -g history-limit 50000
set -g mouse on
TMUX

# export the env in THIS subshell so the install + which checks below
# see the right PATH (the .bashrc edits only affect FUTURE shells).
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color

if [ "$AGENT_CLI" = "codex" ]; then
    if ! command -v codex >/dev/null 2>&1; then
        curl -fsSL https://chatgpt.com/codex/install.sh | sh
    fi

    # Codex reads global AGENTS.md from CODEX_HOME on every new session.
    # Preserve local edits on re-bootstrap; only seed a fresh configuration.
    if [ ! -f "$CODEX_HOME/AGENTS.md" ]; then
        curl -fsSL "${AGENTS_RAW}/codex/AGENTS.md" -o "$CODEX_HOME/AGENTS.md"
    fi
    if [ ! -f "$CODEX_HOME/config.toml" ]; then
        cat > "$CODEX_HOME/config.toml" <<'CONFIG'
[agents]
enabled = true
max_concurrent_threads_per_session = 4
CONFIG
    fi
else
    # Claude Code still uses npm; keep the install in the user's home.
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    if ! command -v claude >/dev/null 2>&1; then
        npm install -g "$AGENT_PACKAGE"
    fi
fi
if command -v "$AGENT_CLI" >/dev/null 2>&1; then
    echo "  ✓ $("$AGENT_CLI" --version) at $(command -v "$AGENT_CLI")"
else
    echo "  ✗ ${AGENT_CLI} install failed; see npm output above"
    exit 1
fi
EOF

if [ "${INSTALL_TEAM}" = "1" ]; then
echo
echo "=== [6.5/7] install legacy agent-team layer (as ${USER_NAME}) ==="
# the multi-agent workflow layer: launchers (team/msg), the claude code bundle
# (roles + hooks + skill + settings) into a persistent CLAUDE_CONFIG_DIR on
# /workspace, and the name pool. rides the same curl flow; idempotent.
su - "${USER_NAME}" <<EOF
set -euo pipefail
export AGENTS_RAW="${AGENTS_RAW}"
# put claude code's config on the persistent volume so the one-time /login
# survives pod restarts.
export CLAUDE_CONFIG_DIR="${WORKSPACE}/.claude"
curl -fsSL "${AGENTS_RAW}/team/install.sh" -o /tmp/agents_install.sh
bash /tmp/agents_install.sh
EOF
else
    echo "=== [6.5/7] skip legacy agent-team layer (INSTALL_TEAM=0) ==="
fi

echo
echo "=== [7/7] stash re-bootstrap command at /workspace/bootstrap.sh ==="
# runpod stop/restart wipes the container fs (so /etc/passwd loses our user,
# apt packages disappear, node + the agent CLI are gone) but keeps /workspace.
# write a tiny bootstrap that re-runs this setup with the same env vars so
# you don't have to re-type the curl pipe after every restart — just:
#     bash /workspace/bootstrap.sh
# the script is idempotent: the cloned repo at ${REPO_DIR} (on /workspace)
# is not re-cloned, only the container-side bits get reinstalled.
cat > /workspace/bootstrap.sh <<EOF
#!/usr/bin/env bash
# auto-generated by agents/setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# re-bootstrap this pod after a runpod stop/restart (the container fs is
# wiped, but /workspace persists, so this file survives). run as root:
#
#     bash /workspace/bootstrap.sh
#
# idempotent — the cloned repo at ${REPO_DIR} is already on /workspace and
# is not re-cloned; only the user account, apt packages, node, and the agent
# CLI (which all live on the container fs) get reinstalled.

set -euo pipefail

curl -fsSL ${AGENTS_RAW}/setup.sh \\
  | AGENTS_RAW='${AGENTS_RAW}' \\
    REPO='${REPO}' \\
    BRANCH='${BRANCH}' \\
    USER_NAME='${USER_NAME}' \\
    TMUX_SESSION='${TMUX_SESSION}' \\
    REPO_DIR_NAME='${REPO_DIR_NAME}' \\
    PROJECT_SUBDIR='${PROJECT_SUBDIR}' \\
    AGENT_CLI='${AGENT_CLI}' \\
    INSTALL_TEAM='${INSTALL_TEAM}' \\
    bash
EOF
chmod 0755 /workspace/bootstrap.sh
echo "  /workspace/bootstrap.sh written (after restart: bash /workspace/bootstrap.sh)"
echo "  checkout status:"
su - "${USER_NAME}" -c "git -C '${REPO_DIR}' status --short --branch"

# ─── summary ──────────────────────────────────────────────────────────────────
cat <<INSTRUCTIONS

==========================================================================
  ✓ setup complete.

  IMPORTANT: your CURRENT root shell still has LANG='' because
  update-locale only affects FUTURE login shells. to fix this shell:
      export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color
  (you can ignore this if you're about to switch to ${USER_NAME} anyway.)

  STEP 1 — switch to non-root user (do NOT skip; tmux launched as root
            won't find ${AGENT_CLI}, and runpod_activate.sh writes to
            ~/.cache as the running user):

      su - ${USER_NAME}

  STEP 2 — fill in any project API keys in the ignored .env:

      cd ${PROJECT_DIR}
      nano .env

  STEP 3 — activate the project, then open tmux as ${USER_NAME}:

      cd ${PROJECT_DIR}
      export RUNPOD_PROJECT_DIR=${PROJECT_DIR}
      source ${ACTIVATE_SCRIPT}
      [ -n "\${GH_TOKEN:-}" ] && gh auth setup-git
      ${AGENT_AUTH_HINT}
      tmux new-session -A -s ${TMUX_SESSION}

  STEP 4 — inside tmux, launch ${AGENT_CLI} from the Git repository root:

      cd ${REPO_DIR}
      ${AGENT_LAUNCH}

INSTRUCTIONS

if [ "${AGENT_CLI}" = "codex" ]; then
    cat <<INSTRUCTIONS
  CODEX_HOME points to ${WORKSPACE}/.codex, so the login and Codex subagent
  configuration survive pod restarts.

INSTRUCTIONS
fi

if [ "${INSTALL_TEAM}" = "1" ]; then
    cat <<INSTRUCTIONS
  The legacy Claude team layer is installed. Launch it with:

      team

INSTRUCTIONS
fi

if [ -n "${KICKOFF_PROMPT}" ]; then
    cat <<INSTRUCTIONS
  Paste this first prompt to ${AGENT_CLI}:

      ${KICKOFF_PROMPT}

INSTRUCTIONS
fi

cat <<INSTRUCTIONS
  detach tmux: ctrl-b d.  reattach: tmux attach -t ${TMUX_SESSION}.

  AFTER POD RESTART: runpod wipes the container fs (user account, apt,
  node, ${AGENT_CLI}) but /workspace persists. to re-bootstrap, just ssh
  in as root and run:

      bash /workspace/bootstrap.sh

  (this file was just written with your REPO/BRANCH/USER_NAME baked in,
  so you don't need to re-type the curl command.)

  gpu layout: this script is gpu-count-agnostic. the cloned repo's run
  scripts auto-detect via nvidia-smi -L.
==========================================================================
INSTRUCTIONS
