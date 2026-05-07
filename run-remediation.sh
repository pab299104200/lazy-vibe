#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
SHARED_PROMPT="${SHARED_PROMPT:-$SCRIPT_DIR/generic-shared.md}"
PRODUCT_PROFILE="${PRODUCT_PROFILE:-}"
PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"
PROFILE="${PROFILE:-}"
AUDIT_RUN=""
REMEDIATION_DIR="${REMEDIATION_DIR:-}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
MAX_WORKSTREAM_PACKETS="${MAX_WORKSTREAM_PACKETS:-80}"
CONTINUE_ON_FAIL="${CONTINUE_ON_FAIL:-0}"
AUTO_REVISE="${REMEDIATION_AUTO_REVISE:-1}"
MAX_REVISION_ROUNDS="${REMEDIATION_MAX_REVISION_ROUNDS:-1}"
MAX_AUTO_REVISE_FINDINGS="${REMEDIATION_MAX_AUTO_REVISE_FINDINGS:-8}"
EXECUTE=0
VERIFY=0
VERIFY_ONLY=0
DRY_RUN=0
VERBOSE="${VERBOSE:-0}"
ONLY_GROUP=""
ONLY_UNIT=""
CATALOG_WITH_CODEX=0
FORCE_CATALOG=0
REVISE_EXISTING=0
SPLIT_INCOMPLETE=0
AUTO_SPLIT_BEFORE_EXECUTE="${REMEDIATION_AUTO_SPLIT:-1}"
MAX_UNIT_PACKET_COUNT="${REMEDIATION_MAX_UNIT_PACKET_COUNT:-3}"
MAX_UNIT_PACKET_BYTES="${REMEDIATION_MAX_UNIT_PACKET_BYTES:-120000}"
MAX_PACKET_BYTES="${REMEDIATION_MAX_PACKET_BYTES:-60000}"
IMPLEMENTER_AGENT="${IMPLEMENTER_AGENT:-codex}"
PLANNER_AGENT="${PLANNER_AGENT:-}"
REVIEWER_AGENT="${REVIEWER_AGENT:-}"
PLAN_MODEL_CLASSES="${PLAN_MODEL_CLASSES:-high-risk complex}"
VERIFY_SCOPE="${REMEDIATION_VERIFY_SCOPE:-implementation}"
AUTO_SPLIT_CHILD_UNITS=""
SPLIT_CANDIDATE_UNITS=""
SPLIT_SKIP_EXECUTION=0
RECOORDINATE=0
NO_NORMALIZE=0
SPLIT_RUN_UNITS=""
REMEDIATION_MAX_RETRIES="${REMEDIATION_MAX_RETRIES:-2}"
REMEDIATION_RAW_UNIT_ABORT_THRESHOLD="${REMEDIATION_RAW_UNIT_ABORT_THRESHOLD:-20}"
REMEDIATION_ALLOW_RAW_UNITS="${REMEDIATION_ALLOW_RAW_UNITS:-0}"
REMEDIATION_REWRITE_PACKETS="${REMEDIATION_REWRITE_PACKETS:-0}"
REMEDIATION_REWRITE_WORKSTREAMS="${REMEDIATION_REWRITE_WORKSTREAMS:-0}"
REMEDIATION_REWRITE_UNITS="${REMEDIATION_REWRITE_UNITS:-0}"
REMEDIATION_IMPORT_PRIOR_RUNS="${REMEDIATION_IMPORT_PRIOR_RUNS:-1}"
REMEDIATION_COMMIT_ON_VERIFY="${REMEDIATION_COMMIT_ON_VERIFY:-0}"
REMEDIATION_COMMIT_ROOTS="${REMEDIATION_COMMIT_ROOTS:-backend,frontend}"
NO_CATALOG=0

usage() {
  cat <<'USAGE'
Usage: run-remediation.sh --audit-run RUN_DIR [--execute] [--verify] [--verify-only] [--revise-existing] [--split-incomplete] [--no-auto-split] [--no-catalog] [--force-catalog] [--catalog-with-codex] [--dry-run] [--verbose] [--only-group GROUP] [--only-unit IU-0001,IU-0002]

Environment:
  REMEDIATION_DIR             Output directory for remediation plan and logs.
  REPO_ROOT                   Product repo root. Defaults to current working directory.
  PROFILE                     Profile name (resolved under PROFILES_DIR) or absolute path to a profile directory.
                              Sets PRODUCT_PROFILE from the profile if not already set.
  PROFILES_DIR                Directory containing named profile subdirectories. Defaults to profiles/ alongside the script.
  PRODUCT_PROFILE             Optional product profile markdown. Set automatically when PROFILE is used.
  MAX_PARALLEL                Max workstreams per wave. Defaults to 3.
  MAX_WORKSTREAM_PACKETS      Max packets per workstream coordinator. Oversized workstreams are
                              split by source kind, then source file stem, then numerically.
                              Defaults to 80.
  CONTINUE_ON_FAIL            1 to continue after a failed workstream. Defaults to 0.
  REMEDIATION_AUTO_REVISE     1 to rerun verifier-revised units before final review. Defaults to 1.
  REMEDIATION_MAX_REVISION_ROUNDS
                              Max implement/verify revision rounds after first verification. Defaults to 1.
  REMEDIATION_MAX_AUTO_REVISE_FINDINGS
                              Max verifier finding rows allowed for automatic revision. Defaults to 8.
  REMEDIATION_REVISION_MAX_PARALLEL
                              Parallelism during revision rounds. Defaults to 2.
  REMEDIATION_VERIFY_SCOPE    implementation or launch. Defaults to implementation.
  REMEDIATION_MAX_RETRIES     Extra retry attempts per workstream on non-zero runner exit. Defaults to 2 (3 total attempts, backoff 15s/30s).
  REMEDIATION_RAW_UNIT_ABORT_THRESHOLD
                              Abort before execution when this many raw one-packet PX-* implementation
                              units remain after coordination/cataloging. Defaults to 20.
  REMEDIATION_ALLOW_RAW_UNITS 1 to allow execution of a large raw one-packet manifest. Defaults to 0.
  REMEDIATION_REWRITE_PACKETS
                              1 to overwrite existing packet files when reusing REMEDIATION_DIR. Defaults to 0.
  REMEDIATION_REWRITE_WORKSTREAMS
                              1 to overwrite existing workstream TSV when reusing REMEDIATION_DIR. Defaults to 0.
  REMEDIATION_REWRITE_UNITS   1 to overwrite existing implementation units TSV when reusing REMEDIATION_DIR. Defaults to 0.
  REMEDIATION_IMPORT_PRIOR_RUNS
                              1 to recover fixed packets from sibling remediation runs for the same audit run
                              when the packet source/line/title still matches. Defaults to 1.
  REMEDIATION_COMMIT_ON_VERIFY
                              1 to commit changed Git roots after a unit verifies as accepted/fixed.
                              Defaults to 0. Forces serialized implementation/verification waves.
  REMEDIATION_COMMIT_ROOTS     Comma-separated repo roots under REPO_ROOT to commit when
                              REMEDIATION_COMMIT_ON_VERIFY=1. Defaults to backend,frontend.
  REMEDIATION_AUTO_SPLIT      1 to auto-detect oversized units before execution. Defaults to 1.
  REMEDIATION_MAX_UNIT_PACKET_COUNT
                              Max packets per implementation unit before split preflight. Defaults to 3.
  REMEDIATION_MAX_UNIT_PACKET_BYTES
                              Max combined packet bytes per implementation unit before split preflight. Defaults to 120000.
  REMEDIATION_MAX_PACKET_BYTES
                              Max single packet bytes before split preflight. Defaults to 60000.
  IMPLEMENTER_AGENT           Built-in implementer: codex (default), claude, or gemini.
                              Use runner to hand off to IMPLEMENTER_RUNNER instead.
  IMPLEMENTER_RUNNER          Custom implementer wrapper (overrides built-in agent).
                              Receives: prompt_file remediation_dir workstream_id.
  PLANNER_AGENT               Built-in planner agent for high-risk/complex units. Defaults to
                              REVIEWER_AGENT, then COORDINATOR_AGENT, then IMPLEMENTER_AGENT.
                              Planners read code and write a design doc; implementers then
                              execute against the design.
  PLANNER_RUNNER              Custom planner wrapper (overrides built-in agent).
  PLAN_MODEL_CLASSES          Space-separated model classes that run through the planner phase
                              before implementation. Defaults to "high-risk complex".
  REVIEWER_AGENT              Built-in reviewer: codex, claude, or gemini.
                              Defaults to IMPLEMENTER_AGENT when not set; a warning is printed when
                              same-model review is used since it reduces independence.
                              Use runner to hand off to REVIEWER_RUNNER instead.
  REVIEWER_RUNNER             Custom reviewer wrapper (overrides built-in agent).
                              Receives: prompt_file remediation_dir workstream_id.
  REMEDIATION_RUNNER          Fallback wrapper for all roles when no role-specific runner is set.
                              Receives: prompt_file remediation_dir workstream_id.
  CATALOG_RUNNER              Optional cataloger wrapper override.
  VERIFICATION_RUNNER         Optional verifier wrapper override.
  REVIEW_RUNNER               Optional final-review wrapper override.

Codex agent (IMPLEMENTER_AGENT=codex or REVIEWER_AGENT=codex):
  CODEX_MODEL                 Override model for all classes.
  CODEX_MODEL_COORDINATOR     Defaults to gpt-5.5.
  CODEX_MODEL_PLANNER         Defaults to gpt-5.5.
  CODEX_MODEL_HIGH_RISK       Defaults to gpt-5.5.
  CODEX_MODEL_STANDARD        Defaults to gpt-5.4.
  CODEX_MODEL_VERIFIER        Defaults to gpt-5.5.
  CODEX_MODEL_REVIEWER        Defaults to gpt-5.5.
  CODEX_REASONING_EFFORT      Override reasoning effort for all classes.
  CODEX_REASONING_COORDINATOR Defaults to high.
  CODEX_REASONING_PLANNER     Defaults to high.
  CODEX_REASONING_HIGH_RISK   Defaults to high.
  CODEX_REASONING_STANDARD    Defaults to medium.
  CODEX_REASONING_VERIFIER    Defaults to high.
  CODEX_REASONING_REVIEWER    Defaults to high.
  CODEX_PROFILE               Optional profile passed to codex exec.
  CODEX_EXTRA_ARGS            Optional extra args appended to codex exec. Split on shell words.

Claude agent (IMPLEMENTER_AGENT=claude or REVIEWER_AGENT=claude):
  Model is chosen automatically from the packet's model class:
    coordinator / planner / high-risk / verifier / reviewer → claude-opus-4-7
    standard / cataloger                                    → claude-sonnet-4-6
  CLAUDE_MODEL                Override model for all classes.
  CLAUDE_MODEL_HIGH           Model for high-effort classes. Defaults to claude-opus-4-7.
  CLAUDE_MODEL_STANDARD       Model for standard/cataloger classes. Defaults to claude-sonnet-4-6.
  CLAUDE_EFFORT               Override effort for all classes (low|medium|high|xhigh|max).
  CLAUDE_EFFORT_CATALOGER     Effort for the cataloger. Defaults to low (avoids extended thinking on large prompts).
  CLAUDE_EFFORT_HIGH          Effort for high-effort classes. Defaults to high.
  CLAUDE_EFFORT_STANDARD      Effort for standard implementation classes. Defaults to medium.
  CLAUDE_EXTRA_ARGS           Optional extra args appended to claude. Split on shell words.

Gemini agent (IMPLEMENTER_AGENT=gemini or REVIEWER_AGENT=gemini):
  Model is chosen automatically from the packet's model class:
    coordinator / planner / high-risk / verifier / reviewer → gemini-2.5-pro
    standard / cataloger                                    → gemini-2.5-flash
  GEMINI_MODEL                Override model for all classes.
  GEMINI_MODEL_HIGH           Model for high-effort classes. Defaults to gemini-2.5-pro.
  GEMINI_MODEL_STANDARD       Model for standard/cataloger. Defaults to gemini-2.5-flash.
  GEMINI_EXTRA_ARGS           Optional extra args appended to gemini. Split on shell words.
  SPLIT_CHILD_MAX_PARALLEL    Max parallelism after auto-splitting. Defaults to 1 to avoid shared-file conflicts.
  REMEDIATION_HEARTBEAT_SECONDS
                              Progress heartbeat interval while an agent is running. Defaults to 60.
  REMEDIATION_STALL_INTERVALS Number of unchanged-log heartbeat intervals before a stall-kill is triggered.
                              Defaults to 5 (5 minutes at 60s heartbeat). Set to 0 to disable stall detection.

Default behavior builds the master Px list, work packets, grouping, and prompts only.
Use --execute to run the coordinator and workstream agents. The cataloger runs automatically with --execute unless --no-catalog is set.
Use --no-catalog to skip the cataloger when --execute is set (useful when packets were hand-edited or the cataloger already ran).
Use --recoordinate to strip coordinate-* checkpoint entries and re-run workstream coordinators against incomplete packets only. Combine with --no-catalog --no-auto-split --execute to resume from open packets without touching the catalog or splitting logic.
Use --no-normalize to skip workstream source-kind splitting on resume runs where normalization has already been done.
Use --catalog-with-codex to run the cataloger explicitly without --execute (plan-only mode with catalog refinement).
Use --verify to run read-only verifier agents after workstream implementation.
Use --verify-only to run only verifier and final-review agents against an existing remediation directory.
Use --revise-existing with REMEDIATION_DIR to rerun implementation against existing packet/verifier artifacts instead of regenerating packets.
Use --split-incomplete to detect oversized/incomplete/revise units, create child implementation units, and run those children when --execute is set.
Oversized unit detection runs automatically before execution by default; use --no-auto-split to disable it.
Use --only-unit to limit execution or verification to specific implementation units.
Use --dry-run to print the generated execution schedule without running agents.
USAGE
}

while (($#)); do
  case "$1" in
    --audit-run)
      AUDIT_RUN="${2:?missing audit run directory}"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --verify-only)
      VERIFY=1
      VERIFY_ONLY=1
      shift
      ;;
    --revise-existing)
      REVISE_EXISTING=1
      shift
      ;;
    --split-incomplete)
      SPLIT_INCOMPLETE=1
      REVISE_EXISTING=1
      shift
      ;;
    --recoordinate)
      RECOORDINATE=1
      shift
      ;;
    --no-normalize)
      NO_NORMALIZE=1
      shift
      ;;
    --no-auto-split)
      AUTO_SPLIT_BEFORE_EXECUTE=0
      shift
      ;;
    --no-catalog)
      NO_CATALOG=1
      shift
      ;;
    --force-catalog)
      FORCE_CATALOG=1
      CATALOG_WITH_CODEX=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --catalog-with-codex)
      CATALOG_WITH_CODEX=1
      shift
      ;;
    --only-group)
      ONLY_GROUP="${2:?missing group}"
      shift 2
      ;;
    --only-unit)
      ONLY_UNIT="${2:?missing unit id list}"
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

if [[ -z "$AUDIT_RUN" ]]; then
  echo "--audit-run is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$AUDIT_RUN" ]]; then
  echo "Audit run directory not found: $AUDIT_RUN" >&2
  exit 2
fi

if [[ -z "$REMEDIATION_DIR" ]]; then
  REMEDIATION_DIR="$(dirname "$AUDIT_RUN")/$(date +%Y-%m-%d)-remediation-run"
fi

