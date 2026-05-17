# Generic Launch-Readiness Audit Prompt

Use this prompt with `generic-jobs.tsv` and a product profile.

## Purpose

Run a launch-readiness audit for any software repo using the repo's own product profile, docs, code, tests, runtime harnesses, and launch claims. The audit must not assume a specific product category.

## Generic Operating Rules

1. The product profile is the launch contract. Audit against the claims, critical journeys, trust boundaries, risk areas, competitors, and verification commands listed there.
2. If the product profile is incomplete, inspect repo docs and code inventories to infer likely domains, but mark assumptions and missing profile data as findings.
3. Spec/docs truth matters. When docs promise behavior code does not implement, record a code/product gap. When code exposes material behavior docs do not describe, record a docs/spec gap.
4. Evidence must be line-aware. Cite code `file:line`, docs `path#heading`, command artifacts, and screenshots/logs where applicable.
5. Do not fix code during audit.
6. Keep jobs bounded. Each job should focus on the required output and top launch risks. Do not attempt exhaustive repo coverage — that is why the launcher splits the audit across many jobs.
7. Use current web research only for the market comparison job, and only when competitors/alternatives are listed in the product profile.
8. Log unexplored boundaries. When you hit the job budget or context limit and have identified P0/P1 areas you could not finish, write them to `pending-jobs.tsv` per the Exploration Boundary Protocol below. The launcher queues them as follow-up deep-dive jobs automatically.

## Shared Standards Gate

Read and apply the shared Cadres standards before closing any audit job that evaluates code, UI, tests, docs, or launch readiness:

- `/home/pete/cadres/shared/templates/coding.md`: coding standard, file/function size limits, helper expectations, and single-source-of-truth rules.
- `/home/pete/cadres/shared/templates/ui-specification.md`: UI/UX conventions for frontend, route, workflow, and operator-facing surfaces.
- `/home/pete/cadres/shared/templates/definition-of-done-checklist.md`: completion gate for implementation quality, tests, docs, operations, and failure handling.
- `/home/pete/cadres/shared/AGENTS.md`: execution philosophy and enterprise-grade completion bar.

For each relevant finding, classify standards violations as first-class launch-readiness issues, not cosmetic concerns. Examples include oversized or duplicated code that violates the coding standard, UI flows that violate the UI specification, missing failure-path handling, missing docs/tests required by definition of done, or incomplete platform integration. If a job does not touch frontend/UI, state that the UI standard was not applicable. If any shared standard file is unavailable, record that as residual audit risk.

## Exploration Boundary Protocol

This applies to all discovery and synthesis jobs. When you reach the job budget, context limit, or a major unexplored module that is materially relevant to P0/P1 launch readiness, log it as a pending deep-dive by **appending** a tab-separated row to:

`$RUN_DIR/artifacts/pending-jobs.tsv`

**If the file does not exist**, create it with this exact tab-separated header:

```
job_id	parent_job	depth	entry_point	files	scope	rationale
```

**Then append one row per unexplored boundary** (all fields tab-separated, no newlines within a field):

| Field | Content |
|---|---|
| `job_id` | Unique slug, e.g. `deep-<parent>-<topic>` — no spaces, slashes, or tabs |
| `parent_job` | The current job's ID |
| `depth` | `1` (standard jobs spawn at depth 1; depth-1 jobs spawn at depth 2) |
| `entry_point` | `file:line`, function name, or module to start from |
| `files` | Comma-separated repo-relative paths for the follow-up agent to focus on |
| `scope` | One sentence: what specifically to investigate |
| `rationale` | One sentence: why this is a P0/P1 launch risk |

**Only log P0/P1 risk areas** you identified but could not finish. Do not log for completeness. Maximum 5 pending entries per job — prioritize by severity.

The launcher automatically queues logged entries as follow-up deep-dive jobs after the current group completes, up to the configured depth cap (default: 2).

## Required Output Layout

```text
RUN_DIR/
├── 00-orchestrator-plan.md
├── 01-domain/
├── 02-cross-cutting/
├── 03-spec-additions/
├── 08-launch-readiness.md
├── 10-runtime-verification.md
├── 11-maturity-stage-simulation.md
├── 13-adversarial-review.md
└── 14-final-release-decision.md
```

## GENERIC PHASE 0

Bootstrap the run directory. Inventory repo docs, source roots, tests, package/build files, deployment docs, CI configs, and product profile completeness. Write `00-orchestrator-plan.md`.

## GENERIC 1A

Audit product claims and docs. Map launch claims from the product profile to documentation and likely implementation surfaces. Identify missing, vague, or overclaimed launch promises.

## GENERIC 1B

Audit architecture, data model, and trust boundaries. Find core entities, ownership boundaries, sensitive data, persistence, migrations, retention, authorization boundaries, and external dependencies.

## GENERIC 1C

