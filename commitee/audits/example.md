# Financial Platform — Launch-Readiness Audit Prompt (Example)

> **This is a worked example for a mid-market financial automation platform. Copy it to a new file under `audits/`, replace the product description and repo path, and adapt the domain phases for your own product.**

**Purpose:** Single self-contained prompt to run a full code-vs-spec, security, refactoring, workflow, financial-integrity, and market-positioning audit using one orchestrator plus parallel subagents per phase. Each subagent's working set is capped by tightly scoping its domain.

**How to use:** Pass this file to `agent_loop.py` via `--instruction-file audits/your-product.md --task-type audit`. Use the strongest available model. Do not edit code or read large files in the orchestrator session itself; the orchestrator dispatches subagents, records summaries, and synthesizes the disk artifacts.

---

## AUDIT PROMPT

You are the **orchestrator** of a launch-readiness audit of the codebase at `{repo}`. This is a mid-market financial automation platform spanning CRM, billing, accounting, tax, bank, documents, expenses, communications, and product integrations for companies up to roughly `$100M` in revenue. It is not freelancer software, not a toy billing app, and not an ERP clone. Its competitive context is **Sage Intacct, NetSuite, QuickBooks Online Advanced, Xero upper-tier, FreshBooks, Wave, Stripe Billing, Chargebee, Maxio, Recurly, Ramp, Brex, Bill.com, Mercury, Plaid-connected accounting flows, and finance-automation layers built around modern SaaS operations**.

> **Adapt this paragraph for your product.** Replace the description above with your product's actual mission and competitive positioning.

The product's explicit mission is to become a best-in-class mid-market financial automation platform that connects CRM, billing, accounting, tax, bank, documents, communications, expenses, and product contracts into one coherent operational system. The product bar is not "can an operator manually do it eventually?" The bar is **financially correct, automation-first, auditable, tenant-safe, and operationally trustworthy under real volume and pressure**.

**Mission positioning to audit against:**

- **Finance-native end-to-end workflows.** CRM opportunities, customer records, product contracts, subscriptions, invoices, payments, revenue recognition, refunds, credits, AR aging, dunning, GL posting, bank reconciliation, tax obligations, documents, and operator communications must connect without manual export/import or duplicate entry.
- **Automation with humans for exceptions only.** Invoice generation, contract handoff, payment-provider setup, revenue posting, dunning escalation, bank matching, expense policy evaluation, close checklists, quarterly tax estimates, report scheduling, daily digests, and product integration events should be inferred, scheduled, triggered, or detected automatically wherever possible. Repetitive manual operator work is a design failure unless there is a real control reason.
- **Financial integrity over UI completeness.** Every amount, ledger entry, tax value, subscription state, contract state, payment event, refund, credit, and reconciliation decision must have a durable, explainable source of truth. Pretty screens that can drift from accounting truth are launch blockers.
- **Tenant and entity safety.** The product scopes tenants by `tenant_id` and uses company entities for multi-entity financial work. Tenant-owned queries must be scoped. Entity-aware workflows must not collapse multi-entity truth into a singleton unless the docs explicitly define that boundary.
- **Auditability and recoverability.** Meaningful state changes, especially financial, security, destructive, archive, approval, import, webhook, and contract actions, must be audited with actor, target, action, and relevant before/after state. Failures must be diagnosable and recoverable without admin heroics.
- **External dependency honesty.** SSO OAuth/directory sync, Stripe/payment providers, Plaid/bank feeds, SMTP/SMS/WhatsApp providers, product-contract APIs, and integration webhooks must fail closed with actionable operator states. A green UI over a broken dependency is a bug.
- **Mid-market scale from day one.** Search, filtering, pagination, aggregation, reconciliation, dashboards, and reports must work for real customer counts, invoice volume, transaction volume, document volume, and communications history. Client-side reconstruction of server truth and N+1 loading are findings.
- **Mission-fit market position.** The product wins only if it gives mid-market operators more trustworthy automation than accounting point tools plus spreadsheets. Audit whether the actual product is closer to a coherent financial operations platform or a loose bundle of screens.

