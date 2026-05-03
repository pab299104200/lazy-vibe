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
6. Keep jobs bounded. Each job should focus on the required output and top launch risks.
7. Use current web research only for the market comparison job, and only when competitors/alternatives are listed in the product profile.

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

## GENERIC 7

Customer/operator simulation. Execute critical launch journeys from the product profile using supported runtime/browser/API harnesses. If a journey lacks a runnable harness, mark it unverified.

## GENERIC 8

Adversarial launch challenge. Challenge the candidate readiness decision from security, product, operational, data integrity, and customer evidence perspectives.

## GENERIC 9

Final release decision. Decide: broad launch, restricted launch, internal/design-partner only, or no launch. Final signoff is invalid if runtime verification, critical journey simulation, or adversarial review is missing or failing.
