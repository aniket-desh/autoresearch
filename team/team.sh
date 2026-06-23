#!/usr/bin/env bash
# team.sh — launch a Claude Code research team on one pod.
#
# main (orchestrator, you talk to it) + N persistent peers, each in its own git
# worktree + tmux session, names sampled without replacement, GPU partitioned
# to the pod, staggered launches to dodge the subscription burst limiter.
#
#   team                 # auto-size from GPU count
#   TEAM=3 team          # force 3 peers
#   team status          # list sessions
#   team stop            # kill team sessions (worktrees + branches kept)
#
# env:
#   TEAM            force peer count (else auto from nvidia-smi)
#   STAGGER         seconds between launches (default 8; burst limiter)
#   TEAM_NATIVE     1 (default) use `claude --worktree --tmux`; 0 = manual fallback
#   DRYRUN          1 = print the launch plan, don't spawn anything
#   AUTO_COMPACT    main's CLAUDE_CODE_AUTO_COMPACT_WINDOW (default 400000)
set -euo pipefail

STAGGER="${STAGGER:-8}"
TEAM_NATIVE="${TEAM_NATIVE:-1}"
AUTO_COMPACT="${AUTO_COMPACT:-400000}"
USER_NAME="$(id -un)"
TEAM_DIR="${TEAM_DIR:-/workspace/${USER_NAME}/.team}"
STATE="${TEAM_DIR}/state"; REPORTS="${TEAM_DIR}/reports"; MAILBOX="${TEAM_DIR}/mailbox"
NAMES_FILE="${NAMES_FILE:-${STATE}/names.txt}"
SESSION_PREFIX="${SESSION_PREFIX:-}"   # optional prefix for tmux session names

REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -z "${REPO_DIR}" ] || [ ! -d "${REPO_DIR}/.git" ]; then
  echo "team: run from inside your cloned project (or set REPO_DIR=)" >&2; exit 1
fi
cd "${REPO_DIR}"
BASE="$(git branch --show-current 2>/dev/null || echo main)"
WT_ROOT="$(dirname "${REPO_DIR}")/worktrees"

# NOTE: every claude launch below goes through `env -u ANTHROPIC_API_KEY claude`
# so interactive turns bill the subscription, not the autointerp API key.

# --- subcommands -------------------------------------------------------------
case "${1:-up}" in
  status) tmux list-sessions 2>/dev/null | grep -E "^(main|${SESSION_PREFIX})" || echo "no team running"; exit 0 ;;
  stop)
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
      case "$s" in main|"${SESSION_PREFIX}"*) tmux kill-session -t "$s" 2>/dev/null || true ;; esac
    done
    echo "team stopped (worktrees + branches kept under ${WT_ROOT})"; exit 0 ;;
esac

mkdir -p "${STATE}" "${REPORTS}" "${MAILBOX}" "${WT_ROOT}"
[ -s "${NAMES_FILE}" ] || { echo "team: name pool ${NAMES_FILE} missing/empty (run team/install.sh)" >&2; exit 1; }

# --- size the team from GPUs unless TEAM is set ------------------------------
mapfile -t GPUS < <(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr -d ' ' || true)
NGPU="${#GPUS[@]}"
if [ -n "${TEAM:-}" ]; then K="${TEAM}"
elif (( NGPU <= 1 )); then K=2
elif (( NGPU >= 6 )); then K=6
else K="${NGPU}"; fi

# --- sample K names without replacement --------------------------------------
touch "${STATE}/used_names"
mapfile -t NAMES < <(comm -23 <(tr 'A-Z' 'a-z' < "${NAMES_FILE}" | sort -u) \
                              <(sort -u "${STATE}/used_names") | shuf | head -n "${K}")
