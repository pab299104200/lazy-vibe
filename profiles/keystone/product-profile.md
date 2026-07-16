# Cadres Keystone Launch-Readiness Product Profile

## Product

- Product name: Cadres Keystone
- Repo root: `/home/pete/cadres/keystone`
- One-sentence description: Mid-market financial automation platform connecting CRM, billing, revenue, accounting, banking, expenses, tax, communications, documents, integrations, and company controls into one auditable operating system.
- Target customer/user: Finance operators, controllers, founders, revenue operators, accounting teams, tax/compliance owners, customer success and collections teams, tenant administrators, Cadres platform operators, and downstream Cadres products that depend on Keystone financial state.
- Launch type: design partner / private beta until launch-readiness evidence proves restricted or broader launch safety.
- Primary business promise: Replace brittle spreadsheet workflows, disconnected billing/accounting tools, manual close processes, and lightweight finance stacks with a tenant-safe, audit-ready, automation-first finance control plane for companies up to roughly `$100M` in revenue.

## Launch Claims

List the claims the product must be able to truthfully make at launch.

- Claim 1: Keystone can operate a mid-market finance workflow end to end, from customer and contract state through billing, invoicing, collections, revenue recognition, accounting, reporting, tax obligations, and close.
- Claim 2: Keystone provides tenant-safe financial administration with explicit RBAC, Portal session integration, RLS-backed request/system database roles, audit trails, approval controls, and no hidden financial or tenant-bypass shortcuts.
- Claim 3: Keystone supports finance-native automation with deterministic policies, lifecycle states, exceptions, notifications, communications capture, payment provider adapters, bank feeds, ETL imports, and operator-visible recovery paths.
- Claim 4: Keystone can exchange product, billing, entitlement, and evidence state with Cadres RMM and Portal through documented contracts without stale local copies or ambiguous authority.
- Claim 5: Keystone launch readiness can be proven through repo-supported backend, frontend, browser, migration, Postgres/RLS, integration-contract, and financial-control checks plus realistic operator-journey evidence.
- Claim 6: Keystone documentation in `docs/architecture`, `docs/functional`, and `docs/manual` truthfully describes implemented behavior, operator procedures, failure handling, launch limitations, and known unsupported integration states.

## Critical User Journeys

List the workflows that must work end to end. Include actor, goal, and expected evidence.

