# `agents` — research agent-team workflow on RunPod

A plan to rework this repo from "a single curl that bootstraps Claude Code on a
fresh pod" into a **greater agents setup repo**, where that RunPod bootstrap is
one subfeature and the headline feature is a **team-of-agents-run-by-an-agent**
workflow — the thing the Cursor/Base10 folks describe (named peers, a main
orchestrator you talk to, goal loops, adversarial review), adapted to a single
multi-GPU pod and to a Claude Code subscription.

> **Guiding principle (the most important thing the Boris research changed):**
> **native Claude Code now does ~80% of what the hand-rolled scripts in the
> design chat did.** Build the thin custom glue that's genuinely missing
> (billing safety, GPU partitioning, name sampling, persistence, a guard rail);
> lean on native features for everything else. Don't over-invest in a harness —
> the labs are iterating on it faster than we can.

---

## 1. What we're actually replicating

Strip the lore from the transcript and there are five mechanisms:

1. **A `main` agent you talk to that delegates** to others, instead of you
   driving each one.
2. **Persistent named peers** (Hilbert, Gauss…) that can **message each other**
   so they respond instead of ignoring each other.
3. **Goal loops with a judge** — a separate check that forces a worker to keep
   going until a spec is met, defeating the model's bias to stop early.
4. **Adversarial / "thermonuclear" review** — fresh-context, read-everything,
   assume-it's-wrong review, ideally by a *different* perspective so errors
   decorrelate.
5. **Heavy front-loading** into one spec markdown the team + judge reference;
   anything done twice becomes a skill.

The irreplaceable human step is **taste**: picking the problem and writing the
spec. The scaffolding automates execution, not judgement. We stay the
long-term memory and problem-selector.

---

## 2. Native-first mapping (build column = the only things we write)

| Transcript mechanism | Native Claude Code primitive (use this) | Custom glue we still build |
|---|---|---|
| Ephemeral "go do this narrow task" | **Subagents** / **dynamic workflows** ("use a workflow…") | — |
| Persistent named peers, each isolated | `claude --worktree <name> --tmux --name <name>` | name sampling, GPU pin, `.venv`/`.env` into the worktree |
| Watch the whole fleet | **Agent View** (`claude agents`) — groups sessions by needs-input/working/done | — |
| Peer-to-peer messaging | (native "Agent Teams" exists but unconfirmed) | `msg` = `tmux send-keys` into the target session |
| Goal loop / force-keep-going | **`/goal <condition>`** (zero-config Stop gate) | `judge.sh` **only** for cross-model / off-plan judging |
| Heavy parallel verifiable sweep | **dynamic workflows** (orchestrator: implementer → 2 verifiers → fixer; adversarial verification beats self-judging) | — |
| Dangerous-command guard | **auto mode** (safety classifier) + `permissions.deny` | `guard.sh` PreToolUse for pod-specific state |
| Reusable prompt/workflow | **skills** | `thermonuclear-review` skill |
| Big plan before executing | a per-project **`SPEC.md`** (this is the taste injection) | — |
| Role injection | `.claude/agents/main.md` + `peer.md` + `--agent` | the two role files |
| Orchestrator forgetting peers after compaction | `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` + **PostCompact hook** | `postcompact.sh` re-injects the roster |
| Overnight cadence | **`/loop <interval>`** on the pod | — |

**What collapsed vs. the design chat's first draft:** the ~120-line `team.sh`
that did `git worktree add` + `tmux new-window` by hand shrinks to a loop that
samples a name, computes a GPU slice, and calls native `--worktree --tmux
--name`. The `judge.sh` Stop-hook is demoted to optional (use `/goal`).
`--dangerously-skip-permissions` is replaced by auto mode.

---

## 3. Locked design decisions (from the planning chat)

1. **Integration:** the agent layer rides the existing curl. `setup.sh` fetches
   and installs it; `bootstrap.sh` re-bootstraps for free after restart.
2. **Billing:** interactive agents run on the **subscription** ($200/mo plan).
   The Anthropic API key is for **autointerp / LLM-judge only** — never exported
   into an interactive `claude`. *(See §4, this is a real bug today.)*
3. **Scale-adaptive:** no fixed GPU split. 1×A40 small interp job → peers share;
   4–8×H100 final push → each peer gets a GPU slice. Team size adapts to the pod.
4. **Isolation:** **git worktrees** per peer, branch `agent/<name>`. Shared
   `.venv` + `.env` (symlinked, one `uv sync`), shared `/workspace/.cache`.
