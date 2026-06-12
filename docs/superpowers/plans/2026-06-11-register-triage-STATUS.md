# Plan 2b Execution Status — handoff state

**Plan:** `2026-06-11-register-triage.md` (complete code per task — execute task-by-task, byte-faithful, strict TDD red-first).
**Branch:** `feature/register-triage` in this repo (base: main @ 991c7bb). Merge to main when done.
**Suite baseline on branch:** run `python3 -m pytest tests/register -q` and `ruff check .` — both must be green after every task.

## Execution discipline (how Tasks 1–2 were run; continue the same way)
1. Implement the task exactly per its plan section (red-first TDD; if a failure looks like a PLAN defect, stop and re-read — do not improvise silently; document any forced deviation in the plan file itself).
2. Review the result adversarially (probe with hostile inputs, run probes against the real registers read-only), fix findings, re-review until approved.
3. Keep the plan file truthful: any code change made after review must be reflected in the plan's code blocks.
4. Commit per task with the plan's commit message.

## State (2026-06-11 ~21:15 ET)
| Task | Status | Commit |
|---|---|---|
| T1 packet generation | DONE, reviewed/approved | 1e7fd81 |
| T2 result consumption | DONE (d93cd72) + hardening (dec32e0) + candidate binding landed 066f427 — re-review CLOSED | 066f427 (suite 192) |
| T3 policy engine | DONE (ca7de37) + quality fixes landed 123d843 — review CLOSED | 123d843 (suite 211) |
| T4 queue render | not started | |
| T5 triage CLI + close | not started | |
| T6 scope journeys/claims_doc | not started | |
| T7 run-triage.sh + exports + README | not started | |
| T8 Meridian dry-run | not started | |

## T2 hardening: LANDED in dec32e0 (all five review items + non-string duplicate_of/split_paths guards, result lifecycle via triage/results/consumed/). Re-review item LANDED in 066f427: duplicate claims bound to the solicited fuzzy candidate (`duplicate_of == _fuzzy_candidate(finding)`), closing both the unsolicited-claim hole AND the nonexistent-id silent fall-through (the residual previously flagged for T4 — now resolved).

## T3 quality fixes: LANDED in 123d843 (red-first per fix). C1: `_candidate:`-themed findings are NOT adjudicable by policy — readiness's vocabulary-gap guard only blocks `new` findings, so a park rule would leak them past readiness (spec §12); they stay `new` and land in `PolicyOutcome.vocabulary_gaps`. I1: load-time type validation of match values (severity must be a string in SEVERITY_ORDER — a list silently never matched; in_scope/verified must be real YAML booleans — `"false"` bool-coerced truthy and matched the OPPOSITE set); `_matches` compares without coercion. I2: `propose_risk_accept` skips findings whose history already carries a `risk_accept_proposed` event, so policy re-runs do not stack duplicate proposals. M1: empty/omitted `match` is a load-time hard error (catch-all intent goes through `default`). M2: dead `findings` param dropped from `_act`. M3: `risk_accept_proposed` events carry a displayable `reason` for the T4 queue render.

Plan test arithmetic re-derived after T3 fixes (+5): T2 192, T3 211, T4 221, T5 228, T6 232, T7/final 233.

## Review carry-forwards from T2 re-review (NOTE comments in verify.py)
- **T5:** VerifyOutcome buckets are per-run deltas, not a register census — verify-consume CLI summary must not present them as totals.
- **T7:** `_archive_result` os.replace overwrites a prior consumed result on re-verification — consider run_id suffix or refuse-overwrite for per-run auditability.

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
