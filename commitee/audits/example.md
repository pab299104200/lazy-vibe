# YourProduct — Launch-Readiness Audit Prompt (Example)

> **This is a worked example. Copy it to a new file under `audits/`, replace every placeholder with your product's actual mission, architecture, and competitive context, and expand the phase list to cover your own domains.**

**Purpose:** Single self-contained prompt to run a full code-vs-spec, security, refactoring, workflow, and market-positioning audit using one orchestrator plus parallel subagents per phase. Each subagent's working set is capped by tightly scoping its domain.

**How to use:** Pass this file to `agent_loop.py` via `--instruction-file audits/your-product.md --task-type audit`. Use the strongest available model. Do not edit code or read large files in the orchestrator session itself; the orchestrator dispatches subagents, records summaries, and synthesizes the disk artifacts.

---

## AUDIT PROMPT

You are the **orchestrator** of a launch-readiness audit of the codebase at `{repo}`.

> **Replace this paragraph.** Describe what YourProduct is, who it is for, what it is not, and what its competitive context is. Be specific — the more precisely you define the product bar, the fewer inferences subagents need to make.

Example: *YourProduct is a [category] platform for [ICP]. It is not [common mischaracterisation]. Its competitive context includes [Competitor A, Competitor B, Competitor C].*

**Mission positioning to audit against:**

> **Replace these bullets.** Each bullet should be an explicit product promise that has a code-level implication. Vague mission statements produce vague findings. Concrete promises produce concrete gaps.