if (( ${#NAMES[@]} < K )); then
  echo "team: only ${#NAMES[@]} unused names left for ${K} peers." >&2
  echo "      reset the pool with:  > ${STATE}/used_names" >&2
  exit 1
fi

# --- adaptive GPU assignment: chunk GPUs across peers ------------------------
assign_gpus() {                # echo CUDA_VISIBLE_DEVICES for peer index $1
  local i="$1"
  (( NGPU == 0 )) && { echo ""; return; }
  if (( K <= NGPU )); then
    local per=$(( NGPU / K )) rem=$(( NGPU % K )) start cnt
    if (( i < rem )); then cnt=$(( per + 1 )); start=$(( i * cnt ))
    else cnt=$per; start=$(( rem * (per + 1) + (i - rem) * per )); fi
    (( cnt < 1 )) && cnt=1
    local slice=("${GPUS[@]:start:cnt}"); (IFS=,; echo "${slice[*]}")
  else
    echo "${GPUS[$(( i % NGPU ))]}"        # more peers than GPUs -> share, round-robin
  fi
}

echo "GPUs=${NGPU}  peers=${K}  base=${BASE}  native=${TEAM_NATIVE}  stagger=${STAGGER}s"
PEER_LIST="$(IFS=, ; echo "${NAMES[*]}")"

# launch_session <name> <cwd> <agent> <extra-env...> -- <launch-style>
# style: "main" (no worktree) | "peer" (worktree)
spawn() {
  local name="$1" gpus="$2" style="$3"
  local sname="${SESSION_PREFIX}${name}"
  local common_env="AGENT_NAME=${name} TEAM_DIR=${TEAM_DIR} TEAM_REPORTS=${REPORTS} TEAM_MAILBOX=${MAILBOX}"
  [ -n "$gpus" ] && common_env="${common_env} CUDA_VISIBLE_DEVICES=${gpus}"

  if [ "$style" = "main" ]; then
    local cmd="env ${common_env} CLAUDE_CODE_AUTO_COMPACT_WINDOW=${AUTO_COMPACT} -u ANTHROPIC_API_KEY claude --agent main"
    if [ "${DRYRUN:-0}" = "1" ]; then echo "  [main] session=${sname} cwd=${REPO_DIR} gpus=[${gpus:-shared}]"; echo "         $cmd"; return; fi
    tmux new-session -d -s "${sname}" -c "${REPO_DIR}"
    tmux send-keys -t "${sname}" "${cmd}" C-m
    return
  fi

  # peer
  if [ "${TEAM_NATIVE}" = "1" ]; then
    local cmd="env ${common_env} -u ANTHROPIC_API_KEY claude --worktree ${name} --tmux --name ${sname} --agent peer"
    if [ "${DRYRUN:-0}" = "1" ]; then echo "  [peer] ${name}  gpus=[${gpus:-shared}]  (native --worktree)"; echo "         $cmd"; return; fi
    eval "${cmd}" &     # native creates the worktree + tmux session itself
  else
    # manual fallback: explicit worktree + tmux session
    local wt="${WT_ROOT}/${name}"
    if [ "${DRYRUN:-0}" = "1" ]; then echo "  [peer] ${name}  gpus=[${gpus:-shared}]  wt=${wt}  (manual)"; return; fi
    git worktree add -B "agent/${name}" "${wt}" "${BASE}" >/dev/null 2>&1 || true
    ln -sfn "${REPO_DIR}/.venv" "${wt}/.venv" 2>/dev/null || true
    ln -sfn "${REPO_DIR}/.env"  "${wt}/.env"  2>/dev/null || true
    tmux new-session -d -s "${sname}" -c "${wt}"
    tmux send-keys -t "${sname}" "env ${common_env} -u ANTHROPIC_API_KEY claude --agent peer" C-m
  fi
}

# --- spawn main, then peers (staggered) --------------------------------------
echo "spawning main (orchestrator)..."
spawn "main" "" "main"
[ "${DRYRUN:-0}" = "1" ] || sleep "${STAGGER}"

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; gpus="$(assign_gpus "$i")"
  echo "  + ${name}  gpus=[${gpus:-shared}]"
  spawn "${name}" "${gpus}" "peer"
  [ "${DRYRUN:-0}" = "1" ] || sleep "${STAGGER}"
done

# record the names as used (only on a real launch)
if [ "${DRYRUN:-0}" != "1" ]; then
  printf '%s\n' "${NAMES[@]}" >> "${STATE}/used_names"
fi

echo
echo "team up.  watch the fleet:  claude agents   (or: tmux ls)"
echo "talk to the team in the 'main' session:  tmux attach -t ${SESSION_PREFIX}main"
echo "peers: ${PEER_LIST}"
