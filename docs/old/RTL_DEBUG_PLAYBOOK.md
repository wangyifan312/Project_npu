# RTL Debug Playbook

## Purpose

This document captures the RTL debugging rules that proved effective during the
`Tasks 1-9` cleanup and the subsequent `LeNet(MNIST)` bring-up work.

It is intended to be used as a long-term working guide for:

- `Claude Code` when implementing RTL changes
- `Codex` when reviewing and accepting RTL work
- human developers when deciding whether a task is truly complete

The focus is not style. The focus is **how to get RTL work to converge**.

---

## 1. Definition Of Done

Do not treat any of the following as completion by themselves:

- `structure complete`
- `framework exists`
- `task accepted`
- `done=1`
- `no error`
- `output is non-x`

A task is only complete when all of the following are true:

1. the designated strict testbench passes
2. output values match the golden/reference result
3. the process exits successfully for the right reason
4. existing regressions are not broken
5. documentation and tests reflect the same behavior as RTL

If one of these is missing, the task is not complete.

---

## 2. One Task At A Time

Do not expand scope while the current task is still failing.

Required discipline:

- If `Task 3` is failing, do not move on to `Task 4/5`
- If `Pool` is failing, do not start whole-network bring-up
- If `FC` is only accepted but not numerically correct, do not call it complete

The workflow must be:

1. isolate one task
2. make its test strict
3. fix RTL until the test passes
4. only then move to the next task

This is the single most important convergence rule.

---

## 3. Fix The Testbench First

Many failures are prolonged because the testbench is not a real acceptance test.

Common bad patterns:

- mismatch is only printed, not failed
- simulation exits with code `0` after errors
- test only checks `done`, not numeric output
- test uses a weak proxy scenario instead of the real target

Before changing RTL, confirm the testbench does all of the following:

1. compares against expected values
2. fails on mismatch
3. fails on timeout
4. fails on protocol misuse
5. covers the actual requirement, not a substitute

Examples:

- `4->20` is not a substitute for `20->50`
- `FC accepted` is not a substitute for `FC functional correctness`
- `network framework exists` is not a substitute for a completed network test

---

## 4. Start With The Simplest Root Causes

Do not begin by assuming a deep timing problem.

First check basic correctness:

1. address calculation
2. byte count
3. alignment
4. stride calculation
5. block sizing
6. valid/ready handshake
7. start/done pulse timing
8. stale register use within the same cycle
9. preload/testbench wiring

Only after these are ruled out should you escalate to:

- pipeline alignment
- multi-cycle propagation
- last-column timing
- systolic-array drain timing

This rule mattered repeatedly:

- a suspected array timing bug turned out to be weight-chunk misalignment
- a suspected Pool complexity issue turned out to be first-beat loss plus stale sizing

---

## 5. Build A Minimal Verifiable Loop

Do not debug at full network scale first.

Preferred progression:

1. smallest spatial size that exercises the path
2. smallest channel count that exercises the path
3. single block before multi-block
4. hand-computable golden case before large-scale regression
5. one layer before full network

Examples:

- debug `FC 4->2` before `800->500`
- debug `Pool 4x4x1 -> 2x2x1` before `24x24x20 -> 12x12x20`
- debug `Conv 1->4` before `20->50`

If the minimal loop does not pass, larger tests do not provide useful signal.

---

## 6. Prefer The Shortest Correct Path

Do not overcommit to a half-finished architecture path just because it already exists.

If an existing path is incomplete and hard to validate:

- do not keep stacking patches on it indefinitely
- first implement the smallest correct behavior that matches the spec
- make it pass numerically
- then improve elegance later if needed

This was important for FC:

- a half-connected `fc_frontend + array` path was not converging
- a smaller direct compute path made functional validation possible

Correctness comes before elegance.

---

## 7. Separate “Runs” From “Correct”

These mean different things:

- `runs`
- `completes`
- `does not error`
- `produces data`
- `produces the correct values`

Only the last one closes a functional task.

When reporting status, be explicit:

- `checker accepts FC` means control-plane acceptance only
- `FC outputs match golden values` means functional completion

Never blur these together.

---

