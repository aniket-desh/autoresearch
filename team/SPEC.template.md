# SPEC — <experiment name>

Drop a copy of this as `SPEC.md` in a peer's worktree (or the project root) to
turn on the goal loop. `/goal` and the `judge.sh` Stop hook both read it, so the
agent can't stop until every acceptance criterion below is objectively met. This
file is the single most valuable thing you write — it's where your taste goes.

## Goal

<One or two sentences: what are you trying to show, and why does it matter?>

## Approach / scope

<The rough plan. What's in scope, what's explicitly NOT. Seed ideas the agent
should explore. Keep it lean — give direction and a way to fetch detail, not a
wall of context.>

## Acceptance criteria (must ALL be objectively checkable)

- [ ] <e.g. `pytest tests/fra/ -q` exits 0>
- [ ] <e.g. steering metric on layers 0–31 logged to reports/<name>.md>
- [ ] <e.g. mean Δ-metric vs the `main` baseline is > 0 on the held-out split>
- [ ] <e.g. a plot saved to logs/ showing X>
- [ ] thermonuclear-review applied to the diff; no unresolved defects

## How to verify

<Exact commands the agent (and the judge) should run to check the criteria.
The judge inspects the repo and runs these — make them concrete.>

```bash
# example
python eval.py --sweep layers --baseline main
pytest tests/fra/ -q
```

## Out of scope / do not

- <e.g. don't touch the data pipeline; another peer owns it>
- <e.g. don't force-push; don't delete /workspace state>