Your job: orchestrate a code-vs-spec, security, refactoring, workflow, financial-integrity, and launch-readiness audit using parallel subagents. You dispatch; you do not read code yourself except at synthesis time from short reports and consolidated registers. All findings get written to disk by subagents.

### Operating Rules

1. **Spec is master.** When code does not implement spec, that is a code gap. When code implements behavior not in spec, that is a spec gap. Document both directions.
2. **Evidence-based only.** Every finding must cite `file:line` for code and `path#heading` for docs/specs. No vibes.
3. **Findings to disk.** Each subagent writes its own file. The orchestrator keeps only short summaries in context.
4. **Cap each subagent.** Keep each subagent under roughly 120k tokens. For files over 1500 lines, use `mcp__lattice__get_skeleton` first, then targeted reads. Use `mcp__lattice__get_context_capsule`, `mcp__lattice__get_docs_capsule`, and `mcp__lattice__find_relevant_tests` instead of broad file reads where practical.
5. **No remediation during audit.** Subagents document findings; they do not edit code. Spec additions for code-not-in-spec are allowed only as append-only `NEEDS-REVIEW` blocks.
6. **Track operator burden as first-class.** Manual setup, repeated entry, exports/imports, "operator must remember" workflows, multi-screen reconciliation, avoidable configuration, and missing defaults are findings. Grade by frequency, tenant impact, and financial risk.
7. **Track financial integrity rigorously.** Anything that can misstate AR/AP, revenue, tax, ledger, payment, refund, credit, reconciliation, or close truth is P0/P1 depending on blast radius.
8. **Track tenant and entity boundaries rigorously.** Every endpoint touched must be checked for `tenant_id` and, where relevant, company-entity scope. Cross-tenant leaks are P0. Cross-entity financial misstatements are P0/P1.
9. **Run phases in parallel where possible.** Phases 1-12 each dispatch three subagents in one orchestrator turn. Phase 12.5 is one web-research subagent. Phase 13 is synthesis.

### Output Layout

Create at session start:

```text
docs/audit/YYYY-MM-DD-launch-readiness/
├── 00-orchestrator-plan.md
├── 01-domain/
│   ├── 01a-auth-sessions.md
│   ├── 01b-rbac-admin-access.md
│   ├── 01c-tenancy-entity-scope.md
│   ├── 02a-crm-customers-pipeline.md
│   ├── 02b-crm-activities-ownership.md
│   ├── 02c-crm-product-contracts.md
│   ├── 03a-products-plans-subscriptions.md
│   ├── 03b-invoices-payments-credits-refunds.md
│   ├── 03c-payment-providers-webhooks-self-serve.md
│   ├── 04a-revenue-recognition-obligations.md
│   ├── 04b-general-ledger-journals-statements.md
│   ├── 04c-close-consolidation-multicurrency.md
│   ├── 05a-bank-feeds-reconciliation.md
│   ├── 05b-etl-connections-imports-rules.md
│   ├── 05c-mercury-rmm-product-events.md
│   ├── 06a-expenses-vendors-approvals.md
│   ├── 06b-purchasing-ap-bills.md
│   ├── 06c-tax-sales-obligations-filings.md
│   ├── 07a-communications-channels-messages.md
│   ├── 07b-communications-automation-deliverability.md
│   ├── 07c-notifications-digests-sla.md
│   ├── 08a-documents-attachments-storage.md
│   ├── 08b-company-profile-entities-controls.md
│   ├── 08c-dashboard-reporting-schedules.md
│   ├── 09a-portal-oauth-directory-sync.md
│   ├── 09b-platform-runtime-scheduler-readiness.md
│   └── 09c-security-rate-limits-secrets.md
├── 02-cross-cutting/
│   ├── 10a-security-auth-boundaries.md
│   ├── 10b-security-data-protection.md
│   ├── 10c-security-tenant-entity-isolation.md
│   ├── 11a-refactor-backend.md
│   ├── 11b-refactor-frontend.md
│   ├── 11c-test-coverage.md
│   ├── 12a-ux-finance-operator-journeys.md
│   ├── 12b-ux-customer-vendor-journeys.md
│   ├── 12c-automation-gaps.md
│   └── 12_5-competitor-snapshot.md
├── 03-spec-additions/
├── 04-gap-register.md
├── 05-security-register.md
├── 06-refactor-register.md
├── 07-market-positioning.md
├── 08-launch-readiness.md
└── 09-executive-summary.md
```

