# lazy-vibe

Agent-driven launch-readiness audit and remediation toolkit. Two scripts — `run-audit.sh` and `run-remediation.sh` — orchestrate multi-agent sessions that audit a codebase for launch readiness, then catalogue and fix every finding.

Supports Codex CLI, Claude CLI, and Gemini CLI as agent backends. Profiles let you drop in product-specific job lists and prompts without modifying the scripts.

---

## Directory layout

```
lazy-vibe/
├── run-audit.sh                        # audit orchestrator
├── run-remediation.sh                  # remediation orchestrator
├── generic-shared.md                   # shared rules injected into every audit job
├── generic-jobs.tsv                    # default job manifest (used when no profile sets one)
├── generic-launch-readiness-audit-prompt.md
├── generic-product-profile-template.md
└── profiles/
    └── <your-product>/
        ├── jobs.tsv          # optional — overrides generic-jobs.tsv
        ├── product-profile.md
        └── shared.md         # optional — overrides generic-shared.md
```

---

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
| **06** | `06-runtime` | Runs the supported test commands listed in the product profile. Only commands listed there are executed — nothing is invented. |
| **07** | `07-customer-simulation` | Simulates critical customer/operator journeys end-to-end. If browser automation is configured (URL + credentials + Playwright command in the profile), it drives the UI. Journeys with no harness are marked `unverified`. |
| **08** | `08-adversarial` | A hostile reviewer attacks the launch claims and tries to find gaps the earlier jobs missed. |
| **09** | `09-final-decision` | Issues the final release decision based on all prior findings. |

The remediation phase reads the audit output, extracts findings into packets, and runs an implementer–verifier loop that fixes code, tests, and docs.

### What the audit relies on

The audit reads what is already in the repo. The quality of its findings depends on what is there to read.

| Input | Used by | What happens without it |
|---|---|---|
| Architecture, functional, and API docs (locations in product profile) | Groups 01–03 | Findings shift from "code diverges from docs" to "docs are missing entirely" — still valid findings, but less actionable |
| Test suite (unit, integration, E2E) | Groups 02–03, 06 | Test coverage gaps are reported; runtime job (06) has nothing to run |
| Supported test commands in product profile | Group 06 | Runtime job is skipped — it will not invent commands |
| Critical journeys in product profile | Group 07 | Simulation job has no journeys to drive; marks all unverified |
| Competitors/alternatives in product profile | Group 04 | Market comparison job is skipped |
| `docs/ux/.creds` + staging URL + E2E command | Group 07 | Browser journeys are marked `unverified`; non-browser journeys still run |

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
  --execute \
  --verify
```

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
| `MAX_PARALLEL` | `3` | Maximum jobs running in parallel per group. |
| `AUDIT_MAX_RETRIES` | `2` | Retry attempts per job on non-zero exit. |
| `VERBOSE` | `0` | Set to `1` to print log size after each job completes. |

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
| `REMEDIATION_DIR` | `$REPO_ROOT/docs/audit/<date>-remediation-run` | Output directory for packets, prompts, logs, and artifacts. |
| `PRODUCT_PROFILE` | profile `product-profile.md` | Product profile injected into every agent prompt. |
| `SHARED_PROMPT` | `shared.md` (or profile override) | Shared rules injected into every prompt. |
| `IMPLEMENTER_AGENT` | `codex` | Implementation agent: `codex`, `claude`, `gemini`, or `runner`. |
| `PLANNER_AGENT` | `COORDINATOR_AGENT`, then `IMPLEMENTER_AGENT` | Planner agent for `high-risk`/`complex` implementation units. |
| `REVIEWER_AGENT` | — | Verification agent. Empty disables `--verify`. |
| `MAX_PARALLEL` | `3` | Maximum implementation units running in parallel. |
| `CONTINUE_ON_FAIL` | `0` | Set to `1` to continue past a failed unit instead of stopping. |
| `REMEDIATION_AUTO_REVISE` | `1` | Re-run units that verifier marks `revise` or `blocked`. |
| `REMEDIATION_MAX_REVISION_ROUNDS` | `2` | Maximum automatic revision loops before final review. |
| `REMEDIATION_REVISION_MAX_PARALLEL` | `1` | Parallelism during revision rounds. |
| `REMEDIATION_VERIFY_SCOPE` | — | `implementation` checks code/docs/tests; `launch` requires full proof. |
| `REMEDIATION_ALLOW_RAW_UNITS` | `0` | Set to `1` only when intentionally executing a large raw one-packet-per-PX manifest. |
| `REMEDIATION_RAW_UNIT_ABORT_THRESHOLD` | `50` | Raw `PX-*` unit count that triggers the execution guard. |
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
| `--audit-run DIR` | **(required)** Completed audit run directory. |
| `--execute` | Run coordinator and implementation agents. |
| `--verify` | Run verifier agents after implementation. |
| `--verify-only` | Run only verifiers against an existing remediation directory. |
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
| `logs/*.log` | Full agent logs. |
| `04-final-remediation-review.md` | Final read-only signoff. |

`03-implementation-units.tsv` is normalized before prompts are rebuilt. Each `unit_id` is an artifact identity and must appear once; when a coordinator emits repeated rows for the same unit, the runner merges the packet lists into one row before planning, implementation, and verification so agents do not overwrite the same prompt, log, summary, verifier, and checkpoint files.

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

## Progress display

Both scripts show an in-place spinner while an agent is running:

```
[-] PX-0042 (87s)
```

The spinner character cycles through `- \ | /` every 0.5 seconds. The line updates in place — no log spam. Pass `--verbose` to see log size on completion.
