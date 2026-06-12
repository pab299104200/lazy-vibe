# lazy-vibe

Agent-driven launch-readiness audit, remediation, and feature-build toolkit. `run-audit.sh`, `run-remediation.sh`, and `run-feature-build.sh` orchestrate multi-agent sessions that audit a codebase for launch readiness, catalogue and fix findings, and build approved feature specs through a task-isolated harness.

Supports Codex CLI, Claude CLI, and Gemini CLI as agent backends. Profiles let you drop in product-specific job lists and prompts without modifying the scripts.

---

## Directory layout

```
lazy-vibe/
├── run-audit.sh                        # audit orchestrator
├── run-remediation.sh                  # remediation orchestrator
├── run-feature-build.sh                # one-shot feature build orchestrator
├── run-keystone-accounting-audit.sh     # fixed-domain GAAP/IFRS audit harness
├── run-rmm-ops-automation-audit.sh      # fixed-domain RMM automation-chain audit harness
├── claude_pty_runner.py                 # interactive Claude PTY transport used when claude -p is not viable
├── lazy_vibe/                          # Python workflow engines used by the shell entrypoints
│   ├── audit/
│   │   └── summary.py                  # audit summary helpers used by launch-readiness runs
│   └── feature_build/
│       ├── __main__.py                 # python -m lazy_vibe.feature_build entrypoint
│       └── runner.py                   # feature-build planner/implementer/verifier engine
├── commitee/                           # experimental committee-style multi-agent harness
│   ├── agent_loop.py
│   ├── config.json
│   ├── prompts/
│   └── schemas/
├── generic-shared.md                   # shared rules injected into every audit job
├── generic-jobs.tsv                    # default job manifest (used when no profile sets one)
├── generic-launch-readiness-audit-prompt.md
├── generic-product-profile-template.md
├── tests/
│   ├── run-audit-summary-fixtures.sh   # audit summary/remediation-context regression fixtures
│   ├── run-feature-build-fixtures.sh   # feature-build result-quality regression fixtures
│   └── run-remediation-fixtures.sh     # remediation queue/summary regression fixtures
└── profiles/
    └── <your-product>/
        ├── jobs.tsv          # optional — overrides generic-jobs.tsv
        ├── product-profile.md
        └── shared.md         # optional — overrides generic-shared.md
```

---

## Harness Architecture

`lazy-vibe` is a deterministic harness around agent CLIs, not a prompt collection. The shell entrypoints own job ordering, state files, checkpoints, worktree behavior, retries, native command execution, evidence collection, and final summaries. Agents receive bounded prompts and return artifacts; they do not decide the global control flow.

The major harnesses are:

| Harness | Entry point | Engine | Purpose |
|---|---|---|---|
| Launch-readiness audit | `run-audit.sh` | shell + native probes | Runs discovery, runtime, browser, adversarial, and final-decision jobs against a product profile. |
| Remediation | `run-remediation.sh` | shell state machine | Converts audit findings into blocker-ledger packets, plans implementation units, runs implementers/verifiers, drains safe queue actions, and writes summary/queue artifacts. |
| Feature build | `run-feature-build.sh` | `lazy_vibe/feature_build/runner.py` | Decomposes an approved feature spec into tasks, creates a feature branch, runs task-scoped agents, verifies declared commands, commits by default, and optionally pushes/deploys. |
| Fixed-domain audits | `run-keystone-accounting-audit.sh`, `run-rmm-ops-automation-audit.sh` | shell wrappers | Run one specialized prompt for a narrow domain when the full launch-readiness pipeline is too broad. |
| Committee loop | `commitee/agent_loop.py` | Python prototype | Experimental multi-agent deliberation harness using prompts and JSON schemas under `commitee/`. |

The harness layer is responsible for deterministic behavior:

- It snapshots long-running scripts before execution so edits to the source file do not corrupt an active run.
- It writes and resumes checkpoints instead of trusting terminal output.
- It generates native evidence before asking agents to interpret it.
- It filters verifier-declared evidence commands and skips prose instead of executing arbitrary text.
- It treats transport failures, shell syntax failures, API errors, missing helper functions, and malformed artifacts as harness failures rather than successful verifier decisions.
- It uses Lattice MCP context automatically for Codex and Claude when `LATTICE_MCP_AUTO=1`.
- It supports Claude in either normal prompt mode or PTY mode through `CLAUDE_TRANSPORT=prompt|pty`.

Agent selection is pluggable per phase. Codex, Claude, Gemini, and runner-backed paths can be mixed through environment variables such as `RUNNER`, `IMPLEMENTER_AGENT`, `REVIEWER_AGENT`, `FEATURE_BUILD_IMPLEMENTER_AGENT`, and `FEATURE_BUILD_REVIEWER_AGENT`.

## How it works

The audit runs 10 sequential groups. Within each group, jobs execute in parallel (up to `MAX_PARALLEL`). Each job gets its own bounded agent session and writes a report to `RUN_DIR`.

| Group | Jobs | What it does |
|---|---|---|
| **00** | `00-bootstrap` | Inventories the repo, reads docs and the product profile, and produces a structured plan that later jobs reference. |
| **01** | `01a` `01b` `01c` | Domain discovery in parallel: product claims and launch contract (1A), architecture, data model, and trust boundaries (1B), user journeys and workflow surfaces (1C). |
| **02** | `02a` `02b` `02c` | Code deep-dive in parallel: backend API and domain logic (2A), frontend/client surface (2B), integrations, async jobs, and external dependencies (2C). |
| **03** | `03a` `03b` `03c` | Cross-cutting synthesis in parallel: security, auth, and data boundaries (3A), observability, recovery, and operations (3B), test coverage, docs accuracy, and maintainability (3C). |
| **04** | `04-market-comparison` | Web research — compares the product against market alternatives using claims from the product profile. |
| **05** | `05-synthesis` | Full launch-readiness synthesis: ranked blockers, launchable subset, and a remediation register. |
| **06** | `06-runtime` | Runs the supported test commands listed in the product profile, plus native SAST/CVE scanning (Bandit, Semgrep, pip-audit, npm audit), native Lighthouse Core Web Vitals, and native external service connectivity probes before the agent analyzes the evidence. |
| **07** | `07-customer-simulation` | Simulates critical customer/operator journeys end-to-end. Runs native axe-core WCAG 2.1 AA accessibility scans and native Lighthouse on configured target URLs before the agent analyzes the evidence. Journeys with no harness are marked `unverified`. |
| **08** | `08-adversarial` | A hostile reviewer attacks the launch claims and tries to find gaps the earlier jobs missed. |
| **09** | `09-final-decision` | Issues the final release decision based on all prior findings. |
| *(dynamic)* | `deep-<parent>-<topic>` | When a discovery or synthesis job hits its budget on a P0/P1 area it could not finish, it logs the boundary to `artifacts/pending-jobs.tsv`. The launcher drains that file after each group and runs follow-up deep-dive jobs automatically, up to `DYNAMIC_DEPTH_CAP` levels deep. |
| *(optional)* | `load-test` | When `LOAD_TEST_ENABLED=1`, the launcher runs a native three-scenario load test (baseline 10 VU / ramp 1→50 VU / spike 100 VU) after all runtime jobs complete and then asks the agent to interpret the captured evidence. |

The remediation phase reads the audit output, extracts findings into packets, and runs an implementer–verifier loop that fixes code, tests, and docs.

Before packet generation, remediation now builds a deterministic blocker ledger:

- `00-raw-px-list.tsv` keeps every raw P0/P1/P2 finding mention extracted from domain, synthesis, runtime, simulation, adversarial, final-decision, logs, and artifact reports.
- `00-blocker-ledger.tsv` and `00-blocker-ledger.md` collapse repeated mentions into root-cause blockers such as `product_gap`, `evidence_gap`, `harness_gap`, `stale_prior_decision`, and `runtime_unavailable`.
- `00-master-px-list.tsv` and packet files are generated from the blocker ledger, not from every repeated module mention.
- Packet files include the blocker ID, category, theme, raw Px IDs, and all source references so implementers fix the root cause once and then rerun the referenced audit jobs for proof.

This is intentionally deterministic. The cataloger may merge or split blocker-ledger rows, but it must preserve the original blocker ID and explain any split with current-code evidence. A broad audit with 40 failed jobs should not automatically become 40 unrelated implementation units when several jobs are repeating the same MSP, browser-evidence, RLS, connector, or stale-baseline defect.