### Severity Scale

- **P0** — blocks launch: cross-tenant leak, broken auth boundary, financial misstatement, broken ledger/payment/contract core flow, destructive data loss, audit-trail gap on control-sensitive financial action, production readiness lie, regulatory/tax violation.
- **P1** — must fix before GA: spec gap on advertised feature, missing failure handling on critical journey, broken UX on critical operator flow, missing audit on meaningful state change, dependency failure hidden from operators, entity-scope defect with bounded blast radius.
- **P2** — should fix before GA: maintainability issue, missing edge-case test, workflow friction, incomplete automation, pagination/search scale risk, weaker observability.
- **P3** — post-launch acceptable: enhancement, polish, future integration depth, low-frequency automation improvement.

### Per-Domain Report Template

```markdown
# <Domain Name> — Audit Report

**Subagent:** <id>  **Date:** <date>
**Specs reviewed:**
- docs/architecture/<file>.md (sections used)
- docs/functional/<file>.md (sections used)
- docs/manual/<file>.md (if exists)

**Code surveyed:**
- backend/routers/<path>.py
- backend/models/<path>.py
- backend/core/<path>.py
- backend/tests/test_<name>.py
- frontend/src/pages/<path>.tsx
- frontend/src/services/api.ts

## 1. Spec-to-code coverage map
| Spec section (path#heading) | Implemented in (file:lines) | Status |
|---|---|---|

## 2. Code-to-spec coverage map
| Code (file:lines) | Behavior summary | Spec patch location | Flag |
|---|---|---|---|

## 3. Gaps
### GAP-01 — <one-line title> [P0/P1/P2/P3]
- **Spec:** path#heading says ...
- **Reality:** file:line implements ...
- **Evidence:** code/test/doc references.
- **Fix:** specific change at file:line.

## 4. Security findings
### SEC-01 — <title> [P0/P1/P2/P3]
- file:line, attack vector, blast radius, fix.

## 5. Financial integrity findings
### FIN-01 — <title> [P0/P1/P2/P3]
- source of truth affected, misstatement risk, recovery path, fix.

## 6. Refactor opportunities
### REF-01 — <title> [P2/P3, ROI: H/M/L]
- file:line, rationale, scope estimate.

## 7. Test coverage assessment
- What's tested, what's not, missing tenant negatives, missing RBAC negatives, missing entity-scope tests, missing financial failure tests.

## 8. Operator burden / automation gaps
- Manual work, repeated entry, avoidable config, missing defaults, export/import sidecars, batch/template opportunities, and actions that should be inferred/scheduled/triggered/detected.

## 9. Dependency, observability, and recovery
- External dependencies, failure states, retries/idempotency, logs, audit, operator recovery path.

## 10. Domain verdict
- **Launch readiness for this domain:** Ready / Needs work / Blocked
- **Top 3 must-fix items before launch.**
```

### Subagent Return Summary Template

```text
DOMAIN: <name>
REPORT: docs/audit/YYYY-MM-DD-launch-readiness/01-domain/<file>.md
COUNTS: gaps P0=N P1=N P2=N P3=N | security P0=N P1=N P2=N | financial P0=N P1=N P2=N | refactor P2=N P3=N
TOP-3 BLOCKERS:
1. <one line + severity>
2. ...
3. ...
SPEC ADDITIONS WRITTEN: <paths or "none">
VERDICT: <Ready | Needs work | Blocked>
NOTES FOR SYNTHESIS: <cross-domain signals>
```

---

### PHASE 0 — Bootstrap

1. Verify the audit output directory does not exist yet. If it does, append `-rerun-N`.
2. Create the directory tree above.
3. Write `00-orchestrator-plan.md` with this plan, the dispatch table, and an empty per-phase log.
4. Inventory `docs/architecture/`, `docs/functional/`, `docs/manual/`, `backend/routers/`, `backend/models/`, `backend/core/`, `backend/tests/`, `frontend/src/pages/`, `frontend/src/components/`, `frontend/src/services/`, and `frontend/e2e/`.
5. Update the plan file with discovered inventories.

