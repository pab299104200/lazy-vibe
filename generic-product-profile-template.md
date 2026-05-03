# Generic Launch-Readiness Product Profile

Fill this out before running the generic launch-readiness audit against a repo.

## Product

- Product name:
- Repo root:
- One-sentence description:
- Target customer/user:
- Launch type: internal / design partner / private beta / public beta / GA
- Primary business promise:

## Launch Claims

List the claims the product must be able to truthfully make at launch.

- Claim 1:
- Claim 2:
- Claim 3:

## Critical User Journeys

List the workflows that must work end to end. Include actor, goal, and expected evidence.

| Journey | Actor | Goal | Evidence required |
| --- | --- | --- | --- |
| | | | |

## Critical Domains

List the product-specific domains to audit. Examples: authentication, billing, imports, device enrollment, projects, reports, AI workflow, integrations, admin console, mobile app.

| Domain | Why it matters | Likely code/docs/tests |
| --- | --- | --- |
| | | |

## Trust Boundaries

- Authentication/session model:
- Authorization/RBAC/roles:
- Tenant/account/project isolation model:
- Sensitive data handled:
- External integrations:
- Payments/financial flows:
- Admin/support access:

## Compliance And Risk

- Regulatory/security expectations:
- Data retention/export/deletion expectations:
- Audit logging expectations:
- Availability/recovery expectations:

## Competitors Or Alternatives

List products the launch will be compared against. The audit can use web research only when current market comparison is in scope.

- Competitor 1:
- Competitor 2:

## Runtime Verification

- Supported backend test commands:
- Supported frontend test commands:
- Supported E2E/browser commands:
- Dev/staging URL and credential source, if any:
- Commands that must not be run:

## Documentation Locations

- Architecture docs:
- Functional/spec docs:
- Manual/operator/customer docs:
- API docs:
- Deployment docs:

## Known Non-Goals

List things that should not be treated as launch blockers.

- Non-goal 1:
