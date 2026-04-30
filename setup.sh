#!/usr/bin/env bash
# setup.sh — generic runpod bootstrap for mech-interp / ai research projects.
#
# Bootstraps a fresh runpod from absolute zero (root ssh, blank
# /workspace volume) to "tmux + claude code running as a non-root user
# inside a uv venv", in one curl-pipe-bash invocation.
#
# usage (as root, from a fresh pod):
#
#     curl -fsSL https://raw.githubusercontent.com/aniket-desh/autoresearch/main/setup.sh \
#       | REPO=https://github.com/<owner>/<repo>.git \
#         BRANCH=<branch> \
#         USER_NAME=<user> \
#         bash
#
# configurable env vars (each has a sensible default unless marked required):
#   REPO            REQUIRED        repo to clone (e.g. https://github.com/me/proj.git)
#   BRANCH          REQUIRED        branch to check out
#   USER_NAME       'researcher'    non-root user to create + run claude code as
#   TMUX_SESSION    "${USER_NAME}"  tmux session name printed in instructions
#   KICKOFF_PROMPT  ''              first prompt to paste into claude code
#                                    (printed at end if set)
#   REPO_DIR_NAME   <repo basename> directory to clone into under /workspace/<user>
#
# the script assumes the cloned repo follows the convention:
#   scripts/runpod_setup.sh        installs uv, syncs deps, creates .env template
#   scripts/runpod_activate.sh     sources .env + verifies keys + nvidia-smi
# if those don't exist, the script still completes the user + node + claude
# code install, and prints what's missing.
#
# idempotent: re-running on a half-set-up pod is safe.
#
# bugs hit on real pods that this script handles:
#   - mkdir /workspace/.cache eacces — pre-create as root with chmod 777
#   - LANG='' in current root shell after script — also export here
#   - npm install -g eacces /usr/lib/node_modules — set npm prefix first
#   - claude not found in tmux — print loud "switch to user FIRST" warning
#   - PATH not inherited by non-interactive shells — write to both .bashrc + .profile

set -euo pipefail

USER_NAME="${USER_NAME:-researcher}"
BRANCH="${BRANCH:-}"
REPO="${REPO:-}"
TMUX_SESSION="${TMUX_SESSION:-${USER_NAME}}"
KICKOFF_PROMPT="${KICKOFF_PROMPT:-}"
WORKSPACE="/workspace/${USER_NAME}"

if [ -z "${REPO}" ] || [ -z "${BRANCH}" ]; then
    cat <<EOM >&2
ERROR: REPO and BRANCH env vars are required. example:

    curl -fsSL https://raw.githubusercontent.com/aniket-desh/autoresearch/main/setup.sh \\
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

if [ "$(id -u)" -ne 0 ]; then
    cat <<EOM >&2
