---
name: thermonuclear-review
description: Deep adversarial code review. Use after writing or modifying non-trivial code, before marking a task done. Read the full changed surface from scratch, assume it is wrong, and find the specific bug with a failing case.
---

# Thermonuclear review

Do **NOT** skim. Reconstruct intent from a blank slate, then attack the code.

1. **Read everything.** `git diff` the full change set; read every changed file
   end to end, plus the callers and callees of anything touched. Spend the
   tokens to actually read — do not pattern-match.
2. **State the invariant.** For each function, say in your own words the
   property it is supposed to preserve.
3. **Break it.** Find the concrete input that violates each invariant:
   - off-by-one / boundary conditions
   - tensor shape / broadcasting mismatch
   - silent dtype casts, device drift (cpu↔cuda), float precision
   - threading / async races, shared-state mutation
   - empty / degenerate inputs, NaN/Inf propagation
   - resource leaks (open files, un-freed GPU memory)
4. **Check intent, not just correctness.** Does this do what `SPEC.md` (or the
   task) actually asked, or something adjacent that only looks right? Metric
   computed on the wrong axis, eval on the train split, baseline mismatch.
5. **Report.** Output a ranked list of concrete defects, each with `file:line`
   and a specific failing case or input. No praise, no summary of what works.

If you find nothing after a genuine read, say so explicitly and name the two or
three places you consider most likely to harbor a latent bug.
