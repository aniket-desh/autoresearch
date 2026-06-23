---
description: Snapshot of what each peer is working on (sessions + latest report + last commit)
allowed-tools: Bash(tmux:*), Bash(tail:*), Bash(basename:*), Bash(ls:*), Bash(git:*), Bash(printf:*), Bash(id:*)
---

Live sessions:
!`tmux list-sessions -F '#{session_name}  (#{?session_attached,attached,detached})' 2>/dev/null || echo "no team running"`

Latest report line per peer:
!`R="${TEAM_REPORTS:-${TEAM_DIR:-/workspace/$(id -un)/.team}/reports}"; if ls "$R"/*.md >/dev/null 2>&1; then for f in "$R"/*.md; do n="$(basename "$f" .md)"; printf '  %-12s %s\n' "$n" "$(tail -n 1 "$f" 2>/dev/null)"; done; else echo "  (no reports yet)"; fi`

Last commit on each peer branch:
!`git for-each-ref --format='  %(refname:short)  %(committerdate:relative)  %(subject)' refs/heads/agent/ 2>/dev/null || echo "  (no agent/* branches yet)"`

From the data above, give me a **compact table**: peer | session (alive?) | latest update | last commit. Then one line flagging anyone who looks idle, stuck, or has no recent report. Do not take any other action.
