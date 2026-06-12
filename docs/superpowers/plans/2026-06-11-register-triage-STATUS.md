# Plan 2b Execution Status — handoff state

**Plan:** `2026-06-11-register-triage.md` (complete code per task — execute task-by-task, byte-faithful, strict TDD red-first).
**Branch:** `feature/register-triage` in this repo (base: main @ 991c7bb). Merge to main when done.
**Suite baseline on branch:** run `python3 -m pytest tests/register -q` and `ruff check .` — both must be green after every task.

## Execution discipline (how Tasks 1–2 were run; continue the same way)
1. Implement the task exactly per its plan section (red-first TDD; if a failure looks like a PLAN defect, stop and re-read — do not improvise silently; document any forced deviation in the plan file itself).
2. Review the result adversarially (probe with hostile inputs, run probes against the real registers read-only), fix findings, re-review until approved.
3. Keep the plan file truthful: any code change made after review must be reflected in the plan's code blocks.
4. Commit per task with the plan's commit message.

## State (2026-06-11 ~20:30 ET)
| Task | Status | Commit |
|---|---|---|
| T1 packet generation | DONE, reviewed/approved | 1e7fd81 |
| T2 result consumption | DONE (d93cd72) + FIX-FIRST in flight | fix commit pending |
| T3 policy engine | not started | |
| T4 queue render | not started | |
| T5 triage CLI + close | not started | |
| T6 scope journeys/claims_doc | not started | |
| T7 run-triage.sh + exports + README | not started | |
| T8 Meridian dry-run | not started | |

## In-flight: T2 fix (commit message "fix(register): close verifier-input attack paths, idempotent result consumption")
If absent from git log, apply before T3: (C1) `_validate_result` rejects `duplicate_of == finding_id`; (C2) every `evidence` element must be a non-empty string, RegisterError naming index; (I3) duplicate-absorb target must be in {new, open, in_remediation, regressed} else RegisterError; (I1) `_absorb_duplicate_evidence` dedups on ref alone; (I2) processed result files MOVE to `triage/results/consumed/R-NNNN.json` (os.replace) so consume is idempotent — twice → one verification event. Adversarial test per fix, red-first. Expected suite ≈185.

## Review carry-forwards (hold later tasks to these)
- **T4 (queue):** every free-text cell AND evidence ref rendered into triage-queue.md must go through `store.markdown_cell` (verifier-supplied refs may contain `|`/newlines — injection vector flagged in T2 review).
- **T5 (triage CLI):** decisions must go through `transitions.transition()`/`reaffirm_risk()` stamped by="pete"; never mutate dispositions directly (store invariant rejects it anyway — that is the wall working).
- **T7 (run-triage.sh):** verification-only glue; full run-remediation.sh rewiring is Plan 3.
- **T8:** packets for Meridian's 5 P0 + 10 sampled P1 only (token bound); report verifier outcomes honestly; commit register changes in /home/pete/cadres/meridian.

## After T8
Final whole-branch adversarial review (cross-module composition, debris, plan/spec/code consistency) → fix minors → merge to main, run suite on merge, delete branch, push. Update spec deferred-items if scope changed.

## Wider context
- Registers live: meridian (397 findings, commit 35bdd9af) and portal (353, seeded by Pete) at `docs/audit/register/` in each repo.
- Meridian readiness (findings side): NOT READY, 238 blocking (5 P0 + 59 P1 + 174 untriaged P2). Gate runs (backend pytest) intentionally not yet executed to completion.
- Plan 3 (not yet written): run-remediation.sh register wiring, differential audit mode (spec §8), prompt calibration + skill retirement (§9/§10), collision auto-split.