The feature-build phase reads an approved `docs/new-feature/<slug>.md` spec, asks a planner agent to decompose it into machine-readable tasks, creates or switches to `feature/<slug>` by default for execution, executes tasks with isolated prompts, verifies declared exit commands, auto-commits successful verified builds, and can push or deploy when explicitly requested.

Feature-specific UX audit and feature remediation are not separate control planes. UX, accessibility, and browser proof belong in `run-audit.sh`; scorecard and finding remediation belongs in `run-remediation.sh`. Thin feature-scoped wrappers are acceptable, but the audit and remediation scripts own state, retries, model routing, evidence, and final verdicts.

Read-only audit jobs (`discovery`, `synthesis`, `web`, and dynamic `deep-*` jobs) diff against a pre-run repository snapshot. If one of those jobs edits product files, the launcher fails the job. On a clean repo it restores only the unexpected product-file changes; on a dirty repo it preserves the existing user diff and reports the integrity violation without reverting unrelated work.

Runtime, simulation, and load-test jobs now follow the same split everywhere possible:

- The harness executes deterministic checks natively and writes raw artifacts plus summary markdown/JSON under `RUN_DIR/artifacts/...`.
- The agent reads those artifacts as mandatory evidence inputs, correlates them with code/docs/claims, and decides blocker vs warning vs rerun gate.

### Contract, boundary, operations, and maintainability gates

The harness treats "good enough" as working, debuggable, documented, and maintainable without assuming the operator can read code. Audit and remediation prompts now make these checks explicit:

- **API contract docs** are stricter than architecture and functional specs. For high-risk APIs, routes, CLIs, async jobs, webhooks, protocol operations, integrations, generated clients, OpenAPI documents, or schemas, agents must check or update operation-level docs that include request/response shapes, permissions/auth, validation and error cases, pagination/filtering/sorting where relevant, idempotency/retry behavior, lifecycle/state transitions, audit/logging expectations, and examples where useful.
- **Boundary tests** must be permanent source-controlled regression tests when the repo can support them. Audit-only evidence is not enough for high-risk tenant/account/project isolation, RBAC negatives, destructive action authorization, audit-log assertions, idempotency/retry behavior, stale connector/evidence failure behavior, protocol replay, or lifecycle/state-transition negatives.
- **Operational debugging** is audited per serious workflow. A workflow is incomplete when it lacks the concrete logs, audit events, request/correlation IDs, job/status state, retry/error state, operator-visible recovery, or runbook/docs needed to diagnose and recover production failures.
- **Static maintainability gates** are product-profile driven. If a repo supports type checks, complexity checks, dead-code checks, linting, dependency scanning, or SAST/CVE scanning, the harness treats those commands as evidence. Existing debt can be reported as a ratchet, while new or changed code should not introduce fresh hard-to-debug complexity, dead code, or type drift.

Verifier findings have dedicated categories for these gaps: `api_contract`, `boundary_tests`, `operability`, and `static_analysis`. Those categories flow back into the normal targeted-revision queue instead of becoming vague final-review advice.

Harness health is treated the same way. `tests/run-audit-summary-fixtures.sh` verifies that audit summaries preserve source job metadata and classify failures into remediation-usable context such as browser evidence and missing output. `tests/run-feature-build-fixtures.sh` verifies that feature-build tasks cannot close without runnable verification commands and complete result artifacts. `tests/run-remediation-fixtures.sh` builds a temporary remediation ledger and verifies queue classification plus summary behavior for accepted units, evidence-pending units, API contract findings, boundary-test findings, operability findings, static-analysis findings, missing verifiers, stale verifier inputs, split child pending/decomposed states, split parents with blocked child units, postcheck-invalid worktree evidence, failed deterministic evidence, contract conflicts, test-harness blockers, and blocked units.

### What the audit relies on

The audit reads what is already in the repo. The quality of its findings depends on what is there to read.

| Input | Used by | What happens without it |
|---|---|---|
| Architecture, functional, manual, and API contract docs (locations in product profile) | Groups 01–03 | Findings shift from "code diverges from docs" to "docs are missing entirely" — still valid findings, but less actionable |
| Test suite (unit, integration, E2E) | Groups 02–03, 06 | Test coverage gaps are reported; runtime job (06) has nothing to run |
| Supported test commands in product profile | Group 06 | Runtime job is skipped — it will not invent commands |
| Supported type, complexity, dead-code, lint, dependency, and security commands in product profile | Groups 03, 06, remediation verifier | Static maintainability gaps are reported; existing debt can be ratcheted, but changed surfaces still need focused proof |
| Critical journeys in product profile | Group 07 | Simulation job has no journeys to drive; marks all unverified |
| Competitors/alternatives in product profile | Group 04 | Market comparison job is skipped |
| `docs/ux/.creds` + staging URL + E2E command | Groups 06–07 | Browser journeys are marked `unverified`; external-services probe and Lighthouse also depend on the base URL |
| Python/Node.js source files in repo | Group 06 (`SAST_ENABLED=1`) | SAST and CVE scanning reports no findings — not a failure, just nothing to scan |
| `Performance SLOs` in product profile | Load test | Load test uses default thresholds (p95 < 2000ms, p99 < 5000ms, error rate < 1%) |

Groups 01–03 can infer domain structure from code alone, but they will flag every missing doc as a finding. If the repo is pre-docs, expect a high finding volume in those groups. If docs exist but are not listed in the product profile, add their paths under **Documentation Locations** so agents read them before judging gaps.

---

## Prerequisites

### Agent CLI

Install at least one supported agent:

```bash
npm install -g @openai/codex   # Codex (default)
npm install -g @anthropic-ai/claude-code  # Claude
pip install gemini-cli         # Gemini
```

### Lattice MCP

Audit, remediation, and feature-build runs auto-register the Lattice MCP server for Codex and Claude agents when `LATTICE_MCP_AUTO=1` (the default). The harness keeps the MCP workspace at `REPO_ROOT` and optionally narrows context with `LATTICE_MCP_FOCUS_FILES` and `LATTICE_MCP_FOCUS_DIRS`, each accepting comma- or newline-separated paths. Set `LATTICE_MCP_COMMAND` to override the server binary. Set `LATTICE_MCP_AUTO=0` or pass `MCP_CONFIG` / `CLAUDE_MCP_CONFIG` to use an explicit config instead.

Feature-build progress refreshes on the same terminal line by default when stdout is a TTY. Use `FEATURE_BUILD_STATUS_INTERVAL_SECONDS` to tune the interval and `FEATURE_BUILD_PROGRESS=0` to force old line-by-line status output.

### Product profile

Create a product profile before running the audit. The profile tells agents what the product promises, what journeys must work, and where to find docs and test commands.

```bash
mkdir -p profiles/myproduct
cp generic-product-profile-template.md profiles/myproduct/product-profile.md
# fill in the template
```

Key sections to complete:

| Section | Why it matters |
|---|---|
| Launch claims | Agents use these as the pass/fail bar |
| Critical user journeys | Runtime and simulation jobs prove these end to end |
| Supported test commands | Runtime job runs exactly these — nothing invented |
| Dev/staging URL and credential source | Required for browser automation jobs |
| Documentation locations | Agents read these before judging any docs finding |

### Repo structure

The audit writes its output under `$REPO_ROOT/docs/audit/<date>-launch-readiness-run/` by default. The repo does not need any pre-existing structure — the script creates all directories.

The remediation phase reads `artifacts/00-bootstrap/` from the audit run (generated by the bootstrap job). Run the audit before the remediation.

During remediation, native verification commands are chosen deterministically. The launcher prefers the explicit commands listed in the product profile's **Runtime Verification** section (`Supported backend test commands`, `Supported frontend test commands`, `Supported E2E/browser commands`) and respects `Commands that must not be run`. Only when those are absent does it fall back to repo-shape defaults such as `pytest`, `npm test`, `cargo test`, or `make test`.

For maintainability gates, list supported commands in the product profile rather than relying on agents to invent them. Examples by stack:

- Python type checking: `mypy ...` or `pyright ...`
- Python complexity: `radon cc ...` and `radon mi ...`
- Python dead code: `vulture ...`
- Frontend type checking: `tsc --noEmit`
- Frontend dead code: a repo-supported command such as `knip`, `ts-prune`, or an existing lint rule set
- Existing lint/security gates: `ruff`, `eslint`, `bandit`, `semgrep`, `pip-audit`, `npm audit`

Use these as ratchets. It is acceptable for an old repo to report existing debt without blocking every launch run, but changed code should not add new excessive complexity, dead code, type errors, or lint/security failures.

