# Plan 3 — Register Integration

**Goal:** make the persistent register the default control plane across audit,
triage, remediation, and feature-build. Product profiles remain the source of
truth for repo roots, launch claims, supported verification commands, docs
locations, and product-specific prompt context.

**Spec:** `docs/superpowers/specs/2026-06-11-register-core-design.md` §8
(differential audit), §9 (prompt calibration), §10 (skill consolidation), §11
(integration contracts), §12 (collision/error handling).

**Repo:** `/home/pete/cadres/shared/lazy-vibe`. Verification baseline:
`python3 -m pytest tests/register -q`, `python3 -m pytest tests/register/test_cli_end_to_end.py -q`,
`bash -n run-triage.sh`, `ruff check .`.

## Current State

- Plan 1/2a/2b are landed and pushed on `main`.
- Meridian has a seeded register and a sampled triage dry-run commit:
  `88832bb5 chore(register): triage dry-run — verify 5 P0 + 10 P1, starter policy`.
- `run-audit.sh` and `run-remediation.sh` already resolve `PROFILE`,
  `PROFILES_DIR`, and `PRODUCT_PROFILE`.
- Before this plan, `run-triage.sh` did not. It required an explicit
  `--register-dir` and ran Codex from lazy-vibe, which made bare evidence refs
  such as `ConnectorHeader.tsx:241` weaker than the product-profile contract.

## Task 1: Product-Profile Register Triage

**Status:** landed in this plan's first code slice.

Make `run-triage.sh` honor the audit/remediation profile contract:

- `PROFILE=<name>` resolves under `PROFILES_DIR`.
- `PRODUCT_PROFILE` can be supplied directly.
- The product profile's `- Repo root: ...` line becomes `PRODUCT_REPO_ROOT`.
- If `--register-dir` is omitted, use
  `$PRODUCT_REPO_ROOT/docs/audit/register`.
- Verifier agents run from the product repo; Codex receives
  `-C "$PRODUCT_REPO_ROOT"`.
- Existing explicit `--register-dir` and `--no-generate` behavior stays intact.

Regression coverage:

- `test_run_triage_sh_profile_sets_register_and_codex_cwd`.
- Existing stub-agent and bounded-packet tests remain green.

## Task 2: Register-Backed Remediation Queue

**Status:** landed in the second Plan 3 code slice.

Replace register-enabled remediation cataloging with a deterministic register
source while retaining the existing packet/workstream state machine.

Required behavior:

- Detect register-enabled repos from `PROFILE`/`PRODUCT_PROFILE` or an explicit
  `REGISTER_DIR`.
- Build remediation candidates from `register.jsonl` entries with disposition
  `open` or `regressed`; do not scrape historical scorecards/audit prose for
  those repos except during explicit backfill/legacy mode.
- Preserve the register finding id through `00-register-px-map.tsv` and every
  generated packet's `Register Context` block.
- Keep blocker-ledger/source-reference context so implementers see the evidence,
  severity, taxonomy, scope, occurrences, and last verification event.
- Mark register entries `in_remediation` through the register state machine
  when a unit starts, not by editing JSONL directly.
- On verifier pass, call
  `python3 -m lazy_vibe.register close --register-dir ... --finding R-NNNN --test path::test`
  and require the verifier to name the regression test.
- On verifier failure, leave the register item `open` or `regressed` and attach
  verifier artifacts to the remediation run; do not synthesize false-positive
  decisions in remediation.
- Existing raw PX extraction remains only for repos/runs without a register or
  for explicitly requested legacy backfill.

Tests:

- Shell fixture for register-sourced packet generation from two open/regressed
  findings.
- Fixture proving false-positive/fixed/new findings are excluded from the
  register-backed map.
- Fixture proving verifier pass closes via the CLI and stores regression_test.
- Python CLI tests for `start-remediation`.

## Task 3: Audit Ingest/Reconcile Hook

**Status:** landed across the third and sixth Plan 3 code slices.

After launch-readiness summary generation, reconcile findings into the product
register automatically.

Required behavior:

- Resolve register dir through `REGISTER_DIR`, product profile `Repo root`, or
  `<REPO_ROOT>/docs/audit/register`.
- Generate `RUN_DIR/00-blocker-ledger.tsv` from audit summary/log/artifact
  evidence, then generate candidates through the register ingest path and
  reconcile with run id `basename "$RUN_DIR"` and the run date.
- Update `baseline.json` after a successful reconcile.
- Render `register.md` and a reconcile report in the product repo.
- Fail loudly on corrupt register data, missing themes, or unmapped in-scope
  vocabulary gaps.

Tests:

- Audit summary fixture generates a blocker ledger from audit output, writes
  candidates, reconciles, and writes `baseline.json`.
- Existing summary fixtures stay green.