## 8. Reduce Each Iteration To One Claim

Before every RTL change, write down:

1. the exact failing symptom
2. the most likely root cause
3. the single mechanism you are changing
4. the test that should change if your theory is right

Bad pattern:

- modify five modules at once and hope the behavior improves

Good pattern:

- symptom: Pool is missing one output
- hypothesis: `pp_start` overlaps first `data_valid`, so first input is lost
- change: delay Pool feed by one cycle after `pp_start`
- expected result: output count becomes correct

If the expected result does not happen, the hypothesis was wrong.

---

## 9. Test The Real Requirement

Every acceptance test must map to the actual task requirement.

Examples:

- if the target is `Conv2: 20->50`, the test must include `20->50`
- if the target is `Pool1: 24x24x20 -> 12x12x20`, the test must include multi-channel Pool
- if the target is `FC1: 800->500`, there must be an `800->500` correctness test

Do not claim coverage from a smaller or structurally different case unless it is
explicitly designated as a preliminary test.

Preliminary tests are useful, but they are not acceptance.

---

## 10. Keep Documentation In Lockstep

RTL, tests, and documentation must describe the same behavior.

Whenever RTL behavior changes, check whether these also need updates:

- task spec
- weight layout
- memory layout
- supported task types
- disabled features
- quantization rules
- test expectations

Examples:

- if FC is disabled, unit tests must expect rejection
- if FC is enabled, unit tests must stop expecting rejection
- if weight layout changes, both testbench preload and spec must change

Leaving old documentation in place causes repeated false debugging loops.

---

## 11. Recommended Debug Order

When a task is failing, use this sequence:

1. reproduce the failure locally
2. make sure the testbench is strict
3. reduce to the smallest failing case
4. inspect addresses, bytes, alignment, and state transitions
5. inspect start/valid/done handshake timing
6. only then inspect deeper datapath timing
7. re-run the exact failing test
8. re-run nearby regressions

Do not skip step 2 or step 3.

---

## 12. What To Report After Every Fix

Every completed iteration should report:

1. failing symptom
2. root cause
3. files changed
4. exact verification commands
5. exact verification result
6. whether acceptance criteria are now satisfied
7. remaining risks, if any

Use concrete language.

Good:

- `Pool task was losing the first input beat because pp_start overlapped the first data_valid cycle`

Bad:

- `minor postproc timing issue remains`

---

## 13. Lessons From This Repository

These are concrete examples from this project:

### Example A: Multi-channel Conv

Observed symptom:

- only the last columns were wrong

Initial temptation:

- blame last-column propagation timing

Actual root cause:

- each `c_in` weight chunk was not padded to a 32-bit boundary

Lesson:

- check layout/alignment before blaming array timing

### Example B: Pool Path

Observed symptom:

- Pool outputs were `x`, incomplete, or timed out

Actual root causes:

- first Pool input beat was lost because `pp_start` and `data_valid` overlapped
- block sizing used same-cycle stale dimensions
- internal postproc state was not cleared on restart

Lesson:

- control-path and initialization bugs often masquerade as datapath bugs

### Example C: FC Path

Observed symptom:

- FC tasks were accepted and completed, but no correctness proof existed

Actual issue:

- the existing FC path was only partially wired

Resolution:

- implement a minimal correct FC execution path first
- add real functional tests with golden values

Lesson:

- “accepted and completed” is not functional correctness

---

## 14. Required Rules For Claude Code

Claude Code should follow these rules on every RTL task:

1. do not claim completion from structure alone
2. do not move to the next task while the current strict test is failing
3. always make the testbench strict before relying on it
4. always start from the smallest failing case
5. check alignment/bytes/addresses before deep timing theories
6. if an architecture path is half-finished, prefer the shortest correct implementation path
7. never report `accepted`, `done`, or `non-x` as proof of functional completion
8. always include exact commands and real results
9. keep spec, tests, and RTL synchronized
10. treat every residual bug as unresolved until a task’s acceptance criteria are actually met

---

## 15. One-Sentence Summary

Use strict tests to pin down the failure, use the smallest closed loop to localize
the root cause, and use the shortest correct implementation path to close the task.