### Browser and Playwright tests

Runtime (job 06) and simulation (job 07) jobs can drive browser automation for E2E proof. To enable this:

1. Put a credentials file at `docs/ux/.creds` in the repo. Use `KEY=VALUE` format, one entry per line:

   ```
   APP_URL=https://staging.example.com
   ADMIN_EMAIL=admin@example.com
   ADMIN_PASSWORD=secret
   TEST_USER_EMAIL=user@example.com
   TEST_USER_PASSWORD=secret
   ```

   The agent reads this file only when a browser job requires it and redacts secret values from all outputs. Add `docs/ux/.creds` to `.gitignore` — do not commit credentials.

2. Set the dev/staging URL in the product profile under **Runtime Verification → Dev/staging URL and credential source**.
3. List the supported E2E/Playwright command in the profile (e.g. `npx playwright test`). The agent runs only commands listed here — it will not invent commands.

If `docs/ux/.creds` is absent, the agent has no credentials to authenticate with. Browser-dependent journeys in the simulation job (07) are marked `unverified` rather than failed — the audit completes, but those journeys produce no authenticated proof. If you only need runtime test execution (not browser simulation), the credentials file is not required.

---

## Quickstart

### Audit a repo

```bash
REPO_ROOT=/path/to/repo \
PROFILE=your-product \
./run-audit.sh --dry-run   # preview job schedule

REPO_ROOT=/path/to/repo \
PROFILE=your-product \
./run-audit.sh             # run
```

### Remediate the findings

```bash
REPO_ROOT=/path/to/repo \
PROFILE=your-product \
REMEDIATION_DIR=/path/to/repo/docs/audit/$(date +%Y-%m-%d)-remediation-run \
REMEDIATION_VERIFY_SCOPE=implementation \
IMPLEMENTER_AGENT=claude \
REVIEWER_AGENT=codex \
./run-remediation.sh \
  --audit-run /path/to/repo/docs/audit/$(date +%Y-%m-%d)-launch-readiness-run \
  --execute
```

`--execute` runs implementation, verifier, deterministic evidence collection, safe auto-revision, queue regeneration, and final review by default. Use `--no-verify-after-execute` only when intentionally producing implementation artifacts without verifier scoring.

To resume an existing remediation ledger without rebuilding packets:

```bash
REPO_ROOT=/path/to/repo \
PROFILE=your-product \
REMEDIATION_DIR=/path/to/repo/docs/audit/<date>-remediation-run-ledger \
REVIEWER_AGENT=codex \
./run-remediation.sh \
  --audit-run /path/to/repo/docs/audit/<date>-launch-readiness-run \
  --execute \
  --no-catalog \
  --verbose
```

For a verifier refresh after the product code changed or prior verifier artifacts are stale:

```bash
./run-remediation.sh \
  --audit-run /path/to/repo/docs/audit/<date>-launch-readiness-run \
  --rerun-verifiers \
  --rerun-final-review \
  --no-catalog \
  --verbose
```

### Build a feature from a spec

```bash
REPO_ROOT=/path/to/repo \
FEATURE_BUILD_PLANNER_AGENT=claude \
FEATURE_BUILD_IMPLEMENTER_AGENT=codex \
FEATURE_BUILD_REVIEWER_AGENT=claude \
./run-feature-build.sh \
  --feature customer-risk-notifications \
  --execute \
  --verify \
  --push dev
```

By default the spec is read from `docs/new-feature/<feature>.md`, state is written to `docs/plans/<feature>/`, execution happens on `feature/<feature>`, and a verified successful build is committed with `feat: build <feature>`.

---

## Profiles

A profile is a subdirectory under `profiles/`. Set `PROFILE=<name>` and the scripts resolve it automatically.

| File | Purpose |
|---|---|
| `product-profile.md` | Product description, trust boundaries, critical journeys. Injected into every agent prompt. |
| `jobs.tsv` | Ordered job manifest for the audit. Overrides `generic-jobs.tsv`. |
| `shared.md` | Shared rules for every job. Overrides `generic-shared.md` / `shared.md`. |

All three files are optional. A profile with only `product-profile.md` gives agents product context while using the generic job schedule.

Create a new profile:

```bash
mkdir profiles/myproduct
cp generic-product-profile-template.md profiles/myproduct/product-profile.md
# fill in the template, then:
REPO_ROOT=/path/to/repo PROFILE=myproduct ./run-audit.sh
```

---

## run-audit.sh

