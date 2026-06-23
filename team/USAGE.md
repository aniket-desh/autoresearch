# Operating the agent team

Once a pod is provisioned (`setup.sh`) and you've logged in once on your
subscription, `team` is on your PATH. This is the day-to-day operator guide.

## Launch

```bash
cd /workspace/<user>/<project>
team                 # main + peers, auto-sized to the pod's GPUs
TEAM=3 team          # force 3 peers
team status          # list running sessions
team stop            # kill sessions (worktrees + branches are KEPT)
```

- `claude agents` — the native live dashboard; every session grouped by
  needs-input / working / done. Better than cycling tmux.
- `/howto` — print the harness cheat-sheet in-session (forget a command? this).
- `/peers` — in-conversation snapshot: each peer's session, latest report line,
  and last commit, formatted into a table. (A slash command renders as a turn,
  not a floating popup — `claude agents` is the live popup-style dashboard.)
- `tmux attach -t main` — drop into the orchestrator you talk to.
- Peers are sessions named after mathematicians/physicists, sampled without
  replacement. Reset the pool when you've burned through it:
  `> "$TEAM_DIR/state/used_names"`.

## The two-layer loop

```
you ── talk to ──► main
        ┌────────────┼────────────┐
     Hilbert       Gauss       Poincaré      ← persistent peers, one idea each
        │            │            │
   each "use a workflow…" → ephemeral subagents (impl → 2 verifiers → fixer)
```

1. You give `main` your 3–4 experiment ideas (or just your intent and let it
   decompose).
2. `main` assigns one idea per peer with `msg <name> "<idea + acceptance>"`.
3. Each peer **owns** its idea, and when the work is a verifiable fan-out it
   launches a **dynamic workflow** to execute with adversarial verification.
4. Peers write full output to `$TEAM_REPORTS/<name>.md` and ping `main` one
   line; `main` reads on demand and synthesizes for you.

### Messaging

```bash
msg <name> "<text>"   # inject a user turn into another agent's session
msg list              # who's alive
```

## Dynamic workflows (the execution layer)

Inside a peer, trigger one by saying **"use a workflow to ..."**. Good fits:

- "use a workflow to run the steering eval on layers 0–31 and verify each metric
  against main, **use 80k tokens**"
- "use a workflow to catalogue every SAE feature and bucket the dead ones"
- "use a workflow to rank these 80 configs and double-check the top 10"

Rules of thumb:
- **Always cap tokens** inline (`use 50k tokens`) — workflows are token-hungry.
- **One peer's workflow at a time.** Token burn is multiplicative across
  peers × subagents on the one subscription pool; check `/usage` first.
- **Keep research subagents non-isolated** (they read + run evals). Only use
  worktree isolation when subagents edit code in parallel.

## Goal loops — grind a peer to spec

Front-load a `SPEC.md` (this is the taste injection — see the template in this
dir). Then in the peer:

```
/goal all evals in test/fra pass and the metric beats the main baseline
```

`/goal` re-checks at every stop attempt and won't let the peer quit early.
For a *decorrelated* judge (a different model, billed to the autointerp API key
instead of your subscription), the `judge.sh` Stop hook fires automatically when
a `SPEC.md` is present — set `AUTOINTERP_ANTHROPIC_API_KEY` (the activate script
does this from `.env`).

## Overnight, unattended

- **Cadence on the pod:** `/loop 1h <skill-or-prompt>`. Use this, **not**
  `/schedule` or Routines — those run on Anthropic infra and can't see your pod's
  GPUs.
- **Autonomous messaging:** the default `msg` (tmux send-keys) wakes interactive
  agents. For a fully headless overnight team, enable the file mailbox: launch
  with `TEAM_AUTONOMOUS=1`, and have senders append instead of send-keys:
  `echo "[from <me>] <text>" >> "$TEAM_MAILBOX/<recipient>"`. The
  `mailbox-drain.sh` Stop hook delivers queued mail before an agent rests.

## Safety

- Interactive turns run on your **subscription** (the activate script strips
  `ANTHROPIC_API_KEY`); only the judge uses the API key.
- `permissions.deny` + `guard.sh` block remote/persistent/secret damage
  (force-push, `/workspace` deletion, `.env` exfil, wandb/repo deletion) even
  under auto mode. Local-ephemeral `rm` is allowed — the pod is disposable.
- Prefer **auto mode** (shift+tab) over `--dangerously-skip-permissions`.

## Habits that make long runs work

- **Verification is the #1 multiplier** — give every task a way to check itself.
- **Write mistakes into `CLAUDE.md` or a skill**, don't re-prompt — that's what
  lets a run go for hours without drifting.
- **Read the code before testing hypotheses** — understand the whole setup, then
  make a few targeted checks.
- Keep `main`'s and each peer's context lean; let report files hold the detail.