### PHASE 1 — Identity, RBAC, Tenancy, Entity Scope

**1A — Authentication and session lifecycle**
- Specs: `docs/architecture/authentication.md`, `docs/functional/authentication.md`, `docs/manual/getting-started.md`.
- Backend: `backend/routers/auth.py`, `backend/core/auth.py`, `backend/models/auth_tokens.py`, `backend/tests/test_auth.py`, `backend/tests/test_auth_security.py`, `backend/tests/test_auth_session_contract.py`.
- Frontend: `frontend/src/pages/Login.tsx`, `frontend/src/pages/AuthCallback.tsx`.
- Lens: SSO OAuth2 callback, refresh-token rotation, cookie/session behavior, strict launch JWT configuration, CSRF/state storage, logout revocation, failed auth errors, shadow-user creation.
- Output: `01-domain/01a-auth-sessions.md`.

**1B — RBAC, admin access, permissions**
- Specs: `docs/architecture/rbac.md`, `docs/functional/rbac-permissions.md`, `docs/functional/admin-access.md`.
- Backend: `backend/routers/admin_access.py`, `backend/core/rbac.py`, `backend/core/permissions.py`, `backend/models/portal_shadow.py`, RBAC tests.
- Frontend: `frontend/src/pages/AdminAccess.tsx`, `frontend/src/pages/admin/*`.
- Lens: permission catalog parity, role/grant assignment, default deny, mutating endpoint guards, admin access workflow, group/user grants, audit trail.
- Output: `01-domain/01b-rbac-admin-access.md`.

**1C — Tenant and company-entity scope**
- Specs: `docs/architecture/system-overview.md`, `docs/architecture/company.md`, `docs/functional/company.md`, `docs/manual/company.md`.
- Backend: all models with `tenant_id` or entity IDs, `backend/core/request_tenant.py`, tenant/session dependencies, RLS tests.
- Frontend: entity selectors and company profile surfaces.
- Lens: every query scopes tenant; entity-aware finance paths do not leak or mix data; default entity semantics are explicit; RLS/session variables match docs.
- Output: `01-domain/01c-tenancy-entity-scope.md`.

### PHASE 2 — CRM and Product Contracts

**2A — Customers, contacts, deals, pipeline**
- Specs: `docs/architecture/crm.md`, `docs/functional/crm.md`, `docs/manual/crm.md`.
- Backend: `backend/routers/crm/*`, `backend/models/customer.py`, `backend/models/crm.py`, CRM tests.
- Frontend: `frontend/src/pages/CRM.tsx`, `frontend/src/pages/crm/*`.
- Lens: customer source of truth, deal stage state, contact ownership, search/pagination, activity timeline integrity, customer-to-billing links.
- Output: `01-domain/02a-crm-customers-pipeline.md`.

**2B — CRM activities, ownership, reporting**
- Specs: same CRM specs plus communications integration docs.
- Backend: `crm/activities.py`, `crm/ownership.py`, `crm/reporting.py`, `crm/workspace.py`, CRM runtime tests.
- Frontend: CRM workspace panels and reporting views.
- Lens: owner assignment, task/activity workflow, linked communication capture, reporting correctness, no manual context hunting.
- Output: `01-domain/02b-crm-activities-ownership.md`.

**2C — Product contracts and cross-product events**
- Specs: `docs/architecture/integration.md`, `docs/functional/integration.md`, `docs/functional/rmm-integration.md`, `docs/manual/integration.md`.
- Backend: `backend/routers/integrations/product_contracts.py`, `backend/routers/integrations/product_events.py`, `backend/routers/billing/capability_contracts.py`, `backend/core/product_contracts.py`, `backend/core/contract_change_requests.py`, `backend/core/integration_events.py`.
- Frontend: product integration and capability contract panels.
- Lens: machine auth, contract read/write boundary, change-request state machine, product event idempotency, RMM/product tenant mapping.
- Output: `01-domain/02c-crm-product-contracts.md`.

### PHASE 3 — Billing, Payments, Self-Serve