Splits the launch-readiness audit into parallel job batches, builds one bounded prompt per job, and runs each job in a fresh agent session.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_ROOT` | `$PWD` | Repository root passed to the agent. |
| `PROFILE` | — | Profile name (under `profiles/`) or absolute path to a profile dir. |
| `PROFILES_DIR` | `profiles/` alongside the script | Directory containing named profile subdirectories. |
| `RUN_DIR` | `$REPO_ROOT/docs/audit/<date>-launch-readiness-run` | Output directory for logs and findings. |
| `JOBS_FILE` | `generic-jobs.tsv` (or profile override) | Job manifest TSV. |
| `PRODUCT_PROFILE` | profile `product-profile.md` | Product profile markdown injected into prompts. |
| `SHARED_PROMPT` | `generic-shared.md` (or profile override) | Shared rules file injected into every job prompt. |
| `MASTER_PROMPT` | `generic-launch-readiness-audit-prompt.md` | Master audit prompt template. |
| `RUNNER` | `codex` | Agent backend: `codex`, `claude`, or `gemini`. |
| `AUDIT_RUNNER` | — | Custom executable wrapper (overrides `RUNNER`). Receives `<prompt_file> <run_dir> <job_id>`. |
| `AUDIT_DIFFERENTIAL` | `0` | Set to `1` or pass `--differential` to load `docs/audit/register/baseline.json`, compute changed paths from baseline SHA to `HEAD`, and run only the affected audit jobs plus the cheap final gates. |
| `AUDIT_BASELINE_SHA` | — | Optional explicit baseline SHA for differential mode. Overrides `baseline.json`. |
| `MAX_PARALLEL` | `3` | Maximum jobs running in parallel per group. |
| `AUDIT_MAX_RETRIES` | `2` | Retry attempts per job on non-zero exit. |
| `VERBOSE` | `0` | Set to `1` to print log size after each job completes. |
| `DYNAMIC_DEPTH_CAP` | `2` | Maximum depth for dynamically spawned deep-dive jobs. Depth-1 jobs are spawned by standard jobs; depth-2 by depth-1 jobs. Beyond the cap, remaining gaps are logged as findings only. |
| `ACCESSIBILITY_SCAN` | `1` | Run native axe-core accessibility scans during runtime and simulation jobs. Writes raw JSON plus `artifacts/<job>/accessibility/summary.md`. Set to `0` to disable. |
| `LIGHTHOUSE_SCAN` | `1` | Run native Lighthouse during runtime and simulation jobs. Writes raw JSON plus `artifacts/<job>/lighthouse/summary.md`. A poor rating or score < 50 is a launch blocker. Set to `0` to disable. |
| `EXTERNAL_SERVICES_TEST` | `1` | Run native external-service probes during the runtime job using URL/credential material from `docs/ux/.creds`. Writes `artifacts/<job>/external-services/summary.md`. Set to `0` to disable. |
| `SAST_ENABLED` | `1` | Run SAST (Bandit, Semgrep) and dependency CVE scanning (pip-audit, npm audit) during the runtime job. Critical CVEs in direct dependencies or high-severity SAST findings with documented exploits are launch blockers. Set to `0` to disable. |
| `AUDIT_TOOLING_AUTO_INSTALL` | `1` | Auto-install missing native Python audit tooling (`bandit`, `semgrep`, `pip-audit`) into `AUDIT_TOOLING_VENV`. Set to `0` to require preinstalled tooling. |
| `AUDIT_TOOLING_VENV` | `$RUN_DIR/.audit-tooling/venv` | Virtualenv path used for native audit tooling installs. |
| `AUDIT_NODE_TOOLING_AUTO_INSTALL` | `1` | Auto-install missing native Node/browser tooling for Lighthouse and accessibility scans into `AUDIT_NODE_TOOLING_DIR`. Set to `0` to require preinstalled tooling. |
| `AUDIT_NODE_TOOLING_DIR` | `$RUN_DIR/.audit-tooling/node` | Tooling directory used for native Lighthouse/accessibility dependencies and Playwright browser downloads. |
| `AUDIT_BASE_URL` | — | Explicit base URL for native runtime/simulation/load probes. When unset, the script tries `docs/ux/.creds` and the product profile. |
| `ACCESSIBILITY_PATHS` | `/,/login` | Comma-separated paths or absolute URLs used by the native accessibility runner. |
| `LIGHTHOUSE_PATHS` | `/,/login` | Comma-separated paths or absolute URLs used by the native Lighthouse runner. |
| `LOAD_TEST_ENABLED` | `0` | Set to `1` to inject a load test job after all standard runtime jobs complete. The native runner executes baseline, ramp, and spike scenarios and writes a summary artifact before the agent analyzes it. |
| `LOAD_TEST_TARGET` | — | Base URL to load-test. Auto-detected from `docs/ux/.creds` or deployment docs when unset. |
| `LOAD_TEST_TOOL` | `k6` | Advisory preferred load-test tool label passed through the audit metadata. The current native runner uses the built-in HTTP driver and writes `artifacts/load-test/native-load-test-summary.*` for the agent to interpret. |
| `LOAD_TEST_PATHS` | `/` | Comma-separated paths or absolute URLs used by the native load-test runner. |
| `EXTERNAL_SERVICE_TIMEOUT` | `10` | Timeout in seconds for each native external-service probe. |
| `SAST_BANDIT_TIMEOUT` | `300` | Timeout for native Bandit SAST. |
| `SAST_SEMGREP_TIMEOUT` | `600` | Timeout for native Semgrep SAST. |
| `SAST_PIP_AUDIT_TIMEOUT` | `300` | Timeout for native pip-audit. |
| `SAST_NPM_AUDIT_TIMEOUT` | `300` | Timeout for native npm audit. |

Native accessibility and Lighthouse outputs are aggregated into:

- `artifacts/ux-browser-gate-summary.md`
- `artifacts/ux-browser-gate-summary.tsv`

Adversarial and final-decision jobs are instructed to read those files before issuing launch posture. Unverified or failing browser/accessibility/performance evidence is a release input, not optional polish.

At the end of each audit run, the harness also writes:

- `00-run-summary.tsv` — deterministic status for manifest jobs, dynamic deep dives, and optional load test. The first three columns remain `job_id`, `kind`, and `result` for compatibility; appended columns carry `group`, `title`, `output`, `log_path`, and `remediation_context` so remediation packets can preserve source scope and evidence class.
- `failed-jobs-next-actions.md` — non-pass jobs with output paths, log paths, likely failure markers, remediation context, and focused rerun commands.

The summary and next-action artifacts are generated by `lazy_vibe.audit.summary`; `run-audit.sh` owns orchestration, while Python owns deterministic report synthesis.

If a runner/provider outage is detected from job logs, the harness records `runner-unavailable.txt`, stops launching additional jobs, and marks the failed job as `RUNNER_UNAVAILABLE` in the summary. A selected resume with `--only`, `--from-group`, or `--to-group` archives the stale outage marker before launching so you can rerun with another `RUNNER` or after provider recovery.

### Model overrides (Codex)

| Variable | Default |
|---|---|
| `CODEX_MODEL` | per-kind defaults |
| `CODEX_MODEL_DISCOVERY` | `gpt-5.4` |
| `CODEX_MODEL_SYNTHESIS` | `gpt-5.5` |
| `CODEX_MODEL_RUNTIME` | `gpt-5.4` |
| `CODEX_MODEL_SIMULATION` | `gpt-5.5` |
| `CODEX_MODEL_ADVERSARIAL` | `gpt-5.5` |
| `CODEX_MODEL_FINAL` | `gpt-5.5` |

Reasoning effort follows the same pattern: `CODEX_REASONING_EFFORT` overrides all, or set per kind with `CODEX_REASONING_DISCOVERY` etc.

### Model overrides (Claude)

| Variable | Default |
|---|---|
| `CLAUDE_MODEL` | per-kind defaults |
| `CLAUDE_MODEL_DISCOVERY` | `claude-sonnet-4-6` |
| `CLAUDE_MODEL_SYNTHESIS` | `claude-opus-4-7` |
| `CLAUDE_MODEL_RUNTIME` | `claude-sonnet-4-6` |
| `CLAUDE_MODEL_SIMULATION` | `claude-opus-4-7` |
| `CLAUDE_MODEL_ADVERSARIAL` | `claude-opus-4-7` |
| `CLAUDE_MODEL_FINAL` | `claude-opus-4-7` |

Effort follows the same pattern: `CLAUDE_EFFORT` or per-kind `CLAUDE_EFFORT_DISCOVERY` etc.

### Model overrides (Gemini)

| Variable | Default |
|---|---|
| `GEMINI_MODEL` | per-kind defaults |
| `GEMINI_MODEL_DISCOVERY` | `gemini-2.5-flash` |
| `GEMINI_MODEL_SYNTHESIS` | `gemini-2.5-pro` |
| `GEMINI_MODEL_RUNTIME` | `gemini-2.5-flash` |
| `GEMINI_MODEL_SIMULATION` | `gemini-2.5-pro` |
| `GEMINI_MODEL_ADVERSARIAL` | `gemini-2.5-pro` |
| `GEMINI_MODEL_FINAL` | `gemini-2.5-pro` |

### CLI flags

| Flag | Description |
|---|---|
| `--dry-run` | Print the job schedule without running any agents. |
| `--verbose` | Print log size and path after each job completes. |
| `--rules FILE` | Override the shared rules file. |
| `--from-group GROUP` | Start execution from this group (skip earlier groups). |
| `--to-group GROUP` | Stop after this group. |
| `--only JOB_ID` | Run only this single job. |

---

## run-remediation.sh

Reads a completed audit run, extracts findings into remediation packets, groups them into implementation units, runs implementer agents, and optionally runs verifier agents in a revision loop.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_ROOT` | `$PWD` | Repository root. |
| `PROFILE` | — | Profile name or absolute path. Sets `PRODUCT_PROFILE` and `SHARED_PROMPT`. |
| `PROFILES_DIR` | `profiles/` alongside the script | Directory containing named profile subdirectories. |
| `REMEDIATION_DIR` | audit-date remediation directory | Output directory for packets, prompts, logs, and artifacts. When omitted, the script derives the date from the selected audit run and writes beside it. |
| `PRODUCT_PROFILE` | profile `product-profile.md` | Product profile injected into every agent prompt. |
| `SHARED_PROMPT` | `shared.md` (or profile override) | Shared rules injected into every prompt. |
| `IMPLEMENTER_AGENT` | `codex` | Implementation agent: `codex`, `claude`, `gemini`, or `runner`. |
| `CATALOG_AGENT` | `IMPLEMENTER_AGENT` | Cataloger agent: `codex`, `claude`, or `gemini`. |
| `PLANNER_AGENT` | `REVIEWER_AGENT`, then `COORDINATOR_AGENT`, then `IMPLEMENTER_AGENT` | Planner agent for `high-risk`/`complex` implementation units. |
| `REVIEWER_AGENT` | — | Verification agent. Empty disables `--verify`. |
| `MAX_PARALLEL` | `3` | Maximum implementation units running in parallel. |
| `CONTINUE_ON_FAIL` | `0` | Set to `1` to continue past a failed unit instead of stopping. |
| `REMEDIATION_AUTO_REVISE` | `1` | Re-run units that verifier marks `revise` when findings are safe for targeted automatic revision. |
| `REMEDIATION_MAX_REVISION_ROUNDS` | `1` | Maximum automatic revision loops before final review. |
| `REMEDIATION_MAX_AUTO_REVISE_FINDINGS` | `8` | Maximum verifier finding rows allowed for automatic revision; larger units are left for manual triage or splitting. |
| `REMEDIATION_REVISE_NEXT_LIMIT` | `8` | Maximum safe queue rows selected by one `--revise-next` batch. Set `0` for all currently safe rows. |
| `REMEDIATION_REVISE_NEXT_MAX_ROUNDS` | `10` | Maximum deterministic revise-next batches before stopping. Set `0` to continue until no safe candidates or no queue progress. |
| `REMEDIATION_QUEUE_DRAIN_MAX_ROUNDS` | `20` | Maximum deterministic queue-drain action rounds. Set `0` to continue until only manual buckets remain or progress stops. |
| `REMEDIATION_REVISION_MAX_PARALLEL` | `1` | Parallelism during revision rounds. |
| `REMEDIATION_VERIFY_SCOPE` | — | `implementation` checks code/docs/tests; `launch` requires full proof. |
| `REMEDIATION_COLLECT_EVIDENCE` | `1` | Automatically collect deterministic launch evidence after verification surfaces `launch_evidence` or `sandbox_blocked` findings. Set to `0` only to force a manual evidence pass. |
| `REMEDIATION_EVIDENCE_MODE` | `targeted` | Evidence collection mode for browser/live proof. `targeted` exports `PORTAL_AUDIT_SKIP_RUNTIME_QUALITY=1` so proof-specific Playwright evidence is not failed by unrelated Lighthouse/runtime-quality gates. Use `full` when the evidence item is itself runtime quality. |
| `REMEDIATION_EVIDENCE_MAX_ROUNDS` | `1` | Maximum collect-evidence then verify-only loops. |
| `REMEDIATION_AUTO_RERUN_FINAL_REVIEW` | `1` | Rerun final review automatically when verifier inputs changed. |
| `REMEDIATION_AUTO_VERIFY_MISSING` | `1` | During deterministic resume, run verifier agents for queue rows with missing or unreadable verifier artifacts. |
| `REMEDIATION_AUTO_METADATA_CLOSEOUT` | `1` | Automatically repair remediation-owned packet/summary closeout metadata findings, then reverify those units. Does not edit product code or product docs. |
| `REMEDIATION_SANDBOX_PYTEST_FALLBACK` | `1` | Retry pytest commands with `-p no:rerunfailures` when `pytest_rerunfailures` is blocked by sandbox socket permissions. |
| `REMEDIATION_STATIC_PRECHECKS` | `1` | Run deterministic static hygiene prechecks and include their output in verifier prompts. Profiles may add an executable `prechecks.sh`; the built-in scan flags obvious frontend inline-English JSX literals. |
| `REMEDIATION_AUTO_DRAIN_QUEUE` | `1` | On a resumed remediation directory with no explicit phase, drain safe queue actions by default. Set `0` or pass `--no-drain-queue` for bookkeeping-only resume. |
| `REMEDIATION_VERIFY_AFTER_EXECUTE` | `1` | Run verifiers automatically after an implementation wave. Set `0` or pass `--no-verify-after-execute` only for implementation-only artifact generation. |
| `REMEDIATION_REQUIRE_BROWSER_DEPLOY` | `1` | For profiles that require VPS browser evidence, refuse Playwright/Lighthouse proof until the current code has been deployed or deployment is explicitly disabled. Meridian uses this to avoid stale VPS evidence. |
| `REMEDIATION_AUTO_DEPLOY_BROWSER_VPS` | `0` | When set to `1`, allow the harness to run a product deploy command before VPS browser evidence. Meridian runs `scripts/deploy-runtime dev` and then marks browser evidence as deployment-ready for the current harness process. |
| `REMEDIATION_VPS_DEPLOYED` | `0` | Set to `1` only after the relevant product code has been deployed to the VPS for the current run. Used when deployment was performed outside the harness. |
| `REMEDIATION_RUN_GLOBAL_NATIVE_CHECKS` | `0` | Set to `1` to run profile-wide native checks such as full lint/build/test after each implementation unit. By default the remediation runner skips those broad commands so unrelated repo drift does not fail focused unit remediation. |
| `REMEDIATION_ALLOW_LIVE_WORKSPACE_PARALLEL` | `0` | Set to `1` to preserve `MAX_PARALLEL` when `REPO_ROOT` is not a git root. This deliberately allows parallel units to edit the same live workspace without git worktree isolation. Use only when the remediation runner is the only writer. |
| `REMEDIATION_ALLOW_RAW_UNITS` | `0` | Set to `1` only when intentionally executing or auto-revising a large raw one-packet-per-PX manifest. |
| `REMEDIATION_RAW_UNIT_ABORT_THRESHOLD` | `20` | Raw `PX-*` unit count that triggers the execution guard. |
| `REMEDIATION_REWRITE_PACKETS` | `0` | Set to `1` to overwrite existing packet files when reusing `REMEDIATION_DIR`. |
| `REMEDIATION_REWRITE_WORKSTREAMS` | `0` | Set to `1` to overwrite an existing workstream TSV when reusing `REMEDIATION_DIR`. |
| `REMEDIATION_REWRITE_UNITS` | `0` | Set to `1` to overwrite an existing implementation-units TSV when reusing `REMEDIATION_DIR`. |
| `REMEDIATION_IMPORT_PRIOR_RUNS` | `1` | Recover fixed packets from sibling remediation runs for the same audit run when packet source, line, and title still match. |
| `REMEDIATION_HEARTBEAT_SECONDS` | `60` | How often stall detection checks log size. |
| `REMEDIATION_STALL_INTERVALS` | `5` | Unchanged-log intervals before stall-kill (0 disables). |
| `VERBOSE` | `0` | Print log size after each unit completes. |