if [[ -n "$PROFILE" ]]; then
  _profile_dir="$PROFILE"
  [[ "$PROFILE" != /* ]] && _profile_dir="$PROFILES_DIR/$PROFILE"
  if [[ ! -d "$_profile_dir" ]]; then
    printf 'Profile not found: %s\n' "$_profile_dir" >&2; exit 2
  fi
  [[ -z "$PRODUCT_PROFILE" && -f "$_profile_dir/product-profile.md" ]] && PRODUCT_PROFILE="$_profile_dir/product-profile.md"
  [[ "$SHARED_PROMPT" == "$SCRIPT_DIR/shared.md" && -f "$_profile_dir/shared.md" ]] && SHARED_PROMPT="$_profile_dir/shared.md"
fi

mkdir -p "$REMEDIATION_DIR"/{packets,prompts,logs,artifacts}
CHECKPOINT_FILE="$REMEDIATION_DIR/completed-units.txt"

if [[ "$REMEDIATION_COMMIT_ON_VERIFY" == "1" ]]; then
  if [[ "$MAX_PARALLEL" != "1" ]]; then
    printf '[commit-on-verify] forcing MAX_PARALLEL=1 so unit diffs cannot interleave across repos\n'
    MAX_PARALLEL=1
  fi
  if [[ "${REMEDIATION_REVISION_MAX_PARALLEL:-2}" != "1" ]]; then
    printf '[commit-on-verify] forcing REMEDIATION_REVISION_MAX_PARALLEL=1 so revision diffs remain attributable\n'
    REMEDIATION_REVISION_MAX_PARALLEL=1
  fi
fi

# Auto-enable the cataloger for fresh execution only. Existing implementation
# units are catalog state and must be resumed as-is unless --force-catalog is
# passed. --no-catalog opts out; --catalog-with-codex still works explicitly.
if [[ "$EXECUTE" == "1" && "$NO_CATALOG" != "1" && "$REVISE_EXISTING" != "1" && "$VERIFY_ONLY" != "1" && \
      ( "$FORCE_CATALOG" == "1" || ! -s "$REMEDIATION_DIR/03-implementation-units.tsv" ) ]]; then
  CATALOG_WITH_CODEX=1
fi

# Default REVIEWER_AGENT to IMPLEMENTER_AGENT so --verify works without extra
# configuration. Print a warning when same-model review is used so operators
# know independence is reduced.
if [[ -z "$REVIEWER_AGENT" && -z "${REVIEWER_RUNNER:-}" && -z "${VERIFICATION_RUNNER:-}" && -z "${REVIEW_RUNNER:-}" ]]; then
  REVIEWER_AGENT="$IMPLEMENTER_AGENT"
  if [[ "$VERIFY" == "1" || "$VERIFY_ONLY" == "1" ]]; then
    printf '[warn] REVIEWER_AGENT not set; defaulting to IMPLEMENTER_AGENT=%s. Same-model verification reduces independence — set REVIEWER_AGENT to a different agent for stronger review.\n' "$IMPLEMENTER_AGENT" >&2
  fi
fi

PX_TSV="$REMEDIATION_DIR/00-master-px-list.tsv"
PX_MD="$REMEDIATION_DIR/01-master-px-list.md"
WORKSTREAMS_TSV="$REMEDIATION_DIR/02-workstreams.tsv"
UNITS_TSV="$REMEDIATION_DIR/03-implementation-units.tsv"
AUDIT_SOURCE_MANIFEST="$REMEDIATION_DIR/00-audit-source-manifest.tsv"
SPLIT_CANDIDATES_TSV="$REMEDIATION_DIR/05-split-candidates.tsv"
SPLIT_PLAN_MD="$REMEDIATION_DIR/05-split-plan.md"
COMPLETED_PACKETS_TSV="$REMEDIATION_DIR/04-completed-packets.tsv"

case "$VERIFY_SCOPE" in
  implementation|launch) ;;
  *)
    echo "REMEDIATION_VERIFY_SCOPE must be implementation or launch, got: $VERIFY_SCOPE" >&2
    exit 2
    ;;
esac

unit_selected() {
  local unit_id="$1"
  if [[ -z "$ONLY_UNIT" ]]; then
    return 0
  fi
  case ",$ONLY_UNIT," in
    *,"$unit_id",*) return 0 ;;
    *) return 1 ;;
  esac
}

file_matches() {
  local pattern="$1" file="$2"
  [[ -f "$file" ]] || return 1
  if command -v rg >/dev/null 2>&1; then
    rg -aqi "$pattern" "$file"
  else
    grep -Eaiq "$pattern" "$file"
  fi
}

verifier_findings_tsv_for_unit() {
  printf '%s/artifacts/verify-%s-findings.tsv\n' "$REMEDIATION_DIR" "$1"
}

aggregate_verifier_findings_tsv() {
  printf '%s/05-verifier-findings.tsv\n' "$REMEDIATION_DIR"
}

ensure_verifier_findings_header() {
  local file="$1"
  [[ -s "$file" ]] && return 0
  mkdir -p "$(dirname "$file")"
  printf 'unit_id\tseverity\ttype\tfile\tline\tfinding\trequired_fix\n' > "$file"
}

verifier_finding_type_blocks_auto_revise() {
  local findings="$1"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' '
    NR > 1 && ($3 == "contract_conflict" || $3 == "test_harness" || $3 == "blocked" || $3 == "split_required") {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$findings"
}

verifier_findings_exceed_auto_revise_limit() {
  local findings="$1"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' -v max="$MAX_AUTO_REVISE_FINDINGS" '
    NR > 1 && $1 != "" {
      count += 1
    }
    END { exit count > max ? 0 : 1 }
  ' "$findings"
}

aggregate_verifier_findings() {
  local aggregate
  aggregate="$(aggregate_verifier_findings_tsv)"
  ensure_verifier_findings_header "$aggregate"
  [[ -d "$REMEDIATION_DIR/artifacts" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  printf 'unit_id\tseverity\ttype\tfile\tline\tfinding\trequired_fix\n' > "$tmp"
  find "$REMEDIATION_DIR/artifacts" -maxdepth 1 -name 'verify-*-findings.tsv' -print 2>/dev/null \
    | sort \
    | while IFS= read -r file; do
        tail -n +2 "$file"
      done >> "$tmp"
  mv "$tmp" "$aggregate"
}

combine_unit_lists() {
  printf '%s\n' "$@" |
    tr ',' '\n' |
    awk 'NF && !seen[$0]++ { print }' |
    paste -sd, -
}

pending_split_child_units() {
  local -a units=()
  local unit_id group model_class packet_count packets_csv unit_rationale
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    [[ "$unit_id" == *-S[0-9][0-9] ]] || continue

    local packet_id packet pending=0
    local IFS=,
    for packet_id in $packets_csv; do
      packet="$REMEDIATION_DIR/packets/$packet_id.md"
      if file_matches 'Status:[[:space:]]*`?(pending|not-started|incomplete|partial|blocked|revise)' "$packet"; then
        pending=1
      fi
    done

    if [[ "$pending" == "1" ]]; then
      units+=("$unit_id")
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

pending_implementation_units() {
  local -a units=()
  local unit_id group model_class packet_count packets_csv unit_rationale
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi

    local packet_id packet pending=0 parent_split=0
    local IFS=,
    for packet_id in $packets_csv; do
      packet="$REMEDIATION_DIR/packets/$packet_id.md"
      if file_matches 'Status:[[:space:]]*`?split-into-child-units|split-into-child-units' "$packet"; then
        parent_split=1
      elif file_matches 'Status:[[:space:]]*`?(pending|not-started|incomplete|partial|blocked|revise)' "$packet"; then
        pending=1
      fi
    done

    if [[ "$parent_split" == "0" && "$pending" == "1" ]]; then
      units+=("$unit_id")
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

revised_units_from_verifiers() {
  local -a units=()
  local unit_id group model_class packet_count packets_csv unit_rationale
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi

    local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local findings
    findings="$(verifier_findings_tsv_for_unit "$unit_id")"
    if [[ ! -s "$verifier" ]]; then
      units+=("$unit_id")
      continue
    fi
    if file_matches '(^|[-*[:space:]])Decision:[[:space:]]*`?(stop)|(^|[-*[:space:]])Implementation decision:[[:space:]]*`?(blocked)' "$verifier"; then
      printf '[auto-revise] %s blocked by verifier decision; leaving for manual triage\n' "$unit_id" >&2
      continue
    fi
    if verifier_finding_type_blocks_auto_revise "$findings"; then
      printf '[auto-revise] %s has contract/test-harness/split/blocking verifier findings; leaving for manual triage\n' "$unit_id" >&2
      continue
    fi
    if verifier_findings_exceed_auto_revise_limit "$findings"; then
      printf '[auto-revise] %s has more than %s verifier findings; leaving for manual triage/splitting\n' \
        "$unit_id" "$MAX_AUTO_REVISE_FINDINGS" >&2
      continue
    fi
    if file_matches '(^|[-*[:space:]])Decision:[[:space:]]*`?(revise)|(^|[-*[:space:]])Implementation decision:[[:space:]]*`?(revise)' "$verifier"; then
      units+=("$unit_id")
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

direct_split_candidate_units() {
  local -a units=()
  local parent
  local IFS=,
  for parent in $SPLIT_CANDIDATE_UNITS; do
    [[ -z "${parent:-}" ]] && continue
    if ! awk -F '\t' -v prefix="$parent-S" 'FNR > 1 && index($1, prefix) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$UNITS_TSV"; then
      local packet="$REMEDIATION_DIR/packets/$parent.md"
      if file_matches 'Status:[[:space:]]*`?(pending|not-started|incomplete|partial|blocked|revise)' "$packet"; then
        units+=("$parent")
      fi
    fi
  done

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

normalize_source_path() {
  local path="$1"
  if [[ "$path" == "$REPO_ROOT/"* ]]; then
    printf '%s\n' "${path#"$REPO_ROOT/"}"
  else
    printf '%s\n' "$path"
  fi
}

product_profile_block() {
  if [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]]; then
    cat "$PRODUCT_PROFILE"
  else
    printf 'No product profile was provided. Infer cautiously from the audit run and repo docs, and mark assumptions explicitly.\n'
  fi
}

source_kind() {
  local source="$1"
  case "$source" in
    */01-domain/*) printf 'domain\n' ;;
    */02-cross-cutting/*) printf 'cross-cutting\n' ;;
    */03-spec-additions/*) printf 'spec-addition\n' ;;
    */10-runtime-verification.md|*/artifacts/14*/*|*/logs/14*) printf 'runtime-verification\n' ;;
    */11-maturity-stage-simulation.md|*/12-customer-playbook.md|*/artifacts/15*/*|*/logs/15*) printf 'maturity-customer-proof\n' ;;
    */13-adversarial-review.md|*/14-final-release-decision.md|*/logs/16*) printf 'adversarial-final-decision\n' ;;
    */artifacts/00-bootstrap/spec-inventory.txt|*/artifacts/00-bootstrap/master-prompt-excerpts.txt) printf 'spec-addition\n' ;;
    *) printf 'synthesis\n' ;;
  esac
}

audit_source_files() {
  {
    find "$AUDIT_RUN" -maxdepth 1 -type f -name '*.md'
    find "$AUDIT_RUN/01-domain" "$AUDIT_RUN/02-cross-cutting" "$AUDIT_RUN/03-spec-additions" -type f -name '*.md' 2>/dev/null || true
    find "$AUDIT_RUN/artifacts/00-bootstrap" -maxdepth 1 -type f \( -name 'spec-inventory.txt' -o -name 'master-prompt-excerpts.txt' \) 2>/dev/null || true
    find "$AUDIT_RUN/logs" -maxdepth 1 -type f \( -name '14*.log' -o -name '15*.log' -o -name '16*.log' \) 2>/dev/null || true
    find "$AUDIT_RUN/logs" -maxdepth 1 -type f -name '16c-adversarial-product.log' 2>/dev/null || true
  } | sort -u
}

write_audit_source_manifest() {
  {
    printf 'source_kind\tsource\n'
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      local rel
      rel="$(normalize_source_path "$file")"
      printf '%s\t%s\n' "$(source_kind "$rel")" "$rel"
    done < <(audit_source_files)
  } > "$AUDIT_SOURCE_MANIFEST"
}

classify_group() {
  local source="$1" title="$2"
  local haystack
  haystack="$(printf '%s %s' "$source" "$title" | tr '[:upper:]' '[:lower:]')"

  case "$haystack" in
    *spec-inventory*|*master-prompt-excerpts*|*spec*addition*|*must\ implement*|*contract\ gap*) printf 'spec-contract-gaps\n' ;;
    *runtime-backend*|*runtime-frontend*|*runtime-protocol*|*quality*|*ruff*|*postgres*|*migration-table*|*smoke*) printf 'runtime-quality-gates\n' ;;
    *csrf*|*tenant-isolation*|*support-access*|*mfa-pending*|*rbac*|*auth-boundar*|*data-protection*|*guest-invite*|*guest-access*|*public*invite*|*tenants*|*roles-permissions*) printf 'security-auth\n' ;;
    *scim*|*lifecycle*|*provisioning*|*joiner*|*mover*|*leaver*) printf 'scim-lifecycle\n' ;;
    *saml*|*oidc*|*oauth*|*federation*|*jwks*|*authnrequest*|*replay*|*signing-key*) printf 'protocol-federation\n' ;;
    *iga*|*governance*|*jml*|*access-review*|*reviewer*|*request*approval*|*approver*) printf 'iga-governance\n' ;;
    *migration*|*webhook*|*product*|*entitlement*|*billing*|*market*|*replacement*) printf 'product-integrations\n' ;;
    *audit*|*soc*|*iso*|*gdpr*|*retention*|*evidence*|*compliance*) printf 'audit-compliance\n' ;;
    *frontend*|*ux*|*navigation*|*i18n*|*manual*|*playwright*|*test-coverage*|*selector*) printf 'frontend-ux-tests\n' ;;
    *) printf 'core-platform\n' ;;
  esac
}

model_class_for_group() {
  case "$1" in
    security-auth|scim-lifecycle|protocol-federation|iga-governance|runtime-quality-gates|spec-contract-gaps) printf 'high-risk\n' ;;
    *) printf 'standard\n' ;;
  esac
}

select_model() {
  local class="$1"
  if [[ -n "${CODEX_MODEL:-}" ]]; then
    printf '%s\n' "$CODEX_MODEL"
    return
  fi
  case "$class" in
    coordinator) printf '%s\n' "${CODEX_MODEL_COORDINATOR:-gpt-5.5}" ;;
    planner) printf '%s\n' "${CODEX_MODEL_PLANNER:-gpt-5.5}" ;;
    verifier) printf '%s\n' "${CODEX_MODEL_VERIFIER:-gpt-5.5}" ;;
    reviewer) printf '%s\n' "${CODEX_MODEL_REVIEWER:-gpt-5.5}" ;;
    high-risk) printf '%s\n' "${CODEX_MODEL_HIGH_RISK:-gpt-5.5}" ;;
    *) printf '%s\n' "${CODEX_MODEL_STANDARD:-gpt-5.4}" ;;
  esac
}

select_reasoning() {
  local class="$1"
  if [[ -n "${CODEX_REASONING_EFFORT:-}" ]]; then
    printf '%s\n' "$CODEX_REASONING_EFFORT"
    return
  fi
  case "$class" in
    coordinator) printf '%s\n' "${CODEX_REASONING_COORDINATOR:-high}" ;;
    planner) printf '%s\n' "${CODEX_REASONING_PLANNER:-high}" ;;
    verifier) printf '%s\n' "${CODEX_REASONING_VERIFIER:-high}" ;;
    reviewer) printf '%s\n' "${CODEX_REASONING_REVIEWER:-high}" ;;
    high-risk) printf '%s\n' "${CODEX_REASONING_HIGH_RISK:-high}" ;;
    *) printf '%s\n' "${CODEX_REASONING_STANDARD:-medium}" ;;
  esac
}

# coordinator/planner/high-risk/verifier/reviewer → opus; standard/cataloger → sonnet.
# Packet model_class drives this automatically; no manual per-job override needed.
select_claude_model() {
  local class="$1"
  [[ -n "${CLAUDE_MODEL:-}" ]] && { printf '%s' "$CLAUDE_MODEL"; return; }
  case "$class" in
    coordinator|planner|high-risk|verifier|reviewer) printf '%s' "${CLAUDE_MODEL_HIGH:-claude-opus-4-7}" ;;
    *) printf '%s' "${CLAUDE_MODEL_STANDARD:-claude-sonnet-4-6}" ;;
  esac
}

select_claude_effort() {
  local class="$1"
  [[ -n "${CLAUDE_EFFORT:-}" ]] && { printf '%s' "$CLAUDE_EFFORT"; return; }
  case "$class" in
    cataloger) printf '%s' "${CLAUDE_EFFORT_CATALOGER:-low}" ;;
    coordinator|planner|high-risk|verifier|reviewer) printf '%s' "${CLAUDE_EFFORT_HIGH:-high}" ;;
    *) printf '%s' "${CLAUDE_EFFORT_STANDARD:-medium}" ;;
  esac
}

# coordinator/planner/high-risk/verifier/reviewer → pro; standard/cataloger → flash.
select_gemini_model() {
  local class="$1"
  [[ -n "${GEMINI_MODEL:-}" ]] && { printf '%s' "$GEMINI_MODEL"; return; }
  case "$class" in
    coordinator|planner|high-risk|verifier|reviewer) printf '%s' "${GEMINI_MODEL_HIGH:-gemini-2.5-pro}" ;;
    *) printf '%s' "${GEMINI_MODEL_STANDARD:-gemini-2.5-flash}" ;;
  esac
}

# Called via run_command_with_heartbeat so stdout/stderr are already redirected to the log.
# claude has no -C flag; subshell into REPO_ROOT so its tools resolve paths correctly.
# stream-json+verbose writes each conversation turn as a JSON event immediately rather than
# buffering until task completion. The python3 filter converts events to human-readable text.
_exec_claude() {
  local prompt_file="$1" class="$2"
  local cmd=(claude -p --verbose --output-format stream-json
    --no-session-persistence --dangerously-skip-permissions)
  local model effort mcp_cfg
  model="$(select_claude_model "$class")"
  effort="$(select_claude_effort "$class")"
  [[ -n "$model" ]] && cmd+=(--model "$model")
  [[ -n "$effort" ]] && cmd+=(--effort "$effort")
  if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($CLAUDE_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
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
  )
}

