#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
MASTER_PROMPT="${MASTER_PROMPT:-$SCRIPT_DIR/generic-launch-readiness-audit-prompt.md}"
SHARED_PROMPT="${SHARED_PROMPT:-$SCRIPT_DIR/generic-shared.md}"
JOBS_FILE="${JOBS_FILE:-}"
PRODUCT_PROFILE="${PRODUCT_PROFILE:-}"
PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"
PROFILE="${PROFILE:-}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/docs/audit/$(date +%Y-%m-%d)-launch-readiness-run}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
CONTINUE_ON_FAIL="${CONTINUE_ON_FAIL:-1}"
DRY_RUN=0
VERBOSE="${VERBOSE:-0}"
AUDIT_MAX_RETRIES="${AUDIT_MAX_RETRIES:-2}"
DYNAMIC_DEPTH_CAP="${DYNAMIC_DEPTH_CAP:-2}"
ACCESSIBILITY_SCAN="${ACCESSIBILITY_SCAN:-1}"
EXTERNAL_SERVICES_TEST="${EXTERNAL_SERVICES_TEST:-1}"
LOAD_TEST_ENABLED="${LOAD_TEST_ENABLED:-0}"
LOAD_TEST_TARGET="${LOAD_TEST_TARGET:-}"
LOAD_TEST_TOOL="${LOAD_TEST_TOOL:-k6}"
SAST_ENABLED="${SAST_ENABLED:-1}"
LIGHTHOUSE_SCAN="${LIGHTHOUSE_SCAN:-1}"

usage() {
  cat <<'USAGE'
Usage: run-audit.sh [--dry-run] [--verbose] [--rules FILE] [--from-group GROUP] [--to-group GROUP] [--only JOB_ID]

Environment:
  RUN_DIR              Output directory for this audit run.
  REPO_ROOT            Repo root. Defaults to current working directory.
  MASTER_PROMPT        Master audit prompt. Defaults to generic-launch-readiness-audit-prompt.md alongside the script.
  PROFILE              Profile name (resolved under PROFILES_DIR) or absolute path to a profile directory.
                       Sets JOBS_FILE, PRODUCT_PROFILE, and SHARED_PROMPT (from shared.md in profile dir) if not already set.
  PROFILES_DIR         Directory containing named profile subdirectories. Defaults to profiles/ alongside the script.
  PRODUCT_PROFILE      Optional product profile markdown. Required for generic prompt usage.
  JOBS_FILE            Job manifest TSV. Defaults to generic-jobs.tsv alongside the script (or jobs.tsv from the profile dir).
  SHARED_PROMPT        Shared job instructions. Defaults to generic-shared.md. Override with --rules or this env var.
  RUNNER               LLM runner to use: codex (default), claude, or gemini.
  MAX_PARALLEL         Max jobs per group to run concurrently. Defaults to 3.
  CONTINUE_ON_FAIL     1 to keep going after a failed group. Defaults to 1 (jobs are independent; use 0 to stop on first failure).
  AUDIT_MAX_RETRIES    Extra retry attempts per job on non-zero runner exit. Defaults to 2 (3 total attempts, backoff 10s/20s).
  AUDIT_RUNNER         Optional executable wrapper (overrides RUNNER). Receives: prompt_file run_dir job_id.
  DYNAMIC_DEPTH_CAP    Max depth for dynamically spawned deep-dive jobs. Defaults to 2.
                       Discovery/synthesis jobs log unexplored P0/P1 areas to pending-jobs.tsv; the launcher
                       queues them as follow-up deep-dive jobs after each group completes. Entries beyond the
                       cap are logged in pending-jobs.tsv as findings but not run.

Accessibility scanning (RUNNER=claude|codex|gemini, runtime/simulation jobs):
  ACCESSIBILITY_SCAN   1 to run axe-core accessibility scans during Playwright E2E jobs. Defaults to 1.
                       Results written to RUN_DIR/artifacts/<job_id>/accessibility/. Set to 0 to disable.

External services testing (runtime jobs):
  EXTERNAL_SERVICES_TEST  1 to probe external service connectivity during runtime verification. Defaults to 1.
                          Uses credentials from docs/ux/.creds when available. Set to 0 to disable.

Load testing (optional, auto-injected after runtime jobs):
  LOAD_TEST_ENABLED    1 to inject a load test job after all standard runtime jobs complete. Defaults to 0.
  LOAD_TEST_TARGET     Base URL to load-test. Auto-detected from docs/ux/.creds or product profile if unset.
  LOAD_TEST_TOOL       Load testing tool: k6 (default), wrk, artillery, or locust.
                       The agent installs/uses whichever tool is already present or available to install.

Security scanning (runtime jobs):
  SAST_ENABLED         1 to run SAST and dependency CVE scanning during runtime verification. Defaults to 1.
                       Runs Bandit (Python SAST), Semgrep (multi-language SAST), pip-audit, and npm audit as
                       applicable to the detected languages. Results written to RUN_DIR/artifacts/<job_id>/sast/.
                       Critical CVEs in direct dependencies or high-severity SAST findings are launch blockers.
                       Set to 0 to disable.

Performance scanning (runtime and simulation jobs):
  LIGHTHOUSE_SCAN      1 to run Lighthouse against key pages during runtime and simulation jobs. Defaults to 1.
                       Reports Core Web Vitals (LCP, CLS, INP, TTFB) and performance/accessibility/SEO scores.
                       Results written to RUN_DIR/artifacts/<job_id>/lighthouse/. Set to 0 to disable.

Codex runner (RUNNER=codex):
  CODEX_MODEL            Override model for all jobs.
  CODEX_MODEL_DISCOVERY  Defaults to gpt-5.4.
  CODEX_MODEL_SYNTHESIS  Defaults to gpt-5.5.
  CODEX_MODEL_RUNTIME    Defaults to gpt-5.4.
  CODEX_MODEL_SIMULATION Defaults to gpt-5.5.
  CODEX_MODEL_ADVERSARIAL Defaults to gpt-5.5.
  CODEX_MODEL_FINAL      Defaults to gpt-5.5.
  CODEX_REASONING_EFFORT Override reasoning effort for all jobs.
  CODEX_REASONING_DISCOVERY  Defaults to medium.
  CODEX_REASONING_SYNTHESIS  Defaults to high.
  CODEX_REASONING_RUNTIME    Defaults to medium.
  CODEX_REASONING_SIMULATION Defaults to medium.
  CODEX_REASONING_ADVERSARIAL Defaults to high.
  CODEX_REASONING_FINAL      Defaults to high.
  CODEX_PROFILE        Optional profile passed to codex exec.
  CODEX_EXTRA_ARGS     Optional extra args appended to codex exec. Split on shell words.

Claude runner (RUNNER=claude):
  CLAUDE_MODEL           Override model for all jobs.
  CLAUDE_MODEL_DISCOVERY  Defaults to claude-sonnet-4-6.
  CLAUDE_MODEL_SYNTHESIS  Defaults to claude-opus-4-7.
  CLAUDE_MODEL_RUNTIME    Defaults to claude-sonnet-4-6.
  CLAUDE_MODEL_SIMULATION Defaults to claude-opus-4-7.
  CLAUDE_MODEL_ADVERSARIAL Defaults to claude-opus-4-7.
  CLAUDE_MODEL_FINAL      Defaults to claude-opus-4-7.
  CLAUDE_EFFORT          Override effort for all jobs (low|medium|high|xhigh|max).
  CLAUDE_EFFORT_DISCOVERY  Defaults to medium.
  CLAUDE_EFFORT_SYNTHESIS  Defaults to high.
  CLAUDE_EFFORT_RUNTIME    Defaults to medium.
  CLAUDE_EFFORT_SIMULATION Defaults to medium.
  CLAUDE_EFFORT_ADVERSARIAL Defaults to high.
  CLAUDE_EFFORT_FINAL      Defaults to high.
  CLAUDE_EXTRA_ARGS      Optional extra args appended to claude. Split on shell words.

Gemini runner (RUNNER=gemini):
  GEMINI_MODEL           Override model for all jobs.
  GEMINI_MODEL_DISCOVERY  Defaults to gemini-2.5-flash.
  GEMINI_MODEL_SYNTHESIS  Defaults to gemini-2.5-pro.
  GEMINI_MODEL_RUNTIME    Defaults to gemini-2.5-flash.
  GEMINI_MODEL_SIMULATION Defaults to gemini-2.5-pro.
  GEMINI_MODEL_ADVERSARIAL Defaults to gemini-2.5-pro.
  GEMINI_MODEL_FINAL      Defaults to gemini-2.5-pro.
  GEMINI_EXTRA_ARGS      Optional extra args appended to gemini. Split on shell words.
USAGE
}