**3A — Products, plans, subscriptions**
- Specs: `docs/architecture/billing.md`, `docs/functional/billing.md`, `docs/manual/billing.md`.
- Backend: `backend/routers/billing/subscriptions.py`, `contracts.py`, `usage.py`, `backend/models/billing/*`, subscription tests.
- Frontend: `frontend/src/pages/Billing.tsx`, `Products.tsx`, `frontend/src/pages/billing/*`.
- Lens: subscription lifecycle, plan price mapping, usage billing, contract/version truth, limits, downgrade behavior.
- Output: `01-domain/03a-products-plans-subscriptions.md`.

**3B — Invoices, payments, credits, refunds, dunning**
- Specs: `docs/architecture/finance.md`, `docs/functional/finance.md`, `docs/manual/finance.md`.
- Backend: `backend/routers/finance/invoices.py`, `payments.py`, `revenue.py`, billing obligations, finance tests.
- Frontend: `Invoices.tsx`, `Finance.tsx`, finance sections, customer billing detail.
- Lens: AR truth, payment application, credit/refund GL impact, dunning state, partial failure behavior, invoice PDF/email delivery.
- Output: `01-domain/03b-invoices-payments-credits-refunds.md`.

**3C — Payment providers, webhooks, self-serve**
- Specs: billing and integration docs.
- Backend: `payment_providers.py`, `payment_webhooks.py`, `stripe_webhooks.py`, `portal.py`, `self_serve.py`, `return_urls.py`, provider tests.
- Frontend: payment provider and self-serve panels.
- Lens: webhook signature verification, idempotency, return URL allowlist, hosted payment links, provider failures, customer-facing scope.
- Output: `01-domain/03c-payment-providers-webhooks-self-serve.md`.

### PHASE 4 — Accounting, Revenue, Close

**4A — Revenue recognition and performance obligations**
- Specs: `docs/architecture/accounting.md`, `docs/functional/accounting.md`, `docs/functional/billing.md`.
- Backend: deferred revenue, obligations, revenue analytics, GL engine, GAAP tests.
- Frontend: `Revenue.tsx`, `DeferredRevenue.tsx`, `BillingPerformanceObligations.tsx`.
- Lens: ASC 606 behavior, deferred revenue schedules, contract modifications, GL posting, reversals, auditability.
- Output: `01-domain/04a-revenue-recognition-obligations.md`.

**4B — General ledger, journals, statements**
- Specs: `docs/architecture/accounting.md`, `docs/functional/accounting.md`, `docs/manual/accounting.md`.
- Backend: accounting routers, `backend/core/gl_engine.py`, accounting models/tests.
- Frontend: `GeneralLedger.tsx`, `JournalEntries.tsx`, `FinancialStatements.tsx`, statement panels.
- Lens: double-entry invariants, journal approval/void rules, statement math, AR/AP integration, raw SQL safety.
- Output: `01-domain/04b-general-ledger-journals-statements.md`.

**4C — Close, consolidation, multicurrency**
- Specs: `docs/functional/close-engine.md`, `docs/functional/consolidation.md`, `docs/manual/consolidation.md`, accounting docs.
- Backend: close runs, consolidation, exchange rates, annual package, multicurrency tests.
- Frontend: `CloseRuns.tsx`, `AnnualPackage.tsx`, `ExchangeRates.tsx`, close-run detail.
- Lens: close state machine, period locking, entity consolidation, intercompany elimination, FX translation, immutable close evidence.
- Output: `01-domain/04c-close-consolidation-multicurrency.md`.

### PHASE 5 — Bank, ETL, Integrations

**5A — Bank feeds and reconciliation**
- Specs: `docs/architecture/bank.md`, `docs/functional/bank.md`, `docs/manual/bank.md`.
- Backend: accounting bank feed/recon routers, bank models, bank matching, Plaid tests.
- Frontend: `BankFeeds.tsx`, `BankReconciliation.tsx`.
- Lens: feed sync idempotency, matching correctness, stale credentials, replay, unmatched transaction recovery, statement reconciliation.
- Output: `01-domain/05a-bank-feeds-reconciliation.md`.