5. **Messaging:** `tmux send-keys` (`msg`) as the default — it wakes an idle
   agent, faithful to the transcript. Ship a mailbox file for autonomous loops.
6. **Loop topology — two layers (chosen):** persistent named peers, each owning
   **one experiment idea**, and each peer drops into a **dynamic workflow** to
   execute its idea (spawn/kill ephemeral subagents with adversarial
   verification). You → `main` → peers (one idea each) → each peer fans out a
   workflow. Peers write **full** output to `reports/<name>.md` and ping main
   with a **one-line** pointer; main reads on demand. Only main talks to me for
   *control*; I can still passively watch any peer pane. Each peer gets its own
   `SPEC.md` + `/goal`. *(See §4 for the multiplicative-token constraint and the
   non-isolated-subagents rule that make this safe.)*
7. **Names:** sample from `names.txt` (243 surnames) **without replacement**,
   tracking used names so there's never confusion about who's who.
8. **Guard scope:** protect **remote + persistent + secret** state (force-push,
   `/workspace` deletion, `.env` exfil, wandb/repo deletion). Leave
   local-ephemeral `rm` alone — the pod is disposable.

---

## 4. Critical do's and don'ts (the load-bearing gotchas)

**DON'T export `ANTHROPIC_API_KEY` into an interactive `claude` — it silently
double-bills.** When the API key is present as an env var it takes precedence
over the subscription OAuth, so you pay API rates on top of the $200 plan. This
is **already happening** in the current repo: `runpod_activate.sh` sources
`.env` which exports the key. **Fix:** capture it as
`AUTOINTERP_ANTHROPIC_API_KEY`, then launch interactive turns with
`env -u ANTHROPIC_API_KEY claude`; re-inject the real key *only* into the
headless judge call. Patch `runpod_activate.sh` with an
`alias claude='env -u ANTHROPIC_API_KEY claude'` so manual launches are safe too.

**DON'T bulk-spawn agents — it trips a burst/concurrency limiter** ("Server is
temporarily limiting requests… Rate limited"). Stagger launches (`STAGGER=8s`
default). All concurrent agents draw from the **same** rolling pool, so K agents
= K× burn against the plan — **size the team to the plan limit, not the GPU
count.** Small job → 2 peers even on 8 GPUs.

**DON'T run all peers' workflows at once — token burn is MULTIPLICATIVE under the
two-layer topology.** 3 persistent peers × a 5-subagent workflow each ≈ 15–18
concurrent agents, all billing the one plan pool; even max plans hit limits.
**Gate it:** peers idle by default; in practice **one peer runs its workflow at a
time** while the others sit. Check `/usage` before firing a sweep.

**DON'T give research workflow subagents `isolation: worktree`.** They mostly
read + run evals, not edit code in parallel, so they should share the peer's
worktree — otherwise you get worktrees-of-worktrees under `agent/<name>`. Reserve
isolation for the rare parallel-code-edit workflow.

**DON'T let main hold every peer's output in context** — it compaction-thrashes
and loses the thread. Peers write to `reports/<name>.md`, ping a one-liner; main
reads on demand. Launch main with `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000`
(context rot sets in ~300–400k on the 1M model) and a PostCompact hook that
re-injects the team roster + protocol. Keep role prompts lean (context
minimalism: give the goal + a way to fetch the rest).

**DON'T use `--dangerously-skip-permissions`.** Use **auto mode** (red-teamed
safety classifier; available on Max) so you can run many agents unattended, and
keep `permissions.deny` as an absolute backstop (deny rules outrank auto mode
and even bypass mode). `guard.sh` (PreToolUse exit-2) catches the
pod-specific stuff and fires even under bypass.

**DON'T use `/schedule` or Routines for anything touching GPUs** — they run on
Anthropic infra and can't see your pod's GPUs. Use **`/loop <interval>`** on the
pod for overnight train/eval sweeps.

**DO front-load a `SPEC.md`** — it's the one irreplaceable step (taste).
**DO give every task a way to verify itself** (run the eval, diff the metric vs
`main`) — verification is the repeated #1 tip, a 2–3× quality multiplier.
**DO write every mistake into `CLAUDE.md` or a skill** instead of re-prompting —
that's what lets a run go for hours without drifting.
**DO reach for dynamic workflows** for metric-driven parallel work (sweeps,
"rank these 80 configs and verify the top 10", catalogue/dedup) — the
orchestrator's separate verifiers kill the self-preferential bias where a model
grades its own work. Cap tokens inline (`…use 50k tokens`).

