#!/usr/bin/env bash
# shellcheck disable=SC2016
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
AUDIT_TOOLING_AUTO_INSTALL="${AUDIT_TOOLING_AUTO_INSTALL:-1}"
AUDIT_TOOLING_VENV="${AUDIT_TOOLING_VENV:-$RUN_DIR/.audit-tooling/venv}"
AUDIT_NODE_TOOLING_AUTO_INSTALL="${AUDIT_NODE_TOOLING_AUTO_INSTALL:-1}"
AUDIT_NODE_TOOLING_DIR="${AUDIT_NODE_TOOLING_DIR:-$RUN_DIR/.audit-tooling/node}"
AUDIT_BASE_URL="${AUDIT_BASE_URL:-}"
ACCESSIBILITY_PATHS="${ACCESSIBILITY_PATHS:-/,/login}"
LIGHTHOUSE_PATHS="${LIGHTHOUSE_PATHS:-/,/login}"
LOAD_TEST_PATHS="${LOAD_TEST_PATHS:-/}"
EXTERNAL_SERVICE_TIMEOUT="${EXTERNAL_SERVICE_TIMEOUT:-10}"
SAST_BANDIT_TIMEOUT="${SAST_BANDIT_TIMEOUT:-300}"
SAST_SEMGREP_TIMEOUT="${SAST_SEMGREP_TIMEOUT:-600}"
SAST_PIP_AUDIT_TIMEOUT="${SAST_PIP_AUDIT_TIMEOUT:-300}"
SAST_NPM_AUDIT_TIMEOUT="${SAST_NPM_AUDIT_TIMEOUT:-300}"

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
  AUDIT_TOOLING_AUTO_INSTALL
                       1 to auto-install missing native Python audit tooling into AUDIT_TOOLING_VENV.
                       Defaults to 1. Set to 0 to require preinstalled tooling.
  AUDIT_TOOLING_VENV   Virtualenv path used for native audit tooling installs. Defaults to
                       RUN_DIR/.audit-tooling/venv.
  AUDIT_NODE_TOOLING_AUTO_INSTALL
                       1 to auto-install missing native Node/browser tooling into AUDIT_NODE_TOOLING_DIR.
                       Defaults to 1. Set to 0 to require preinstalled tooling.
  AUDIT_NODE_TOOLING_DIR
                       Tooling directory used for native Lighthouse/accessibility dependencies.
                       Defaults to RUN_DIR/.audit-tooling/node.
  AUDIT_BASE_URL       Optional explicit base URL for native runtime/simulation/load probes.
  ACCESSIBILITY_PATHS  Comma-separated paths or absolute URLs for native axe scans. Defaults to /,/login.
  LIGHTHOUSE_PATHS     Comma-separated paths or absolute URLs for native Lighthouse runs. Defaults to /,/login.
  LOAD_TEST_PATHS      Comma-separated paths or absolute URLs targeted by the native load-test runner.
                       Defaults to /.
  EXTERNAL_SERVICE_TIMEOUT
                       Timeout in seconds for native external-service probes. Defaults to 10.

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

audit_readonly_kind() {
  [[ "$1" =~ ^(discovery|synthesis|web|deep-dive)$ ]]
}

audit_relative_run_dir() {
  if [[ "$RUN_DIR" == "$REPO_ROOT/"* ]]; then
    printf '%s\n' "${RUN_DIR#"$REPO_ROOT/"}"
  fi
}

audit_readonly_diff_snapshot() {
  local rel_run_dir
  rel_run_dir="$(audit_relative_run_dir)"
  local pathspec=(.)
  if [[ -n "$rel_run_dir" ]]; then
    pathspec+=(":(exclude)$rel_run_dir")
  fi
  git -C "$REPO_ROOT" status --porcelain=v1 -uall -- "${pathspec[@]}"
}

audit_restore_readonly_changes() {
  local rel_run_dir
  rel_run_dir="$(audit_relative_run_dir)"
  local pathspec=(.)
  if [[ -n "$rel_run_dir" ]]; then
    pathspec+=(":(exclude)$rel_run_dir")
  fi

  local restore_list
  restore_list="$(mktemp)"
  {
    git -C "$REPO_ROOT" diff --name-only -- "${pathspec[@]}"
    git -C "$REPO_ROOT" diff --cached --name-only -- "${pathspec[@]}"
  } | awk 'NF && !seen[$0]++ { print }' > "$restore_list"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    git -C "$REPO_ROOT" restore --source=HEAD --staged --worktree -- "$path" >/dev/null 2>&1 || true
  done < "$restore_list"
  rm -f "$restore_list"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -rf "${REPO_ROOT:?}/$path"
  done < <(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${pathspec[@]}")
}

trim_inline_value() {
  local value="$1"
  value="${value#\`}"
  value="${value%\`}"
  value="${value#\"}"
  value="${value%\"}"
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\n' "$value"
}

profile_section_values() {
  local section="$1" key="$2"
  [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]] || return 0
  awk -v section="$section" -v key="$key" '
    BEGIN { in_section = 0; capture = 0 }
    /^## / {
      line = $0
      sub(/^##[[:space:]]+/, "", line)
      if (in_section && line != section) exit
      in_section = (line == section)
      capture = 0
      next
    }
    !in_section { next }
    $0 ~ "^- " key ":" {
      line = $0
      sub("^- " key ":[[:space:]]*", "", line)
      if (line != "") print line
      capture = 1
      next
    }
    capture {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^- /) {
        capture = 0
        next
      }
      if ($0 ~ /^[[:space:]][[:space:]]*-[[:space:]]+/) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        print line
        next
      }
      if ($0 ~ /^[[:space:]]+/) {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        print line
        next
      }
      capture = 0
    }
  ' "$PRODUCT_PROFILE"
}

extract_first_url() {
  local text="$1"
  printf '%s\n' "$text" | grep -Eo 'https?://[^[:space:]`")]+'
}

profile_runtime_value() {
  local key="$1"
  local value
  value="$(profile_section_values "Runtime Verification" "$key" | head -1)"
  trim_inline_value "$value"
}

audit_creds_file() {
  local creds="$REPO_ROOT/docs/ux/.creds"
  [[ -f "$creds" ]] || return 1
  printf '%s\n' "$creds"
}

audit_cred_value() {
  local key="$1"
  local creds
  creds="$(audit_creds_file 2>/dev/null)" || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }' "$creds"
}