Audit user/operator journeys. Identify critical workflows from the profile and docs, then map them to UI/API/CLI surfaces and tests. For UI surfaces, explicitly check the relevant routes/components against `/home/pete/cadres/shared/templates/ui-specification.md`.

## GENERIC 2A

Audit backend/API/domain logic. Focus on core launch claims, validation, permissions, error handling, idempotency, state transitions, and data integrity. Check changed or high-risk backend code against `/home/pete/cadres/shared/templates/coding.md` and the definition-of-done checklist.

## GENERIC 2B

Audit frontend/client/mobile/CLI surfaces. Focus on critical user journeys, forms, errors, loading/empty states, accessibility, client/server contract drift, and unsupported routes. Check frontend surfaces against `/home/pete/cadres/shared/templates/ui-specification.md`, `/home/pete/cadres/shared/templates/coding.md`, and the definition-of-done checklist.

## GENERIC 2C

Audit integrations, async jobs, protocols, imports/exports, webhooks, queues, scheduled work, and external service failure handling. Use product-specific integrations from the profile.

## GENERIC 3A

Cross-cutting security and data-boundary synthesis. Challenge authentication, authorization, tenant/account/project scoping if present, public endpoints, sensitive data exposure, CSRF/session/token behavior, secrets, and destructive actions.

## GENERIC 3B

Cross-cutting operability and recovery synthesis. Review logs, audit trails, metrics, migrations, backups, retries, rollback, partial failure, runbooks, deployment docs, and support/admin workflows.

## GENERIC 3C

Cross-cutting test, docs, and maintainability synthesis. Compare launch claims to tests and docs. Identify missing integration/E2E coverage, stale tests, unsupported smoke paths, large/refactor-risk files, and violations of the shared coding, UI, and definition-of-done standards.

## GENERIC 3D

Cross-cutting stale-code, superseded-path, and stub audit. Treat replacement implementations as a presumption that the old implementation should be retired unless there is an explicit compatibility contract.

Find and classify:

- Old and new implementations coexisting for the same behavior after a design pivot.
- Legacy routes, services, jobs, UI pages/components, API clients, feature flags, env/config keys, scripts, migrations, schemas, or tests that are no longer referenced by current workflows.
- Compatibility shims, `v1`/`v2` duplicates, `old`/`new` pairs, `legacy`, `deprecated`, `temporary`, `compat`, `shim`, `fallback`, `todo`, `stub`, `placeholder`, `mock`, `not implemented`, `coming soon`, and `no-op` code that still ships.
- Backend endpoints with no frontend, agent, job, CLI, documentation, or external caller.
- Frontend routes/components hidden from navigation but still bundled.
- Tests and docs that preserve obsolete behavior and prevent deletion.
- Tables, columns, models, queue/job payloads, or event names no longer written/read except by legacy tests or stale scripts.

Use deterministic repo evidence before making claims. At minimum inspect:

- Text search for stale markers: `legacy|deprecated|superseded|stub|placeholder|mock|no-op|not implemented|coming soon|temporary|compat|shim|v1|v2|old|new|TODO|FIXME`.
- Exported symbol references versus imports/callers where the language tooling makes that practical.
- Route/API inventories versus frontend/API-client/job/docs references.
- Frontend route/component inventory versus router/nav references.
- Config/env keys versus runtime usage and docs.
- Tests that reference symbols with no production callers.

For each finding, provide:

- Stale artifact path plus symbol/component/route/job/config name.
- Replacement/current artifact if one exists.
- Evidence that it is unreachable, duplicated, stubbed, or superseded, with line-aware citations.
- Deletion or convergence plan.
- Migration/data/customer-compatibility risk.
- Exact tests required after removal.
- Classification: `safe-delete`, `staged-removal`, `merge-with-current-path`, or `product-decision-required`.

Write a machine-readable candidate list to `RUN_DIR/artifacts/stale-code-candidates.tsv` with this exact tab-separated header when findings exist:

```text
candidate_id	severity	classification	stale_artifact	replacement_artifact	evidence	required_remediation	tests_after_removal
```

Do not report generic large-file or style issues unless they are evidence of superseded/stubbed code. Prefer deletion and convergence over additional abstraction.

## 9D

Product-profile stale-code, superseded-path, and stub audit. Follow the same protocol as `GENERIC 3D`, but ground findings in this product's launch claims, architecture docs, critical journeys, and prior audit outputs under `RUN_DIR/01-domain/` and `RUN_DIR/02-cross-cutting/`.

Focus especially on design-pivot residue:

- Old implementation path left in place after a new path landed.
- Feature stubs or placeholder UI/API surfaces that make launch claims look implemented.
- Duplicate service/client/helper layers where one supersedes another.
- Hidden pages, unused routes, stale API endpoints, dead jobs, abandoned migrations, old event payloads, stale docs/tests, and unused config/feature flags.

For every finding, state whether remediation should delete code, merge callers onto the current path, remove/update stale tests/docs, or require a product decision because external compatibility is still plausible.