**Caveat on native flags:** `--worktree`/`--tmux` and auto mode are confirmed in
official docs. Agent View, `/goal`, dynamic workflows, nested subagents, and
`fork:true` are recent/preview and were fan-compiled from tweets — **verify each
against the live docs before baking into `setup.sh`** (see §8 checklist). Keep
the hand-rolled tmux loop as a fallback in case the native flags differ.

---

## 5. Target repo structure

Rename the headline concept from *autoresearch* → *agents*. The RunPod
bootstrap becomes the `provision/` subfeature; the agent-team layer is the
headline `team/` + `.claude/` bundle.

```
agents/
  README.md                         # top-level: two subsystems, quickstart
  PLAN.md                           # this file
  setup.sh                          # entry curl — now also installs the agent layer
  bootstrap.sh        (generated)   # unchanged re-bootstrap stash

  provision/                        # SUBFEATURE 1 — the RunPod bootstrap (was the whole repo)
    runpod_setup.sh                 # uv sync + .env template (unchanged)
    runpod_activate.sh              # PATCHED: billing strip (env -u / alias)

  team/                             # SUBFEATURE 2 — the multi-agent layer
    team.sh                         # thin launcher: name-sample + GPU pin + native --worktree/--tmux/--name
    msg.sh                          # tmux send-keys messaging primitive (+ `msg list`)
    names.txt                       # 243 surnames, sampled without replacement
    install.sh                      # integrator: install bundle/ into CLAUDE_CONFIG_DIR + launchers on PATH
    bundle/                         # the Claude Code config that lands on the pod
      agents/
        main.md                     # orchestrator role (delegates; only one that talks to human)
        peer.md                     # worker role (owns one idea; launches workflows; self-review)
      skills/
        thermonuclear-review/SKILL.md
      hooks/
        guard.sh                    # PreToolUse(Bash): protect remote/persistent/secret
        judge.sh                    # Stop (opt-in via SPEC.md): cross-model judge on the API key, --bare
        postcompact.sh              # PostCompact: re-inject roster + protocol into main
        mailbox-drain.sh            # optional Stop hook for fully-autonomous messaging
        worktree-link.sh            # optional WorktreeCreate hook: symlink .venv/.env into new worktrees
      settings.json                 # permissions.deny backstop + hook wiring
```

> **Why `team/bundle/` and not a top-level `.claude/`:** the repo's own `.claude/`
> is the config Claude Code loads when you work on *this* repo. Putting the pod
> hooks there would fire `guard.sh`/`judge.sh` (which assume pod paths) on your
> laptop. `install.sh` copies `bundle/` → `CLAUDE_CONFIG_DIR` on the pod instead.

**Repo-rename note (needs a decision — see §8):** `setup.sh` hard-codes
`raw.githubusercontent.com/aniket-desh/autoresearch/main/...` in ~5 places. If
the GitHub slug changes to `agents`, all of those must update. Cleanest: define
one `AGENTS_RAW` base var at the top of `setup.sh` and reference it everywhere,
so a future rename is a one-line change.

---

## 6. File-by-file build plan

### `team/team.sh` — the launcher (much thinner now)
- Resolve repo root; refuse if not in a git repo.
- Size the team: `TEAM` env overrides; else from GPU count (`nvidia-smi -L`) but
  **clamped small** (≤1 GPU → 2 peers; ≥6 → 6; mind the plan limit, not GPUs).
- Sample K names without replacement: `comm -23` of `names.txt` minus
  `state/used_names`, `shuf | head -K`; append chosen to `used_names`.
- Compute a CUDA slice per peer (chunk GPUs evenly; round-robin if peers > GPUs).
- For each peer, launch native, staggered:
  ```bash
  env -u ANTHROPIC_API_KEY CUDA_VISIBLE_DEVICES="$slice" AGENT_NAME="$name" \
    claude --worktree "$name" --tmux --name "$name" --agent peer
  sleep "$STAGGER"
  ```
  (Symlink `.venv`/`.env` into the new worktree here, or let the
  `worktree-link.sh` WorktreeCreate hook do it.)