**5B — ETL connections, imports, matching rules**
- Specs: `docs/architecture/etl-engine.md`, `docs/functional/etl-engine.md`, `docs/manual/etl-connections.md`.
- Backend: `backend/routers/etl/*`, `backend/models/etl.py`, ETL tests.
- Frontend: `ETLConnections.tsx`, `frontend/src/pages/etl/*`.
- Lens: source connection lifecycle, import state machine, transform/matching rules, tenant scoping, error surfacing, large-file scale.
- Output: `01-domain/05b-etl-connections-imports-rules.md`.

**5C — Mercury, RMM, product webhooks**
- Specs: `docs/functional/rmm-integration.md`, `docs/architecture/integration.md`, integration manuals.
- Backend: `etl/mercury.py`, `integrations/rmm.py`, product events, RMM webhook tests, Mercury OAuth tests.
- Frontend: integration surfaces.
- Lens: OAuth state, webhook authenticity, cross-product tenant mapping, idempotency, dependency failure clarity.
- Output: `01-domain/05c-mercury-rmm-product-events.md`.

### PHASE 6 — Expenses, Purchasing, Tax

**6A — Expenses, vendors, approvals**
- Specs: `docs/architecture/expenses.md`, `docs/functional/expenses.md`, `docs/manual/expenses.md`, `docs/functional/vendors.md`.
- Backend: expenses routers, vendor routers/models, expense policy engine, tests.
- Frontend: `Expenses.tsx`, `Vendors.tsx`.
- Lens: approval controls, policy automation, receipt handling, reimbursements, vendor tenancy, 1099 readiness.
- Output: `01-domain/06a-expenses-vendors-approvals.md`.

**6B — Purchasing and AP bills**
- Specs: accounting, expenses, and finance docs.
- Backend: bills, purchase orders, goods receipts, three-way matching, AP tests.
- Frontend: `Bills.tsx`, `PurchaseOrders.tsx`, `GoodsReceipts.tsx`, `ThreeWayMatching.tsx`.
- Lens: PO/bill/receipt matching, AP aging, approvals, duplicate invoice prevention, GL impact.
- Output: `01-domain/06b-purchasing-ap-bills.md`.

**6C — Tax, sales tax, obligations, filings**
- Specs: `docs/architecture/tax.md`, `docs/functional/tax.md`, `docs/manual/tax.md`.
- Backend: tax routers, sales tax, quarterly tax, obligation engine, tax tests.
- Frontend: tax pages and compliance calendar.
- Lens: nexus, rates, filing readiness, remittance automation, tax GL integrity, regulatory error risk.
- Output: `01-domain/06c-tax-sales-obligations-filings.md`.

### PHASE 7 — Communications and Notifications

**7A — Channels, conversations, messages**
- Specs: `docs/architecture/communications.md`, `docs/functional/communications.md`, `docs/manual/communications.md`.
- Backend: comms routers/models/core plugins, message tests.
- Frontend: `Communications.tsx`.
- Lens: channel setup, inbound/outbound message integrity, threading, attachment handling, contact preferences.
- Output: `01-domain/07a-communications-channels-messages.md`.

**7B — Automation, deliverability, webhooks**
- Specs: communications docs.
- Backend: comms rules, dispatcher, retry, health monitor, webhooks, templates, bounce parser.
- Frontend: automation/rules surfaces.
- Lens: tracking consent fail-closed, retries, webhook signatures, provider health, no silent delivery failures.
- Output: `01-domain/07b-communications-automation-deliverability.md`.

**7C — Notifications, daily digests, SLA**
- Specs: communications, company, and scheduler docs.
- Backend: notification manager, daily digest, SLA/escalation, scheduler loops.
- Frontend: notification and dashboard surfaces.
- Lens: tenant-explicit digest behavior, SLA escalation, alert fatigue, operator recovery.
- Output: `01-domain/07c-notifications-digests-sla.md`.

### PHASE 8 — Documents, Company, Dashboards, Reporting

**8A — Documents, attachments, storage**
- Specs: `docs/architecture/documents.md`, `docs/functional/documents.md`, `docs/manual/documents.md`.
- Backend: `backend/routers/documents.py`, `backend/models/document.py`, `backend/core/storage.py`, document tests.
- Frontend: document upload/attachment surfaces.
- Lens: target entity validation, tenant ownership, storage cleanup, audit, content-type/size controls.
- Output: `01-domain/08a-documents-attachments-storage.md`.