## Task 4: Differential Audit Mode

**Status:** landed in the seventh Plan 3 code slice.

Implement `run-audit.sh --differential` as the cheap, scoped post-feature gate.

Required behavior:

- Load `baseline.json` and compute changed paths from baseline sha to `HEAD`.
- Map changed paths to launch-scope surfaces, docs links, and Lattice impact
  when available.
- Run affected jobs only; deterministic cheap gates still run.
- Differential/feature-scoped audit prompts must enumerate changed endpoint,
  route, permission, state transition, docs, and tests exhaustively.
- Full sweep remains available and reconciles through the register.

Implementation notes:

- `lazy_vibe.audit.differential` loads `baseline.json`, validates that the
  baseline SHA is an ancestor of `HEAD`, computes changed paths, writes the
  filtered job manifest, and records `artifacts/differential-scope.md`.
- The runner injects the differential scope into every selected prompt so the
  agent must enumerate changed endpoints, routes, permissions, state
  transitions, docs, and tests for its scope.
- `--full` disables differential selection and uses the normal full manifest.

Tests:

- Fixture where a backend path selects backend/security/runtime jobs.
- Fixture where docs-only changes select docs/contract jobs and cheap gates.
- Missing/stale baseline fails with an actionable message unless `--full` is
  used.

## Task 5: Feature-Build Postcheck

**Status:** landed in the eighth Plan 3 code slice.

Wire `run-feature-build.sh` completion into the differential audit pipeline.

Required behavior:

- After a verified feature build, run differential audit unless explicitly
  disabled.
- Reconcile differential findings into the register.
- Run register triage and then remediation for newly opened entries.
- Preserve branch/worktree safety: no concurrent mutation of the same product
  checkout.

Implementation notes:

- Register-enabled feature builds auto-run `run-audit.sh --differential` after
  task verification and standard gates, before final success/commit/push/deploy.
- The postcheck passes through `PROFILE`, `PROFILES_DIR`, `PRODUCT_PROFILE`,
  `JOBS_FILE`, `REGISTER_DIR`, `REPO_ROOT`, and a feature-scoped audit
  `RUN_DIR`.
- Feature-build postchecks set `AUDIT_DIFFERENTIAL_INCLUDE_WORKTREE=1` so the
  differential scope includes verified task changes before the default
  auto-commit step.
- `FEATURE_BUILD_POSTCHECK=0` disables the hook; `FEATURE_BUILD_POSTCHECK_TRIAGE`
  and `FEATURE_BUILD_POSTCHECK_REMEDIATE` control the follow-on triage and
  remediation steps.

Tests:

- Feature-build fixture proves post-build audit command is emitted/invoked with
  `PROFILE`, `RUN_DIR`, and the product repo root.
- Failure in differential audit blocks final success.

## Task 6: Prompt Calibration And Skill Consolidation

**Status:** landed across the fifth, ninth, and tenth Plan 3 code slices.

Remove finding-count incentives and make accurate dispositions the central
prompt contract.

Required behavior:

- Update generic audit/remediation prompts with severity anchors and
  evidence-or-silence requirements.
- Inject compact suppressed/open register context into audit prompts.
- Treat existing scorecards as historical sources or generated register views,
  not runtime authority.
- In Meridian, retire or rewire `.claude/skills` per spec §10 after verifying
  equivalent harness coverage.

Meridian follow-through:

- `feature-review` and `feature-ux-audit` skill entrypoints were removed.
- `feature-remediation` now delegates to register-backed `run-remediation.sh`.
- `feature-build`, `feature-acceptance`, `feature-design`, and
  `feature-marketresearch` now point at `run-audit.sh --differential` and
  register-backed remediation instead of retired scorecard-era skills.

Tests:

- Text fixture proves the accuracy contract and severity anchors are present
  and rejects old "finding count equals effort" language.
- Prompt fixture proves active and adjudicated suppressed register entries are
  included in generated audit prompts.

## Task 7: Collision Auto-Split

**Status:** landed in the fourth Plan 3 code slice.

Finish the spec §12 collision path.

Required behavior:

- Reconciler detects same fingerprint with materially divergent evidence
  file/line sets.
- It creates split candidates with a `collision` history event instead of
  silently suppressing or merging.
- Triage queue renders the split with enough evidence for Pete to decide.

Tests:

- Two candidates with the same fingerprint but divergent evidence/title split.
- Re-running the same collision is idempotent.

## Done Criteria

- Register-enabled Meridian and Portal flows can run:
  audit -> register reconcile -> triage -> remediation -> close -> readiness.
- Product profile is the only product-selection contract used by the shell
  entrypoints.
- Raw scorecard/PX extraction is not the authority for register-enabled repos.
- Full register suite, relevant shell fixtures, and lint are green.