- Launch `main` in the repo root with
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000 … --agent main` (no worktree).
- `team status` → `claude agents` (Agent View) or `tmux ls`; `team stop` kills
  sessions but **keeps** worktrees/branches.
- Keep a `FALLBACK=1` path that does manual `git worktree add` + `tmux
  new-window` if native `--worktree` is unavailable.

### `team/msg.sh` — `msg <agent> <text> | msg list`
- `tmux send-keys` the text into the target session, `sleep 0.2`, then send
  `Enter` separately (TUIs drop a fused paste+submit).
- Prefix `[from $AGENT_NAME]`. Validate the target exists; `msg list` enumerates
  sessions.

### `.claude/agents/main.md` — orchestrator role
- "You are `main`, the only agent that talks to the human. Assign **one
  experiment idea** per peer with `msg <name> "<idea + scope>"`. Peers write full
  output to `reports/<name>.md` and ping you one line — read those on demand;
  never hold long peer output in context. Synthesize concisely to the operator.
  Delegate; don't do the work yourself." Keep it lean.

### `.claude/agents/peer.md` — worker role (persistent owner + workflow launcher)
- "You are `$AGENT_NAME`, owner of experiment **\<idea\>**, working in worktree
  `agent/<name>`. Hold the plan and taste for your idea across the whole session.
  When your work decomposes into many verifiable units, **use a workflow** to fan
  out ephemeral subagents (implementer → 2 verifiers → fixer); keep those
  subagents **non-isolated** (share this worktree) unless they edit code in
  parallel. Keep workflow output structured; write full findings to
  `reports/<name>.md`; keep your own context lean. Commit code to your branch.
  Gate completion with `/goal` against your `SPEC.md`. Before declaring done,
  apply the `thermonuclear-review` skill. Notify main with one line:
  `msg main "done: <one-line>; see reports/<name>.md"`. Stay within your
  `CUDA_VISIBLE_DEVICES`. Route through main; peer↔peer only for tightly-coupled
  work."

### `.claude/skills/thermonuclear-review/SKILL.md`
- Deep adversarial review: `git diff` the full surface, read every changed file +
  callers/callees from scratch, state each invariant, find the input that breaks
  it (off-by-one, shape/broadcast, dtype/device drift, races, precision), check
  it matches `SPEC.md` vs something adjacent, output ranked defects with
  `file:line` + a failing case. No praise.

### `.claude/hooks/guard.sh` — PreToolUse(Bash)
- Read JSON on stdin, extract `.tool_input.command`, `deny` (exit 2 / decision
  JSON) on: `rm -rf /workspace*`, `git push --force/-f`, remote branch deletion,
  `wandb … delete`, `gh repo/release delete`, and `.env`/`printenv` piped to
  `curl`/`wget`/`nc`. Leave local-ephemeral destruction alone.

### `.claude/hooks/judge.sh` — Stop (opt-in)
- Only fires if `SPEC.md` exists; bail if `stop_hook_active`. Run the judge on
  the **autointerp API key**, `--bare` (10× faster startup, no project config) +
  Haiku to keep cost low: inspect repo, reply `DONE` or `NOT_DONE <punch-list>`.
  Block the stop with the punch-list if not done. *(Optional — prefer native
  `/goal` unless you specifically want a different model / off-plan billing.)*

### `.claude/hooks/postcompact.sh` — PostCompact
- Re-emit the team roster + the peers→main→human protocol so main doesn't forget
  its team after a compaction.

### `.claude/hooks/mailbox-drain.sh` — optional Stop hook
- Gated on `TEAM_AUTONOMOUS=1`: before an agent rests, deliver queued
  `mailbox/<name>` lines as its next turn. Pairs with an append-to-file sender.

### `.claude/settings.json`
- `permissions.deny`: `sudo *`, `rm -rf /*`, `rm -rf /workspace*`, `rm -rf ~*`,
  `git push --force*`, `curl * | bash`, `Read(./.env*)`, `Read(/workspace/**/.env)`.
- `hooks`: PreToolUse→guard, Stop→judge, PostCompact→postcompact, optional
  WorktreeCreate→worktree-link. Absolute paths under `CLAUDE_CONFIG_DIR`.

### `team/install.sh` — the integrator (curl'd by `setup.sh`)
- Set `CLAUDE_CONFIG_DIR=/workspace/<user>/.claude` (creds + settings + hooks on
  the **persistent** volume → log in **once**, survives restarts).
- Fetch `team.sh`, `msg.sh` → `~/.local/bin/{team,msg}` (chmod +x).
- Fetch `names.txt` → `state/names.txt`; create `state/ reports/ mailbox/`.
- Fetch hooks + skill + agent defs into `CLAUDE_CONFIG_DIR`.
- Write `settings.json` only if absent (never clobber an edited one).
- Append to `.bashrc`/`.profile`: `PATH`, `CLAUDE_CONFIG_DIR`, `TEAM_DIR`.
- Idempotent throughout.

### `setup.sh` — integration
- Add `AGENTS_RAW` base var; replace hard-coded raw URLs with it.
- After the claude-code install step `[6/7]`, add `[6.5/7]`: as the user,
  `curl … team/install.sh | bash`.
- Update the closing instructions: one-time `claude` login (subscription, **no
  API key paste**), then `cd <project> && team`.

### `provision/runpod_activate.sh` — patch
- After sourcing `.env`: `export AUTOINTERP_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"`
  then `alias claude='env -u ANTHROPIC_API_KEY claude'`.