ERROR: this script must run as root (runpod's ssh lands as root by default).

if you've already done the root-side bits, finish manually as the user:

    su - ${USER_NAME}
    cd ${REPO_DIR}
    bash scripts/runpod_setup.sh
    nano .env
    source scripts/runpod_activate.sh
    npm config set prefix "\$HOME/.npm-global"
    npm install -g @anthropic-ai/claude-code
    export PATH="\$HOME/.npm-global/bin:\$PATH"
    tmux new -s ${TMUX_SESSION}
    claude --dangerously-skip-permissions
EOM
    exit 1
fi

echo "=== [1/6] system packages (as root) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
# locales gives us en_US.UTF-8 so claude code's box-drawing + emoji
# render. fonts-noto-color-emoji covers the emoji glyphs claude code
# uses for status icons. both required for symbols not to appear as ?.
apt-get install -y curl ca-certificates gnupg tmux vim nano less git \
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

if ! command -v node >/dev/null 2>&1; then
    echo "  installing node.js 22 from nodesource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null
fi
echo "  node $(node --version), npm $(npm --version)"

echo
echo "=== [2/6] create non-root user '${USER_NAME}' ==="
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
echo "=== [3/6] pre-create shared dirs as root (so user-side mkdirs don't eacces) ==="
# /workspace/.cache (hf model cache) needs to exist BEFORE the user-side
# runpod_setup.sh runs `mkdir -p` on it, because /workspace is sometimes
# owned by an account that doesn't include the new user. world-writable
# so any user can populate them.
mkdir -p /workspace/.cache /workspace/.cache/huggingface
chmod 777 /workspace /workspace/.cache /workspace/.cache/huggingface 2>/dev/null || true
echo "  /workspace/.cache → $(ls -ld /workspace/.cache | awk '{print $1, $3}')"

echo
echo "=== [4/6] clone + checkout ${BRANCH} as ${USER_NAME} ==="
# autoresearch's bundled fallback helper scripts. used by step [5/6] if
# the cloned project repo doesn't ship its own scripts/runpod_*.sh.
AUTORESEARCH_RAW="https://raw.githubusercontent.com/aniket-desh/autoresearch/main/scripts"

su - "${USER_NAME}" <<EOF
set -euo pipefail
cd "${WORKSPACE}"
if [ ! -d "${REPO_DIR}/.git" ]; then
    git clone "${REPO}" "${REPO_DIR}"
fi
cd "${REPO_DIR}"
git fetch origin
git checkout "${BRANCH}"
git pull --ff-only origin "${BRANCH}" || true

# fall back to autoresearch's bundled helpers if the project doesn't
# ship its own. only install if missing — never overwrite.
mkdir -p scripts
for f in runpod_setup.sh runpod_activate.sh; do
    if [ ! -f "scripts/\$f" ]; then
        echo "  fetching autoresearch's \$f (project repo doesn't ship one)"
        curl -fsSL "${AUTORESEARCH_RAW}/\$f" -o "scripts/\$f"
    fi
done
chmod +x scripts/runpod_setup.sh scripts/runpod_activate.sh 2>/dev/null || true
EOF

echo
echo "=== [5/6] run scripts/runpod_setup.sh as ${USER_NAME} (uv sync + .env template) ==="
su - "${USER_NAME}" <<EOF
set -euo pipefail
cd "${REPO_DIR}"
bash scripts/runpod_setup.sh
EOF

echo
echo "=== [6/6] per-user shell env + claude code install (as ${USER_NAME}) ==="
su - "${USER_NAME}" <<'EOF'
set -euo pipefail

# persist env across all future shells (interactive + login + tmux).
# we write to BOTH .bashrc and .profile so non-interactive su/ssh
# sessions also inherit the correct PATH/locale.
add_to_rcs() {
    for rc in "$HOME/.bashrc" "$HOME/.profile"; do
        touch "$rc"
        grep -qF "$1" "$rc" 2>/dev/null || echo "$1" >> "$rc"
    done
}
add_to_rcs 'export PATH=$HOME/.npm-global/bin:$PATH'
add_to_rcs 'export LANG=en_US.UTF-8'
add_to_rcs 'export LC_ALL=en_US.UTF-8'
# tmux strips claude code's box-drawing chars unless TERM is xterm-256color
# (or tmux-256color, set via .tmux.conf below).
add_to_rcs 'export TERM=xterm-256color'

# tmux config: force utf-8, 256-color + truecolor passthrough, scrollback.
cat > "$HOME/.tmux.conf" <<'TMUX'
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc,xterm*:Tc"
set -g history-limit 50000
set -g mouse on
TMUX

# set npm prefix BEFORE installing so the global install lands in the
# user's home rather than /usr/lib/node_modules (which requires root).
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
NPM_PREFIX_NOW=$(npm config get prefix)
echo "  npm prefix = ${NPM_PREFIX_NOW}"
if [ "${NPM_PREFIX_NOW}" != "${HOME}/.npm-global" ]; then
    echo "  WARNING: npm prefix is not ${HOME}/.npm-global; install may eacces."
fi

# export the env in THIS subshell so the install + which checks below
# see the right PATH (the .bashrc edits only affect FUTURE shells).
export PATH="$HOME/.npm-global/bin:$PATH"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color

# install loudly (no /dev/null redirect, so eacces or network errors
# are visible; previous quiet install was masking failures).
if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
fi
if command -v claude >/dev/null 2>&1; then
    echo "  ✓ claude $(claude --version) at $(which claude)"
else
    echo "  ✗ claude install failed; see npm output above"
    exit 1
fi
EOF

# ─── summary ──────────────────────────────────────────────────────────────────
cat <<INSTRUCTIONS

==========================================================================
  ✓ setup complete.

  IMPORTANT: your CURRENT root shell still has LANG='' because
  update-locale only affects FUTURE login shells. to fix this shell:
      export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color
  (you can ignore this if you're about to switch to ${USER_NAME} anyway.)

  STEP 1 — switch to non-root user (do NOT skip; tmux launched as root
            won't find claude code, and runpod_activate.sh writes to
            ~/.cache as the running user):

      su - ${USER_NAME}

  STEP 2 — fill in api keys in .env:

      cd ${REPO_DIR}
      nano .env

  STEP 3 — open tmux as ${USER_NAME} and launch claude code:

      tmux new -s ${TMUX_SESSION}
      # inside tmux:
      cd ${REPO_DIR}
      source scripts/runpod_activate.sh
      claude --dangerously-skip-permissions

INSTRUCTIONS

if [ -n "${KICKOFF_PROMPT}" ]; then
    cat <<INSTRUCTIONS
  STEP 4 — paste this first prompt to claude code:

      ${KICKOFF_PROMPT}

INSTRUCTIONS
fi

cat <<INSTRUCTIONS
  detach tmux: ctrl-b d.  reattach: tmux attach -t ${TMUX_SESSION}.

  gpu layout: this script is gpu-count-agnostic. the cloned repo's run
  scripts auto-detect via nvidia-smi -L.
==========================================================================
INSTRUCTIONS
