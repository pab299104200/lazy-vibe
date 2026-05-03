# agent-orchestrator

Provider-agnostic orchestration for multi-agent planning, implementation, and review.

The coordinator is deterministic software — no model decides what happens next, the script does. Model roles are assigned in `config.json`:

- `architect` turns the user instruction into a structured work packet.
- `critic` challenges the work packet adversarially before implementation starts.
- `chair` moderates planning consensus and post-review signoff.
- `implementer` edits the repo, with bounded subagent orchestration when the plan allows it.
- `reviewer` reviews the actual diff and verification evidence.
- `verifier` (audit workflow only) challenges audit findings against real code and docs before review.

## Prerequisites

Python 3.8 or later. At least one supported agent CLI:

```bash
npm install -g @openai/codex               # Codex
npm install -g @anthropic-ai/claude-code   # Claude
pip install gemini-cli                     # Gemini
```

## Layout

```text
agent-orchestrator/
├── agent_loop.py
├── config.json
├── audits/           # product-specific audit instruction prompts
├── prompts/          # role prompt templates
├── schemas/          # structured output schemas per phase
└── sessions/         # session logs (gitignored by default)
```

Each run creates one folder under `sessions/`:

```text
sessions/<timestamp>-<task-type>-<hash>/
├── metadata.json
├── instruction.md
├── run_config.json
├── transcript.jsonl    # machine-readable event log
├── transcript.md       # human-readable session log
├── prompts/            # rendered prompts per phase
├── outputs/            # raw agent stdout/stderr/result per phase
├── contracts/          # consensus and blocker contracts
└── diffs/              # git diffs captured after each write phase
```

Sessions accumulate alongside `agent_loop.py`. The `sessions/` directory is gitignored by default — add a `sessions/.gitkeep` to preserve the directory in version control.

## Configuration

`config.json` controls providers, model profiles, workflows, and default role assignments.

| Key | Purpose |
|---|---|
| `roles` | Default provider and model profile for each role |
| `model_profiles` | Named profiles (`cheap_fast`, `balanced`, `deep`) and their per-provider model IDs |
| `providers` | CLI command, prompt delivery, and sandbox modes for each provider |
| `workflows` | Phase sequences and loop limits for `implement`, `bug`, and `audit` task types |
| `shared_dir` | Absolute path to your shared standards directory (see below) |

### Shared standards

The reviewer checks implementation against your shared coding standards. Set `shared_dir` in `config.json`:

```json
{
  "shared_dir": "/path/to/your/standards"
}
```

The reviewer looks for these files under `shared_dir`:

| File | Purpose |
|---|---|
| `templates/coding.md` | Coding standard |
| `templates/ui-specification.md` | UI/UX conventions |
| `templates/definition-of-done-checklist.md` | Completion gate |
| `AGENTS.md` (section: Execution Philosophy) | Agent operating principles |

If these files do not exist, the reviewer notes them as residual risk rather than blocking signoff. Leave `shared_dir` empty if you do not have shared standards.

## Usage

Prepare a run without calling any model:

```bash
python3 agent_loop.py run \
  --repo /path/to/repo \
  --instruction "Add missing input validation to the signup form"
```

Execute the configured workflow:

```bash
python3 agent_loop.py run \
  --repo /path/to/repo \
  --instruction-file /tmp/task.md \
  --task-type implement \
  --execute
```

Override role assignments per run:

```bash
python3 agent_loop.py run \
  --repo /path/to/repo \
  --instruction-file /tmp/task.md \
  --roles '{"chair":"gemini","architect":"claude","critic":"codex","implementer":"claude","reviewer":"codex"}' \
  --execute
```

Run an audit using a product-specific prompt from the `audits/` directory:

```bash
python3 agent_loop.py run \
  --repo /path/to/repo \
  --instruction-file audits/your-product.md \
  --task-type audit \
  --roles '{"chair":"gemini","architect":"claude","critic":"codex","implementer":{"provider":"claude","model_profile":"deep","max_subagents":8},"verifier":"codex","reviewer":"codex"}' \
  --execute
```

Run with an interactive planning pause:

```bash
python3 agent_loop.py run \
  --repo /path/to/repo \
  --instruction-file /tmp/task.md \
  --task-type implement \
  --interactive-plan \
  --execute
```

`--interactive-plan` disables automatic Architect revision loops. When Critic or Chair blocks planning consensus, the coordinator pauses for user guidance, appends it to the transcript, and runs a Chair re-analysis. The guidance is treated as moderation evidence — it does not automatically force a plan rewrite.

Resume from an existing session folder:

```bash
python3 agent_loop.py resume sessions/20260428-091500-implement-a1b2c3d4e5 --execute
```

Retry a failed or coordinator-blocked session in a new session folder:

```bash
python3 agent_loop.py retry \
  sessions/20260429-213807-audit-48efb9e47d \
  --from-failed \
  --refresh-config \
  --execute
```

`retry` creates a new session folder, copies the prior transcript as context, and starts at the failed or blocked phase instead of rerunning completed phases. Use `--from-phase <phase>` to override the automatic retry start point — useful after a prompt or policy fix. Verifier and reviewer blockers retry from `implementation` by default so issues are fixed before verification reruns.

## Task types

### implement

Normal planning → implementation → review loop.

Requires a consensus `task_plan` with effort estimate, risk class, task class, model profile, context budget, tests, and docs for each task. Implementer subagents must report a `context_budget_tokens` value at or below `200000`. Review must explicitly check the agreed spec, shared coding standard, UI standard where applicable, definition-of-done checklist, execution philosophy, model routing, and subagent context budgets.

If the Critic rejects the Architect plan, the coordinator runs Architect/Critic revision rounds up to `max_plan_rounds` before Chair moderation.

### bug

Same loop as `implement` but every prompt is labelled as bug work so agents focus on reproduction, diagnosis, regression tests, and the smallest correct fix.

Bug tasks additionally require a `remote_log_plan` in the consensus contract, `remote_logs_checked` in the implementation output, and `bug_log_review` in the reviewer output. The team must check remote VPS logs before assigning root cause — the plan is rejected if it jumps straight to code changes without first checking or explicitly documenting why logs are unavailable.

### audit

Adds an evidence-verification phase between implementation and review. The verifier challenges every P0/P1 audit finding against real code and documentation. Review and signoff are blocked when verification returns failed findings, missing evidence, register inconsistencies, or fail/partial assertion checks.

The `audits/` directory holds product-specific audit instruction prompts. See `audits/example.md` for a worked example of a full multi-phase audit prompt covering code-vs-spec, security, financial integrity, UX journeys, refactoring, and market comparison.

## Safety defaults

- Runs are dry by default. Pass `--execute` to launch agent CLIs.
- Only the `implementer` phase runs in write mode. All other phases are read-only.
- The implementation prompt includes `max_subagents` and model-routing limits so the implementer cannot over-provision.
- Every rendered prompt and raw agent output is recorded to the session folder before moving to the next phase.