# Extract the section of a markdown file whose heading contains the ref string.
# Reads from that heading until the next heading at the same or higher level.
# Injecting the section directly avoids requiring the LLM to scan the full master
# prompt file, which would defeat the per-job budget guardrail.
extract_section() {
  local file="$1" ref="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  awk -v ref="$ref" '
    BEGIN { found=0; level=0 }
    !found && /^#+/ && index($0, ref) > 0 {
      found=1
      s=$0; n=0
      while (substr(s,1,1)=="#") { n++; s=substr(s,2) }
      level=n
      print; next
    }
    found {
      if (/^#+/) {
        s=$0; n=0
        while (substr(s,1,1)=="#") { n++; s=substr(s,2) }
        if (n<=level) { exit }
      }
      print
    }
  ' "$file"
}

FROM_GROUP=""
TO_GROUP=""
ONLY_JOB=""

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --from-group)
      FROM_GROUP="${2:?missing group}"
      shift 2
      ;;
    --to-group)
      TO_GROUP="${2:?missing group}"
      shift 2
      ;;
    --only)
      ONLY_JOB="${2:?missing job id}"
      shift 2
      ;;
    --rules)
      SHARED_PROMPT="${2:?missing rules file}"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$PROFILE" ]]; then
  _profile_dir="$PROFILE"
  [[ "$PROFILE" != /* ]] && _profile_dir="$PROFILES_DIR/$PROFILE"
  if [[ ! -d "$_profile_dir" ]]; then
    printf 'Profile not found: %s\n' "$_profile_dir" >&2; exit 2
  fi
  [[ -z "$JOBS_FILE" && -f "$_profile_dir/jobs.tsv" ]] && JOBS_FILE="$_profile_dir/jobs.tsv"
  [[ -z "$PRODUCT_PROFILE" && -f "$_profile_dir/product-profile.md" ]] && PRODUCT_PROFILE="$_profile_dir/product-profile.md"
  [[ "$SHARED_PROMPT" == "$SCRIPT_DIR/generic-shared.md" && -f "$_profile_dir/shared.md" ]] && SHARED_PROMPT="$_profile_dir/shared.md"
fi
JOBS_FILE="${JOBS_FILE:-$SCRIPT_DIR/generic-jobs.tsv}"

mkdir -p "$RUN_DIR"/{prompts,logs,artifacts,01-domain,02-cross-cutting,03-spec-additions}
CHECKPOINT_FILE="$RUN_DIR/completed-jobs.txt"

group_selected() {
  local group="$1"
  if [[ -n "$FROM_GROUP" && "$group" < "$FROM_GROUP" ]]; then
    return 1
  fi
  if [[ -n "$TO_GROUP" && "$group" > "$TO_GROUP" ]]; then
    return 1
  fi
  return 0
}

build_prompt() {
  local group="$1" job_id="$2" kind="$3" title="$4" output="$5" ref="$6"
  local prompt_file="$RUN_DIR/prompts/$job_id.md"

  # Extract the job's scope from the master prompt. Written via printf so any
  # shell-special characters in the prompt content (backticks, dollar signs) are
  # passed through literally rather than being expanded by the heredoc.
  local section_content
  section_content="$(extract_section "$MASTER_PROMPT" "$ref")"

  cat > "$prompt_file" <<HEADER
# Launch-Readiness Audit Job: $job_id

## Job Metadata

- RUN_DIR: $RUN_DIR
- Repo root: $REPO_ROOT
- Master prompt: $MASTER_PROMPT
- Product profile: ${PRODUCT_PROFILE:-"(none)"}
- Job group: $group
- Job id: $job_id
- Job kind: $kind
- Title: $title
- Required output: $RUN_DIR/$output
- Master prompt reference: $ref

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(if [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]]; then cat "$PRODUCT_PROFILE"; else printf 'No product profile was provided. If this is a generic audit, infer cautiously from repo docs and mark assumptions explicitly.'; fi)

## Job Scope

The following section from the master prompt defines this job's scope. Execute this scope only — do not read the full master prompt.

HEADER

  if [[ -n "$section_content" ]]; then
    printf '%s\n\n' "$section_content" >> "$prompt_file"
  else
    printf 'WARNING: Section "%s" was not found in %s. Locate it manually, read only that section, and proceed.\n\n' \
      "$ref" "$MASTER_PROMPT" >> "$prompt_file"
  fi

  # Synthesis, adversarial, and final jobs must ground their analysis in the
  # outputs already produced by prior discovery jobs rather than re-reading
  # source code from scratch.
  if [[ "$kind" =~ ^(synthesis|adversarial|final|simulation|web)$ ]]; then
    cat >> "$prompt_file" <<PRIOR
## Prior Discovery Outputs

Before analyzing source code, read the findings already produced by prior jobs:

- \`$RUN_DIR/01-domain/\` — domain-level discovery findings (groups 01–07)
PRIOR
    if [[ "$kind" =~ ^(adversarial|final)$ ]]; then
      printf -- '- `%s/02-cross-cutting/` — cross-cutting synthesis findings (groups 08–10)\n' \
        "$RUN_DIR" >> "$prompt_file"
    fi
    printf '\nDo not re-derive findings already captured there unless you are challenging or extending them.\n\n' \
      >> "$prompt_file"
  fi

  # ── Core job instructions ────────────────────────────────────────────────
  cat >> "$prompt_file" <<INSTRUCTIONS
## Job Instructions

Use the required output path above. If the output path contains a markdown anchor, append or update only that section in the target file. If the target file does not exist, create it with a clear heading for this job.

Budget guardrails for this job:

- The job scope is inlined in the "Job Scope" section above — do not read the full master prompt.
- Do not attempt exhaustive repo coverage in this session. This launcher intentionally splits the audit across jobs.
- Prioritize P0/P1 readiness issues over completeness.
- If you hit the budget or cannot confidently finish, write \`RESULT: INCOMPLETE\` and list the remaining exact files/workflows.
- Discovery jobs: report at most 5 findings total, ranked by severity. If you identify more, drop the lowest-priority ones and note how many were dropped. The 5-item cap applies to all reported items — do not repackage additional findings as sub-bullets, caveats, or observations.

## Exploration Boundary Protocol

When you reach the job budget, context limit, or encounter a critical unexplored module you could not fully analyze, log it as a pending deep-dive by **appending** a tab-separated row to:

\`$RUN_DIR/artifacts/pending-jobs.tsv\`

If the file does not exist, create it first with this exact tab-separated header line:

\`job_id<TAB>parent_job<TAB>depth<TAB>entry_point<TAB>files<TAB>scope<TAB>rationale\`

Then append one row per unexplored boundary with these fields (all tab-separated):

- **job_id** — unique slug, e.g. \`deep-$job_id-<topic>\` (no spaces, no slashes, no tabs)
- **parent_job** — \`$job_id\`
- **depth** — \`1\`
- **entry_point** — \`file:line\` or function/module name to start from
- **files** — comma-separated repo-relative paths for the follow-up agent to focus on
- **scope** — one sentence: what specifically to investigate
- **rationale** — one sentence: why this is a P0/P1 launch risk worth a follow-up job

Only log boundaries for P0/P1 risk areas you identified but could not finish. Do not log for completeness. The launcher queues logged entries as follow-up deep-dive jobs automatically after this group completes.

For discovery and synthesis jobs, do not run tests or start servers. For runtime and simulation jobs, run the commands/browser automation required by the master prompt and write raw outputs under:

\`$RUN_DIR/artifacts/$job_id/\`

For dev VPS browser or customer-path work, read \`docs/ux/.creds\` only as needed and redact secrets from all outputs.
INSTRUCTIONS

  # ── Accessibility scanning (runtime and simulation jobs) ─────────────────
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${ACCESSIBILITY_SCAN:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<ACCESSIBILITY

## Accessibility Scanning

For every page your Playwright browser automation visits during this job, run an axe-core accessibility scan. If `@axe-core/playwright` is available in the frontend dev dependencies, use it. Otherwise use the `axe-playwright` npm package or inject the axe-core CDN bundle via `page.addScriptTag`.

For each page scanned:

1. Call `AxeBuilder({ page }).analyze()` (or equivalent) after the page reaches a stable loaded state.
2. Record violations grouped by impact level: **critical**, **serious**, **moderate**, **minor**.
3. For each critical or serious violation, record: rule ID, element selector, WCAG criterion, and page URL.
4. Determine overall WCAG 2.1 AA conformance status for the page: pass / partial / fail.

Save the raw JSON reports to \`$RUN_DIR/artifacts/$job_id/accessibility/<page-slug>.json\`.

Write a summary table in your report output with one row per page: page URL, critical count, serious count, overall WCAG status. If axe-core is unavailable after a reasonable install attempt, record ACCESSIBILITY: UNVERIFIED and explain why.
ACCESSIBILITY
  fi

  # ── Lighthouse / Core Web Vitals (runtime and simulation jobs) ───────────
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${LIGHTHOUSE_SCAN:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<LIGHTHOUSE

## Lighthouse / Core Web Vitals

Run the Lighthouse CLI against each key page visited during this job. Derive the target base URL from the running dev server or the VPS base URL in \`docs/ux/.creds\`.

For each key page (at minimum: login, primary operator dashboard, and any page flagged as performance-sensitive in prior discovery findings):

\`\`\`bash
npx lighthouse "<page-url>" \\
  --output=json \\
  --output-path="$RUN_DIR/artifacts/$job_id/lighthouse/<page-slug>.json" \\
  --chrome-flags="--headless --no-sandbox" \\
  --only-categories=performance,accessibility,best-practices,seo \\
  --quiet
\`\`\`

For each page, extract and record:

- **Performance score** (0–100)
- **LCP** — good < 2.5s | needs-improvement 2.5–4s | poor > 4s
- **CLS** — good < 0.1 | needs-improvement 0.1–0.25 | poor > 0.25
- **INP** — good < 200ms | needs-improvement 200–500ms | poor > 500ms
- **TTFB** — good < 800ms
- **Accessibility score** (0–100, complements axe-core violation details)

A performance score < 50 or any **poor** Core Web Vital rating is a **launch blocker**.

Save raw JSON reports to \`$RUN_DIR/artifacts/$job_id/lighthouse/\`. Include a summary table in your report: page, perf score, LCP, CLS, INP, result. If Lighthouse cannot be installed via npx, record LIGHTHOUSE: UNVERIFIED.
LIGHTHOUSE
  fi

  # ── External services connectivity (runtime jobs) ────────────────────────
  if [[ "$kind" == "runtime" && "${EXTERNAL_SERVICES_TEST:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<EXTERNAL

## External Services Connectivity

Identify all external service integrations configured in the repo (OAuth providers, SaaS APIs, cloud services, SMTP/email, Slack, payment processors, identity providers, etc.) by reading environment config files, connector registrations, and integration docs.

For each integration found:

1. Check whether credentials are available in \`docs/ux/.creds\` or environment variables. If not, mark the service as UNVERIFIED and skip.
2. If credentials exist, perform a minimal connectivity check — authenticate, call a low-impact read endpoint (e.g. `/me`, `/ping`, `/status`), or verify a webhook signature round-trip.
3. Record: service name, endpoint tested, HTTP status, latency (ms), and pass/fail.
4. Redact all credential values from outputs before writing.

Save raw HTTP logs to \`$RUN_DIR/artifacts/$job_id/external-services/\`.

Include an external services table in your report: service, endpoint, status, latency, result. If no external integrations are configured, record EXTERNAL_SERVICES: none-configured.
EXTERNAL
  fi

  # ── SAST and dependency CVE scanning (runtime jobs) ──────────────────────
  if [[ "$kind" == "runtime" && "${SAST_ENABLED:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<SAST

## Static Analysis and Dependency CVE Scanning

Detect the primary languages in the repo and run all applicable tools below. Install missing tools via pip or npm as needed. Save all raw outputs to \`$RUN_DIR/artifacts/$job_id/sast/\`.

**Python SAST** (if \`*.py\` files exist — run from repo root):
\`\`\`bash
pip install bandit 2>/dev/null
bandit -r . -f json -o "$RUN_DIR/artifacts/$job_id/sast/bandit.json" -ll 2>/dev/null || true
\`\`\`

**Multi-language SAST via Semgrep**:
\`\`\`bash
pip install semgrep 2>/dev/null
semgrep --config=auto --json --output="$RUN_DIR/artifacts/$job_id/sast/semgrep.json" . 2>/dev/null || true
\`\`\`

**Python dependency CVEs** (if \`requirements*.txt\` or \`pyproject.toml\` exist):
\`\`\`bash
pip install pip-audit 2>/dev/null
pip-audit --format=json --output="$RUN_DIR/artifacts/$job_id/sast/pip-audit.json" 2>/dev/null || true
\`\`\`

**Node.js dependency CVEs** (run in each directory containing \`package.json\`):
\`\`\`bash
npm audit --json > "$RUN_DIR/artifacts/$job_id/sast/npm-audit.json" 2>/dev/null || true
\`\`\`

For each tool that produced output, report:
- Totals by severity: critical, high, medium, low
- Every **critical** and **high** finding in full: tool, CVE or rule ID, affected file or package, description, fix version if available

A critical CVE in a direct dependency, or a high-severity SAST finding with a documented exploit, is a **launch blocker**.

Include a SAST/CVE summary table in your report: tool, critical count, high count, medium count, result (pass / warn / fail).
SAST
  fi

  # ── Closing instructions (all jobs) ─────────────────────────────────────
  cat >> "$prompt_file" <<CLOSING

End with a concise final response:

\`\`\`
JOB: $job_id
REPORT: $RUN_DIR/$output
RESULT: PASS / FAIL / INCOMPLETE
TOP FINDINGS:
1. ...
BLOCKERS:
- ...
\`\`\`
CLOSING

  printf '%s\n' "$prompt_file"
}

_model_for_kind() {
  local kind="$1" override="$2"
  local disc="$3" synth="$4" runtime="$5" sim="$6" adv="$7" final="$8"
  if [[ -n "$override" ]]; then printf '%s' "$override"; return; fi
  case "$kind" in
    discovery|deep-dive) printf '%s' "$disc" ;;
    synthesis|web)       printf '%s' "$synth" ;;
    runtime|load)        printf '%s' "$runtime" ;;
    simulation)          printf '%s' "$sim" ;;
    adversarial)         printf '%s' "$adv" ;;
    final)               printf '%s' "$final" ;;
    *)                   printf '%s' "$disc" ;;
  esac
}

_run_codex() {
  local prompt_file="$1" job_id="$2" kind="$3" log_file="$4"
  local cmd=(codex)
  if [[ "$kind" == "web" ]]; then
    cmd+=(--search)
  fi
  cmd+=(exec --ephemeral --full-auto --skip-git-repo-check -C "$REPO_ROOT")
  local selected_model
  selected_model="$(_model_for_kind "$kind" "${CODEX_MODEL:-}" \
    "${CODEX_MODEL_DISCOVERY:-gpt-5.4}" "${CODEX_MODEL_SYNTHESIS:-gpt-5.5}" \
    "${CODEX_MODEL_RUNTIME:-gpt-5.4}"  "${CODEX_MODEL_SIMULATION:-gpt-5.5}" \
    "${CODEX_MODEL_ADVERSARIAL:-gpt-5.5}" "${CODEX_MODEL_FINAL:-gpt-5.5}")"
  [[ -n "$selected_model" ]] && cmd+=(-m "$selected_model")
  local selected_reasoning
  selected_reasoning="$(_model_for_kind "$kind" "${CODEX_REASONING_EFFORT:-}" \
    "${CODEX_REASONING_DISCOVERY:-medium}" "${CODEX_REASONING_SYNTHESIS:-high}" \
    "${CODEX_REASONING_RUNTIME:-medium}"  "${CODEX_REASONING_SIMULATION:-medium}" \
    "${CODEX_REASONING_ADVERSARIAL:-high}" "${CODEX_REASONING_FINAL:-high}")"
  [[ -n "$selected_reasoning" ]] && cmd+=(-c "model_reasoning_effort=\"$selected_reasoning\"")
  [[ -n "${CODEX_PROFILE:-}" ]] && cmd+=(-p "$CODEX_PROFILE")
  if [[ -n "${CODEX_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($CODEX_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  "${cmd[@]}" - <"$prompt_file" >"$log_file" 2>&1
}

_run_claude() {
  local prompt_file="$1" job_id="$2" kind="$3" log_file="$4"
  local cmd=(claude -p --verbose --output-format stream-json
    --no-session-persistence --dangerously-skip-permissions)
  local selected_model
  selected_model="$(_model_for_kind "$kind" "${CLAUDE_MODEL:-}" \
    "${CLAUDE_MODEL_DISCOVERY:-claude-sonnet-4-6}" "${CLAUDE_MODEL_SYNTHESIS:-claude-opus-4-7}" \
    "${CLAUDE_MODEL_RUNTIME:-claude-sonnet-4-6}"   "${CLAUDE_MODEL_SIMULATION:-claude-opus-4-7}" \
    "${CLAUDE_MODEL_ADVERSARIAL:-claude-opus-4-7}" "${CLAUDE_MODEL_FINAL:-claude-opus-4-7}")"
  [[ -n "$selected_model" ]] && cmd+=(--model "$selected_model")
  local selected_effort
  selected_effort="$(_model_for_kind "$kind" "${CLAUDE_EFFORT:-}" \
    "${CLAUDE_EFFORT_DISCOVERY:-medium}" "${CLAUDE_EFFORT_SYNTHESIS:-high}" \
    "${CLAUDE_EFFORT_RUNTIME:-medium}"   "${CLAUDE_EFFORT_SIMULATION:-medium}" \
    "${CLAUDE_EFFORT_ADVERSARIAL:-high}" "${CLAUDE_EFFORT_FINAL:-high}")"
  [[ -n "$selected_effort" ]] && cmd+=(--effort "$selected_effort")
  if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($CLAUDE_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  local mcp_cfg
  mcp_cfg="$(mktemp --suffix=.json)"
  printf '{"mcpServers":{}}\n' > "$mcp_cfg"
  cmd+=(--strict-mcp-config --mcp-config "$mcp_cfg")
  (
    cd "$REPO_ROOT"
    "${cmd[@]}" < "$prompt_file" | python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type', '')
        if t == 'assistant':
            for block in obj.get('message', {}).get('content', []):
                bt = block.get('type', '')
                if bt == 'text':
                    sys.stdout.write(block.get('text', ''))
                    sys.stdout.flush()
                elif bt == 'tool_use':
                    sys.stdout.write('[tool: %s]\n' % block.get('name', '?'))
                    sys.stdout.flush()
        elif t == 'result' and obj.get('is_error'):
            sys.stdout.write('[error] %s\n' % obj.get('result', 'unknown'))
            sys.stdout.flush()
    except Exception:
        pass
"
    local s="${PIPESTATUS[0]}"
    rm -f "$mcp_cfg"
    return "$s"
  ) >"$log_file" 2>&1
}

_run_gemini() {
  local prompt_file="$1" job_id="$2" kind="$3" log_file="$4"
  # --yolo: auto-approve all tool actions (equivalent to full-auto).
  # Gemini CLI has no reasoning-effort flag; model selection covers that axis.
  local cmd=(gemini --yolo)
  local selected_model
  selected_model="$(_model_for_kind "$kind" "${GEMINI_MODEL:-}" \
    "${GEMINI_MODEL_DISCOVERY:-gemini-2.5-flash}" "${GEMINI_MODEL_SYNTHESIS:-gemini-2.5-pro}" \
    "${GEMINI_MODEL_RUNTIME:-gemini-2.5-flash}"   "${GEMINI_MODEL_SIMULATION:-gemini-2.5-pro}" \
    "${GEMINI_MODEL_ADVERSARIAL:-gemini-2.5-pro}" "${GEMINI_MODEL_FINAL:-gemini-2.5-pro}")"
  [[ -n "$selected_model" ]] && cmd+=(-m "$selected_model")
  if [[ -n "${GEMINI_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($GEMINI_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  # gemini has no -C flag; same subshell workaround as the claude runner.
  (cd "$REPO_ROOT" && "${cmd[@]}" -p "$(cat "$prompt_file")") >"$log_file" 2>&1
}

run_with_spinner() {
  local job_id="$1" log_file="$2"
  shift 2

  local stall_threshold=$(( ${AUDIT_STALL_INTERVALS:-5} * ${AUDIT_HEARTBEAT_SECONDS:-60} ))
  local start_ts
  start_ts="$(date +%s)"

  set +e
  "$@" &
  local cmd_pid="$!"

  (
    local spin_chars='-\|/'
    local spin_idx=0
    local prev_size=-1
    local last_change_ts="$start_ts"
    while sleep 0.5; do
      local now elapsed size
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      local spin_char="${spin_chars:$((spin_idx % 4)):1}"
      spin_idx=$((spin_idx + 1))
      printf '\r[%s] %s (%ds)  ' "$spin_char" "$job_id" "$elapsed"
      if [[ -f "$log_file" ]]; then
        size="$(wc -c <"$log_file" | tr -d ' ')"
      else
        size=0
      fi
      if [[ "$size" -ne "$prev_size" ]]; then
        last_change_ts="$now"
        prev_size="$size"
      elif [[ "$stall_threshold" -gt 0 && "$prev_size" -ge 0 ]]; then
        local stall_secs=$((now - last_change_ts))
        if [[ "$stall_secs" -ge "$stall_threshold" ]]; then
          printf '\r[!] %s: stalled after %ds — terminating\033[K\n' "$job_id" "$elapsed" >&2
          printf '[stall-kill] log stalled after %ds — terminating\n' "$elapsed" >>"$log_file"
          kill "$cmd_pid" 2>/dev/null || true
          break
        fi
      fi
    done
  ) &
  local heartbeat_pid="$!"

  wait "$cmd_pid"
  local status="$?"
  set -e

  kill "$heartbeat_pid" >/dev/null 2>&1 || true
  wait "$heartbeat_pid" >/dev/null 2>&1 || true
  printf '\n'
  if [[ "${VERBOSE:-0}" == "1" && -f "$log_file" ]]; then
    local final_size
    final_size="$(wc -c <"$log_file" | tr -d ' ')"
    printf '    log_bytes=%s log=%s\n' "$final_size" "$log_file"
  fi
  return "$status"
}

run_prompt() {
  local prompt_file="$1" job_id="$2" kind="$3"
  local log_file="$RUN_DIR/logs/$job_id.log"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s -> %s\n' "$job_id" "$prompt_file"
    return 0
  fi

  local max_attempts=$((AUDIT_MAX_RETRIES + 1))
  local attempt=1
  local cmd_exit=0

  while ((attempt <= max_attempts)); do
    if ((attempt > 1)); then
      local backoff=$(( (attempt - 1) * 10 ))
      printf '[retry] %s attempt=%s/%s delay=%ss\n' "$job_id" "$attempt" "$max_attempts" "$backoff" >&2
      sleep "$backoff"
    fi

    cmd_exit=0
    if [[ -n "${AUDIT_RUNNER:-}" ]]; then
      run_with_spinner "$job_id" "$log_file" \
        bash -c '"$1" "$2" "$3" "$4" >"$5" 2>&1' _ \
          "$AUDIT_RUNNER" "$prompt_file" "$RUN_DIR" "$job_id" "$log_file"
      cmd_exit=$?
    else
      case "${RUNNER:-codex}" in
        codex)   run_with_spinner "$job_id" "$log_file" _run_codex  "$prompt_file" "$job_id" "$kind" "$log_file"; cmd_exit=$? ;;
        claude)  run_with_spinner "$job_id" "$log_file" _run_claude "$prompt_file" "$job_id" "$kind" "$log_file"; cmd_exit=$? ;;
        gemini)  run_with_spinner "$job_id" "$log_file" _run_gemini "$prompt_file" "$job_id" "$kind" "$log_file"; cmd_exit=$? ;;
        *)
          printf 'Unknown RUNNER "%s" — must be codex, claude, or gemini\n' "${RUNNER}" >&2
          return 1
          ;;
      esac
    fi

    if ((cmd_exit == 0)); then
      break
    fi
    attempt=$((attempt + 1))
  done

  # Discovery, synthesis, and deep-dive jobs are read-only audit phases — they must not
  # modify source files. Detect any changes and revert them so an over-eager
  # agent can't corrupt the repo or the audit baseline. Integrity check runs
  # only after the final attempt so retries on a clean repo still get caught.
  if [[ "$kind" =~ ^(discovery|synthesis|web|deep-dive)$ ]]; then
    if git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null; then
      if ! git -C "$REPO_ROOT" diff --exit-code --quiet 2>>"$log_file"; then
        printf '\nAUDIT INTEGRITY VIOLATION: job %s modified source files; reverting\n' "$job_id" >>"$log_file"
        git -C "$REPO_ROOT" checkout -- . >>"$log_file" 2>&1
        return 1
      fi
    fi
  fi

  return "$cmd_exit"
}

current_group=""
declare -a group_pids=()
declare -a group_names=()
declare -a group_outputs=()
active_count=0

flush_group() {
  if ((${#group_pids[@]} == 0)); then
    return 0
  fi
  printf 'Waiting for group %s (%d job(s))...\n' "$current_group" "${#group_pids[@]}"
  local flush_failed=0

  for idx in "${!group_pids[@]}"; do
    local pid="${group_pids[$idx]}"
    local name="${group_names[$idx]}"
    local job_passed=1

    if wait "$pid"; then
      printf '[ok] %s\n' "$name"
    else
      printf '[fail] %s (see %s/logs/%s.log)\n' "$name" "$RUN_DIR" "$name" >&2
      flush_failed=1
      job_passed=0
    fi

    # Verify each job actually wrote its required output file. An exit-0 job
    # that never wrote the report is a silent failure — catch it here.
    if [[ "$DRY_RUN" != "1" && -n "${group_outputs[$idx]}" ]]; then
      local expected_path="$RUN_DIR/${group_outputs[$idx]%%#*}"
      if [[ ! -f "$expected_path" ]]; then
        printf '[missing-output] %s: expected %s\n' "$name" "$expected_path" >&2
        flush_failed=1
        job_passed=0
      fi
    fi

    # Write to checkpoint only when both exit code and output check passed.
    # Future runs skip this job during --resume or accidental re-runs.
    if ((job_passed)) && [[ "$DRY_RUN" != "1" ]]; then
      printf '%s\n' "$name" >> "$CHECKPOINT_FILE"
    fi
  done

  if ((flush_failed)) && [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
    exit 1
  fi
  group_pids=()
  group_names=()
  group_outputs=()
  active_count=0
}

# ── Dynamic deep-dive spawning ─────────────────────────────────────────────
# Discovery/synthesis jobs write unexplored P0/P1 boundaries to
# $RUN_DIR/artifacts/pending-jobs.tsv. After each group and at the end of the
# run, drain_pending_jobs() reads that file, deduplicates against already-
# queued entries, and spawns follow-up deep-dive jobs up to DYNAMIC_DEPTH_CAP.

_DRAIN_STARTED=0

build_deep_dive_prompt() {
  local job_id="$1" parent_job="$2" depth="$3" entry_point="$4" files="$5" scope="$6" rationale="$7"
  local prompt_file="$RUN_DIR/prompts/$job_id.md"
  local output="01-domain/$job_id.md"
  local next_depth=$(( depth + 1 ))

  cat > "$prompt_file" <<DDHEADER
# Launch-Readiness Audit Deep-Dive: $job_id

## Job Metadata

- RUN_DIR: $RUN_DIR
- Repo root: $REPO_ROOT
- Job id: $job_id
- Job kind: deep-dive
- Depth: $depth / ${DYNAMIC_DEPTH_CAP} (cap)
- Parent job: $parent_job
- Required output: $RUN_DIR/$output

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(if [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]]; then cat "$PRODUCT_PROFILE"; else printf 'No product profile provided. Infer cautiously from repo docs and mark assumptions explicitly.'; fi)

## Prior Discovery Outputs

Ground your analysis in findings already produced by prior jobs before reading source code:

- \`$RUN_DIR/01-domain/\` — domain-level discovery findings; start with the parent job output at \`$RUN_DIR/01-domain/$parent_job.md\`

Do not re-derive findings already captured there unless you are directly challenging or extending them.

## Deep-Dive Scope

This job was queued by **$parent_job** because it reached an exploration boundary.

- **Entry point**: $entry_point
- **Files**: $files
- **Scope**: $scope
- **Rationale**: $rationale

## Job Instructions

Focus exclusively on the scope above. Do not re-read or re-examine areas already covered by the parent job.

Budget guardrails:
- Prioritize P0/P1 readiness issues only.
- Report at most 5 findings, ranked by severity.
- Do not run tests or start servers.

DDHEADER

  if (( depth < DYNAMIC_DEPTH_CAP )); then
    cat >> "$prompt_file" <<DDPROTOCOL
## Exploration Boundary Protocol

If you reach a sub-boundary that is materially P0/P1 relevant and cannot be finished in this job, append a tab-separated row to \`$RUN_DIR/artifacts/pending-jobs.tsv\`:

Fields (tab-separated): **job_id**, **parent_job**, **depth**, **entry_point**, **files**, **scope**, **rationale**

Use **depth=$next_depth** and **parent_job=$job_id**. Only log genuine P0/P1 gaps. The launcher will queue them automatically.

DDPROTOCOL
  else
    printf 'You are at the maximum spawn depth (%s). Do not append to pending-jobs.tsv — record remaining gaps as findings in your report instead.\n\n' \
      "${DYNAMIC_DEPTH_CAP}" >> "$prompt_file"
  fi

  cat >> "$prompt_file" <<DDEND
End with a concise final response:

\`\`\`
JOB: $job_id
REPORT: $RUN_DIR/$output
RESULT: PASS / FAIL / INCOMPLETE
TOP FINDINGS:
1. ...
BLOCKERS:
- ...
\`\`\`
DDEND

  printf '%s\n' "$prompt_file"
}

drain_pending_jobs() {
  _DRAIN_STARTED=0
  local pending_file="$RUN_DIR/artifacts/pending-jobs.tsv"
  [[ -f "$pending_file" ]] || return 0

  local queued_file="$RUN_DIR/artifacts/queued-deep-dives.txt"
  touch "$queued_file"

  # Reuse the global group arrays (guaranteed empty after flush_group).
  # Set current_group to "dynamic" so flush_group prints a clear label.
  local saved_group="$current_group"
  current_group="dynamic"

  while IFS=$'\t' read -r dj_id parent_job depth entry_point files scope rationale; do
    # Skip header and blank/malformed rows.
    [[ -z "${dj_id:-}" || "$dj_id" == "job_id" ]] && continue
    local depth_int="${depth:-1}"
    [[ "$depth_int" =~ ^[0-9]+$ ]] || continue

    if (( depth_int > DYNAMIC_DEPTH_CAP )); then
      printf '[deep-dive] depth-capped: %s (depth=%s cap=%s)\n' "$dj_id" "$depth_int" "$DYNAMIC_DEPTH_CAP"
      continue
    fi

    if grep -qxF "$dj_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      printf '[resume] skipping completed deep-dive %s\n' "$dj_id"
      continue
    fi

    if grep -qxF "$dj_id" "$queued_file" 2>/dev/null; then
      continue
    fi

    local prompt_file
    prompt_file="$(build_deep_dive_prompt "$dj_id" "$parent_job" "$depth_int" "$entry_point" "$files" "$scope" "$rationale")"
    printf '[start] group=dynamic job=%s kind=deep-dive depth=%s parent=%s\n' "$dj_id" "$depth_int" "$parent_job"

    printf '%s\n' "$dj_id" >> "$queued_file"
    _DRAIN_STARTED=$(( _DRAIN_STARTED + 1 ))

    run_prompt "$prompt_file" "$dj_id" "deep-dive" &
    group_pids+=("$!")
    group_names+=("$dj_id")
    group_outputs+=("01-domain/$dj_id.md")
    active_count=$(( active_count + 1 ))

    if (( active_count >= MAX_PARALLEL )); then
      flush_group
      current_group="dynamic"
    fi
  done < "$pending_file"

  flush_group
  current_group="$saved_group"
}

# ── Optional load testing ──────────────────────────────────────────────────
# Auto-injected after all standard runtime/simulation jobs when LOAD_TEST_ENABLED=1.
# Uses the same global group arrays as flush_group; must be called after flush_group
# empties them.

build_load_test_prompt() {
  local job_id="load-test"
  local prompt_file="$RUN_DIR/prompts/$job_id.md"
  local output="artifacts/load-test/load-test-report.md"
  local tool="${LOAD_TEST_TOOL:-k6}"
  local target="${LOAD_TEST_TARGET:-}"

  mkdir -p "$RUN_DIR/artifacts/load-test"

  cat > "$prompt_file" <<LTHEAD
# Launch-Readiness Audit: Load Test

## Job Metadata

- RUN_DIR: $RUN_DIR
- Repo root: $REPO_ROOT
- Job id: $job_id
- Job kind: load
- Required output: $RUN_DIR/$output

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(if [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]]; then cat "$PRODUCT_PROFILE"; else printf 'No product profile provided. Infer the base URL from docs/ux/.creds or deployment docs.'; fi)

## Prior Discovery Outputs

Ground your test scenarios in findings from prior jobs:

- \`$RUN_DIR/10-runtime-verification.md\` — runtime verification results
- \`$RUN_DIR/11-maturity-stage-simulation.md\` — customer journey simulation results
- \`$RUN_DIR/01-domain/\` — domain discovery findings

## Load Test Scope

**Tool preference**: ${tool}. Use whichever of k6, wrk, artillery, or locust is already installed, or install the preferred tool if it is not present.

**Target base URL**: ${target:-"(auto-detect from docs/ux/.creds or deployment docs — read APP_URL, BASE_URL, or equivalent)"}

### Test Scenarios

Run three scenarios against the target:

1. **Baseline** — 10 virtual users, 60 seconds steady state. Establishes per-request latency baseline.
2. **Ramp** — ramp from 1 to 50 VUs over 2 minutes, hold 1 minute, ramp down. Identifies the throughput ceiling and where latency degrades.
3. **Spike** — jump to 100 VUs for 30 seconds. Tests resilience under sudden traffic bursts.

For each scenario, target the following critical endpoints identified from prior discovery:
- Auth/login endpoint
- Primary read API endpoint (tenant dashboard, list endpoint, or equivalent)
- Primary write/mutation endpoint
- Any endpoint flagged as a latency risk in prior discovery findings

Read docs/ux/.creds for auth credentials. Redact all credential values from outputs.

### Thresholds

Flag as FAIL if any scenario exceeds:
- p95 response time > 2000ms for API endpoints
- p99 response time > 5000ms
- Error rate > 1% under baseline or ramp
- Error rate > 5% under spike

If the product profile specifies SLO targets, use those instead.

### Outputs

Save raw tool output and any generated script to \`$RUN_DIR/artifacts/load-test/\`.

Write \`$RUN_DIR/$output\` with:
- Summary table: scenario, VUs, duration, p50, p95, p99 latency, throughput (req/s), error rate, result
- Bottleneck analysis: which endpoint degraded first and at what VU count
- Comparison to thresholds: pass / fail / partial per scenario
- Any errors encountered (HTTP 5xx, connection resets, timeouts)

## Job Instructions

Do not modify source files. Run only read or simulated-traffic operations.

End with a concise final response:

\`\`\`
JOB: $job_id
REPORT: $RUN_DIR/$output
RESULT: PASS / FAIL / INCOMPLETE
TOP FINDINGS:
1. ...
BLOCKERS:
- ...
\`\`\`
LTHEAD

  printf '%s\n' "$prompt_file"
}

run_load_test_job() {
  if grep -qxF "load-test" "$CHECKPOINT_FILE" 2>/dev/null; then
    printf '[resume] skipping completed job load-test\n'
    return 0
  fi

  local prompt_file
  prompt_file="$(build_load_test_prompt)"
  printf '[start] group=load job=load-test kind=load tool=%s\n' "${LOAD_TEST_TOOL:-k6}"

  current_group="load"
  run_prompt "$prompt_file" "load-test" "load" &
  group_pids+=("$!")
  group_names+=("load-test")
  group_outputs+=("artifacts/load-test/load-test-report.md")
  active_count=$(( active_count + 1 ))
  flush_group
}

write_run_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local summary="$RUN_DIR/00-run-summary.tsv"
  local total=0 pass=0 incomplete=0 fail=0

  printf 'job_id\tkind\tresult\n' > "$summary"

  while IFS=$'\t' read -r group job_id kind _title _output _ref; do
    [[ -z "${job_id:-}" ]] && continue
    if [[ -n "$ONLY_JOB" && "$job_id" != "$ONLY_JOB" ]]; then continue; fi
    if ! group_selected "$group"; then continue; fi

    local log="$RUN_DIR/logs/$job_id.log"
    local result
    if grep -qxF "$job_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      result="$(grep -o 'RESULT:[[:space:]]*[A-Za-z/]*' "$log" 2>/dev/null | tail -1 | sed 's/.*RESULT:[[:space:]]*//')"
      [[ -z "$result" ]] && result="completed"
    elif [[ -f "$log" ]]; then
      result="FAIL"
    else
      result="not-run"
    fi

    printf '%s\t%s\t%s\n' "$job_id" "$kind" "$result" >> "$summary"
    total=$((total + 1))
    case "$result" in
      PASS|completed) pass=$((pass + 1)) ;;
      INCOMPLETE) incomplete=$((incomplete + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done < <(tail -n +2 "$JOBS_FILE")

  # Include dynamically-spawned deep-dive jobs in the summary.
  local queued_file="$RUN_DIR/artifacts/queued-deep-dives.txt"
  if [[ -f "$queued_file" ]]; then
    while IFS= read -r dj_id; do
      [[ -z "${dj_id:-}" ]] && continue
      local dj_log="$RUN_DIR/logs/$dj_id.log"
      local dj_result
      if grep -qxF "$dj_id" "$CHECKPOINT_FILE" 2>/dev/null; then
        dj_result="$(grep -o 'RESULT:[[:space:]]*[A-Za-z/]*' "$dj_log" 2>/dev/null | tail -1 | sed 's/.*RESULT:[[:space:]]*//')"
        [[ -z "$dj_result" ]] && dj_result="completed"
      elif [[ -f "$dj_log" ]]; then
        dj_result="FAIL"
      else
        dj_result="not-run"
      fi
      printf '%s\t%s\t%s\n' "$dj_id" "deep-dive" "$dj_result" >> "$summary"
      total=$(( total + 1 ))
      case "$dj_result" in
        PASS|completed) pass=$(( pass + 1 )) ;;
        INCOMPLETE) incomplete=$(( incomplete + 1 )) ;;
        *) fail=$(( fail + 1 )) ;;
      esac
    done < "$queued_file"
  fi

  # Include auto-injected load test job if it ran.
  if [[ "${LOAD_TEST_ENABLED:-0}" == "1" ]]; then
    local lt_log="$RUN_DIR/logs/load-test.log"
    local lt_result
    if grep -qxF "load-test" "$CHECKPOINT_FILE" 2>/dev/null; then
      lt_result="$(grep -o 'RESULT:[[:space:]]*[A-Za-z/]*' "$lt_log" 2>/dev/null | tail -1 | sed 's/.*RESULT:[[:space:]]*//')"
      [[ -z "$lt_result" ]] && lt_result="completed"
    elif [[ -f "$lt_log" ]]; then
      lt_result="FAIL"
    else
      lt_result="not-run"
    fi
    printf '%s\t%s\t%s\n' "load-test" "load" "$lt_result" >> "$summary"
    total=$(( total + 1 ))
    case "$lt_result" in
      PASS|completed) pass=$(( pass + 1 )) ;;
      INCOMPLETE) incomplete=$(( incomplete + 1 )) ;;
      *) fail=$(( fail + 1 )) ;;
    esac
  fi

  printf '\n=== Audit Run Summary (%d jobs) ===\n' "$total"
  printf 'PASS/completed: %d  INCOMPLETE: %d  FAIL/not-run: %d\n' "$pass" "$incomplete" "$fail"
  if ((incomplete > 0 || fail > 0)); then
    printf 'Non-pass:\n'
    awk -F'\t' 'NR>1 && $3 !~ /^(PASS|completed)$/ { printf "  %s (%s): %s\n", $1, $2, $3 }' "$summary"
  fi
  printf 'Summary: %s\n' "$summary"
  printf '===================================\n'
}