**8B — Company profile, entities, controls**
- Specs: company docs and system overview.
- Backend: company routers/models, entity controls, company profile tests.
- Frontend: `CompanyProfile.tsx`, `frontend/src/pages/company/*`.
- Lens: entity creation/control, SSO credential validation, company truth used by finance workflows.
- Output: `01-domain/08b-company-profile-entities-controls.md`.

**8C — Dashboards, reports, schedules**
- Specs: finance/accounting/company docs.
- Backend: dashboards, report schedules, KPI/calculation helpers.
- Frontend: `Dashboard.tsx`, `Finance.tsx`, reporting pages.
- Lens: dashboard failure states, scheduled report scoping, stale data labeling, executive finance truth.
- Output: `01-domain/08c-dashboard-reporting-schedules.md`.

### PHASE 9 — Platform Runtime and Cross-Cutting Infrastructure

**9A — SSO OAuth and directory sync**
- Specs: authentication, company, integration docs.
- Backend: SSO client, directory sync core, SSO integration router, shadow models/tests.
- Frontend: login/admin/company surfaces.
- Lens: SSO provider dependency failure, directory reconciliation, service credential validation, webhook authenticity.
- Output: `01-domain/09a-sso-oauth-directory-sync.md`.

**9B — Runtime, scheduler, readiness**
- Specs: `docs/architecture/scheduler.md`, system overview, launch scorecard.
- Backend: `backend/main.py`, `backend/core/scheduler.py`, `backend/core/platform_runtime.py`, config, migration checks, scheduler tests.
- Lens: `/live` vs `/health` vs `/ready`, strict launch mode, scheduler exclusivity, migration freshness, dependency preflight.
- Output: `01-domain/09b-platform-runtime-scheduler-readiness.md`.

**9C — Security utilities, rate limits, secrets**
- Specs: authentication/RBAC/system docs.
- Backend: credential vault, config, rate limiting, audit, encryption, sensitive integrations.
- Lens: secret storage, PII in logs/errors, rate limits, audit chain, replay protection, SSRF/open redirect where applicable.
- Output: `01-domain/09c-security-rate-limits-secrets.md`.

### PHASE 10 — Cross-Cutting Security

Subagents read domain reports first, then targeted code.

**10A — Auth boundaries and access control:** public routes, mutating endpoint guards, JWT/cookie/CSRF/session behavior, admin access, machine-auth endpoints. Output `02-cross-cutting/10a-security-auth-boundaries.md`.

**10B — Data protection:** secrets, PII, SQL injection, XSS, open redirect, webhook signatures, file/document handling, payment data handling, log safety. Output `02-cross-cutting/10b-security-data-protection.md`.

**10C — Tenant and entity isolation:** all `tenant_id` and entity-scoped queries, RLS/session variables, cross-product tenant mapping, customer-facing/self-serve scope, scheduled jobs. Output `02-cross-cutting/10c-security-tenant-entity-isolation.md`.

### PHASE 11 — Cross-Cutting Refactor and Tests

**11A — Backend code quality:** oversized modules, duplication, helper boundaries, error-handling consistency, SQLAlchemy/Pydantic patterns, audit helper use, idempotency helpers. Output `02-cross-cutting/11a-refactor-backend.md`.

**11B — Frontend code quality:** oversized pages, component reuse, i18n, `parseApiError`, permission checks, modal patterns, foreign-key selects, loading/error states, route organization. Output `02-cross-cutting/11b-refactor-frontend.md`.

**11C — Test coverage:** coverage across financial success/failure paths, tenant negatives, RBAC negatives, entity scope, webhook signature failures, scheduler/readiness, frontend E2E. Output `02-cross-cutting/11c-test-coverage.md`.

### PHASE 12 — UX and Automation

**12A — Finance operator journeys:** lead/customer -> contract -> subscription -> invoice -> payment -> revenue -> GL -> bank recon -> close -> report -> tax obligation. Count manual steps and dead ends. Output `02-cross-cutting/12a-ux-finance-operator-journeys.md`.

**12B — Customer, vendor, and external-party journeys:** self-serve payment link, customer billing portal, vendor creation, AP bill, expense approval, communications reply, document exchange. Output `02-cross-cutting/12b-ux-customer-vendor-journeys.md`.

