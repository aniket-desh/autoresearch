#!/bin/bash
# runpod_activate.sh — source this in every new shell.
#
#   source scripts/runpod_activate.sh
#
# loads .env, activates the uv-managed venv, sets sane defaults for
# online-friendly tooling, prints a one-line status. idempotent.

# RUNPOD_PROJECT_DIR may select a nested Python project. Keep the Git root
# separately so agents can still reason about the full checkout.
PROJECT_ROOT="${RUNPOD_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_ROOT" || return 1 2>/dev/null || exit 1
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# load api keys + cache config from .env if present.
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

# --- billing safety -----------------------------------------------------------
# CRITICAL: if ANTHROPIC_API_KEY is exported when you launch `claude`, Claude
# Code bills your interactive turns at API pay-as-you-go rates EVEN IF you're
# logged in on a subscription — the key takes precedence over the OAuth login.
# We want the opposite: interactive turns on the $200 subscription, and the API
# key reserved for headless autointerp / LLM-judge calls only.
#
# So: stash the key under a name Claude Code ignores, then alias `claude` to
# launch with the key stripped from its environment. Hooks/scripts that DO want
# the autointerp key read AUTOINTERP_ANTHROPIC_API_KEY and re-inject it.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    export AUTOINTERP_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
fi
# strip the key from interactive claude launches (subscription billing).
alias claude='env -u ANTHROPIC_API_KEY claude'

# uv writes the venv to .venv by default.
if [ -f .venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source .venv/bin/activate
fi

# uv installer drops binaries here.
export PATH="$HOME/.local/bin:$PATH"

# claude code's npm-global location (oneshot installs it here for the user).
[ -d "$HOME/.npm-global/bin" ] && export PATH="$HOME/.npm-global/bin:$PATH"

# put the Python project on the import path so `from <pkg> import …` works
# regardless of cwd.
export PYTHONPATH="$PROJECT_ROOT${PYTHONPATH:+:$PYTHONPATH}"

# tqdm progress bars work better unbuffered.
export PYTHONUNBUFFERED=1

# runpod has internet (unlike trillium); make sure offline flags are off.
unset HF_HUB_OFFLINE TRANSFORMERS_OFFLINE 2>/dev/null || true

# locale + term (idempotent — oneshot already wrote these to .bashrc, but
# in case this script is sourced in a context where they weren't loaded).
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export TERM="${TERM:-xterm-256color}"

# one-line status print so the user knows the env is loaded + which keys
# are set (without echoing the keys themselves).
echo "(runpod) repo:    $REPO_ROOT"
echo "  project:        $PROJECT_ROOT"
[ -n "${ANTHROPIC_API_KEY:-}" ] && echo "  ANTHROPIC_API_KEY: set (autointerp/judge only — stripped from interactive claude)" || echo "  ANTHROPIC_API_KEY: missing"
[ -n "${HF_TOKEN:-}" ]          && echo "  HF_TOKEN:          set"   || echo "  HF_TOKEN:          missing"
[ -n "${GH_TOKEN:-}" ]          && echo "  GH_TOKEN:          set"   || echo "  GH_TOKEN:          missing"
[ -n "${WANDB_API_KEY:-}" ]     && echo "  WANDB_API_KEY:     set"   || echo "  WANDB_API_KEY:     (optional)"
command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader \
    || echo "  (no nvidia-smi — gpu pod check skipped)"