- [Core promise 1 — e.g. "All [entity] state changes must be auditable with actor, before, and after state."]
- [Core promise 2 — e.g. "No [workflow] should require manual operator intervention once configured."]
- [Core promise 3 — e.g. "Tenant data must never be accessible across account boundaries."]
- [Add as many as apply to your product's real commitments.]

Your job: orchestrate a code-vs-spec, security, refactoring, workflow, and launch-readiness audit using parallel subagents. You dispatch; you do not read code yourself except at synthesis time from short reports and consolidated registers. All findings get written to disk by subagents.

### Operating Rules

1. **Spec is master.** When code does not implement spec, that is a code gap. When code implements behavior not in spec, that is a spec gap. Document both directions.
2. **Evidence-based only.** Every finding must cite `file:line` for code and `path#heading` for docs/specs. No vibes.
3. **Findings to disk.** Each subagent writes its own file. The orchestrator keeps only short summaries in context.
4. **Cap each subagent.** Keep each subagent under roughly 120k tokens. For files over 1500 lines, use skeleton tools first, then targeted reads.
5. **No remediation during audit.** Subagents document findings; they do not edit code. Spec additions for code-not-in-spec are allowed only as append-only `NEEDS-REVIEW` blocks.
6. **Track operator burden as first-class.** Manual setup, repeated entry, exports/imports, "operator must remember" workflows, and missing defaults are findings. Grade by frequency, user impact, and risk.
7. **Run phases in parallel where possible.**

### Output Layout

Create at session start:

```text
docs/audit/<date>-launch-readiness/
├── 00-orchestrator-plan.md
├── 01-domain/
│   ├── 01-auth-rbac-tenancy.md
│   ├── 02-[your-core-domain-a].md
│   ├── 03-[your-core-domain-b].md
│   └── [add phases for every major subsystem]
├── 02-cross-cutting/
│   ├── 10-security.md
│   ├── 11-refactor-tests.md
│   ├── 12-ux-operator-journeys.md
│   └── 13-competitor-snapshot.md
├── 03-spec-additions/
├── 04-gap-register.md
├── 05-security-register.md
├── 06-refactor-register.md
├── 07-market-positioning.md
├── 08-launch-readiness.md
└── 09-executive-summary.md
```

### Severity Scale

- **P0** — blocks launch: cross-tenant leak, broken auth boundary, data integrity failure, broken core workflow, destructive data loss, audit-trail gap on control-sensitive action.
- **P1** — must fix before GA: spec gap on advertised feature, missing failure handling on critical journey, broken UX on critical operator flow, missing audit on meaningful state change, hidden dependency failure.
- **P2** — should fix before GA: maintainability issue, missing edge-case test, workflow friction, incomplete automation, pagination/search scale risk.
- **P3** — post-launch acceptable: enhancement, polish, low-frequency improvement.

### Per-Domain Report Template

```markdown
# <Domain Name> — Audit Report

**Subagent:** <id>  **Date:** <date>
**Specs reviewed:**
- docs/architecture/<file>.md (sections used)
- docs/functional/<file>.md (sections used)

**Code surveyed:**
- [list files actually read]

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

## 5. Integrity findings
### INT-01 — <title> [P0/P1/P2/P3]
- source of truth affected, misstatement risk, recovery path, fix.

## 6. Refactor opportunities
### REF-01 — <title> [P2/P3, ROI: H/M/L]
- file:line, rationale, scope estimate.

## 7. Test coverage assessment
- What is tested, what is not, missing tenant negatives, missing RBAC negatives.

## 8. Operator burden / automation gaps
- Manual work, repeated entry, avoidable config, missing defaults.

## 9. Dependency, observability, and recovery
- External dependencies, failure states, retries/idempotency, operator recovery path.

## 10. Domain verdict
- **Launch readiness for this domain:** Ready / Needs work / Blocked
- **Top 3 must-fix items before launch.**
```

### Subagent Return Summary Template

```text
DOMAIN: <name>
REPORT: docs/audit/<date>-launch-readiness/01-domain/<file>.md
COUNTS: gaps P0=N P1=N P2=N P3=N | security P0=N P1=N P2=N | integrity P0=N P1=N | refactor P2=N P3=N
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
4. Inventory your docs directories, backend routers/models/core/tests, and frontend pages/components.
5. Update the plan file with discovered inventories.

### PHASE 1 — Identity, RBAC, and Tenancy (Example — adapt for your product)

**1A — Authentication and session lifecycle**
- Specs: `docs/architecture/authentication.md`, `docs/functional/authentication.md`.
- Backend: auth router, auth core, session/token models, auth tests.
- Lens: login flow, session expiry, token rotation, logout revocation, failed auth error messages, CSRF handling.
- Output: `01-domain/01-auth-rbac-tenancy.md`.

**1B — RBAC and permissions**
- Specs: `docs/architecture/rbac.md`, `docs/functional/rbac-permissions.md`.
- Backend: RBAC core, permissions, role/grant models and tests.
- Lens: permission catalog parity with spec, default-deny enforcement, mutating endpoint guards, role assignment audit trail.
- Output: appended to `01-domain/01-auth-rbac-tenancy.md`.

**1C — Tenant isolation**
- Specs: system overview, multi-tenancy architecture doc.
- Backend: all models with `account_id` or equivalent tenant key, tenant resolution middleware, RLS configuration.
- Lens: every query scopes tenant; no cross-tenant data reachable; scheduled jobs scope tenant correctly.
- Output: appended to `01-domain/01-auth-rbac-tenancy.md`.

### PHASE 2 — [Your Core Domain A] (Example — replace with your own)

> **Replace this phase** with your product's primary domain. Show the specs, backend files, frontend files, and audit lens for each subagent. Keep each subagent under 120k tokens by scoping tightly.

**2A — [Subagent title]**
- Specs: `docs/architecture/[domain].md`, `docs/functional/[domain].md`.
- Backend: `backend/routers/[domain]/`, `backend/models/[domain].py`, relevant tests.
- Frontend: `frontend/src/pages/[Domain].tsx`, related components.
- Lens: [specific things to look for in this domain — state machines, integrity invariants, automation gaps, etc.]
- Output: `01-domain/02-[domain-a].md`.

> Add 2B, 2C as needed. Add further phases (PHASE 3, PHASE 4, …) for every major subsystem of your product.

### PHASE N-2 — Cross-Cutting Security

Subagents read domain reports first, then targeted code.

**Security — Auth boundaries:** public routes, mutating endpoint guards, session/JWT/cookie/CSRF behavior, machine-auth endpoints. Output `02-cross-cutting/10-security.md`.

**Security — Data protection:** secrets, PII, SQL injection, XSS, open redirect, webhook signatures, file handling, log safety. Appended to `02-cross-cutting/10-security.md`.

**Security — Tenant isolation:** all tenant-scoped queries, RLS/session variables, scheduled jobs, customer-facing scope. Appended to `02-cross-cutting/10-security.md`.

### PHASE N-1 — Refactor, Tests, UX

**Refactor — Backend:** oversized modules, duplication, error-handling consistency, idempotency helpers. Output `02-cross-cutting/11-refactor-tests.md`.

**Refactor — Frontend:** oversized pages, component reuse, loading/error states, permission checks. Appended to `02-cross-cutting/11-refactor-tests.md`.

**Test coverage:** coverage across critical success/failure paths, tenant negatives, RBAC negatives, dependency failure paths. Appended to `02-cross-cutting/11-refactor-tests.md`.

**UX — Operator journeys:** walk the primary operator workflows end-to-end. Count manual steps and dead ends. Output `02-cross-cutting/12-ux-operator-journeys.md`.

**Competitor snapshot:** run one web-research subagent. Research your specified competitors. Prefer official vendor docs and recent release notes. Capture URL and retrieval date for every claim. Output `02-cross-cutting/13-competitor-snapshot.md`.

### PHASE N — Synthesis

The orchestrator reads only structured report sections and registers, not full domain reports.

1. Build `04-gap-register.md`: all gaps, sorted by severity then domain.
2. Build `05-security-register.md`: all security findings, deduped and severity sorted.
3. Build `06-refactor-register.md`: all refactor findings, sorted by ROI and risk.
4. Build `07-market-positioning.md`: grounded in competitor snapshot and audit registers. Compare the product honestly against each competitor. Separate where the product wins, ties, and loses.
5. Build `08-launch-readiness.md`: go/no-go, P0 blockers, P1 GA blockers, soft-launch boundaries, production-deploy prerequisites, rough effort to clear blockers.
6. Build `09-executive-summary.md`: two pages max. Sections: What the product is, where it stands, top risks, top strengths, recommendation.

### Final Orchestrator Action

Append a final entry to `00-orchestrator-plan.md` with total dispatches, total artifacts, paths to the four most important deliverables, and cross-cutting concerns that do not fit a single register. Then stop. Do not begin remediation.

---

### Subagent Dispatch Pattern

Use this pattern for each domain subagent:

> You are auditing the **[DOMAIN]** subsystem of YourProduct at `{repo}/` for launch readiness. YourProduct is [one sentence product description]. Audit against [your core integrity promises], tenant isolation, auditability, recoverability, and the repo specs.
>
> **Working-set discipline:** keep context under 120k tokens. For files over 1500 LOC, read the skeleton first, then targeted sections.
>
> **Specs to read:** [list]
> **Backend code in scope:** [list]
> **Frontend code in scope:** [list]
> **Tests in scope:** [list]
>
> **Audit lens for this domain:** [copy the phase lens]
>
> **Universal lenses:** tenant isolation; RBAC; audit trail; failure handling; dependency recovery; idempotency; pagination/search/scale; operator burden; automation opportunities; documentation truthfulness.
>
> **Deliverables:** write the report to the assigned path using the template; append `NEEDS-REVIEW` spec blocks only for code-not-in-spec; return only the summary template. Do not edit code. Do not run tests. Do not start a dev server.

Begin with PHASE 0 now.

---

## End of audit prompt
