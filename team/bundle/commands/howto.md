---
description: Remind me what this agent harness can do and how to drive it
---

Print this harness cheat-sheet to the operator **verbatim** as a fenced block.
Do not act on it, do not run anything — just display it.

```
agent harness — quick reference

drive the team
  team                      launch main + peers (auto-sized to GPUs)
  team status | team stop   list / tear down (worktrees + branches kept)
  claude agents             LIVE dashboard: every session by status
  tmux attach -t main       talk to the orchestrator you steer
  msg <name> "<text>"       message another agent   (msg list = roster)
  /peers                    snapshot of what each peer is working on

get work done
  talk to main              it assigns one experiment IDEA per peer
  (in a peer) "use a workflow to ... use 50k tokens"
                            fan out ephemeral subagents w/ adversarial verify
  /goal <condition>         keep a peer working until criteria pass
  SPEC.md                   drop one (see SPEC.template.md) to arm goal loop + judge
  /loop 1h <prompt>         overnight cadence ON THE POD
                            (NOT /schedule — that runs off-pod, no GPUs)

watch-outs
  - one peer's workflow at a time: token burn is multiplicative on the one
    subscription pool — check /usage before a big fan-out
  - keep research workflow subagents NON-isolated (they read + run evals)
  - interactive turns = subscription; ANTHROPIC_API_KEY is autointerp/judge only
  - guard hook blocks force-push, /workspace deletion, .env exfil — even in auto mode
  - prefer auto mode (shift+tab) over --dangerously-skip-permissions

reset
  name pool:  > "$TEAM_DIR/state/used_names"
```