### CLI flags

| Flag | Description |
|---|---|
| `--audit-run DIR` | Completed audit run directory. If omitted, the script auto-detects the latest `*-launch-readiness-run` or `*-audit-run` under `$REPO_ROOT/docs/audit`, `$REPO_ROOT/project-audit`, or `$REPO_ROOT`. |
| `--feature SLUG` | Seed remediation from `docs/scorecard/<slug>.md` or `docs/scorecards/<slug>.md` when no audit run is supplied. |
| `--scorecard FILE` | Seed remediation from an explicit scorecard file. When no audit run is supplied, the scorecard becomes the only packet source. |
| `--execute` | Run coordinator and implementation agents. |
| `--verify` | Run verifier agents after implementation. |
| `--no-verify-after-execute` | Skip the default verifier/final-review drain after an implementation wave. |
| `--verify-only` | Run only verifiers against an existing remediation directory. |
| `--summary-only` | Regenerate aggregate findings, summary, and queue without running agents. |
| `--finalize-only` | Run final review against existing verifier artifacts. With default settings, stale final-review inputs rerun automatically. |
| `--rerun-verifiers` | Force verifier agents to rerun even when checkpoints exist. |
| `--rerun-final-review` | Force final review to rerun even when its input fingerprint is unchanged. |
| `--revise-next` | Select safe `needs_targeted_revision` rows from the current queue and run targeted implementation plus verification. |
| `--drain-queue` | Keep deriving safe next actions from the current queue: verify missing/stale rows, revise safe rows, repair remediation-owned artifacts/metadata, execute pending split children, collect deterministic evidence, refresh final review, and regenerate summaries. |
| `--no-drain-queue` | Disable default queue drain for a reused remediation directory. |
| `--revise-existing` | Skip cataloging and re-run implementation against existing packets. |
| `--split-incomplete` | Detect and split oversized or incomplete units before re-running. |
| `--no-catalog` | Skip the cataloger when `--execute` is set. |
| `--force-catalog` | Run the cataloger even when an existing implementation-unit catalog is present. |
| `--dry-run` | Print the execution schedule without running agents. |
| `--verbose` | Print log size and path after each unit completes. |
| `--rules FILE` | Override the shared rules file. |
| `--only-group GROUP` | Run only one workstream group. |
| `--only-unit ID` | Run only specific units (comma-separated). |

### Outputs

| Path | Description |
|---|---|
| `00-master-px-list.tsv` | Deduplicated finding inventory. |
| `02-workstreams.tsv` | Packet-to-workstream mapping. |
| `03-implementation-units.tsv` | Implementation units with model class and packet assignments. |
| `packets/PX-*.md` | Remediation packets with status, scope, and work log. |
| `artifacts/*-summary.md` | Post-implementation summaries (changed files, tests, docs, risks). |
| `artifacts/verify-*.md` | Verifier decisions. |
| `artifacts/verify-*-findings.tsv` | Structured verifier findings used as the narrow auto-revision contract. Accepted units may have only the header or launch/sandbox evidence rows. |
| `05-verifier-findings.tsv` | Aggregate verifier findings across units. |
| `06-run-summary.tsv` | Implementation and verifier decision summary by unit. |
| `07-remediation-queue.tsv` | Triage queue that classifies units as accepted, targeted revision, contract conflict, test harness, split required, blocked, or not verified. |
| `08-manual-triage.md` | Human-readable index for manual buckets, with extracted verifier failure reasons and required next actions. |
| `09-next-actions.tsv` / `09-next-actions.md` | Deterministic queue plan that maps every unit to `verify_only`, `implement_then_verify`, `targeted_revision`, `artifact_repair`, `evidence_only`, `child_manual_blockers`, `split_parent_noop`, or a manual action before the harness runs more agents. |
| `artifacts/triage-*.md` | Per-unit manual triage notes for `blocked`, `test_harness`, `contract_conflict`, and `split_required` units. |
| `logs/*.log` | Full agent logs. |
| `04-final-remediation-review.md` | Final read-only signoff. |