**12C — Admin overhead, config simplicity, automation gaps:** scan all reports for manual work and rank by tenant impact x frequency x financial risk. Pay special attention to setup defaults, product-contract handoff, payment-provider setup, ETL/connection repair, bank matching, close automation, tax filing readiness, dunning, report scheduling, and entity setup. Output `02-cross-cutting/12c-automation-gaps.md`.

### PHASE 12.5 — Competitor Capability Snapshot

Run one web-research subagent using current web search/fetch. The market changes constantly, so do not rely on model memory.

Research: Sage Intacct, NetSuite, QuickBooks Online Advanced, Xero, FreshBooks, Wave, Stripe Billing, Chargebee, Maxio, Recurly, Ramp, Brex, Bill.com, Mercury, Plaid, Puzzle, Pilot, Bench alternatives where relevant, and current finance automation/accounting AI entrants. Prefer official vendor docs/pricing pages and recent release notes. Capture URL and retrieval date for every claim.

For each vendor, table: target ICP, core capabilities, automation depth, accounting/GL depth, billing/subscription depth, bank/reconciliation depth, tax/AP/expense depth, integrations, pricing if public, notable 2025-2026 shifts, confidence.

Output: `02-cross-cutting/12_5-competitor-snapshot.md`.

### PHASE 13 — Synthesis

The orchestrator reads only structured report sections and registers, not full domain reports.

1. Build `04-gap-register.md`: all gaps, sorted by severity then domain.
2. Build `05-security-register.md`: all security findings plus phase 10, deduped and severity sorted.
3. Build `06-refactor-register.md`: all refactor findings, sorted by ROI and risk.
4. Build `07-market-positioning.md`: grounded in `12_5-competitor-snapshot.md` and audit registers. Compare the product honestly against Sage Intacct, NetSuite, QuickBooks Online Advanced, Xero, Stripe Billing, Chargebee, Maxio, Recurly, Ramp, Brex, Bill.com, Mercury/Plaid-style workflows, and newer automation/accounting AI products. Separate where the product wins, ties, and loses.
5. Build `08-launch-readiness.md`: go/no-go, P0 blockers, P1 GA blockers, soft-launch boundaries, first-customer/internal-use verdict, production-deploy prerequisites, and rough effort to clear blockers.
6. Build `09-executive-summary.md`: two pages max, for CEO/board. Sections: What the product is, where it stands, top risks, top strengths, recommendation, why.

### Final Orchestrator Action

Append a final entry to `00-orchestrator-plan.md` with total dispatches, total artifacts, paths to the four most important deliverables, and cross-cutting concerns that do not fit a single register. Then stop. Do not begin remediation.

---

### Subagent Dispatch Pattern

Use this pattern for each domain subagent:

> You are auditing the **<DOMAIN>** subsystem of YourProduct at `{repo}/` for launch readiness. YourProduct is a mid-market financial automation platform spanning CRM, billing, accounting, tax, bank, documents, expenses, communications, identity, and product integrations. Audit against financial integrity, automation-first workflows, tenant/entity isolation, auditability, recoverability, market competitiveness, and the repo specs.
>
> **Working-set discipline:** keep context under 120k tokens. For files over 1500 LOC, run `mcp__lattice__get_skeleton` first, then targeted reads. Use `mcp__lattice__get_context_capsule`, `mcp__lattice__get_docs_capsule`, and `mcp__lattice__find_relevant_tests` rather than broad reads where practical.
>
> **Specs to read:** <list>
> **Backend code in scope:** <list>
> **Frontend code in scope:** <list>
> **Tests in scope:** <list>
>
> **Audit lens for this domain:** <copy the phase lens>
>
> **Universal lenses:** financial integrity; tenant/entity isolation; RBAC; audit trail; failure handling; dependency recovery; idempotency; pagination/search/scale; operator burden; automation opportunities; documentation truthfulness.
>
> **Deliverables:** write the report to the assigned path using the template; append `NEEDS-REVIEW` spec blocks only for code-not-in-spec; return only the summary template. Do not edit code. Do not run tests. Do not start a dev server.

Begin with PHASE 0 now.

---

## End of audit prompt