# gemini has no -C flag; same subshell workaround.
_exec_gemini() {
  local prompt_file="$1" class="$2"
  local cmd=(gemini --yolo)
  local model
  model="$(select_gemini_model "$class")"
  [[ -n "$model" ]] && cmd+=(-m "$model")
  if [[ -n "${GEMINI_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($GEMINI_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  (cd "$REPO_ROOT" && "${cmd[@]}" -p "$(cat "$prompt_file")")
}

_exec_codex() {
  local prompt_file="$1" class="$2"
  local cmd=(codex exec --ephemeral --full-auto --skip-git-repo-check -C "$REPO_ROOT")
  local model reasoning
  model="$(select_model "$class")"
  reasoning="$(select_reasoning "$class")"
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ -n "$reasoning" ]] && cmd+=(-c "model_reasoning_effort=\"$reasoning\"")
  [[ -n "${CODEX_PROFILE:-}" ]] && cmd+=(-p "$CODEX_PROFILE")
  if [[ -n "${CODEX_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($CODEX_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  "${cmd[@]}" - <"$prompt_file"
}

review_enabled() {
  [[ -n "$REVIEWER_AGENT" || -n "${REVIEWER_RUNNER:-}" || -n "${VERIFICATION_RUNNER:-}" || -n "${REVIEW_RUNNER:-}" ]]
}

extract_findings() {
  local tmp="$REMEDIATION_DIR/.px-candidates.tsv"
  : > "$tmp"
  write_audit_source_manifest

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    local rel
    rel="$(normalize_source_path "$file")"
    awk -v file="$rel" '
      BEGIN { }
      function clean(s) {
        gsub(/\t/, " ", s)
        sub(/^[[:space:]]*#+[[:space:]]*/, "", s)
        sub(/^[[:space:]]*[-*0-9.)]+[[:space:]]*/, "", s)
        sub(/^[*`_[:space:]]+/, "", s)
        sub(/[*`_[:space:]]+$/, "", s)
        sub(/^[^A-Za-z0-9`]+[[:space:]]*/, "", s)
        return s
      }
      function severity(s) {
        if (match(s, /P[0-9](\/P[0-9])?/)) return substr(s, RSTART, RLENGTH)
        return ""
      }
      function print_finding(sev, line_no, title) {
        title = clean(title)
        sub(/^FAIL[[:space:]]+[—-][[:space:]]*/, "", title)
        sub(/^\[[Pp][0-9]\][[:space:]]*/, "", title)
        sub(/^[Pp][0-9][[:space:]:—-]+/, "", title)
        if (title == "" || title ~ /^RESULT:/ || title ~ /^Result:/) return
        print sev "\t" file "\t" line_no "\t" title
      }
      /[Ss]everity:[[:space:]]*`?[Pp][0-9]/ {
        sev = severity($0)
        if (last_heading != "") print_finding(sev, last_heading_line, last_heading)
        else print_finding(sev, NR, $0)
        next
      }
      /^[[:space:]]*#+[[:space:]]+/ || /^[[:space:]]*[0-9]+[.)][[:space:]]+/ || /^[[:space:]]*[-*][[:space:]]+/ {
        last_heading = $0
        last_heading_line = NR
      }
      /(^|[^A-Za-z0-9])P[0-9](\/P[0-9])?([^A-Za-z0-9]|$)/ {
        if ($0 ~ /[Ss]everity:[[:space:]]*/) next
        if ($0 !~ /^[[:space:]]*#+[[:space:]]+/ && $0 !~ /^[[:space:]]*[0-9]+[.)][[:space:]]+/ && $0 !~ /^[[:space:]]*[-*][[:space:]]+/) next
        sev = severity($0)
        print_finding(sev, NR, $0)
      }
    ' "$file" >> "$tmp"
  done < <(
    {
      audit_source_files
    }
  )

  {
    printf 'id\tseverity\tgroup\tmodel_class\tsource\tline\ttitle\tpacket\n'
    local n=0
    while IFS=$'\t' read -r severity source line title; do
      [[ -z "${source:-}" ]] && continue
      n=$((n + 1))
      local id group model_class packet
      id="$(printf 'PX-%04d' "$n")"
      group="$(classify_group "$source" "$title")"
      model_class="$(model_class_for_group "$group")"
      packet="packets/$id.md"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$severity" "$group" "$model_class" "$source" "$line" "$title" "$packet"
    done < "$tmp"
  } > "$PX_TSV"
}

write_master_markdown() {
  {
    printf '# Master Px Remediation List\n\n'
    printf -- '- Audit run: `%s`\n' "$AUDIT_RUN"
    printf -- '- Generated: `%s`\n' "$(date -Iseconds)"
    printf -- '- Source inventory: `%s`\n\n' "$PX_TSV"
    printf '| ID | Severity | Group | Source | Finding |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    tail -n +2 "$PX_TSV" | while IFS=$'\t' read -r id severity group _model_class source line title _packet; do
      printf '| `%s` | `%s` | `%s` | `%s:%s` | %s |\n' "$id" "$severity" "$group" "$source" "$line" "$title"
    done
  } > "$PX_MD"
}

write_packet() {
  local id="$1" severity="$2" group="$3" model_class="$4" source="$5" line="$6" title="$7"
  local packet="$REMEDIATION_DIR/packets/$id.md"
  if [[ -f "$packet" && "$REMEDIATION_REWRITE_PACKETS" != "1" ]]; then
    return 0
  fi
  local kind
  kind="$(source_kind "$source")"
  local abs_source="$REPO_ROOT/$source"
  if [[ "$source" == /* ]]; then
    abs_source="$source"
  fi
  local start=$((line > 3 ? line - 3 : 1))
  local end=$((line + 18))

  {
    printf '# Remediation Packet %s\n\n' "$id"
    printf -- '- Severity: `%s`\n' "$severity"
    printf -- '- Workstream: `%s`\n' "$group"
    printf -- '- Model class: `%s`\n' "$model_class"
    printf -- '- Source kind: `%s`\n' "$kind"
    printf -- '- Source: `%s:%s`\n' "$source" "$line"
    printf -- '- Finding: %s\n\n' "$title"
    printf '## Source Excerpt\n\n'
    printf '```text\n'
    if [[ -f "$abs_source" ]]; then
      sed -n "${start},${end}p" "$abs_source"
    else
      printf 'Source file not found in current checkout: %s\n' "$source"
    fi
    printf '\n```\n\n'
    printf '## Required Remediation Work\n\n'
    printf '1. Verify the finding against current code and docs before editing.\n'
    printf '2. Fix the defect at the correct backend, frontend, protocol, data, or workflow layer.\n'
    printf '3. Add or update tests that prove success and failure behavior, including authorization, isolation, trust-boundary, integration, and protocol negatives where relevant.\n'
    printf '4. Update the product documentation locations named by the product profile wherever behavior, contracts, workflows, controls, or operator/customer guidance changes. If the repo uses `docs/architecture`, `docs/functional`, or `docs/manual`, keep those layers truthful.\n'
    printf '5. Record the outcome in this packet under `## Work Log`.\n\n'
    if [[ "$kind" == "spec-addition" ]]; then
      printf 'Spec-origin rule: this packet is not documentation polish. Implement the missing product/protocol/workflow contract in code, tests, and docs, or explicitly prove the contract is already implemented and update the packet with that evidence.\n\n'
    fi
    printf '## Suggested Verification\n\n'
    printf -- '- Run the narrowest relevant unit/integration tests first.\n'
    printf -- '- Run affected repo-supported smoke or browser checks when this packet changes an operator workflow.\n'
    printf -- '- Re-run the launch audit phase that originally reported this packet when the workstream is complete.\n\n'
    printf '## Work Log\n\n'
    printf -- '- Status: `not-started`\n'
    printf -- '- Assigned workstream: `%s`\n' "$group"
    printf -- '- Files changed: _pending_\n'
    printf -- '- Docs updated: _pending_\n'
    printf -- '- Verification: _pending_\n'
    printf -- '- Remaining risk: _pending_\n'
  } > "$packet"
}

write_packets_and_workstreams() {
  # Preserve existing run state by default. Reusing REMEDIATION_DIR means packet
  # work logs, normalized workstreams, and cataloged units are durable state.
  if [[ "$REMEDIATION_REWRITE_WORKSTREAMS" == "1" || ! -f "$WORKSTREAMS_TSV" ]]; then
    {
      printf 'group\tmodel_class\tpacket_count\tpackets\n'
      tail -n +2 "$PX_TSV" | awk -F '\t' '
        {
          key = $3 "\t" $4
          count[key] += 1
          if (packets[key] == "") packets[key] = $1
          else packets[key] = packets[key] "," $1
        }
        END {
          for (key in count) {
            print key "\t" count[key] "\t" packets[key]
          }
        }
      ' | sort
    } > "$WORKSTREAMS_TSV"
  fi

  tail -n +2 "$PX_TSV" | while IFS=$'\t' read -r id severity group model_class source line title _packet; do
    write_packet "$id" "$severity" "$group" "$model_class" "$source" "$line" "$title"
  done
}

write_default_units() {
  {
    printf 'unit_id\tpackets\tgroup\tmodel_class\tseverity\trationale\n'
    tail -n +2 "$PX_TSV" | while IFS=$'\t' read -r id severity group model_class _source _line _title _packet; do
      [[ -z "${id:-}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t\n' "$id" "$id" "$group" "$model_class" "$severity"
    done
  } > "$UNITS_TSV"
}

# Merge duplicate unit rows after the manifest has been normalized. A unit ID is
# the artifact/log/checkpoint identity, so duplicate rows would make concurrent
# agents overwrite the same prompt, log, summary, verifier artifact, and
# checkpoint entry.
merge_duplicate_units_tsv() {
  [[ ! -f "$UNITS_TSV" ]] && return 0
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN {
      FS = OFS = "\t"
    }
    FNR == 1 {
      print "unit_id", "packets", "group", "model_class", "severity", "rationale"
      next
    }
    NF == 0 || $1 == "" {
      next
    }
    {
      unit = $1
      if (!(unit in seen_unit)) {
        order[++order_count] = unit
        seen_unit[unit] = 1
        group[unit] = $3
        model_class[unit] = $4
        severity[unit] = $5
        rationale[unit] = $6
      } else {
        duplicate_count += 1
        if (group[unit] != "" && $3 != "" && group[unit] != $3) {
          printf "[normalize-units] duplicate unit_id=%s has conflicting group values: %s vs %s; keeping %s\n", unit, group[unit], $3, group[unit] > "/dev/stderr"
        }
        if (model_class[unit] != "" && $4 != "" && model_class[unit] != $4) {
          printf "[normalize-units] duplicate unit_id=%s has conflicting model_class values: %s vs %s; keeping %s\n", unit, model_class[unit], $4, model_class[unit] > "/dev/stderr"
        }
        if (severity[unit] == "" && $5 != "") {
          severity[unit] = $5
        }
        if (rationale[unit] == "" && $6 != "") {
          rationale[unit] = $6
        } else if ($6 != "" && index(rationale[unit], $6) == 0) {
          rationale[unit] = rationale[unit] " | " $6
        }
      }

      packet_count = split($2, packet_ids, ",")
      for (i = 1; i <= packet_count; i += 1) {
        packet = packet_ids[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", packet)
        if (packet == "") {
          continue
        }
        packet_key = unit SUBSEP packet
        if (!(packet_key in seen_packet)) {
          seen_packet[packet_key] = 1
          if (packets[unit] == "") {
            packets[unit] = packet
          } else {
            packets[unit] = packets[unit] "," packet
          }
        }
      }
    }
    END {
      for (i = 1; i <= order_count; i += 1) {
        unit = order[i]
        print unit, packets[unit], group[unit], model_class[unit], severity[unit], rationale[unit]
      }
      if (duplicate_count > 0) {
        printf "[normalize-units] merged %d duplicate unit row(s) by unit_id\n", duplicate_count > "/dev/stderr"
      }
    }
  ' "$UNITS_TSV" > "$tmp"
  mv "$tmp" "$UNITS_TSV"
}

# Normalize UNITS_TSV to canonical column order: unit_id packets group model_class severity rationale.
# The coordinator (especially claude) may write a different column order; this makes it uniform.
normalize_units_tsv() {
  [[ ! -f "$UNITS_TSV" ]] && return 0
  local col2
  col2="$(head -1 "$UNITS_TSV" | cut -f2)"
  local tmp
  case "$col2" in
    packets|packets_csv)
      # Already canonical — ensure header matches expected name
      merge_duplicate_units_tsv
      return 0
      ;;
    group)
      # Old default format: unit_id group model_class packet_count packets [rationale]
      # Reorder to: unit_id packets group model_class severity rationale
      tmp="$(mktemp)"
      {
        printf 'unit_id\tpackets\tgroup\tmodel_class\tseverity\trationale\n'
        awk 'BEGIN{OFS="\t"; FS="\t"} FNR>1 && NF>0 {print $1,$5,$2,$3,"",""}' "$UNITS_TSV"
      } > "$tmp"
      mv "$tmp" "$UNITS_TSV"
      printf '[normalize-units] converted old format (group col2) to canonical format\n'
      merge_duplicate_units_tsv
      ;;
    packet_id)
      # Claude coordinator format: unit_id packet_id workstream_id title model_class estimated_tokens status
      # Reorder to: unit_id packets group model_class severity rationale
      tmp="$(mktemp)"
      {
        printf 'unit_id\tpackets\tgroup\tmodel_class\tseverity\trationale\n'
        awk 'BEGIN{OFS="\t"; FS="\t"} FNR>1 && NF>0 {print $1,$2,$3,$5,"",""}' "$UNITS_TSV"
      } > "$tmp"
      mv "$tmp" "$UNITS_TSV"
      printf '[normalize-units] converted claude coordinator format (packet_id col2) to canonical format\n'
      merge_duplicate_units_tsv
      ;;
    workstream|workstream_id)
      local header
      header="$(head -1 "$UNITS_TSV")"
      # Rich cataloger format:
      # unit_id workstream_id workstream_name model_class status severity_floor packets title rationale
      if [[ "$header" == $'unit_id\tworkstream_id\tworkstream_name\tmodel_class\tstatus\tseverity_floor\tpackets\t'* ]]; then
        tmp="$(mktemp)"
        {
          printf 'unit_id\tpackets\tgroup\tmodel_class\tseverity\trationale\n'
          awk 'BEGIN{OFS="\t"; FS="\t"} FNR>1 && NF>0 {print $1,$7,($3==""?$2:$3),$4,$6,($9==""?$8:$9)}' "$UNITS_TSV"
        } > "$tmp"
        mv "$tmp" "$UNITS_TSV"
        printf '[normalize-units] converted rich cataloger workstream format to canonical format\n'
        merge_duplicate_units_tsv
        return 0
      fi

      # Legacy format: unit_id workstream[_id] model_class packet_count packets rationale
      # Reorder to: unit_id packets group model_class severity rationale
      tmp="$(mktemp)"
      {
        printf 'unit_id\tpackets\tgroup\tmodel_class\tseverity\trationale\n'
        awk 'BEGIN{OFS="\t"; FS="\t"} FNR>1 && NF>0 {print $1,$5,$2,$3,"",($6==""?"":$6)}' "$UNITS_TSV"
      } > "$tmp"
      mv "$tmp" "$UNITS_TSV"
      printf '[normalize-units] converted workstream format (col2=%s) to canonical format\n' "$col2"
      merge_duplicate_units_tsv
      ;;
    *)
      printf '[normalize-units] unrecognized UNITS_TSV format (col2=%s), leaving as-is\n' "$col2" >&2
      ;;
  esac
}

guard_against_raw_unit_manifest() {
  [[ -f "$UNITS_TSV" ]] || return 0
  [[ "$REMEDIATION_ALLOW_RAW_UNITS" == "1" ]] && return 0
  [[ -n "$ONLY_UNIT" ]] && return 0

  local stats total raw single
  stats="$(raw_incomplete_unit_manifest_stats)"
  IFS=$'\t' read -r total raw single <<< "$stats"

  if ! raw_incomplete_unit_manifest_is_unsafe "$total" "$raw" "$single"; then
    return 0
  fi

  cat >&2 <<EOF
[raw-unit-guard] refusing to execute a raw one-packet implementation manifest.

Manifest: $UNITS_TSV
Rows: total=$total raw_px_unit_ids=$raw single_packet_rows=$single

This means cataloging/coordinator consolidation did not produce implementation-ready
units. Running now would launch one planner/implementer per PX packet and burn quota
without using the combined packet graph.

Fix:
  - Stop this run.
  - Re-run with --force-catalog so 00-cataloger can rewrite $UNITS_TSV, or
    provide a hand-edited implementation-unit TSV that merges related packets.
  - Use --only-unit for a deliberately targeted raw packet run.

Override only when you intentionally want raw per-PX execution:
  REMEDIATION_ALLOW_RAW_UNITS=1
EOF
  return 2
}

guard_against_auto_revise_raw_unit_manifest() {
  [[ -f "$UNITS_TSV" ]] || return 0
  [[ "$REMEDIATION_ALLOW_RAW_UNITS" == "1" ]] && return 0

  local stats total raw single
  stats="$(raw_unit_manifest_stats)"
  IFS=$'\t' read -r total raw single <<< "$stats"

  if ! raw_incomplete_unit_manifest_is_unsafe "$total" "$raw" "$single"; then
    return 0
  fi

  cat >&2 <<EOF
[auto-revise-guard] refusing to auto-revise a raw one-packet implementation manifest.

Manifest: $UNITS_TSV
Rows: total=$total raw_px_unit_ids=$raw single_packet_rows=$single

Automatic revision internally narrows execution with ONLY_UNIT. That must not
bypass the raw-manifest guard, because a stale catalog can otherwise launch one
revision implementer per PX packet.

Fix:
  - Stop this run.
  - Re-run with --force-catalog and the rewrite flags if this remediation state
    is being intentionally rebuilt:
      REMEDIATION_REWRITE_PACKETS=1
      REMEDIATION_REWRITE_WORKSTREAMS=1
      REMEDIATION_REWRITE_UNITS=1
  - Or provide a merged implementation-unit TSV before resuming.

Override only when you intentionally want raw per-PX auto-revision:
  REMEDIATION_ALLOW_RAW_UNITS=1
EOF
  return 2
}

guard_against_incomplete_unit_coverage() {
  [[ "${REMEDIATION_ALLOW_INCOMPLETE_UNIT_COVERAGE:-0}" == "1" ]] && return 0
  [[ -f "$PX_TSV" && -f "$UNITS_TSV" ]] || return 0
  [[ -n "$ONLY_UNIT" ]] && return 0

  local -A assigned_packets=()
  local unit_id packets_csv _group _model _sev _rat px
  while IFS=$'\t' read -r unit_id packets_csv _group _model _sev _rat; do
    [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
    IFS=',' read -ra _unit_packets <<< "$packets_csv"
    for px in "${_unit_packets[@]}"; do
      px="${px//[[:space:]]/}"
      [[ -n "$px" ]] && assigned_packets["$px"]=1
    done
  done < "$UNITS_TSV"

  local total_current=0 incomplete_current=0 missing_count=0 sample_missing=()
  local id severity group model_class source line title packet
  while IFS=$'\t' read -r id severity group model_class source line title packet; do
    [[ "$id" == "id" || -z "${id:-}" ]] && continue
    total_current=$((total_current + 1))
    packet_is_done "$REMEDIATION_DIR/packets/$id.md" "$id" && continue
    incomplete_current=$((incomplete_current + 1))
    if [[ -z "${assigned_packets[$id]:-}" ]]; then
      missing_count=$((missing_count + 1))
      if (( ${#sample_missing[@]} < 12 )); then
        sample_missing+=("$id")
      fi
    fi
  done < "$PX_TSV"

  (( missing_count == 0 )) && return 0

  cat >&2 <<EOF
[unit-coverage-guard] refusing to execute an incomplete implementation-unit manifest.

Manifest: $UNITS_TSV
Master PX inventory: $PX_TSV
Current PX rows: $total_current
Incomplete current PX rows: $incomplete_current
Incomplete PX rows missing from units: $missing_count
Sample missing packets: ${sample_missing[*]}

This means the catalog/unit manifest does not cover the current packet graph.
Running now would silently skip not-started packets.

Fix:
  - Use a fresh REMEDIATION_DIR, or
  - Rebuild the run state with --force-catalog and the rewrite flags when the
    existing state is intentionally being replaced:
      REMEDIATION_REWRITE_PACKETS=1
      REMEDIATION_REWRITE_WORKSTREAMS=1
      REMEDIATION_REWRITE_UNITS=1

Override only for a deliberate partial run:
  REMEDIATION_ALLOW_INCOMPLETE_UNIT_COVERAGE=1
EOF
  return 2
}

raw_unit_manifest_stats() {
  [[ -f "$UNITS_TSV" ]] || {
    printf '0\t0\t0\n'
    return 0
  }
  local total=0 raw=0 single=0 unit_id packets_csv _group _model _sev _rat
  while IFS=$'\t' read -r unit_id packets_csv _group _model _sev _rat; do
    [[ -z "${unit_id:-}" ]] && continue
    total=$((total + 1))
    if [[ "$unit_id" =~ ^PX-[0-9]+$ ]]; then
      raw=$((raw + 1))
    fi
    if [[ "$packets_csv" != *,* ]]; then
      single=$((single + 1))
    fi
  done < <(tail -n +2 "$UNITS_TSV")
  printf '%d\t%d\t%d\n' "$total" "$raw" "$single"
}

raw_incomplete_unit_manifest_stats() {
  [[ -f "$UNITS_TSV" ]] || {
    printf '0\t0\t0\n'
    return 0
  }
  local total=0 raw=0 single=0 unit_id packets_csv _group _model _sev _rat
  while IFS=$'\t' read -r unit_id packets_csv _group _model _sev _rat; do
    [[ -z "${unit_id:-}" ]] && continue
    # Count only units that still have incomplete packets. A raw historical
    # manifest should not block resume when all of its packets are already done.
    [[ -n "$(incomplete_packets_csv "$packets_csv")" ]] || continue
    total=$((total + 1))
    if [[ "$unit_id" =~ ^PX-[0-9]+$ ]]; then
      raw=$((raw + 1))
    fi
    if [[ "$packets_csv" != *,* ]]; then
      single=$((single + 1))
    fi
  done < <(tail -n +2 "$UNITS_TSV")
  printf '%d\t%d\t%d\n' "$total" "$raw" "$single"
}

raw_incomplete_unit_manifest_is_unsafe() {
  local total="$1" raw="$2" single="$3"
  local threshold="${REMEDIATION_RAW_UNIT_ABORT_THRESHOLD:-20}"
  if (( total == 0 || raw < threshold )); then
    return 1
  fi

  local raw_pct=$(( raw * 100 / total ))
  local single_pct=$(( single * 100 / total ))
  if (( raw_pct < 80 || single_pct < 80 )); then
    return 1
  fi

  return 0
}

# Split workstreams in WORKSTREAMS_TSV before coordinator dispatch.
# Level 1 (always): split by Source kind when multiple kinds exist in a workstream.
# Level 2: split by source file stem when a kind-group exceeds MAX_WORKSTREAM_PACKETS.
# Level 3: numeric batching when a file-group still exceeds MAX_WORKSTREAM_PACKETS.
normalize_workstream_sizes() {
  local max="${MAX_WORKSTREAM_PACKETS:-80}"
  local packets_dir="$REMEDIATION_DIR/packets"

  local tmp
  tmp="$(mktemp)"
  head -1 "$WORKSTREAMS_TSV" > "$tmp"
  local any_split=0

  while IFS=$'\t' read -r f1 f2 f3 f4 _rest; do
    local group model_class packets_csv
    if [[ "$f1" == WS-* ]]; then
      group="$f1"; model_class="$f3"; packets_csv="$f4"
    else
      group="$f1"; model_class="$f2"; packets_csv="$f4"
    fi
    [[ -z "${group:-}" ]] && continue

    # Level 1: always group by Source kind.
    # If all packets share the same kind (or have no kind), keep the group as-is.
    local -A kind_map=()
    local -a all_pxs
    IFS=',' read -ra all_pxs <<< "$packets_csv"
    for px in "${all_pxs[@]}"; do
      local kind
      kind=$(grep "^- Source kind:" "$packets_dir/$px.md" 2>/dev/null | head -1 | grep -oP '`[^`]+`' | tr -d '`')
      [[ -z "$kind" ]] && kind="other"
      kind="${kind// /-}"
      kind_map[$kind]="${kind_map[$kind]:+${kind_map[$kind]},}$px"
    done

    local num_kinds="${#kind_map[@]}"

    if (( num_kinds <= 1 )); then
      # Single source kind — keep as one group, still apply size cap below.
      local count="${#all_pxs[@]}"
      if (( count <= max )); then
        printf '%s\t%s\t%d\t%s\n' "$group" "$model_class" "$count" "$packets_csv" >> "$tmp"
      else
        # Level 3 directly: numeric batching
        printf '[normalize-workstreams] %s: %d packets, batching numerically\n' "$group" "$count"
        any_split=1
        local -a batch=(); local bn=1
        for px in "${all_pxs[@]}"; do
          batch+=("$px")
          if (( ${#batch[@]} >= max )); then
            local bc; printf -v bc '%s,' "${batch[@]}"; bc="${bc%,}"
            printf '%s\t%s\t%d\t%s\n' "${group}-${bn}" "$model_class" "${#batch[@]}" "$bc" >> "$tmp"
            bn=$(( bn + 1 )); batch=()
          fi
        done
        if (( ${#batch[@]} > 0 )); then
          local bc; printf -v bc '%s,' "${batch[@]}"; bc="${bc%,}"
          printf '%s\t%s\t%d\t%s\n' "${group}-${bn}" "$model_class" "${#batch[@]}" "$bc" >> "$tmp"
        fi
      fi
      continue
    fi

    # Multiple source kinds — split into sub-groups.
    printf '[normalize-workstreams] %s: splitting %d packets into %d source-kind groups\n' \
      "$group" "${#all_pxs[@]}" "$num_kinds"
    any_split=1

    for kind in "${!kind_map[@]}"; do
      local sg="${group}-${kind}"
      local sg_csv="${kind_map[$kind]}"
      local -a sg_pxs
      IFS=',' read -ra sg_pxs <<< "$sg_csv"
      local sg_count="${#sg_pxs[@]}"

      if (( sg_count <= max )); then
        printf '%s\t%s\t%d\t%s\n' "$sg" "$model_class" "$sg_count" "$sg_csv" >> "$tmp"
        continue
      fi

      printf '[normalize-workstreams] %s: %d packets, splitting by source file\n' "$sg" "$sg_count"

      # Level 2: group by source file stem
      local -A stem_map=()
      for px in "${sg_pxs[@]}"; do
        local src stem
        src=$(grep "^- Source:" "$packets_dir/$px.md" 2>/dev/null | head -1 | grep -oP '`[^`]+`' | tr -d '`')
        stem=$(basename "${src%%:*}" 2>/dev/null | sed 's/\.[^.]*$//')
        [[ -z "$stem" ]] && stem="other"
        stem_map[$stem]="${stem_map[$stem]:+${stem_map[$stem]},}$px"
      done

      for stem in "${!stem_map[@]}"; do
        local stg="${sg}-${stem}"
        local stg_csv="${stem_map[$stem]}"
        local -a stg_pxs
        IFS=',' read -ra stg_pxs <<< "$stg_csv"
        local stg_count="${#stg_pxs[@]}"

        if (( stg_count <= max )); then
          printf '%s\t%s\t%d\t%s\n' "$stg" "$model_class" "$stg_count" "$stg_csv" >> "$tmp"
        else
          # Level 3: numeric batching
          printf '[normalize-workstreams] %s: %d packets, batching numerically\n' "$stg" "$stg_count"
          local -a batch=(); local bn=1
          for px in "${stg_pxs[@]}"; do
            batch+=("$px")
            if (( ${#batch[@]} >= max )); then
              local bc; printf -v bc '%s,' "${batch[@]}"; bc="${bc%,}"
              printf '%s\t%s\t%d\t%s\n' "${stg}-${bn}" "$model_class" "${#batch[@]}" "$bc" >> "$tmp"
              bn=$(( bn + 1 )); batch=()
            fi
          done
          if (( ${#batch[@]} > 0 )); then
            local bc; printf -v bc '%s,' "${batch[@]}"; bc="${bc%,}"
            printf '%s\t%s\t%d\t%s\n' "${stg}-${bn}" "$model_class" "${#batch[@]}" "$bc" >> "$tmp"
          fi
        fi
      done
    done
  done < <(tail -n +2 "$WORKSTREAMS_TSV")

  mv "$tmp" "$WORKSTREAMS_TSV"
  if [[ "$any_split" -eq 1 ]]; then
    printf '[normalize-workstreams] done: %d workstreams\n' "$(tail -n +2 "$WORKSTREAMS_TSV" | grep -c .)"
  fi
}

# Associative array populated by build_implemented_packet_set.
# Maps packet ID -> 1 for packets whose implementation unit was checkpointed fixed.
# Declared here so packet_is_done can reference it without a separate argument.
declare -gA _IMPLEMENTED_PACKETS=()

# Build _IMPLEMENTED_PACKETS from the checkpoint + UNITS_TSV + summary artifacts,
# then stamp Status: complete into any packet file that is done but unstamped.
# This makes completion state durable in the packet files themselves.
packet_has_terminal_status() {
  local pfile="$1"
  [[ -f "$pfile" ]] || return 1
  file_matches 'Status:[[:space:]]*`?(complete|fixed|split-into-child-units|deferred)' "$pfile"
}

stamp_packet_complete() {
  local px="$1" source_label="$2" pfile="$REMEDIATION_DIR/packets/$px.md"
  [[ -f "$pfile" ]] || return 1
  packet_has_terminal_status "$pfile" && return 1
  printf '\n- Status: `complete`\n' >> "$pfile"
}

remediation_dir_audit_run() {
  local rdir="$1"
  sed -n 's/^- Audit run: `\(.*\)`$/\1/p' "$rdir/01-master-px-list.md" 2>/dev/null | head -1
}

packet_row_key() {
  local px="$1" px_tsv="$2"
  awk -F '\t' -v px="$px" 'NR > 1 && $1 == px { print $5 "\t" $6 "\t" $7; found = 1; exit } END { if (!found) exit 1 }' "$px_tsv" 2>/dev/null
}

remediation_state_exists() {
  [[ -s "$WORKSTREAMS_TSV" || -s "$UNITS_TSV" || -s "$CHECKPOINT_FILE" ]] && return 0
  find "$REMEDIATION_DIR/packets" -maxdepth 1 -name 'PX-*.md' -print -quit 2>/dev/null | grep -q .
}

guard_reused_px_inventory() {
  local previous_px_tsv="$1"
  [[ -n "$previous_px_tsv" && -f "$previous_px_tsv" && -f "$PX_TSV" ]] || return 0
  cmp -s "$previous_px_tsv" "$PX_TSV" && return 0
  remediation_state_exists || return 0

  if [[ "$FORCE_CATALOG" == "1" && "$REMEDIATION_REWRITE_PACKETS" == "1" && \
        "$REMEDIATION_REWRITE_WORKSTREAMS" == "1" && "$REMEDIATION_REWRITE_UNITS" == "1" ]]; then
    printf '[manifest-guard] master PX inventory changed; rewriting packets/workstreams/units because explicit rewrite flags and --force-catalog are set\n' >&2
    return 0
  fi

  if [[ "${REMEDIATION_ALLOW_PX_INVENTORY_DRIFT:-0}" == "1" ]]; then
    printf '[manifest-guard] warning: master PX inventory changed but REMEDIATION_ALLOW_PX_INVENTORY_DRIFT=1 is set; preserving existing state\n' >&2
    return 0
  fi

  cat >&2 <<EOF
[manifest-guard] refusing to reuse remediation state after the master PX inventory changed.

Remediation dir: $REMEDIATION_DIR
Previous inventory: $previous_px_tsv
Current inventory: $PX_TSV

Existing packet files, workstreams, implementation units, checkpoints, and
artifacts are keyed by PX IDs. If the master inventory changes underneath that
state, a packet such as PX-0021 can point at one defect while manifests or
artifacts point at another. Running agents in that state can skip real work or
send implementers after the wrong files.

Fix:
  - Use a fresh REMEDIATION_DIR for the changed audit inventory, or
  - Re-run against the exact audit inputs that produced this remediation dir, or
  - If replacing this run state is intentional, rerun with:
      REMEDIATION_REWRITE_PACKETS=1
      REMEDIATION_REWRITE_WORKSTREAMS=1
      REMEDIATION_REWRITE_UNITS=1
      --force-catalog

Override only for manual recovery after inspecting the mismatch:
  REMEDIATION_ALLOW_PX_INVENTORY_DRIFT=1
EOF
  exit 2
}

guard_existing_px_inventory_consistency() {
  [[ -f "$PX_TSV" ]] || return 0
  [[ -d "$REMEDIATION_DIR/packets" ]] || return 0

  local packet_file_count px_row_count unit_unknown_count
  packet_file_count="$(find "$REMEDIATION_DIR/packets" -maxdepth 1 -name 'PX-*.md' -printf '.' 2>/dev/null | wc -c | tr -d ' ')"
  px_row_count="$(awk 'NR > 1 && $1 ~ /^PX-/ { count += 1 } END { print count + 0 }' "$PX_TSV")"
  unit_unknown_count=0
  if [[ -f "$UNITS_TSV" ]]; then
    unit_unknown_count="$(
      awk -F '\t' '
        NR == FNR {
          if (FNR > 1 && $1 ~ /^PX-/) known[$1] = 1
          next
        }
        FNR == 1 {
          packet_col = 2
          for (i = 1; i <= NF; i += 1) {
            if ($i == "packets" || $i == "packets_csv") packet_col = i
          }
          next
        }
        FNR > 1 {
          split($packet_col, ids, ",")
          for (i in ids) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", ids[i])
            if (ids[i] ~ /^PX-/ && !(ids[i] in known)) unknown[ids[i]] = 1
          }
        }
        END {
          for (id in unknown) count += 1
          print count + 0
        }
      ' "$PX_TSV" "$UNITS_TSV"
    )"
  fi

  if (( packet_file_count > px_row_count || unit_unknown_count > 0 )); then
    cat >&2 <<EOF
[manifest-guard] refusing to preserve an inconsistent remediation inventory.

Remediation dir: $REMEDIATION_DIR
Master PX inventory: $PX_TSV
Packet files: $packet_file_count
Master PX rows: $px_row_count
Unit packet IDs missing from master: $unit_unknown_count

The run directory has cataloged packets or units that are not represented in
the master inventory. Resuming would let the runner skip real packet work.

Fix:
  - Restore the matching cataloged $PX_TSV, or
  - Rebuild this run with:
      REMEDIATION_REWRITE_PACKETS=1
      REMEDIATION_REWRITE_WORKSTREAMS=1
      REMEDIATION_REWRITE_UNITS=1
      --force-catalog
EOF
    exit 2
  fi
}

packet_row_matches_current_run() {
  local px="$1" prior_dir="$2"
  local current_key prior_key
  current_key="$(packet_row_key "$px" "$PX_TSV" || true)"
  prior_key="$(packet_row_key "$px" "$prior_dir/00-master-px-list.tsv" || true)"
  [[ -n "$current_key" && "$current_key" == "$prior_key" ]]
}

mark_fixed_packets_from_summary() {
  local summary="$1" source_dir="$2" require_row_match="$3"
  grep -qi 'IMPLEMENTATION_RESULT:[[:space:]]*fixed' "$summary" 2>/dev/null || return 0
  local px
  while IFS= read -r px; do
    [[ -n "$px" ]] || continue
    if [[ "$require_row_match" == "1" ]] && ! packet_row_matches_current_run "$px" "$source_dir"; then
      continue
    fi
    _IMPLEMENTED_PACKETS[$px]=1
  done < <(grep -oE 'PX-[0-9]{4}' "$summary" | sort -u)
}

recover_packets_from_prior_remediation_runs() {
  [[ "$REMEDIATION_IMPORT_PRIOR_RUNS" == "1" ]] || return 0
  [[ -f "$PX_TSV" ]] || return 0
  local parent_dir current_audit prior_dir prior_audit summary imported_before imported_after imported
  parent_dir="$(dirname "$REMEDIATION_DIR")"
  current_audit="$(remediation_dir_audit_run "$REMEDIATION_DIR")"
  [[ -n "$current_audit" ]] || current_audit="$AUDIT_RUN"
  imported_before="${#_IMPLEMENTED_PACKETS[@]}"

  shopt -s nullglob
  for prior_dir in "$parent_dir"/*-remediation-run; do
    [[ "$prior_dir" != "$REMEDIATION_DIR" ]] || continue
    [[ -f "$prior_dir/00-master-px-list.tsv" ]] || continue
    if [[ -f "$prior_dir/.remediation-no-import" || -f "$prior_dir/DO-NOT-IMPORT" ]]; then
      printf '[resume] skipping quarantined prior remediation run: %s\n' "$prior_dir"
      continue
    fi
    prior_audit="$(remediation_dir_audit_run "$prior_dir")"
    [[ -n "$prior_audit" && "$prior_audit" == "$current_audit" ]] || continue
    for summary in "$prior_dir"/artifacts/*-summary.md; do
      mark_fixed_packets_from_summary "$summary" "$prior_dir" 1
    done
  done
  shopt -u nullglob

  imported_after="${#_IMPLEMENTED_PACKETS[@]}"
  imported=$(( imported_after - imported_before ))
  if (( imported > 0 )); then
    printf '[resume] recovered %d fixed packet(s) from prior same-audit remediation runs\n' "$imported"
  fi
}

build_implemented_packet_set() {
  local write_stamps="${1:-1}"
  _IMPLEMENTED_PACKETS=()
  [[ ! -f "$UNITS_TSV" ]] && return 0
  while IFS=$'\t' read -r unit_id packets_csv _group _model _sev _rat; do
    [[ -z "${unit_id:-}" ]] && continue
    grep -qxF "implement-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || continue
    local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    grep -qi 'IMPLEMENTATION_RESULT:[[:space:]]*fixed' "$summary" 2>/dev/null || continue
    local IFS=,
    local px
    for px in $packets_csv; do
      local pfile="$REMEDIATION_DIR/packets/$px.md"
      if [[ -f "$pfile" ]] && file_matches 'Status:[[:space:]]*`?(complete|fixed|split-into-child-units|deferred)' "$pfile"; then
        _IMPLEMENTED_PACKETS[$px]=1
        continue
      fi
      if ! grep -qF "$px" "$summary" 2>/dev/null; then
        printf '[resume] checkpoint implement-%s has fixed summary but does not mention packet %s; leaving packet incomplete\n' \
          "$unit_id" "$px" >&2
        continue
      fi
      _IMPLEMENTED_PACKETS[$px]=1
    done
  done < <(tail -n +2 "$UNITS_TSV")

  # Recovery path for reused remediation directories whose unit manifest was
  # accidentally regenerated. Summary artifacts are the durable implementation
  # proof, so scan them directly and map any mentioned packets back to done.
  local summary
  shopt -s nullglob
  for summary in "$REMEDIATION_DIR"/artifacts/*-summary.md; do
    mark_fixed_packets_from_summary "$summary" "$REMEDIATION_DIR" 0
  done
  shopt -u nullglob

  recover_packets_from_prior_remediation_runs

  [[ "$write_stamps" == "1" ]] || return 0

  # Stamp Status: complete into packet files that are done but unstamped.
  local stamped=0
  for px in "${!_IMPLEMENTED_PACKETS[@]}"; do
    local pfile="$REMEDIATION_DIR/packets/$px.md"
    [[ -f "$pfile" ]] || continue
    if packet_has_terminal_status "$pfile"; then
      continue
    fi
    if stamp_packet_complete "$px" "fixed implementation artifact"; then
      stamped=$(( stamped + 1 ))
    fi
  done
  if [[ "$stamped" -gt 0 ]]; then
    printf '[stamp] wrote Status: complete to %d packet files\n' "$stamped"
  fi
}

write_completed_packet_manifest() {
  {
    printf 'packet\tstatus\tsource\tline\ttitle\n'
    [[ -f "$PX_TSV" ]] || return 0
    local id severity group model_class source line title packet
    while IFS=$'\t' read -r id severity group model_class source line title packet; do
      [[ "$id" == "id" || -z "${id:-}" ]] && continue
      if packet_is_done "$REMEDIATION_DIR/packets/$id.md" "$id"; then
        printf '%s\tcomplete\t%s\t%s\t%s\n' "$id" "$source" "$line" "$title"
      fi
    done < "$PX_TSV"
  } > "$COMPLETED_PACKETS_TSV"
}

# Returns 0 (true) if a packet is done. Checks in order:
#   1. Explicit Status: complete/fixed/split-into-child-units/deferred in the packet file.
#   2. Packet belongs to a unit that was checkpointed with IMPLEMENTATION_RESULT: fixed.
packet_is_done() {
  local pfile="$1" px="${2:-}"
  [[ -f "$pfile" ]] || return 1
  if packet_has_terminal_status "$pfile"; then
    return 0
  fi
  if [[ -n "$px" && -v "_IMPLEMENTED_PACKETS[$px]" ]]; then
    return 0
  fi
  return 1
}

# Given a comma-separated list of packet IDs, returns a CSV of only those
# packets that are not yet complete. Empty output means all packets are done.
incomplete_packets_csv() {
  local packets_csv="$1"
  local -a result=()
  local IFS=,
  local px
  for px in $packets_csv; do
    packet_is_done "$REMEDIATION_DIR/packets/$px.md" "$px" || result+=("$px")
  done
  if (( ${#result[@]} > 0 )); then
    local IFS=,
    printf '%s' "${result[*]}"
  fi
}

artifact_mentions_all_packets() {
  local artifact="$1" packets_csv="$2"
  [[ -s "$artifact" ]] || return 1
  local IFS=,
  local px
  for px in $packets_csv; do
    [[ -z "${px:-}" ]] && continue
    grep -qF "$px" "$artifact" 2>/dev/null || return 1
  done
  return 0
}

packet_paths_for_ids() {
  local ids_csv="$1"
  local IFS=,
  local ids=($ids_csv)
  local id
  for id in "${ids[@]}"; do
    printf '%s/packets/%s.md\n' "$REMEDIATION_DIR" "$id"
  done
}

build_coordinator_prompt() {
  local prompt="$REMEDIATION_DIR/prompts/00-coordinator.md"
  cat > "$prompt" <<PROMPT
# Remediation Coordinator

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Master Px list: $PX_MD
- Workstreams: $WORKSTREAMS_TSV
- Product profile: ${PRODUCT_PROFILE:-"(none)"}
- Implementation units: $UNITS_TSV
- Verification scope: $VERIFY_SCOPE

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Coordinator Instructions

**ROLE CONSTRAINT — READ THIS FIRST**: You are a COORDINATOR, not an implementer. You must NOT write any product source code, commit changes, run tests, or modify any files outside the remediation directory ($REMEDIATION_DIR). Shared rules 1–9 above describe what IMPLEMENTERS must do; they do not apply to your coordination role. Rule 10 is the operative rule for you: coordination is planning only.

Review the master Px list and workstream grouping.

Manifest invariant: each \`unit_id\` in \`$UNITS_TSV\` must appear exactly once. If multiple packets belong to the same implementation unit, put all packet IDs in that row's comma-separated \`packets\` field. Never create repeated rows with the same \`unit_id\`; repeated IDs cause prompt, log, summary, verifier, and checkpoint artifact collisions.

Write \`$REMEDIATION_DIR/03-coordinator-plan.md\` with:

1. Ordered workstream waves, preserving parallel-safe grouping.
2. Any packet moves or merges needed to avoid file ownership conflicts.
3. Any implementation units in \`$UNITS_TSV\` that should be merged or split before implementation.
4. The exact verification gates required before rerunning the audit.
5. A context-budget warning for any workstream or implementation unit likely to exceed 200k tokens.

If the generated grouping is acceptable, say so and leave \`$WORKSTREAMS_TSV\` and \`$UNITS_TSV\` unchanged.
PROMPT
}

build_workstream_coordinator_prompt() {
  local group="$1" model_class="$2" packets_csv="$3"
  local prompt="$REMEDIATION_DIR/prompts/coordinate-$group.md"

  # Only show the coordinator packets that haven't been completed yet.
  local incomplete_csv
  incomplete_csv="$(incomplete_packets_csv "$packets_csv")"
  if [[ -z "$incomplete_csv" ]]; then
    # All packets complete — write a stub prompt so the file exists but mark it skip.
    printf '# Workstream Coordinator: %s\n\nAll packets complete — no coordination required.\n' "$group" > "$prompt"
    return 0
  fi

  local packet_list
  packet_list="$(packet_paths_for_ids "$incomplete_csv")"
  local total_count incomplete_count
  total_count=$(tr ',' '\n' <<< "$packets_csv" | grep -c .)
  incomplete_count=$(tr ',' '\n' <<< "$incomplete_csv" | grep -c .)

  cat > "$prompt" <<PROMPT
# Workstream Coordinator: $group

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Workstream: $group
- Model class: $model_class
- Total packets: $total_count
- Incomplete packets: $incomplete_count (packets with Status: complete/fixed/split-into-child-units/deferred are excluded)
- Incomplete packet IDs: $incomplete_csv
- Implementation units manifest: $UNITS_TSV
- Product profile: ${PRODUCT_PROFILE:-"(none)"}

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Incomplete Packets (to coordinate)

\`\`\`text
$packet_list
\`\`\`

## Workstream Coordinator Instructions

**ROLE CONSTRAINT — READ THIS FIRST**: You are a WORKSTREAM COORDINATOR, not an implementer. You must NOT write any product source code, commit changes, run tests, or modify any files outside the remediation directory ($REMEDIATION_DIR). Shared rules 1–9 above describe what IMPLEMENTERS must do; they do not apply to your coordination role. Rule 10 is the operative rule for you: coordination is planning only. Allowed writes: $UNITS_TSV, $REMEDIATION_DIR/artifacts/coordinate-$group.md, and packet work-log fields. Nothing else.

**Packet status**: Only incomplete packets are listed above. Packets with \`Status: complete\`, \`fixed\`, \`split-into-child-units\`, or \`deferred\` have already been handled and must not be reassigned or given new unit IDs. When updating \`$UNITS_TSV\`, preserve the existing unit IDs for completed packets — add or modify only units for the incomplete packets listed above.

Review the incomplete packets and \`$UNITS_TSV\`. Decide whether the default one-packet-per-unit split is correct.

Manifest invariant: each \`unit_id\` in \`$UNITS_TSV\` must appear exactly once. If multiple packets belong to the same implementation unit, merge them into the comma-separated \`packets\` field of a single row. Never add repeated rows with the same \`unit_id\`; repeated IDs collide on the same prompt, log, summary, verifier, and checkpoint artifact paths.

You may update only:

- \`$UNITS_TSV\`
- \`$REMEDIATION_DIR/artifacts/coordinate-$group.md\`
- packet work-log coordination notes if a packet is merged, split, deferred, or moved.

Write \`$REMEDIATION_DIR/artifacts/coordinate-$group.md\` with:

1. The implementation units for this workstream.
2. File ownership or sequencing constraints.
3. Which packets can run in parallel and which must be serialized.
4. Required docs and verification gates per implementation unit.
5. Context-budget risks for any unit that may exceed 200000 tokens.

Model class guidance for units you create or update: \`high-risk\` for security, tenant isolation, protocol, SCIM/lifecycle, IGA, migration, runtime quality; \`complex\` for multi-file architectural changes that need a design phase before implementation; \`standard\` for narrow UI/docs/test/cleanup work. High-risk and complex units run through a planner before the implementer.

If the default unit split is acceptable, state that and leave \`$UNITS_TSV\` unchanged.
PROMPT
}

build_catalog_prompt() {
  local prompt="$REMEDIATION_DIR/prompts/00-cataloger.md"
  cat > "$prompt" <<PROMPT
# Remediation Cataloger

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Seed Px TSV: $PX_TSV
- Seed Px markdown: $PX_MD
- Audit source manifest: $AUDIT_SOURCE_MANIFEST
- Seed workstreams: $WORKSTREAMS_TSV
- Seed implementation units: $UNITS_TSV
- Seed packets directory: $REMEDIATION_DIR/packets
- Completed packet manifest: $COMPLETED_PACKETS_TSV
- Product profile: ${PRODUCT_PROFILE:-"(none)"}

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Cataloger Instructions

You are not implementing remediation. You are creating the best possible remediation catalog from the completed audit.

Use the generated seed inventory as a starting point, then inspect the audit reports under:

- \`$AUDIT_RUN/*.md\`
- \`$AUDIT_RUN/01-domain/*.md\`
- \`$AUDIT_RUN/02-cross-cutting/*.md\`
- \`$AUDIT_RUN/03-spec-additions/*.md\`
- \`$AUDIT_RUN/artifacts/00-bootstrap/spec-inventory.txt\`
- \`$AUDIT_RUN/artifacts/00-bootstrap/master-prompt-excerpts.txt\`
- \`$AUDIT_RUN/10-runtime-verification.md\`
- \`$AUDIT_RUN/11-maturity-stage-simulation.md\`
- \`$AUDIT_RUN/12-customer-playbook.md\`
- \`$AUDIT_RUN/13-adversarial-review.md\`
- \`$AUDIT_RUN/14-final-release-decision.md\`
- \`$AUDIT_RUN/logs/14*.log\`, \`$AUDIT_RUN/logs/15*.log\`, and \`$AUDIT_RUN/logs/16*.log\` when the markdown artifacts cite missing or incomplete evidence.
- \`$AUDIT_RUN/logs/16c-adversarial-product.log\` if it exists, because the final decision says 16C was not fully merged.

Rewrite these files with a deduplicated, implementation-ready catalog:

1. \`$PX_TSV\`
2. \`$PX_MD\`
3. \`$WORKSTREAMS_TSV\`
4. \`$UNITS_TSV\`
5. \`$REMEDIATION_DIR/packets/PX-*.md\`

Catalog requirements:

- First read \`$COMPLETED_PACKETS_TSV\` and the seed packet work logs. Completed packet IDs represent already-fixed work recovered from current or prior same-audit remediation artifacts.
- One packet should represent one coherent remediation outcome, not every repeated mention of the same defect.
- Merge duplicate mentions across domain, cross-cutting, spec-addition, runtime, maturity, customer-proof, adversarial, and final-decision reports.
- When a deduplicated packet consists only of already-completed seed packets, preserve that completion in the merged packet work log and set \`Status: complete\`.
- When a deduplicated packet includes both completed and incomplete seed packets, keep the merged packet incomplete, but list the completed seed packet IDs and evidence in the work log so the implementer does not redo closed work.
- Do not convert completed work back to \`not-started\` merely because packet IDs or implementation units are being deduplicated.
- Treat spec inventory, product profile, and master-prompt deltas as first-class packet sources. If a required product capability appears in the profile/spec prompt but lacks implementation, docs, tests, or launch evidence, create or merge a packet for that missing contract.
- Do not collapse spec-origin requirements into "evidence pending" when code/docs/tests are missing. Split implementation work from launch-proof work when needed.
- Keep severity as the highest severity found for the outcome.
- Preserve source evidence with multiple audit references when merged.
- Group mixed P0/P1/P2 packets together when they belong to the same implementation surface and can be fixed by one agent.
- Split implementation units that would exceed roughly 200k tokens or create file ownership conflicts.
- Default to one implementation unit per packet for high-risk P0s unless the same code/doc/test change clearly closes several packets together.
- Write \`$UNITS_TSV\` with this exact tab-separated header and column order: \`unit_id	packets	group	model_class	severity	rationale\`.
- In \`$UNITS_TSV\`, put all packet IDs covered by the unit in the comma-separated \`packets\` column. Do not write alternate schemas such as \`workstream_id/workstream_name/status/severity_floor/title\`; the runner consumes the canonical six-column schema.
- Select model class per unit: \`high-risk\` for security, tenant isolation, protocol, SCIM/lifecycle, IGA execution, migration runtime correctness, and runtime quality gates; \`complex\` for multi-file architectural changes that require design before implementation (cross-cutting state machines, permission model restructuring, API contract changes); \`standard\` for narrow UI/docs/test-harness/product cleanup. High-risk and complex units run through a planner agent that writes an implementation design before the implementer runs.
- Every packet must include required docs updates for the documentation locations named by the product profile. If the repo uses \`docs/architecture\`, \`docs/functional\`, or \`docs/manual\`, update the relevant layer when behavior or customer/operator workflows change.
- Every packet must include verification gates.
- Every packet must include a \`## Work Log\` section. Initialize it to \`not-started\` only when none of the merged seed packets are listed as complete in \`$COMPLETED_PACKETS_TSV\`.

Do not edit product code. Do not start remediation.
PROMPT
}

detect_split_candidates() {
  {
    printf 'unit_id\tgroup\tmodel_class\tpackets\treasons\tsummary\tverifier\tlog\n'
    tail -n +2 "$UNITS_TSV" | while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
      [[ -z "${unit_id:-}" ]] && continue
      if ! unit_selected "$unit_id"; then
        continue
      fi
      if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
        continue
      fi

      local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
      local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
      local log="$REMEDIATION_DIR/logs/implement-$unit_id.log"
      local reasons=()
      local packet_bytes=0

      if [[ "$unit_id" == *-S[0-9][0-9] ]]; then
        continue
      fi
      if [[ "$packets_csv" == *-S[0-9][0-9]* ]]; then
        continue
      fi
      local parent_split=0
      local IFS=,
      local packet_id
      for packet_id in $packets_csv; do
        local packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
        if file_matches 'Status:[[:space:]]*`?split-into-child-units|split-into-child-units' "$packet_file"; then
          parent_split=1
        fi
        if [[ -f "$packet_file" ]]; then
          local bytes
          bytes="$(wc -c <"$packet_file" | tr -d ' ')"
          packet_bytes=$((packet_bytes + bytes))
          if ((bytes > MAX_PACKET_BYTES)); then
            reasons+=("oversized-packet")
          fi
        fi
      done
      if [[ "$parent_split" == "1" ]]; then
        continue
      fi

      if file_matches '(^|[^[:alpha:]])(RESULT:[[:space:]]*)?INCOMPLETE|IMPLEMENTATION_RESULT:[[:space:]]*(partial|blocked)|packet status.*INCOMPLETE|too broad|monolith|i18n debt remains|decomposition|exceed(ed|s)? .*context|context .*exceed|over .*200000|above .*200000' "$summary"; then
        reasons+=("summary-incomplete-or-partial")
      fi
      if file_matches 'too broad|monolith|split into|should split|needs splitting|exceed(ed|s)? .*context|context .*exceed|token budget|tokens used|over .*200000|above .*200000|decompose|decomposition|i18n remediation|audited-page|not satisfied.*monolith|not satisfied.*inline English' "$verifier"; then
        reasons+=("verifier-split-signal")
      fi
      if file_matches 'tokens used.*([2-9][0-9]{5,}|[2-9][0-9]{2},[0-9]{3}|[0-9]{1,3},[0-9]{3},[0-9]{3})|exceed(ed|s)? .*200000|above .*200000|over .*200000' "$log"; then
        reasons+=("token-budget-risk")
      fi
      if ((packet_bytes > MAX_UNIT_PACKET_BYTES)); then
        reasons+=("oversized-unit-packet-text")
      fi

      if ((${#reasons[@]} > 0)); then
        local reason_text
        reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$unit_id" "$group" "$model_class" "$packets_csv" "$reason_text" "$summary" "$verifier" "$log"
      fi
    done
  } > "$SPLIT_CANDIDATES_TSV"
}

build_split_prompt() {
  local prompt="$REMEDIATION_DIR/prompts/05-split-incomplete.md"
  cat > "$prompt" <<PROMPT
# Incomplete Packet Splitter

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Implementation units manifest: $UNITS_TSV
- Workstreams manifest: $WORKSTREAMS_TSV
- Split candidates: $SPLIT_CANDIDATES_TSV
- Split plan output: $SPLIT_PLAN_MD

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Splitter Instructions

You are a planning/coordinator role. Do not edit product code. Your job is to convert oversized, incomplete, or verifier-revised implementation units into smaller child implementation units that can be completed and verified independently.

Read:

- \`$SPLIT_CANDIDATES_TSV\`
- Each candidate packet under \`$REMEDIATION_DIR/packets\`
- Each candidate summary, verifier artifact, and implementation log listed in the TSV
- Any changed-code references needed only to understand ownership boundaries

For every candidate:

1. Decide whether it needs splitting or a direct revision.
2. If splitting is needed, create child packet files named \`packets/<parent-packet>-SNN.md\`.
3. Add child rows to \`$UNITS_TSV\` using unit IDs \`<parent-unit>-SNN\`.
4. Each child packet must have one coherent outcome, explicit file ownership boundaries, docs requirements, verification gates, and a fresh \`## Work Log\`.
5. Mark the parent packet work log as \`split-into-child-units\` and list the child packet IDs. Do not delete parent history.
6. Avoid overlapping write ownership among child units unless serialized in the rationale.
7. Keep each child unit below a 200k-token context window. For UI monolith/i18n packets, split by page or bounded domain rather than asking one agent to clean all pages.
8. Keep launch-only evidence separate from implementation work; child units should close code/docs/tests.
9. Candidates with \`oversized-packet\` or \`oversized-unit-packet-text\` are pre-execution size risks. Split them unless you can prove the packet/unit is already narrow enough for one implementation context after reading only the packet metadata and source excerpts.

Write \`$SPLIT_PLAN_MD\` with:

- Candidates examined.
- Child units created.
- Direct-revision units left unchanged.
- Required execution order and parallel-safe groups.
- Any candidates that cannot be split automatically and why.

Do not run implementation. Do not start verification.
PROMPT
}

split_incomplete_units() {
  detect_split_candidates
  local candidate_count
  candidate_count="$(tail -n +2 "$SPLIT_CANDIDATES_TSV" | wc -l | tr -d ' ')"
  SPLIT_CANDIDATE_UNITS="$(tail -n +2 "$SPLIT_CANDIDATES_TSV" | cut -f1 | paste -sd, -)"
  printf '[split-detect] candidates=%s file=%s\n' "$candidate_count" "$SPLIT_CANDIDATES_TSV"
  if [[ "$candidate_count" == "0" ]]; then
    return 0
  fi
  build_split_prompt
  printf '[splitter] %s\n' "$REMEDIATION_DIR/prompts/05-split-incomplete.md"
  if ! run_prompt "$REMEDIATION_DIR/prompts/05-split-incomplete.md" "05-split-incomplete" "coordinator"; then
    printf '[splitter-warning] splitter failed; continuing with existing child units and direct candidates (see %s/logs/05-split-incomplete.log)\n' "$REMEDIATION_DIR" >&2
  fi

  AUTO_SPLIT_CHILD_UNITS="$(
    awk -F '\t' '
      NR == FNR {
        if (FNR > 1 && $1 != "") parents[$1] = 1
        next
      }
      FNR > 1 {
        for (parent in parents) {
          if (index($1, parent "-S") == 1) {
            print $1
          }
        }
      }
    ' "$SPLIT_CANDIDATES_TSV" "$UNITS_TSV" | sort -u | paste -sd, -
  )"

  if [[ -n "$AUTO_SPLIT_CHILD_UNITS" ]]; then
    printf '[split-children] units=%s\n' "$AUTO_SPLIT_CHILD_UNITS"
  else
    printf '[split-children] units=none\n'
  fi
}

build_workstream_prompt() {
  local unit_id="$1" group="$2" model_class="$3" packets_csv="$4"
  local prompt="$REMEDIATION_DIR/prompts/implement-$unit_id.md"
  local packet_list
  packet_list="$(packet_paths_for_ids "$packets_csv")"
  local design_doc="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
  local design_block=""
  if [[ -f "$design_doc" ]]; then
    design_block=$(cat <<DESIGN

## Implementation Design

A planner has already analyzed the packets and code for this unit and produced a precise implementation design. **Read the design document first and treat it as your primary brief.** Execute the specified changes rather than re-deriving the approach from scratch. If you discover the design is incorrect once you read the actual code, apply the necessary correction and note the deviation in your summary — do not redesign from scratch.

- Design: \`$design_doc\`
DESIGN
)
  fi
  local revision_context=""
  if [[ "$REVISE_EXISTING" == "1" ]]; then
    local findings_tsv
    findings_tsv="$(verifier_findings_tsv_for_unit "$unit_id")"
    revision_context=$(cat <<REVISION

## Revision Context

This is a revision pass against an existing remediation run. Do not recatalog the packet and do not treat missing live launch-readiness evidence as the implementation task unless the packet itself requires a code/docs/test change to produce that evidence.

Open these prior artifacts before editing:

- Previous implementation summary: \`$REMEDIATION_DIR/artifacts/$unit_id-summary.md\`
- Previous verifier artifact: \`$REMEDIATION_DIR/artifacts/verify-$unit_id.md\`
- Previous verifier findings TSV: \`$findings_tsv\`
- Previous implementation log if needed for failure details: \`$REMEDIATION_DIR/logs/implement-$unit_id.log\`

Your work contract is the unresolved implementation/code/docs/test revision list from the verifier findings TSV. Fix only those findings and the minimum directly required follow-on changes. Do not redesign, recatalog, broaden scope, or revisit accepted packet areas. If the TSV is missing or empty, use the verifier artifact's explicit required revisions and keep the same narrow scope.

If the verifier finding type is \`contract_conflict\`, \`test_harness\`, or \`blocked\`, stop and write \`IMPLEMENTATION_RESULT: blocked\` with the exact human decision or targeted command required. Do not guess the product contract, and do not make broad test-harness rewrites from inside the auto-revise loop.

In implementation scope, do not run sandbox-sensitive PostgreSQL suites, live VPS checks, browser/E2E launch proof, or external integration proof unless they are explicitly known to be stable in this environment. Record those as launch evidence pending or sandbox-blocked, but do not leave fixable code/docs/tests unresolved.
REVISION
)
  fi

  cat > "$prompt" <<PROMPT
# Remediation Implementation Unit: $unit_id

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Workstream: $group
- Implementation unit: $unit_id
- Model class: $model_class
- Packet IDs: $packets_csv
- Product profile: ${PRODUCT_PROFILE:-"(none)"}

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Assigned Packets

\`\`\`text
$packet_list
\`\`\`
$design_block
$revision_context

## Implementation Instructions

Read only the assigned packets first (and the design document above if one was provided). Then inspect the minimal code, tests, and docs required to fix them.

Packets may originate from domain, cross-cutting, spec-addition, runtime, maturity/customer-proof, adversarial, or final-decision audit sources. Treat all source kinds as first-class implementation contracts. For spec-addition or product-profile packets, do not close the packet with docs-only evidence unless the packet explicitly says the missing work is documentation truth; implement the missing code path, validation, control, operator/customer workflow, protocol behavior, integration behavior, or test harness required by the spec/profile.

Own this implementation unit end to end:

1. Implement the remediation for the assigned packets.
2. Update each packet's \`## Work Log\` with a machine-readable status line as the final entry:
   - \`- Status: \`complete\`\` — packet fully implemented, tests pass, docs updated.
   - \`- Status: \`partial\`\` — implementation started but not finished; describe what remains.
   - \`- Status: \`blocked\`\` — cannot proceed; describe the blocker.
   This status is used by the coordinator on re-runs to skip already-completed packets. Do not leave it as \`not-started\`.
3. Update the product documentation locations named by the product profile as required.
4. Run the strongest relevant verification available in the repo for the changed surface.
5. Write \`$REMEDIATION_DIR/artifacts/$unit_id-summary.md\` with changed files, tests, docs, remaining risks, and any packets left incomplete.

Keep the context window under 200k tokens. If these packets are too broad, complete the highest-severity coherent subset, mark completed packets \`Status: \`complete\`\`, and mark the rest \`Status: \`partial\`\` in the packet logs.

For revision passes, do not stop at restating verifier findings. Resolve them. The summary must include:

- \`IMPLEMENTATION_RESULT: fixed\`, \`partial\`, or \`blocked\`.
- A verifier-finding disposition table: fixed / still failing / launch-evidence-pending / sandbox-blocked.
- Exact commands run and outcomes.
- Exact docs updated, or a statement that no docs change was needed after checking the product-profile documentation locations.
PROMPT
}

build_verifier_prompt() {
  local unit_id="$1" group="$2" model_class="$3" packets_csv="$4"
  local prompt="$REMEDIATION_DIR/prompts/verify-$unit_id.md"
  local findings_tsv
  findings_tsv="$(verifier_findings_tsv_for_unit "$unit_id")"
  local packet_list
  packet_list="$(packet_paths_for_ids "$packets_csv")"

  cat > "$prompt" <<PROMPT
# Remediation Verification: $unit_id

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Workstream: $group
- Implementation unit: $unit_id
- Implementation model class: $model_class
- Verifier role: read-only evidence verifier
- Verification scope: $VERIFY_SCOPE
- Packet IDs: $packets_csv
- Product profile: ${PRODUCT_PROFILE:-"(none)"}

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Assigned Packets

\`\`\`text
$packet_list
\`\`\`

## Verification Instructions

Do not edit files. Use a review/evidence-verification stance.

Verification scope is \`$VERIFY_SCOPE\`.

When scope is \`implementation\`, answer the question: "Did the implementation fix the code/docs/tests for this packet, and do the implementation owner and verifier agree the packet is code-complete?" Do not run sandbox-sensitive PostgreSQL suites, live VPS checks, browser/E2E launch proof, or external integration proof unless they are explicitly known to be stable in this environment. Missing launch-readiness reruns, live VPS/browser proof, external IdP/relying-party proof, and PostgreSQL checks that cannot run in this sandbox must be recorded as \`launch-evidence-pending\` or \`sandbox-blocked\`, not as implementation failure. Still block implementation signoff for stale active tests, docs contradictions, unrun runnable local tests, failing runnable local tests, incomplete code, unsupported claims, or missing required success/failure test coverage.

When scope is \`launch\`, require full launch evidence and block on missing live/staged/browser/PostgreSQL/e2e evidence where the packet requires it.

This verifier is intentionally independent from the implementation workstream and may run on a different provider/model through \`VERIFICATION_RUNNER\`. Use strict evidence discipline:

1. Verify every assigned P0/P1 packet, and sample P2 packets when present.
2. Check that each packet's work log contains a machine-readable \`- Status: \`complete\`\` (or \`partial\`/\`blocked\`) line as its final entry, and that the stated status is truthful. A packet missing this line or still reading \`not-started\` is incomplete regardless of the implementation summary.
3. Check that each packet's work log truthfully states files changed, docs updated, verification run, and remaining risk.
4. Open cited audit sources, changed code, changed tests, and changed docs. Confirm the fix addresses the actual finding, not just the symptom.
5. Confirm docs were updated in the product-profile documentation locations where behavior, contracts, workflows, controls, or customer guidance changed.
6. Confirm success-path and failure-path tests exist and were run or honestly blocked.
7. Search for alternate paths that could invalidate the fix, especially trust-boundary bypasses, authorization or isolation gaps, stale UI/API contracts, protocol/integration replay, lifecycle recovery, and audit evidence gaps.
8. Block implementation signoff for: missing or untruthful packet Work Log status lines, overclaimed packet closure, failing runnable tests, stale tests, documentation contradictions, unverified P0/P1 code closure, incomplete code, or any subagent context budget over 200000 tokens. In launch scope, also block signoff for missing launch evidence.
9. Prefer focused verification commands owned by this unit. Do not run the full backend/frontend suite unless the packet is explicitly a runtime quality-gate packet or the focused evidence cannot prove the claim. If a local command is sandbox-blocked, classify it as \`sandbox_blocked\` or \`launch_evidence\` rather than product failure unless it is a normal supported local implementation gate.
10. If docs, tests, packet text, and code disagree about the intended product/security contract, classify the finding as \`contract_conflict\` and use \`Decision: stop\` or \`Implementation decision: blocked\` unless the intended contract is explicit in the assigned packet.
11. If the blocker is a flaky, timing-sensitive, performance, environment-ordering, or broad harness issue, classify it as \`test_harness\` and specify the exact targeted command or human decision required. Do not demand repeated full-suite execution from the auto-revise loop.
12. Do not reopen an already closed packet solely because the original audit text still exists or because launch evidence is pending under implementation scope. Reopen it only when current code/docs/tests/work-log evidence contradicts the claimed closure, a focused runnable implementation gate fails, or a required implementation artifact is missing.
13. If the unit requires more than \`$MAX_AUTO_REVISE_FINDINGS\` independent code/docs/test fixes, or the findings span unrelated product areas that should not be revised as one change, classify the excess as \`split_required\` and use \`Decision: stop\` / \`Implementation decision: blocked\`.

Write \`$REMEDIATION_DIR/artifacts/verify-$unit_id.md\` with:

- Decision: \`accept\`, \`revise\`, or \`stop\`.
- Implementation decision: \`fixed\`, \`revise\`, or \`blocked\`.
- Launch evidence decision: \`complete\`, \`pending\`, or \`blocked\`.
- Packet-by-packet assertion checks.
- References opened and wider searches performed.
- Missing evidence and required revisions.
- Whether this workstream can be included in final remediation signoff.

Also write \`$findings_tsv\` with this exact tab-separated header:

\`\`\`text
unit_id	severity	type	file	line	finding	required_fix
\`\`\`

Use one row per unresolved verifier finding. Valid \`type\` values:

- \`code\` — product/source implementation defect.
- \`docs\` — stale or contradictory docs with clear intended behavior.
- \`tests\` — missing or failing normal focused tests.
- \`test_harness\` — flaky/timing/performance/environment-ordering/broad-suite harness issue that needs a targeted command or explicit human decision before auto-revision.
- \`contract_conflict\` — code/tests/docs/packet disagree on the intended behavior and a human product/security decision is required.
- \`launch_evidence\` — launch proof pending but implementation is otherwise fixed.
- \`sandbox_blocked\` — evidence cannot run in this environment.
- \`split_required\` — too many independent findings or unrelated product areas for safe automatic revision.
- \`blocked\` — cannot proceed without external dependency, access, or human input.

For \`accept\` / \`fixed\`, write only the header or only \`launch_evidence\` / \`sandbox_blocked\` rows. Do not include \`contract_conflict\`, \`test_harness\`, \`split_required\`, or \`blocked\` rows on an accepted implementation.
PROMPT
}

build_final_review_prompt() {
  local prompt="$REMEDIATION_DIR/prompts/99-final-review.md"
  cat > "$prompt" <<PROMPT
# Remediation Final Review

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Master Px list: $PX_MD
- Workstreams: $WORKSTREAMS_TSV
- Product profile: ${PRODUCT_PROFILE:-"(none)"}

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Final Review Instructions

Do not edit files. Review the coordinator plan, workstream summaries, packet logs, verification outputs, current diff, and relevant docs/tests.

Use an independent chair/reviewer pattern:

1. Treat verifier \`revise\` or \`stop\` decisions as blocking for the selected verification scope unless the evidence clearly proves the verifier was wrong.
2. Separate implementation closure from launch evidence. In \`implementation\` scope, do not fail code remediation solely because live/staged/browser/PostgreSQL evidence could not run in this environment; list those as launch rerun gates. Still fail for stale active tests, runnable test failures, missing required local tests, incomplete code, docs contradictions, overclaimed closure, or subagent context budgets above 200000 tokens.
3. In \`launch\` scope, block final signoff for unresolved P0/P1 packets, missing required docs, missing required tests, failed verification, overclaimed closure, missing launch evidence, or subagent context budgets above 200000 tokens.
4. Check that model/provider routing was appropriate for risk: high-risk security/protocol/SCIM/IGA/runtime work should have used deep/high-risk implementation and independent verifier roles.
5. Check that the workflow stayed agent-agnostic: implementation, cataloging, verification, and review could be routed through configured runners rather than depending on one provider.
6. Produce two decisions: implementation remediation decision and launch-evidence decision, plus exact rerun gates for the launch audit.

Write \`$REMEDIATION_DIR/04-final-remediation-review.md\`.
PROMPT
}

rebuild_unit_prompts() {
  normalize_units_tsv
  tail -n +2 "$UNITS_TSV" | while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    build_workstream_prompt "$unit_id" "$group" "$model_class" "$packets_csv"
    build_verifier_prompt "$unit_id" "$group" "$model_class" "$packets_csv"
  done
}

needs_planner() {
  local class="$1"
  local c
  for c in ${PLAN_MODEL_CLASSES:-high-risk complex}; do
    if [[ "$c" == "$class" ]]; then
      return 0
    fi
  done
  return 1
}

build_planner_prompt() {
  local unit_id="$1" group="$2" model_class="$3" packets_csv="$4"
  local prompt="$REMEDIATION_DIR/prompts/plan-$unit_id.md"
  local packet_list
  packet_list="$(packet_paths_for_ids "$packets_csv")"
  local design_out="$REMEDIATION_DIR/artifacts/$unit_id-design.md"

  cat > "$prompt" <<PROMPT
# Remediation Planner: $unit_id

## Metadata

- Repo root: $REPO_ROOT
- Audit run: $AUDIT_RUN
- Remediation run: $REMEDIATION_DIR
- Workstream: $group
- Implementation unit: $unit_id
- Model class: $model_class
- Packet IDs: $packets_csv
- Product profile: ${PRODUCT_PROFILE:-"(none)"}
- Design output: $design_out

## Shared Instructions

$(cat "$SHARED_PROMPT")

## Product Profile

$(product_profile_block)

## Assigned Packets

\`\`\`text
$packet_list
\`\`\`

## Planner Instructions

**ROLE CONSTRAINT**: You are a PLANNER, not an implementer. Do NOT edit product source files, commit changes, or run tests. Your only output is the design document written to \`$design_out\`.

Your job: understand the assigned packets and the relevant code deeply, then produce a precise file-by-file implementation design that an implementer agent can execute without re-deriving the approach.

**Working-set discipline**: Keep context under 120k tokens. For files over 1500 lines, read the skeleton first, then targeted sections.

**Process**:
1. Read each assigned packet file in full.
2. Identify what code, docs, and tests need to change.
3. Read the relevant source files (skeleton first, then targeted reads).
4. Verify the current state of each affected code section before specifying the fix. Do not speculate.
5. Write the design document and stop.

**Design document structure** (write to \`$design_out\`):

\`\`\`markdown
# Implementation Design: $unit_id

## Problem Summary
What is broken, exactly where, and why it matters. Severity and blast radius.

## Solution Approach
The architectural decision — what to do and why. If multiple approaches exist, state which you chose and the tradeoff.

## Per-File Change Spec
For every file that must change:
### File: path/to/file.py (lines NNN–MMM)
**Current behavior:** what the code does now.
**Required change:** exactly what to add, remove, or replace. Precise enough that the implementer does not need to re-read the original finding.

## Test Requirements
For each change: what test to write, what to assert, what negative cases to cover, where in the test suite it belongs.

## Migration Requirements
Any DB schema changes, config updates, ordered sequencing constraints, or deployment steps.

## Invariants to Preserve
Tenant isolation, permission boundaries, audit trail continuity, idempotency contracts, and any other invariants the implementer must not break.

## Risks and Unknowns
Edge cases, unknown dependencies, or areas where the implementer may need to deviate from the design and must document why.
\`\`\`

Do not edit product source files. Do not run tests. Write only the design document.
PROMPT
}

rebuild_planner_prompts() {
  tail -n +2 "$UNITS_TSV" | while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    needs_planner "$model_class" || continue
    build_planner_prompt "$unit_id" "$group" "$model_class" "$packets_csv"
  done
}

execute_planners() {
  # Skip entirely if no units in UNITS_TSV need the planner phase.
  local any=0
  while IFS=$'\t' read -r _uid _pcsv _grp mc _sev _rat; do
    [[ -z "${_uid:-}" ]] && continue
    [[ -z "$(incomplete_packets_csv "$_pcsv")" ]] && continue
    if needs_planner "$mc"; then
      any=1
      break
    fi
  done < <(tail -n +2 "$UNITS_TSV")
  if [[ "$any" -eq 0 ]]; then
    return 0
  fi

  rebuild_planner_prompts

  printf '[planners] design phase for model classes: %s\n' "${PLAN_MODEL_CLASSES:-high-risk complex}"

  local -a pids=() names=()
  local active=0

  export _WAVE_DISPLAY=1

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    needs_planner "$model_class" || continue
    if ! unit_selected "$unit_id"; then continue; fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then continue; fi
    if [[ -z "$(incomplete_packets_csv "$packets_csv")" ]]; then
      printf '[resume] all packets complete for plan-%s; auto-checkpointing\n' "$unit_id"
      grep -qxF "plan-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "plan-$unit_id" >> "$CHECKPOINT_FILE"
      continue
    fi
    local design_doc="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
    if final_result_is_pass "$design_doc" && artifact_mentions_all_packets "$design_doc" "$packets_csv"; then
      printf '[resume] recovered completed plan-%s from existing design artifact\n' "$unit_id"
      grep -qxF "plan-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "plan-$unit_id" >> "$CHECKPOINT_FILE"
      continue
    fi
    if grep -qxF "plan-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      if artifact_mentions_all_packets "$design_doc" "$packets_csv"; then
        printf '[resume] skipping completed plan-%s\n' "$unit_id"
        continue
      fi
      printf '[resume] re-running plan-%s; checkpoint exists but design does not cover merged packets=%s\n' \
        "$unit_id" "$packets_csv"
    fi
    local prompt="$REMEDIATION_DIR/prompts/plan-$unit_id.md"
    printf '[plan] unit=%s group=%s model_class=%s\n' "$unit_id" "$group" "$model_class"
    run_prompt "$prompt" "plan-$unit_id" "planner" &
    pids+=("$!")
    names+=("plan-$unit_id")
    active=$((active + 1))
    if ((active >= MAX_PARALLEL)); then
      if ! wait_for_wave pids names; then
        [[ "$CONTINUE_ON_FAIL" != "1" ]] && exit 1
      fi
      pids=(); names=(); active=0
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#pids[@]} > 0)); then
    if ! wait_for_wave pids names; then
      [[ "$CONTINUE_ON_FAIL" != "1" ]] && exit 1
    fi
  fi
}

rebuild_workstream_coordinator_prompts() {
  tail -n +2 "$WORKSTREAMS_TSV" | while IFS=$'\t' read -r f1 f2 f3 f4 f5 _f6 _f7; do
    local group model_class packets_csv
    if [[ "$f1" == WS-* ]]; then
      group="$f1"
      model_class="$f3"
      packets_csv="$f4"
    else
      group="$f1"
      model_class="$f2"
      packets_csv="$f4"
    fi
    [[ -z "${group:-}" ]] && continue
    build_workstream_coordinator_prompt "$group" "$model_class" "$packets_csv"
  done
}

_display_name_for() {
  case "$1" in
    00-cataloger)   printf 'Cataloging' ;;
    00-coordinator) printf 'Coordinating' ;;
    coordinate-*)   printf '%s' "${1#coordinate-}" ;;
    implement-*)    printf '%s' "${1#implement-}" ;;
    verify-*)       printf 'verify:%s' "${1#verify-}" ;;
    *)              printf '%s' "$1" ;;
  esac
}

run_command_with_heartbeat() {
  local workstream="$1" log_file="$2"
  shift 2

  local heartbeat_interval="${REMEDIATION_HEARTBEAT_SECONDS:-60}"
  local stall_intervals="${REMEDIATION_STALL_INTERVALS:-5}"
  local start_ts
  start_ts="$(date +%s)"

  # Run command in background so the heartbeat can kill it on stall
  set +e
  "$@" >"$log_file" 2>&1 &
  local cmd_pid="$!"

  # In wave mode the combined display in wait_for_wave owns the terminal.
  # Skip the per-job heartbeat to avoid interleaved output.
  if [[ "${_WAVE_DISPLAY:-0}" != "1" ]]; then
    local display_name
    display_name="$(_display_name_for "$workstream")"
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
        printf '\r[%s] %s (%ds)  ' "$spin_char" "$display_name" "$elapsed"
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
          if [[ "$stall_secs" -ge "$stall_threshold" ]] && final_result_is_terminal "$log_file"; then
            printf '\r[!] %s: stalled after %ds with RESULT — terminating\033[K\n' \
              "$display_name" "$elapsed" >&2
            printf '[stall-kill] log stalled after %ds — terminating process\n' "$elapsed" >>"$log_file"
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

  if [[ "${VERBOSE:-0}" == "1" && -f "$log_file" ]]; then
    local final_size
    final_size="$(wc -c <"$log_file" | tr -d ' ')"
    printf '    log_bytes=%s log=%s\n' "$final_size" "$log_file"
  fi
  return "$status"
}

validate_prompt_outputs() {
  local workstream="$1" class="$2"
  if [[ "$workstream" == implement-* ]]; then
    local unit_id="${workstream#implement-}"
    local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    if [[ ! -s "$summary" ]]; then
      printf '[postcheck] missing implementation summary: %s\n' "$summary" >&2
      return 1
    fi
  elif [[ "$workstream" == verify-* ]]; then
    local unit_id="${workstream#verify-}"
    local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local findings
    findings="$(verifier_findings_tsv_for_unit "$unit_id")"
    if [[ ! -s "$verifier" ]]; then
      printf '[postcheck] missing verifier artifact: %s\n' "$verifier" >&2
      return 1
    fi
    ensure_verifier_findings_header "$findings"
  elif [[ "$class" == "reviewer" ]]; then
    if [[ ! -s "$REMEDIATION_DIR/04-final-remediation-review.md" ]]; then
      printf '[postcheck] missing final remediation review: %s\n' "$REMEDIATION_DIR/04-final-remediation-review.md" >&2
      return 1
    fi
  fi
}

final_result_value() {
  local log_file="$1"
  grep -aE '^RESULT:[[:space:]]*(PASS|FAIL|INCOMPLETE|BLOCKED)' "$log_file" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^RESULT:[[:space:]]*//; s/[[:space:]].*$//' \
    | tr '[:lower:]' '[:upper:]'
}

final_result_is_pass() {
  [[ "$(final_result_value "$1")" == "PASS" ]]
}

final_result_is_terminal() {
  case "$(final_result_value "$1")" in
    PASS|FAIL|INCOMPLETE|BLOCKED) return 0 ;;
    *) return 1 ;;
  esac
}

implementation_summary_is_fixed() {
  local summary="$1"
  [[ -s "$summary" ]] || return 1
  grep -aqiE '^[[:space:]#*_`-]*IMPLEMENTATION_RESULT:[[:space:]]*`?fixed`?([[:space:]]|$)' "$summary" 2>/dev/null
}

recover_verifier_artifact_from_log() {
  local unit_id="$1" log_file="$2"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  local packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" || true)"
  [[ ! -s "$verifier" ]] || return 0
  final_result_is_pass "$log_file" || return 1
  implementation_summary_is_fixed "$summary" || return 1

  mkdir -p "$REMEDIATION_DIR/artifacts"
  {
    printf '# Verification: %s\n\n' "$unit_id"
    printf -- '- Decision: accept\n'
    printf -- '- Implementation decision: fixed\n'
    printf -- '- Launch evidence decision: pending\n\n'
    [[ -n "$packets_csv" ]] && printf -- '- Packets: %s\n\n' "$packets_csv"
    printf 'Recovered from `%s` after the verifier exited non-zero or stalled after writing `RESULT: PASS` but before creating this artifact.\n\n' "$log_file"
    printf 'The implementation summary records `IMPLEMENTATION_RESULT: fixed`; this recovered verifier artifact exists so resume and commit-on-verify can use the normal artifact contract.\n\n'
    printf 'RESULT: PASS\n'
  } > "$verifier"
  ensure_verifier_findings_header "$(verifier_findings_tsv_for_unit "$unit_id")"
  printf '[auto-recover] verify-%s: recovered missing verifier artifact from RESULT: PASS log\n' "$unit_id" >>"$log_file"
}

readonly_role_diff_snapshot() {
  local rel_rdir="${REMEDIATION_DIR#"$REPO_ROOT/"}"
  git -C "$REPO_ROOT" diff --binary -- . ":(exclude)${rel_rdir}" 2>/dev/null || true
}

commit_root_path() {
  local root="$1"
  if [[ "$root" == /* ]]; then
    printf '%s\n' "$root"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$root"
  fi
}

commit_root_label() {
  local root="$1"
  root="${root#"$REPO_ROOT"/}"
  root="${root#/}"
  [[ -n "$root" ]] || root="repo"
  printf '%s\n' "$root" | tr '/[:space:]' '--'
}

unit_packets_csv() {
  local wanted="$1"
  awk -F '\t' -v unit="$wanted" 'NR > 1 && $1 == unit { print $2; found = 1; exit } END { if (!found) exit 1 }' "$UNITS_TSV" 2>/dev/null
}

commit_baseline_dir_for_unit() {
  printf '%s/commit-baselines/%s\n' "$REMEDIATION_DIR/artifacts" "$1"
}

record_commit_baseline_for_unit() {
  [[ "$REMEDIATION_COMMIT_ON_VERIFY" == "1" ]] || return 0
  local unit_id="$1" baseline_dir
  baseline_dir="$(commit_baseline_dir_for_unit "$unit_id")"
  mkdir -p "$baseline_dir"

  local IFS=',' root root_path label status_file
  for root in $REMEDIATION_COMMIT_ROOTS; do
    [[ -n "$root" ]] || continue
    root_path="$(commit_root_path "$root")"
    [[ -d "$root_path" ]] || continue
    if ! git -C "$root_path" rev-parse --git-dir >/dev/null 2>&1; then
      continue
    fi
    label="$(commit_root_label "$root_path")"
    status_file="$baseline_dir/$label.status"
    [[ -f "$status_file" ]] && continue
    git -C "$root_path" status --porcelain=v1 -uall > "$status_file"
    if [[ -s "$status_file" ]]; then
      printf '[commit-on-verify] %s: %s dirty before implementation; auto-commit disabled for this unit/root\n' \
        "$unit_id" "$root_path"
    fi
  done
}

verifier_accepts_unit() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  [[ -s "$verifier" ]] || return 1
  grep -qiE '^[[:space:]-]*Decision:[[:space:]]*`?accept`?' "$verifier" || return 1
  grep -qiE '^[[:space:]-]*Implementation decision:[[:space:]]*`?fixed`?' "$verifier" || return 1
}

commit_verified_unit_changes() {
  [[ "$REMEDIATION_COMMIT_ON_VERIFY" == "1" ]] || return 0
  local unit_id="$1"
  verifier_accepts_unit "$unit_id" || {
    printf '[commit-on-verify] %s: verifier did not accept/fix; not committing\n' "$unit_id"
    return 0
  }

  local packets_csv baseline_dir
  packets_csv="$(unit_packets_csv "$unit_id" || true)"
  baseline_dir="$(commit_baseline_dir_for_unit "$unit_id")"
  [[ -d "$baseline_dir" ]] || {
    printf '[commit-on-verify] %s: missing clean baseline; not committing\n' "$unit_id" >&2
    return 1
  }

  local IFS=',' root root_path label status_file current_status commit_msg
  for root in $REMEDIATION_COMMIT_ROOTS; do
    [[ -n "$root" ]] || continue
    root_path="$(commit_root_path "$root")"
    [[ -d "$root_path" ]] || continue
    if ! git -C "$root_path" rev-parse --git-dir >/dev/null 2>&1; then
      continue
    fi
    label="$(commit_root_label "$root_path")"
    status_file="$baseline_dir/$label.status"
    if [[ ! -f "$status_file" ]]; then
      printf '[commit-on-verify] %s: no baseline for %s; not committing that root\n' "$unit_id" "$root_path" >&2
      continue
    fi
    if [[ -s "$status_file" ]]; then
      printf '[commit-on-verify] %s: %s was dirty before implementation; leaving changes uncommitted\n' \
        "$unit_id" "$root_path" >&2
      continue
    fi
    current_status="$(git -C "$root_path" status --porcelain=v1 -uall)"
    if [[ -z "$current_status" ]]; then
      printf '[commit-on-verify] %s: no %s changes to commit\n' "$unit_id" "$label"
      continue
    fi

    git -C "$root_path" add -A
    commit_msg="$(printf 'fix(remediation): complete %s %s\n\nPackets: %s\nVerifier: accept/fixed\nAudit run: %s\n' \
      "$unit_id" "$label" "${packets_csv:-unknown}" "$(basename "$AUDIT_RUN")")"
    if git -C "$root_path" commit -m "$commit_msg"; then
      printf '[commit-on-verify] %s: committed %s changes in %s\n' "$unit_id" "$label" "$root_path"
    else
      printf '[commit-on-verify] %s: git commit failed in %s\n' "$unit_id" "$root_path" >&2
      return 1
    fi
  done
}

run_prompt() {
  local prompt_file="$1" workstream="$2" class="$3"
  local log_file="$REMEDIATION_DIR/logs/$workstream.log"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s class=%s prompt=%s\n' "$workstream" "$class" "$prompt_file"
    return 0
  fi

  # Resolve runner and effective agent. Custom wrappers take precedence over
  # built-in agents. REMEDIATION_RUNNER is the universal fallback for all roles.
  local runner="" effective_agent=""
  case "$class" in
    cataloger)
      runner="${CATALOG_RUNNER:-${REMEDIATION_RUNNER:-}}"
      effective_agent="${IMPLEMENTER_AGENT:-codex}"
      ;;
    coordinator)
      runner="${REMEDIATION_RUNNER:-}"
      effective_agent="${IMPLEMENTER_AGENT:-codex}"
      ;;
    planner)
      if [[ -n "${PLANNER_RUNNER:-}" ]]; then
        runner="$PLANNER_RUNNER"
      elif [[ "${REVIEWER_AGENT:-}" == "runner" && -n "${REVIEWER_RUNNER:-}" ]]; then
        runner="$REVIEWER_RUNNER"
      else
        runner="${REMEDIATION_RUNNER:-}"
        effective_agent="${PLANNER_AGENT:-${REVIEWER_AGENT:-${COORDINATOR_AGENT:-${IMPLEMENTER_AGENT:-codex}}}}"
      fi
      ;;
    high-risk|standard|complex)
      if [[ "$IMPLEMENTER_AGENT" == "runner" ]]; then
        runner="${IMPLEMENTER_RUNNER:?IMPLEMENTER_AGENT=runner requires IMPLEMENTER_RUNNER}"
      else
        runner="${IMPLEMENTER_RUNNER:-${REMEDIATION_RUNNER:-}}"
        effective_agent="${IMPLEMENTER_AGENT:-codex}"
      fi
      ;;
    verifier)
      if [[ "$REVIEWER_AGENT" == "runner" ]]; then
        runner="${REVIEWER_RUNNER:?REVIEWER_AGENT=runner requires REVIEWER_RUNNER}"
      else
        runner="${REVIEWER_RUNNER:-${VERIFICATION_RUNNER:-${REMEDIATION_RUNNER:-}}}"
        effective_agent="${REVIEWER_AGENT:-}"
      fi
      ;;
    reviewer)
      if [[ "$REVIEWER_AGENT" == "runner" ]]; then
        runner="${REVIEWER_RUNNER:?REVIEWER_AGENT=runner requires REVIEWER_RUNNER}"
      else
        runner="${REVIEWER_RUNNER:-${REVIEW_RUNNER:-${VERIFICATION_RUNNER:-${REMEDIATION_RUNNER:-}}}}"
        effective_agent="${REVIEWER_AGENT:-}"
      fi
      ;;
    *)
      runner="${IMPLEMENTER_RUNNER:-${REMEDIATION_RUNNER:-}}"
      effective_agent="${IMPLEMENTER_AGENT:-codex}"
      ;;
  esac

  # Skip reviewer/verifier roles when no agent is configured.
  if [[ "$class" == "verifier" || "$class" == "reviewer" ]]; then
    if [[ -z "$runner" && ( -z "$effective_agent" || "$effective_agent" == "none" ) ]]; then
      printf '[skip] %s class=%s reviewer not configured\n' "$workstream" "$class"
      return 0
    fi
  fi

  local max_attempts=$((REMEDIATION_MAX_RETRIES + 1))
  local attempt=1
  local status=0
  local readonly_integrity=0 readonly_before_file="" readonly_before_hash="" readonly_before_size=0
  if [[ "$class" =~ ^(cataloger|coordinator|verifier|reviewer)$ ]] && \
     git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null 2>&1; then
    readonly_integrity=1
    readonly_before_file="$(mktemp)"
    readonly_role_diff_snapshot > "$readonly_before_file"
    readonly_before_hash="$(sha256sum "$readonly_before_file" | awk '{print $1}')"
    readonly_before_size="$(wc -c <"$readonly_before_file" | tr -d ' ')"
  fi

  while ((attempt <= max_attempts)); do
    if ((attempt > 1)); then
      local backoff=$(( (attempt - 1) * 15 ))
      printf '[retry] %s attempt=%s/%s delay=%ss\n' "$workstream" "$attempt" "$max_attempts" "$backoff" >&2
      sleep "$backoff"
    fi

    status=0
    if [[ -n "$runner" ]]; then
      run_command_with_heartbeat "$workstream" "$log_file" \
        "$runner" "$prompt_file" "$REMEDIATION_DIR" "$workstream"
      status="$?"
    else
      case "${effective_agent:-codex}" in
        claude)
          run_command_with_heartbeat "$workstream" "$log_file" _exec_claude "$prompt_file" "$class"
          status="$?"
          ;;
        gemini)
          run_command_with_heartbeat "$workstream" "$log_file" _exec_gemini "$prompt_file" "$class"
          status="$?"
          ;;
        codex)
          run_command_with_heartbeat "$workstream" "$log_file" _exec_codex "$prompt_file" "$class"
          status="$?"
          ;;
        *)
          printf 'Unknown agent "%s" for class %s — set IMPLEMENTER_AGENT/REVIEWER_AGENT to codex, claude, gemini, or runner\n' \
            "${effective_agent}" "$class" >&2
          return 2
          ;;
      esac
    fi

    if ((status == 0)); then
      break
    fi
    attempt=$((attempt + 1))
  done

  # validate_prompt_outputs and the integrity check run once after the final
  # attempt — retries only fire on runner exit-code failures, not content failures.
  if [[ "$status" == "0" ]]; then
    validate_prompt_outputs "$workstream" "$class" || status="$?"
  fi

  # Coordinator, cataloger, verifier, and reviewer roles must not modify product
  # source code. Compare against the pre-run diff snapshot so verifier/reviewer
  # roles do not get blamed for implementation changes that were already dirty.
  if [[ "$readonly_integrity" == "1" ]]; then
    local readonly_after_file readonly_after_hash
    readonly_after_file="$(mktemp)"
    readonly_role_diff_snapshot > "$readonly_after_file"
    readonly_after_hash="$(sha256sum "$readonly_after_file" | awk '{print $1}')"
    if [[ "$readonly_after_hash" != "$readonly_before_hash" ]]; then
      printf '\nINTEGRITY VIOLATION: %s (class=%s) modified source files outside remediation dir; reverting\n' \
        "$workstream" "$class" >>"$log_file"
      if [[ "$readonly_before_size" == "0" ]]; then
        local rel_rdir="${REMEDIATION_DIR#"$REPO_ROOT/"}"
        git -C "$REPO_ROOT" checkout -- . ":(exclude)${rel_rdir}" >>"$log_file" 2>&1 || true
      else
        printf 'Pre-existing product diff was present before %s; not reverting to avoid destroying implementation work.\n' \
          "$workstream" >>"$log_file"
      fi
      if [[ "$class" != "coordinator" ]]; then
        status=1
      fi
    fi
    rm -f "$readonly_before_file" "$readonly_after_file"
  fi

  # Auto-recover: if the agent exited non-zero but the summary artifact records
  # IMPLEMENTATION_RESULT: fixed, the work completed — checkpoint it anyway.
  # This handles rate-limit disconnects and stall-kills where the agent finished
  # writing output before the connection was lost.
  if [[ "$status" != "0" ]] && [[ "$class" =~ ^(high-risk|standard)$ ]]; then
    local unit_id="${workstream#implement-}"
    local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    if implementation_summary_is_fixed "$summary"; then
      printf '\n[auto-recover] %s: non-zero exit but IMPLEMENTATION_RESULT: fixed summary exists — treating as success\n' \
        "$workstream" >>"$log_file"
      status=0
    fi
  fi
  if [[ "$status" != "0" && "$workstream" == verify-* ]]; then
    local unit_id="${workstream#verify-}"
    if recover_verifier_artifact_from_log "$unit_id" "$log_file"; then
      status=0
    fi
  fi

  return "$status"
}

wave_job_completed_successfully() {
  local name="$1" log_file="$2"
  if grep -q '^INTEGRITY VIOLATION:' "$log_file" 2>/dev/null; then
    return 1
  fi
  case "$name" in
    plan-*)
      local unit_id="${name#plan-}"
      local design="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
      final_result_is_pass "$design" && [[ -s "$design" ]]
      ;;
    implement-*)
      local unit_id="${name#implement-}"
      local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
      implementation_summary_is_fixed "$summary"
      ;;
    verify-*)
      local unit_id="${name#verify-}"
      local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
      recover_verifier_artifact_from_log "$unit_id" "$log_file" || true
      final_result_is_terminal "$log_file" && [[ -s "$verifier" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_wave() {
  local -n pids_ref=$1
  local -n names_ref=$2
  local failed=0
  local n=${#pids_ref[@]}
  if [[ $n -eq 0 ]]; then
    return 0
  fi

  local heartbeat_interval="${REMEDIATION_HEARTBEAT_SECONDS:-60}"
  local stall_intervals="${REMEDIATION_STALL_INTERVALS:-5}"
  local stall_threshold=$(( stall_intervals * heartbeat_interval ))
  local now
  now="$(date +%s)"

  # Per-job state: start time, log file, last-seen log size, last-change timestamp
  local -a job_start=() job_log=() job_prev_size=() job_last_change=()
  local idx
  for idx in "${!names_ref[@]}"; do
    job_start+=("$now")
    job_log+=("$REMEDIATION_DIR/logs/${names_ref[$idx]}.log")
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
        # Job finished — collect status, clear display line, report
        wait "${pids_ref[$idx]}"
        local s=$?
        local _tw; _tw=$(tput cols 2>/dev/null || echo 120)
        printf '\r%-*s\r' $(( _tw - 1 )) ''
        if [[ $s -eq 0 ]]; then
          printf '[ok] %s\n' "${names_ref[$idx]}"
          printf '%s\n' "${names_ref[$idx]}" >> "$CHECKPOINT_FILE"
          if [[ "${names_ref[$idx]}" == verify-* ]]; then
            if ! commit_verified_unit_changes "${names_ref[$idx]#verify-}"; then
              failed=1
            fi
          fi
        elif wave_job_completed_successfully "${names_ref[$idx]}" "${job_log[$idx]}"; then
          printf '[ok] %s (auto-recovered after non-zero wave exit)\n' "${names_ref[$idx]}"
          printf '\n[auto-recover] %s: non-zero wave exit but terminal RESULT with required artifact — treating as success\n' \
            "${names_ref[$idx]}" >>"${job_log[$idx]}"
          printf '%s\n' "${names_ref[$idx]}" >> "$CHECKPOINT_FILE"
          if [[ "${names_ref[$idx]}" == verify-* ]]; then
            if ! commit_verified_unit_changes "${names_ref[$idx]#verify-}"; then
              failed=1
            fi
          fi
        else
          printf '[fail] %s (see %s/logs/%s.log)\n' \
            "${names_ref[$idx]}" "$REMEDIATION_DIR" "${names_ref[$idx]}" >&2
          failed=1
        fi
      else
        still_running+=("$idx")

        # Stall detection
        local size=0
        if [[ -f "${job_log[$idx]}" ]]; then
          size="$(wc -c <"${job_log[$idx]}" | tr -d ' ')"
        fi
        if [[ "$size" -ne "${job_prev_size[$idx]}" ]]; then
          job_last_change[$idx]="$now2"
          job_prev_size[$idx]="$size"
        elif [[ "$stall_threshold" -gt 0 ]]; then
          local stall_secs=$(( now2 - job_last_change[$idx] ))
          if [[ "$stall_secs" -ge "$stall_threshold" ]] && final_result_is_terminal "${job_log[$idx]}"; then
            local elapsed=$(( now2 - job_start[$idx] ))
            printf '\r\033[K[!] %s: stalled after %ds — terminating\n' \
              "${names_ref[$idx]}" "$elapsed" >&2
            printf '[stall-kill] stalled after %ds\n' "$elapsed" >> "${job_log[$idx]}"
            kill "${pids_ref[$idx]}" 2>/dev/null || true
          fi
        fi
      fi
    done
    remaining=("${still_running[@]}")

    # Render combined status line
    if [[ ${#remaining[@]} -gt 0 ]]; then
      local parts=() part_idx
      for part_idx in "${remaining[@]}"; do
        local elapsed=$(( now2 - job_start[$part_idx] ))
        local dname
        dname="$(_display_name_for "${names_ref[$part_idx]}")"
        parts+=("$dname (${elapsed}s)")
      done
      local line="${parts[0]}"
      for p in "${parts[@]:1}"; do line+=" | $p"; done
      local term_width
      term_width=$(tput cols 2>/dev/null || echo 120)
      local content="[$spin_char] $line"
      local padded
      printf -v padded '%-*s' $(( term_width - 1 )) "$content"
      padded="${padded:0:$(( term_width - 1 ))}"
      printf '\r%s' "$padded"
    fi
  done

  local _tw; _tw=$(tput cols 2>/dev/null || echo 120)
  printf '\r%-*s\r' $(( _tw - 1 )) ''  # clear final display line
  return "$failed"
}

execute_workstreams() {
  local coordinator="$REMEDIATION_DIR/prompts/00-coordinator.md"
  if [[ "$REVISE_EXISTING" != "1" ]]; then
    if grep -qxF "00-coordinator" "$CHECKPOINT_FILE" 2>/dev/null; then
      printf '[resume] skipping completed 00-coordinator\n'
    else
      printf '[coordinator] %s\n' "$coordinator"
      if run_prompt "$coordinator" "00-coordinator" "coordinator"; then
        printf '%s\n' "00-coordinator" >> "$CHECKPOINT_FILE"
      fi
    fi
  else
    printf '[revise-existing] skipping catalog/global coordination and using existing implementation units\n'
  fi

  if [[ "$NO_NORMALIZE" != "1" ]]; then
    normalize_workstream_sizes
  fi
  normalize_units_tsv
  build_implemented_packet_set 0
  rebuild_workstream_coordinator_prompts

  if [[ "$REVISE_EXISTING" != "1" ]]; then
    while IFS=$'\t' read -r f1 f2 f3 f4 f5 _f6 _f7; do
      local group model_class packets_csv
      if [[ "$f1" == WS-* ]]; then
        group="$f1"
        model_class="$f3"
        packets_csv="$f4"
      else
        group="$f1"
        model_class="$f2"
        packets_csv="$f4"
      fi
      [[ -z "${group:-}" ]] && continue
      if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
        continue
      fi
      local prompt="$REMEDIATION_DIR/prompts/coordinate-$group.md"
      local coord_name="coordinate-$group"
      if grep -qxF "$coord_name" "$CHECKPOINT_FILE" 2>/dev/null; then
        printf '[resume] skipping completed %s\n' "$coord_name"
        continue
      fi
      # If every packet in this workstream is already complete, auto-checkpoint
      # without running the coordinator — nothing left to coordinate.
      local _remaining
      _remaining="$(incomplete_packets_csv "$packets_csv")"
      if [[ -z "$_remaining" ]]; then
        printf '[coordinator-skip] %s: all packets complete, auto-checkpointing\n' "$coord_name"
        printf '%s\n' "$coord_name" >> "$CHECKPOINT_FILE"
        continue
      fi
      printf '[workstream-coordinator] group=%s model_class=%s incomplete=%s\n' \
        "$group" "$model_class" "$_remaining"
      if run_prompt "$prompt" "$coord_name" "coordinator"; then
        printf '%s\n' "$coord_name" >> "$CHECKPOINT_FILE"
      fi
    done < <(tail -n +2 "$WORKSTREAMS_TSV")
  fi

  guard_against_raw_unit_manifest
  execute_planners

  local -a pids=()
  local -a names=()
  local active=0

  rebuild_unit_prompts

  export _WAVE_DISPLAY=1

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    if [[ "$REVISE_EXISTING" != "1" ]]; then
      local _already_complete_packets
      _already_complete_packets="$(incomplete_packets_csv "$packets_csv")"
      if [[ -z "$_already_complete_packets" ]]; then
        printf '[resume] all packets complete for %s; auto-checkpointing\n' "implement-$unit_id"
        printf '%s\n' "implement-$unit_id" >> "$CHECKPOINT_FILE"
        continue
      fi
    fi
    # Skip already-completed units. Revision passes re-run units unless the
    # summary artifact already records IMPLEMENTATION_RESULT: fixed, which
    # means the unit was successfully implemented and does not need a redo.
    if grep -qxF "implement-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      local _summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
      local _remaining_packets
      _remaining_packets="$(incomplete_packets_csv "$packets_csv")"
      if [[ "$REVISE_EXISTING" == "1" ]]; then
        printf '[revise] re-running %s from verifier decision\n' "implement-$unit_id"
      elif [[ -z "$_remaining_packets" ]]; then
        printf '[resume] skipping completed unit %s\n' "implement-$unit_id"
        continue
      else
        printf '[resume] re-running %s; checkpoint exists but packets remain incomplete: %s\n' \
          "implement-$unit_id" "$_remaining_packets"
      fi
    fi
    local prompt="$REMEDIATION_DIR/prompts/implement-$unit_id.md"
    printf '[start] unit=%s group=%s model_class=%s packets=%s\n' "$unit_id" "$group" "$model_class" "$packets_csv"
    record_commit_baseline_for_unit "$unit_id"
    run_prompt "$prompt" "implement-$unit_id" "$model_class" &
    pids+=("$!")
    names+=("implement-$unit_id")
    active=$((active + 1))
    if ((active >= MAX_PARALLEL)); then
      if ! wait_for_wave pids names; then
        if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
          exit 1
        fi
      fi
      pids=()
      names=()
      active=0
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#pids[@]} > 0)); then
    if ! wait_for_wave pids names; then
      if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
        exit 1
      fi
    fi
  fi
}

execute_verifier_units() {
  local -a pids=()
  local -a names=()
  local active=0

  rebuild_unit_prompts

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local prior_verify_log="$REMEDIATION_DIR/logs/verify-$unit_id.log"
    if [[ "$REVISE_EXISTING" != "1" ]] && \
       ! grep -qxF "verify-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null && \
       recover_verifier_artifact_from_log "$unit_id" "$prior_verify_log"; then
      printf '[resume] recovered completed verify-%s from existing verifier log\n' "$unit_id"
      printf '%s\n' "verify-$unit_id" >> "$CHECKPOINT_FILE"
      if ! commit_verified_unit_changes "$unit_id"; then
        if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
          exit 1
        fi
      fi
      continue
    fi
    # Skip already-verified units unless this is a revision pass.
    if [[ "$REVISE_EXISTING" != "1" ]] && grep -qxF "verify-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      if artifact_mentions_all_packets "$verifier" "$packets_csv"; then
        printf '[resume] skipping completed verify-%s\n' "$unit_id"
        continue
      fi
      printf '[resume] re-running verify-%s; checkpoint exists but verifier does not cover merged packets=%s\n' \
        "$unit_id" "$packets_csv"
    fi
    local prompt="$REMEDIATION_DIR/prompts/verify-$unit_id.md"
    printf '[verify] unit=%s group=%s implementation_class=%s packets=%s\n' "$unit_id" "$group" "$model_class" "$packets_csv"
    run_prompt "$prompt" "verify-$unit_id" "verifier" &
    pids+=("$!")
    names+=("verify-$unit_id")
    active=$((active + 1))
    if ((active >= MAX_PARALLEL)); then
      if ! wait_for_wave pids names; then
        if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
          exit 1
        fi
      fi
      pids=()
      names=()
      active=0
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if ((${#pids[@]} > 0)); then
    if ! wait_for_wave pids names; then
      if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
        exit 1
      fi
    fi
  fi
  aggregate_verifier_findings
}

execute_final_review() {
  local final_review="$REMEDIATION_DIR/prompts/99-final-review.md"
  if grep -qxF "99-final-review" "$CHECKPOINT_FILE" 2>/dev/null; then
    printf '[resume] skipping completed 99-final-review\n'
    return 0
  fi
  printf '[final-review] %s\n' "$final_review"
  if run_prompt "$final_review" "99-final-review" "reviewer"; then
    printf '%s\n' "99-final-review" >> "$CHECKPOINT_FILE"
  fi
}

execute_verifiers() {
  execute_verifier_units
  execute_final_review
}

execute_revision_rounds() {
  if [[ "$AUTO_REVISE" != "1" || "$EXECUTE" != "1" || "$VERIFY" != "1" || "$VERIFY_SCOPE" != "implementation" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  local user_selected_units="$ONLY_UNIT"
  if [[ -z "$user_selected_units" ]]; then
    guard_against_auto_revise_raw_unit_manifest
  fi

  local round=1
  while ((round <= MAX_REVISION_ROUNDS)); do
    aggregate_verifier_findings
    local revised_units
    revised_units="$(revised_units_from_verifiers)"
    if [[ -z "$revised_units" ]]; then
      printf '[auto-revise] no verifier-revised units remain after round=%s\n' "$((round - 1))"
      return 0
    fi

    printf '[auto-revise] round=%s units=%s\n' "$round" "$revised_units"
    local previous_only="$ONLY_UNIT"
    local previous_revise="$REVISE_EXISTING"
    local previous_parallel="$MAX_PARALLEL"
    ONLY_UNIT="$revised_units"
    REVISE_EXISTING=1
    MAX_PARALLEL="${REMEDIATION_REVISION_MAX_PARALLEL:-2}"

    execute_workstreams
    execute_verifier_units
    aggregate_verifier_findings

    ONLY_UNIT="$previous_only"
    REVISE_EXISTING="$previous_revise"
    MAX_PARALLEL="$previous_parallel"
    round=$((round + 1))
  done

  local remaining_units
  aggregate_verifier_findings
  remaining_units="$(revised_units_from_verifiers)"
  if [[ -n "$remaining_units" ]]; then
    printf '[auto-revise] max rounds reached; remaining verifier-revised units=%s\n' "$remaining_units" >&2
  fi
}

if [[ "$VERIFY_ONLY" != "1" && "$REVISE_EXISTING" != "1" ]]; then
  _previous_px_tsv=""
  _preserve_existing_inventory=0
  if [[ -f "$PX_TSV" && "$REMEDIATION_REWRITE_PACKETS" != "1" ]] && remediation_state_exists; then
    _preserve_existing_inventory=1
  fi

  if [[ "$_preserve_existing_inventory" == "1" ]]; then
    printf '[resume] preserving existing master PX inventory: %s\n' "$PX_TSV"
    guard_existing_px_inventory_consistency
  else
    if [[ -f "$PX_TSV" ]]; then
      _previous_px_tsv="$(mktemp)"
      cp "$PX_TSV" "$_previous_px_tsv"
    fi
    extract_findings
    guard_reused_px_inventory "$_previous_px_tsv"
    [[ -n "$_previous_px_tsv" ]] && rm -f "$_previous_px_tsv"
    write_master_markdown
    write_packets_and_workstreams
  fi
  # Preserve existing implementation units by default. A reused REMEDIATION_DIR
  # may already contain cataloged/combined units; regenerating the raw PX list
  # here would disconnect resume state from completed artifacts.
  if [[ "$REMEDIATION_REWRITE_UNITS" == "1" || ! -f "$UNITS_TSV" ]]; then
    write_default_units
  elif [[ "$FORCE_CATALOG" == "1" && "$EXECUTE" == "1" && "$NO_CATALOG" != "1" ]]; then
    printf '[catalog] preserving existing implementation units as catalog seed; --force-catalog will rerun 00-cataloger: %s\n' "$UNITS_TSV"
  else
    printf '[resume] preserving existing implementation units: %s\n' "$UNITS_TSV"
  fi

  # Reconcile completed packet state before any agent phase. A reused
  # REMEDIATION_DIR may have fixed summaries from prior runs, and cataloging can
  # be slow or interrupted before the normal execution resume path is reached.
  build_implemented_packet_set 0
  write_completed_packet_manifest

  if [[ "$EXECUTE" == "1" && "$NO_CATALOG" != "1" && "$FORCE_CATALOG" != "1" && -s "$UNITS_TSV" ]]; then
    _raw_stats="$(raw_incomplete_unit_manifest_stats)"
    IFS=$'\t' read -r _raw_total _raw_units _raw_single <<< "$_raw_stats"
    if raw_incomplete_unit_manifest_is_unsafe "$_raw_total" "$_raw_units" "$_raw_single"; then
      printf '[catalog] existing implementation units are a raw incomplete PX manifest; running 00-cataloger (use --no-catalog to forbid this)\n'
      CATALOG_WITH_CODEX=1
    fi
  fi

  if [[ "$CATALOG_WITH_CODEX" == "1" ]]; then
    if [[ "$FORCE_CATALOG" == "1" && -f "$CHECKPOINT_FILE" ]]; then
      _catalog_checkpoint_tmp="$(mktemp)"
      grep -vxF "00-cataloger" "$CHECKPOINT_FILE" > "$_catalog_checkpoint_tmp" || true
      mv "$_catalog_checkpoint_tmp" "$CHECKPOINT_FILE"
      printf '[force-catalog] cleared 00-cataloger checkpoint; cataloger will rerun\n'
    fi
    if [[ "$FORCE_CATALOG" != "1" && -s "$UNITS_TSV" && -s "$WORKSTREAMS_TSV" ]]; then
      _raw_stats="$(raw_incomplete_unit_manifest_stats)"
      IFS=$'\t' read -r _raw_total _raw_units _raw_single <<< "$_raw_stats"
      if raw_incomplete_unit_manifest_is_unsafe "$_raw_total" "$_raw_units" "$_raw_single"; then
        build_catalog_prompt
        printf '[cataloger] %s\n' "$REMEDIATION_DIR/prompts/00-cataloger.md"
        if run_prompt "$REMEDIATION_DIR/prompts/00-cataloger.md" "00-cataloger" "cataloger"; then
          printf '%s\n' "00-cataloger" >> "$CHECKPOINT_FILE"
        fi
      else
        printf '[resume] existing catalog detected; skipping 00-cataloger (use --force-catalog to rewrite)\n'
        grep -qxF "00-cataloger" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "00-cataloger" >> "$CHECKPOINT_FILE"
      fi
    else
      build_catalog_prompt
      if grep -qxF "00-cataloger" "$CHECKPOINT_FILE" 2>/dev/null; then
        printf '[resume] skipping completed 00-cataloger\n'
      else
        printf '[cataloger] %s\n' "$REMEDIATION_DIR/prompts/00-cataloger.md"
        if run_prompt "$REMEDIATION_DIR/prompts/00-cataloger.md" "00-cataloger" "cataloger"; then
          printf '%s\n' "00-cataloger" >> "$CHECKPOINT_FILE"
        fi
      fi
    fi
  elif [[ "$EXECUTE" == "1" && "$NO_CATALOG" != "1" && "$FORCE_CATALOG" != "1" && -s "$UNITS_TSV" && -s "$WORKSTREAMS_TSV" ]]; then
    printf '[resume] existing catalog detected; not auto-running 00-cataloger (use --force-catalog to rewrite)\n'
  fi
elif [[ ! -f "$WORKSTREAMS_TSV" || ! -f "$PX_TSV" || ! -f "$UNITS_TSV" ]]; then
  echo "--verify-only/--revise-existing requires an existing REMEDIATION_DIR with $PX_TSV, $WORKSTREAMS_TSV, and $UNITS_TSV" >&2
  exit 2
fi

normalize_units_tsv
build_implemented_packet_set 0
if [[ "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
  guard_against_incomplete_unit_coverage
  guard_against_raw_unit_manifest
fi
build_implemented_packet_set 1
build_coordinator_prompt

rebuild_workstream_coordinator_prompts
rebuild_unit_prompts
build_final_review_prompt

SHOULD_RUN_SPLIT_PREFLIGHT=0
if [[ "$SPLIT_INCOMPLETE" == "1" ]]; then
  SHOULD_RUN_SPLIT_PREFLIGHT=1
elif [[ "$AUTO_SPLIT_BEFORE_EXECUTE" == "1" && "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
  SHOULD_RUN_SPLIT_PREFLIGHT=1
fi

if [[ "$SHOULD_RUN_SPLIT_PREFLIGHT" == "1" ]]; then
  split_incomplete_units
  PENDING_SPLIT_CHILD_UNITS="$(pending_split_child_units)"
  PENDING_IMPLEMENTATION_UNITS="$(pending_implementation_units)"
  DIRECT_SPLIT_CANDIDATE_UNITS="$(direct_split_candidate_units)"
  SPLIT_RUN_UNITS="$(combine_unit_lists "$PENDING_IMPLEMENTATION_UNITS" "$AUTO_SPLIT_CHILD_UNITS" "$PENDING_SPLIT_CHILD_UNITS" "$DIRECT_SPLIT_CANDIDATE_UNITS")"
  if [[ -n "$SPLIT_RUN_UNITS" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
    if [[ -n "$PENDING_IMPLEMENTATION_UNITS" ]]; then
      printf '[split-auto-run] scheduling pending implementation units: %s\n' "$PENDING_IMPLEMENTATION_UNITS"
    fi
    if [[ -n "$PENDING_SPLIT_CHILD_UNITS" || -n "$AUTO_SPLIT_CHILD_UNITS" ]]; then
      printf '[split-auto-run] scheduling split child units: %s\n' "$(combine_unit_lists "$AUTO_SPLIT_CHILD_UNITS" "$PENDING_SPLIT_CHILD_UNITS")"
    fi
    if [[ -n "$DIRECT_SPLIT_CANDIDATE_UNITS" ]]; then
      printf '[split-auto-run] scheduling direct candidate units: %s\n' "$DIRECT_SPLIT_CANDIDATE_UNITS"
    fi
    ONLY_UNIT="$SPLIT_RUN_UNITS"
    printf '[split-auto-run] selected units: %s\n' "$ONLY_UNIT"
    if [[ -n "$PENDING_SPLIT_CHILD_UNITS" || -n "$AUTO_SPLIT_CHILD_UNITS" ]]; then
      MAX_PARALLEL="${SPLIT_CHILD_MAX_PARALLEL:-1}"
    fi
    printf '[split-auto-run] max parallel=%s\n' "$MAX_PARALLEL"
  elif [[ -n "$AUTO_SPLIT_CHILD_UNITS" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
    printf '[split-auto-run] replacing selected parent units with child units: %s\n' "$AUTO_SPLIT_CHILD_UNITS"
    ONLY_UNIT="$AUTO_SPLIT_CHILD_UNITS"
    MAX_PARALLEL="${SPLIT_CHILD_MAX_PARALLEL:-1}"
    printf '[split-auto-run] child max parallel=%s\n' "$MAX_PARALLEL"
  elif [[ -n "$SPLIT_CANDIDATE_UNITS" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
    printf '[split-auto-run] split candidates detected, but no pending direct or child units remain; skipping fixed candidates\n'
    SPLIT_SKIP_EXECUTION=1
  elif [[ "$SPLIT_INCOMPLETE" == "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
    printf '[split-auto-run] no split candidates or child units; skipping execution\n'
    SPLIT_SKIP_EXECUTION=1
  elif [[ "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ]]; then
    printf '[split-auto-run] no split candidates or child units; continuing with normal execution schedule\n'
  fi
  rebuild_workstream_coordinator_prompts
  rebuild_unit_prompts
  build_final_review_prompt
fi

write_run_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ ! -f "$UNITS_TSV" ]] && return 0
  local summary="$REMEDIATION_DIR/06-run-summary.tsv"
  local total=0 fixed=0 partial=0 blocked=0

  printf 'unit_id\tgroup\tmodel_class\timplement_result\tverify_decision\n' > "$summary"

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    local impl_artifact="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    local verify_artifact="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local impl_log="$REMEDIATION_DIR/logs/implement-$unit_id.log"

    local impl_result
    if [[ -s "$impl_artifact" ]]; then
      impl_result="$(grep -oi 'IMPLEMENTATION_RESULT:[[:space:]]*[a-z]*' "$impl_artifact" 2>/dev/null | head -1 | sed 's/.*IMPLEMENTATION_RESULT:[[:space:]]*//')"
      [[ -z "$impl_result" ]] && impl_result="$(grep -oi 'RESULT:[[:space:]]*[A-Za-z/]*' "$impl_log" 2>/dev/null | tail -1 | sed 's/.*RESULT:[[:space:]]*//')"
      [[ -z "$impl_result" ]] && impl_result="completed"
    elif [[ -f "$impl_log" ]]; then
      impl_result="failed"
    else
      impl_result="not-run"
    fi

    local verify_decision
    if [[ -s "$verify_artifact" ]]; then
      verify_decision="$(grep -oi 'Decision:[[:space:]]*[a-z]*' "$verify_artifact" 2>/dev/null | head -1 | sed 's/.*Decision:[[:space:]]*//')"
      [[ -z "$verify_decision" ]] && verify_decision="unreadable"
    else
      verify_decision="not-verified"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$unit_id" "$group" "$model_class" "$impl_result" "$verify_decision" >> "$summary"
    total=$((total + 1))
    case "$impl_result" in
      fixed|pass|PASS|completed) fixed=$((fixed + 1)) ;;
      partial|incomplete|INCOMPLETE) partial=$((partial + 1)) ;;
      *) blocked=$((blocked + 1)) ;;
    esac
  done < <(tail -n +2 "$UNITS_TSV")

  printf '\n=== Remediation Run Summary (%d units) ===\n' "$total"
  printf 'fixed/completed: %d  partial: %d  failed/not-run: %d\n' "$fixed" "$partial" "$blocked"
  if ((partial > 0 || blocked > 0)); then
    printf 'Non-fixed units:\n'
    awk -F'\t' 'NR>1 && $4 !~ /^(fixed|pass|PASS|completed)$/ { printf "  %s (%s): impl=%s verify=%s\n", $1, $2, $4, $5 }' "$summary"
  fi
  printf 'Summary: %s\n' "$summary"
  printf '==========================================\n'
}

verifier_finding_type_exists() {
  local findings="$1" type="$2"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' -v type="$type" '
    NR > 1 && $3 == type {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$findings"
}

verifier_findings_count() {
  local findings="$1"
  [[ -s "$findings" ]] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' 'NR > 1 && $1 != "" { count += 1 } END { printf "%d\n", count }' "$findings"
}

verifier_queue_category() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"

  if verifier_accepts_unit "$unit_id"; then
    if verifier_finding_type_exists "$findings" "launch_evidence" || verifier_finding_type_exists "$findings" "sandbox_blocked"; then
      printf 'accepted_evidence_pending\n'
    else
      printf 'accepted\n'
    fi
    return 0
  fi

  if verifier_finding_type_exists "$findings" "contract_conflict"; then
    printf 'contract_conflict\n'
  elif verifier_finding_type_exists "$findings" "test_harness"; then
    printf 'test_harness\n'
  elif verifier_finding_type_exists "$findings" "split_required"; then
    printf 'split_required\n'
  elif verifier_finding_type_exists "$findings" "blocked"; then
    printf 'blocked\n'
  elif [[ ! -s "$verifier" ]]; then
    printf 'not_verified\n'
  elif file_matches '(^|[-*[:space:]])Decision:[[:space:]]*`?(stop)|(^|[-*[:space:]])Implementation decision:[[:space:]]*`?(blocked)' "$verifier"; then
    printf 'blocked\n'
  elif file_matches '(^|[-*[:space:]])Decision:[[:space:]]*`?(revise)|(^|[-*[:space:]])Implementation decision:[[:space:]]*`?(revise)' "$verifier"; then
    printf 'needs_targeted_revision\n'
  else
    printf 'needs_review\n'
  fi
}

write_remediation_queue_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ ! -f "$UNITS_TSV" ]] && return 0
  aggregate_verifier_findings

  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  printf 'unit_id\tgroup\tmodel_class\tpackets\tcategory\tfinding_count\tverifier_artifact\tfindings_tsv\n' > "$queue"

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local findings
    findings="$(verifier_findings_tsv_for_unit "$unit_id")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$unit_id" \
      "$group" \
      "$model_class" \
      "$packets_csv" \
      "$(verifier_queue_category "$unit_id")" \
      "$(verifier_findings_count "$findings")" \
      "$verifier" \
      "$findings" >> "$queue"
  done < <(tail -n +2 "$UNITS_TSV")

  printf 'Queue: %s\n' "$queue"
  awk -F '\t' 'NR > 1 { count[$5] += 1 } END { for (category in count) printf "  %s: %d\n", category, count[category] }' "$queue" | sort
}

printf 'Remediation run directory: %s\n' "$REMEDIATION_DIR"
printf 'Master Px list: %s\n' "$PX_MD"
printf 'Workstreams: %s\n' "$WORKSTREAMS_TSV"
printf 'Implementation units: %s\n' "$UNITS_TSV"
printf 'Packets: %s/packets\n' "$REMEDIATION_DIR"

if [[ "$RECOORDINATE" == "1" && -f "$CHECKPOINT_FILE" ]]; then
  _rc_before=$(grep -c "^coordinate-" "$CHECKPOINT_FILE" 2>/dev/null || true)
  grep -v "^coordinate-" "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
  _rc_after=$(grep -c "^coordinate-" "$CHECKPOINT_FILE" 2>/dev/null || true)
  printf '[recoordinate] cleared %d coordinate-* checkpoint entries; workstream coordinators will re-run against incomplete packets\n' \
    "$(( _rc_before - _rc_after ))"
fi

if [[ "$VERIFY_ONLY" == "1" ]]; then
  execute_verifiers
elif [[ "$SPLIT_SKIP_EXECUTION" == "1" ]]; then
  printf 'No split candidates or child units to execute.\n'
elif [[ "$EXECUTE" == "1" || "$DRY_RUN" == "1" ]]; then
  execute_workstreams
  if [[ "$VERIFY" == "1" ]]; then
    execute_verifier_units
    execute_revision_rounds
    execute_final_review
  fi
else
  printf 'Plan generated only. Re-run with --execute to launch remediation agents.\n'
fi

write_run_summary
write_remediation_queue_summary
