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

Audit user/operator journeys. Identify critical workflows from the profile and docs, then map them to UI/API/CLI surfaces and tests.

## GENERIC 2A

Audit backend/API/domain logic. Focus on core launch claims, validation, permissions, error handling, idempotency, state transitions, and data integrity.

## GENERIC 2B

Audit frontend/client/mobile/CLI surfaces. Focus on critical user journeys, forms, errors, loading/empty states, accessibility, client/server contract drift, and unsupported routes.

## GENERIC 2C

Audit integrations, async jobs, protocols, imports/exports, webhooks, queues, scheduled work, and external service failure handling. Use product-specific integrations from the profile.

## GENERIC 3A

Cross-cutting security and data-boundary synthesis. Challenge authentication, authorization, tenant/account/project scoping if present, public endpoints, sensitive data exposure, CSRF/session/token behavior, secrets, and destructive actions.

## GENERIC 3B

Cross-cutting operability and recovery synthesis. Review logs, audit trails, metrics, migrations, backups, retries, rollback, partial failure, runbooks, deployment docs, and support/admin workflows.

## GENERIC 3C

Cross-cutting test, docs, and maintainability synthesis. Compare launch claims to tests and docs. Identify missing integration/E2E coverage, stale tests, unsupported smoke paths, and large/refactor-risk files.

## GENERIC 4

Market or alternative comparison. Use only product-profile competitors or repo-documented alternatives. Browse current public sources when needed. Do not invent market claims.

## GENERIC 5

Synthesize launch readiness. Produce severity-ranked blockers, security register, docs/test gaps, launchable subset, non-launchable claims, and required remediation before re-decision.

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

Final release decision. Decide: broad launch, restricted launch, internal/design-partner only, or no launch. Final signoff is invalid if runtime verification, critical journey simulation, or adversarial review is missing or failing.