printf 'Audit run directory: %s\n' "$RUN_DIR"
printf 'Job manifest: %s\n' "$JOBS_FILE"

{
  read -r _header
  while IFS=$'\t' read -r group job_id kind title output ref; do
    [[ -z "${group:-}" ]] && continue
    if [[ -n "$ONLY_JOB" && "$job_id" != "$ONLY_JOB" ]]; then
      continue
    fi
    if ! group_selected "$group"; then
      continue
    fi

    if [[ -z "$current_group" ]]; then
      current_group="$group"
    elif [[ "$group" != "$current_group" ]]; then
      flush_group
      drain_pending_jobs
      current_group="$group"
    fi

    if grep -qxF "$job_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      printf '[resume] skipping completed job %s\n' "$job_id"
      continue
    fi

    prompt_file="$(build_prompt "$group" "$job_id" "$kind" "$title" "$output" "$ref")"
    printf '[start] group=%s job=%s kind=%s title=%s\n' "$group" "$job_id" "$kind" "$title"

    run_prompt "$prompt_file" "$job_id" "$kind" &
    group_pids+=("$!")
    group_names+=("$job_id")
    group_outputs+=("$output")
    active_count=$((active_count + 1))

    if ((active_count >= MAX_PARALLEL)); then
      flush_group
    fi
  done
} < "$JOBS_FILE"

flush_group

# Optional load test — runs after all standard runtime/simulation jobs complete
# so the agent can ground its scenario selection in prior discovery findings.
if [[ "${LOAD_TEST_ENABLED:-0}" == "1" ]]; then
  run_load_test_job
fi

# Drain any pending deep-dives accumulated during the run. Loop until stable:
# depth-1 jobs run first; their completions may add depth-2 entries to
# pending-jobs.tsv, which the next drain pass picks up. Stops when no new
# jobs are started (all entries are depth-capped, already queued, or done).
drain_pending_jobs
while (( _DRAIN_STARTED > 0 )); do
  drain_pending_jobs
done

write_run_summary
printf 'Audit launcher complete. Run directory: %s\n' "$RUN_DIR"