The normal remediation lifecycle is deterministic: catalog, coordinate, implement, verify, auto-revise safe implementation findings, collect deterministic launch evidence, rerun affected verifiers, then write the final queue and next-action plan. Operators should not need to copy commands out of verifier reports. Environment variables are force/escape hatches, not required steps for the standard path.

Queue planning is intentionally stricter than queue classification. The queue says what state a unit is in; `09-next-actions.*` says what the harness will do next. Bad remediation-owned native-test scripts, stale native-test logs, packet-work-log contradictions, and metadata-only closeout problems are routed to `artifact_repair` or `metadata_closeout` rather than broad product-code remediation. True harness, contract, split, or blocked rows remain manual with `08-manual-triage.md` and `artifacts/triage-*.md` explaining why another blind agent pass is not deterministic.

Closure is verifier-derived, not packet-state-derived. A split parent is not considered decomposed just because parent packets say `split-into-child-units`; every direct child must have accepted verifier state. If any child has blocked, contract, split-required, or test-harness findings, the parent remains `split_children_pending` and the next-action plan emits `child_manual_blockers` until the child row is closed.

`--rerun-verifiers` is verifier-only when used by itself, but when it is combined with `--execute` it forces verifier reruns after the selected implementation pass. This is especially important with `--revise-existing`: selected units are implemented first, then their verifier artifacts are refreshed from the new active checkout.

Browser evidence wrappers receive `PORTAL_AUDIT_RUN_DIR`, `PORTAL_AUDIT_JOB_ID`, `PORTAL_AUDIT_JOURNEY_SLUG`, `PORTAL_AUDIT_ARTIFACT_DIR`, and `PORTAL_AUDIT_EVIDENCE_MODE` during deterministic evidence collection. A PASS `summary.json` only counts as reusable evidence when every declared `proof_files[]` entry exists on disk; PASS without durable proof is classified as failed evidence. Queue generation also auto-resolves launch-evidence rows that explicitly depend on another `IU-*` once that target unit is accepted with no unresolved findings.

Meridian browser evidence has two extra harness contracts. First, dev VPS browser proof is split-subdomain: `E2E_BASE_URL` is the SPA host and `E2E_API_BASE` is the `api-*` host. The harness derives `E2E_API_BASE=https://api-$host` from a non-local `E2E_BASE_URL` when `api_url` is absent, and refuses same-host API proof for Meridian. Second, VPS Playwright evidence must run against deployed code. Run `scripts/deploy-runtime dev` before collecting Meridian browser proof, set `REMEDIATION_VPS_DEPLOYED=1` if deployment happened outside the harness, or set `REMEDIATION_AUTO_DEPLOY_BROWSER_VPS=1` to let the harness deploy before browser evidence.

`03-implementation-units.tsv` is normalized before prompts are rebuilt. Each `unit_id` is an artifact identity and must appear once; when a coordinator emits repeated rows for the same unit, the runner merges the packet lists into one row before planning, implementation, and verification so agents do not overwrite the same prompt, log, summary, verifier, and checkpoint files.

Resume safety is strict by design. If an existing remediation directory has packet files or unit packet IDs missing from `00-master-px-list.tsv`, the runner refuses to continue because resuming would skip real packet work. Rebuild the catalog with `REMEDIATION_REWRITE_PACKETS=1 REMEDIATION_REWRITE_WORKSTREAMS=1 REMEDIATION_REWRITE_UNITS=1 --force-catalog`, or restore the matching master inventory.

Oversized verifier revisions are split deterministically. When a verifier returns more than `REMEDIATION_MAX_AUTO_REVISE_FINDINGS` non-blocking findings for one parent unit, the runner creates bounded `IU-*-SNN` child packets from those verifier rows instead of revising the oversized parent directly or leaving it as manual-only. Blocking categories still stay manual: `contract_conflict`, true `test_harness`, `blocked`, and explicit `split_required` rows require contract/test-harness/split handling before automatic revision. Parent rows do not hide those blockers; unresolved child rows keep the parent open.

Verifier recovery is intentionally conservative. A verifier process may be auto-recovered only when the log contains a usable verifier artifact and no hard runner/API error. Short verifier logs that only contain transport failures, Codex configuration errors, shell syntax failures, or missing command helpers are treated as real failures instead of accepted verifier output.

Native evidence commands are filtered before execution. The runner accepts real command prefixes from verifier artifacts and skips explanatory prose, so a verifier note such as "run the browser proof manually" is recorded as non-executable evidence rather than sent to the shell.

Global setup and broad project checks are not treated as per-unit native evidence by default. Commands such as `./scripts/backend-venv`, `./scripts/dev-postgres bootstrap`, full backend test suites, frontend builds, and frontend lint/typecheck are skipped unless `REMEDIATION_RUN_GLOBAL_NATIVE_CHECKS=1` is set, because those commands can fail for environment or repo-wide reasons after a unit has already produced valid targeted proof. Agents may write `IMPLEMENTATION_RESULT` markers as plain text, headings, code spans, or bold Markdown; the runner normalizes those forms before deciding whether a non-zero agent process can be recovered from an existing terminal summary.

Verifier prompts cap embedded native-test and static-precheck logs with a head/tail excerpt so broad-suite failures cannot exceed agent input limits. The full log remains on disk under `artifacts/`; tune the prompt excerpt with `REMEDIATION_PROMPT_LOG_MAX_BYTES` when a verifier genuinely needs more context.

Existing ledgers that already contain child packets for the old native-test prose bug are closed deterministically. If a generated child packet only asks to repair a remediation-owned `*-native-test-*.sh` artifact whose failure was executing prose as shell, the runner writes a fixed summary and packet closeout instead of launching an agent against product code.

### Model overrides (Codex)

| Variable | Default |
|---|---|
| `CODEX_MODEL` | per-class defaults |
| `CODEX_MODEL_COORDINATOR` | `gpt-5.5` |
| `CODEX_MODEL_PLANNER` | `gpt-5.5` |
| `CODEX_MODEL_HIGH_RISK` | `gpt-5.5` |
| `CODEX_MODEL_VERIFIER` | `gpt-5.5` |
| `CODEX_MODEL_REVIEWER` | `gpt-5.5` |
| `CODEX_MODEL_STANDARD` | `gpt-5.4` |

Reasoning effort follows the same pattern: `CODEX_REASONING_EFFORT` overrides all, or set per class with `CODEX_REASONING_COORDINATOR` etc.

### Model overrides (Claude)

| Variable | Default |
|---|---|
| `CLAUDE_MODEL` | per-class defaults |
| `CLAUDE_MODEL_HIGH` | `claude-opus-4-7` (coordinator, planner, high-risk, verifier, reviewer) |
| `CLAUDE_MODEL_STANDARD` | `claude-sonnet-4-6` (standard, cataloger) |

Effort follows the same pattern: `CLAUDE_EFFORT`, `CLAUDE_EFFORT_HIGH`, `CLAUDE_EFFORT_STANDARD`, `CLAUDE_EFFORT_CATALOGER`.

### Model overrides (Gemini)

| Variable | Default |
|---|---|
| `GEMINI_MODEL` | per-class defaults |
| `GEMINI_MODEL_HIGH` | `gemini-2.5-pro` (coordinator, planner, high-risk, verifier, reviewer) |
| `GEMINI_MODEL_STANDARD` | `gemini-2.5-flash` (standard, cataloger) |

### Stall detection and auto-recovery

The spinner updates every 0.5 seconds in place on one line. If a unit's log file stops growing for `REMEDIATION_STALL_INTERVALS × REMEDIATION_HEARTBEAT_SECONDS` seconds and the log already contains a `RESULT:` line, the stuck process is killed and the unit is checked for auto-recovery.

If the log contains `RESULT: PASS` and the summary artifact exists, the unit is checkpointed as successful even if the agent process exited non-zero (handles rate-limit disconnects where work completed before the connection dropped).

### Runner hooks

Override the agent for specific roles:

| Variable | Role |
|---|---|
| `CATALOG_RUNNER` | Cataloger |
| `REMEDIATION_RUNNER` | All roles (fallback) |
| `VERIFICATION_RUNNER` | Verifier |
| `REVIEW_RUNNER` | Final reviewer |
| `IMPLEMENTER_RUNNER` | Implementation units (when `IMPLEMENTER_AGENT=runner`) |
| `REVIEWER_RUNNER` | Verifier and reviewer (when `REVIEWER_AGENT=runner`) |