## GENERIC 4

Market or alternative comparison. Use only product-profile competitors or repo-documented alternatives. Browse current public sources when needed. Do not invent market claims.

## GENERIC 5

Synthesize launch readiness. Produce severity-ranked blockers, security register, docs/test gaps, shared-standards gaps, launchable subset, non-launchable claims, and required remediation before re-decision.

## GENERIC 6

Runtime verification. Run repo-supported build/lint/typecheck/test/migration/browser/protocol checks from the profile or repo docs. Save raw outputs under `RUN_DIR/artifacts/06-runtime/`.

**Accessibility** (when `ACCESSIBILITY_SCAN=1`, injected by launcher): For each page visited during browser automation, run an axe-core scan and report WCAG 2.1 AA violations by severity. Save raw JSON reports to `RUN_DIR/artifacts/<job_id>/accessibility/`.

**Lighthouse / Core Web Vitals** (when `LIGHTHOUSE_SCAN=1`, injected by launcher): Run the Lighthouse CLI against the login page, primary dashboard, and any performance-sensitive page. Report performance score, LCP, CLS, INP, TTFB. Performance score < 50 or any poor Core Web Vital is a launch blocker. Save JSON reports to `RUN_DIR/artifacts/<job_id>/lighthouse/`.

**External services** (when `EXTERNAL_SERVICES_TEST=1`, injected by launcher): Probe each external service integration found in the repo — OAuth providers, SaaS APIs, SMTP, webhooks, cloud SDKs. Use credentials from `docs/ux/.creds` if available; mark UNVERIFIED if not. Save raw logs to `RUN_DIR/artifacts/<job_id>/external-services/`.

**SAST and dependency CVEs** (when `SAST_ENABLED=1`, injected by launcher): Run Bandit and Semgrep for static analysis, pip-audit and npm audit for dependency CVEs. Report all critical and high findings in full. Critical CVEs in direct dependencies or high-severity SAST findings with documented exploits are launch blockers. Save raw outputs to `RUN_DIR/artifacts/<job_id>/sast/`.

## GENERIC 7

Customer/operator simulation. Execute critical launch journeys from the product profile.

**CRITICAL UI TESTING PROTOCOL:** Do NOT attempt to write or execute raw JavaScript/Playwright scripts. You must use the provided `mcp_playwright_browser_*` tools to interactively drive the browser.
1. Navigate to the local staging URL.
2. Use `browser_snapshot` after every action to understand the current page state.
3. Use `browser_click`, `browser_fill_form`, etc., to progress through the journey step-by-step.
4. If you encounter an error toast or unexpected state, log it as a UI failure.
If a journey cannot be completed via interactive browser tools, or if you need to manipulate backend state (e.g. seeding test data), use the `lattice` tools if available. If UI interaction fails entirely, mark it as FAILED and explain where the UI blocked you.

**Accessibility** (when `ACCESSIBILITY_SCAN=1`, injected by launcher): Run axe-core scans on each page reached during simulated journeys. A critical or serious WCAG violation on an operator-facing page is a launch blocker.

**Lighthouse** (when `LIGHTHOUSE_SCAN=1`, injected by launcher): Run Lighthouse against pages visited during simulation. A poor Core Web Vital on a critical customer journey page is a launch blocker.

## GENERIC LOAD TEST

Optional load test auto-injected by the launcher when `LOAD_TEST_ENABLED=1`. Runs after all runtime and simulation jobs so scenario selection can be grounded in prior findings.

Use the preferred tool (`LOAD_TEST_TOOL`, default k6). Auto-detect the target base URL from `docs/ux/.creds` or deployment docs if `LOAD_TEST_TARGET` is not set.

Run three scenarios:

1. **Baseline** — 10 VUs, 60s steady state. Establishes per-request latency baseline.
2. **Ramp** — 1→50 VUs over 2 minutes, hold 1 minute, ramp down. Finds the throughput ceiling.
3. **Spike** — 100 VUs for 30 seconds. Tests resilience under sudden traffic bursts.

Target the auth endpoint, primary read API, and primary write/mutation endpoint. Flag as FAIL if p95 > 2000ms, p99 > 5000ms, or error rate > 1% (baseline/ramp) / 5% (spike), unless the product profile specifies tighter SLOs.

Save raw tool output and generated scripts to `RUN_DIR/artifacts/load-test/`. Write a summary report to `RUN_DIR/artifacts/load-test/load-test-report.md`.

## GENERIC 8

Adversarial launch challenge. Challenge the candidate readiness decision from security, product, operational, data integrity, and customer evidence perspectives.

## GENERIC 9

Final release decision. Decide: broad launch, restricted launch, internal/design-partner only, or no launch. Final signoff is invalid if runtime verification, critical journey simulation, adversarial review, or shared standards review is missing or failing for launch-critical code or UI surfaces.