---

## 7. End-to-end pod lifecycle

```bash
# fresh pod, as root:
curl -fsSL https://raw.githubusercontent.com/<owner>/agents/main/setup.sh \
  | REPO=https://github.com/me/proj.git BRANCH=main USER_NAME=me bash
su - me
claude                       # ONE-TIME /login (subscription), Ctrl-C after
cd /workspace/me/proj
# optional: write SPEC.md (acceptance criteria) for a goal-loop run
team                         # auto-sizes: A40 → 2 peers; 8×H100 → 6 peers w/ GPU slices
```
Then in the **main** session: *"split the FRA steering sweep across the team —
each peer takes one layer range."* Main delegates via `msg`; peers commit to
`agent/<name>` and report one-liners. Watch everything with `claude agents`.
For heavy verifiable work, tell main *"use a workflow to rank these configs and
verify the top 10, use 50k tokens."* For completion gating, `/goal all evals in
test/fra pass`. For overnight, `/loop 1h <skill>`.

---

## 8. Open decisions + verification checklist

**Resolved:**
1. ✅ **Rename** `aniket-desh/autoresearch` → `aniket-desh/agents`; parameterize
   all curl URLs via a single `AGENTS_RAW` base var so the rename is one line.
2. ✅ **`/goal` is the default** completion gate. `judge.sh` stays as an opt-in
   (via `SPEC.md`) for when you specifically want a decorrelated model judging
   off-plan on the API key.

3. ✅ **Both, layered.** Persistent named peers (one experiment idea each) sit on
   top; each peer drops into a dynamic workflow to execute its idea. Keep `msg`
   for the persistent team; workflows do the verifiable fan-out underneath.
   Constraints that make it safe: peers idle by default + one workflow at a time
   (multiplicative token burn), and workflow subagents stay non-isolated. See §4.

**Verify against live docs before baking into `setup.sh`** (fan-sourced):
- [ ] `claude --worktree <name> --tmux --name <name>` exact flag names/behavior
- [ ] Agent View invocation (`claude agents`) and discovery scope
- [ ] `/goal` semantics and persistence
- [ ] auto mode flag (`--enable-auto-mode`?) + availability on the $200 plan
- [ ] dynamic-workflows trigger phrase + token-budget syntax
- [ ] `CLAUDE_CODE_AUTO_COMPACT_WINDOW` + PostCompact hook event name
- [ ] `--bare` flag for the headless judge
- [ ] WorktreeCreate hook (for the `.venv`/`.env` symlink automation)

---

## 9. Phased rollout — STATUS: all built + locally verified

1. ✅ **Reorg + billing fix.** `provision/` + `team/`, `AGENTS_RAW`
   parameterization, the `env -u` billing patch (verified: interactive→sub,
   judge→API), README rewritten. (jq added to apt — hooks need it.)
2. ✅ **The bundle.** `team/bundle/` agents + `thermonuclear-review` skill +
   5 hooks + `settings.json` template; `team/install.sh` (dual local/remote
   source); `[6.5/7]` + `CLAUDE_CONFIG_DIR` persistence wired into `setup.sh`.
   Verified: guard 12/12, judge all branches, postcompact JSON, worktree-link
   symlinks, install e2e + idempotent.
3. ✅ **The launcher.** `team.sh` (native-first + `TEAM_NATIVE=0` fallback +
   `DRYRUN`) and `msg.sh`. Verified: sizing + GPU slicing across 0/1/2/4/8 GPU
   and `TEAM=` override, name sampling w/o replacement + exhaustion error,
   `msg` delivery + resolution against real tmux.
4. ✅ **Polish.** PostCompact roster re-inject, mailbox autonomous mode,
   `team/USAGE.md` (the `/goal` + `/loop` + workflow recipes),
   `team/SPEC.template.md`. setup.sh closing instructions updated to the
   subscription-login + `team` + auto-mode flow. shellcheck clean.

**Verified locally; NOT yet verified on a live pod.** The §8 checklist of
fan-sourced native flags (`--worktree`/`--tmux`/`--name`, `claude agents`,
`/goal`, auto mode, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `--bare`, WorktreeCreate)
still needs a real-pod smoke test; `TEAM_NATIVE=0` is the deterministic fallback
if any native flag differs.
