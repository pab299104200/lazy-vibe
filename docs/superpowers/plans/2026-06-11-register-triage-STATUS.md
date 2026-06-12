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
| T4 queue render | DONE (4009584) + quality fixes landed 2aad3d7 — review CLOSED | 2aad3d7 (suite 236) |
| T5 triage CLI + close | DONE (789b365) + quality fixes landed 04491b5 — review CLOSED | 04491b5 (suite 257) |
| T6 scope journeys/claims_doc | DONE (f949c9c) — suite 260 (plan said 261; arithmetic defect: replaced 1 test with 4, net +3 not +4) | f949c9c |
| T7 run-triage.sh + exports + README | DONE (58de804) + Task 8 sampling fix (`--no-generate`) landed in current fix commit | suite 263 |
| T8 Meridian dry-run | DONE — Meridian commit 88832bb5; 15 sampled, 12 VERIFIED/opened, 3 UNSUPPORTED/false_positive, 382 queued | 88832bb5 |

## T2 hardening: LANDED in dec32e0 (all five review items + non-string duplicate_of/split_paths guards, result lifecycle via triage/results/consumed/). Re-review item LANDED in 066f427: duplicate claims bound to the solicited fuzzy candidate (`duplicate_of == _fuzzy_candidate(finding)`), closing both the unsolicited-claim hole AND the nonexistent-id silent fall-through (the residual previously flagged for T4 — now resolved).

## T3 quality fixes: LANDED in 123d843 (red-first per fix). C1: `_candidate:`-themed findings are NOT adjudicable by policy — readiness's vocabulary-gap guard only blocks `new` findings, so a park rule would leak them past readiness (spec §12); they stay `new` and land in `PolicyOutcome.vocabulary_gaps`. I1: load-time type validation of match values (severity must be a string in SEVERITY_ORDER — a list silently never matched; in_scope/verified must be real YAML booleans — `"false"` bool-coerced truthy and matched the OPPOSITE set); `_matches` compares without coercion. I2: `propose_risk_accept` skips findings whose history already carries a `risk_accept_proposed` event, so policy re-runs do not stack duplicate proposals. M1: empty/omitted `match` is a load-time hard error (catch-all intent goes through `default`). M2: dead `findings` param dropped from `_act`. M3: `risk_accept_proposed` events carry a displayable `reason` for the T4 queue render.

Plan test arithmetic re-derived after T5 quality fixes: T2 192, T3 211, T4 236, T5 257, T6 261, T7/final 262.
(T4 first landed 227 with 6 extra escaping/determinism/purity tests; the quality-fix round added 9 more — C1 integration x3, I1 x1, C2 x4, M1 x1. T5 first landed 243 per plan; its quality-fix round added 14 — C1 x9, I2 x2, I3 x1, M1 x1, M3 x1.)

## T4 quality fixes: LANDED (red-first per fix). C1: reconcile.py's suppression branch wrote `suppressed_occurrence` events with NO `ref`, so the queue's reopen gate could never fire on production data — the event now carries `"ref": f"{normalize_path(candidate.path)}:{candidate.line}"`; the queue keeps the novelty comparison and tolerates historical no-ref events (existing meridian/portal registers carry them; they are skipped). Proven by integration tests driving the real reconcile→build_queue cycle. C2: `build_queue` gains a required ISO `today` param (malformed → RegisterError, mirrors readiness) and emits `risk_review` items for risk_accepted findings with `review_by < today` (recommendation "reaffirm or open"); plan Task 5 call sites updated to pass `today=date`. I1: reopen rows dedup by distinct novel ref within a finding. M1: unverified section render capped at first 20 by severity + `…and N more` overflow line. M2: dead `QueueItem.extra` dropped. M3: build_queue docstring corrected (takes the exclusive lock for a consistent snapshot, writes nothing).

## T5 quality fixes: LANDED in 04491b5 (red-first per fix). C1 (disqualifying): `--accept-all` forged by="pete" decisions — `_recommendation_choice` fell through to "o" for unverified/fuzzy_confirm/reopen/risk_review/severity_review items and `_apply_decision` hardcoded `verified=True`, so accept-all opened unverified findings, reopened protected states, and force-opened past-due risk acceptances unattended. Now accept-all routes through `_accept_all_decision` (ONLY scope park/unpark with the proposal's reason, and false-positive proposals backed by a live UNSUPPORTED verification with the disproof as reason); everything else lands in `TriageOutcome.requires_human` and the CLI summarizes "N items require interactive decisions". `verified` is derived from the finding's last `verification` event; interactive "o" on an unverified `new` finding is rejected with "unverified — run verify-packets / run-triage.sh first". Interactive reopen of protected states stays (by="pete"), unreachable from accept-all. Production probe: accept-all on the live Meridian register now applies 0/397 (pre-fix it would have force-opened all 397). I2: `validate_regression_test` in transitions.py (`path::test_name`, non-empty halves; mirrors `_require_iso_date`) used by `_guard_fixed` AND validated up-front by the close verb. I3: `QueueItem.source_disposition` stamped at build; `_apply_decision` raises `QueueDrift` when the live disposition drifted → `TriageOutcome.drifted`, never applied. M1: one decision per finding per walk ("already decided this walk"). M3: `prompt` raises EOFError instead of substituting a sentinel "s" line — EOF mid-risk-accept aborts the item with nothing applied (no sentinel review dates/reasons), stops the walk, saves only completed decisions; KeyboardInterrupt persists nothing (abort contract in queue.py module docstring).

