# Pipeline Unification Design

**Date:** 2026-06-13
**Status:** Approved

## Goal

Collapse the current 4–5 manual invocations into two entry points:

```bash
PROFILE=meridian ./run-audit.sh          # audit + triage + readiness
PROFILE=meridian ./run-remediation.sh    # (triage if needed) + remediate + readiness
```

## Current Gaps

The architecture already exists. These are wiring gaps only:

1. `run-triage.sh` stops after `verify-consume` — does not run `triage --policy`, split resolution, or readiness
2. `run-audit.sh` does not call the triage pipeline after register backfill
3. `run-remediation.sh` does not auto-detect the register or run triage when `new` findings exist
4. No decision agent for verified P2/P3 findings that fall through policy (queued)

## Shared Triage Pipeline Function

Both entry points call the same triage pipeline. It lives in `run-triage.sh` and is invoked inline by the other scripts. Inputs: `REGISTER_DIR`, `TRIAGE_AGENT`, `MAX_PARALLEL`, `TRIAGE_DATE`.

Steps in order:

1. **verify-packets** — generate packets for all `new` findings
2. **verifier agents** — dispatch in parallel (already implemented)
3. **verify-consume** — fold results into register (already implemented)
4. **triage --policy** — auto-open P0/P1 verified in-scope; queue the rest
   - Policy file: `$REGISTER_DIR/triage-policy.yaml`
5. **split resolution** — if any `split` findings exist: generate split-packets, dispatch resolver agents, split-consume
6. **decision agent** — for remaining `new` verified findings (P2/P3 queued): generate decision-packets, dispatch agents, decision-consume
7. **readiness** — print verdict; exit 0 (ready) / 1 (blocked) / 2 (not enough data)
   - Scope file: `$REGISTER_DIR/launch-scope.yaml`

The pipeline is idempotent: each step checks whether its output already exists before re-running.

## New CLI Verbs: `decision-packets` + `decision-consume`

**`decision-packets`**

Generates one markdown packet per `new` verified finding that policy left queued (no disposition change). Packet presents:
- Finding details: id, severity, taxonomy, title, evidence, mechanism
- Launch scope: is it in scope, what is the bar
- Contract: agent writes JSON to `$REGISTER_DIR/triage/decision-results/$finding_id.json`

```json
{
  "schema_version": 1,
  "finding_id": "R-XXXX",
  "decision": "open | park | risk_accept",
  "rationale": "one sentence",
  "review_by": "YYYY-MM-DD"  // required only for risk_accept
}
```

Output dir: `triage/decision-packets/`

**`decision-consume`**

Reads decision JSONs, applies transitions with authority `policy:decision-agent`. Moves consumed results to `triage/decision-results/consumed/`. Same pattern as `split-consume`.

Valid decisions:
- `open` → transition to `open` (enters remediation)
- `park` → transition to `parked` (deferred, does not block readiness)
- `risk_accept` → transition to `risk_accepted` with `review_by` date

## `run-audit.sh` Changes

After the register backfill (already runs at end of group 09), if `$REGISTER_DIR/register.jsonl` exists and `AUDIT_RUN_TRIAGE` is not `0`:

```bash
bash "$SCRIPT_DIR/run-triage.sh" \
  --register-dir "$REGISTER_DIR" \
  [--agent "$TRIAGE_AGENT"] \
  [--no-generate]  # packets were just seeded by backfill
```

New env var: `AUDIT_RUN_TRIAGE` (default: `1`). Set to `0` to skip triage after audit.

## `run-remediation.sh` Changes

**Auto-detect register source.** When `PROFILE` is set (or `REGISTER_DIR` is set) and `$REGISTER_DIR/register.jsonl` exists and `AUDIT_RUN` is not explicitly provided, default `AUDIT_RUN=register:$REGISTER_DIR`.

**Auto-run triage when needed.** Before building the master packet list, check if any findings have `disposition=new`. If so, run the triage pipeline inline:

```bash
if _register_has_new_findings "$REGISTER_DIR"; then
  bash "$SCRIPT_DIR/run-triage.sh" --register-dir "$REGISTER_DIR" ...
fi
```

**Print readiness at end.** After all units reach terminal state (accepted/blocked/manual), run:

```bash
python3 -m lazy_vibe.register readiness \
  --register-dir "$REGISTER_DIR" \
  --scope "$REGISTER_DIR/launch-scope.yaml"
```

New env var: `REMEDIATION_RUN_READINESS` (default: `1`). Set to `0` to skip.

## Idempotency Rules

Each step checks before acting:

| Step | Skip condition |
|------|---------------|
| verify-packets | All `new` findings already have a packet in `packets/` |
| verifier agents | Result exists in `results/` or `results/consumed/` |
| verify-consume | No pending results in `results/` |
| triage --policy | No `new` findings with matching policy rules |
| split-packets | No `split` findings |
| split agents | Result exists in `split-results/` or `split-results/consumed/` |
| decision-packets | No `new` verified queued findings |
| decision agents | Result exists in `decision-results/` or `decision-results/consumed/` |
| readiness | (always runs — cheap, deterministic) |

## New `run-decision.sh`

Thin script mirroring `run-split-resolve.sh`:

```
Env: TRIAGE_AGENT, MAX_PARALLEL, TRIAGE_DATE, PROFILE, PROFILES_DIR, PRODUCT_PROFILE, PRODUCT_REPO_ROOT
Args: [--register-dir DIR] [--agent AGENT] [--no-generate]
```

Steps: `decision-packets` → parallel agent dispatch → `decision-consume`

## Out of Scope

- `register close` (per-finding closeout) remains a manual step — it requires a regression test reference that only the implementer knows
- Interactive triage walk (`triage` without `--render-only`) — Pete-only, opt-in
- `run-audit.sh` job groups — unchanged