Each runner receives `<prompt_file> <remediation_dir> <workstream_id>`.

---

## run-feature-build.sh

Builds a complete feature from an approved spec under `docs/new-feature/`. The shell script is intentionally thin; the workflow engine lives in `lazy_vibe/feature_build/`.

The harness is state-driven:

1. Planner agent reads the spec and writes `docs/plans/<feature>/tasks.json`.
2. The harness mirrors that machine contract into `docs/plans/<feature>/plan.md`.
3. Implementer agents execute pending tasks whose dependencies are complete, with parallel DAG execution across ready tasks.
4. Before dispatching an agent, the harness runs the task verification contract. If the current tree already satisfies it, the task is marked complete without burning implementation tokens.
5. Reviewer tasks run like normal tasks and can block downstream work.
6. The harness, not the agent, marks a task complete only after expected files exist, declared verification commands pass, and the task result artifact satisfies the closeout quality gate.
7. The harness injects coding, UI, definition-of-done, route, and multi-layer contract standards into task prompts.
8. The harness rejects deferral/workaround language by default.
9. Optional post-build review and remediation commands can call the existing audit/remediation control planes before the default commit and any explicit push/deploy step.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_ROOT` | `$PWD` | Product repo root. |
| `FEATURE_BUILD_PLANNER_AGENT` | `PLANNER_AGENT`, then `claude` | Agent used to decompose the spec into task files. |
| `FEATURE_BUILD_IMPLEMENTER_AGENT` | `IMPLEMENTER_AGENT`, then `codex` | Agent used for implementation tasks. |
| `FEATURE_BUILD_REVIEWER_AGENT` | `REVIEWER_AGENT`, then `claude` | Agent used for review tasks. |
| `FEATURE_BUILD_MAX_RETRIES` | `1` | Retry attempts per failed task before the harness stops. |
| `FEATURE_BUILD_MAX_PARALLEL` | `3` | Maximum ready DAG tasks running in parallel. |
| `FEATURE_BUILD_STANDARD_GATES` | `1` | Inject coding/UI/definition-of-done verification and run final standard gates. |
| `FEATURE_BUILD_RESULT_QUALITY_GATES` | `1` | Require complete per-task result artifacts after agent execution and for already-complete tasks during verify-only runs. The result must include expected closeout sections, exact verification commands, no deferral language, and `Final status: complete`. |
| `FEATURE_BUILD_REQUIRE_REVIEW_TASKS` | `1` | Reject plans that contain no review tasks. |
| `FEATURE_BUILD_ALLOW_DEFERRALS` | `0` | Reject task plans containing deferral/workaround language unless explicitly enabled. |
| `FEATURE_BUILD_AUTO_BRANCH` | `1` | Create or switch to the feature branch before execute runs. Set to `0` to require caller-managed branches. |
| `FEATURE_BUILD_BRANCH` | `feature/<feature>` | Branch name used by the default branch step when `--branch` is not provided. |
| `FEATURE_BUILD_AUTO_COMMIT` | `1` | Commit successful `--execute --verify` builds after final state is written. Set to `0` to leave changes uncommitted by default. |
| `FEATURE_BUILD_POST_BUILD_REVIEW_COMMAND` | — | Optional independent review command after build verification. Receives `FEATURE_BUILD_FEATURE`, `FEATURE_BUILD_RUN_DIR`, `FEATURE_BUILD_SPEC`, and `FEATURE_BUILD_SCORECARD`. |
| `FEATURE_BUILD_AUTO_REMEDIATE_COMMAND` | — | Optional remediation command run when the post-build review writes a revise/fail decision. Receives the same variables plus `FEATURE_BUILD_REVIEW_ROUND`. |
| `FEATURE_BUILD_POST_BUILD_ROUNDS` | `1` | Maximum post-build review/remediation rounds. |
| `CODEX_MODEL` | — | Override Codex model for every feature-build task. |
| `FEATURE_BUILD_CODEX_MODEL_FAST` | `gpt-5.3-codex-spark` | Codex model for fast tasks. |
| `FEATURE_BUILD_CODEX_MODEL_BALANCED` | `gpt-5.4` | Codex model for balanced tasks. |
| `FEATURE_BUILD_CODEX_MODEL_ADVANCED` | `gpt-5.5` | Codex model for advanced tasks. |
| `CODEX_EXTRA_ARGS` | — | Extra arguments appended to `codex exec`. |
| `CLAUDE_MODEL` | — | Override Claude model for all feature-build phases. |
| `FEATURE_BUILD_CLAUDE_MODEL_FAST` | `claude-haiku-4-5` | Claude model for fast tasks. |
| `FEATURE_BUILD_CLAUDE_MODEL_BALANCED` | `claude-sonnet-4-6` | Claude model for balanced tasks. |
| `FEATURE_BUILD_CLAUDE_MODEL_ADVANCED` | `claude-opus-4-7` | Claude model for advanced tasks. |
| `CLAUDE_EXTRA_ARGS` | — | Extra arguments appended to `claude`. |
| `CLAUDE_TRANSPORT` | `prompt` | `prompt` uses `claude -p`; `pty` drives interactive Claude through a pseudo-terminal and avoids `-p`. Supported by audit, remediation, feature-build, and fixed-domain audit harnesses. |
| `CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS` | `20` | PTY mode exits after this many idle seconds once a `RESULT:` marker is observed. |
| `CLAUDE_PTY_STARTUP_SECONDS` | `3` | PTY mode waits this long before pasting the prompt into interactive Claude. |
| `GEMINI_MODEL` | — | Override Gemini model. |
| `FEATURE_BUILD_GEMINI_MODEL_FAST` | `gemini-2.5-flash` | Gemini model for fast tasks. |
| `FEATURE_BUILD_GEMINI_MODEL_BALANCED` | `gemini-3.1-pro` | Gemini model for balanced tasks. |
| `FEATURE_BUILD_GEMINI_MODEL_ADVANCED` | `gemini-3.1-pro` | Gemini model for advanced tasks; Gemini currently has no separate Opus/GPT-5.5-equivalent tier. |
| `GEMINI_EXTRA_ARGS` | — | Extra arguments appended to `gemini`. |

`model_class` is a three-tier contract: `fast`, `balanced`, or `advanced`. The harness also accepts old aliases: `standard` maps to `balanced`, while `complex`, `high-risk`, `planner`, `review`, and `reviewer` map to `advanced`.

### CLI flags

| Flag | Description |
|---|---|
| `--feature SLUG` | Required feature slug. |
| `--spec FILE` | Spec file. Defaults to `$REPO_ROOT/docs/new-feature/<slug>.md`. |
| `--run-dir DIR` | State directory. Defaults to `$REPO_ROOT/docs/plans/<slug>`. |
| `--execute` | Run pending tasks after decomposition. |
| `--verify` | Re-run all task verification commands after task execution. |
| `--verify-only` | Run verification commands against an existing plan without invoking agents. |
| `--force-decompose` | Regenerate `tasks.json` and task files. |
| `--only-task T01,T02` | Execute or verify only specific task IDs. |
| `--max-retries N` | Retry failed tasks N times. |
| `--max-parallel N` | Run up to N ready DAG tasks in parallel. |
| `--dry-run` | Print the task schedule without invoking agents. |
| `--branch BRANCH` | Feature branch to create or use before execution. Defaults to `feature/<feature>`. |
| `--no-branch` | Disable default feature branch creation/switching. |
| `--commit` | Force a commit after all gates pass. Successful `--execute --verify` runs commit by default. |
| `--no-commit` | Disable the default post-verify commit. |
| `--commit-message MSG` | Commit message. Defaults to `feat: build <feature>`. |
| `--push [REMOTE]` | Push the current branch after commit. Defaults to `origin`; use `--push dev` for the dev VPS remote. |
| `--push-branch BRANCH` | Branch to push. Defaults to the current branch. |
| `--deploy-command CMD` | Command to run after push succeeds. |
| `--post-build-review-command CMD` | Run an independent review command after build verification. A zero exit with no structured decision is treated as accepted. |
| `--auto-remediate-command CMD` | Run a remediation command if the post-build review emits a revise/fail decision. |
| `--post-build-rounds N` | Maximum review/remediation rounds. |
| `--skip-standard-gates` | Emergency bypass for harness-injected standards and final standard gates. Prefer fixing the plan instead. |

### Outputs

| Path | Description |
|---|---|
| `docs/plans/<feature>/state.json` | Machine-readable run state and event log. |
| `docs/plans/<feature>/tasks.json` | Machine-readable task graph consumed by the harness. |
| `docs/plans/<feature>/plan.md` | Human-readable task graph and verification contract generated from `tasks.json`. |
| `docs/plans/<feature>/tasks/*.md` | Human-readable task files for agents. |
| `docs/plans/<feature>/prompts/*.md` | Exact prompts sent to agents. |
| `docs/plans/<feature>/logs/*.log` | Agent logs and deploy logs. |
| `docs/plans/<feature>/results/*.md` | Agent result summaries. |
| `docs/plans/<feature>/verify/<task>/*.log` | Verification command output. |
| `docs/plans/<feature>/artifacts/post-build-review.json` | Optional structured post-build review decision: `{"accepted": true}` or `{"verdict": "revise"}`. |

`tasks.json` is the contract. Each task must include `task_id`, `title`, `task_type`, `depends_on`, `status`, `files_expected`, and `verification_commands`. The harness refuses duplicate IDs, unknown dependencies, and non-skipped tasks with no runnable verification commands after harness filtering.

When standard gates are enabled, the harness appends verification commands from repo shape:

- Backend Python files trigger `ruff check`, `ruff format --check`, and `pytest` when those tools/tests are present.
- Frontend TypeScript/JavaScript/CSS files trigger available `npm run lint`, `npm run typecheck`, `npm run build`, and `npm run test` scripts.
- Review tasks require the shared definition-of-done checklist.
- Route/page work requires the shared route-acceptance checklist.
- Multi-layer contract work adds deterministic checks for backend, frontend, docs, and agent surfaces when task titles, types, or expected files mention agent, BES, job payload, telemetry, permissions, webhooks, integrations, or contracts.

With `--verify`, those backend/frontend standard gates also run once at the end before post-build review, commit, or push.

Per-task result quality gates are separate from shell verification. After an agent runs, `results/<task>.md` must include the required closeout sections, list the exact verification commands from `tasks.json`, avoid deferral/workaround language unless explicitly allowed, and declare `Final status: complete`. Verify-only also checks result quality for tasks already marked `complete`. This prevents agents from closing feature tasks with unstructured prose while code, docs, tests, cleanup, or operability proof are missing.

### Harness consolidation roadmap

These are deliberate control-plane boundaries:

- `run-audit.sh` owns launch-readiness audit, including UX/browser proof, accessibility, Lighthouse, route/nav/API wiring, dynamic deep-dive queue freshness, and final release decisions.
- `run-remediation.sh` owns remediation, including scorecard/finding ingestion, verification-before-implementation, root-cause metadata, no-change fast paths, worktree promotion, scorecard rewrites, and final remediation queues.
- `run-feature-build.sh` owns building from an approved spec, then calls audit/remediation control planes through post-build commands rather than duplicating their state machines.
- Specialized harnesses are only justified where the domain has hard external rules and fixed evidence contracts. Current examples are Keystone GAAP/IFRS accounting audit and RMM ops automation chain audit.

## Specialized domain harnesses

These are intentionally narrow wrappers around rich domain skills. They do not replace `run-audit.sh`; they exist where the audit domain has fixed external rules or fixed chain-tracing evidence that should not be diluted into a generic launch audit.

### Keystone accounting audit

```bash
cd /home/pete/cadres/keystone
REPO_ROOT=/home/pete/cadres/keystone \
RUNNER=claude \
/home/pete/cadres/shared/lazy-vibe/run-keystone-accounting-audit.sh
```

The wrapper loads `.claude/skills/keystone-accounting-audit/SKILL.md`, writes a fixed audit prompt under `RUN_DIR/prompts/`, and logs the agent run under `RUN_DIR/logs/`.

### RMM ops automation audit

```bash
cd /home/pete/cadres/rmm
REPO_ROOT=/home/pete/cadres/rmm \
RUNNER=claude \
/home/pete/cadres/shared/lazy-vibe/run-rmm-ops-automation-audit.sh
```

The wrapper loads `.claude/skills/spog-ops-auditor/SKILL.md`, preserving the automation-chain tracing model, gap taxonomy, and file:line evidence requirement.

---

## Findings register (`lazy_vibe/register`)

Persistent, adjudicated findings register — the convergence layer between
audit runs. Design: `docs/superpowers/specs/2026-06-11-register-core-design.md`.

Each product repo owns `docs/audit/register/` containing `register.jsonl`
(canonical, git-committed), generated `register.md`, `themes.yaml` (theme
vocabulary), and `reconcile-report.md` (latest run delta).

Usage after an audit/remediation run produced a blocker ledger:

    python3 -m lazy_vibe.register backfill \
      --register-dir <product>/docs/audit/register \
      --ledger <REMEDIATION_DIR>/00-blocker-ledger.tsv \
      --run-id <run-id>

The reconcile report headline (`N new, M suppressed, K regressed, J still
open`) is the run-over-run convergence metric. Dispositions: new findings are
adjudicated once (open / false_positive / risk_accepted / parked) and that
decision persists; `fixed` requires a linked regression test; reappearance of
a fixed finding is flagged as a regression. `false_positive` and
`risk_accepted` are protected — only Pete can reopen them, and risk
acceptances carry a mandatory `review_by` date.

Tests: `python3 -m pytest tests/register -v`

Plan 2a adds: `scorecard-ingest` (feature-review scorecards -> register),
`scope-recompute` (re-evaluate `in_scope` after editing
`launch-scope.yaml`), and `readiness` (deterministic verdict; exit 0
READY / 1 NOT READY / 2 stale gate evidence). The readiness report always
lists active risk acceptances and parked counts.

Plan 2b adds the triage pipeline: `verify-packets` (write per-finding
verification packets for `new` findings), `verify-consume` (fold
schema-validated verifier results back — VERIFIED stays `new` for
policy/Pete, UNSUPPORTED proposes `false_positive`, confirmed duplicates
absorb into the original, `split` queues a manual item), `triage` (apply
`triage-policy.yaml`, render `triage-queue.md`, and walk it interactively as
Pete — `--accept-all` for batch, `--render-only` to just regenerate the
queue), and `close` (harness: `open`/`in_remediation` -> `fixed` with a
linked regression test). `run-triage.sh` dispatches a verifier agent
(`TRIAGE_AGENT`, default `claude`; `MAX_PARALLEL`, default 3) over the packets
and consumes the results. It follows the same product-profile contract as
audit/remediation: set `PROFILE=meridian` (or `PRODUCT_PROFILE=/path/to/product-profile.md`)
and it reads the profile's `Repo root`, defaults the register to
`<repo>/docs/audit/register` when `--register-dir` is omitted, and runs verifier
agents from the product repo so bare evidence refs resolve against the right
checkout. Policy auto-dispositions are stamped
`policy:<rule-id>`; every Pete decision is stamped `pete`.

Plan 3 starts wiring remediation to the register. For register-enabled product
repos, `run-remediation.sh` resolves the same `PROFILE`/`PRODUCT_PROFILE`
contract, detects `docs/audit/register/register.jsonl`, and builds its packet
inventory from `open` and `regressed` register entries instead of scraping
historical audit prose. It writes `00-register-px-map.tsv` so the legacy
`PX-*` packet runner remains stable while each packet stays bound to an
authoritative `R-*` finding. When a verifier accepts a unit, the harness
requires a `Regression test: path::test_name` line and closes the mapped
register finding through `python3 -m lazy_vibe.register close`.

`run-audit.sh` also has a post-summary register hook. It generates
`RUN_DIR/00-blocker-ledger.tsv` from non-pass audit summary rows plus job
logs/artifacts, resolves the product register, runs
`python3 -m lazy_vibe.register backfill`, regenerates the register report, and
writes `docs/audit/register/baseline.json` with the reconciled run id and git
sha. If an audit has no non-pass jobs, no ledger is written.

For post-feature checks, `run-audit.sh --differential` reads that
`baseline.json`, diffs the baseline SHA to `HEAD`, writes
`RUN_DIR/artifacts/differential-scope.md` and
`RUN_DIR/artifacts/differential-jobs.tsv`, and injects the changed-path scope
into every selected prompt. Missing, corrupt, or stale baselines fail with an
actionable message; pass `--full` to force the normal full job manifest.

---

## Progress display

Audit and remediation show an in-place spinner while an agent is running:

```
[-] PX-0042 (87s)
```

The spinner character cycles through `- \ | /` every 0.5 seconds. The line updates in place — no log spam. Pass `--verbose` to see log size on completion.