## Review carry-forwards from T2 re-review (NOTE comments in verify.py)
- **T5:** ~~VerifyOutcome buckets are per-run deltas, not a register census — verify-consume CLI summary must not present them as totals.~~ DONE in 789b365: `_cmd_verify_consume` prints "this run: …" deltas with a NOTE(T5) comment.
- **T7:** ~~`_archive_result` os.replace overwrites a prior consumed result on re-verification~~ DONE in 58de804: `_archive_result` now suffixes `R-NNNN.<unix_ts>.json` when the destination already exists — no prior verifier output is ever overwritten. Red-first test `test_archive_result_timestamps_collision` in test_verify.py.

## Review carry-forwards (hold later tasks to these)
- **T4 (queue):** every free-text cell AND evidence ref rendered into triage-queue.md must go through `store.markdown_cell` (verifier-supplied refs may contain `|`/newlines — injection vector flagged in T2 review).
- **T5 (triage CLI):** ~~decisions must go through `transitions.transition()`/`reaffirm_risk()` stamped by="pete"; never mutate dispositions directly.~~ DONE in 789b365/04491b5: all decisions flow through `transition()`/`reaffirm_risk()` by="pete"; accept-all additionally restricted to fully-specified decisions (see T5 quality fixes).
- **T7 (run-triage.sh):** verification-only glue; full run-remediation.sh rewiring is Plan 3. Export `QueueDrift` alongside the queue symbols (plan T7 block updated).
- **T8:** packets for Meridian's 5 P0 + 10 sampled P1 only (token bound); report verifier outcomes honestly; commit register changes in /home/pete/cadres/meridian. NOTE: with the C1 fix, `triage --accept-all` will NOT auto-open verified findings — that is the POLICY's job (`apply_policy` open action); the dry-run flow (policy then queue) is unaffected. Task 8 exposed a T7/T8 integration defect: `run-triage.sh` regenerated all packets before dispatch, undoing the sample move-aside and causing the interrupted Claude run to create 24 out-of-scope `R-0001`–`R-0024` results. Fix: wrapper now accepts `--no-generate`; default behavior is unchanged, and Task 8 uses `--no-generate` after pre-bounding packets.

## After T8
Final whole-branch adversarial review (cross-module composition, debris, plan/spec/code consistency) → fix minors → merge to main, run suite on merge, delete branch, push. Update spec deferred-items if scope changed.

## T8 dry-run results (2026-06-11/12)
- Lazy-vibe T7/T8 sampling defect fixed in commit 9bc65ff: `run-triage.sh --no-generate` preserves a caller-bounded packet set. Full register suite after fix: 263 passed; `ruff check .` clean; `bash -n run-triage.sh` clean.
- Meridian commit: 88832bb5 `chore(register): triage dry-run — verify 5 P0 + 10 P1, starter policy`.
- Sample: P0 `R-0046`, `R-0200`, `R-0328`, `R-0371`, `R-0374`; P1 `R-0006`, `R-0010`, `R-0011`, `R-0017`, `R-0041`, `R-0052`, `R-0057`, `R-0065`, `R-0072`, `R-0073`.
- Verifier outcomes: 12 `VERIFIED`, 3 `UNSUPPORTED`, 0 `split`, 0 schema rejections. `UNSUPPORTED`: `R-0328`, `R-0371`, `R-0374`; verifier consumption transitioned them to `false_positive`.
- Policy outcome after consume: 12 opened, 0 parked, 0 false_positive (already consumed), 0 risk-accept proposed, 382 queued.
- Queue: `triage-queue.md` has one capped section, `Unverified findings (382)`, with 20 rendered rows and overflow text.
- Readiness: findings-only evaluation is `NOT READY`, 235 blocking, exit code 1. Full `readiness` command was interrupted because `launch-scope.yaml` runs the full backend pytest gate even though the register already fails; no gate verdict claimed.
- Anomaly preserved: the interrupted Claude attempt ran before the `--no-generate` fix and produced 20 out-of-scope `R-0001`–`R-0024` results. They were not consumed; they are committed under `triage/results/out_of_scope_20260611_overdispatch/`.

## Wider context
- Registers live: meridian (397 findings, commit 35bdd9af) and portal (353, seeded by Pete) at `docs/audit/register/` in each repo.
- Meridian readiness (findings side): NOT READY, 238 blocking (5 P0 + 59 P1 + 174 untriaged P2). Gate runs (backend pytest) intentionally not yet executed to completion.
- Plan 3 is now `docs/superpowers/plans/2026-06-12-register-integration.md`.
  Its first prerequisite slice is landed in lazy-vibe: `run-triage.sh` honors
  `PROFILE`/`PRODUCT_PROFILE`, infers the register from product `Repo root`,
  and runs Codex from the product repo so bare evidence refs resolve correctly.
  Remaining Plan 3 work: run-remediation.sh register wiring, differential audit
  mode (spec §8), prompt calibration + skill retirement (§9/§10), collision
  auto-split.