detect_base_url() {
  if [[ -n "${AUDIT_BASE_URL:-}" ]]; then
    printf '%s\n' "$AUDIT_BASE_URL"
    return 0
  fi
  local key value
  for key in APP_URL BASE_URL APPLICATION_URL STAGING_URL DEV_URL; do
    value="$(audit_cred_value "$key" 2>/dev/null || true)"
    value="$(trim_inline_value "$value")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  value="$(profile_runtime_value "Dev/staging URL and credential source, if any")"
  value="$(extract_first_url "$value" | head -1)"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

csv_to_unique_lines() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

join_url() {
  local base="$1" path="$2"
  if [[ "$path" =~ ^https?:// ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ -z "$base" ]]; then
    return 1
  fi
  base="${base%/}"
  if [[ "$path" == /* ]]; then
    printf '%s%s\n' "$base" "$path"
  else
    printf '%s/%s\n' "$base" "$path"
  fi
}

collect_target_urls() {
  local base_url="$1" paths_csv="$2"
  local path
  while IFS= read -r path; do
    path="$(trim_inline_value "$path")"
    [[ -n "$path" ]] || continue
    join_url "$base_url" "$path"
  done < <(csv_to_unique_lines "$paths_csv") | awk 'NF && !seen[$0]++ { print }'
}

slugify() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's#https\?://##; s#[^a-z0-9]\+#-#g; s#^-##; s#-$##')"
  [[ -n "$raw" ]] || raw="page"
  printf '%s\n' "$raw"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

audit_tooling_bin() {
  printf '%s/bin/%s\n' "$AUDIT_TOOLING_VENV" "$1"
}

audit_tooling_pip() {
  audit_tooling_bin pip
}

audit_ensure_python_tool_venv() {
  [[ -x "$(audit_tooling_pip)" ]] && return 0
  command_exists python3 || return 1
  mkdir -p "$(dirname "$AUDIT_TOOLING_VENV")"
  python3 -m venv "$AUDIT_TOOLING_VENV" >/dev/null 2>&1 || return 1
}

audit_install_python_tool() {
  local package="$1" log_file="$2"
  if [[ "${AUDIT_TOOLING_AUTO_INSTALL:-1}" != "1" ]]; then
    printf '[native-tooling] auto-install disabled; missing package=%s\n' "$package" >> "$log_file"
    return 1
  fi
  if ! audit_ensure_python_tool_venv; then
    printf '[native-tooling] failed to create tooling venv at %s for package=%s\n' "$AUDIT_TOOLING_VENV" "$package" >> "$log_file"
    return 1
  fi
  printf '[native-tooling] installing %s into %s\n' "$package" "$AUDIT_TOOLING_VENV" >> "$log_file"
  "$(audit_tooling_pip)" install "$package" >> "$log_file" 2>&1 || {
    printf '[native-tooling] install failed for %s\n' "$package" >> "$log_file"
    return 1
  }
}

audit_ensure_python_tool() {
  local cmd_name="$1" package="$2" log_file="$3"
  if command_exists "$cmd_name"; then
    return 0
  fi
  local tool_path
  tool_path="$(audit_tooling_bin "$cmd_name")"
  if [[ -x "$tool_path" ]]; then
    return 0
  fi
  audit_install_python_tool "$package" "$log_file" || return 1
  [[ -x "$tool_path" ]]
}

audit_resolve_python_tool() {
  local cmd_name="$1"
  if command_exists "$cmd_name"; then
    command -v "$cmd_name"
    return 0
  fi
  local tool_path
  tool_path="$(audit_tooling_bin "$cmd_name")"
  [[ -x "$tool_path" ]] || return 1
  printf '%s\n' "$tool_path"
}

audit_node_bin() {
  printf '%s/node_modules/.bin/%s\n' "$AUDIT_NODE_TOOLING_DIR" "$1"
}

audit_ensure_node_project() {
  command_exists node || return 1
  command_exists npm || return 1
  mkdir -p "$AUDIT_NODE_TOOLING_DIR"
  if [[ ! -f "$AUDIT_NODE_TOOLING_DIR/package.json" ]]; then
    (cd "$AUDIT_NODE_TOOLING_DIR" && npm init -y >/dev/null 2>&1) || return 1
  fi
}

audit_node_package_dir() {
  local package="$1"
  printf '%s/node_modules/%s\n' "$AUDIT_NODE_TOOLING_DIR" "$package"
}

audit_node_package_present() {
  [[ -d "$(audit_node_package_dir "$1")" ]]
}

audit_install_node_packages() {
  local log_file="$1"
  shift
  [[ "${AUDIT_NODE_TOOLING_AUTO_INSTALL:-1}" == "1" ]] || {
    printf '[native-tooling] node auto-install disabled; missing packages=%s\n' "$*" >> "$log_file"
    return 1
  }
  audit_ensure_node_project || {
    printf '[native-tooling] failed to initialize node tooling dir %s\n' "$AUDIT_NODE_TOOLING_DIR" >> "$log_file"
    return 1
  }
  printf '[native-tooling] installing node packages into %s: %s\n' "$AUDIT_NODE_TOOLING_DIR" "$*" >> "$log_file"
  (cd "$AUDIT_NODE_TOOLING_DIR" && npm install --no-save "$@") >> "$log_file" 2>&1 || {
    printf '[native-tooling] node install failed for packages=%s\n' "$*" >> "$log_file"
    return 1
  }
}

audit_ensure_node_packages() {
  local log_file="$1"
  shift
  local missing=()
  local package
  for package in "$@"; do
    audit_node_package_present "$package" || missing+=("$package")
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  audit_install_node_packages "$log_file" "${missing[@]}"
}

audit_ensure_node_bin() {
  local bin_name="$1" log_file="$2"
  shift 2
  if command_exists "$bin_name"; then
    return 0
  fi
  local tool_path
  tool_path="$(audit_node_bin "$bin_name")"
  if [[ -x "$tool_path" ]]; then
    return 0
  fi
  audit_install_node_packages "$log_file" "$@" || return 1
  [[ -x "$tool_path" ]]
}

audit_resolve_node_bin() {
  local bin_name="$1"
  if command_exists "$bin_name"; then
    command -v "$bin_name"
    return 0
  fi
  local tool_path
  tool_path="$(audit_node_bin "$bin_name")"
  [[ -x "$tool_path" ]] || return 1
  printf '%s\n' "$tool_path"
}

audit_ensure_playwright_chromium() {
  local log_file="$1"
  audit_ensure_node_bin "playwright" "$log_file" "playwright" || return 1
  local browser_dir="$AUDIT_NODE_TOOLING_DIR/playwright-browsers"
  if [[ -d "$browser_dir" ]] && find "$browser_dir" -mindepth 1 -maxdepth 1 -type d | read -r; then
    return 0
  fi
  [[ "${AUDIT_NODE_TOOLING_AUTO_INSTALL:-1}" == "1" ]] || {
    printf '[native-tooling] browser auto-install disabled; chromium not present\n' >> "$log_file"
    return 1
  }
  printf '[native-tooling] installing playwright chromium into %s\n' "$browser_dir" >> "$log_file"
  PLAYWRIGHT_BROWSERS_PATH="$browser_dir" "$(audit_resolve_node_bin "playwright")" install chromium >> "$log_file" 2>&1 || {
    printf '[native-tooling] playwright chromium install failed\n' >> "$log_file"
    return 1
  }
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

  if [[ "$kind" =~ ^(adversarial|final)$ ]]; then
    cat >> "$prompt_file" <<UXGATE
## UX, Browser, Accessibility, and Lighthouse Gate

The harness maintains a deterministic UX/browser evidence summary at:

- \`$RUN_DIR/artifacts/ux-browser-gate-summary.md\`
- \`$RUN_DIR/artifacts/ux-browser-gate-summary.tsv\`

Read this gate summary before issuing launch posture. Treat broken or unverified critical browser, accessibility, Lighthouse, route/navigation, API/UI wiring, and console-error evidence as release-decision inputs, not as optional UX polish.

UXGATE
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

For discovery and synthesis jobs, do not run tests or start servers. For runtime and simulation jobs, analyze the native harness artifacts under:

\`$RUN_DIR/artifacts/$job_id/\`

For dev VPS browser or customer-path work, read \`docs/ux/.creds\` only as needed and redact secrets from all outputs.
INSTRUCTIONS

  # ── Accessibility scanning (runtime and simulation jobs) ─────────────────
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${ACCESSIBILITY_SCAN:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<ACCESSIBILITY

## Accessibility Scanning

The harness has already attempted native axe scans against the configured accessibility target URLs.

Required evidence inputs:

- Raw JSON reports: \`$RUN_DIR/artifacts/$job_id/accessibility/<page-slug>.json\`
- Native summary: \`$RUN_DIR/artifacts/$job_id/accessibility/summary.md\`

Read those artifacts directly. If the summary reports \`STATUS: UNVERIFIED\`, carry that forward as missing evidence and cite the exact reason from the native summary instead of inventing a browser pass.
ACCESSIBILITY
  fi

  # ── Lighthouse / Core Web Vitals (runtime and simulation jobs) ───────────
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${LIGHTHOUSE_SCAN:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<LIGHTHOUSE

## Lighthouse / Core Web Vitals

The harness has already attempted native Lighthouse runs against the configured target URLs.

Required evidence inputs:

- Raw JSON reports: \`$RUN_DIR/artifacts/$job_id/lighthouse/<page-slug>.json\`
- Native summary: \`$RUN_DIR/artifacts/$job_id/lighthouse/summary.md\`

Read those artifacts directly. Treat a performance score < 50 or any **poor** Core Web Vital rating as a launch blocker. If the summary reports \`STATUS: UNVERIFIED\`, carry that forward as missing evidence and cite the exact reason from the native summary.
LIGHTHOUSE
  fi

  # ── External services connectivity (runtime jobs) ────────────────────────
  if [[ "$kind" == "runtime" && "${EXTERNAL_SERVICES_TEST:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<EXTERNAL

## External Services Connectivity

The harness has already attempted native external-service connectivity probes using URL/credential material from \`docs/ux/.creds\`.

Required evidence inputs:

- Native summary: \`$RUN_DIR/artifacts/$job_id/external-services/summary.md\`
- Per-service raw artifacts: \`$RUN_DIR/artifacts/$job_id/external-services/*.json\`

Read those artifacts directly. If the summary reports \`STATUS: UNVERIFIED\`, carry that forward as missing evidence and cite the exact reason from the native summary rather than retrying ad hoc probes.
EXTERNAL
  fi

  # ── SAST and dependency CVE scanning (runtime jobs) ──────────────────────
  if [[ "$kind" == "runtime" && "${SAST_ENABLED:-1}" == "1" ]]; then
    cat >> "$prompt_file" <<SAST

## Static Analysis and Dependency CVE Scanning

The harness has already executed or attempted the following tools natively:
- **Bandit** (Python SAST)
- **Semgrep** (Multi-language SAST)
- **pip-audit** (Python dependency CVEs)
- **npm audit** (Node.js dependency CVEs)

Raw JSON outputs have been saved to \`$RUN_DIR/artifacts/$job_id/sast/\`. Read these files directly to analyze the findings.

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
  if [[ -f "$REPO_ROOT/.gemini/settings.json" ]]; then
    cp "$REPO_ROOT/.gemini/settings.json" "$mcp_cfg"
  else
    printf '{"mcpServers":{}}\n' > "$mcp_cfg"
  fi
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

  local heartbeat_interval="${AUDIT_HEARTBEAT_SECONDS:-60}"
  local stall_intervals="${AUDIT_STALL_INTERVALS:-5}"
  local start_ts
  start_ts="$(date +%s)"

  set +e
  "$@" &
  local cmd_pid="$!"

  if [[ "${_WAVE_DISPLAY:-0}" != "1" ]]; then
    (
      local spin_chars='-\|/'
      local spin_idx=0
      local prev_size=-1
      local last_change_ts="$start_ts"
      local stall_threshold=$(( stall_intervals * heartbeat_interval ))
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
  else
    wait "$cmd_pid"
    local status="$?"
    set -e
  fi

  if [[ "${VERBOSE:-0}" == "1" && "${_WAVE_DISPLAY:-0}" != "1" && -f "$log_file" ]]; then
    local final_size
    final_size="$(wc -c <"$log_file" | tr -d ' ')"
    printf '    log_bytes=%s log=%s\n' "$final_size" "$log_file"
  fi
  return "$status"
}

run_native_sast() {
  local job_id="$1"
  local sast_dir="$RUN_DIR/artifacts/$job_id/sast"
  local log_file="$RUN_DIR/logs/$job_id.log"
  mkdir -p "$sast_dir"

  printf '\n[native-sast] running bandit, semgrep, pip-audit, npm audit\n' >> "$log_file"

  local bandit_cmd="" semgrep_cmd="" pip_audit_cmd=""
  if audit_ensure_python_tool "bandit" "bandit" "$log_file"; then
    bandit_cmd="$(audit_resolve_python_tool "bandit")"
  else
    printf '[native-sast] bandit unavailable after install check; skipping\n' >> "$log_file"
  fi
  if audit_ensure_python_tool "semgrep" "semgrep" "$log_file"; then
    semgrep_cmd="$(audit_resolve_python_tool "semgrep")"
  else
    printf '[native-sast] semgrep unavailable after install check; skipping\n' >> "$log_file"
  fi
  if audit_ensure_python_tool "pip-audit" "pip-audit" "$log_file"; then
    pip_audit_cmd="$(audit_resolve_python_tool "pip-audit")"
  else
    printf '[native-sast] pip-audit unavailable after install check; skipping\n' >> "$log_file"
  fi

  run_native_sast_tool() {
    local label="$1" timeout_seconds="$2" log_path="$3"
    shift 3

    printf '[native-sast] starting %s timeout=%ss\n' "$label" "$timeout_seconds" >> "$log_path"
    set +e
    timeout "$timeout_seconds" "$@" >> "$log_path" 2>&1 &
    local tool_pid="$!"
    (
      while kill -0 "$tool_pid" 2>/dev/null; do
        sleep "${AUDIT_NATIVE_HEARTBEAT_SECONDS:-30}"
        if kill -0 "$tool_pid" 2>/dev/null; then
          printf '[native-sast] %s still running\n' "$label" >> "$log_path"
        fi
      done
    ) &
    local heartbeat_pid="$!"
    wait "$tool_pid"
    local status="$?"
    kill "$heartbeat_pid" >/dev/null 2>&1 || true
    wait "$heartbeat_pid" >/dev/null 2>&1 || true
    set -e

    if [[ "$status" == "0" ]]; then
      printf '[native-sast] %s completed\n' "$label" >> "$log_path"
    else
      printf '[native-sast] %s timed out or failed status=%s; continuing\n' "$label" "$status" >> "$log_path"
    fi
    return 0
  }

  # Python SAST
  if [[ -n "$bandit_cmd" ]] && find . -name "*.py" | read -r; then
    run_native_sast_tool "bandit" "${SAST_BANDIT_TIMEOUT:-300}" "$log_file" \
      "$bandit_cmd" -r . -f json -o "$sast_dir/bandit.json" -ll
  fi

  # Multi-language SAST
  if [[ -n "$semgrep_cmd" ]]; then
    run_native_sast_tool "semgrep" "${SAST_SEMGREP_TIMEOUT:-600}" "$log_file" \
      "$semgrep_cmd" \
      --config=auto \
      --json \
      --output="$sast_dir/semgrep.json" \
      --exclude docs/audit \
      --exclude .audit-tooling \
      --exclude node_modules \
      --exclude .venv \
      --exclude venv \
      --exclude site-packages \
      .
  fi

  # Python dependency CVEs
  if [[ -n "$pip_audit_cmd" ]] && [[ -f "requirements.txt" || -f "pyproject.toml" ]]; then
    run_native_sast_tool "pip-audit" "${SAST_PIP_AUDIT_TIMEOUT:-300}" "$log_file" \
      "$pip_audit_cmd" --format=json --output="$sast_dir/pip-audit.json"
  fi

  # Node.js dependency CVEs
  if [[ -f "package.json" ]]; then
    if command_exists npm; then
      timeout "${SAST_NPM_AUDIT_TIMEOUT:-300}" \
        npm audit --json > "$sast_dir/npm-audit.json" 2>/dev/null || {
          printf '[native-sast] npm audit timed out or failed; continuing\n' >> "$log_file"
        }
    else
      printf '[native-sast] npm unavailable; skipping npm audit\n' >> "$log_file"
    fi
  fi
}

write_unverified_summary() {
  local summary_file="$1" title="$2" reason="$3"
  mkdir -p "$(dirname "$summary_file")"
  {
    printf '# %s\n\n' "$title"
    printf 'STATUS: UNVERIFIED\n\n'
    printf '%s\n' "$reason"
  } > "$summary_file"
}

run_native_accessibility() {
  local job_id="$1"
  local log_file="$RUN_DIR/logs/$job_id.log"
  local out_dir="$RUN_DIR/artifacts/$job_id/accessibility"
  local summary_md="$out_dir/summary.md"
  local summary_json="$out_dir/summary.json"
  mkdir -p "$out_dir"

  local base_url
  base_url="$(detect_base_url 2>/dev/null || true)"
  if [[ -z "$base_url" ]]; then
    write_unverified_summary "$summary_md" "Accessibility Summary" "Base URL unavailable. Set AUDIT_BASE_URL or provide docs/ux/.creds / product-profile runtime URL."
    return 0
  fi

  if ! audit_ensure_node_packages "$log_file" "playwright" "@axe-core/playwright"; then
    write_unverified_summary "$summary_md" "Accessibility Summary" "Playwright tooling unavailable after install check. See $log_file."
    return 0
  fi
  if ! audit_ensure_node_bin "playwright" "$log_file" "playwright"; then
    write_unverified_summary "$summary_md" "Accessibility Summary" "Playwright tooling unavailable after install check. See $log_file."
    return 0
  fi
  if ! audit_ensure_playwright_chromium "$log_file"; then
    write_unverified_summary "$summary_md" "Accessibility Summary" "Playwright Chromium unavailable after install check. See $log_file."
    return 0
  fi

  local urls_file script_file
  urls_file="$out_dir/urls.txt"
  script_file="$out_dir/run-axe.cjs"
  collect_target_urls "$base_url" "${ACCESSIBILITY_PATHS:-/,/login}" > "$urls_file"
  if [[ ! -s "$urls_file" ]]; then
    write_unverified_summary "$summary_md" "Accessibility Summary" "No accessibility target URLs were resolved."
    return 0
  fi

  cat > "$script_file" <<'NODE'
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");
const { AxeBuilder } = require("@axe-core/playwright");

const urls = fs.readFileSync(process.env.AXE_URLS_FILE, "utf8").split(/\r?\n/).map(v => v.trim()).filter(Boolean);
const outDir = process.env.AXE_OUTPUT_DIR;
const summaryJson = process.env.AXE_SUMMARY_JSON;
const summaryMd = process.env.AXE_SUMMARY_MD;
const timeoutMs = Number(process.env.AXE_TIMEOUT_MS || "30000");

function slugify(input) {
  return input.toLowerCase().replace(/^https?:\/\//, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "page";
}

function countsFor(violations) {
  const counts = { critical: 0, serious: 0, moderate: 0, minor: 0 };
  for (const violation of violations || []) {
    const impact = violation.impact || "minor";
    if (counts[impact] !== undefined) counts[impact] += 1;
  }
  return counts;
}

function wcagStatus(counts, error) {
  if (error) return "unverified";
  if ((counts.critical || 0) > 0 || (counts.serious || 0) > 0) return "fail";
  if ((counts.moderate || 0) > 0 || (counts.minor || 0) > 0) return "partial";
  return "pass";
}

(async () => {
  const summary = [];
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    for (const url of urls) {
      const page = await context.newPage();
      const slug = slugify(url);
      try {
        await page.goto(url, { waitUntil: "networkidle", timeout: timeoutMs });
        const results = await new AxeBuilder({ page }).analyze();
        const counts = countsFor(results.violations);
        fs.writeFileSync(path.join(outDir, `${slug}.json`), JSON.stringify(results, null, 2));
        summary.push({ url, slug, counts, status: wcagStatus(counts, null), error: null });
      } catch (error) {
        summary.push({
          url,
          slug,
          counts: { critical: 0, serious: 0, moderate: 0, minor: 0 },
          status: "unverified",
          error: String(error && error.message ? error.message : error),
        });
      } finally {
        await page.close().catch(() => {});
      }
    }
    await context.close().catch(() => {});
  } finally {
    if (browser) await browser.close().catch(() => {});
  }

  fs.writeFileSync(summaryJson, JSON.stringify(summary, null, 2));
  let md = "# Accessibility Summary\n\n| URL | Critical | Serious | Moderate | Minor | Status | Error |\n| --- | --- | --- | --- | --- | --- | --- |\n";
  for (const row of summary) {
    md += `| ${row.url} | ${row.counts.critical} | ${row.counts.serious} | ${row.counts.moderate} | ${row.counts.minor} | ${row.status} | ${row.error || ""} |\n`;
  }
  fs.writeFileSync(summaryMd, md);
})().catch((error) => {
  fs.writeFileSync(summaryJson, JSON.stringify([{ status: "unverified", error: String(error && error.message ? error.message : error) }], null, 2));
  fs.writeFileSync(summaryMd, `# Accessibility Summary\n\nSTATUS: UNVERIFIED\n\n${String(error && error.message ? error.message : error)}\n`);
  process.exit(0);
});
NODE

  AXE_URLS_FILE="$urls_file" \
  AXE_OUTPUT_DIR="$out_dir" \
  AXE_SUMMARY_JSON="$summary_json" \
  AXE_SUMMARY_MD="$summary_md" \
  AXE_TIMEOUT_MS="${AUDIT_BROWSER_TIMEOUT_MS:-30000}" \
  NODE_PATH="$AUDIT_NODE_TOOLING_DIR/node_modules" \
  PLAYWRIGHT_BROWSERS_PATH="$AUDIT_NODE_TOOLING_DIR/playwright-browsers" \
  node "$script_file" >> "$log_file" 2>&1 || true
}

run_native_lighthouse() {
  local job_id="$1"
  local log_file="$RUN_DIR/logs/$job_id.log"
  local out_dir="$RUN_DIR/artifacts/$job_id/lighthouse"
  local summary_md="$out_dir/summary.md"
  local summary_json="$out_dir/summary.json"
  mkdir -p "$out_dir"

  local base_url
  base_url="$(detect_base_url 2>/dev/null || true)"
  if [[ -z "$base_url" ]]; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Base URL unavailable. Set AUDIT_BASE_URL or provide docs/ux/.creds / product-profile runtime URL."
    return 0
  fi

  if ! audit_ensure_node_packages "$log_file" "lighthouse" "playwright"; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Lighthouse tooling unavailable after install check. See $log_file."
    return 0
  fi
  if ! audit_ensure_node_bin "lighthouse" "$log_file" "lighthouse" "playwright"; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Lighthouse tooling unavailable after install check. See $log_file."
    return 0
  fi
  if ! audit_ensure_playwright_chromium "$log_file"; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Chromium unavailable for Lighthouse after install check. See $log_file."
    return 0
  fi

  local urls_file
  urls_file="$out_dir/urls.txt"
  collect_target_urls "$base_url" "${LIGHTHOUSE_PATHS:-/,/login}" > "$urls_file"
  if [[ ! -s "$urls_file" ]]; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "No Lighthouse target URLs were resolved."
    return 0
  fi

  local chrome_path
  if ! chrome_path="$(
    cd "$AUDIT_NODE_TOOLING_DIR" &&
      PLAYWRIGHT_BROWSERS_PATH="$AUDIT_NODE_TOOLING_DIR/playwright-browsers" \
        node -e 'console.log(require("playwright").chromium.executablePath())' 2>>"$log_file"
  )"; then
    chrome_path=""
  fi
  if [[ -z "$chrome_path" ]]; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Could not resolve Chromium executable path for Lighthouse."
    return 0
  fi

  local url slug
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    slug="$(slugify "$url")"
    "$(audit_resolve_node_bin "lighthouse")" "$url" \
      --output=json \
      --output-path="$out_dir/$slug.json" \
      --chrome-path="$chrome_path" \
      --chrome-flags="--headless --no-sandbox" \
      --only-categories=performance,accessibility,best-practices,seo \
      --quiet >> "$log_file" 2>&1 || true
  done < "$urls_file"

  if ! find "$out_dir" -maxdepth 1 -type f -name '*.json' ! -name 'summary.json' | read -r; then
    write_unverified_summary "$summary_md" "Lighthouse Summary" "Native Lighthouse did not produce any JSON reports. See $log_file."
    return 0
  fi

  LIGHTHOUSE_DIR="$out_dir" LIGHTHOUSE_SUMMARY_JSON="$summary_json" LIGHTHOUSE_SUMMARY_MD="$summary_md" python3 - <<'PY'
import json, os, pathlib

out_dir = pathlib.Path(os.environ["LIGHTHOUSE_DIR"])
summary_json = pathlib.Path(os.environ["LIGHTHOUSE_SUMMARY_JSON"])
summary_md = pathlib.Path(os.environ["LIGHTHOUSE_SUMMARY_MD"])
rows = []
for path in sorted(out_dir.glob("*.json")):
    if path.name == "summary.json":
        continue
    try:
        data = json.loads(path.read_text())
        audits = data.get("audits", {})
        perf = data.get("categories", {}).get("performance", {}).get("score")
        perf_score = int(round((perf or 0) * 100))
        metrics = {
            "lcp": audits.get("largest-contentful-paint", {}).get("numericValue"),
            "cls": audits.get("cumulative-layout-shift", {}).get("numericValue"),
            "inp": audits.get("interaction-to-next-paint", {}).get("numericValue"),
            "ttfb": audits.get("server-response-time", {}).get("numericValue"),
        }
        poor = (
            perf_score < 50
            or (metrics["lcp"] or 0) > 4000
            or (metrics["cls"] or 0) > 0.25
            or (metrics["inp"] or 0) > 500
        )
        rows.append({
            "page": path.stem,
            "perf_score": perf_score,
            "lcp_ms": metrics["lcp"],
            "cls": metrics["cls"],
            "inp_ms": metrics["inp"],
            "ttfb_ms": metrics["ttfb"],
            "status": "fail" if poor else "pass",
            "error": None,
        })
    except Exception as exc:
        rows.append({"page": path.stem, "status": "unverified", "error": str(exc)})

summary_json.write_text(json.dumps(rows, indent=2))
lines = [
    "# Lighthouse Summary",
    "",
    "| Page | Perf | LCP ms | CLS | INP ms | TTFB ms | Status | Error |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
]
for row in rows:
    lines.append(
        f"| {row.get('page','')} | {row.get('perf_score','')} | {row.get('lcp_ms','')} | {row.get('cls','')} | {row.get('inp_ms','')} | {row.get('ttfb_ms','')} | {row.get('status','')} | {row.get('error','') or ''} |"
    )
summary_md.write_text("\n".join(lines) + "\n")
PY
}

run_native_external_services() {
  local job_id="$1"
  local log_file="$RUN_DIR/logs/$job_id.log"
  local out_dir="$RUN_DIR/artifacts/$job_id/external-services"
  local summary_md="$out_dir/summary.md"
  mkdir -p "$out_dir"

  local creds
  creds="$(audit_creds_file 2>/dev/null || true)"
  if [[ -z "$creds" ]]; then
    write_unverified_summary "$summary_md" "External Services Summary" "No docs/ux/.creds file found. Native external-service probes require URL/credential material."
    return 0
  fi
  command_exists curl || {
    write_unverified_summary "$summary_md" "External Services Summary" "curl is unavailable; external-service probes could not run."
    return 0
  }

  {
    printf '# External Services Summary\n\n'
    printf '| Service | URL key | Status | Latency ms | Result |\n'
    printf '| --- | --- | --- | --- | --- |\n'
  } > "$summary_md"

  local url_key url_value prefix token user password path probe_url body_file meta_file
  local found=0
  while IFS='=' read -r url_key url_value; do
    [[ -n "${url_key:-}" ]] || continue
    case "$url_key" in
      APP_URL|BASE_URL|APPLICATION_URL|STAGING_URL|DEV_URL) continue ;;
    esac
    if [[ ! "$url_key" =~ (_URL|_BASE_URL|_API_URL)$ ]]; then
      continue
    fi
    found=1
    url_value="$(trim_inline_value "$url_value")"
    [[ -n "$url_value" ]] || continue
    prefix="${url_key%_URL}"
    prefix="${prefix%_BASE_URL}"
    prefix="${prefix%_API_URL}"
    path="$(audit_cred_value "${prefix}_HEALTHCHECK_PATH" 2>/dev/null || audit_cred_value "${prefix}_PING_PATH" 2>/dev/null || audit_cred_value "${prefix}_STATUS_PATH" 2>/dev/null || true)"
    path="$(trim_inline_value "$path")"
    probe_url="$(join_url "$url_value" "${path:-/}")"
    token="$(trim_inline_value "$(audit_cred_value "${prefix}_TOKEN" 2>/dev/null || audit_cred_value "${prefix}_API_KEY" 2>/dev/null || true)")"
    user="$(trim_inline_value "$(audit_cred_value "${prefix}_USERNAME" 2>/dev/null || true)")"
    password="$(trim_inline_value "$(audit_cred_value "${prefix}_PASSWORD" 2>/dev/null || true)")"
    body_file="$out_dir/${prefix,,}.body.txt"
    meta_file="$out_dir/${prefix,,}.json"

    local curl_args=(curl -sS -L --max-time "${EXTERNAL_SERVICE_TIMEOUT:-10}" -o "$body_file" -w '%{http_code}\t%{time_total}')
    if [[ -n "$token" ]]; then
      curl_args+=(-H "Authorization: Bearer $token")
    elif [[ -n "$user" && -n "$password" ]]; then
      curl_args+=(-u "$user:$password")
    fi

    local probe_result http_status latency
    probe_result="$("${curl_args[@]}" "$probe_url" 2>>"$log_file" || true)"
    http_status="${probe_result%%$'\t'*}"
    latency="${probe_result#*$'\t'}"
    [[ "$http_status" == "$probe_result" ]] && latency=""
    {
      printf '{\n'
      printf '  "service": "%s",\n' "${prefix,,}"
      printf '  "url_key": "%s",\n' "$url_key"
      printf '  "probe_url": "%s",\n' "$probe_url"
      printf '  "http_status": "%s",\n' "$http_status"
      printf '  "latency_seconds": "%s"\n' "$latency"
      printf '}\n'
    } > "$meta_file"

    local result="unverified"
    if [[ "$http_status" =~ ^2[0-9][0-9]$ || "$http_status" =~ ^3[0-9][0-9]$ ]]; then
      result="pass"
    elif [[ "$http_status" =~ ^[0-9][0-9][0-9]$ ]]; then
      result="warn"
    fi
    printf '| %s | %s | %s | %s | %s |\n' "${prefix,,}" "$url_key" "${http_status:-none}" "${latency:-}" "$result" >> "$summary_md"
  done < "$creds"
  if [[ "$found" == "0" ]]; then
    printf '\nSTATUS: EXTERNAL_SERVICES_NONE_CONFIGURED\n' >> "$summary_md"
  fi
}

run_native_load_test() {
  local log_file="$RUN_DIR/logs/load-test.log"
  local out_dir="$RUN_DIR/artifacts/load-test"
  local summary_md="$out_dir/native-load-test-summary.md"
  local summary_json="$out_dir/native-load-test-summary.json"
  mkdir -p "$out_dir"

  local base_url
  base_url="${LOAD_TEST_TARGET:-}"
  if [[ -z "$base_url" ]]; then
    base_url="$(detect_base_url 2>/dev/null || true)"
  fi
  if [[ -z "$base_url" ]]; then
    write_unverified_summary "$summary_md" "Native Load Test Summary" "Base URL unavailable. Set AUDIT_BASE_URL or provide docs/ux/.creds / product-profile runtime URL."
    return 0
  fi

  local urls_file
  urls_file="$out_dir/urls.txt"
  collect_target_urls "$base_url" "${LOAD_TEST_PATHS:-/}" > "$urls_file"
  if [[ ! -s "$urls_file" ]]; then
    write_unverified_summary "$summary_md" "Native Load Test Summary" "No load-test target URLs were resolved."
    return 0
  fi

  LOAD_URLS_FILE="$urls_file" LOAD_SUMMARY_JSON="$summary_json" LOAD_SUMMARY_MD="$summary_md" python3 - <<'PY'
import concurrent.futures
import json
import os
import pathlib
import time
import urllib.request

urls = [line.strip() for line in pathlib.Path(os.environ["LOAD_URLS_FILE"]).read_text().splitlines() if line.strip()]
summary_json = pathlib.Path(os.environ["LOAD_SUMMARY_JSON"])
summary_md = pathlib.Path(os.environ["LOAD_SUMMARY_MD"])

scenarios = [
    ("baseline", 10, 60),
    ("ramp", 50, 180),
    ("spike", 100, 30),
]

def hit(url):
    start = time.time()
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            status = response.getcode()
            response.read(256)
    except Exception:
        status = 0
    elapsed = (time.time() - start) * 1000.0
    return status, elapsed

rows = []
for name, workers, duration in scenarios:
    samples = []
    errors = 0
    stop_at = time.time() + min(duration, 5)
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, 32)) as pool:
        futures = []
        while time.time() < stop_at:
          for url in urls:
            futures.append(pool.submit(hit, url))
          if len(futures) >= workers:
            done, futures = futures[:workers], futures[workers:]
            for future in done:
              status, elapsed = future.result()
              samples.append(elapsed)
              if status < 200 or status >= 400:
                errors += 1
        for future in futures:
            status, elapsed = future.result()
            samples.append(elapsed)
            if status < 200 or status >= 400:
                errors += 1
    samples.sort()
    total = len(samples)
    if total:
        p50 = samples[int(total * 0.50) - 1 if int(total * 0.50) else 0]
        p95 = samples[int(total * 0.95) - 1 if int(total * 0.95) else 0]
        p99 = samples[int(total * 0.99) - 1 if int(total * 0.99) else 0]
    else:
        p50 = p95 = p99 = 0.0
    error_rate = (errors / total) if total else 1.0
    status = "fail" if (p95 > 2000 or p99 > 5000 or (name != "spike" and error_rate > 0.01) or (name == "spike" and error_rate > 0.05)) else "pass"
    rows.append({
        "scenario": name,
        "virtual_users": workers,
        "duration_seconds_requested": duration,
        "duration_seconds_executed": min(duration, 5),
        "samples": total,
        "p50_ms": round(p50, 2),
        "p95_ms": round(p95, 2),
        "p99_ms": round(p99, 2),
        "error_rate": round(error_rate, 4),
        "status": status,
    })

summary_json.write_text(json.dumps(rows, indent=2))
lines = [
    "# Native Load Test Summary",
    "",
    "The built-in runner clamps execution time to 5 seconds per scenario in this harness pass so it can produce deterministic baseline evidence without monopolizing the audit process.",
    "",
    "| Scenario | VUs | Requested s | Executed s | Samples | p50 ms | p95 ms | p99 ms | Error rate | Status |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
]
for row in rows:
    lines.append(
        f"| {row['scenario']} | {row['virtual_users']} | {row['duration_seconds_requested']} | {row['duration_seconds_executed']} | {row['samples']} | {row['p50_ms']} | {row['p95_ms']} | {row['p99_ms']} | {row['error_rate']} | {row['status']} |"
    )
summary_md.write_text("\n".join(lines) + "\n")
PY
}

run_native_runtime_checks() {
  local job_id="$1" kind="$2"
  [[ "$DRY_RUN" == "1" ]] && return 0
  if [[ "$kind" == "runtime" && "${SAST_ENABLED:-1}" == "1" ]]; then
    run_native_sast "$job_id"
  fi
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${ACCESSIBILITY_SCAN:-1}" == "1" ]]; then
    run_native_accessibility "$job_id"
  fi
  if [[ "$kind" =~ ^(runtime|simulation)$ && "${LIGHTHOUSE_SCAN:-1}" == "1" ]]; then
    run_native_lighthouse "$job_id"
  fi
  if [[ "$kind" == "runtime" && "${EXTERNAL_SERVICES_TEST:-1}" == "1" ]]; then
    run_native_external_services "$job_id"
  fi
  write_ux_browser_gate_summary
}

write_ux_browser_gate_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local summary_tsv="$RUN_DIR/artifacts/ux-browser-gate-summary.tsv"
  local summary_md="$RUN_DIR/artifacts/ux-browser-gate-summary.md"
  mkdir -p "$RUN_DIR/artifacts"

  printf 'job_id\tlane\tstatus\tsummary\n' > "$summary_tsv"

  local summary_file job_id lane status reason
  shopt -s nullglob
  for summary_file in "$RUN_DIR"/artifacts/*/accessibility/summary.md "$RUN_DIR"/artifacts/*/lighthouse/summary.md; do
    [[ -s "$summary_file" ]] || continue
    job_id="$(basename "$(dirname "$(dirname "$summary_file")")")"
    lane="$(basename "$(dirname "$summary_file")")"
    status="PASS"
    if grep -qi 'STATUS:[[:space:]]*UNVERIFIED' "$summary_file"; then
      status="UNVERIFIED"
    elif grep -qiE 'STATUS:[[:space:]]*(FAIL|BLOCK|BLOCKER)|\|[[:space:]]*(fail|poor)[[:space:]]*\|' "$summary_file"; then
      status="FAIL"
    elif grep -qiE 'WARN|WARNING|poor|score[[:space:]]*< ?50' "$summary_file"; then
      status="WARN"
    fi
    reason="$(grep -E 'STATUS:|UNVERIFIED|FAIL|BLOCK|WARN|poor|score' "$summary_file" | head -3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$reason" ]] || reason="summary available"
    printf '%s\t%s\t%s\t%s\n' "$job_id" "$lane" "$status" "$reason" >> "$summary_tsv"
  done
  shopt -u nullglob

  {
    printf '# UX Browser Gate Summary\n\n'
    printf 'This file is generated by the audit harness from native accessibility and Lighthouse artifacts. Final release decisions must treat this as first-class evidence.\n\n'
    printf '| Job | Lane | Status | Summary |\n'
    printf '| --- | --- | --- | --- |\n'
    if [[ "$(wc -l < "$summary_tsv" | tr -d ' ')" == "1" ]]; then
      printf '| _none_ | _none_ | UNVERIFIED | No native UX/browser summaries were produced. |\n'
    else
      tail -n +2 "$summary_tsv" | while IFS=$'\t' read -r job_id lane status reason; do
        printf '| `%s` | `%s` | `%s` | %s |\n' "$job_id" "$lane" "$status" "$reason"
      done
    fi
  } > "$summary_md"
}

run_native_checks_and_prompt() {
  local prompt_file="$1" job_id="$2" kind="$3"
  run_native_runtime_checks "$job_id" "$kind"
  run_prompt "$prompt_file" "$job_id" "$kind"
}

run_prompt() {
  local prompt_file="$1" job_id="$2" kind="$3"
  local log_file="$RUN_DIR/logs/$job_id.log"
  local readonly_integrity=0 readonly_before_file="" readonly_before_hash="" readonly_before_size=0

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s -> %s\n' "$job_id" "$prompt_file"
    return 0
  fi

  if audit_readonly_kind "$kind" && git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null; then
    readonly_integrity=1
    readonly_before_file="$(mktemp)"
    audit_readonly_diff_snapshot > "$readonly_before_file"
    readonly_before_hash="$(sha256sum "$readonly_before_file" | awk '{print $1}')"
    readonly_before_size="$(wc -c <"$readonly_before_file" | tr -d ' ')"
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

  # Read-only audit phases must not modify product files. Compare against the
  # pre-run snapshot so existing user changes are preserved and only new writes
  # introduced by this job are treated as violations.
  if [[ "$readonly_integrity" == "1" ]]; then
    local readonly_after_file readonly_after_hash
    readonly_after_file="$(mktemp)"
    audit_readonly_diff_snapshot > "$readonly_after_file"
    readonly_after_hash="$(sha256sum "$readonly_after_file" | awk '{print $1}')"
    if [[ "$readonly_after_hash" != "$readonly_before_hash" ]]; then
      printf '\nAUDIT INTEGRITY VIOLATION: job %s modified product files outside RUN_DIR\n' "$job_id" >>"$log_file"
      if [[ "$readonly_before_size" == "0" ]]; then
        printf 'Restoring unexpected tracked/untracked changes because the repo was clean before this job.\n' >>"$log_file"
        audit_restore_readonly_changes
      else
        printf 'Pre-existing product diff was present before %s; leaving files untouched to avoid destroying user changes.\n' "$job_id" >>"$log_file"
      fi
      rm -f "$readonly_before_file" "$readonly_after_file"
      return 1
    fi
    rm -f "$readonly_before_file" "$readonly_after_file"
  fi

  return "$cmd_exit"
}

current_group=""
declare -a group_pids=()
declare -a group_names=()
declare -a group_outputs=()
active_count=0

wait_for_group() {
  local -n pids_ref=$1
  local -n names_ref=$2
  local -n outputs_ref=$3
  local failed=0
  local n=${#pids_ref[@]}
  if [[ $n -eq 0 ]]; then
    return 0
  fi

  local heartbeat_interval="${AUDIT_HEARTBEAT_SECONDS:-60}"
  local stall_intervals="${AUDIT_STALL_INTERVALS:-5}"
  local stall_threshold=$(( stall_intervals * heartbeat_interval ))
  local now
  now="$(date +%s)"

  local -a job_start=() job_log=() job_prev_size=() job_last_change=()
  local idx
  for idx in "${!names_ref[@]}"; do
    job_start+=("$now")
    job_log+=("$RUN_DIR/logs/${names_ref[$idx]}.log")
    job_prev_size+=(-1)
    job_last_change+=("$now")
  done

  local spin_chars='-\|/'
  local spin_idx=0
  local -a remaining=("${!pids_ref[@]}")

  while [[ ${#remaining[@]} -gt 0 ]]; do
    sleep 0.5
    local now2 spin_char
    now2="$(date +%s)"
    spin_char="${spin_chars:$((spin_idx % 4)):1}"
    spin_idx=$(( (spin_idx + 1) % 4 ))

    local -a still_running=()
    for idx in "${remaining[@]}"; do
      if ! kill -0 "${pids_ref[$idx]}" 2>/dev/null; then
        wait "${pids_ref[$idx]}"
        local status=$?
        local term_width
        term_width=$(tput cols 2>/dev/null || echo 120)
        printf '\r%-*s\r' $(( term_width - 1 )) ''

        local job_name="${names_ref[$idx]}"
        local job_log_file="${job_log[$idx]}"
        local job_passed=0
        if [[ "$status" == "0" ]]; then
          job_passed=1
          if [[ "$DRY_RUN" != "1" && -n "${outputs_ref[$idx]}" ]]; then
            local expected_path="$RUN_DIR/${outputs_ref[$idx]%%#*}"
            if [[ ! -f "$expected_path" ]]; then
              printf '[missing-output] %s: expected %s\n' "$job_name" "$expected_path" >&2
              failed=1
              job_passed=0
            fi
          fi
          if ((job_passed)); then
            printf '[ok] %s\n' "$job_name"
            if [[ "$DRY_RUN" != "1" ]]; then
              printf '%s\n' "$job_name" >> "$CHECKPOINT_FILE"
            fi
          fi
        else
          printf '[fail] %s (see %s/logs/%s.log)\n' "$job_name" "$RUN_DIR" "$job_name" >&2
          failed=1
        fi

        if [[ "${VERBOSE:-0}" == "1" && -f "$job_log_file" ]]; then
          local final_size
          final_size="$(wc -c <"$job_log_file" | tr -d ' ')"
          printf '    log_bytes=%s log=%s\n' "$final_size" "$job_log_file"
        fi
      else
        still_running+=("$idx")
        local size=0
        if [[ -f "${job_log[$idx]}" ]]; then
          size="$(wc -c <"${job_log[$idx]}" | tr -d ' ')"
        fi
        if [[ "$size" -ne "${job_prev_size[$idx]}" ]]; then
          job_last_change[idx]="$now2"
          job_prev_size[idx]="$size"
        elif [[ "$stall_threshold" -gt 0 && "${job_prev_size[$idx]}" -ge 0 ]]; then
          local stall_secs=$(( now2 - job_last_change[idx] ))
          if [[ "$stall_secs" -ge "$stall_threshold" ]]; then
            local elapsed=$(( now2 - job_start[idx] ))
            local term_width
            term_width=$(tput cols 2>/dev/null || echo 120)
            printf '\r%-*s\r' $(( term_width - 1 )) ''
            printf '[!] %s: stalled after %ds — terminating\n' "${names_ref[$idx]}" "$elapsed" >&2
            printf '[stall-kill] stalled after %ds — terminating\n' "$elapsed" >> "${job_log[$idx]}"
            kill "${pids_ref[$idx]}" 2>/dev/null || true
          fi
        fi
      fi
    done
    remaining=("${still_running[@]}")

    if [[ ${#remaining[@]} -gt 0 ]]; then
      local parts=()
      local part_idx
      for part_idx in "${remaining[@]}"; do
        local elapsed=$(( now2 - job_start[part_idx] ))
        parts+=("${names_ref[$part_idx]} (${elapsed}s)")
      done
      local line="${parts[0]}"
      local part
      for part in "${parts[@]:1}"; do
        line+=" | $part"
      done
      local term_width
      term_width=$(tput cols 2>/dev/null || echo 120)
      local content="[$spin_char] $line"
      local padded
      printf -v padded '%-*s' $(( term_width - 1 )) "$content"
      padded="${padded:0:$(( term_width - 1 ))}"
      printf '\r%s' "$padded"
    fi
  done

  local term_width
  term_width=$(tput cols 2>/dev/null || echo 120)
  printf '\r%-*s\r' $(( term_width - 1 )) ''
  return "$failed"
}

flush_group() {
  if ((${#group_pids[@]} == 0)); then
    return 0
  fi
  printf 'Waiting for group %s (%d job(s))...\n' "$current_group" "${#group_pids[@]}"
  local flush_failed=0

  if ! wait_for_group group_pids group_names group_outputs; then
    flush_failed=1
  fi

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
  local drained_file="$RUN_DIR/artifacts/drained-deep-dives.txt"
  touch "$queued_file"
  touch "$drained_file"

  # Reuse the global group arrays (guaranteed empty after flush_group).
  # Set current_group to "dynamic" so flush_group prints a clear label.
  local saved_group="$current_group"
  current_group="dynamic"

  while IFS=$'\t' read -r dj_id parent_job depth entry_point files scope rationale; do
    # Skip header and blank/malformed rows.
    [[ -z "${dj_id:-}" || "$dj_id" == "job_id" ]] && continue
    local depth_int="${depth:-1}"
    [[ "$depth_int" =~ ^[0-9]+$ ]] || continue

    if grep -qxF "$dj_id" "$drained_file" 2>/dev/null; then
      continue
    fi

    if (( depth_int > DYNAMIC_DEPTH_CAP )); then
      printf '[deep-dive] depth-capped: %s (depth=%s cap=%s)\n' "$dj_id" "$depth_int" "$DYNAMIC_DEPTH_CAP"
      printf '%s\n' "$dj_id" >> "$drained_file"
      continue
    fi

    if grep -qxF "$dj_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      printf '[dynamic] already completed deep-dive %s\n' "$dj_id"
      printf '%s\n' "$dj_id" >> "$drained_file"
      continue
    fi

    if grep -qxF "$dj_id" "$queued_file" 2>/dev/null; then
      printf '%s\n' "$dj_id" >> "$drained_file"
      continue
    fi

    local prompt_file
    prompt_file="$(build_deep_dive_prompt "$dj_id" "$parent_job" "$depth_int" "$entry_point" "$files" "$scope" "$rationale")"
    printf '[start] group=dynamic job=%s kind=deep-dive depth=%s parent=%s\n' "$dj_id" "$depth_int" "$parent_job"

    printf '%s\n' "$dj_id" >> "$queued_file"
    _DRAIN_STARTED=$(( _DRAIN_STARTED + 1 ))

    _WAVE_DISPLAY=1 run_prompt "$prompt_file" "$dj_id" "deep-dive" &
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

**Tool preference**: ${tool}. The harness has already attempted the native load-test runner before this analysis job.

**Target base URL**: ${target:-"(auto-detect from docs/ux/.creds or deployment docs — read APP_URL, BASE_URL, or equivalent)"}

### Native Evidence Inputs

The harness has already attempted the native load-test runner and written:

- Summary markdown: \`$RUN_DIR/artifacts/load-test/native-load-test-summary.md\`
- Summary JSON: \`$RUN_DIR/artifacts/load-test/native-load-test-summary.json\`
- Target URL list: \`$RUN_DIR/artifacts/load-test/urls.txt\`

### Thresholds

Flag as FAIL if any scenario exceeds:
- p95 response time > 2000ms for API endpoints
- p99 response time > 5000ms
- Error rate > 1% under baseline or ramp
- Error rate > 5% under spike

If the product profile specifies SLO targets, use those instead.

### Outputs

Write \`$RUN_DIR/$output\` with:
- Summary table: scenario, VUs, duration, p50, p95, p99 latency, throughput (req/s), error rate, result
- Bottleneck analysis: which endpoint degraded first and at what VU count
- Comparison to thresholds: pass / fail / partial per scenario
- Any errors encountered (HTTP 5xx, connection resets, timeouts)

## Job Instructions

Do not modify source files. Analyze the native load-test artifacts first. If the native summary is \`STATUS: UNVERIFIED\`, record that exact limitation and only propose a rerun gate instead of fabricating load evidence.

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

  if [[ "$DRY_RUN" != "1" ]]; then
    run_native_load_test
  fi

  current_group="load"
  _WAVE_DISPLAY=1 run_prompt "$prompt_file" "load-test" "load" &
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

    _WAVE_DISPLAY=1 run_native_checks_and_prompt "$prompt_file" "$job_id" "$kind" &
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

write_ux_browser_gate_summary
write_run_summary
printf 'Audit launcher complete. Run directory: %s\n' "$RUN_DIR"
