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

  cat >> "$prompt_file" <<INSTRUCTIONS
## Job Instructions

Use the required output path above. If the output path contains a markdown anchor, append or update only that section in the target file. If the target file does not exist, create it with a clear heading for this job.

Budget guardrails for this job:

- The job scope is inlined in the "Job Scope" section above — do not read the full master prompt.
- Do not attempt exhaustive repo coverage in this session. This launcher intentionally splits the audit across jobs.
- Prioritize P0/P1 readiness issues over completeness.
- If you hit the budget or cannot confidently finish, write \`RESULT: INCOMPLETE\` and list the remaining exact files/workflows.
- Discovery jobs: report at most 5 findings total, ranked by severity. If you identify more, drop the lowest-priority ones and note how many were dropped. The 5-item cap applies to all reported items — do not repackage additional findings as sub-bullets, caveats, or observations.

For discovery and synthesis jobs, do not run tests or start servers. For runtime and simulation jobs, run the commands/browser automation required by the master prompt and write raw outputs under:

\`$RUN_DIR/artifacts/$job_id/\`

For dev VPS browser or customer-path work, read \`docs/ux/.creds\` only as needed and redact secrets from all outputs.

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
INSTRUCTIONS

  printf '%s\n' "$prompt_file"
}

_model_for_kind() {
  local kind="$1" override="$2"
  local disc="$3" synth="$4" runtime="$5" sim="$6" adv="$7" final="$8"
  if [[ -n "$override" ]]; then printf '%s' "$override"; return; fi
  case "$kind" in
    discovery)          printf '%s' "$disc" ;;
    synthesis|web)      printf '%s' "$synth" ;;
    runtime)            printf '%s' "$runtime" ;;
    simulation)         printf '%s' "$sim" ;;
    adversarial)        printf '%s' "$adv" ;;
    final)              printf '%s' "$final" ;;
    *)                  printf '%s' "$disc" ;;
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

  # Discovery and synthesis jobs are read-only audit phases — they must not
  # modify source files. Detect any changes and revert them so an over-eager
  # agent can't corrupt the repo or the audit baseline. Integrity check runs
  # only after the final attempt so retries on a clean repo still get caught.
  if [[ "$kind" =~ ^(discovery|synthesis|web)$ ]]; then
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

write_run_summary
printf 'Audit launcher complete. Run directory: %s\n' "$RUN_DIR"