| Journey | Actor | Goal | Evidence required |
| --- | --- | --- | --- |
| Keystone purchase, isolated workspace provisioning, and admin bootstrap | Cadres operator then customer tenant admin | Sell the Cadres-owned \`keystone\` product from the commercial-control tenant, bind the resulting Portal tenant as a downstream customer account, provision an isolated customer-owned Keystone workspace, then sign in through Portal and reach a usable finance dashboard without membership in the Cadres control tenant | Sold-contract and binding tests, Portal provisioning evidence, first-admin tests, browser proof, control-tenant/customer-tenant negatives, audit records, docs |
| Company and entity setup | Controller or finance admin | Configure company profile, legal entities, fiscal settings, ownership, tax registrations, and dashboard scope | Backend tests, UI workflow tests, RLS/account-scope negatives, manual docs, audit trail |
| CRM to contract to billing | Revenue operator | Manage customers, contacts, opportunities, contracts, product capability contracts, pricing, and billing setup without double entry | CRM/billing API tests, frontend workflow tests, product contract tests, browser proof, docs |
| Invoice and payment lifecycle | Billing specialist | Create invoices, send/track them, record payments, process credits/refunds, handle hosted payment providers, and keep GL/customer state consistent | Invoice/payment tests, payment-provider adapter tests, UI proof, webhook/failure evidence, audit records |
| AR, dunning, and communications | Collections operator | Monitor aging, run dunning workflows, use communications templates/channels, capture replies, escalate exceptions, and preserve customer context | AR/dunning/comms tests, browser proof, retry/failure evidence, retention docs, audit trail |
| AP, vendors, purchase orders, goods receipts, and three-way match | AP operator | Manage vendors, purchase orders, receipts, bills, approvals, match exceptions, and payment readiness | Backend tests, UI tests, conflict/failure evidence, approval audit logs, manual docs |
| Bank feeds and reconciliation | Finance operator | Connect/import bank data, match transactions, reconcile accounts, export drill-downs, and recover from provider/import failures | Bank provider/matching tests, tenant-scope tests, UI proof, retry/failure evidence, docs |
| General ledger and journal controls | Controller | Maintain chart of accounts, journal entries, fixed assets, allocations, account deactivation controls, override approvals, and auditability | GL/accounting tests, SoD/permission negatives, migration evidence, browser proof, docs |
| Revenue recognition and billing obligations | Controller | Manage performance obligations, deferred revenue, contract changes, tax implications, and recognition schedules | Revenue allocation tests, GAAP-focused tests, UI proof, deterministic schedules, docs |
| Month-end and year-end close | Controller | Run close cycles, approvals, accruals, remediation, fiscal periods, trial balance, statements, and annual packages | Close engine tests, approval negative tests, browser proof, package/report artifacts, docs |
| Financial reporting and dashboards | CFO or finance operator | Review cash position, P&L, balance sheet, cash flow, AR/AP aging, budgets, forecasts, and risk/health indicators | Report tests, frontend tests, browser evidence, accuracy fixtures, docs |
| Tax and compliance obligations | Tax owner | Maintain tax brackets, sales tax, quarterly tax, filing readiness, remittance automation, LLC/member state, and compliance calendar | Tax engine tests, remittance tests, UI proof, jurisdiction/failure evidence, docs |
| Expenses and spend controls | Finance operator or employee | Submit, categorize, approve, budget-check, reimburse, and audit expenses with policy exceptions | Expense policy tests, exception-control tests, UI proof, permission negatives, docs |
| Document and evidence management | Finance operator or auditor | Upload, classify, bind, retain, and retrieve invoices, statements, contracts, reports, and supporting documents safely | Document CRUD/launch-readiness tests, storage/hash evidence, tenant negatives, manual docs |
| ETL and external imports | Integration owner | Configure CSV/OFX/Mercury/import pipelines, mapping rules, matching rules, sync history, webhooks, and recover failed transforms | ETL engine/state-machine tests, scale tests, UI proof, retry/failure evidence, docs |
| RMM product integration | Cadres operator or product admin | Configure product contracts, return URL allowlists, entitlements, lifecycle state, and data exchange with Cadres RMM | Product integration E2E tests, contract tests, RMM integration docs, browser proof, audit logs |
| Launch-readiness runtime audit | Release operator | Run the prompt pack, collect artifacts, classify findings, and reach a defensible launch/no-go decision | Shared launch-readiness prompt output, backend/frontend/browser artifacts, final decision doc |

## Critical Domains

List the product-specific domains to audit. Examples: authentication, billing, imports, device enrollment, projects, reports, AI workflow, integrations, admin console, mobile app.

| Domain | Why it matters | Likely code/docs/tests |
| --- | --- | --- |
| Portal authentication, sessions, and first-user access | Portal is Keystone's identity authority and first-run access must fail closed without locking out legitimate admins | `backend/core/auth.py`, `backend/routers/auth.py`, `frontend/src/pages/Login.tsx`, `frontend/src/pages/AuthCallback.tsx`, `docs/architecture/authentication.md`, auth/session tests |
| RBAC, permissions, admin access, and SoD | Financial actions require explicit permission gates and separation-of-duties controls | `backend/core/permissions.py`, `backend/core/rbac.py`, `backend/core/separation_of_duties.py`, `backend/routers/admin_access.py`, `docs/architecture/rbac.md`, `docs/functional/rbac-permissions.md`, RBAC/admin tests |
| Tenant isolation, RLS, and request/system DB roles | Financial records are tenant-owned; UI filtering is not a safety boundary | `backend/db/database.py`, `backend/scripts/rls_role_setup.sql`, tenant-scoped models/routers, `docs/README.md` local DB section, RLS/tenant-negative tests |
| Company, entity, and dashboard scope | Company/entity state drives tax, accounting, reporting, and consolidated views | `backend/core/company_profile.py`, `backend/models/company.py`, `frontend/src/pages/CompanyProfile.tsx`, company docs/tests |
| CRM and customer workspace | Customer truth connects sales pipeline, contracts, billing, communications, and risk | `backend/models/crm.py`, `backend/core/crm_stage_automation.py`, `frontend/src/pages/CRM.tsx`, CRM components/services, CRM docs/tests |
| Product contracts, lifecycle, entitlements, and RMM integration | Keystone coordinates first-party product billing and capability contracts | `backend/core/product_contracts.py`, `backend/core/product_lifecycle.py`, `backend/core/integration_events.py`, product integration pages, `docs/functional/rmm-integration.md`, integration tests |
| Billing, subscriptions, invoices, credits, refunds, and payment providers | Revenue collection must stay consistent across customers, contracts, GL, providers, and communications | `backend/core/finance_invoicing.py`, `backend/core/finance_subscriptions.py`, `backend/core/hosted_payment_providers.py`, `backend/core/stripe_provider_adapter*.py`, billing pages/docs/tests |
| AR/AP, vendors, purchase orders, receipts, and matching | Payables and receivables workflows need approval controls, reconciliation, and exception handling | accounting/vendor models/routers, AP/PO/receipt pages, `docs/architecture/accounting.md`, `docs/functional/vendors.md`, accounting/AP tests |
| Bank feeds, matching, and reconciliation | Bank truth validates cash, payments, GL activity, and fraud/error detection | `backend/core/bank_matching.py`, `backend/core/plaid_client.py`, bank routers/pages, `docs/architecture/bank.md`, bank tests |
| General ledger, fixed assets, statements, consolidation, and close | Keystone's finance promise depends on accurate books, close controls, and reportable statements | `backend/core/gl_engine.py`, `backend/core/consolidation_engine.py`, `backend/core/close_engine.py`, accounting/statement pages, accounting/close/consolidation docs/tests |
| Revenue recognition and obligations | Deferred revenue and performance obligations are control-sensitive, not simple billing fields | `backend/core/revenue_allocation.py`, obligation/revenue pages, `docs/functional/billing.md`, GAAP and deferred-revenue tests |
| Tax, sales tax, filing readiness, and obligations | Tax workflows need jurisdictional correctness, deadlines, and auditable remittance decisions | `backend/core/sales_tax_engine.py`, `backend/core/quarterly_tax.py`, `backend/core/tax_guards.py`, tax pages/docs/tests |
| Expenses and spend policy | Expense approvals, categories, budgets, and exceptions affect cash, GL, and controls | `backend/core/expense_policy_engine.py`, expense models/pages, `docs/architecture/expenses.md`, expense tests |
| Communications and notifications | Finance automation depends on customer/vendor communications, templates, retention, delivery health, and escalation | `backend/core/notification_manager.py`, comms models/components/pages, `docs/architecture/communications.md`, comms tests |
| Documents, storage, and audit evidence | Financial artifacts must remain tenant-safe, retrievable, and traceable | `backend/core/storage.py`, `backend/routers/documents.py`, `frontend/src/pages/Documents` where present, document docs/tests |
| ETL, integrations, sync history, and webhooks | Imports and external syncs must be idempotent, recoverable, and tenant-scoped | `backend/models/etl.py`, ETL services/pages, `docs/architecture/etl-engine.md`, ETL tests |
| Scheduler, daily digest, obligations, and async loops | Automation quality depends on deterministic scheduling, replay safety, and visible failures | `backend/core/scheduler.py`, `backend/core/daily_digest.py`, `backend/core/obligation_engine.py`, scheduler docs/tests |
| Runtime, migrations, quality gates, and production config | Launch blockers often surface under real startup, Alembic, Postgres, and standards gates | `backend/alembic`, `backend/core/platform_runtime.py`, `scripts/backend-venv`, `scripts/dev-postgres`, migration/config tests |
| Frontend operator UX, accessibility, i18n, and route completeness | Finance operators need complete, recoverable workflows rather than backend-only capability | `frontend/src/pages`, `frontend/src/components`, `frontend/src/services`, locale files, Playwright config, screenshots/docs/ux evidence |

## Trust Boundaries

- Authentication/session model: Keystone delegates identity to Cadres Portal, handles login/callback/session replacement through backend auth routes, maps Portal user and tenant context into Keystone requests, and must reject unauthenticated or ambiguous tenant requests.
- Authorization/RBAC/roles: Default deny. Backend endpoints enforce explicit Keystone permissions and separation-of-duties controls for financial, approval, admin, product-contract, and integration actions. Frontend gates are advisory only.
- Tenant/account/project isolation model: Tenant-owned rows must be scoped by account/tenant context at backend and database layers. Local development uses distinct request and system PostgreSQL roles (`keystone_app` and `keystone_system`) to exercise the intended trust boundary.
- Sensitive data handled: Customer and vendor records, contracts, invoices, bills, payment and provider metadata, bank-feed data, accounting ledgers, tax records, documents, communications, OAuth/provider credentials, product contract state, audit logs, and financial reports.
- External integrations: Cadres Portal, Cadres RMM, payment providers such as Stripe where enabled, hosted payment provider adapters, Plaid/bank providers, Mercury/CSV/OFX imports, email/SMS/WhatsApp/IMAP/SMTP/Twilio/Telnyx/Signal/webhook communications plugins, and API/webhook clients.
- Payments/financial flows: Payment provider configuration, hosted payment provider adapter state, invoice payment recording, credits, refunds, subscriptions, dunning, bank reconciliation, GL postings, deferred revenue, and tax remittance are control-sensitive even when no live payment provider is used.
- Admin/support access: Tenant admins, finance admins, controllers, operators, Cadres platform admins, and system actors must have scoped, attributable access. No hidden bypasses around tenant scoping, financial approvals, SoD, auditability, provider secrets, or document access.

## Compliance And Risk

- Regulatory/security expectations: Tenant isolation, least privilege, auditability, financial control evidence, separation of duties, secure session handling, provider secret protection, truthful accounting/tax behavior, and SOC2-style operational evidence.
- Data retention/export/deletion expectations: Invoices, bills, GL entries, bank records, tax artifacts, documents, audit records, communications retention artifacts, reports, close packages, and integration sync artifacts require durable provenance and carefully controlled deletion/archive semantics.
- Audit logging expectations: Meaningful state-changing actions require actor, tenant/account, target, action, timestamp, outcome, and relevant before/after or context. Financial approvals, provider configuration, role changes, product contracts, document changes, close transitions, and integration events are audit-sensitive.
- Availability/recovery expectations: Alembic migrations must be safe; startup must fail closed without required secrets; schedulers, payment webhooks, bank syncs, ETL jobs, communications delivery, dunning, close workflows, and report generation must be idempotent, retryable, and operator-diagnosable.

## Competitors Or Alternatives

List products the launch will be compared against. The audit can use web research only when current market comparison is in scope.

- QuickBooks Online
- Xero
- NetSuite
- Sage Intacct
- Microsoft Dynamics 365 Business Central
- Oracle Fusion Cloud ERP
- Stripe Billing
- Chargebee
- Zuora
- Maxio
- Bill.com
- Ramp
- Brex
- Plaid-backed bank feed workflows
- Manual spreadsheet-based close and tax workflows

## Runtime Verification

- Supported backend test commands:
  - `./scripts/backend-venv`
  - Local execution is limited to database-independent unit/static checks. Do not bootstrap, create, or troubleshoot a local PostgreSQL service for Keystone audit or remediation work.
  - `scripts/deploy-runtime dev` deploys the candidate revision to the authoritative dev VPS before database-backed, migration, integration, RLS, or browser verification.
  - Run focused and full database-backed pytest commands through the repository's dev-VPS verification path after deployment; do not substitute an ephemeral local database when VPS access fails.
  - `ruff check .`
  - `ruff format --check .`
  - Run Alembic, PostgreSQL, and RLS proof against the configured dev-VPS environment only. A missing or unavailable VPS dependency is a truthful blocked verification result, not permission to create a local replacement.
- Supported frontend test commands:
  - `cd frontend && npm run build`
  - `cd frontend && npm run lint`
  - `cd frontend && npm run dev` for local browser proof
- Supported E2E/browser commands:
  - `cd frontend && npx playwright test` when node dependencies and browser fixtures are available
  - Repo-supported Playwright configs under `frontend/playwright.config.ts` and `frontend/playwright.verify.config.ts`
  - Browser proofs against the dev VPS when `docs/ux/.creds` is present
  - Keystone launch-readiness prompt pack under `docs/audit/launch-readiness-prompts/*` when using the repo-local audit runner
  - Shared generic launch-readiness prompt pack under `/home/pete/cadres/shared/launch-readiness-prompts/*`
- Dev/staging URL and credential source, if any:
  - The deployed dev VPS is the authoritative Keystone runtime and database verification environment. Local source inspection and database-independent checks are supporting evidence only.
  - `docs/ux/.creds` for dev VPS/browser credentials when present. Redact all secrets from outputs.
- Commands that must not be run:
  - Do not run `./scripts/dev-postgres`, `createdb`, `dropdb`, `pg_ctlcluster`, or an equivalent local PostgreSQL bootstrap as part of Keystone audit or remediation.
  - Do not run destructive database reset/drop commands against shared, staging, production, or unclear databases.
  - Do not print secrets, raw tokens, private keys, OAuth/provider credentials, payment provider secrets, bank credentials, webhook secrets, invoice/payment artifacts containing sensitive data, or credentials from `docs/ux/.creds`.
  - Do not use live payment providers, live bank feeds, live customer email/SMS/WhatsApp channels, or production product entitlements unless the audit job explicitly scopes that environment and redaction requirements.

## Documentation Locations

- Architecture docs: `docs/architecture/*.md`
- Functional/spec docs: `docs/functional/*.md`
- Manual/operator/customer docs: `docs/manual/*.md`
- API docs: Backend route/schema definitions where present; public/operator behavior is also documented in architecture, functional, and manual files.
- Deployment docs: `docs/README.md`, `docs/manual/getting-started.md`, `backend/alembic.ini`, `scripts/backend-venv`, `scripts/dev-postgres`, and runtime artifacts under `docs/audit/*/artifacts` where present.
- Launch-readiness prompt pack: `/home/pete/cadres/shared/launch-readiness-prompts/*`; Keystone also has repo-local launch-readiness prompts under `docs/audit/launch-readiness-prompts/*`.
- Shared standards:
  - UI specification: `/home/pete/cadres/shared/templates/ui-specification.md`
  - Coding standard: `/home/pete/cadres/shared/templates/coding.md`

## Known Non-Goals

List things that should not be treated as launch blockers.

- Broad public GA is not assumed. The audit may recommend design-partner launch, private beta, no-go, or narrower launch based on evidence.
- Missing live external-customer evidence is not automatically an implementation failure in implementation-scope verification, but it remains launch evidence pending.
- Sandbox-blocked Postgres, browser, VPS, payment-provider, bank-feed, or external integration checks should be classified honestly as blocked/pending unless the environment is available.
- Competitor parity claims must be narrowed if behavior is not implemented, documented, and verified; the audit should not invent launch claims to match NetSuite, Intacct, QuickBooks, Xero, Stripe Billing, Chargebee, Zuora, Bill.com, Ramp, or Brex.
- Live payment processing, live bank transactions, production email/SMS/WhatsApp sends, and production tax filing/remittance should not be required unless explicitly scoped to a controlled launch environment.
- Cosmetic UI polish that does not affect workflow correctness, accessibility, trust, evidence, security, or operator productivity is lower priority than tenant safety, financial integrity, recovery, auditability, and customer-operable workflows.
