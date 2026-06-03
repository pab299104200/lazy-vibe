#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

if [[ "${REMEDIATION_SCRIPT_SNAPSHOT:-0}" != "1" ]]; then
  _remediation_script_source="${BASH_SOURCE[0]}"
  _remediation_script_dir="$(cd "$(dirname "$_remediation_script_source")" && pwd)"
  _remediation_script_snapshot="$(mktemp "${TMPDIR:-/tmp}/run-remediation.XXXXXX.sh")"
  cp "$_remediation_script_source" "$_remediation_script_snapshot"
  chmod 700 "$_remediation_script_snapshot"
  if ! bash -n "$_remediation_script_snapshot"; then
    printf '[fatal] run-remediation.sh has a shell syntax error; refusing to start a long remediation run\n' >&2
    printf '[fatal] source=%s snapshot=%s\n' "$_remediation_script_source" "$_remediation_script_snapshot" >&2
    exit 2
  fi
  export REMEDIATION_SCRIPT_SNAPSHOT=1
  export REMEDIATION_SCRIPT_DIR="$_remediation_script_dir"
  export REMEDIATION_SCRIPT_ORIGINAL="$_remediation_script_source"
  exec bash "$_remediation_script_snapshot" "$@"
fi

SCRIPT_DIR="${REMEDIATION_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Harness runs must never block in an interactive git editor. These exports also
# cover implementer/verifier child processes launched from this script.
export GIT_EDITOR="${GIT_EDITOR:-true}"
export GIT_SEQUENCE_EDITOR="${GIT_SEQUENCE_EDITOR:-true}"
export GIT_MERGE_AUTOEDIT="${GIT_MERGE_AUTOEDIT:-no}"

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
REVISE_NEXT_LIMIT="${REMEDIATION_REVISE_NEXT_LIMIT:-8}"
REVISE_NEXT_MAX_ROUNDS="${REMEDIATION_REVISE_NEXT_MAX_ROUNDS:-10}"
QUEUE_DRAIN_MAX_ROUNDS="${REMEDIATION_QUEUE_DRAIN_MAX_ROUNDS:-20}"
EXECUTE=0
VERIFY=0
VERIFY_ONLY=0
FINALIZE_ONLY=0
SUMMARY_ONLY=0
STATE_RESUME=0
FORCE_VERIFY=0
FORCE_FINAL_REVIEW=0
REVISE_NEXT=0
DRAIN_QUEUE=0
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
SPLIT_CANDIDATE_COUNT=0
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
REMEDIATION_COLLECT_EVIDENCE="${REMEDIATION_COLLECT_EVIDENCE:-1}"
REMEDIATION_EVIDENCE_MAX_ROUNDS="${REMEDIATION_EVIDENCE_MAX_ROUNDS:-1}"
REMEDIATION_EVIDENCE_MODE="${REMEDIATION_EVIDENCE_MODE:-targeted}"
REMEDIATION_AUTO_RERUN_FINAL_REVIEW="${REMEDIATION_AUTO_RERUN_FINAL_REVIEW:-1}"
REMEDIATION_AUTO_VERIFY_MISSING="${REMEDIATION_AUTO_VERIFY_MISSING:-1}"
REMEDIATION_AUTO_METADATA_CLOSEOUT="${REMEDIATION_AUTO_METADATA_CLOSEOUT:-1}"
REMEDIATION_SANDBOX_PYTEST_FALLBACK="${REMEDIATION_SANDBOX_PYTEST_FALLBACK:-1}"
REMEDIATION_STATIC_PRECHECKS="${REMEDIATION_STATIC_PRECHECKS:-1}"
REMEDIATION_AUTO_DRAIN_QUEUE="${REMEDIATION_AUTO_DRAIN_QUEUE:-1}"
REMEDIATION_VERIFY_AFTER_EXECUTE="${REMEDIATION_VERIFY_AFTER_EXECUTE:-1}"
NO_CATALOG=0
FEATURE=""
SCORECARD=""
SCORECARD_ONLY_SOURCE=0

usage() {
  cat <<'USAGE'
Usage: run-remediation.sh --audit-run RUN_DIR [--feature SLUG] [--scorecard FILE] [--execute] [--verify] [--no-verify-after-execute] [--verify-only] [--finalize-only] [--summary-only] [--rerun-verifiers] [--rerun-final-review] [--revise-next] [--drain-queue] [--no-drain-queue] [--revise-existing] [--split-incomplete] [--no-auto-split] [--no-catalog] [--force-catalog] [--catalog-with-codex] [--dry-run] [--verbose] [--only-group GROUP] [--only-unit IU-0001,IU-0002]

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
  REMEDIATION_REVISE_NEXT_LIMIT
                              Max safe queue units selected by --revise-next. Defaults to 8.
                              Set to 0 for all currently safe candidates.
  REMEDIATION_REVISE_NEXT_MAX_ROUNDS
                              Max deterministic --revise-next batches before stopping. Defaults to 10.
                              Set to 0 to continue until no safe candidates or no queue progress.
  REMEDIATION_QUEUE_DRAIN_MAX_ROUNDS
                              Max deterministic --drain-queue action rounds. Defaults to 20.
                              Set to 0 to continue until only manual buckets remain or progress stops.
  REMEDIATION_REVISION_MAX_PARALLEL
                              Parallelism during revision rounds. Defaults to 2.
  REMEDIATION_VERIFY_SCOPE    implementation or launch. Defaults to implementation.
  REMEDIATION_RUN_GLOBAL_NATIVE_CHECKS
                              1 to run profile-wide native commands such as full lint/build/test
                              after every unit. Defaults to 0 so unrelated repo drift does not
                              fail a focused implementation unit.
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
  REMEDIATION_COLLECT_EVIDENCE
                              1 to automatically collect deterministic launch evidence after
                              verification finds only evidence/coordination gaps. Defaults to 1.
                              Set to 0 only to force a manual evidence pass.
  REMEDIATION_EVIDENCE_MODE   targeted or full. Defaults to targeted. Targeted mode exports
                              PORTAL_AUDIT_SKIP_RUNTIME_QUALITY=1 for browser evidence wrappers
                              so proof-specific Playwright evidence is not failed by unrelated
                              Lighthouse/runtime-quality gates.
  REMEDIATION_EVIDENCE_MAX_ROUNDS
                              Max collect-evidence then verify-only loops. Defaults to 1.
  REMEDIATION_AUTO_RERUN_FINAL_REVIEW
                              1 to rerun final review automatically when verifier inputs changed.
                              Defaults to 1.
  REMEDIATION_AUTO_VERIFY_MISSING
                              1 to verify queue rows with missing/unreadable verifier artifacts
                              during default state resume. Defaults to 1.
  REMEDIATION_AUTO_METADATA_CLOSEOUT
                              1 to auto-repair remediation-owned packet/summary closeout metadata
                              findings and reverify them. Defaults to 1.
  REMEDIATION_SANDBOX_PYTEST_FALLBACK
                              1 to retry pytest commands with -p no:rerunfailures when the
                              rerunfailures plugin is blocked by sandbox socket permissions.
                              Defaults to 1.
  REMEDIATION_STATIC_PRECHECKS
                              1 to run deterministic static hygiene prechecks and feed their
                              output into verifier prompts. Defaults to 1.
  REMEDIATION_AUTO_DRAIN_QUEUE
                              1 to drain the current remediation queue by default on resumed
                              runs with no explicit phase. Defaults to 1. Use --no-drain-queue
                              or set to 0 for summary/resume-only behavior.
  REMEDIATION_VERIFY_AFTER_EXECUTE
                              1 to run verifiers automatically after an implementation wave.
                              Defaults to 1. Use --no-verify-after-execute or set to 0 only
                              when intentionally generating implementation artifacts without
                              verifier scoring.
  REMEDIATION_ALLOW_WORKTREE_FALLBACK
                              1 to fall back to the live REPO_ROOT when git worktree creation fails.
                              Defaults to 0 for git-root repos because live fallback can make
                              parallel units overwrite each other.
  REMEDIATION_ALLOW_LIVE_WORKSPACE_PARALLEL
                              1 to allow parallel execution when REPO_ROOT is not a git root.
                              This is unsafe for general use because units edit the same live
                              workspace without git worktree isolation.
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
  CATALOG_AGENT               Built-in cataloger agent. Defaults to IMPLEMENTER_AGENT.
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
  CLAUDE_TRANSPORT            prompt or pty. Defaults to prompt, which uses claude -p.
                              pty avoids -p by driving interactive claude through a pseudo-terminal.
  CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS
                              Seconds of no terminal output after RESULT before PTY mode exits. Defaults to 20.
  CLAUDE_PTY_STARTUP_SECONDS  Seconds to wait before pasting the prompt into interactive claude. Defaults to 3.

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
Use --execute to run the coordinator and workstream agents, then verifier/final-review agents by default.
Use --no-verify-after-execute only for an intentional implementation-only pass.
Use --no-catalog to skip the cataloger when --execute is set (useful when packets were hand-edited or the cataloger already ran).
Use --recoordinate to strip coordinate-* checkpoint entries and re-run workstream coordinators against incomplete packets only. Combine with --no-catalog --no-auto-split --execute to resume from open packets without touching the catalog or splitting logic.
Use --no-normalize to skip workstream source-kind splitting on resume runs where normalization has already been done.
Use --catalog-with-codex to run the cataloger explicitly without --execute (plan-only mode with catalog refinement).
Use --verify to run read-only verifier agents after workstream implementation.
Use --verify-only to run only verifier and final-review agents against an existing remediation directory.
Use --finalize-only to skip implementation/verifier agents and regenerate aggregate findings,
run or skip the final review based on its input fingerprint, and write summary/queue outputs.
Use --summary-only to skip all agents and only regenerate aggregate findings, run summary,
and remediation queue outputs.
By default, a reused remediation directory drains deterministically from current state:
missing/stale verifiers are refreshed, safe targeted revisions are implemented and verified,
pending split children are executed, deterministic evidence is collected, final review is
refreshed, and summaries/queues are regenerated. It stops when only manual buckets remain.
Use --no-drain-queue to skip those automatic actions and only do resume bookkeeping.
Use --rerun-verifiers to explicitly rerun completed/stale verifier sections.
Use --rerun-final-review to explicitly rerun a completed/stale final review.
Use --revise-next to implement and verify the next safe needs_targeted_revision units
from the current remediation queue, leaving blocked/contract/test-harness/split work untouched.
It selects at most REMEDIATION_REVISE_NEXT_LIMIT units per batch in queue order by default,
then repeats deterministically until safe candidates are exhausted, the queue stops improving,
or REMEDIATION_REVISE_NEXT_MAX_ROUNDS is reached.
Use --drain-queue to keep deriving safe next actions from the current queue:
refresh not_verified units, revise safe needs_targeted_revision units, execute pending split
children, repair remediation metadata, collect deterministic evidence, and refresh final review.
It stops when only manual buckets remain, such as blocked, contract_conflict, true test_harness,
or launch evidence that cannot be collected deterministically.
Use --no-drain-queue to disable the default queue drain on a reused remediation directory.
Use --revise-existing with REMEDIATION_DIR to rerun implementation against existing packet/verifier artifacts instead of regenerating packets.
When --revise-existing is combined with --execute, the selected verifier sections are rerun automatically so the queue cannot remain on stale verifier artifacts.
Use --feature or --scorecard to seed remediation from a feature scorecard. When no --audit-run is supplied, the scorecard becomes the source of truth for packet extraction.
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
    --feature)
      FEATURE="${2:?missing feature slug}"
      shift 2
      ;;
    --scorecard)
      SCORECARD="${2:?missing scorecard file}"
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
    --no-verify-after-execute)
      REMEDIATION_VERIFY_AFTER_EXECUTE=0
      shift
      ;;
    --verify-only)
      VERIFY=1
      VERIFY_ONLY=1
      shift
      ;;
    --finalize-only)
      FINALIZE_ONLY=1
      shift
      ;;
    --summary-only)
      SUMMARY_ONLY=1
      shift
      ;;
    --rerun-verifiers)
      FORCE_VERIFY=1
      VERIFY=1
      VERIFY_ONLY=1
      shift
      ;;
    --rerun-final-review)
      FORCE_FINAL_REVIEW=1
      FINALIZE_ONLY=1
      shift
      ;;
    --revise-next)
      REVISE_NEXT=1
      shift
      ;;
    --drain-queue)
      DRAIN_QUEUE=1
      EXECUTE=1
      shift
      ;;
    --no-drain-queue)
      REMEDIATION_AUTO_DRAIN_QUEUE=0
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

if [[ -z "$SCORECARD" && -n "$FEATURE" ]]; then
  if [[ -f "$REPO_ROOT/docs/scorecard/$FEATURE.md" ]]; then
    SCORECARD="$REPO_ROOT/docs/scorecard/$FEATURE.md"
  elif [[ -f "$REPO_ROOT/docs/scorecards/$FEATURE.md" ]]; then
    SCORECARD="$REPO_ROOT/docs/scorecards/$FEATURE.md"
  fi
fi
if [[ -n "$SCORECARD" ]]; then
  [[ "$SCORECARD" != /* ]] && SCORECARD="$REPO_ROOT/$SCORECARD"
  if [[ ! -f "$SCORECARD" ]]; then
    printf 'Scorecard file not found: %s\n' "$SCORECARD" >&2
    exit 2
  fi
fi

if [[ -z "$AUDIT_RUN" ]]; then
  if [[ -n "$SCORECARD" ]]; then
    AUDIT_RUN="scorecard:$SCORECARD"
    SCORECARD_ONLY_SOURCE=1
    printf '[scorecard] using scorecard remediation source: %s\n' "$SCORECARD"
  else
    # Auto-detect latest audit run
    AUDIT_RUN=$(find "$REPO_ROOT/docs/audit" "$REPO_ROOT/project-audit" "$REPO_ROOT" -maxdepth 2 -type d \( -name "*-launch-readiness-run" -o -name "*-audit-run" \) 2>/dev/null | sort | tail -n 1 || true)
  fi
  if [[ -z "$AUDIT_RUN" ]]; then
    echo "--audit-run is required and could not be auto-detected" >&2
    usage >&2
    exit 2
  fi
  [[ "$AUDIT_RUN" == scorecard:* ]] || printf '[auto-detect] using audit run: %s\n' "$AUDIT_RUN"
elif [[ ! -d "$AUDIT_RUN" ]]; then
  echo "Audit run directory not found: $AUDIT_RUN" >&2
  exit 2
fi

if [[ -z "$REMEDIATION_DIR" ]]; then
  if [[ "$AUDIT_RUN" == scorecard:* ]]; then
    _feature_slug="${FEATURE:-$(basename "$SCORECARD" .md)}"
    REMEDIATION_DIR="$REPO_ROOT/docs/audit/$(date +%Y-%m-%d)-${_feature_slug}-remediation-run"
  else
    _audit_date=$(basename "$AUDIT_RUN" | grep -o '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || date +%Y-%m-%d)
    REMEDIATION_DIR="$(dirname "$AUDIT_RUN")/${_audit_date}-remediation-run"
  fi
  printf '[auto-detect] using remediation dir: %s\n' "$REMEDIATION_DIR"
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

if [[ "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" ) ]] && \
   ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 && \
   [[ "${REMEDIATION_ALLOW_LIVE_WORKSPACE_PARALLEL:-0}" != "1" ]]; then
  if [[ "$MAX_PARALLEL" != "1" ]]; then
    printf '[workspace] REPO_ROOT is not a git root; using live split-root workspace and forcing MAX_PARALLEL=1 so implementation units do not edit backend/frontend concurrently\n'
    MAX_PARALLEL=1
  fi
  if [[ "${REMEDIATION_REVISION_MAX_PARALLEL:-2}" != "1" ]]; then
    printf '[workspace] REPO_ROOT is not a git root; forcing REMEDIATION_REVISION_MAX_PARALLEL=1 for the same reason\n'
    REMEDIATION_REVISION_MAX_PARALLEL=1
  fi
elif [[ "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" ) ]] && \
     ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  printf '[workspace] REPO_ROOT is not a git root; REMEDIATION_ALLOW_LIVE_WORKSPACE_PARALLEL=1 set for live split-root workspace, preserving MAX_PARALLEL=%s and REMEDIATION_REVISION_MAX_PARALLEL=%s\n' \
    "$MAX_PARALLEL" "${REMEDIATION_REVISION_MAX_PARALLEL:-2}"
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
  if [[ "$VERIFY" == "1" || "$VERIFY_ONLY" == "1" || "$FINALIZE_ONLY" == "1" ]]; then
    printf '[warn] REVIEWER_AGENT not set; defaulting to IMPLEMENTER_AGENT=%s. Same-model verification reduces independence — set REVIEWER_AGENT to a different agent for stronger review.\n' "$IMPLEMENTER_AGENT" >&2
  fi
fi

PX_TSV="$REMEDIATION_DIR/00-master-px-list.tsv"
PX_MD="$REMEDIATION_DIR/01-master-px-list.md"
RAW_PX_TSV="$REMEDIATION_DIR/00-raw-px-list.tsv"
BLOCKER_LEDGER_TSV="$REMEDIATION_DIR/00-blocker-ledger.tsv"
BLOCKER_LEDGER_MD="$REMEDIATION_DIR/00-blocker-ledger.md"
WORKSTREAMS_TSV="$REMEDIATION_DIR/02-workstreams.tsv"
UNITS_TSV="$REMEDIATION_DIR/03-implementation-units.tsv"
AUDIT_SOURCE_MANIFEST="$REMEDIATION_DIR/00-audit-source-manifest.tsv"
SPLIT_CANDIDATES_TSV="$REMEDIATION_DIR/05-split-candidates.tsv"
SPLIT_PLAN_MD="$REMEDIATION_DIR/05-split-plan.md"
SCOPE_CLASSIFICATION_TSV="$REMEDIATION_DIR/05-scope-classification.tsv"
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
    *)
      local parent_unit="$unit_id"
      parent_unit="${parent_unit%-S[0-9][0-9]}"
      if [[ "$parent_unit" != "$unit_id" ]]; then
        case ",$ONLY_UNIT," in
          *,"$parent_unit",*) return 0 ;;
        esac
      fi
      return 1
      ;;
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

verifier_findings_count() {
  local findings="$1"
  [[ -s "$findings" ]] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' 'NR > 1 && $1 != "" { count += 1 } END { printf "%d\n", count + 0 }' "$findings"
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


hash_file_for_fingerprint() {
  local label="$1" file="$2"
  if [[ -s "$file" ]]; then
    printf 'file\t%s\t' "$label"
    sha256sum "$file"
  else
    printf 'missing\t%s\n' "$label"
  fi
}

verifier_fingerprint_file() {
  printf '%s/artifacts/verify-%s.inputs.sha256\n' "$REMEDIATION_DIR" "$1"
}

verifier_input_fingerprint() {
  local unit_id="$1" packets_csv="$2"
  {
    printf 'kind\tverifier\n'
    printf 'unit\t%s\n' "$unit_id"
    printf 'packets\t%s\n' "$packets_csv"
    hash_file_for_fingerprint "manifest:03-implementation-units.tsv" "$UNITS_TSV"

    local packet_id packet_file
    IFS=',' read -ra _fingerprint_packets <<< "$packets_csv"
    for packet_id in "${_fingerprint_packets[@]}"; do
      packet_id="${packet_id#"${packet_id%%[![:space:]]*}"}"
      packet_id="${packet_id%"${packet_id##*[![:space:]]}"}"
      [[ -n "$packet_id" ]] || continue
      packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
      hash_file_for_fingerprint "packet:$packet_id" "$packet_file"
    done

    hash_file_for_fingerprint "implementation-summary:$unit_id" "$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    hash_file_for_fingerprint "implementation-log:$unit_id" "$REMEDIATION_DIR/logs/implement-$unit_id.log"
  } | sha256sum | awk '{print $1}'
}

write_verifier_input_fingerprint() {
  local unit_id="$1" packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  [[ -n "$packets_csv" ]] || return 1
  mkdir -p "$REMEDIATION_DIR/artifacts"
  verifier_input_fingerprint "$unit_id" "$packets_csv" > "$(verifier_fingerprint_file "$unit_id")"
}

verifier_input_fingerprint_matches() {
  local unit_id="$1" packets_csv="$2" fingerprint_file
  fingerprint_file="$(verifier_fingerprint_file "$unit_id")"
  [[ -s "$fingerprint_file" ]] || return 1
  [[ "$(cat "$fingerprint_file")" == "$(verifier_input_fingerprint "$unit_id" "$packets_csv")" ]]
}

final_review_fingerprint_file() {
  printf '%s/artifacts/99-final-review.inputs.sha256\n' "$REMEDIATION_DIR"
}

final_review_input_fingerprint() {
  {
    printf 'kind\tfinal-review\n'
    printf 'audit_run\t%s\n' "$AUDIT_RUN"
    printf 'verify_scope\t%s\n' "$VERIFY_SCOPE"
    hash_file_for_fingerprint "manifest:01-px.tsv" "$PX_TSV"
    hash_file_for_fingerprint "manifest:02-workstreams.tsv" "$WORKSTREAMS_TSV"
    hash_file_for_fingerprint "manifest:03-implementation-units.tsv" "$UNITS_TSV"
    hash_file_for_fingerprint "aggregate:05-verifier-findings.tsv" "$(aggregate_verifier_findings_tsv)"
    hash_file_for_fingerprint "scope:05-scope-classification.tsv" "$REMEDIATION_DIR/05-scope-classification.tsv"

    if [[ -d "$REMEDIATION_DIR/packets" ]]; then
      find "$REMEDIATION_DIR/packets" -maxdepth 1 -type f -name 'PX-*.md' -print 2>/dev/null \
        | sort \
        | while IFS= read -r file; do
            hash_file_for_fingerprint "packet:${file#"$REMEDIATION_DIR/packets/"}" "$file"
          done
    fi

    if [[ -d "$REMEDIATION_DIR/artifacts" ]]; then
      find "$REMEDIATION_DIR/artifacts" -maxdepth 1 -type f \
        \( -name 'verify-*.md' -o -name 'verify-*-findings.tsv' -o -name 'verify-*.inputs.sha256' \) -print 2>/dev/null \
        | sort \
        | while IFS= read -r file; do
            hash_file_for_fingerprint "artifact:${file#"$REMEDIATION_DIR/artifacts/"}" "$file"
          done
    fi
  } | sha256sum | awk '{print $1}'
}

write_final_review_input_fingerprint() {
  mkdir -p "$REMEDIATION_DIR/artifacts"
  final_review_input_fingerprint > "$(final_review_fingerprint_file)"
}

final_review_input_fingerprint_matches() {
  local fingerprint_file
  fingerprint_file="$(final_review_fingerprint_file)"
  [[ -s "$fingerprint_file" ]] || return 1
  [[ "$(cat "$fingerprint_file")" == "$(final_review_input_fingerprint)" ]]
}

remove_checkpoint_entry() {
  local entry="$1"
  [[ -f "$CHECKPOINT_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -vxF "$entry" "$CHECKPOINT_FILE" > "$tmp" || true
  mv "$tmp" "$CHECKPOINT_FILE"
}

combine_unit_lists() {
  printf '%s\n' "$@" |
    tr ',' '\n' |
    awk 'NF && !seen[$0]++ { print }' |
    paste -sd, -
}

tsv_escape() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

slugify_id() {
  local text="$1"
  text="$(printf '%s' "$text" | sed -E 's#^backend/##; s#^frontend/##; s#^docs/##; s#\.[A-Za-z0-9]+$##')"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##; s#-{2,}#-#g')"
  [[ -n "$text" ]] || text="scope"
  printf '%s\n' "$text" | cut -c1-48
}

append_scope_classification() {
  local unit_id="$1" decision="$2" reason="$3" owner="$4" files="$5" child_units="$6"
  if [[ ! -s "$SCOPE_CLASSIFICATION_TSV" ]]; then
    printf 'unit_id\tdecision\treason\towner\tfiles\tchild_units\n' > "$SCOPE_CLASSIFICATION_TSV"
  fi
  awk -F '\t' -v unit="$unit_id" -v decision="$decision" '
    NR > 1 && $1 == unit && $2 == decision { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$SCOPE_CLASSIFICATION_TSV" 2>/dev/null && return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(tsv_escape "$unit_id")" \
    "$(tsv_escape "$decision")" \
    "$(tsv_escape "$reason")" \
    "$(tsv_escape "$owner")" \
    "$(tsv_escape "$files")" \
    "$(tsv_escape "$child_units")" >> "$SCOPE_CLASSIFICATION_TSV"
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

pending_split_child_units() {
  local -a units=()
  local unit_id group model_class packets_csv
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    [[ "$unit_id" == *-S[0-9][0-9] ]] || continue
    local parent_unit="$unit_id"
    parent_unit="${parent_unit%-S[0-9][0-9]}"
    if ! unit_selected "$unit_id" && ! unit_selected "$parent_unit"; then
      continue
    fi
    verifier_accepts_unit "$unit_id" && continue
    local child_findings child_verifier
    child_findings="$(verifier_findings_tsv_for_unit "$unit_id")"
    child_verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    verifier_finding_type_exists "$child_findings" "contract_conflict" && continue
    verifier_finding_type_exists "$child_findings" "test_harness" && continue
    verifier_finding_type_exists "$child_findings" "blocked" && continue
    if file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(stop)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(blocked)' "$child_verifier"; then
      continue
    fi

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
  local unit_id group model_class packets_csv
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    if verifier_accepts_unit "$unit_id"; then
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
  local unit_id group model_class packets_csv
  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
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
    if verifier_accepts_unit "$unit_id"; then
      continue
    fi
    if unit_has_split_children "$unit_id" || unit_packets_marked_split_parent "$unit_id"; then
      printf '[auto-revise] %s decomposed into split child units; parent will not be revised directly\n' "$unit_id" >&2
      continue
    fi
    if verifier_has_only_launch_evidence_findings "$unit_id"; then
      continue
    fi
    if verifier_has_only_coordinator_or_evidence_findings "$unit_id"; then
      printf '[auto-revise] %s has only packet/process/evidence findings; leaving for coordinator cleanup\n' "$unit_id" >&2
      continue
    fi
    if file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(stop)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(blocked)' "$verifier"; then
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
    if file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(revise)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(revise)' "$verifier"; then
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

unit_has_split_children() {
  local unit_id="$1"
  [[ -s "$UNITS_TSV" ]] || return 1
  awk -F '\t' -v prefix="$unit_id-S" '
    FNR > 1 && index($1, prefix) == 1 {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$UNITS_TSV"
}

split_child_units_csv() {
  local unit_id="$1"
  [[ -s "$UNITS_TSV" ]] || return 0
  awk -F '\t' -v prefix="$unit_id-S" '
    FNR > 1 && index($1, prefix) == 1 {
      print $1
    }
  ' "$UNITS_TSV" | paste -sd, -
}

unit_split_children_pending() {
  local unit_id="$1"
  local child_id packets_csv _group _model _severity _rationale
  [[ -s "$UNITS_TSV" ]] || return 1
  while IFS=$'\t' read -r child_id packets_csv _group _model _severity _rationale; do
    [[ "$child_id" == "$unit_id"-S[0-9][0-9]* ]] || continue
    verifier_accepts_unit "$child_id" && continue
    verifier_finding_type_exists "$(verifier_findings_tsv_for_unit "$child_id")" "contract_conflict" && continue
    verifier_finding_type_exists "$(verifier_findings_tsv_for_unit "$child_id")" "test_harness" && continue
    verifier_finding_type_exists "$(verifier_findings_tsv_for_unit "$child_id")" "blocked" && continue
    if file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(stop)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(blocked)' \
      "$REMEDIATION_DIR/artifacts/verify-$child_id.md"; then
      continue
    fi
    if ! unit_packets_have_terminal_status "$packets_csv"; then
      return 0
    fi
  done < <(tail -n +2 "$UNITS_TSV")
  return 1
}

unit_packets_marked_split_parent() {
  local unit_id="$1" packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  [[ -n "$packets_csv" ]] || return 1
  local packet_id packet_file
  local IFS=,
  for packet_id in $packets_csv; do
    [[ -n "${packet_id:-}" ]] || continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    file_matches 'Status:[[:space:]]*`?split-into-child-units|split-into-child-units' "$packet_file" && return 0
  done
  return 1
}

unit_changed_files_text() {
  local unit_id="$1"
  local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  local packets_csv packet_id packet_file
  {
    if [[ -s "$summary" ]]; then
      awk '
        /^## Changed Files/ { in_section = 1; next }
        /^## / && in_section { in_section = 0 }
        in_section { print }
      ' "$summary"
    fi
    packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
    local IFS=,
    for packet_id in $packets_csv; do
      packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
      [[ -s "$packet_file" ]] || continue
      awk '
        /Files changed:/ || /Implemented .* in `/ || /Added .* in `/ || /Replaced .* in `/ || /Removed .* from `/ { print }
      ' "$packet_file"
    done
  } | tr '\n' ' '
}

finding_is_sibling_drift() {
  local unit_id="$1" finding_file="$2" finding_type="$3"
  [[ "$finding_type" == "test_harness" ]] || return 1
  [[ -n "$finding_file" ]] || return 1
  local changed_text
  changed_text="$(unit_changed_files_text "$unit_id")"
  [[ -n "$changed_text" ]] || return 0
  [[ "$changed_text" != *"$finding_file"* ]]
}

split_plan_marks_no_split() {
  local unit_id="$1"
  [[ -s "$SPLIT_PLAN_MD" ]] || return 1
  local unit_ref
  unit_ref="$(printf '`%s`' "$unit_id")"
  awk -v unit="$unit_ref" '
    index($0, unit) && tolower($0) ~ /(do not split|left unchanged|launch evidence|launch-evidence)/ {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$SPLIT_PLAN_MD"
}

verifier_has_only_launch_evidence_findings() {
  local unit_id="$1"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  verifier_accepts_unit "$unit_id" || return 1
  [[ -s "$findings" ]] || return 1
  awk -F '\t' '
    NR > 1 && $1 != "" {
      count += 1
      if ($3 != "launch_evidence" && $3 != "sandbox_blocked") {
        blocked = 1
      }
    }
    END { exit count > 0 && blocked != 1 ? 0 : 1 }
  ' "$findings"
}

verifier_has_only_coordinator_or_evidence_findings() {
  local unit_id="$1"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' '
    NR > 1 && $1 != "" {
      details = tolower($4 " " $6 " " $7)
      count += 1
      coordinator_blocked = 0
      if ($3 == "blocked" &&
          details ~ /\/packets\/px-[0-9]+\.md/ &&
          details ~ /(packet.*work.?log|orchestrator|canonical packet|status: not-started)/) {
        coordinator_blocked = 1
      }
      if (!coordinator_blocked &&
          $3 != "launch_evidence" &&
          $3 != "sandbox_blocked" &&
          $3 != "docs/process" &&
          $3 != "process" &&
          $3 != "packet_status" &&
          $3 != "packet-worklog" &&
          $3 != "packet_worklog") {
        code_work = 1
      }
    }
    END { exit count > 0 && code_work != 1 ? 0 : 1 }
  ' "$findings"
}

verifier_has_only_remediation_metadata_findings() {
  local unit_id="$1"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' -v rdir="$REMEDIATION_DIR" '
    NR > 1 && $1 != "" {
      count += 1
      type = $3
      file = $4
      details = tolower($4 " " $6 " " $7)
      if (type == "launch_evidence" || type == "sandbox_blocked") {
        next
      }
      remediation_file = 0
      if (index(file, rdir "/") == 1) {
        remediation_file = 1
      }
      if (file ~ /^docs\/audit\/[^/]+\/[^/]+\/(packets|artifacts|logs|prompts)\//) {
        remediation_file = 1
      }
      if (file ~ /\/docs\/audit\/[^/]+\/[^/]+\/(packets|artifacts|logs|prompts)\//) {
        remediation_file = 1
      }

      metadata_type = 0
      if (type == "docs/process" ||
          type == "process" ||
          type == "packet_status" ||
          type == "packet-worklog" ||
          type == "packet_worklog") {
        metadata_type = 1
      }
      if (type == "docs" && remediation_file) {
        metadata_type = 1
      }
      if (type == "blocked" &&
          details ~ /(packet.*work.?log|implementation summary|summary.*partial|status: not-started|status: partial)/) {
        metadata_type = 1
      }

      if (!metadata_type || (!remediation_file && type != "blocked")) {
        code_work = 1
      }
    }
    END { exit count > 0 && code_work != 1 ? 0 : 1 }
  ' "$findings"
}

unit_evidence_has_failed_status() {
  local unit_id="$1"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  [[ -d "$unit_dir" ]] || return 1
  if unit_summary_missing_proofs "$unit_id" >/dev/null; then
    return 0
  fi
  if unit_has_passing_summary_artifact "$unit_id"; then
    return 1
  fi
  local status_file command status
  declare -A latest_status_by_command=()
  while IFS= read -r status_file; do
    command="$(awk -F ': ' '/^COMMAND: / { print substr($0, index($0, $2)); exit }' "$status_file")"
    [[ -n "$command" ]] || command="$(awk -F ': ' '/^JOB: / { print "audit:" substr($0, index($0, $2)); exit }' "$status_file")"
    [[ -n "$command" ]] || command="$status_file"
    status="$(awk -F ': ' '/^STATUS: / { print $2; exit }' "$status_file")"
    latest_status_by_command["$command"]="$status"
  done < <(find "$unit_dir" -maxdepth 1 -name '*.status' -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{ $1 = ""; sub(/^ /, ""); print }')
  for status in "${latest_status_by_command[@]}"; do
    [[ "$status" == "fail" ]] && return 0
  done
  return 1
}

unit_has_passing_summary_artifact() {
  local unit_id="$1"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  [[ -d "$unit_dir" ]] || return 1
  local summary_json
  while IFS= read -r summary_json; do
    [[ -f "$summary_json" ]] || continue
    if python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(1)
status = str(payload.get("status", "")).strip().upper()
proof_files = payload.get("proof_files") or []
if status != "PASS" or not proof_files:
    raise SystemExit(1)
missing = []
for proof in proof_files:
    proof_path = pathlib.Path(str(proof))
    if not proof_path.is_absolute():
        proof_path = path.parent / proof_path
    if not proof_path.is_file():
        missing.append(str(proof))
raise SystemExit(1 if missing else 0)
PY
    then
      return 0
    fi
  done < <(find "$unit_dir" -mindepth 2 -maxdepth 3 -name 'summary.json' -print 2>/dev/null | sort)
  return 1
}

unit_summary_missing_proofs() {
  local unit_id="$1"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  [[ -d "$unit_dir" ]] || return 1
  local summary_json found=1
  while IFS= read -r summary_json; do
    [[ -f "$summary_json" ]] || continue
    if python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(1)
if str(payload.get("status", "")).strip().upper() != "PASS":
    raise SystemExit(1)
proof_files = payload.get("proof_files") or []
if not proof_files:
    raise SystemExit(1)
missing = []
for proof in proof_files:
    proof_path = pathlib.Path(str(proof))
    if not proof_path.is_absolute():
        proof_path = path.parent / proof_path
    if not proof_path.is_file():
        missing.append(str(proof))
if missing:
    print(f"{path}: missing proof files: {', '.join(missing)}")
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      found=0
    fi
  done < <(find "$unit_dir" -mindepth 2 -maxdepth 3 -name 'summary.json' -print 2>/dev/null | sort)
  return "$found"
}

unit_evidence_artifacts_newer_than_file() {
  local unit_id="$1" baseline="$2"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  [[ -d "$unit_dir" && -s "$baseline" ]] || return 1

  local evidence_file
  while IFS= read -r evidence_file; do
    [[ -n "$evidence_file" ]] || continue
    if [[ "$evidence_file" -nt "$baseline" ]]; then
      return 0
    fi
  done < <(find "$unit_dir" -type f \( -name '*.status' -o -name '*.log' -o -name 'summary.json' -o -name 'proof-summary.json' -o -name '*.har' -o -name '*.png' -o -name '*.json' \) -print 2>/dev/null)

  return 1
}

unit_packets_have_terminal_status() {
  local packets_csv="$1"
  local packet_id packet
  local IFS=,
  local checked=0
  for packet_id in $packets_csv; do
    [[ -n "${packet_id:-}" ]] || continue
    checked=1
    packet="$REMEDIATION_DIR/packets/$packet_id.md"
    packet_has_terminal_status "$packet" || return 1
  done
  [[ "$checked" == "1" ]]
}

split_candidate_has_durable_decision() {
  local unit_id="$1" packets_csv="$2"
  unit_has_split_children "$unit_id" && return 0
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  if [[ -s "$findings" ]] && \
     verifier_findings_exceed_auto_revise_limit "$findings" && \
     ! verifier_finding_type_blocks_auto_revise "$findings" && \
     ! verifier_has_only_launch_evidence_findings "$unit_id"; then
    return 1
  fi
  unit_packets_have_terminal_status "$packets_csv" && return 0
  verifier_has_only_launch_evidence_findings "$unit_id" && return 0
  split_plan_marks_no_split "$unit_id" && return 0
  return 1
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

trim_inline_value() {
  local value="$1"
  value="${value#\`}"
  value="${value%\`}"
  value="${value#\"}"
  value="${value%\"}"
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\n' "$value"
}

extract_profile_command() {
  local value="$1"
  local extracted
  if [[ "$value" == *'`'*'`'* ]]; then
    extracted="$(printf '%s\n' "$value" | sed -n 's/^[^`]*`\([^`]*\)`.*/\1/p')"
    if [[ -n "$extracted" ]]; then
      trim_inline_value "$extracted"
      return 0
    fi
  fi
  trim_inline_value "$value"
}

profile_runtime_values() {
  local key="$1"
  [[ -n "$PRODUCT_PROFILE" && -f "$PRODUCT_PROFILE" ]] || return 0
  awk -v key="$key" '
    BEGIN { in_section = 0; capture = 0 }
    /^## / {
      if (in_section && $0 !~ /^## Runtime Verification[[:space:]]*$/) exit
      in_section = ($0 ~ /^## Runtime Verification[[:space:]]*$/)
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

append_unique_line() {
  local value="$1"
  local array_name="$2"
  local -n target="$array_name"
  local existing
  [[ -n "$value" ]] || return 0
  for existing in "${target[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  target+=("$value")
}

normalize_profile_commands() {
  local key="$1"
  local raw cleaned lower
  while IFS= read -r raw; do
    cleaned="$(extract_profile_command "$raw")"
    [[ -n "$cleaned" ]] || continue
    lower="$(printf '%s' "$cleaned" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      tbd|n/a|none|none-configured|not-applicable|_pending_|pending) continue ;;
    esac
    printf '%s\n' "$cleaned"
  done < <(profile_runtime_values "$key")
}

command_is_forbidden() {
  local candidate="$1"
  local forbidden
  case "$candidate" in
    *"<"*">"*|*"\`"*|*"focused test file"*|*"focused test"*|*"placeholder"*|*" when "*|*" if "*)
      return 0
      ;;
  esac
  while IFS= read -r forbidden; do
    forbidden="$(extract_profile_command "$forbidden")"
    [[ -n "$forbidden" ]] || continue
    if [[ "$candidate" == "$forbidden" || "$candidate" == *"$forbidden"* || "$forbidden" == *"$candidate"* ]]; then
      return 0
    fi
  done < <(normalize_profile_commands "Commands that must not be run")
  return 1
}

shell_fragment_is_valid() {
  local fragment="$1"
  [[ -n "$fragment" ]] || return 1
  bash -n < <(printf '%s\n' "$fragment") >/dev/null 2>&1
}

command_looks_executable() {
  local command="$1"
  [[ -n "$command" ]] || return 1
  case "$command" in
    cd\ *\ \&\&\ *|\
    npm\ *|\
    npx\ *|\
    pytest*|\
    python\ *|\
    python3\ *|\
    bash\ *|\
    ./scripts/*|\
    make\ *|\
    cargo\ *|\
    go\ test*|\
    ruff\ *|\
    alembic\ *|\
    pip-audit*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

evidence_command_is_allowed() {
  local command="$1"
  [[ -n "$command" ]] || return 1
  command_is_forbidden "$command" && return 1
  command_looks_executable "$command" || return 1
  shell_fragment_is_valid "$command" || return 1
  case "$command" in
    "cd backend && python3 -m pytest "*|\
    "cd backend && python -m pytest "*|\
    "cd backend && pytest "*|\
    "cd frontend && npm run typecheck"|\
    "cd frontend && npm run build"|\
    "cd frontend && npm run lint"|\
    "cd frontend && npm run test"*|\
    "cd frontend && npm run test:e2e"*|\
    "cd frontend && npx playwright test "*|\
    "npx playwright test "*)
      return 0
      ;;
  esac

  local supported
  for supported in \
    "Supported backend test commands" \
    "Supported frontend test commands" \
    "Supported E2E/browser commands"; do
    while IFS= read -r profile_cmd; do
      profile_cmd="$(extract_profile_command "$profile_cmd")"
      [[ -n "$profile_cmd" ]] || continue
      [[ "$profile_cmd" == *"<"*">"* ]] && continue
      if [[ "$command" == "$profile_cmd" || "$command" == "$profile_cmd "* ]]; then
        return 0
      fi
    done < <(normalize_profile_commands "$supported")
  done

  return 1
}

extract_first_backtick_command() {
  local text="$1"
  printf '%s\n' "$text" | sed -n 's/^[^`]*`\([^`][^`]*\)`.*/\1/p' | head -1
}

evidence_command_for_finding() {
  local file="$1" finding="$2" required_fix="$3"
  local text command
  text="$file $finding $required_fix"
  command="$(extract_first_backtick_command "$required_fix")"

  if [[ "$text" == *"MERIDIAN_TEST_ALEMBIC_POSTGRES_URL"* && "$text" == *"test_migrations.py"* ]]; then
    printf 'cd backend && python3 -m pytest tests/test_migrations.py -m postgres -q -rs\n'
    return 0
  fi

  if [[ "$text" == *"program-create.spec.ts"* ]]; then
    printf 'cd frontend && npm run test:e2e -- program-create.spec.ts\n'
    return 0
  fi

  if [[ "$text" == *"npm run typecheck"* ]]; then
    printf 'cd frontend && npm run typecheck\n'
    return 0
  fi

  if [[ "$text" == *"auditor-portal.spec.ts"* && "$text" == *"access-review.spec.ts"* ]]; then
    printf 'cd frontend && npx playwright test --config e2e/playwright.config.ts e2e/auditor-portal.spec.ts e2e/access-review.spec.ts\n'
    return 0
  fi

  if [[ "$text" == *"auditor-portal.spec.ts"* ]]; then
    printf 'cd frontend && npx playwright test --config e2e/playwright.config.ts e2e/auditor-portal.spec.ts\n'
    return 0
  fi

  if [[ "$text" == *"access-review.spec.ts"* ]]; then
    printf 'cd frontend && npx playwright test --config e2e/playwright.config.ts e2e/access-review.spec.ts\n'
    return 0
  fi

  if [[ -n "$command" ]] && evidence_command_is_allowed "$command"; then
    printf '%s\n' "$command"
  fi
}

audit_job_for_evidence_finding() {
  local text="$1"
  case "$text" in
    *"15a-compliance-program-operator"*|*"compliance-program-operator"*|*"15a prompt"*|*"15a-"*) printf '15a-compliance-program-operator\n' ;;
    *"03a-connectors-ingestion"*|*"connectors-ingestion"*|*"03a prompt"*|*"03a-"*) printf '03a-connectors-ingestion\n' ;;
  esac
}

unit_packet_source_kinds() {
  local unit_id="$1"
  local packets_csv packet_id packet_file kind
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  [[ -n "$packets_csv" ]] || return 0
  local IFS=,
  for packet_id in $packets_csv; do
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    [[ -f "$packet_file" ]] || continue
    kind="$(sed -n 's/^- Source kind: `\(.*\)`$/\1/p' "$packet_file" | head -1)"
    [[ -n "$kind" ]] && printf '%s\n' "$kind"
  done | awk '!seen[$0]++'
}

preferred_verification_scopes_for_unit() {
  local unit_id="$1" group="$2"
  local -a scopes=()
  case "$group" in
    frontend-ux-tests) scopes+=(frontend e2e) ;;
    runtime-quality-gates) scopes+=(backend frontend e2e) ;;
    *) scopes+=(backend frontend e2e) ;;
  esac

  if unit_packet_source_kinds "$unit_id" | grep -qx 'maturity-customer-proof'; then
    scopes=(e2e "${scopes[@]}")
  elif unit_packet_source_kinds "$unit_id" | grep -qx 'runtime-verification'; then
    scopes=(backend frontend e2e "${scopes[@]}")
  fi

  printf '%s\n' "${scopes[@]}" | awk '!seen[$0]++'
}

fallback_verification_cmds() {
  local worktree="$1"
  if [[ -f "$worktree/Makefile" ]] && grep -q '^[[:space:]]*test:' "$worktree/Makefile"; then
    printf 'make test\n'
  fi
  if [[ -f "$worktree/package.json" ]] && grep -q '"test"' "$worktree/package.json"; then
    printf 'npm test\n'
  fi
  if [[ -f "$worktree/pytest.ini" || -f "$worktree/conftest.py" ]]; then
    printf 'pytest\n'
  fi
  if [[ -f "$worktree/Cargo.toml" ]]; then
    printf 'cargo test\n'
  fi
}

command_is_global_native_check() {
  local command="$1"
  case "$command" in
    "cd backend && ruff check ."|\
    "cd backend && ruff format --check ."|\
    "cd backend && bash scripts/check-standards.sh"|\
    "cd backend && pytest"|\
    "cd backend && pytest -m postgres"*|\
    "cd backend && python -m pytest"|\
    "cd backend && python -m pytest tests/ -v"|\
    "cd backend && python3 -m pytest"|\
    "cd backend && python3 -m pytest tests/ -v"|\
    "./scripts/backend-venv"|\
    "./scripts/dev-postgres bootstrap"|\
    "cd backend && alembic upgrade head"*|\
    "cd frontend && npm run build"|\
    "cd frontend && npm run lint"|\
    "cd frontend && npm run format:check"|\
    "cd frontend && npm run test"|\
    "cd frontend && npm run test:e2e"|\
    "cd frontend && npm run typecheck")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

native_global_checks_enabled() {
  [[ "${REMEDIATION_RUN_GLOBAL_NATIVE_CHECKS:-0}" == "1" ]]
}

command_is_path_reference() {
  local command="$1" worktree="$2"
  [[ "$command" == */* ]] || return 1
  [[ "$command" != *[[:space:]]* ]] || return 1
  [[ "$command" != ./* ]] || return 1
  [[ "$command" != /* ]] || return 1
  if [[ "$command" == *"*"* || "$command" == *"?"* || "$command" == *"["* ]]; then
    compgen -G "$worktree/$command" >/dev/null
    return $?
  fi
  return 0
}

collect_verification_cmds() {
  local unit_id="$1" group="$2" worktree="$3"
  local -a commands=()
  local scope key raw

  if [[ -n "${EXTERNAL_VERIFICATION_CMD:-}" ]]; then
    printf '%s\n' "$EXTERNAL_VERIFICATION_CMD"
    return 0
  fi

  while IFS= read -r scope; do
    [[ -n "$scope" ]] || continue
    case "$scope" in
      backend) key="Supported backend test commands" ;;
      frontend) key="Supported frontend test commands" ;;
      e2e) key="Supported E2E/browser commands" ;;
      *) continue ;;
    esac
    while IFS= read -r raw; do
      raw="$(extract_profile_command "$raw")"
      [[ -n "$raw" ]] || continue
      command_is_forbidden "$raw" && continue
      command_looks_executable "$raw" || continue
      command_is_path_reference "$raw" "$worktree" && continue
      if command_is_global_native_check "$raw" && ! native_global_checks_enabled; then
        continue
      fi
      append_unique_line "$raw" commands
    done < <(normalize_profile_commands "$key")
  done < <(preferred_verification_scopes_for_unit "$unit_id" "$group")

  if ((${#commands[@]} == 0)); then
    while IFS= read -r raw; do
      raw="$(extract_profile_command "$raw")"
      [[ -n "$raw" ]] || continue
      command_is_forbidden "$raw" && continue
      command_looks_executable "$raw" || continue
      command_is_path_reference "$raw" "$worktree" && continue
      append_unique_line "$raw" commands
    done < <(fallback_verification_cmds "$worktree")
  fi

  printf '%s\n' "${commands[@]}" | awk 'NF && !seen[$0]++ { print }'
}

native_test_results_block() {
  local unit_id="$1"
  local test_log="$REMEDIATION_DIR/artifacts/$unit_id-native-test.log"
  if [[ -f "$test_log" ]]; then
    cat "$test_log"
  else
    printf 'No native test output available.\n'
  fi
  local precheck_log="$REMEDIATION_DIR/artifacts/static-prechecks.log"
  if [[ -f "$precheck_log" ]]; then
    printf '\n## Harness Static Prechecks\n'
    cat "$precheck_log"
  fi
}

native_test_placeholder_text() {
  printf 'No supported verification commands were configured in the product profile or detected from repo defaults.\n'
}

native_test_log_is_placeholder() {
  local test_log="$1"
  [[ -s "$test_log" ]] || return 1
  [[ "$(cat "$test_log")" == "$(native_test_placeholder_text)" ]]
}

pytest_rerunfailures_socket_blocked() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 1
  grep -qiE 'pytest_rerunfailures|rerunfailures' "$log_file" || return 1
  grep -qiE 'PermissionError: \[Errno 1\] Operation not permitted|socket|forbidden socket|Operation not permitted' "$log_file"
}

pytest_without_rerunfailures_cmd() {
  local cmd="$1"
  [[ "$cmd" == *pytest* ]] || return 1
  [[ "$cmd" != *"-p no:rerunfailures"* ]] || return 1
  python3 - "$cmd" <<'PY'
import re
import sys

cmd = sys.argv[1]
if re.search(r'(^|[;&|()\s])python3?\s+-m\s+pytest(\s|$)', cmd):
    print(re.sub(r'python3?[ \t]+-m[ \t]+pytest', lambda m: m.group(0) + ' -p no:rerunfailures', cmd, count=1))
elif re.search(r'(^|[;&|()\s])pytest(\s|$)', cmd):
    print(re.sub(r'(^|[;&|() \t])pytest([ \t]|$)', lambda m: m.group(1) + 'pytest -p no:rerunfailures' + m.group(2), cmd, count=1))
else:
    sys.exit(1)
PY
}

run_static_prechecks() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ "$REMEDIATION_STATIC_PRECHECKS" == "1" ]] || return 0
  mkdir -p "$REMEDIATION_DIR/artifacts"
  local log="$REMEDIATION_DIR/artifacts/static-prechecks.log"
  : > "$log"
  printf '[static-precheck] repo=%s\n' "$REPO_ROOT" >> "$log"

  local profile_dir=""
  if [[ -n "$PROFILE" && -d "$PROFILE" ]]; then
    profile_dir="$PROFILE"
  elif [[ -n "$PROFILE" && -d "$PROFILES_DIR/$PROFILE" ]]; then
    profile_dir="$PROFILES_DIR/$PROFILE"
  fi
  if [[ -n "$profile_dir" && -x "$profile_dir/prechecks.sh" ]]; then
    printf '[static-precheck] running profile hook: %s\n' "$profile_dir/prechecks.sh" >> "$log"
    if (cd "$REPO_ROOT" && "$profile_dir/prechecks.sh") >> "$log" 2>&1; then
      printf '[static-precheck] profile hook passed\n' >> "$log"
    else
      printf '[static-precheck] profile hook reported findings\n' >> "$log"
    fi
  fi

  if [[ -d "$REPO_ROOT/frontend/src" ]]; then
    printf '[static-precheck] frontend inline-English JSX scan\n' >> "$log"
    local inline_hits
    inline_hits="$(
      grep -RInE '>[[:space:]]*[A-Z][A-Za-z0-9 ,;:!?'\''"()/-]{3,}[[:space:]]*<' "$REPO_ROOT/frontend/src" \
        --include='*.tsx' --include='*.jsx' 2>/dev/null \
        | grep -Ev 'node_modules|__snapshots__|\.test\.|\.spec\.|aria-hidden|data-testid' \
        | head -50 || true
    )"
    if [[ -n "$inline_hits" ]]; then
      printf '%s\n' "$inline_hits" >> "$log"
    else
      printf '[static-precheck] no obvious inline-English JSX literals found\n' >> "$log"
    fi
  fi
}

source_kind() {
  local source="$1"
  case "$source" in
    */docs/scorecard/*.md|*/docs/scorecards/*.md|docs/scorecard/*.md|docs/scorecards/*.md) printf 'scorecard\n' ;;
    */artifacts/stale-code-candidates.tsv|artifacts/stale-code-candidates.tsv) printf 'stale-code\n' ;;
    */01-domain/*) printf 'domain\n' ;;
    */02-cross-cutting/*) printf 'cross-cutting\n' ;;
    */03-spec-additions/*) printf 'spec-addition\n' ;;
    */10-runtime-verification.md|*/artifacts/14*/*|*/logs/14*) printf 'runtime-verification\n' ;;
    */11-maturity-stage-simulation.md|*/12-customer-playbook.md|*/artifacts/15*/*|*/logs/15*) printf 'maturity-customer-proof\n' ;;
    */13-adversarial-review.md|*/14-final-release-decision.md|*/logs/16*) printf 'adversarial-final-decision\n' ;;
    */artifacts/00-bootstrap/spec-inventory.txt|*/artifacts/00-bootstrap/master-prompt-excerpts.txt) printf 'spec-addition\n' ;;
    # Dynamic deep-dive outputs land in 01-domain/ and are already covered above.
    # Runtime scan artifacts: SAST, Lighthouse, accessibility, external-services, load-test.
    */artifacts/*/sast/*|*/artifacts/*/lighthouse/*|*/artifacts/*/accessibility/*|*/artifacts/*/external-services/*|*/artifacts/load-test/*) printf 'runtime-verification\n' ;;
    *) printf 'synthesis\n' ;;
  esac
}

audit_source_files() {
  {
    if [[ -n "$SCORECARD" ]]; then
      printf '%s\n' "$SCORECARD"
      if [[ "$SCORECARD_ONLY_SOURCE" == "1" ]]; then
        return 0
      fi
    fi
    find "$AUDIT_RUN" -maxdepth 1 -type f -name '*.md'
    find "$AUDIT_RUN/01-domain" "$AUDIT_RUN/02-cross-cutting" "$AUDIT_RUN/03-spec-additions" -type f -name '*.md' 2>/dev/null || true
    find "$AUDIT_RUN/artifacts/00-bootstrap" -maxdepth 1 -type f \( -name 'spec-inventory.txt' -o -name 'master-prompt-excerpts.txt' \) 2>/dev/null || true
    find "$AUDIT_RUN/logs" -maxdepth 1 -type f \( -name '14*.log' -o -name '15*.log' -o -name '16*.log' \) 2>/dev/null || true
    find "$AUDIT_RUN/logs" -maxdepth 1 -type f -name '16c-adversarial-product.log' 2>/dev/null || true
    # Runtime artifact reports: SAST, Lighthouse, accessibility, external-services, load-test
    find "$AUDIT_RUN/artifacts" -mindepth 2 -type f -name '*.md' 2>/dev/null || true
    find "$AUDIT_RUN/artifacts" -maxdepth 1 -type f -name 'stale-code-candidates.tsv' 2>/dev/null || true
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
    *scorecard*security*|*scorecard*s-*|*critical*tenant*|*critical*auth*) printf 'security-auth\n' ;;
    *scorecard*ux*|*scorecard*frontend*|*scorecard*browser*|*acceptance*|*forced\ intervention*) printf 'frontend-ux-tests\n' ;;
    *scorecard*performance*|*scorecard*runtime*|*scorecard*quality*) printf 'runtime-quality-gates\n' ;;
    *spec-inventory*|*master-prompt-excerpts*|*spec*addition*|*must\ implement*|*contract\ gap*) printf 'spec-contract-gaps\n' ;;
    *runtime-backend*|*runtime-frontend*|*runtime-protocol*|*quality*|*ruff*|*postgres*|*migration-table*|*smoke*) printf 'runtime-quality-gates\n' ;;
    # SAST/CVE findings → security-auth (highest-risk workstream for vulnerability findings)
    *bandit*|*semgrep*|*pip-audit*|*npm\ audit*|*cve-*|*cvss*|*sql\ injection*|*command\ injection*|*xss*|*sast*|*dependency\ vulnerability*|*supply\ chain*) printf 'security-auth\n' ;;
    # Accessibility violations → frontend-ux-tests
    *wcag*|*axe-core*|*axe\ violation*|*accessibility\ violation*|*aria-*|*color\ contrast*|*screen\ reader*) printf 'frontend-ux-tests\n' ;;
    # Lighthouse / Core Web Vitals performance findings → runtime-quality-gates
    *lighthouse*|*core\ web\ vitals*|*lcp\ *|*cls\ *|*inp\ *|*ttfb\ *|*performance\ score*|*cumulative\ layout\ shift*|*largest\ contentful\ paint*) printf 'runtime-quality-gates\n' ;;
    # External services connectivity failures -> product-integrations
    *external\ service*|*external-service*|*oauth\ provider*|*smtp*|*saas\ api*|*webhook\ probe*|*cloud\ sdk*) printf 'product-integrations\n' ;;
    # Load test failures -> runtime-quality-gates
    *load\ test*|*load-test*|*p95\ *|*p99\ *|*error\ rate*|*baseline\ scenario*|*ramp\ scenario*|*spike\ scenario*|*k6*|*locust*|*artillery*) printf 'runtime-quality-gates\n' ;;
    *stale-code-candidates*|*stale\ code*|*superseded*|*safe-delete*|*staged-removal*|*merge-with-current-path*|*dead\ code*|*stub*|*placeholder*|*deprecated*|*legacy*) printf 'tech-debt-cleanup\n' ;;
    *csrf*|*tenant-isolation*|*support-access*|*mfa-pending*|*rbac*|*auth-boundar*|*data-protection*|*guest-invite*|*guest-access*|*public*invite*|*tenants*|*roles-permissions*) printf 'security-auth\n' ;;
    *scim*|*lifecycle*|*provisioning*|*joiner*|*mover*|*leaver*) printf 'scim-lifecycle\n' ;;
    *saml*|*oidc*|*oauth*|*federation*|*jwks*|*authnrequest*|*replay*|*signing-key*) printf 'protocol-federation\n' ;;
    *frontend*|*ux*|*navigation*|*i18n*|*manual*|*playwright*|*test-coverage*|*selector*) printf 'frontend-ux-tests\n' ;;
    iga|iga-*|*-iga|*-iga-*|*\ iga\ *|*\ iga-*|*-iga\ *|*governance*|*access-review*|*reviewer*|*request*approval*|*approver*) printf 'iga-governance\n' ;;
    *migration*|*webhook*|*product*|*entitlement*|*billing*|*market*|*replacement*) printf 'product-integrations\n' ;;
    *audit*|*soc*|*iso*|*gdpr*|*retention*|*evidence*|*compliance*) printf 'audit-compliance\n' ;;
    *) printf 'core-platform\n' ;;
  esac
}

model_class_for_group() {
  case "$1" in
    security-auth|scim-lifecycle|protocol-federation|iga-governance|runtime-quality-gates|spec-contract-gaps) printf 'high-risk\n' ;;
    tech-debt-cleanup) printf 'complex\n' ;;
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

write_lattice_mcp_config() {
  local dest="$1" workspace="${2:-$REPO_ROOT}"
  local command="${LATTICE_MCP_COMMAND:-/home/pete/cadres/lattice/daemon/target/release/lattice}"
  if [[ -n "${MCP_CONFIG:-}" && -f "${MCP_CONFIG:-}" ]]; then
    cp "$MCP_CONFIG" "$dest"
    return
  fi
  if [[ -n "${CLAUDE_MCP_CONFIG:-}" && -f "${CLAUDE_MCP_CONFIG:-}" ]]; then
    cp "$CLAUDE_MCP_CONFIG" "$dest"
    return
  fi
  if [[ "${LATTICE_MCP_AUTO:-1}" != "1" ]]; then
    if [[ -f "$workspace/.mcp.json" ]]; then
      cp "$workspace/.mcp.json" "$dest"
    elif [[ -f "$REPO_ROOT/.mcp.json" ]]; then
      cp "$REPO_ROOT/.mcp.json" "$dest"
    elif [[ -f "$workspace/.gemini/settings.json" ]]; then
      cp "$workspace/.gemini/settings.json" "$dest"
    elif [[ -f "$REPO_ROOT/.gemini/settings.json" ]]; then
      cp "$REPO_ROOT/.gemini/settings.json" "$dest"
    else
      printf '{"mcpServers":{}}\n' > "$dest"
    fi
    return
  fi
  python3 - "$dest" "$workspace" "$command" <<'PY'
import json
import os
import sys
from pathlib import Path

dest = Path(sys.argv[1])
workspace = sys.argv[2]
command = sys.argv[3]
config = {"mcpServers": {}}
for candidate in (
    Path(workspace) / ".mcp.json",
    Path(workspace) / ".gemini" / "settings.json",
    Path.cwd() / ".mcp.json",
):
    if candidate.exists():
        try:
            loaded = json.loads(candidate.read_text())
            if isinstance(loaded, dict):
                config = loaded
                break
        except json.JSONDecodeError:
            pass
servers = config.setdefault("mcpServers", {})
focus_files = []
for value in os.environ.get("LATTICE_MCP_FOCUS_FILES", "").replace(",", "\n").splitlines():
    value = value.strip()
    if value and value not in focus_files:
        focus_files.append(value)
focus_dirs = []
for value in os.environ.get("LATTICE_MCP_FOCUS_DIRS", "").replace(",", "\n").splitlines():
    value = value.strip()
    if value and value not in focus_dirs:
        focus_dirs.append(value)
args = ["--stdio", "--workspace", workspace]
for value in focus_files:
    args.extend(["--focus-file", value])
for value in focus_dirs:
    args.extend(["--focus-dir", value])
servers["lattice"] = {
    "type": "stdio",
    "command": command,
    "args": args,
}
dest.write_text(json.dumps(config, indent=2) + "\n")
PY
}

lattice_codex_args_json() {
  local workspace="${1:-$REPO_ROOT}"
  python3 - "$workspace" <<'PY'
import json
import os
import sys

workspace = sys.argv[1]
def parse_env(name):
    values = []
    for value in os.environ.get(name, "").replace(",", "\n").splitlines():
        value = value.strip()
        if value and value not in values:
            values.append(value)
    return values

args = ["--stdio", "--workspace", workspace]
for value in parse_env("LATTICE_MCP_FOCUS_FILES"):
    args.extend(["--focus-file", value])
for value in parse_env("LATTICE_MCP_FOCUS_DIRS"):
    args.extend(["--focus-dir", value])
print(json.dumps(args))
PY
}

# Called via run_command_with_heartbeat so stdout/stderr are already redirected to the log.
# claude has no -C flag; subshell into the worktree so its tools resolve paths correctly.
_exec_claude() {
  local prompt_file="$1" class="$2" worktree_dir="${3:-$REPO_ROOT}"
  local transport="${CLAUDE_TRANSPORT:-prompt}"
  local cmd=(claude)
  if [[ "$transport" == "prompt" ]]; then
    cmd+=(-p --verbose --output-format stream-json --no-session-persistence)
  fi
  cmd+=(--dangerously-skip-permissions)
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
  write_lattice_mcp_config "$mcp_cfg" "$REPO_ROOT"
  cmd+=(--strict-mcp-config --mcp-config "$mcp_cfg")

  if [[ "$transport" == "pty" ]]; then
    (
      cd "$worktree_dir"
      CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS="${CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS:-20}" \
      CLAUDE_PTY_STARTUP_SECONDS="${CLAUDE_PTY_STARTUP_SECONDS:-3}" \
      python3 -u - "$prompt_file" "${cmd[@]}" <<'PY'
import os
import re
import shlex
import sys
import time

try:
    import pexpect
except Exception as exc:
    sys.stderr.write(f"[claude-pty] pexpect is required for CLAUDE_TRANSPORT=pty: {exc}\n")
    raise SystemExit(2)

prompt_file = sys.argv[1]
cmd = sys.argv[2:]
prompt = open(prompt_file, encoding="utf-8").read()
startup_seconds = float(os.environ.get("CLAUDE_PTY_STARTUP_SECONDS", "3"))
idle_after_result = float(os.environ.get("CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS", "20"))
result_re = re.compile(r"RESULT:\s*(PASS|FAIL|INCOMPLETE|BLOCKED)", re.I)
error_re = re.compile(r"(login required|not authenticated|rate limit|permission denied|error:)", re.I)

sys.stdout.write("[claude-pty] spawning: " + " ".join(shlex.quote(part) for part in cmd) + "\n")
sys.stdout.flush()
child = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=1, echo=False, dimensions=(40, 160))
last_output = time.monotonic()
result_seen = False
output_tail = ""

end_startup = time.monotonic() + startup_seconds
while time.monotonic() < end_startup:
    try:
        chunk = child.read_nonblocking(size=4096, timeout=0.25)
    except pexpect.TIMEOUT:
        continue
    except pexpect.EOF:
        sys.stdout.write("\n[claude-pty] claude exited before prompt was sent\n")
        sys.stdout.flush()
        raise SystemExit(child.exitstatus if child.exitstatus is not None else 1)
    if chunk:
        sys.stdout.write(chunk)
        sys.stdout.flush()
        last_output = time.monotonic()
        output_tail = (output_tail + chunk)[-8000:]

child.send("\x1b[200~" + prompt + "\x1b[201~")
child.send("\r")
sys.stdout.write("\n[claude-pty] prompt pasted; monitoring terminal output\n")
sys.stdout.flush()

while True:
    try:
        chunk = child.read_nonblocking(size=4096, timeout=1)
    except pexpect.TIMEOUT:
        now = time.monotonic()
        if result_seen and now - last_output >= idle_after_result:
            sys.stdout.write(f"\n[claude-pty] RESULT observed and terminal idle for {idle_after_result:.0f}s; exiting session\n")
            sys.stdout.flush()
            child.sendcontrol("c")
            time.sleep(0.5)
            child.sendline("/exit")
            try:
                child.expect(pexpect.EOF, timeout=5)
            except Exception:
                child.terminate(force=True)
            raise SystemExit(0)
        continue
    except pexpect.EOF:
        sys.stdout.write("\n[claude-pty] claude exited\n")
        sys.stdout.flush()
        raise SystemExit(child.exitstatus if child.exitstatus is not None else 0)

    if not chunk:
        continue
    sys.stdout.write(chunk)
    sys.stdout.flush()
    last_output = time.monotonic()
    output_tail = (output_tail + chunk)[-8000:]
    if result_re.search(output_tail):
        result_seen = True
    if error_re.search(output_tail) and not result_seen:
        pass
PY
      local s="$?"
      rm -f "$mcp_cfg"
      return "$s"
    )
    return "$?"
  fi

  if [[ "$transport" != "prompt" ]]; then
    printf 'Unknown CLAUDE_TRANSPORT=%s; expected prompt or pty\n' "$transport" >&2
    rm -f "$mcp_cfg"
    return 2
  fi

  (
    cd "$worktree_dir"
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
  local prompt_file="$1" class="$2" worktree_dir="${3:-$REPO_ROOT}"
  local cmd=(gemini --yolo)
  local model
  model="$(select_gemini_model "$class")"
  [[ -n "$model" ]] && cmd+=(-m "$model")
  if [[ -n "${GEMINI_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=($GEMINI_EXTRA_ARGS)
    cmd+=("${extra_args[@]}")
  fi
  (cd "$worktree_dir" && "${cmd[@]}" -p "$(cat "$prompt_file")")
}

_exec_codex() {
  local prompt_file="$1" class="$2" worktree_dir="${3:-$REPO_ROOT}"
  local cmd=(codex exec --ephemeral --full-auto --skip-git-repo-check -C "$worktree_dir")
  if [[ "${REMEDIATION_CODEX_IGNORE_USER_CONFIG:-1}" == "1" ]]; then
    cmd+=(--ignore-user-config)
  fi
  local model reasoning
  model="$(select_model "$class")"
  reasoning="$(select_reasoning "$class")"
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ -n "$reasoning" ]] && cmd+=(-c "model_reasoning_effort=\"$reasoning\"")
  if [[ "${LATTICE_MCP_AUTO:-1}" == "1" ]]; then
    local lattice_cmd="${LATTICE_MCP_COMMAND:-/home/pete/cadres/lattice/daemon/target/release/lattice}"
    cmd+=(-c "mcp_servers.lattice.command=\"$lattice_cmd\"")
    cmd+=(-c "mcp_servers.lattice.args=$(lattice_codex_args_json "$REPO_ROOT")")
    cmd+=(-c "mcp_servers.lattice.cwd=\"$REPO_ROOT\"")
  fi
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
    if [[ "$rel" == */artifacts/stale-code-candidates.tsv || "$rel" == artifacts/stale-code-candidates.tsv ]]; then
      awk -F '\t' -v file="$rel" '
        NR == 1 { next }
        NF < 8 { next }
        function clean(s) {
          gsub(/\t/, " ", s)
          gsub(/\r/, "", s)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
          return s
        }
        {
          sev = clean($2)
          classification = clean($3)
          stale = clean($4)
          replacement = clean($5)
          evidence = clean($6)
          required = clean($7)
          tests = clean($8)
          if (sev == "" || stale == "" || required == "") next
          title = "Stale-code cleanup [" classification "]: " stale
          if (replacement != "" && replacement != "_none_" && replacement != "none") {
            title = title " superseded by " replacement
          }
          title = title " — " required
          if (tests != "") {
            title = title " Tests after removal: " tests
          }
          if (evidence != "") {
            title = title " Evidence: " evidence
          }
          print sev "\t" file "\t" NR "\t" title
        }
      ' "$file" >> "$tmp"
      continue
    fi
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
        if (tolower(title) ~ /^(i did not identify|no additional|other p[0-9]|additional p[0-9]|not repeated here|impact: this is not a direct launch blocker)/) return
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

dedupe_findings_into_blocker_ledger() {
  [[ -s "$PX_TSV" ]] || return 0

  cp "$PX_TSV" "$RAW_PX_TSV"

  local tmp_ledger tmp_px
  tmp_ledger="$(mktemp)"
  tmp_px="$(mktemp)"

  awk -F '\t' -v OFS='\t' -v ledger="$tmp_ledger" '
    function trim(s) {
      gsub(/\r/, "", s)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function lower(s) {
      return tolower(s)
    }
    function sev_rank(sev) {
      sev = toupper(sev)
      if (sev ~ /P0/) return 0
      if (sev ~ /P1/) return 1
      if (sev ~ /P2/) return 2
      if (sev ~ /P3/) return 3
      return 9
    }
    function choose_sev(old, new) {
      if (old == "") return new
      if (sev_rank(new) < sev_rank(old)) return new
      return old
    }
    function compact_key(s) {
      s = lower(s)
      gsub(/`[^`]+`/, " ", s)
      gsub(/[^a-z0-9]+/, " ", s)
      gsub(/\<p[0-9]\>/, " ", s)
      gsub(/\<(the|and|or|a|an|to|of|for|in|on|with|still|current|repo|supported|launch|readiness|workflow|route|routes|docs|doc|proof|evidence|missing|gap|gaps|contract|operator|browser|runtime|tests|test)\>/, " ", s)
      gsub(/[[:space:]]+/, " ", s)
      s = trim(s)
      if (length(s) > 96) s = substr(s, 1, 96)
      return s
    }
    function category(source, title, hay) {
      if (hay ~ /(previous|prior|old|stale).*(no[ -]?launch|final decision|baseline)|no[ -]?launch.*(carried|baseline|prior)/) return "stale_prior_decision"
      if (hay ~ /(runner unavailable|subprocess.*timed out|tool timed out|timeout|traceback|syntax error|command not found|unexpected eof)/) return "runtime_unavailable"
      if (hay ~ /(harness|skippable|skip-based|can report success|missing.*artifact|no native.*artifact|no reliable.*evidence|discovery-only|synthesis job|no tests or servers were run|no tests, servers|browser evidence.*absent|unverified)/) return "harness_gap"
      if (hay ~ /(browser proof|browser evidence|playwright|lighthouse|axe|e2e|authenticated browser|live proof|runtime proof|postgres.*proof|rls.*proof)/) return "evidence_gap"
      return "product_gap"
    }
    function theme(source, title, hay, key) {
      if (hay ~ /(msp.*benchmark|benchmark.*msp|tuple-scoped|tuple scoped).*client/) return "msp_benchmark_tuple_scope"
      if (hay ~ /(msp.*raw get_db|raw get_db.*msp|msp.*route.*rls|route-layer.*rls|route layer.*rls|postgresql.*msp.*proof)/) return "msp_route_rls_proof"
      if (hay ~ /(connector.*scheduler.*launch|scheduler.*connector.*launch|scheduled connector.*launch|scheduled connector.*bypass|connector automation.*bypass|launch_supported|launch-supported.*connector|unsupported connector.*schedul)/) return "connector_launch_supported_scheduler"
      if (hay ~ /(redis.*abuse|abuse controls.*redis|abuse controls.*process-local|abuse controls.*process local|brute-force.*process-local|brute force.*process local|public-surface throttles.*process|auth.*throttles.*process)/) return "production_abuse_controls_redis_required"
      if (hay ~ /(functional rls ssot|rls ssot.*stale|rls.*ssot.*misstates|row-level security.*ssot)/) return "rls_ssot_stale"
      if (hay ~ /(terminated.*msp.*tuple|terminated relationships.*tuple|re-engag.*former client.*access|re engagement.*old client access|tuple grants.*re engagement)/) return "msp_tuple_grant_revocation"
      if (hay ~ /(browser evidence|browser proof|skippable|skip-based|no native.*browser|no native.*ux|playwright|lighthouse|axe|launch claim 6)/) return "browser_evidence_missing_or_skippable"
      if (hay ~ /(prior|previous|old|stale).*(no[ -]?launch|final decision|baseline)|no[ -]?launch.*(carried|baseline|prior)/) return "stale_prior_launch_decision"
      if (hay ~ /(cookie-backed|cookie backed|auth audit|marketplace projection|auth session|auth refresh|stale projection)/) return "cookie_auth_session_contract"
      if (hay ~ /(published role|role catalog|user directory|tenant user|rbac.*permission|permission.*rbac)/) return "rbac_role_user_contract"
      if (hay ~ /(vendor questionnaire|questionnaire token|operator message|public questionnaire|resend|remind)/) return "vendor_questionnaire_public_link"
      if (hay ~ /(audit pdf|reporting.*pdf|scheduled report|report builder|native pdf|pdf generation)/) return "reporting_pdf_scheduler"
      if (hay ~ /(evidence package|presigned|pre-async|async.*package|storage.*download|share-token|share token)/) return "evidence_package_contract"
      if (hay ~ /(program.*forbidden field|program.*status|program.*framework|kpi.*trend|dashboard.*trend)/) return "program_dashboard_contract"
      if (hay ~ /(framework builder|control mapping|bulk mapping|oscal|framework maintenance|post-publish)/) return "control_framework_mapping_contract"
      if (hay ~ /(sox|icfr|roll-forward|roll forward)/) return "sox_icfr_contract"
      if (hay ~ /(platform-admin|platform admin|licensing|break-glass|break glass)/) return "platform_admin_licensing_contract"
      if (hay ~ /(i18n|keyboard|clickable row|mouse-only|accessibility|literal-copy|copy discipline)/) return "frontend_accessibility_i18n_contract"
      if (hay ~ /(rmm|cadres rmm|cloud.*saas|saas.*rmm)/) return "rmm_connector_launch_scope"
      key = compact_key(title)
      if (key == "") key = compact_key(source)
      return "finding_" key
    }
    NR == 1 { next }
    $1 == "" { next }
    {
      raw_id = $1
      sev = trim($2)
      group = trim($3)
      model = trim($4)
      source = trim($5)
      line = trim($6)
      title = trim($7)
      hay = lower(source " " title)
      cat = category(source, title, hay)
      th = theme(source, title, hay)
      root_key = cat "|" th

      if (!(root_key in seen)) {
        order[++order_count] = root_key
        seen[root_key] = 1
        first_id[root_key] = raw_id
        best_sev[root_key] = sev
        out_group[root_key] = group
        out_model[root_key] = model
        first_source[root_key] = source
        first_line[root_key] = line
        first_title[root_key] = title
      } else {
        best_sev[root_key] = choose_sev(best_sev[root_key], sev)
        if (out_model[root_key] != "high-risk" && model == "high-risk") out_model[root_key] = model
        if (out_group[root_key] == "core-platform" && group != "") out_group[root_key] = group
      }

      count[root_key] += 1
      ref = raw_id ":" source ":" line
      if (refs[root_key] == "") refs[root_key] = ref
      else refs[root_key] = refs[root_key] "," ref
      if (raw_ids[root_key] == "") raw_ids[root_key] = raw_id
      else raw_ids[root_key] = raw_ids[root_key] "," raw_id
    }
    END {
      print "blocker_id", "category", "theme", "severity", "group", "model_class", "finding_count", "representative_source", "representative_line", "representative_title", "raw_px_ids", "references" > ledger
      print "id", "severity", "group", "model_class", "source", "line", "title", "packet"
      for (i = 1; i <= order_count; i += 1) {
        key = order[i]
        blocker_id = sprintf("B-%04d", i)
        split(key, parts, /\|/)
        packet_id = sprintf("PX-%04d", i)
        title = "[" blocker_id " " parts[1] " " parts[2] "] " first_title[key]
        if (count[key] > 1) title = title " (deduped " count[key] " audit references)"
        print blocker_id, parts[1], parts[2], best_sev[key], out_group[key], out_model[key], count[key], first_source[key], first_line[key], first_title[key], raw_ids[key], refs[key] > ledger
        print packet_id, best_sev[key], out_group[key], out_model[key], first_source[key], first_line[key], title, "packets/" packet_id ".md"
      }
    }
  ' "$PX_TSV" > "$tmp_px"

  mv "$tmp_px" "$PX_TSV"
  mv "$tmp_ledger" "$BLOCKER_LEDGER_TSV"
  write_blocker_ledger_markdown
  printf '[blocker-ledger] raw_findings=%s blockers=%s ledger=%s\n' \
    "$(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$RAW_PX_TSV")" \
    "$(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$BLOCKER_LEDGER_TSV")" \
    "$BLOCKER_LEDGER_TSV"
}

write_blocker_ledger_markdown() {
  [[ -s "$BLOCKER_LEDGER_TSV" ]] || return 0
  {
    printf '# Remediation Blocker Ledger\n\n'
    printf -- '- Audit run: `%s`\n' "$AUDIT_RUN"
    printf -- '- Generated: `%s`\n' "$(date -Iseconds)"
    printf -- '- Raw finding inventory: `%s`\n' "$RAW_PX_TSV"
    printf -- '- Canonical blocker inventory: `%s`\n\n' "$BLOCKER_LEDGER_TSV"
    printf 'This ledger collapses repeated domain, synthesis, runtime, adversarial, and final-decision mentions into deterministic root-cause blockers. Repeated mentions stay in `references`; they should not become separate implementation units unless the verifier later proves they are different defects.\n\n'
    printf '| Blocker | Category | Theme | Severity | Group | Findings | Representative finding |\n'
    printf '| --- | --- | --- | --- | --- | ---: | --- |\n'
    tail -n +2 "$BLOCKER_LEDGER_TSV" | while IFS=$'\t' read -r blocker_id category theme severity group _model finding_count source line title _raw _refs; do
      printf '| `%s` | `%s` | `%s` | `%s` | `%s` | %s | `%s:%s` %s |\n' \
        "$blocker_id" "$category" "$theme" "$severity" "$group" "$finding_count" "$source" "$line" "$title"
    done
  } > "$BLOCKER_LEDGER_MD"
}

blocker_ledger_context_for_px() {
  local px_id="$1"
  [[ -s "$BLOCKER_LEDGER_TSV" ]] || return 0
  local blocker_id
  blocker_id="$(awk -v px="$px_id" 'BEGIN { n = px; sub(/^PX-0*/, "", n); if (n == "") n = 0; printf "B-%04d", n + 0 }')"
  awk -F '\t' -v blocker="$blocker_id" '
    NR > 1 && $1 == blocker {
      print "- Blocker: `" $1 "`"
      print "- Category: `" $2 "`"
      print "- Theme: `" $3 "`"
      print "- Deduped finding count: `" $7 "`"
      print "- Raw Px IDs: `" $11 "`"
      print "- References: `" $12 "`"
    }
  ' "$BLOCKER_LEDGER_TSV"
}

write_master_markdown() {
  {
    printf '# Master Px Remediation List\n\n'
    printf -- '- Audit run: `%s`\n' "$AUDIT_RUN"
    printf -- '- Generated: `%s`\n' "$(date -Iseconds)"
    printf -- '- Source inventory: `%s`\n\n' "$PX_TSV"
    if [[ -s "$BLOCKER_LEDGER_TSV" ]]; then
      printf -- '- Blocker ledger: `%s`\n' "$BLOCKER_LEDGER_TSV"
      printf -- '- Raw finding inventory: `%s`\n\n' "$RAW_PX_TSV"
    fi
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
    local blocker_context
    blocker_context="$(blocker_ledger_context_for_px "$id")"
    if [[ -n "$blocker_context" ]]; then
      printf '## Blocker Ledger Context\n\n'
      printf '%s\n\n' "$blocker_context"
      printf 'Use the blocker as the remediation boundary. Fix the root cause once, then verify the referenced audit jobs as evidence; do not implement separate fixes for repeated synthesis mentions unless current code proves they are distinct defects.\n\n'
    fi
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
    printf '2. Record the root cause before editing: symptom, real cause, correct fix layer, affected contracts, required tests, and required docs.\n'
    printf '3. Fix the defect at the correct backend, frontend, protocol, data, or workflow layer.\n'
    printf '4. Add or update tests that prove success and failure behavior, including authorization, isolation, trust-boundary, integration, and protocol negatives where relevant.\n'
    printf '5. Update the product documentation locations named by the product profile wherever behavior, contracts, workflows, controls, or operator/customer guidance changes. If the repo uses `docs/architecture`, `docs/functional`, or `docs/manual`, keep those layers truthful.\n'
    printf '6. Record the outcome in this packet under `## Work Log`.\n\n'
    if [[ "$kind" == "spec-addition" ]]; then
      printf 'Spec-origin rule: this packet is not documentation polish. Implement the missing product/protocol/workflow contract in code, tests, and docs, or explicitly prove the contract is already implemented and update the packet with that evidence.\n\n'
    fi
    if [[ "$kind" == "scorecard" ]]; then
      printf 'Scorecard-origin rule: scorecard findings must be re-verified against current code before implementation. If the finding is already fixed, update this packet with evidence and mark it complete without code churn. If real, fix the root cause and update the scorecard evidence trail after verification.\n\n'
    fi
    if [[ "$kind" == "stale-code" ]]; then
      printf 'Stale-code rule: this packet is not generic refactoring. Prove whether the named artifact is still active. If it is superseded, stubbed, unreachable, or preserving obsolete behavior, delete it or converge callers/tests/docs onto the current path. Keep compatibility only when an explicit product/API contract requires it, and document that contract in the packet.\n\n'
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

purge_orphaned_packets() {
  [[ -f "$PX_TSV" ]] || return 0
  [[ -d "$REMEDIATION_DIR/packets" ]] || return 0
  local _stale_count=0 _base
  while IFS= read -r _base; do
    rm -f "$REMEDIATION_DIR/packets/$_base"
    _stale_count=$(( _stale_count + 1 ))
  done < <(comm -23 \
    <(find "$REMEDIATION_DIR/packets" -maxdepth 1 -name 'PX-*.md' -printf '%f\n' 2>/dev/null | sort) \
    <(awk 'NR > 1 && $1 ~ /^PX-/ { print $1 ".md" }' "$PX_TSV" | sort))
  if (( _stale_count > 0 )); then
    printf '[catalog] purged %d orphaned packet file(s) not in current master inventory\n' "$_stale_count" >&2
  fi
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

  if [[ "$REMEDIATION_REWRITE_PACKETS" == "1" ]]; then
    purge_orphaned_packets
  fi
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

  if [[ "$DRY_RUN" == "1" ]]; then
    cat >&2 <<EOF
[raw-unit-guard] dry-run warning: raw one-packet implementation manifest detected.

Manifest: $UNITS_TSV
Rows: total=$total raw_px_unit_ids=$raw single_packet_rows=$single

Execution would require catalog consolidation first; dry-run continues so the generated blocker ledger and packet inventory can be inspected.
EOF
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

auto_recover_raw_unit_manifest() {
  [[ -f "$UNITS_TSV" ]] || return 0
  [[ "$REMEDIATION_ALLOW_RAW_UNITS" == "1" ]] && return 0
  [[ -n "$ONLY_UNIT" ]] && return 0
  [[ "$EXECUTE" == "1" ]] || return 0
  [[ "$VERIFY_ONLY" != "1" ]] || return 0
  [[ "$NO_CATALOG" != "1" ]] || return 0

  local stats total raw single
  stats="$(raw_incomplete_unit_manifest_stats)"
  IFS=$'\t' read -r total raw single <<< "$stats"

  if ! raw_incomplete_unit_manifest_is_unsafe "$total" "$raw" "$single"; then
    return 0
  fi

  printf '[auto-recover] raw one-packet implementation manifest detected; forcing 00-cataloger rerun before execution\n'
  FORCE_CATALOG=1
  CATALOG_WITH_CODEX=1

  if [[ -f "$CHECKPOINT_FILE" ]]; then
    local _catalog_checkpoint_tmp
    _catalog_checkpoint_tmp="$(mktemp)"
    grep -vxF "00-cataloger" "$CHECKPOINT_FILE" > "$_catalog_checkpoint_tmp" || true
    mv "$_catalog_checkpoint_tmp" "$CHECKPOINT_FILE"
  fi

  build_catalog_prompt
  printf '[cataloger] %s\n' "$REMEDIATION_DIR/prompts/00-cataloger.md"
  if run_prompt "$REMEDIATION_DIR/prompts/00-cataloger.md" "00-cataloger" "cataloger"; then
    printf '%s\n' "00-cataloger" >> "$CHECKPOINT_FILE"
    purge_orphaned_packets
    normalize_units_tsv
    merge_duplicate_units_tsv
    rebuild_workstream_coordinator_prompts
    rebuild_unit_prompts
    build_final_review_prompt
  else
    printf '[fail] 00-cataloger (see %s/logs/00-cataloger.log)\n' "$REMEDIATION_DIR" >&2
    exit 1
  fi
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
    [[ "$id" =~ ^PX-[0-9]+$ ]] || continue
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

catalog_outputs_are_ready() {
  [[ -s "$PX_TSV" && -s "$PX_MD" && -s "$WORKSTREAMS_TSV" && -s "$UNITS_TSV" ]] || return 1
  local stats total raw single
  stats="$(raw_incomplete_unit_manifest_stats)"
  IFS=$'\t' read -r total raw single <<< "$stats"
  raw_incomplete_unit_manifest_is_unsafe "$total" "$raw" "$single" && return 1
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

  while IFS=$'\t' read -r f1 f2 f3 f4 _f5 _f6 _f7 f8; do
    local group model_class packets_csv
    # packets are always the last populated column (4-col Meridian or 8-col Portal)
    local _last_col="${f8:-${f4}}"
    if [[ "$f1" == WS-* ]]; then
      group="$f1"; model_class="$f3"; packets_csv="$_last_col"
    else
      group="$f1"; model_class="$f2"; packets_csv="$_last_col"
    fi
    [[ -z "${group:-}" ]] && continue

    # Level 1: always group by Source kind.
    # If all packets share the same kind (or have no kind), keep the group as-is.
    local -A kind_map=()
    local -a all_pxs
    IFS=',' read -ra all_pxs <<< "$packets_csv"
    for px in "${all_pxs[@]}"; do
      local kind
      kind=$(grep "^- Source kind:" "$packets_dir/$px.md" 2>/dev/null | head -1 | grep -oP '`[^`]+`' | tr -d '`') || true
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
  local px="$1"
  local pfile="$REMEDIATION_DIR/packets/$px.md"
  [[ -f "$pfile" ]] || return 1
  packet_has_terminal_status "$pfile" && return 1
  printf '\n- Status: `complete`\n' >> "$pfile"
}

remediation_dir_audit_run() {
  local rdir="$1"
  [[ -f "$rdir/01-master-px-list.md" ]] || return 0
  sed -n 's/^- Audit run: `\(.*\)`$/\1/p' "$rdir/01-master-px-list.md" 2>/dev/null | head -1 || true
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

  local packet_file_count px_row_count packet_unknown_count unit_unknown_count
  packet_file_count="$(find "$REMEDIATION_DIR/packets" -maxdepth 1 -name 'PX-*.md' -printf '.' 2>/dev/null | wc -c | tr -d ' ')"
  px_row_count="$(awk 'NR > 1 && $1 ~ /^PX-/ { count += 1 } END { print count + 0 }' "$PX_TSV")"
  packet_unknown_count="$(
    {
      awk -F '\t' 'NR > 1 && $1 ~ /^PX-/ { print "known\t" $1 }' "$PX_TSV"
      find "$REMEDIATION_DIR/packets" -maxdepth 1 -name 'PX-*.md' -printf 'file\t%f\n' 2>/dev/null
    } | awk -F '\t' '
      $1 == "known" {
        known[$2] = 1
        next
      }
      $1 == "file" {
        id = $2
        sub(/\.md$/, "", id)
        parent = id
        sub(/-S[0-9]+$/, "", parent)
        if (id in known) next
        if (id ~ /^PX-[0-9]+-S[0-9]+$/ && parent in known) next
        unknown[id] = 1
      }
      END {
        for (id in unknown) count += 1
        print count + 0
      }
    '
  )"
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
            parent = ids[i]
            sub(/-S[0-9]+$/, "", parent)
            if (ids[i] ~ /^PX-/ && !(ids[i] in known) && !(ids[i] ~ /^PX-[0-9]+-S[0-9]+$/ && parent in known)) unknown[ids[i]] = 1
          }
        }
        END {
          for (id in unknown) count += 1
          print count + 0
        }
      ' "$PX_TSV" "$UNITS_TSV"
    )"
  fi

  if (( packet_unknown_count > 0 || unit_unknown_count > 0 )); then
    cat >&2 <<EOF
[manifest-guard] refusing to preserve an inconsistent remediation inventory.

Remediation dir: $REMEDIATION_DIR
Master PX inventory: $PX_TSV
Packet files: $packet_file_count
Master PX rows: $px_row_count
Packet files missing from master: $packet_unknown_count
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
      [[ "$id" =~ ^PX-[0-9]+$ ]] || continue
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
  local -a ids=()
  read -r -a ids <<< "$ids_csv"
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
- Seed blocker ledger TSV: $BLOCKER_LEDGER_TSV
- Seed blocker ledger markdown: $BLOCKER_LEDGER_MD
- Raw pre-dedup Px TSV: $RAW_PX_TSV
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

Execution constraint: do not use background workflow/delegation tools, sub-agents, or async job launchers. Complete the catalog in this single runner session by reading files directly and writing the required artifacts directly. Do not tell the operator to watch \`/workflows\`. Do not emit \`RESULT: PASS\` until every required catalog file and packet file has been written and re-read for schema consistency.

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
- \`$AUDIT_RUN/artifacts/load-test/load-test-report.md\` if it exists — contains load test scenario results, p95/p99 latencies, and error rates.
- \`$AUDIT_RUN/artifacts/stale-code-candidates.tsv\` if it exists — contains stale/superseded/stub candidates from the tech-debt audit. Treat these as first-class deletion/convergence remediation sources, not optional cleanup notes.
- Any \`*.md\` files under \`$AUDIT_RUN/artifacts/\` subdirectories (e.g., \`sast/\`, \`lighthouse/\`, \`accessibility/\`, \`external-services/\`, deep-dive job reports) — these contain SAST/CVE findings, Core Web Vitals results, WCAG violations, and external service probe results that must be cataloged as packets alongside the main audit reports.
- \`$BLOCKER_LEDGER_MD\` and \`$BLOCKER_LEDGER_TSV\` — deterministic root-cause blocker grouping. Treat these as the first-pass source of truth for whether repeated domain/synthesis/runtime/final-decision mentions are one remediation outcome.
- \`$RAW_PX_TSV\` — the pre-dedup raw finding list. Use it only to recover source references, not to recreate duplicate packets.

Rewrite these files with a deduplicated, implementation-ready catalog:

1. \`$PX_TSV\`
2. \`$PX_MD\`
3. \`$WORKSTREAMS_TSV\`
4. \`$UNITS_TSV\`
5. \`$REMEDIATION_DIR/packets/PX-*.md\`

Catalog requirements:

- First read \`$COMPLETED_PACKETS_TSV\` and the seed packet work logs. Completed packet IDs represent already-fixed work recovered from current or prior same-audit remediation artifacts.
- One packet should represent one coherent remediation outcome, not every repeated mention of the same defect.
- Preserve blocker-ledger grouping by default. If \`B-0001\` appears in six audit reports, create one implementation unit for the root cause and list all six reports as verification targets.
- Only split a blocker-ledger row when current-code inspection proves the row combines unrelated defects. If you split it, write the reason into packet work logs and keep the original blocker ID in each child packet.
- Classify each blocker as one of: \`product_gap\`, \`evidence_gap\`, \`harness_gap\`, \`stale_prior_decision\`, or \`runtime_unavailable\`. Use that category to decide whether the implementation task is product code, test/evidence harness, audit harness behavior, stale artifact reconciliation, or environment recovery.
- Merge duplicate mentions across domain, cross-cutting, spec-addition, runtime, maturity, customer-proof, adversarial, and final-decision reports.
- When a deduplicated packet consists only of already-completed seed packets, preserve that completion in the merged packet work log and set \`Status: complete\`.
- When a deduplicated packet includes both completed and incomplete seed packets, keep the merged packet incomplete, but list the completed seed packet IDs and evidence in the work log so the implementer does not redo closed work.
- Do not convert completed work back to \`not-started\` merely because packet IDs or implementation units are being deduplicated.
- Treat spec inventory, product profile, and master-prompt deltas as first-class packet sources. If a required product capability appears in the profile/spec prompt but lacks implementation, docs, tests, or launch evidence, create or merge a packet for that missing contract.
- Treat stale-code candidates as first-class remediation packets. Prefer deletion, caller convergence, stale test/doc removal, and config/flag cleanup. Do not preserve old and new paths side by side unless there is an explicit compatibility contract and a test proving that contract.
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
      if split_candidate_has_durable_decision "$unit_id" "$packets_csv"; then
        continue
      fi

      local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
      local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
      local log="$REMEDIATION_DIR/logs/implement-$unit_id.log"
      local reasons=()
      local packet_bytes=0
      local packet_count=0

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
        packet_count=$((packet_count + 1))
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
      if [[ -s "$(verifier_findings_tsv_for_unit "$unit_id")" ]] && \
         verifier_findings_exceed_auto_revise_limit "$(verifier_findings_tsv_for_unit "$unit_id")" && \
         ! verifier_finding_type_blocks_auto_revise "$(verifier_findings_tsv_for_unit "$unit_id")"; then
        reasons+=("verifier-findings-over-auto-revise-limit")
      fi
      if file_matches 'tokens used.*([2-9][0-9]{5,}|[2-9][0-9]{2},[0-9]{3}|[0-9]{1,3},[0-9]{3},[0-9]{3})|exceed(ed|s)? .*200000|above .*200000|over .*200000' "$log"; then
        reasons+=("token-budget-risk")
      fi
      if ((packet_bytes > MAX_UNIT_PACKET_BYTES)); then
        reasons+=("oversized-unit-packet-text")
      fi
      if ((packet_count > MAX_UNIT_PACKET_COUNT)); then
        reasons+=("too-many-packets")
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
  SPLIT_CANDIDATE_COUNT="$candidate_count"
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
    local parent unit_id packets_csv _group _model _severity _rationale
    local IFS=,
    for parent in $SPLIT_CANDIDATE_UNITS; do
      [[ -n "${parent:-}" ]] || continue
      unit_has_split_children "$parent" || continue
      while IFS=$'\t' read -r unit_id packets_csv _group _model _severity _rationale; do
        [[ "$unit_id" == "$parent" ]] || continue
        local packet_id packet_file
        local IFS=,
        for packet_id in $packets_csv; do
          packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
          [[ -f "$packet_file" ]] || continue
          file_matches 'Status:[[:space:]]*`?split-into-child-units|split-into-child-units' "$packet_file" && continue
          printf '\n- Status: `split-into-child-units`\n' >> "$packet_file"
          printf -- '- Split child units: `%s`\n' "$(awk -F '\t' -v prefix="$parent-S" 'FNR > 1 && index($1, prefix) == 1 { print $1 }' "$UNITS_TSV" | paste -sd, -)" >> "$packet_file"
        done
      done < <(tail -n +2 "$UNITS_TSV")
    done
  fi

  if [[ -n "$AUTO_SPLIT_CHILD_UNITS" ]]; then
    printf '[split-children] units=%s\n' "$AUTO_SPLIT_CHILD_UNITS"
  else
    printf '[split-children] units=none\n'
  fi
}

next_split_child_number() {
  local parent="$1"
  local max
  max="$(
    awk -F '\t' -v prefix="$parent-S" '
      FNR > 1 && index($1, prefix) == 1 {
        suffix = substr($1, length(prefix) + 1)
        if (suffix ~ /^[0-9][0-9]$/ && suffix + 0 > max) {
          max = suffix + 0
        }
      }
      END { printf "%02d", max + 1 }
    ' "$UNITS_TSV" 2>/dev/null
  )"
  [[ -n "$max" ]] || max="01"
  printf '%s\n' "$max"
}

split_child_exists_for_file() {
  local parent="$1" finding_file="$2"
  [[ -n "$finding_file" ]] || return 1
  awk -F '\t' -v prefix="$parent-S" -v file="$finding_file" -v rdir="$REMEDIATION_DIR" '
    FNR > 1 && index($1, prefix) == 1 {
      packet_count = split($2, packets, ",")
      for (i = 1; i <= packet_count; i += 1) {
        packet = packets[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", packet)
        if (packet == "") continue
        packet_file = rdir "/packets/" packet ".md"
        while ((getline line < packet_file) > 0) {
          if (index(line, file) > 0) {
            found = 1
          }
        }
        close(packet_file)
      }
    }
    END { exit found ? 0 : 1 }
  ' "$UNITS_TSV" 2>/dev/null
}

append_split_child_unit() {
  local parent_unit="$1" parent_packets="$2" group="$3" model_class="$4" severity="$5"
  local finding_type="$6" finding_file="$7" finding="$8" required_fix="$9"

  split_child_exists_for_file "$parent_unit" "$finding_file" && return 0

  local parent_packet child_num child_unit child_packet slug packet_file rationale
  parent_packet="${parent_packets%%,*}"
  child_num="$(next_split_child_number "$parent_unit")"
  slug="$(slugify_id "$finding_file")"
  child_unit="$parent_unit-S$child_num"
  child_packet="$parent_packet-S$child_num"
  packet_file="$REMEDIATION_DIR/packets/$child_packet.md"

  cat > "$packet_file" <<EOF
# Remediation Packet $child_packet

- Severity: \`${severity:-P1}\`
- Workstream: \`$group\`
- Model class: \`$model_class\`
- Status: \`not-started\`
- Parent unit: \`$parent_unit\`
- Parent packets: \`$parent_packets\`
- Split reason: \`$finding_type\`

## Scope

Deterministic child packet created from verifier finding on \`$finding_file\`.

## Required Remediation

Implement this bounded child packet. Do not re-cut it again unless a fresh verifier finding identifies unrelated ownership inside this child scope.

Original verifier routing note:

$(printf '%s\n' "$required_fix")

## Source Finding

$(printf '%s\n' "$finding")

## File Ownership

- Primary file or subsystem: \`$finding_file\`
- Do not modify sibling subsystem files unless they are direct dependencies of this child packet.

## Verification Gates

- Run focused tests and standards checks for \`$finding_file\` or its owning subsystem.
- Re-run the parent verifier after this child packet is complete.

## Work Log

- Status: \`not-started\`
EOF

  rationale="$finding_type:$slug"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$child_unit" "$child_packet" "$group" "$model_class" "${severity:-P1}" "$rationale" >> "$UNITS_TSV"

  printf '%s\n' "$child_unit"
}

mark_parent_split_decomposed() {
  local parent_unit="$1" parent_packets="$2" child_units="$3"
  local packet_id packet_file
  local IFS=,
  for packet_id in $parent_packets; do
    [[ -n "${packet_id:-}" ]] || continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    [[ -f "$packet_file" ]] || continue
    file_matches 'Status:[[:space:]]*`?split-into-child-units|split-into-child-units' "$packet_file" && continue
    {
      printf '\n- Status: `split-into-child-units`\n'
      printf -- '- Split child units: `%s`\n' "$child_units"
      printf -- '- Split reason: deterministic verifier decomposition into bounded child units.\n'
    } >> "$packet_file"
  done
}

workspace_prompt_block() {
  local unit_id="${1:-}"
  local roots
  roots="$(workspace_git_roots | sed 's/^/- `/; s/$/`/' || true)"
  if repo_root_is_git_root; then
    cat <<EOF
- Product root: \`$REPO_ROOT\`
- Workspace mode: isolated git worktree when available.
- Planned unit worktree: \`$REMEDIATION_DIR/worktrees/$unit_id\`
EOF
  elif [[ -n "$roots" ]]; then
    cat <<EOF
- Product root: \`$REPO_ROOT\`
- Workspace mode: split-root live workspace. \`$REPO_ROOT\` is not a git repository, but child repositories are.
- Child git roots:
$roots
- Edit files under the product root, normally under \`backend/\`, \`frontend/\`, and \`docs/\`.
- Treat \`backend\` and \`frontend\` as the source-control roots for status, diffs, and commits. Do not assume the product root itself supports \`git status\`, \`git worktree\`, or repo-relative commits.
EOF
  else
    cat <<EOF
- Product root: \`$REPO_ROOT\`
- Workspace mode: live non-git workspace.
- Edit files under the product root. The orchestrator serializes units because no git root is available for isolated worktrees.
EOF
  fi
}

decompose_verifier_split_findings() {
  [[ -s "$UNITS_TSV" && -d "$REMEDIATION_DIR/artifacts" ]] || return 0
  local created_any=0
  local unit_id packets_csv group model_class severity rationale

  while IFS=$'\t' read -r unit_id packets_csv group model_class severity rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    unit_selected "$unit_id" || continue
    [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]] && continue
    [[ "$unit_id" == *-S[0-9][0-9] ]] && continue

    local findings_file
    findings_file="$(verifier_findings_tsv_for_unit "$unit_id")"
    [[ -s "$findings_file" ]] || continue

    local tmp_rows
    tmp_rows="$(mktemp)"
    awk -F '\t' 'NR > 1 && ($3 == "split_required" || $3 == "test_harness") && $1 != "" { print }' "$findings_file" > "$tmp_rows"
    [[ -s "$tmp_rows" ]] || {
      rm -f "$tmp_rows"
      continue
    }

    local created_units=()
    local row_unit row_severity finding_type finding_file finding_line finding required_fix
    while IFS=$'\t' read -r row_unit row_severity finding_type finding_file finding_line finding required_fix; do
      [[ "$row_unit" == "$unit_id" ]] || continue
      if [[ "$finding_type" == "test_harness" ]] && ! finding_is_sibling_drift "$unit_id" "$finding_file" "$finding_type"; then
        continue
      fi
      local child
      child="$(append_split_child_unit "$unit_id" "$packets_csv" "$group" "$model_class" "${row_severity:-$severity}" "$finding_type" "$finding_file" "$finding" "$required_fix" || true)"
      [[ -n "$child" ]] && created_units+=("$child")
    done < "$tmp_rows"
    rm -f "$tmp_rows"

    local child_units
    child_units="$(split_child_units_csv "$unit_id")"
    if [[ -n "$child_units" ]]; then
      mark_parent_split_decomposed "$unit_id" "$packets_csv" "$child_units"
      append_scope_classification "$unit_id" "split" "verifier_split_required_or_sibling_test_harness" "$group" "$packets_csv" "$child_units"
      created_any=1
    fi
    if ((${#created_units[@]} > 0)); then
      local IFS=,
      printf '[split-verifier] parent=%s children=%s\n' "$unit_id" "${created_units[*]}"
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if [[ "$created_any" == "1" ]]; then
    normalize_units_tsv
    rebuild_unit_prompts
    build_final_review_prompt
  fi
}

decompose_oversized_verifier_findings() {
  [[ -s "$UNITS_TSV" && -d "$REMEDIATION_DIR/artifacts" ]] || return 0
  local created_any=0
  local unit_id packets_csv group model_class severity rationale

  while IFS=$'\t' read -r unit_id packets_csv group model_class severity rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    unit_selected "$unit_id" || continue
    [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]] && continue
    [[ "$unit_id" == *-S[0-9][0-9] ]] && continue
    unit_has_split_children "$unit_id" && continue
    unit_packets_marked_split_parent "$unit_id" && continue

    local findings_file verifier finding_count
    findings_file="$(verifier_findings_tsv_for_unit "$unit_id")"
    verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    [[ -s "$findings_file" && -s "$verifier" ]] || continue
    verifier_accepts_unit "$unit_id" && continue
    verifier_has_only_launch_evidence_findings "$unit_id" && continue
    verifier_has_only_coordinator_or_evidence_findings "$unit_id" && continue
    verifier_finding_type_blocks_auto_revise "$findings_file" && continue
    file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(stop)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(blocked)' "$verifier" && continue
    verifier_findings_exceed_auto_revise_limit "$findings_file" || continue

    finding_count="$(verifier_findings_count "$findings_file")"
    local tmp_rows
    tmp_rows="$(mktemp)"
    awk -F '\t' '
      NR > 1 && $1 != "" &&
      $3 != "launch_evidence" &&
      $3 != "sandbox_blocked" &&
      $3 != "coordinator_cleanup" &&
      $3 != "packet_metadata" &&
      $3 != "process_metadata" {
        print
      }
    ' "$findings_file" > "$tmp_rows"
    [[ -s "$tmp_rows" ]] || {
      rm -f "$tmp_rows"
      continue
    }

    local created_units=()
    local row_unit row_severity finding_type finding_file finding_line finding required_fix
    while IFS=$'\t' read -r row_unit row_severity finding_type finding_file finding_line finding required_fix; do
      [[ "$row_unit" == "$unit_id" ]] || continue
      local child
      child="$(append_split_child_unit "$unit_id" "$packets_csv" "$group" "$model_class" "${row_severity:-$severity}" "oversized_$finding_type" "$finding_file" "$finding" "$required_fix" || true)"
      [[ -n "$child" ]] && created_units+=("$child")
    done < "$tmp_rows"
    rm -f "$tmp_rows"

    local child_units
    child_units="$(split_child_units_csv "$unit_id")"
    if [[ -n "$child_units" ]]; then
      mark_parent_split_decomposed "$unit_id" "$packets_csv" "$child_units"
      append_scope_classification "$unit_id" "split" "oversized_verifier_findings:${finding_count}>${MAX_AUTO_REVISE_FINDINGS}" "$group" "$packets_csv" "$child_units"
      created_any=1
    fi
    if ((${#created_units[@]} > 0)); then
      local IFS=,
      printf '[split-verifier] parent=%s reason=oversized-findings findings=%s children=%s\n' "$unit_id" "$finding_count" "${created_units[*]}"
    fi
  done < <(tail -n +2 "$UNITS_TSV")

  if [[ "$created_any" == "1" ]]; then
    normalize_units_tsv
    rebuild_unit_prompts
    build_final_review_prompt
  fi
}

build_workstream_prompt() {
  local unit_id="$1" group="$2" model_class="$3" packets_csv="$4"
  local prompt="$REMEDIATION_DIR/prompts/implement-$unit_id.md"
  local packet_list
  packet_list="$(packet_paths_for_ids "$packets_csv")"
  local design_doc="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
  local design_block=""
  local workspace_block
  workspace_block="$(workspace_prompt_block "$unit_id")"
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
    if [[ -s "$findings_tsv" || -s "$REMEDIATION_DIR/artifacts/verify-$unit_id.md" ]]; then
      revision_context=$(cat <<REVISION

## Revision Context

This is a revision pass against an existing remediation run. Do not recatalog the packet and do not treat missing live launch-readiness evidence as the implementation task unless the packet itself requires a code/docs/test change to produce that evidence.

Open these prior artifacts before editing:

- Previous implementation summary: \`$REMEDIATION_DIR/artifacts/$unit_id-summary.md\`
- Previous verifier artifact: \`$REMEDIATION_DIR/artifacts/verify-$unit_id.md\`
- Previous verifier findings TSV: \`$findings_tsv\`
- Previous implementation log if needed for failure details: \`$REMEDIATION_DIR/logs/implement-$unit_id.log\`

Your work contract is the unresolved implementation/code/docs/test revision list from the verifier findings TSV. Fix only those findings and the minimum directly required follow-on changes. Do not redesign, recatalog, broaden scope, or revisit accepted packet areas. If the TSV is missing or empty, use the verifier artifact's explicit required revisions and keep the same narrow scope.

## Unresolved Verifier Findings

These are the exact current TSV rows to resolve in this revision pass:

\`\`\`tsv
$(cat "$findings_tsv" 2>/dev/null || true)
\`\`\`

If the verifier finding type is \`contract_conflict\`, \`test_harness\`, or \`blocked\`, stop and write \`IMPLEMENTATION_RESULT: blocked\` with the exact human decision or targeted command required. Do not guess the product contract, and do not make broad test-harness rewrites from inside the auto-revise loop.

In implementation scope, do not run sandbox-sensitive PostgreSQL suites, live VPS checks, browser/E2E launch proof, or external integration proof unless they are explicitly known to be stable in this environment. Record those as launch evidence pending or sandbox-blocked, but do not leave fixable code/docs/tests unresolved.
REVISION
)
    else
      revision_context=$(cat <<REVISION

## Resume Context

This is a resume of an existing remediation run, but no verifier artifact or verifier findings TSV exists for this unit yet:

- Previous verifier artifact: \`$REMEDIATION_DIR/artifacts/verify-$unit_id.md\`
- Previous verifier findings TSV: \`$findings_tsv\`

Treat this as the first implementation attempt for the assigned packets. Use the implementation design above as the primary brief when present. Do not block solely because verifier artifacts are absent; those artifacts are produced after implementation.
REVISION
)
    fi
  fi

  cat > "$prompt" <<PROMPT
# Remediation Implementation Unit: $unit_id

## Metadata

$workspace_block
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

## Shared Standards Gate

Before editing, read the shared standards that apply to this unit:

- \`/home/pete/cadres/shared/templates/coding.md\` for all code, tests, scripts, migrations, and helper design.
- \`/home/pete/cadres/shared/templates/ui-specification.md\` for any frontend, route, workflow, component, visual, copy, accessibility, or operator-facing change. If the unit has no UI surface, state that it was not applicable.
- \`/home/pete/cadres/shared/templates/definition-of-done-checklist.md\` before declaring the unit fixed, partial, or blocked.
- \`/home/pete/cadres/shared/AGENTS.md\` for the execution philosophy and enterprise-grade completion bar.

Treat standards violations as implementation defects, not cosmetic concerns. Fix coding-standard, UI-standard, and definition-of-done gaps that are in scope for the assigned packets. If a required standard file is unavailable, record that as a blocker or residual risk in the summary.

## Legacy Cutover / Tech-Debt Rule

Do not leave legacy, superseded, placeholder, stub, mock, no-op, or duplicate old/new paths in place when this remediation replaces them. If the current fix establishes the correct product contract and no explicit compatibility contract requires the old path, cut the cord in the same unit: remove stale code, routes, jobs, feature flags, config/env keys, docs, tests, scripts, and compatibility shims. If compatibility is genuinely required, document the contract and add focused verification for both the current path and the compatibility path.

## Assigned Packets

\`\`\`text
$packet_list
\`\`\`
$design_block
$revision_context

## Implementation Instructions

Read only the assigned packets first (and the design document above if one was provided). Then inspect the minimal code, tests, and docs required to fix them.

Packets may originate from domain, cross-cutting, spec-addition, runtime, maturity/customer-proof, adversarial, or final-decision audit sources. Treat all source kinds as first-class implementation contracts. For spec-addition or product-profile packets, do not close the packet with docs-only evidence unless the packet explicitly says the missing work is documentation truth; implement the missing code path, validation, control, operator/customer workflow, protocol behavior, integration behavior, or test harness required by the spec/profile.

For stale-code packets, start from deletion/convergence. Search production callers, routes, jobs, tests, docs, configs, migrations, and external compatibility notes. If the artifact is genuinely unused, stubbed, superseded, or preserving obsolete behavior, remove it and update callers/tests/docs. If it is still required, document the live contract and mark the packet complete with proof instead of adding another compatibility layer.

For all other packets, still check whether the fix supersedes an older implementation. Do not close the packet while old and new behavior both remain active by accident. Delete or converge the legacy path unless the assigned packet, product profile, or docs name a real compatibility requirement.

Own this implementation unit end to end:

1. Implement the remediation for the assigned packets.
2. Update each packet's \`## Work Log\` with a machine-readable status line as the final entry:
   - \`- Status: \`complete\`\` — packet fully implemented, tests pass, docs updated.
   - \`- Status: \`partial\`\` — implementation started but not finished; describe what remains.
   - \`- Status: \`blocked\`\` — cannot proceed; describe the blocker.
   This status is used by the coordinator on re-runs to skip already-completed packets. Do not leave it as \`not-started\`.
3. Update the product documentation locations named by the product profile as required.
4. Apply the shared coding standard to changed backend, frontend, test, migration, script, and helper code.
5. Apply the shared UI specification to changed UI surfaces and operator/customer workflows.
6. Run the strongest relevant verification available in the repo for the changed surface.
7. Search the changed surface for legacy/superseded/stub residue and remove it or document the explicit compatibility contract that requires it.
8. Write \`$REMEDIATION_DIR/artifacts/$unit_id-summary.md\` with changed files, tests, docs, standards reviewed, legacy cleanup performed or compatibility retained, remaining risks, and any packets left incomplete.

Keep the context window under 200k tokens. If these packets are too broad, complete the highest-severity coherent subset, mark completed packets \`Status: \`complete\`\`, and mark the rest \`Status: \`partial\`\` in the packet logs.

For revision passes, do not stop at restating verifier findings. Resolve them. The summary must include:

- \`IMPLEMENTATION_RESULT: fixed\`, \`partial\`, or \`blocked\`.
- A verifier-finding disposition table: fixed / still failing / launch-evidence-pending / sandbox-blocked.
- Exact commands run and outcomes.
- Exact docs updated, or a statement that no docs change was needed after checking the product-profile documentation locations.
- Exact shared standards reviewed, including whether the coding standard, UI standard, and definition-of-done checklist were applicable and satisfied.
- Legacy/superseded/stub cleanup performed, or the explicit compatibility contract that required keeping an old path.
PROMPT
}

build_verifier_prompt() {
  local unit_id="$1" group="$2" model_class="$3" packets_csv="$4"
  local prompt="$REMEDIATION_DIR/prompts/verify-$unit_id.md"
  local findings_tsv
  findings_tsv="$(verifier_findings_tsv_for_unit "$unit_id")"
  local packet_list
  packet_list="$(packet_paths_for_ids "$packets_csv")"
  local native_test_results
  native_test_results="$(native_test_results_block "$unit_id")"

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

## Shared Standards Gate

Before accepting implementation signoff, read and apply the shared standards:

- \`/home/pete/cadres/shared/templates/coding.md\` for code, tests, scripts, migrations, and helper design.
- \`/home/pete/cadres/shared/templates/ui-specification.md\` for any frontend, route, workflow, component, visual, copy, accessibility, or operator-facing change.
- \`/home/pete/cadres/shared/templates/definition-of-done-checklist.md\` for completion gates.
- \`/home/pete/cadres/shared/AGENTS.md\` for execution philosophy and enterprise-grade completion expectations.

If the implementation changed UI or operator-facing behavior, UI-standard review is mandatory. If the unit has no UI surface, state that the UI standard was not applicable. Missing or unverifiable standards review is a verifier finding.

## Assigned Packets

\`\`\`text
$packet_list
\`\`\`

## Verification Instructions

Do not edit files. Use a review/evidence-verification stance.

Verification scope is \`$VERIFY_SCOPE\`.

### Active Checkout Boundary

All implementation signoff must be verified against the active checkout rooted at \`$REPO_ROOT\` and its active child git roots such as \`$REPO_ROOT/backend\` and \`$REPO_ROOT/frontend\` when present. Remediation worktrees under \`$REMEDIATION_DIR/worktrees/\` are implementation scratch space only. You may read worktree logs/summaries as historical context, but you must not accept a unit based on files, tests, commits, or branch state that exist only under a worktree path. If a required file, test, doc, or config is present in \`$REMEDIATION_DIR/worktrees/$unit_id\` but absent from the active checkout, write \`Decision: revise\`, \`Implementation decision: revise\`, and a findings TSV row requiring the worktree change to be merged into the active checkout. In an accepted verifier artifact, do not cite worktree-local paths as proof of implementation completion.

Before accepting, run or report active-checkout probes for the claimed changed surfaces, for example \`git -C $REPO_ROOT status --short --branch\`, \`git -C $REPO_ROOT/backend status --short --branch\` when backend is involved, and file existence/search commands from the active checkout. For nested git roots, the active branch/HEAD matters; a top-level gitlink or separate remediation worktree branch is not enough.


When scope is \`implementation\`, answer the question: "Did the implementation fix the code/docs/tests for this packet, and do the implementation owner and verifier agree the packet is code-complete?" Do not run sandbox-sensitive PostgreSQL suites, live VPS checks, browser/E2E launch proof, or external integration proof unless they are explicitly known to be stable in this environment. Missing launch-readiness reruns, live VPS/browser proof, external IdP/relying-party proof, and PostgreSQL checks that cannot run in this sandbox must be recorded as \`launch-evidence-pending\` or \`sandbox-blocked\`, not as implementation failure. Still block implementation signoff for stale active tests, docs contradictions, unrun runnable local tests, failing runnable local tests, incomplete code, unsupported claims, or missing required success/failure test coverage.

When scope is \`launch\`, require full launch evidence and block on missing live/staged/browser/PostgreSQL/e2e evidence where the packet requires it.

This verifier is intentionally independent from the implementation workstream and may run on a different provider/model through \`VERIFICATION_RUNNER\`. Use strict evidence discipline:

1. Verify every assigned P0/P1 packet, and sample P2 packets when present.
2. Check that each packet's work log contains a machine-readable \`- Status: \`complete\`\` (or \`partial\`/\`blocked\`) line as its final entry, and that the stated status is truthful. A packet missing this line or still reading \`not-started\` is incomplete regardless of the implementation summary.
3. Check that each packet's work log truthfully states files changed, docs updated, verification run, and remaining risk.
4. Open cited audit sources, changed code, changed tests, and changed docs. Confirm the fix addresses the actual finding, not just the symptom.
5. Confirm docs were updated in the product-profile documentation locations where behavior, contracts, workflows, controls, or customer guidance changed.
6. Confirm the implementer reviewed and satisfied the shared coding standard for changed code/tests/scripts/migrations/helpers.
7. Confirm the implementer reviewed and satisfied the shared UI specification for changed frontend, route, workflow, copy, accessibility, and operator-facing surfaces.
8. Confirm the implementer reviewed and satisfied the shared definition-of-done checklist, including success paths, failure paths, controls, docs, and focused verification.
9. Confirm success-path and failure-path tests exist and were run or honestly blocked.
10. Search for alternate paths that could invalidate the fix, especially trust-boundary bypasses, authorization or isolation gaps, stale UI/API contracts, protocol/integration replay, lifecycle recovery, and audit evidence gaps.
10a. For stale-code packets, verify deletion/convergence explicitly: the stale artifact is removed or made unreachable only through a documented compatibility contract; stale tests/docs/config are removed or updated; replacement callers still pass focused tests; no new shim preserves the obsolete behavior without proof.
10b. For every implementation packet, check whether the changed surface now has both old and new behavior active. If legacy code, hidden routes, old API clients, stale docs/tests/config, feature flags, placeholders, stubs, mocks, no-op shims, or compatibility glue remain without an explicit compatibility contract, block signoff with \`type=stale_code\`.
11. Block implementation signoff for: missing or untruthful packet Work Log status lines, overclaimed packet closure, failing runnable tests, stale tests, documentation contradictions, unverified P0/P1 code closure, incomplete code, missing standards review, material coding/UI/definition-of-done violations, or any subagent context budget over 200000 tokens. In launch scope, also block signoff for missing launch evidence.
12. Prefer focused verification commands owned by this unit. Do not run the full backend/frontend suite unless the packet is explicitly a runtime quality-gate packet or the focused evidence cannot prove the claim. If a local command is sandbox-blocked, classify it as \`sandbox_blocked\` or \`launch_evidence\` rather than product failure unless it is a normal supported local implementation gate.
13. If docs, tests, packet text, and code disagree about the intended product/security contract, classify the finding as \`contract_conflict\` and use \`Decision: stop\` or \`Implementation decision: blocked\` unless the intended contract is explicit in the assigned packet.
14. If the blocker is a flaky, timing-sensitive, performance, environment-ordering, or broad harness issue, classify it as \`test_harness\` and specify the exact targeted command or human decision required. Do not demand repeated full-suite execution from the auto-revise loop.
15. Do not reopen an already closed packet solely because the original audit text still exists or because launch evidence is pending under implementation scope. Reopen it only when current code/docs/tests/work-log evidence contradicts the claimed closure, a focused runnable implementation gate fails, a standards violation exists on the changed surface, or a required implementation artifact is missing.
16. If the unit requires more than \`$MAX_AUTO_REVISE_FINDINGS\` independent code/docs/test fixes, or the findings span unrelated product areas that should not be revised as one change, classify the excess as \`split_required\` and use \`Decision: stop\` / \`Implementation decision: blocked\`.

Write \`$REMEDIATION_DIR/artifacts/verify-$unit_id.md\` with:

- Decision: \`accept\`, \`revise\`, or \`stop\`.
- Implementation decision: \`fixed\`, \`revise\`, or \`blocked\`.
- Launch evidence decision: \`complete\`, \`pending\`, or \`blocked\`.
- Packet-by-packet assertion checks.
- References opened and wider searches performed.
- Standards reviewed and any coding/UI/definition-of-done violations found.
- Missing evidence and required revisions.
- Whether this workstream can be included in final remediation signoff.

Also write \`$findings_tsv\` with this exact tab-separated header:

\`\`\`text
unit_id	severity	type	file	line	finding	required_fix
\`\`\`

Use one row per unresolved verifier finding. Valid \`type\` values:

- \`code\` — product/source implementation defect.
- \`stale_code\` — stale, superseded, stubbed, placeholder, unreachable, or duplicate code/config/docs/tests remain after the implementation.
- \`docs\` — stale or contradictory docs with clear intended behavior.
- \`tests\` — missing or failing normal focused tests.
- \`standards\` — coding-standard, UI-standard, or definition-of-done violation on the changed surface.
- \`test_harness\` — flaky/timing/performance/environment-ordering/broad-suite harness issue that needs a targeted command or explicit human decision before auto-revision.
- \`contract_conflict\` — code/tests/docs/packet disagree on the intended behavior and a human product/security decision is required.
- \`launch_evidence\` — launch proof pending but implementation is otherwise fixed.
- \`sandbox_blocked\` — evidence cannot run in this environment.
- \`split_required\` — too many independent findings or unrelated product areas for safe automatic revision.
- \`blocked\` — cannot proceed without external dependency, access, or human input.

For \`accept\` / \`fixed\`, write only the header or only \`launch_evidence\` / \`sandbox_blocked\` rows. Do not include \`contract_conflict\`, \`test_harness\`, \`split_required\`, or \`blocked\` rows on an accepted implementation.

## Native Test Results
The harness executed the selected supported verification commands natively. Do NOT run the same commands again unless the log shows they were missing or could not start. Evaluate this output:

\`\`\`text
$native_test_results
\`\`\`
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
5. Identify legacy/superseded/stub paths touched by the change. If the fix replaces an old path, include deletion or caller convergence in the design unless an explicit compatibility contract requires keeping it.
6. Write the design document and stop.

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

## Legacy Cutover / Tech-Debt Cleanup
Old routes, services, flags, stubs, mocks, docs, tests, scripts, config, or compatibility shims to delete or converge as part of this unit. If anything old must remain, name the explicit compatibility contract and the test that proves it.

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
    recover_planner_design_result "$unit_id" "$design_doc" "$REMEDIATION_DIR/logs/plan-$unit_id.log" 2>/dev/null || true
    if final_result_is_pass "$design_doc" && artifact_mentions_all_packets "$design_doc" "$packets_csv"; then
      printf '[resume] recovered completed plan-%s from existing design artifact\n' "$unit_id"
      grep -qxF "plan-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "plan-$unit_id" >> "$CHECKPOINT_FILE"
      continue
    fi
    if grep -qxF "plan-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null; then
      if artifact_mentions_all_packets "$design_doc" "$packets_csv"; then
        printf '[resume] skipping completed plan-%s\n' "$unit_id"
      else
        # Design artifact may not cover all packets yet (e.g. verifier hasn't
        # run), but the planner already ran successfully. Trust the checkpoint.
        printf '[resume] skipping checkpointed plan-%s (design artifact pending)\n' "$unit_id"
      fi
      continue
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
  tail -n +2 "$WORKSTREAMS_TSV" | while IFS=$'\t' read -r f1 f2 f3 f4 _f5 _f6 _f7 f8; do
    local group model_class packets_csv
    local _last_col="${f8:-${f4}}"
    if [[ "$f1" == WS-* ]]; then
      group="$f1"
      model_class="$f3"
      packets_csv="$_last_col"
    else
      group="$f1"
      model_class="$f2"
      packets_csv="$_last_col"
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
          if [[ "$stall_secs" -ge "$stall_threshold" ]] && stall_kill_is_safe "$workstream" "$log_file"; then
            printf '\r[!] %s: stalled after %ds with terminal output/artifacts — terminating\033[K\n' \
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

verifier_postcheck_invalid_file() {
  local unit_id="$1"
  printf '%s/artifacts/verify-%s.postcheck.invalid\n' "$REMEDIATION_DIR" "$unit_id"
}

verifier_postcheck_invalid() {
  local unit_id="$1"
  [[ -s "$(verifier_postcheck_invalid_file "$unit_id")" ]]
}

mark_verifier_postcheck_invalid() {
  local unit_id="$1" reason="$2"
  mkdir -p "$REMEDIATION_DIR/artifacts"
  printf '%s\n' "$reason" > "$(verifier_postcheck_invalid_file "$unit_id")"
}

clear_verifier_postcheck_invalid() {
  local unit_id="$1"
  rm -f "$(verifier_postcheck_invalid_file "$unit_id")"
}

verifier_accepts_unit_raw() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  [[ -s "$verifier" ]] || return 1
  grep -qiE '^[[:space:]-]*(\*\*)?Decision[^[:alnum:]]+`?accept`?' "$verifier" || return 1
  grep -qiE '^[[:space:]-]*(\*\*)?Implementation decision[^[:alnum:]]+`?fixed`?' "$verifier" || return 1
}

verifier_acceptance_uses_worktree_evidence() {
  local unit_id="$1" verifier="$2"
  verifier_accepts_unit_raw "$unit_id" || return 1
  [[ -s "$verifier" ]] || return 1

  local filtered
  filtered="$(
    awk '
      {
        line = tolower($0)
        if (line ~ /not used|were not used|was not used|did not use|did not rely|not rely|did not accept .*worktree|worktree.*did not accept|did not cite .*worktree|active checkout.*not .*worktree|not .*worktree.*evidence|not .*scratch .*worktree|scratch .*worktree.*not accepted|worktree.*not accepted|were not accepted as proof|was not accepted as proof|not accepted as proof|not worktree-only proof|does not depend on .*worktree|not only (in|under) .*worktree|instead of .*worktree|no worktree|no .*proof .*worktree.*accepted|no implementation proof|not accepted from|scratch space|historical|stale .*postcheck|postcheck note|postcheck\.invalid|prior verifier|prior concern|addressed by|superseded .*worktree|worktree.*superseded|replaced .*worktree|worktree.*replaced|inspected .*worktree|searched .*worktree|references opened|wider searches|unrelated .*worktree|worktree.*unrelated|acceptance evidence.*active checkout only|active checkout only.*acceptance evidence|worktree.*active checkout only|worktrees.*active checkout only/) {
          next
        }
        if (line ~ /find .*worktrees/) {
          next
        }
      }
      { print }
    ' "$verifier"
  )"

  printf '%s\n' "$filtered" | grep -Eqi \
    "((accepted|accepting|acceptance|signoff|signed off)[^[:cntrl:]]*(/worktrees/$unit_id|worktrees/$unit_id|worktree|worktree-local|implementation worktree|worktree/backend branch)|(/worktrees/$unit_id|worktrees/$unit_id|worktree|worktree-local|implementation worktree|worktree/backend branch)[^[:cntrl:]]*(accepted|accepting|acceptance|signoff|signed off))"
}

validate_prompt_outputs() {
  local workstream="$1" class="$2"
  local worktree_dir="${3:-$REPO_ROOT}"
  if [[ "$workstream" == plan-* ]]; then
    local unit_id="${workstream#plan-}"
    local design="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
    local log_file="$REMEDIATION_DIR/logs/$workstream.log"
    if [[ ! -s "$design" ]]; then
      printf '[postcheck] missing planner design artifact: %s\n' "$design" >&2
      return 1
    fi
    recover_planner_design_result "$unit_id" "$design" "$log_file" 2>/dev/null || true
    if ! final_result_is_pass "$design"; then
      printf '[postcheck] planner design artifact missing RESULT: PASS: %s\n' "$design" >&2
      return 1
    fi
  elif [[ "$workstream" == implement-* ]]; then
    local unit_id="${workstream#implement-}"
    copy_unit_artifacts_from_worktree "$unit_id" "$worktree_dir" 2>/dev/null || true
    recover_implementation_summary_from_log "$unit_id" "$REMEDIATION_DIR/logs/$workstream.log" 2>/dev/null || true
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
    clear_verifier_postcheck_invalid "$unit_id"
    if [[ ! -s "$verifier" ]]; then
      printf '[postcheck] missing verifier artifact: %s\n' "$verifier" >&2
      return 1
    fi
    ensure_verifier_findings_header "$findings"
    if verifier_acceptance_uses_worktree_evidence "$unit_id" "$verifier"; then
      local reason
      reason="verifier accepted $unit_id using worktree-only evidence; active checkout signoff is invalid: $verifier"
      mark_verifier_postcheck_invalid "$unit_id" "$reason"
      printf '[postcheck] %s\n' "$reason" >&2
      return 1
    fi
    clear_verifier_postcheck_invalid "$unit_id"
    write_verifier_input_fingerprint "$unit_id"
  elif [[ "$class" == "reviewer" ]]; then
    if [[ ! -s "$REMEDIATION_DIR/04-final-remediation-review.md" ]]; then
      printf '[postcheck] missing final remediation review: %s\n' "$REMEDIATION_DIR/04-final-remediation-review.md" >&2
      return 1
    fi
  fi
}

copy_unit_artifacts_from_worktree() {
  local unit_id="$1" worktree_dir="$2"
  [[ -n "$unit_id" ]] || return 0
  [[ "$worktree_dir" != "$REPO_ROOT" ]] || return 0
  [[ -d "$worktree_dir" ]] || return 0

  local rel_rdir="${REMEDIATION_DIR#"$REPO_ROOT"/}"
  [[ "$rel_rdir" != "$REMEDIATION_DIR" ]] || return 0

  local worktree_rdir="$worktree_dir/$rel_rdir"
  [[ -d "$worktree_rdir" ]] || return 0

  mkdir -p "$REMEDIATION_DIR/artifacts" "$REMEDIATION_DIR/packets"

  local src
  src="$worktree_rdir/artifacts/$unit_id-summary.md"
  if [[ -s "$src" ]]; then
    cp "$src" "$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  fi
  src="$worktree_dir/$unit_id-summary.md"
  if [[ -s "$src" && ! -s "$REMEDIATION_DIR/artifacts/$unit_id-summary.md" ]]; then
    cp "$src" "$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  fi

  shopt -s nullglob
  local artifact
  for artifact in "$worktree_rdir/artifacts/$unit_id" "$worktree_rdir/artifacts/$unit_id-"* "$worktree_rdir/artifacts/verify-$unit_id"*; do
    [[ -e "$artifact" ]] || continue
    cp -R "$artifact" "$REMEDIATION_DIR/artifacts/"
  done

  local packet_id packet_src packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" || true)"
  local IFS=,
  for packet_id in $packets_csv; do
    [[ -n "${packet_id:-}" ]] || continue
    packet_src="$worktree_rdir/packets/$packet_id.md"
    [[ -s "$packet_src" ]] || continue
    cp "$packet_src" "$REMEDIATION_DIR/packets/$packet_id.md"
  done
  shopt -u nullglob
}

final_result_value() {
  local log_file="$1"
  awk '
    /^assistant$/ || /^codex$/ || /^claude$/ || /^gemini$/ { marker = NR }
    { lines[NR] = $0 }
    END {
      start = marker ? marker + 1 : 1
      for (i = start; i <= NR; i += 1) print lines[i]
    }
  ' "$log_file" 2>/dev/null \
    | grep -aE '^RESULT:[[:space:]]*(PASS|FAIL|INCOMPLETE|BLOCKED)' 2>/dev/null \
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

stall_kill_is_safe() {
  local workstream="$1" log_file="$2"
  final_result_is_terminal "$log_file" && return 0

  case "$workstream" in
    00-cataloger)
      catalog_outputs_are_ready
      ;;
    plan-*|implement-*|verify-*)
      wave_job_completed_successfully "$workstream" "$log_file"
      ;;
    *)
      return 1
      ;;
  esac
}

runner_log_has_hard_error() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 1
  grep -aqE '(^|[^[:alnum:]_])(ERROR|Error):|\"type\"[[:space:]]*:[[:space:]]*\"error\"|\"code\"[[:space:]]*:[[:space:]]*\"[^\"]+\"|invalid_value|model .* does not exist|rate_limit_exceeded|authentication_error|permission_error' "$log_file" 2>/dev/null
}

planner_design_looks_complete() {
  local design="$1"
  [[ -s "$design" ]] || return 1
  grep -aqE '^# Implementation Design:' "$design" 2>/dev/null || return 1
  grep -aqE '^## Risks and Unknowns' "$design" 2>/dev/null || return 1
  grep -aqE '^## (Implementation|File-by-file|Migration|Invariants)' "$design" 2>/dev/null || return 1
}

recover_planner_design_result() {
  local unit_id="$1" design="$2" log_file="$3"
  final_result_is_pass "$design" && return 0
  planner_design_looks_complete "$design" || return 1
  {
    printf '\n\n---\n\n'
    printf 'RESULT: PASS\n\n'
    printf 'Recovered by the remediation harness after the planner wrote a complete design document but the runner disconnected before emitting the required final result marker.\n'
  } >> "$design"
  printf '[auto-recover] plan-%s: appended RESULT: PASS to complete planner design after runner disconnect\n' \
    "$unit_id" >> "$log_file"
}

implementation_summary_is_fixed() {
  local summary="$1"
  [[ -s "$summary" ]] || return 1
  grep -aqiE '^[[:space:]#*_`-]*IMPLEMENTATION_RESULT:[[:space:]]*`?fixed`?([[:space:]`*_,.;:-]|$)' "$summary" 2>/dev/null
}

implementation_summary_is_terminal() {
  local summary="$1"
  [[ -s "$summary" ]] || return 1
  grep -aqiE '^[[:space:]#*_`-]*IMPLEMENTATION_RESULT:[[:space:]]*`?(fixed|partial|blocked)`?([[:space:]`*_,.;:-]|$)' "$summary" 2>/dev/null
}

log_final_response() {
  local log_file="$1"
  awk '
    /^assistant$/ || /^codex$/ || /^claude$/ || /^gemini$/ { marker = NR }
    { lines[NR] = $0 }
    END {
      # Some runner logs do not preserve a clean final role marker. In that
      # case, scan the tail instead of returning an empty response so artifact
      # recovery can still see terminal markers such as IMPLEMENTATION_RESULT.
      start = marker ? marker + 1 : (NR > 800 ? NR - 799 : 1)
      for (i = start; i <= NR; i += 1) print lines[i]
    }
  ' "$log_file" 2>/dev/null
}

recover_implementation_summary_from_log() {
  local unit_id="$1" log_file="$2"
  local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  local recovered_result="" final_response=""
  [[ ! -s "$summary" ]] || return 0
  [[ -s "$log_file" ]] || return 1
  final_response="$(log_final_response "$log_file")"
  if printf '%s\n' "$final_response" | grep -aqiE 'IMPLEMENTATION_RESULT:[[:space:]]*`?fixed`?([[:space:]`*_,.;:-]|$)'; then
    recovered_result="fixed"
  elif printf '%s\n' "$final_response" | grep -aqiE 'IMPLEMENTATION_RESULT:[[:space:]]*`?blocked`?([[:space:]`*_,.;:-]|$)'; then
    recovered_result="blocked"
  elif printf '%s\n' "$final_response" | grep -aqiE 'IMPLEMENTATION_RESULT:[[:space:]]*`?partial`?([[:space:]`*_,.;:-]|$)'; then
    recovered_result="partial"
  elif printf '%s\n' "$final_response" | grep -aqiE '(honest status is|unit is still|remains)[^[:cntrl:]]*`?partial`?'; then
    recovered_result="partial"
  else
    case "$(final_result_value "$log_file")" in
      PASS) recovered_result="fixed" ;;
      INCOMPLETE|FAIL) recovered_result="partial" ;;
      BLOCKED) recovered_result="blocked" ;;
      *) return 1 ;;
    esac
  fi

  mkdir -p "$REMEDIATION_DIR/artifacts"
  {
    printf '# %s Implementation Summary\n\n' "$unit_id"
    if ! printf '%s\n' "$final_response" | grep -aqiE 'IMPLEMENTATION_RESULT:'; then
      printf 'IMPLEMENTATION_RESULT: %s\n\n' "$recovered_result"
    fi
    printf '%s\n' "$final_response"
    printf '\n\nRecovered from `%s` because the implementer wrote terminal summary content to the log but did not create the required artifact.\n' "$log_file"
  } > "$summary"
  printf '[auto-recover] implement-%s: recovered missing implementation summary from log\n' "$unit_id" >>"$log_file"
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
  write_verifier_input_fingerprint "$unit_id"
  printf '[auto-recover] verify-%s: recovered missing verifier artifact from RESULT: PASS log\n' "$unit_id" >>"$log_file"
}

repo_root_is_git_root() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

workspace_git_roots() {
  local seen_file
  seen_file="$(mktemp)"

  if repo_root_is_git_root; then
    printf '%s\n' "$REPO_ROOT" >> "$seen_file"
  fi

  local IFS=',' root root_path
  for root in $REMEDIATION_COMMIT_ROOTS; do
    [[ -n "$root" ]] || continue
    root_path="$(commit_root_path "$root")"
    [[ -d "$root_path" ]] || continue
    if git -C "$root_path" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s\n' "$root_path" >> "$seen_file"
    fi
  done

  local child
  for child in "$REPO_ROOT"/*; do
    [[ -d "$child" ]] || continue
    if git -C "$child" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s\n' "$child" >> "$seen_file"
    fi
  done

  awk '!seen[$0]++' "$seen_file"
  rm -f "$seen_file"
}

workspace_has_git_roots() {
  local root
  while IFS= read -r root; do
    [[ -n "$root" ]] && return 0
  done < <(workspace_git_roots)
  return 1
}

workspace_has_child_git_roots() {
  local root
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    [[ "$root" == "$REPO_ROOT" ]] && continue
    return 0
  done < <(workspace_git_roots)
  return 1
}

workspace_root_relative_remediation_dir() {
  local root="$1"
  if [[ "$REMEDIATION_DIR" == "$root/"* ]]; then
    printf '%s\n' "${REMEDIATION_DIR#"$root/"}"
  fi
}

readonly_role_diff_snapshot() {
  local root rel_rdir
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    printf 'ROOT\t%s\n' "$root"
    rel_rdir="$(workspace_root_relative_remediation_dir "$root")"
    local pathspec=(.)
    if [[ -n "$rel_rdir" ]]; then
      pathspec+=(":(exclude)$rel_rdir")
    fi
    git -C "$root" status --porcelain=v1 -uall -- "${pathspec[@]}" 2>/dev/null || true
  done < <(workspace_git_roots)
}

readonly_restore_workspace_changes() {
  local root rel_rdir
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    rel_rdir="$(workspace_root_relative_remediation_dir "$root")"
    local pathspec=(.)
    if [[ -n "$rel_rdir" ]]; then
      pathspec+=(":(exclude)$rel_rdir")
    fi

    local restore_list
    restore_list="$(mktemp)"
    {
      git -C "$root" diff --name-only -- "${pathspec[@]}"
      git -C "$root" diff --cached --name-only -- "${pathspec[@]}"
    } | awk 'NF && !seen[$0]++ { print }' > "$restore_list"

    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      git -C "$root" restore --source=HEAD --staged --worktree -- "$path" >/dev/null 2>&1 || true
    done < "$restore_list"
    rm -f "$restore_list"

    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      rm -rf "${root:?}/$path"
    done < <(git -C "$root" ls-files --others --exclude-standard -- "${pathspec[@]}")
  done < <(workspace_git_roots)
}

prepare_unit_workspace() {
  local unit_id="$1"
  local worktree_dir="$REMEDIATION_DIR/worktrees/$unit_id"

  if ! repo_root_is_git_root; then
    if workspace_has_git_roots; then
      printf '[workspace] %s: split-root workspace; using %s directly with child git roots: %s\n' \
        "$unit_id" "$REPO_ROOT" "$(workspace_git_roots | paste -sd, -)" >&2
    else
      printf '[workspace] %s: REPO_ROOT is not a git root; using %s directly\n' "$unit_id" "$REPO_ROOT" >&2
    fi
    printf '%s\n' "$REPO_ROOT"
    return 0
  fi

  if [[ "$REVISE_EXISTING" == "1" ]] && workspace_has_child_git_roots; then
    printf '[workspace] %s: revision in split-root checkout; using active workspace directly so nested git-root changes are verified in place\n' \
      "$unit_id" >&2
    printf '%s\n' "$REPO_ROOT"
    return 0
  fi

  if [[ ! -d "$worktree_dir" ]]; then
    mkdir -p "$REMEDIATION_DIR/worktrees"
    local branch_name
    branch_name="$(unit_worktree_branch_name "$unit_id")"
    local -a add_cmd
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch_name"; then
      add_cmd=(git -C "$REPO_ROOT" worktree add "$worktree_dir" "$branch_name")
    else
      add_cmd=(git -C "$REPO_ROOT" worktree add -b "$branch_name" "$worktree_dir" HEAD)
    fi
    if ! "${add_cmd[@]}" >/dev/null 2>&1; then
      if [[ "${REMEDIATION_ALLOW_WORKTREE_FALLBACK:-0}" != "1" ]]; then
        cat >&2 <<EOF
[workspace] $unit_id: failed to create git worktree under $worktree_dir.

Refusing to fall back to the live repo because this run may execute units in
parallel. Falling back here can make multiple implementers edit the same files
and produce misleading verifier results.

Fix the git worktree problem, lower MAX_PARALLEL to 1 and set
REMEDIATION_ALLOW_WORKTREE_FALLBACK=1 for an intentional live-workspace run, or
use a non-git split-root workspace with REMEDIATION_ALLOW_LIVE_WORKSPACE_PARALLEL=1.
EOF
        return 1
      fi
      printf '[workspace] %s: failed to create git worktree under %s; using %s directly\n' \
        "$unit_id" "$worktree_dir" "$REPO_ROOT" >&2
      printf '%s\n' "$REPO_ROOT"
      return 0
    fi
  fi

  printf '%s\n' "$worktree_dir"
}

unit_workspace_marker_file() {
  printf '%s/artifacts/%s.workspace\n' "$REMEDIATION_DIR" "$1"
}

record_unit_workspace() {
  local unit_id="$1" workspace="$2" marker
  marker="$(unit_workspace_marker_file "$unit_id")"
  mkdir -p "$REMEDIATION_DIR/artifacts"
  {
    printf 'unit_id\t%s\n' "$unit_id"
    printf 'workspace\t%s\n' "$workspace"
    if [[ "$workspace" == "$REPO_ROOT" ]]; then
      printf 'mode\tactive\n'
    else
      printf 'mode\tworktree\n'
    fi
  } > "$marker"
}

recorded_unit_workspace() {
  local unit_id="$1" marker
  marker="$(unit_workspace_marker_file "$unit_id")"
  [[ -s "$marker" ]] || return 1
  awk -F '\t' '$1 == "workspace" { print $2; found = 1; exit } END { if (!found) exit 1 }' "$marker"
}

unit_worktree_changed_after_workspace_marker() {
  local unit_id="$1" worktree_dir="$2" marker
  marker="$(unit_workspace_marker_file "$unit_id")"
  [[ -s "$marker" && -d "$worktree_dir" ]] || return 1
  find "$worktree_dir" \
    \( -path "$worktree_dir/.git" -o -path "$worktree_dir/node_modules" -o -path "$worktree_dir/.venv" \) -prune -o \
    -type f -newer "$marker" -print -quit 2>/dev/null | grep -q .
}

unit_worktree_branch_name() {
  local unit_id="$1"
  local run_label
  run_label="$(basename "$REMEDIATION_DIR")"
  run_label="${run_label//[^[:alnum:]._-]/-}"
  printf 'remediation-%s-%s\n' "$run_label" "$unit_id"
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
  verifier_postcheck_invalid "$unit_id" && return 1
  verifier_accepts_unit_raw "$unit_id"
}

verifier_has_terminal_decision() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  [[ -s "$verifier" ]] || return 1
  grep -qiE '^[[:space:]-]*(\*\*)?Decision[^[:alnum:]]+`?(accept|revise|stop)`?' "$verifier" || return 1
  grep -qiE '^[[:space:]-]*(\*\*)?Implementation decision[^[:alnum:]]+`?(fixed|revise|blocked)`?' "$verifier" || return 1
}

verifier_is_complete_for_packets() {
  local unit_id="$1" packets_csv="$2"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  local implement_log="$REMEDIATION_DIR/logs/implement-$unit_id.log"
  verifier_postcheck_invalid "$unit_id" && return 1
  verifier_has_terminal_decision "$unit_id" || return 1
  artifact_mentions_all_packets "$verifier" "$packets_csv" || return 1
  verifier_input_fingerprint_matches "$unit_id" "$packets_csv" || return 1
  if [[ -s "$summary" && "$summary" -nt "$verifier" ]]; then
    return 1
  fi
  if [[ -s "$implement_log" && "$implement_log" -nt "$verifier" ]]; then
    return 1
  fi
  if verifier_has_only_launch_evidence_findings "$unit_id" && unit_evidence_artifacts_newer_than_file "$unit_id" "$verifier"; then
    return 1
  fi
  local packet_id packet_file
  IFS=',' read -ra _verify_packets <<< "$packets_csv"
  for packet_id in "${_verify_packets[@]}"; do
    packet_id="${packet_id#"${packet_id%%[![:space:]]*}"}"
    packet_id="${packet_id%"${packet_id##*[![:space:]]}"}"
    [[ -z "$packet_id" ]] && continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    if [[ -s "$packet_file" && "$packet_file" -nt "$verifier" ]]; then
      return 1
    fi
  done
}

git_root_merge_pathspec_args() {
  local root="$1"
  printf '.\n'
  local rel_rdir
  rel_rdir="$(workspace_root_relative_remediation_dir "$root")"
  if [[ -n "$rel_rdir" ]]; then
    printf ':(exclude)%s\n' "$rel_rdir"
  fi
}

git_root_is_clean_for_merge() {
  local root="$1"
  local -a pathspec=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && pathspec+=("$path")
  done < <(git_root_merge_pathspec_args "$root")
  git -C "$root" diff --quiet -- "${pathspec[@]}" || return 1
  git -C "$root" diff --cached --quiet -- "${pathspec[@]}" || return 1
}

commit_dirty_git_root() {
  local root="$1" message="$2"
  local -a pathspec=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && pathspec+=("$path")
  done < <(git_root_merge_pathspec_args "$root")
  if ! git -C "$root" diff --quiet -- "${pathspec[@]}" || ! git -C "$root" diff --cached --quiet -- "${pathspec[@]}"; then
    git -C "$root" add -A -- "${pathspec[@]}"
    git -C "$root" commit -m "$message" >/dev/null
  fi
}

merge_branch_or_head_into_root() {
  local active_root="$1" source_root="$2" unit_id="$3" label="$4"
  local source_ref
  source_ref="$(git -C "$source_root" rev-parse --verify HEAD)" || return 1
  local source_branch
  source_branch="$(git -C "$source_root" branch --show-current 2>/dev/null || true)"
  local merge_ref="$source_ref"
  if [[ -n "$source_branch" ]] && git -C "$active_root" show-ref --verify --quiet "refs/heads/$source_branch"; then
    merge_ref="$source_branch"
  fi

  if git -C "$active_root" merge-base --is-ancestor "$source_ref" HEAD >/dev/null 2>&1; then
    printf '[worktree-merge] %s:%s already merged\n' "$unit_id" "$label"
    return 0
  fi

  printf '[worktree-merge] %s:%s merging %s\n' "$unit_id" "$label" "$merge_ref"
  if git -C "$active_root" merge --no-edit --no-ff "$merge_ref" -m "Merge remediation worktree for $unit_id ($label)"; then
    return 0
  fi
  git -C "$active_root" merge --abort >/dev/null 2>&1 || true
  printf '[worktree-merge] %s:%s merge failed; active root left unchanged\n' "$unit_id" "$label" >&2
  return 1
}

integrate_unit_worktree_changes() {
  local unit_id="$1"
  local worktree_dir="$REMEDIATION_DIR/worktrees/$unit_id"
  [[ -d "$worktree_dir" ]] || return 0
  if [[ "$worktree_dir" == "$REPO_ROOT" ]]; then
    return 0
  fi

  local recorded_workspace
  recorded_workspace="$(recorded_unit_workspace "$unit_id" 2>/dev/null || true)"
  if [[ -n "$recorded_workspace" && "$recorded_workspace" == "$REPO_ROOT" ]]; then
    if unit_worktree_changed_after_workspace_marker "$unit_id" "$worktree_dir"; then
      printf '[worktree-merge] %s: active workspace was selected, but unit worktree changed during implementation; attempting recovery merge before verification\n' "$unit_id"
    else
      printf '[worktree-merge] %s: active workspace revision; no worktree merge required before verification\n' "$unit_id"
      return 0
    fi
  elif [[ -n "$recorded_workspace" && "$recorded_workspace" != "$worktree_dir" ]]; then
    printf '[worktree-merge] %s: recorded implementation workspace is %s; skipping stale worktree %s\n' \
      "$unit_id" "$recorded_workspace" "$worktree_dir"
    return 0
  fi

  if repo_root_is_git_root; then
    if ! git_root_is_clean_for_merge "$REPO_ROOT"; then
      printf '[worktree-merge] %s: active repo root has uncommitted changes; refusing pre-verify merge\n' "$unit_id" >&2
      return 1
    fi
    commit_dirty_git_root "$worktree_dir" "fix(remediation): integrate $unit_id"
    if ! merge_branch_or_head_into_root "$REPO_ROOT" "$worktree_dir" "$unit_id" "repo"; then
      return 1
    fi
  fi

  local IFS=',' root active_root source_root label
  for root in $REMEDIATION_COMMIT_ROOTS; do
    [[ -n "$root" ]] || continue
    active_root="$(commit_root_path "$root")"
    source_root="$worktree_dir/$root"
    [[ -d "$active_root" && -d "$source_root" ]] || continue
    git -C "$active_root" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1 || continue
    label="$(commit_root_label "$active_root")"
    if ! git_root_is_clean_for_merge "$active_root"; then
      printf '[worktree-merge] %s:%s active git root has uncommitted changes; refusing pre-verify merge\n' "$unit_id" "$label" >&2
      return 1
    fi
    commit_dirty_git_root "$source_root" "fix(remediation): integrate $unit_id ($label)"
    if ! merge_branch_or_head_into_root "$active_root" "$source_root" "$unit_id" "$label"; then
      return 1
    fi
  done
}

integrate_units_before_verification() {
  local units_csv="$1" unit_id failed=0
  local IFS=,
  for unit_id in $units_csv; do
    [[ -n "$unit_id" ]] || continue
    if ! integrate_unit_worktree_changes "$unit_id"; then
      failed=1
    fi
  done
  if [[ "$failed" != "0" ]]; then
    printf '[worktree-merge] one or more unit worktrees could not be merged; refusing verifier rerun against stale active tree\n' >&2
    return 1
  fi
}

commit_verified_unit_changes() {
  [[ "$REMEDIATION_COMMIT_ON_VERIFY" == "1" ]] || return 0
  local unit_id="$1"
  verifier_accepts_unit "$unit_id" || {
    printf '[commit-on-verify] %s: verifier did not accept/fix; not committing\n' "$unit_id"
    return 0
  }

  if ! repo_root_is_git_root; then
    printf '[commit-on-verify] %s: REPO_ROOT is not a git root; auto-commit is disabled in split-root mode\n' "$unit_id"
    return 0
  fi

  local branch_name
  branch_name="$(unit_worktree_branch_name "$unit_id")"
  local worktree_dir="$REMEDIATION_DIR/worktrees/$unit_id"

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch_name"; then
    # Commit changes in the worktree
    if [[ -n "$(git -C "$worktree_dir" status --porcelain)" ]]; then
       git -C "$worktree_dir" add -A
       git -C "$worktree_dir" commit -m "fix(remediation): complete $unit_id" || true
    fi

    printf '[commit-on-verify] %s: merging branch %s\n' "$unit_id" "$branch_name"
    if git -C "$REPO_ROOT" merge --no-edit --no-ff "$branch_name" -m "Merge branch '$branch_name' into HEAD for $unit_id"; then
      printf '[commit-on-verify] %s: successfully merged\n' "$unit_id"
      # Cleanup
      git -C "$REPO_ROOT" worktree remove "$worktree_dir" --force >/dev/null 2>&1 || true
      git -C "$REPO_ROOT" branch -d "$branch_name" >/dev/null 2>&1 || true
    else
      printf '[commit-on-verify] %s: merge conflict on %s\n' "$unit_id" "$branch_name" >&2
      git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
      return 1
    fi
  else
    printf '[commit-on-verify] %s: branch %s not found\n' "$unit_id" "$branch_name" >&2
    return 1
  fi
}

run_implementer_and_test() {
  local prompt_file="$1" workstream="$2" class="$3" worktree_dir="$4" unit_id="$5"

  run_prompt "$prompt_file" "$workstream" "$class" "$worktree_dir"
  local status=$?

  if [[ "$DRY_RUN" == "1" ]]; then
    return "$status"
  fi

  if [[ "$status" == "0" ]]; then
    local group
    group="$(awk -F '\t' -v unit_id="$unit_id" 'NR > 1 && $1 == unit_id { print $3; exit }' "$UNITS_TSV")"
    local test_log="$REMEDIATION_DIR/artifacts/$unit_id-native-test.log"
    local -a test_cmds=()
    local test_cmd
    while IFS= read -r test_cmd; do
      [[ -n "$test_cmd" ]] || continue
      test_cmds+=("$test_cmd")
    done < <(collect_verification_cmds "$unit_id" "$group" "$worktree_dir")

    if ((${#test_cmds[@]} > 0)); then
      : > "$test_log"
      local test_status=0
      local cmd_status=0
      for test_cmd in "${test_cmds[@]}"; do
        if ! command_looks_executable "$test_cmd"; then
          printf '\n[native-test] skipped non-command evidence instruction: %s\n' "$test_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
          printf '\n$ %s\n[native-test] skipped non-command evidence instruction; not executed\n' "$test_cmd" >> "$test_log"
          continue
        fi
        printf '\n[native-test] running: %s\n' "$test_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
        local test_script
        test_script="$REMEDIATION_DIR/artifacts/$unit_id-native-test-$(printf '%s' "$test_cmd" | sha256sum | awk '{print substr($1, 1, 10)}').sh"
        {
          printf '#!/usr/bin/env bash\n'
          printf 'set -euo pipefail\n'
          printf '%s\n' "$test_cmd"
        } > "$test_script"
        chmod +x "$test_script"
        if shell_fragment_is_valid "$test_cmd"; then
          if {
            printf '$ %s\n' "$test_cmd"
            printf '[native-test] script: %s\n' "$test_script"
            (cd "$worktree_dir" && bash "$test_script")
          } >> "$test_log" 2>&1; then
            cmd_status=0
          else
            cmd_status=$?
          fi
        else
          {
            printf '$ %s\n' "$test_cmd"
            printf '[native-test] script: %s\n' "$test_script"
            printf '[native-test] invalid shell fragment; refusing to execute\n'
          } >> "$test_log" 2>&1
          cmd_status=2
        fi
        if [[ "$cmd_status" == "0" ]]; then
          printf '[native-test] passed: %s\n' "$test_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
        else
          local fallback_cmd=""
          if [[ "$REMEDIATION_SANDBOX_PYTEST_FALLBACK" == "1" ]] && \
             pytest_rerunfailures_socket_blocked "$test_log" && \
             fallback_cmd="$(pytest_without_rerunfailures_cmd "$test_cmd" 2>/dev/null)"; then
            printf '[native-test] pytest rerunfailures socket blocked; retrying sandbox fallback: %s\n' \
              "$fallback_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
            local fallback_script
            fallback_script="$REMEDIATION_DIR/artifacts/$unit_id-native-test-fallback-$(printf '%s' "$fallback_cmd" | sha256sum | awk '{print substr($1, 1, 10)}').sh"
            {
              printf '#!/usr/bin/env bash\n'
              printf 'set -euo pipefail\n'
              printf '%s\n' "$fallback_cmd"
            } > "$fallback_script"
            chmod +x "$fallback_script"
            if shell_fragment_is_valid "$fallback_cmd" && {
              printf '\n$ %s\n' "$fallback_cmd"
              printf '[native-test] fallback script: %s\n' "$fallback_script"
              (cd "$worktree_dir" && bash "$fallback_script")
            } >> "$test_log" 2>&1; then
              cmd_status=0
              printf '[native-test] sandbox fallback passed: %s\n' "$fallback_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
            else
              cmd_status=$?
              printf '[native-test] sandbox fallback failed (exit %d): %s\n' "$cmd_status" "$fallback_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
            fi
          fi
          if [[ "$cmd_status" != "0" ]]; then
            printf '[native-test] failed (exit %d): %s\n' "$cmd_status" "$test_cmd" >> "$REMEDIATION_DIR/logs/$workstream.log"
            test_status="$cmd_status"
            break
          fi
        fi
      done
      if [[ "$test_status" != "0" ]]; then
        return "$test_status"
      fi
    else
      printf '\n[native-test] no supported verification commands detected\n' >> "$REMEDIATION_DIR/logs/$workstream.log"
      if [[ -s "$test_log" ]] && ! native_test_log_is_placeholder "$test_log"; then
        printf '[native-test] preserving existing unit-provided evidence artifact: %s\n' "$test_log" >> "$REMEDIATION_DIR/logs/$workstream.log"
      else
        native_test_placeholder_text > "$test_log"
      fi
    fi
  fi
  return "$status"
}

run_prompt() {
  local prompt_file="$1" workstream="$2" class="$3" worktree_dir="${4:-$REPO_ROOT}"
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
      effective_agent="${CATALOG_AGENT:-${IMPLEMENTER_AGENT:-codex}}"
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
  if [[ "$class" =~ ^(cataloger|coordinator|verifier|reviewer)$ ]] && workspace_has_git_roots; then
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
          run_command_with_heartbeat "$workstream" "$log_file" _exec_claude "$prompt_file" "$class" "$worktree_dir"
          status="$?"
          ;;
        gemini)
          run_command_with_heartbeat "$workstream" "$log_file" _exec_gemini "$prompt_file" "$class" "$worktree_dir"
          status="$?"
          ;;
        codex)
          run_command_with_heartbeat "$workstream" "$log_file" _exec_codex "$prompt_file" "$class" "$worktree_dir"
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
      validate_prompt_outputs "$workstream" "$class" "$worktree_dir" || status="$?"
    fi

    if ((status == 0)); then
      break
    fi
    attempt=$((attempt + 1))
  done

  # validate_prompt_outputs and the integrity check run once after the final
  # attempt — retries only fire on runner exit-code failures, not content failures.
  # validate_prompt_outputs now runs inside the retry loop so missing required
  # artifacts from transient runner disconnects are retried like command errors.

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
        readonly_restore_workspace_changes >>"$log_file" 2>&1 || true
        if [[ "$class" != "coordinator" ]]; then
          status=1
        fi
      else
        printf 'Pre-existing product diff was present before %s; not reverting to avoid destroying implementation work.\n' \
          "$workstream" >>"$log_file"
        printf 'Read-only diff attribution is ambiguous because the product tree was already dirty; continuing without reverting.\n' \
          >>"$log_file"
      fi
    fi
    rm -f "$readonly_before_file" "$readonly_after_file"
  fi

  # Auto-recover: if the agent exited non-zero but the summary artifact records
  # a terminal implementation result, the work completed — checkpoint it anyway.
  # This handles rate-limit disconnects and stall-kills where the agent finished
  # writing output before the connection was lost.
  if [[ "$status" != "0" ]] && [[ "$workstream" == implement-* ]]; then
    local unit_id="${workstream#implement-}"
    local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    recover_implementation_summary_from_log "$unit_id" "$log_file" 2>/dev/null || true
    if implementation_summary_is_terminal "$summary"; then
      printf '\n[auto-recover] %s: non-zero exit but terminal IMPLEMENTATION_RESULT summary exists — treating as success\n' \
        "$workstream" >>"$log_file"
      status=0
    fi
  fi
  if [[ "$status" != "0" && "$workstream" == verify-* ]]; then
    local unit_id="${workstream#verify-}"
    if runner_log_has_hard_error "$log_file"; then
      printf '\n[auto-recover] %s: suppressed because verifier log contains a runner/API error\n' \
        "$workstream" >>"$log_file"
    elif verifier_postcheck_invalid "$unit_id"; then
      printf '\n[auto-recover] %s: suppressed because verifier postcheck invalidated the artifact\n' \
        "$workstream" >>"$log_file"
    elif recover_verifier_artifact_from_log "$unit_id" "$log_file"; then
      status=0
    elif verifier_has_terminal_decision "$unit_id"; then
      ensure_verifier_findings_header "$(verifier_findings_tsv_for_unit "$unit_id")"
      printf '\n[auto-recover] %s: verifier artifact has terminal decision — treating verifier job as complete\n' \
        "$workstream" >>"$log_file"
      status=0
    fi
  fi
  if [[ "$status" != "0" && "$class" == "cataloger" ]]; then
    if catalog_outputs_are_ready; then
      printf '\n[auto-recover] %s: catalog outputs exist and the implementation-unit manifest is no longer raw — treating cataloger as complete\n' \
        "$workstream" >>"$log_file"
      status=0
    fi
  fi

  return "$status"
}

wave_job_completed_successfully() {
  local name="$1" log_file="$2"
  if grep -q '^INTEGRITY VIOLATION:' "$log_file" 2>/dev/null && \
     ! grep -q 'Pre-existing product diff was present before' "$log_file" 2>/dev/null; then
    return 1
  fi
  case "$name" in
    plan-*)
      local unit_id="${name#plan-}"
      local design="$REMEDIATION_DIR/artifacts/$unit_id-design.md"
      recover_planner_design_result "$unit_id" "$design" "$log_file" 2>/dev/null || true
      final_result_is_pass "$design" && [[ -s "$design" ]]
      ;;
    implement-*)
      local unit_id="${name#implement-}"
      local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
      implementation_summary_is_terminal "$summary"
      ;;
    verify-*)
      local unit_id="${name#verify-}"
      local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
      runner_log_has_hard_error "$log_file" && return 1
      verifier_postcheck_invalid "$unit_id" && return 1
      recover_verifier_artifact_from_log "$unit_id" "$log_file" || true
      verifier_postcheck_invalid "$unit_id" && return 1
      if verifier_has_terminal_decision "$unit_id"; then
        ensure_verifier_findings_header "$(verifier_findings_tsv_for_unit "$unit_id")"
        return 0
      fi
      final_result_is_terminal "$log_file" && [[ -s "$verifier" ]]
      ;;
    00-cataloger)
      catalog_outputs_are_ready
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
          if [[ "$DRY_RUN" != "1" ]]; then
            printf '%s\n' "${names_ref[$idx]}" >> "$CHECKPOINT_FILE"
            if [[ "${names_ref[$idx]}" == verify-* ]]; then
              if ! commit_verified_unit_changes "${names_ref[$idx]#verify-}"; then
                failed=1
              fi
            fi
          fi
        elif wave_job_completed_successfully "${names_ref[$idx]}" "${job_log[$idx]}"; then
          printf '[ok] %s (auto-recovered after non-zero wave exit)\n' "${names_ref[$idx]}"
          printf '\n[auto-recover] %s: non-zero wave exit but terminal RESULT with required artifact — treating as success\n' \
            "${names_ref[$idx]}" >>"${job_log[$idx]}"
          if [[ "$DRY_RUN" != "1" ]]; then
            printf '%s\n' "${names_ref[$idx]}" >> "$CHECKPOINT_FILE"
            if [[ "${names_ref[$idx]}" == verify-* ]]; then
              if ! commit_verified_unit_changes "${names_ref[$idx]#verify-}"; then
                failed=1
              fi
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
          job_last_change[idx]="$now2"
          job_prev_size[idx]="$size"
        elif [[ "$stall_threshold" -gt 0 ]]; then
          local stall_secs=$(( now2 - job_last_change[idx] ))
          if [[ "$stall_secs" -ge "$stall_threshold" ]] && stall_kill_is_safe "${names_ref[$idx]}" "${job_log[$idx]}"; then
            local elapsed=$(( now2 - job_start[idx] ))
            printf '\r\033[K[!] %s: stalled after %ds - terminating\n' \
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
        local elapsed=$(( now2 - job_start[part_idx] ))
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
  execute_native_test_script_repairs
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
    while IFS=$'\t' read -r f1 f2 f3 f4 _f5 _f6 _f7 f8; do
      local group model_class packets_csv
      local _last_col="${f8:-${f4}}"
      if [[ "$f1" == WS-* ]]; then
        group="$f1"
        model_class="$f3"
        packets_csv="$_last_col"
      else
        group="$f1"
        model_class="$f2"
        packets_csv="$_last_col"
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

  auto_recover_raw_unit_manifest
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
    if [[ "$REVISE_EXISTING" == "1" ]]; then
      if verifier_accepts_unit "$unit_id"; then
        printf '[revise] skipping verifier-accepted unit %s\n' "implement-$unit_id"
        continue
      fi
      if unit_has_split_children "$unit_id" || unit_packets_marked_split_parent "$unit_id"; then
        printf '[revise] skipping decomposed parent unit %s; split children will run instead\n' "implement-$unit_id"
        continue
      fi
      if verifier_has_only_launch_evidence_findings "$unit_id"; then
        printf '[revise] skipping launch-evidence-only unit %s\n' "implement-$unit_id"
        continue
      fi
      if verifier_has_only_coordinator_or_evidence_findings "$unit_id"; then
        printf '[revise] skipping packet/process/evidence-only unit %s\n' "implement-$unit_id"
        continue
      fi
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
        local _findings
        _findings="$(verifier_findings_tsv_for_unit "$unit_id")"
        if [[ -z "$_remaining_packets" ]] && implementation_summary_is_fixed "$_summary" && [[ ! -s "$_findings" ]]; then
          printf '[revise] skipping fixed completed unit %s\n' "implement-$unit_id"
          continue
        fi
        printf '[revise] re-running %s from verifier decision\n' "implement-$unit_id"
      elif [[ -z "$_remaining_packets" ]]; then
        printf '[resume] skipping completed unit %s\n' "implement-$unit_id"
        continue
      else
        # Packets not yet marked complete (verifier hasn't run), but the
        # implementer already ran successfully. Trust the checkpoint and skip
        # rather than re-running the same implementation again.
        printf '[resume] skipping checkpointed unit %s (packets pending verification)\n' "implement-$unit_id"
        continue
      fi
    fi
    local worktree_dir
    if ! worktree_dir="$(prepare_unit_workspace "$unit_id")"; then
      if [[ "$CONTINUE_ON_FAIL" != "1" ]]; then
        exit 1
      fi
      continue
    fi
    record_unit_workspace "$unit_id" "$worktree_dir"

    local prompt="$REMEDIATION_DIR/prompts/implement-$unit_id.md"
    printf '[start] unit=%s group=%s model_class=%s packets=%s\n' "$unit_id" "$group" "$model_class" "$packets_csv"
    record_commit_baseline_for_unit "$unit_id"

    run_implementer_and_test "$prompt" "implement-$unit_id" "$model_class" "$worktree_dir" "$unit_id" &
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
    if grep -qxF "verify-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || [[ "$REVISE_EXISTING" == "1" ]]; then
      if verifier_is_complete_for_packets "$unit_id" "$packets_csv"; then
        if [[ "$FORCE_VERIFY" == "1" ]]; then
          printf '[rerun] verify-%s requested explicitly\n' "$unit_id"
        else
          printf '[resume] skipping completed verify-%s\n' "$unit_id"
          grep -qxF "verify-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "verify-$unit_id" >> "$CHECKPOINT_FILE"
          continue
        fi
      elif grep -qxF "verify-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null; then
        if [[ "$FORCE_VERIFY" == "1" ]]; then
          printf '[rerun] verify-%s requested; checkpoint verifier does not cover merged packets=%s\n' \
            "$unit_id" "$packets_csv"
        else
          printf '[resume] not re-running verify-%s; checkpoint verifier is stale for packets=%s (use --rerun-verifiers to refresh)\n' \
            "$unit_id" "$packets_csv"
          continue
        fi
      fi
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
  decompose_verifier_split_findings
  decompose_oversized_verifier_findings
  aggregate_verifier_findings
}

not_verified_units_from_queue() {
  write_remediation_queue_summary >/dev/null
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || return 0
  local -a units=()
  local unit_id group _model _packets category _count _verifier _findings
  while IFS=$'\t' read -r unit_id group _model _packets category _count _verifier _findings; do
    [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
    unit_selected "$unit_id" || continue
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    [[ "$category" == "not_verified" ]] || continue
    units+=("$unit_id")
  done < "$queue"
  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

metadata_closeout_units_from_queue() {
  write_remediation_queue_summary >/dev/null
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || return 0
  local -a units=()
  local unit_id _group _model _packets category _count _verifier _findings
  while IFS=$'\t' read -r unit_id _group _model _packets category _count _verifier _findings; do
    [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
    unit_selected "$unit_id" || continue
    if [[ -n "$ONLY_GROUP" && "$_group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    [[ "$category" == "coordinator_cleanup" || "$category" == "needs_targeted_revision" ]] || continue
    verifier_has_only_remediation_metadata_findings "$unit_id" || continue
    units+=("$unit_id")
  done < "$queue"
  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

packet_is_native_test_script_repair() {
  local packet_file="$1"
  [[ -s "$packet_file" ]] || return 1
  file_matches 'Primary file or subsystem:[[:space:]]*`?[^`[:space:]]*/artifacts/[^`[:space:]]+-native-test-[^`[:space:]]+\.sh`?' "$packet_file" || return 1
  file_matches 'Regenerate the native-test script|first executable line is the literal sentence|skipped non-command evidence instruction|non-command evidence instruction' "$packet_file"
}

unit_is_native_test_script_repair() {
  local unit_id="$1" packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  [[ -n "$packets_csv" ]] || return 1

  local packet_id packet_file matched=0
  local IFS=,
  for packet_id in $packets_csv; do
    [[ -n "${packet_id:-}" ]] || continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    packet_is_native_test_script_repair "$packet_file" || return 1
    matched=1
  done
  [[ "$matched" == "1" ]]
}

complete_native_test_script_repair_unit() {
  local unit_id="$1" packets_csv
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  [[ -n "$packets_csv" ]] || return 1
  unit_is_native_test_script_repair "$unit_id" || return 1

  local packet_id packet_file
  local IFS=,
  for packet_id in $packets_csv; do
    [[ -n "${packet_id:-}" ]] || continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    [[ -f "$packet_file" ]] || continue
    file_matches 'Status:[[:space:]]*`?complete`?' "$packet_file" && continue
    {
      printf '\n- Status: `complete`\n'
      printf -- '- Deterministic harness repair: current run-remediation native-test collection filters non-command prose and writes executable shell scripts only for supported verification commands.\n'
      printf -- '- Product code change: none; this packet describes remediation-owned stale native-test artifact generation.\n'
    } >> "$packet_file"
  done

  local summary="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
  mkdir -p "$REMEDIATION_DIR/artifacts"
  cat > "$summary" <<EOF
# Implementation Summary: $unit_id

IMPLEMENTATION_RESULT: fixed

## Packet Disposition

- Packets: \`$packets_csv\`
- Result: deterministic harness closeout.

## Changed Files

- Remediation packet metadata under \`$REMEDIATION_DIR/packets/\`.

## Tests / Verification

- Product tests were not run for this closeout because the packet describes a remediation-owned stale native-test script artifact.
- Current \`run-remediation.sh\` filters non-command verifier instructions before writing native-test shell scripts and skips prose instead of executing it.

## Docs / Standards

- Product docs: not applicable.
- Shared standards: not applicable to product code; no product code changed.

## Legacy Cleanup

- Closed the obsolete generated child packet so the runner does not launch an agent to repair a harness artifact that current harness code already prevents.
EOF

  grep -qxF "implement-$unit_id" "$CHECKPOINT_FILE" 2>/dev/null || printf '%s\n' "implement-$unit_id" >> "$CHECKPOINT_FILE"
  printf '[metadata-closeout] %s: deterministically closed native-test script repair packet\n' "$unit_id"
}

execute_native_test_script_repairs() {
  [[ "$REMEDIATION_AUTO_METADATA_CLOSEOUT" == "1" ]] || return 0
  [[ -s "$UNITS_TSV" ]] || return 0

  local unit_id packets_csv _group _model _severity _rationale
  while IFS=$'\t' read -r unit_id packets_csv _group _model _severity _rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    unit_selected "$unit_id" || continue
    if [[ -n "$ONLY_GROUP" && "$_group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    verifier_accepts_unit "$unit_id" && continue
    unit_is_native_test_script_repair "$unit_id" || continue
    complete_native_test_script_repair_unit "$unit_id" || true
  done < <(tail -n +2 "$UNITS_TSV")
}

build_metadata_closeout_prompt() {
  local unit_id="$1"
  local prompt="$REMEDIATION_DIR/prompts/metadata-closeout-$unit_id.md"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  cat > "$prompt" <<PROMPT
# Remediation Metadata Closeout Repair: $unit_id

## Metadata

- Repo root: $REPO_ROOT
- Remediation run: $REMEDIATION_DIR
- Unit: $unit_id

## Task

Repair only remediation-owned closeout metadata for this unit. This is a narrow deterministic hygiene pass.

Allowed edits:

- \`$REMEDIATION_DIR/packets/*.md\`
- \`$REMEDIATION_DIR/artifacts/$unit_id-summary.md\`
- Other files under \`$REMEDIATION_DIR/artifacts/\` only when they are summaries or ledgers for this unit.

Forbidden edits:

- Product source, product docs, tests, migrations, configs, package manifests, lockfiles, or files outside \`$REMEDIATION_DIR\`.
- Any attempt to change implementation behavior.

Make the packet work logs and implementation summary truthful based on the existing verifier and implementation logs. Do not claim launch evidence is complete when findings say it is pending; record it as launch evidence pending.

Verifier findings to resolve:

\`\`\`text
$(cat "$findings")
\`\`\`

Write a short closeout note to \`$REMEDIATION_DIR/artifacts/$unit_id-metadata-closeout.md\` describing the remediation-owned metadata files updated.
PROMPT
}

execute_metadata_closeout_repairs() {
  [[ "$REMEDIATION_AUTO_METADATA_CLOSEOUT" == "1" ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  local units
  units="$(metadata_closeout_units_from_queue)"
  [[ -n "$units" ]] || return 0
  printf '[metadata-closeout] units=%s\n' "$units"

  local previous_only="$ONLY_UNIT"
  local previous_force_verify="$FORCE_VERIFY"
  local unit_id
  local IFS=,
  for unit_id in $units; do
    [[ -n "$unit_id" ]] || continue
    build_metadata_closeout_prompt "$unit_id"
    if ! run_prompt "$REMEDIATION_DIR/prompts/metadata-closeout-$unit_id.md" "metadata-closeout-$unit_id" "standard" "$REPO_ROOT"; then
      printf '[metadata-closeout] %s failed; leaving unit for normal revision\n' "$unit_id" >&2
    fi
  done
  ONLY_UNIT="$units"
  FORCE_VERIFY=1
  execute_verifier_units
  ONLY_UNIT="$previous_only"
  FORCE_VERIFY="$previous_force_verify"
}

execute_missing_verifiers_from_queue() {
  [[ "$REMEDIATION_AUTO_VERIFY_MISSING" == "1" ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  local units
  units="$(not_verified_units_from_queue)"
  [[ -n "$units" ]] || return 0
  printf '[missing-verifier] units=%s\n' "$units"
  local previous_only="$ONLY_UNIT"
  local previous_force_verify="$FORCE_VERIFY"
  ONLY_UNIT="$units"
  FORCE_VERIFY=1
  execute_verifier_units
  ONLY_UNIT="$previous_only"
  FORCE_VERIFY="$previous_force_verify"
}

execute_final_review() {
  local final_review="$REMEDIATION_DIR/prompts/99-final-review.md"
  aggregate_verifier_findings
  if grep -qxF "99-final-review" "$CHECKPOINT_FILE" 2>/dev/null; then
    if final_review_input_fingerprint_matches; then
      if [[ "$FORCE_FINAL_REVIEW" == "1" ]]; then
        printf '[rerun] 99-final-review requested explicitly\n'
      else
        printf '[resume] skipping completed 99-final-review\n'
        return 0
      fi
    elif [[ "$FORCE_FINAL_REVIEW" == "1" || "$REMEDIATION_AUTO_RERUN_FINAL_REVIEW" == "1" ]]; then
      printf '[rerun] 99-final-review inputs changed since prior final review\n'
    else
      printf '[resume] not re-running 99-final-review; checkpoint inputs changed (use --rerun-final-review to refresh)\n'
      return 0
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
      remove_checkpoint_entry "99-final-review"
    fi
  fi
  printf '[final-review] %s\n' "$final_review"
  if run_prompt "$final_review" "99-final-review" "reviewer"; then
    if [[ "$DRY_RUN" != "1" ]]; then
      write_final_review_input_fingerprint
      printf '%s\n' "99-final-review" >> "$CHECKPOINT_FILE"
    fi
  fi
}

execute_verifiers() {
  run_static_prechecks
  execute_verifier_units
  execute_native_test_script_repairs
  execute_metadata_closeout_repairs
  execute_missing_verifiers_from_queue
  execute_evidence_collection_rounds
  execute_final_review
}

execute_state_resume() {
  printf '[resume] deriving next action from existing remediation state\n'
  run_static_prechecks
  aggregate_verifier_findings

  execute_native_test_script_repairs
  execute_missing_verifiers_from_queue
  execute_metadata_closeout_repairs
  execute_evidence_collection_rounds

  if grep -qxF "99-final-review" "$CHECKPOINT_FILE" 2>/dev/null; then
    execute_final_review
    return 0
  fi

  if find "$REMEDIATION_DIR/artifacts" -maxdepth 1 -name 'verify-*.md' -print -quit 2>/dev/null | grep -q .; then
    printf '[resume] final review checkpoint missing; verifier artifacts exist, so running final review only\n'
    execute_final_review
    return 0
  fi

  printf '[resume] no final-review checkpoint and no verifier artifacts; generated summary/queue only\n'
  printf '[resume] use --execute, --verify-only, or --rerun-verifiers for an explicit agent section\n'
}

execute_queue_drain() {
  local max_rounds="$QUEUE_DRAIN_MAX_ROUNDS"
  [[ "$max_rounds" =~ ^[0-9]+$ ]] || max_rounds=20

  run_static_prechecks
  aggregate_verifier_findings
  decompose_verifier_split_findings
  decompose_oversized_verifier_findings
  execute_native_test_script_repairs
  write_remediation_queue_summary >/dev/null

  local round=1 evidence_attempted=0 stalled_action_keys=$'\n'
  while :; do
    if (( max_rounds > 0 && round > max_rounds )); then
      printf '[drain-queue] max rounds reached: %s\n' "$max_rounds"
      break
    fi

    local before_signature
    before_signature="$(queue_action_signature)"

    local units action="" action_key=""
    units="$(not_verified_units_from_queue)"
    action_key="not_verified:$units"
    if [[ -n "$units" ]] && ! drain_action_was_stalled "$stalled_action_keys" "$action_key"; then
      action="not_verified"
      printf '[drain-queue] round=%s action=verify-missing units=%s\n' "$round" "$units"
      if [[ "$DRY_RUN" == "1" ]]; then
        break
      fi
      local previous_only="$ONLY_UNIT"
      local previous_force_verify="$FORCE_VERIFY"
      ONLY_UNIT="$units"
      FORCE_VERIFY=1
      execute_verifier_units
      ONLY_UNIT="$previous_only"
      FORCE_VERIFY="$previous_force_verify"
    else
      units="$(revise_next_units_from_queue)"
      action_key="needs_targeted_revision:$units"
      if [[ -n "$units" ]] && ! drain_action_was_stalled "$stalled_action_keys" "$action_key"; then
        action="needs_targeted_revision"
        printf '[drain-queue] round=%s action=revise units=%s\n' "$round" "$units"
        if [[ "$DRY_RUN" == "1" ]]; then
          break
        fi
        execute_revise_next_batch "$units"
      else
        units="$(pending_split_child_units)"
        action_key="split_children_pending:$units"
        if [[ -n "$units" ]] && ! drain_action_was_stalled "$stalled_action_keys" "$action_key"; then
          action="split_children_pending"
          printf '[drain-queue] round=%s action=split-children units=%s\n' "$round" "$units"
          if [[ "$DRY_RUN" == "1" ]]; then
            break
          fi
          execute_split_child_units_batch "$units"
        elif [[ "$evidence_attempted" == "0" ]] && ! drain_action_was_stalled "$stalled_action_keys" "evidence:*"; then
          action="evidence"
          action_key="evidence:*"
          evidence_attempted=1
          printf '[drain-queue] round=%s action=evidence\n' "$round"
          if [[ "$DRY_RUN" == "1" ]]; then
            break
          fi
          execute_metadata_closeout_repairs
          execute_evidence_collection_rounds
        fi
      fi
    fi

    if [[ -z "$action" ]]; then
      printf '[drain-queue] no deterministic queue actions remain\n'
      break
    fi

    write_remediation_queue_summary >/dev/null
    local after_signature
    after_signature="$(queue_action_signature)"
    printf '[drain-queue] round=%s action=%s complete\n' "$round" "$action"
    if [[ "$after_signature" == "$before_signature" ]]; then
      stalled_action_keys+="$action_key"$'\n'
      printf '[drain-queue] action=%s did not change queue signature; marking action stalled and checking lower-priority deterministic actions\n' "$action"
    fi

    round=$((round + 1))
  done

  execute_final_review
}

revise_next_units_from_queue() {
  write_remediation_queue_summary >/dev/null
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || return 0

  local -a units=()
  local unit_id group _model _packets category finding_count _verifier _findings
  while IFS=$'	' read -r unit_id group _model _packets category finding_count _verifier _findings; do
    [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
    [[ "$category" == "needs_targeted_revision" ]] || continue
    [[ "$finding_count" =~ ^[0-9]+$ ]] || continue
    (( finding_count > 0 && finding_count <= MAX_AUTO_REVISE_FINDINGS )) || continue
    if ! unit_selected "$unit_id"; then
      continue
    fi
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    units+=("$unit_id")
    if [[ "$REVISE_NEXT_LIMIT" =~ ^[0-9]+$ ]] && (( REVISE_NEXT_LIMIT > 0 && ${#units[@]} >= REVISE_NEXT_LIMIT )); then
      break
    fi
  done < "$queue"

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

queue_category_count() {
  local category="$1"
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' -v category="$category" 'NR > 1 && $5 == category { count += 1 } END { printf "%d\n", count + 0 }' "$queue"
}

queue_category_findings_sum() {
  local category="$1"
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' -v category="$category" '
    NR > 1 && $5 == category && $6 ~ /^[0-9]+$/ { count += $6 }
    END { printf "%d\n", count + 0 }
  ' "$queue"
}

queue_units_for_category() {
  local category="$1"
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || return 0
  awk -F '\t' -v category="$category" 'NR > 1 && $5 == category { print $1 }' "$queue" | paste -sd, -
}

queue_units_for_category_selected() {
  local category="$1"
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || return 0

  local -a units=()
  local unit_id group _model _packets row_category _count _verifier _findings
  while IFS=$'\t' read -r unit_id group _model _packets row_category _count _verifier _findings; do
    [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
    [[ "$row_category" == "$category" ]] || continue
    unit_selected "$unit_id" || continue
    if [[ -n "$ONLY_GROUP" && "$group" != "$ONLY_GROUP" ]]; then
      continue
    fi
    units+=("$unit_id")
  done < "$queue"

  if ((${#units[@]} > 0)); then
    local IFS=,
    printf '%s' "${units[*]}"
  fi
}

queue_action_signature() {
  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  [[ -s "$queue" ]] || {
    printf 'missing\n'
    return 0
  }
  awk -F '\t' '
    NR > 1 {
      finding_count = ($6 ~ /^[0-9]+$/) ? $6 : 0
      printf "%s:%s/%d\n", $5, $1, finding_count
    }
  ' "$queue" | sort | paste -sd ';' -
}

drain_action_was_stalled() {
  local stalled_keys="$1" action_key="$2"
  [[ "$stalled_keys" == *$'\n'"$action_key"$'\n'* ]]
}

execute_revise_next_batch() {
  local revised_units="$1"
  local previous_only="$ONLY_UNIT"
  local previous_revise="$REVISE_EXISTING"
  local previous_parallel="$MAX_PARALLEL"
  local previous_force_verify="$FORCE_VERIFY"

  ONLY_UNIT="$revised_units"
  REVISE_EXISTING=1
  FORCE_VERIFY=1
  MAX_PARALLEL="${REMEDIATION_REVISION_MAX_PARALLEL:-2}"
  if workspace_has_child_git_roots; then
    MAX_PARALLEL=1
    printf '[revise-next] split-root workspace detected; forcing serialized active-workspace revision\n'
  fi

  execute_workstreams
  integrate_units_before_verification "$revised_units"
  run_static_prechecks
  execute_verifier_units
  execute_metadata_closeout_repairs
  aggregate_verifier_findings

  ONLY_UNIT="$previous_only"
  REVISE_EXISTING="$previous_revise"
  FORCE_VERIFY="$previous_force_verify"
  MAX_PARALLEL="$previous_parallel"
}

execute_split_child_units_batch() {
  local child_units="$1"
  [[ -n "$child_units" ]] || return 0

  local previous_only="$ONLY_UNIT"
  local previous_revise="$REVISE_EXISTING"
  local previous_parallel="$MAX_PARALLEL"
  local previous_force_verify="$FORCE_VERIFY"
  local batch_marker
  batch_marker="$(mktemp)"
  touch "$batch_marker"

  ONLY_UNIT="$child_units"
  REVISE_EXISTING=1
  FORCE_VERIFY=1
  MAX_PARALLEL="${SPLIT_CHILD_MAX_PARALLEL:-1}"

  printf '[drain-queue] executing split child units=%s\n' "$child_units"
  execute_workstreams

  local implemented_units=""
  local IFS=, unit_id marker
  for unit_id in $child_units; do
    [[ -n "$unit_id" ]] || continue
    marker="$(unit_workspace_marker_file "$unit_id")"
    if [[ -s "$marker" && "$marker" -nt "$batch_marker" ]]; then
      implemented_units="$(combine_unit_lists "$implemented_units" "$unit_id")"
    fi
  done
  rm -f "$batch_marker"

  if [[ -n "$implemented_units" ]]; then
    integrate_units_before_verification "$implemented_units"
    ONLY_UNIT="$(combine_unit_lists "$implemented_units" "$(queue_units_for_category_selected "not_verified")")"
    run_static_prechecks
    execute_verifier_units
    execute_metadata_closeout_repairs
    aggregate_verifier_findings
  else
    printf '[drain-queue] no split child units were implemented in this batch; skipping worktree merge and child verification\n'
  fi

  ONLY_UNIT="$previous_only"
  REVISE_EXISTING="$previous_revise"
  FORCE_VERIFY="$previous_force_verify"
  MAX_PARALLEL="$previous_parallel"
}

execute_revise_next() {
  local max_rounds="$REVISE_NEXT_MAX_ROUNDS"
  [[ "$max_rounds" =~ ^[0-9]+$ ]] || max_rounds=10

  local round=1
  while :; do
    if (( max_rounds > 0 && round > max_rounds )); then
      printf '[revise-next] max rounds reached: %s\n' "$max_rounds"
      return 0
    fi

    local revised_units
    revised_units="$(revise_next_units_from_queue)"
    if [[ -z "$revised_units" ]]; then
      printf '[revise-next] no safe needs_targeted_revision units found in current queue\n'
      printf '[revise-next] blocked, contract_conflict, test_harness, split, evidence, and oversized finding sets were left untouched\n'
      return 0
    fi

    local before_needs
    before_needs="$(queue_category_count "needs_targeted_revision")"
    local before_need_findings
    before_need_findings="$(queue_category_findings_sum "needs_targeted_revision")"

    printf '[revise-next] round=%s limit=%s needs_targeted_revision=%s units=%s\n' \
      "$round" "$REVISE_NEXT_LIMIT" "$before_needs" "$revised_units"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '[revise-next] dry-run: selected safe revision units only; no agents launched\n'
      return 0
    fi

    execute_revise_next_batch "$revised_units"
    write_remediation_queue_summary >/dev/null

    local after_needs
    after_needs="$(queue_category_count "needs_targeted_revision")"
    local after_need_findings
    after_need_findings="$(queue_category_findings_sum "needs_targeted_revision")"
    printf '[revise-next] round=%s complete needs_targeted_revision=%s unresolved_findings=%s\n' \
      "$round" "$after_needs" "$after_need_findings"
    if (( after_needs >= before_needs && after_need_findings >= before_need_findings )); then
      printf '[revise-next] stopping: needs_targeted_revision did not improve after batch (count before=%s after=%s, findings before=%s after=%s)\n' \
        "$before_needs" "$after_needs" "$before_need_findings" "$after_need_findings"
      printf '[revise-next] remaining needs_targeted_revision units=%s\n' \
        "$(queue_units_for_category "needs_targeted_revision")"
      return 0
    fi
    round=$((round + 1))
  done
}

execute_revision_rounds() {
  if [[ "$AUTO_REVISE" != "1" || "$EXECUTE" != "1" || "$VERIFY" != "1" || "$VERIFY_SCOPE" != "implementation" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  local user_selected_units="$ONLY_UNIT"
  if [[ -z "$user_selected_units" ]]; then
    guard_against_auto_revise_raw_unit_manifest
  fi

  execute_native_test_script_repairs

  local round=1
  while ((round <= MAX_REVISION_ROUNDS)); do
    aggregate_verifier_findings
    decompose_verifier_split_findings
    decompose_oversized_verifier_findings
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
    if workspace_has_child_git_roots; then
      MAX_PARALLEL=1
      printf '[auto-revise] split-root workspace detected; forcing serialized active-workspace revision\n'
    fi

    execute_workstreams
    run_static_prechecks
    execute_verifier_units
    execute_metadata_closeout_repairs
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

collect_evidence_units_from_findings() {
  [[ -d "$REMEDIATION_DIR/artifacts" ]] || return 0
  {
    local file unit_id
    find "$REMEDIATION_DIR/artifacts" -maxdepth 1 -name 'verify-*-findings.tsv' -print 2>/dev/null |
      sort |
      while IFS= read -r file; do
        unit_id="$(basename "$file")"
        unit_id="${unit_id#verify-}"
        unit_id="${unit_id%-findings.tsv}"
        unit_selected "$unit_id" || continue
        awk -F '\t' 'NR > 1 && ($3 == "launch_evidence" || $3 == "sandbox_blocked") && $1 != "" { print $1 }' "$file"
      done

    local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
    if [[ -s "$queue" ]]; then
      while IFS=$'\t' read -r unit_id _group _model _packets category _count _verifier _findings; do
        [[ "$unit_id" == "unit_id" || -z "${unit_id:-}" ]] && continue
        [[ "$category" == "evidence_failed" ]] || continue
        unit_selected "$unit_id" || continue
        printf '%s\n' "$unit_id"
      done < "$queue"
    fi
  } | awk '!seen[$0]++'
}

failed_evidence_commands_for_unit() {
  local unit_id="$1"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  [[ -d "$unit_dir" ]] || return 0

  local status_file status command
  while IFS= read -r status_file; do
    [[ -f "$status_file" ]] || continue
    status="$(awk -F ': ' 'toupper($1) == "STATUS" { print tolower($2); exit }' "$status_file")"
    [[ "$status" == "fail" ]] || continue
    command="$(awk -F ': ' 'toupper($1) == "COMMAND" { sub(/^[^:]+: /, ""); print; exit }' "$status_file")"
    [[ -n "$command" ]] && printf '%s\n' "$command"
  done < <(find "$unit_dir" -type f -name '*.status' -print 2>/dev/null | sort)

  local summary_json
  while IFS= read -r summary_json; do
    [[ -f "$summary_json" ]] || continue
    python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)

command = str(payload.get("command") or "").strip()
if not command:
    raise SystemExit(0)

status = str(payload.get("status", "")).strip().upper()
proof_files = payload.get("proof_files") or []
missing_proofs = []
for proof in proof_files:
    proof_path = pathlib.Path(str(proof))
    if not proof_path.is_absolute():
        proof_path = path.parent / proof_path
    if not proof_path.is_file():
        missing_proofs.append(str(proof))

if status != "PASS" or missing_proofs:
    print(command)
PY
  done < <(find "$unit_dir" -mindepth 2 -maxdepth 3 -name 'summary.json' -print 2>/dev/null | sort)
}

run_logged_evidence_script() {
  local unit_id="$1" run_script="$2" log_file="$3"

  (
    cd "$REPO_ROOT"
    bash "$run_script"
  ) >> "$log_file" 2>&1 &

  local pid="$!"
  local start now elapsed spinner_index spinner_chars spinner_char log_bytes
  start="$(date +%s)"
  spinner_index=0
  spinner_chars='-\|/'

  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start))
    spinner_char="${spinner_chars:spinner_index:1}"
    spinner_index=$(((spinner_index + 1) % ${#spinner_chars}))
    log_bytes="$(wc -c < "$log_file" 2>/dev/null || printf '0')"
    if [[ -t 2 ]]; then
      local columns line max_line
      columns="$(tput cols 2>/dev/null || printf '120')"
      [[ "$columns" =~ ^[0-9]+$ ]] || columns=120
      ((columns < 40)) && columns=40
      max_line=$((columns - 1))
      line="$(printf '[%s] evidence:%s (%ss) log_bytes=%s log=%s' \
        "$spinner_char" "$unit_id" "$elapsed" "$log_bytes" "$log_file")"
      if ((${#line} > max_line)); then
        line="${line:0:$((max_line - 3))}..."
      fi
      printf '\r\033[2K%s' "$line" >&2
    elif (( elapsed > 0 && elapsed % 60 == 0 )); then
      printf '[evidence] running:%s elapsed=%ss log_bytes=%s log=%s\n' \
        "$unit_id" "$elapsed" "$log_bytes" "$log_file" >&2
    fi
    sleep 1
  done

  if [[ -t 2 ]]; then
    printf '\r\033[2K' >&2
  fi

  wait "$pid"
}

run_evidence_command() {
  local unit_id="$1" command="$2" label="$3"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  local safe_label log_file status_file run_script wrapped_command
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-//; s/-$//')"
  [[ -n "$safe_label" ]] || safe_label="evidence"
  mkdir -p "$unit_dir"
  log_file="$unit_dir/${safe_label}.log"
  status_file="$unit_dir/${safe_label}.status"
  wrapped_command="$command"
  if [[ "$wrapped_command" == "cd backend && pytest backend/tests"* ]]; then
    wrapped_command="cd backend && pytest tests${wrapped_command#cd backend && pytest backend/tests}"
  fi
  if [[ "$wrapped_command" == "cd frontend && "*"/frontend/"* ]]; then
    wrapped_command="${wrapped_command//\/frontend\//\/}"
  fi
  if [[ "$command" == *"playwright"* || "$command" == *"test:e2e"* || "$command" == *"browser-evidence"* || "$command" == *"lighthouse"* ]]; then
    if unit_has_passing_summary_artifact "$unit_id"; then
      {
        printf 'STATUS: pass\n'
        printf 'COMMAND: %s\n' "$command"
        printf 'LOG: reused summary artifact under %s\n' "$unit_dir"
        printf 'FINISHED_AT: %s\n' "$(date -Is)"
      } > "$status_file"
      printf '[evidence] %s: pass (reused summary artifact): %s\n' "$unit_id" "$command"
      return 0
    fi
  fi
  if [[ "$command" == *" -m postgres"* && -z "${MERIDIAN_TEST_ALEMBIC_POSTGRES_URL:-}" && -x "$REPO_ROOT/scripts/dev-postgres" ]]; then
    wrapped_command="./scripts/dev-postgres bootstrap && export MERIDIAN_TEST_ALEMBIC_POSTGRES_URL=\"\${MERIDIAN_TEST_ALEMBIC_POSTGRES_URL:-postgresql://meridian:meridian@127.0.0.1:5432/meridian_test}\" && $command"
  fi
  if [[ "$command" == *"playwright"* || "$command" == *"test:e2e"* || "$command" == *"browser-evidence"* || "$command" == *"lighthouse"* ]]; then
    local journey_slug audit_artifact_dir skip_runtime_quality
    journey_slug="$safe_label"
    audit_artifact_dir="$unit_dir/$journey_slug"
    skip_runtime_quality=0
    [[ "$REMEDIATION_EVIDENCE_MODE" == "targeted" ]] && skip_runtime_quality=1
    wrapped_command="set -a; [ -f docs/ux/.creds ] && . docs/ux/.creds; set +a; export E2E_EMAIL=\"\${E2E_EMAIL:-\${email:-}}\" E2E_PASSWORD=\"\${E2E_PASSWORD:-\${password:-}}\" E2E_BASE_URL=\"\${E2E_BASE_URL:-\${url:-}}\" E2E_API_BASE=\"\${E2E_API_BASE:-\${api_url:-}}\" PORTAL_AUDIT_RUN_DIR=\"$REMEDIATION_DIR\" PORTAL_AUDIT_JOB_ID=\"$unit_id\" PORTAL_AUDIT_JOURNEY_SLUG=\"$journey_slug\" PORTAL_AUDIT_ARTIFACT_DIR=\"$audit_artifact_dir\" PORTAL_AUDIT_EVIDENCE_MODE=\"$REMEDIATION_EVIDENCE_MODE\" PORTAL_AUDIT_SKIP_RUNTIME_QUALITY=\"\${PORTAL_AUDIT_SKIP_RUNTIME_QUALITY:-$skip_runtime_quality}\"; if [[ -n \"\${E2E_BASE_URL:-}\" && \"\$E2E_BASE_URL\" != http://* && \"\$E2E_BASE_URL\" != https://* ]]; then export E2E_BASE_URL=\"https://\$E2E_BASE_URL\"; fi; if [[ -z \"\${E2E_API_BASE:-}\" && \"\$E2E_BASE_URL\" =~ ^https?://([^/:]+)(:[0-9]+)?/?$ && \"\${BASH_REMATCH[1]}\" != localhost && \"\${BASH_REMATCH[1]}\" != 127.* ]]; then export E2E_API_BASE=\"https://api-\${BASH_REMATCH[1]}\"; fi; $wrapped_command"
  fi

  run_script="$(mktemp "$unit_dir/${safe_label}.XXXXXX.sh")"
  chmod 700 "$run_script"
  {
    printf 'set -o pipefail\n'
    printf '%s\n' "$wrapped_command"
  } > "$run_script"

  {
    printf 'COMMAND: %s\n' "$command"
    printf 'WRAPPED_COMMAND: %s\n' "$wrapped_command"
    printf 'RUN_SCRIPT: %s\n' "$run_script"
    printf 'STARTED_AT: %s\n\n' "$(date -Is)"
  } > "$log_file"

  if ! bash -n "$run_script" >> "$log_file" 2>&1; then
    {
      printf 'STATUS: fail\n'
      printf 'COMMAND: %s\n' "$command"
      printf 'LOG: %s\n' "$log_file"
      printf 'FINISHED_AT: %s\n' "$(date -Is)"
    } > "$status_file"
    printf '[evidence] %s: failed shell validation: %s (see %s)\n' "$unit_id" "$command" "$log_file" >&2
    return 1
  fi

  if run_logged_evidence_script "$unit_id" "$run_script" "$log_file"; then
    {
      printf 'STATUS: pass\n'
      printf 'COMMAND: %s\n' "$command"
      printf 'LOG: %s\n' "$log_file"
      printf 'FINISHED_AT: %s\n' "$(date -Is)"
    } > "$status_file"
    printf '[evidence] %s: pass: %s\n' "$unit_id" "$command"
    return 0
  fi

  {
    printf 'STATUS: fail\n'
    printf 'COMMAND: %s\n' "$command"
    printf 'LOG: %s\n' "$log_file"
    printf 'FINISHED_AT: %s\n' "$(date -Is)"
  } > "$status_file"
  printf '[evidence] %s: failed: %s (see %s)\n' "$unit_id" "$command" "$log_file" >&2
  return 1
}

evidence_command_label() {
  local unit_id="$1" command="$2" slug hash
  slug="$(printf '%s' "$command" | awk '{ print $1 "-" $2 "-" $3 "-" $4 "-" $5 }')"
  slug="$(printf '%s' "$slug" | tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-//; s/-$//')"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$command" | sha256sum | awk '{ print substr($1, 1, 10) }')"
  else
    hash="$(printf '%s' "$command" | cksum | awk '{ print $1 }')"
  fi
  printf '%s-%s-%s\n' "$unit_id" "${slug:-evidence}" "$hash"
}

run_evidence_audit_job() {
  local unit_id="$1" job_id="$2"
  local unit_dir="$REMEDIATION_DIR/artifacts/$unit_id"
  local log_file status_file
  mkdir -p "$unit_dir"
  log_file="$unit_dir/audit-$job_id.log"
  status_file="$unit_dir/audit-$job_id.status"

  {
    printf 'COMMAND: %s\n' "PROFILE=${PROFILE:-} REPO_ROOT=$REPO_ROOT RUN_DIR=$AUDIT_RUN RUNNER=${REVIEWER_AGENT:-${IMPLEMENTER_AGENT:-codex}} MAX_PARALLEL=1 AUDIT_STALL_INTERVALS=${AUDIT_STALL_INTERVALS:-30} $SCRIPT_DIR/run-audit.sh --only $job_id"
    printf 'STARTED_AT: %s\n\n' "$(date -Is)"
  } > "$log_file"

  if (
    cd "$REPO_ROOT"
    PROFILE="${PROFILE:-}" \
    REPO_ROOT="$REPO_ROOT" \
    RUN_DIR="$AUDIT_RUN" \
    RUNNER="${REVIEWER_AGENT:-${IMPLEMENTER_AGENT:-codex}}" \
    MAX_PARALLEL=1 \
    AUDIT_STALL_INTERVALS="${AUDIT_STALL_INTERVALS:-30}" \
    "$SCRIPT_DIR/run-audit.sh" --only "$job_id"
  ) >> "$log_file" 2>&1; then
    {
      printf 'STATUS: pass\n'
      printf 'JOB: %s\n' "$job_id"
      printf 'LOG: %s\n' "$log_file"
      printf 'FINISHED_AT: %s\n' "$(date -Is)"
    } > "$status_file"
    printf '[evidence] %s: audit job pass: %s\n' "$unit_id" "$job_id"
    return 0
  fi

  {
    printf 'STATUS: fail\n'
    printf 'JOB: %s\n' "$job_id"
    printf 'LOG: %s\n' "$log_file"
    printf 'FINISHED_AT: %s\n' "$(date -Is)"
  } > "$status_file"
  printf '[evidence] %s: audit job failed: %s (see %s)\n' "$unit_id" "$job_id" "$log_file" >&2
  return 1
}

collect_launch_evidence_once() {
  aggregate_verifier_findings
  local units_csv
  units_csv="$(collect_evidence_units_from_findings | paste -sd, -)"
  [[ -n "$units_csv" ]] || return 1

  local ran=0 failed=0 unit_id findings_file
  local IFS=,
  for unit_id in $units_csv; do
    findings_file="$(verifier_findings_tsv_for_unit "$unit_id")"
    [[ -s "$findings_file" ]] || continue
    local tmp_commands tmp_jobs
    tmp_commands="$(mktemp)"
    tmp_jobs="$(mktemp)"
    awk -F '\t' 'NR > 1 && ($3 == "launch_evidence" || $3 == "sandbox_blocked") { print $4 "\t" $6 "\t" $7 }' "$findings_file" |
      while IFS=$'\t' read -r file finding required_fix; do
        local command job text
        command="$(evidence_command_for_finding "$file" "$finding" "$required_fix" || true)"
        if [[ -n "$command" ]] && evidence_command_is_allowed "$command"; then
          printf '%s\n' "$command" >> "$tmp_commands"
        fi
        text="$file $finding $required_fix"
        job="$(audit_job_for_evidence_finding "$text" || true)"
        [[ -n "$job" ]] && printf '%s\n' "$job" >> "$tmp_jobs"
      done

    while IFS= read -r command; do
      [[ -n "$command" ]] || continue
      if evidence_command_is_allowed "$command"; then
        printf '%s\n' "$command" >> "$tmp_commands"
      fi
    done < <(failed_evidence_commands_for_unit "$unit_id")

    while IFS= read -r command; do
      [[ -n "$command" ]] || continue
      ran=1
      if ! run_evidence_command "$unit_id" "$command" "$(evidence_command_label "$unit_id" "$command")"; then
        failed=1
      fi
    done < <(sort -u "$tmp_commands")

    while IFS= read -r job; do
      [[ -n "$job" ]] || continue
      ran=1
      if ! run_evidence_audit_job "$unit_id" "$job"; then
        failed=1
      fi
    done < <(sort -u "$tmp_jobs")

    rm -f "$tmp_commands" "$tmp_jobs"
  done

  [[ "$ran" == "1" ]] || return 1
  [[ "$failed" == "0" ]]
}

execute_evidence_collection_rounds() {
  if [[ "$REMEDIATION_COLLECT_EVIDENCE" != "1" || "$VERIFY_SCOPE" != "implementation" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  local round=1
  while ((round <= REMEDIATION_EVIDENCE_MAX_ROUNDS)); do
    local evidence_units
    evidence_units="$(collect_evidence_units_from_findings | paste -sd, -)"
    [[ -n "$evidence_units" ]] || return 0

    printf '[evidence] round=%s units=%s\n' "$round" "$evidence_units"
    if ! collect_launch_evidence_once; then
      printf '[evidence] deterministic evidence collection incomplete; leaving remaining items in queue\n' >&2
      return 0
    fi

    local previous_only="$ONLY_UNIT"
    local previous_revise="$REVISE_EXISTING"
    ONLY_UNIT="$evidence_units"
    REVISE_EXISTING=1
    execute_verifier_units
    aggregate_verifier_findings
    ONLY_UNIT="$previous_only"
    REVISE_EXISTING="$previous_revise"
    round=$((round + 1))
  done
}

if [[ "$EXECUTE" == "0" && "$VERIFY" == "0" && "$VERIFY_ONLY" == "0" && \
      "$FINALIZE_ONLY" == "0" && "$SUMMARY_ONLY" == "0" && \
      "$REVISE_EXISTING" == "0" && "$REVISE_NEXT" == "0" && "$DRAIN_QUEUE" == "0" && "$SPLIT_INCOMPLETE" == "0" && \
      "$CATALOG_WITH_CODEX" == "0" && "$FORCE_CATALOG" == "0" && \
      "$RECOORDINATE" == "0" ]] && remediation_state_exists; then
  STATE_RESUME=1
fi

if [[ "$STATE_RESUME" != "1" && "$VERIFY_ONLY" != "1" && "$FINALIZE_ONLY" != "1" && "$SUMMARY_ONLY" != "1" && "$REVISE_EXISTING" != "1" && "$REVISE_NEXT" != "1" && "$DRAIN_QUEUE" != "1" ]]; then
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
    dedupe_findings_into_blocker_ledger
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
          purge_orphaned_packets
        else
          printf '[fail] 00-cataloger (see %s/logs/00-cataloger.log)\n' "$REMEDIATION_DIR" >&2
          exit 1
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
          purge_orphaned_packets
        else
          printf '[fail] 00-cataloger (see %s/logs/00-cataloger.log)\n' "$REMEDIATION_DIR" >&2
          exit 1
        fi
      fi
    fi
  elif [[ "$EXECUTE" == "1" && "$NO_CATALOG" != "1" && "$FORCE_CATALOG" != "1" && -s "$UNITS_TSV" && -s "$WORKSTREAMS_TSV" ]]; then
    printf '[resume] existing catalog detected; not auto-running 00-cataloger (use --force-catalog to rewrite)\n'
  fi
elif [[ ! -f "$WORKSTREAMS_TSV" || ! -f "$PX_TSV" || ! -f "$UNITS_TSV" ]]; then
  echo "--verify-only/--finalize-only/--summary-only/--revise-existing requires an existing REMEDIATION_DIR with $PX_TSV, $WORKSTREAMS_TSV, and $UNITS_TSV" >&2
  exit 2
fi

normalize_units_tsv
build_implemented_packet_set 0
if [[ "$REVISE_NEXT" != "1" && "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
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
elif [[ "$REVISE_EXISTING" != "1" && "$REVISE_NEXT" != "1" && "$AUTO_SPLIT_BEFORE_EXECUTE" == "1" && "$VERIFY_ONLY" != "1" && ( "$EXECUTE" == "1" || "$DRY_RUN" == "1" || "$VERIFY" == "1" ) ]]; then
  SHOULD_RUN_SPLIT_PREFLIGHT=1
fi

if [[ "$SHOULD_RUN_SPLIT_PREFLIGHT" == "1" ]]; then
  split_incomplete_units
  execute_native_test_script_repairs
  if [[ "$SPLIT_CANDIDATE_COUNT" == "0" && "$SPLIT_INCOMPLETE" != "1" ]]; then
    printf '[split-auto-run] no split candidates; continuing with normal execution schedule\n'
  else
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
  fi
  rebuild_workstream_coordinator_prompts
  rebuild_unit_prompts
  build_final_review_prompt
fi

write_run_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ ! -f "$UNITS_TSV" ]] && return 0
  reconcile_verifier_postcheck_markers
  aggregate_verifier_findings
  local summary="$REMEDIATION_DIR/06-run-summary.tsv"
  local total=0 fixed=0 partial=0 blocked=0

  printf 'unit_id\tgroup\tmodel_class\timplement_result\tverify_decision\n' > "$summary"

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    local impl_artifact="$REMEDIATION_DIR/artifacts/$unit_id-summary.md"
    local verify_artifact="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local impl_log="$REMEDIATION_DIR/logs/implement-$unit_id.log"

    local queue_category
    queue_category="$(verifier_queue_category "$unit_id")"

    local impl_result
    if unit_has_split_children "$unit_id" || unit_packets_marked_split_parent "$unit_id"; then
      if [[ "$queue_category" == "accept-via-named-children" ]]; then
        impl_result="accepted_via_named_children"
      elif [[ "$queue_category" == "accepted_evidence_pending" || "$queue_category" == "accepted_with_carry_over" ]]; then
        impl_result="fixed"
      elif [[ "$queue_category" == "split_decomposed" ]]; then
        impl_result="split"
      else
        impl_result="split"
      fi
    elif [[ -s "$impl_artifact" ]]; then
      impl_result="$(grep -oi 'IMPLEMENTATION_RESULT:[[:space:]]*[a-z]*' "$impl_artifact" 2>/dev/null | head -1 | sed 's/.*IMPLEMENTATION_RESULT:[[:space:]]*//' || true)"
      [[ -z "$impl_result" ]] && impl_result="$(grep -oi 'RESULT:[[:space:]]*[A-Za-z/]*' "$impl_log" 2>/dev/null | tail -1 | sed 's/.*RESULT:[[:space:]]*//' || true)"
      [[ -z "$impl_result" ]] && impl_result="completed"
    elif [[ -f "$impl_log" ]]; then
      impl_result="failed"
    else
      impl_result="not-run"
    fi

    local verify_decision
    if unit_has_split_children "$unit_id" || unit_packets_marked_split_parent "$unit_id"; then
      if [[ "$queue_category" == "accept-via-named-children" ]]; then
        verify_decision="accept-via-named-children"
      elif [[ "$queue_category" == "accepted_evidence_pending" ]]; then
        verify_decision="accept-with-pending-evidence"
      elif [[ "$queue_category" == "accepted_with_carry_over" ]]; then
        verify_decision="accepted_with_carry_over"
      elif [[ "$queue_category" == "split_decomposed" ]]; then
        verify_decision="decomposed"
      else
        verify_decision="split_children_pending"
      fi
    elif [[ -s "$verify_artifact" ]]; then
      verify_decision="$(
        grep -oiE '^[[:space:]-]*(\*\*)?Decision[^[:alnum:]]+`?(accept|revise|stop)`?' "$verify_artifact" 2>/dev/null \
          | head -1 \
          | sed -E 's/.*`?(accept|revise|stop)`?.*/\1/I' \
          || true
      )"
      [[ -z "$verify_decision" ]] && verify_decision="unreadable"
    else
      verify_decision="not-verified"
    fi
    case "$queue_category" in
      accept-via-named-children) verify_decision="accept-via-named-children" ;;
      accepted_with_carry_over) verify_decision="accepted_with_carry_over" ;;
    esac

    case "$impl_result" in
      PASS|pass|completed) impl_result="fixed" ;;
      INCOMPLETE|incomplete) impl_result="partial" ;;
      BLOCKED) impl_result="blocked" ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\n' "$unit_id" "$group" "$model_class" "$impl_result" "$verify_decision" >> "$summary"
    total=$((total + 1))
    case "$queue_category" in
      accepted|accepted_evidence_pending|accepted_with_carry_over|accept-via-named-children) fixed=$((fixed + 1)) ;;
      split_children_pending|needs_targeted_revision|coordinator_cleanup|not_verified|needs_review|evidence_failed) partial=$((partial + 1)) ;;
      *) blocked=$((blocked + 1)) ;;
    esac
  done < <(tail -n +2 "$UNITS_TSV")

  printf '\n=== Remediation Run Summary (%d units) ===\n' "$total"
  printf 'fixed/completed: %d  partial: %d  failed/not-run: %d\n' "$fixed" "$partial" "$blocked"
  if ((partial > 0 || blocked > 0)); then
    printf 'Non-fixed units:\n'
    awk -F'\t' '
      NR > 1 &&
      $5 !~ /^(accept|accept-via-named-children|accepted_with_carry_over|accept-with-pending-evidence)$/ &&
      $4 != "fixed" {
        printf "  %s (%s): impl=%s verify=%s\n", $1, $2, $4, $5
      }
    ' "$summary"
  fi
  printf 'Summary: %s\n' "$summary"
  printf '==========================================\n'
}

verifier_findings_count() {
  local findings="$1"
  [[ -s "$findings" ]] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' 'NR > 1 && $1 != "" { count += 1 } END { printf "%d\n", count }' "$findings"
}

unit_is_plain_accepted() {
  local unit_id="$1"
  local findings
  verifier_accepts_unit "$unit_id" || return 1
  unit_evidence_has_failed_status "$unit_id" && return 1
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"
  [[ "$(verifier_findings_count "$findings")" == "0" ]]
}

finding_resolved_by_accepted_dependency() {
  local unit_id="$1" text="$2"
  local mentioned=0 dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ "$dep" == "$unit_id" ]] && continue
    mentioned=1
    unit_is_plain_accepted "$dep" || return 1
  done < <(printf '%s\n' "$text" | grep -Eo 'IU-[0-9]{4}(-S[0-9]{2})?' | awk '!seen[$0]++')
  [[ "$mentioned" == "1" ]]
}

verifier_unresolved_findings_count() {
  local unit_id="$1" findings="$2"
  [[ -s "$findings" ]] || {
    printf '0\n'
    return 0
  }

  local count=0 type file finding required_fix text
  while IFS=$'\t' read -r _row_unit _severity type file _line finding required_fix _rest; do
    [[ -n "${_row_unit:-}" ]] || continue
    text="$file $finding $required_fix"
    if [[ "$type" == "launch_evidence" || "$type" == "sandbox_blocked" ]]; then
      if finding_resolved_by_accepted_dependency "$unit_id" "$text"; then
        continue
      fi
    fi
    count=$((count + 1))
  done < <(tail -n +2 "$findings")
  if unit_evidence_has_failed_status "$unit_id"; then
    count=$((count + 1))
  fi
  printf '%d\n' "$count"
}

verifier_has_unresolved_evidence_findings() {
  local unit_id="$1" findings="$2"
  [[ -s "$findings" ]] || return 1
  local type file finding required_fix text
  while IFS=$'\t' read -r _row_unit _severity type file _line finding required_fix _rest; do
    [[ -n "${_row_unit:-}" ]] || continue
    [[ "$type" == "launch_evidence" || "$type" == "sandbox_blocked" ]] || continue
    text="$file $finding $required_fix"
    finding_resolved_by_accepted_dependency "$unit_id" "$text" && continue
    return 0
  done < <(tail -n +2 "$findings")
  return 1
}

verifier_has_non_evidence_findings() {
  local findings="$1"
  [[ -s "$findings" ]] || return 1
  awk -F '\t' '
    NR > 1 && $1 != "" && $3 != "launch_evidence" && $3 != "sandbox_blocked" {
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$findings"
}

unit_implementation_newer_than_verifier() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  [[ -s "$verifier" ]] || return 1

  local candidate
  for candidate in \
    "$REMEDIATION_DIR/artifacts/$unit_id-summary.md" \
    "$REMEDIATION_DIR/artifacts/$unit_id-native-test.log" \
    "$REMEDIATION_DIR/artifacts/$unit_id-metadata-closeout.md" \
    "$REMEDIATION_DIR/logs/implement-$unit_id.log"; do
    if [[ -s "$candidate" && "$candidate" -nt "$verifier" ]]; then
      return 0
    fi
  done

  local packets_csv packet_id packet_file
  packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
  IFS=',' read -ra _stale_packets <<< "$packets_csv"
  for packet_id in "${_stale_packets[@]}"; do
    packet_id="${packet_id#"${packet_id%%[![:space:]]*}"}"
    packet_id="${packet_id%"${packet_id##*[![:space:]]}"}"
    [[ -n "$packet_id" ]] || continue
    packet_file="$REMEDIATION_DIR/packets/$packet_id.md"
    if [[ -s "$packet_file" && "$packet_file" -nt "$verifier" ]]; then
      return 0
    fi
  done

  return 1
}

reconcile_verifier_postcheck_markers() {
  [[ -d "$REMEDIATION_DIR/artifacts" ]] || return 0
  local marker unit_id verifier packets_csv
  shopt -s nullglob
  for marker in "$REMEDIATION_DIR"/artifacts/verify-*.postcheck.invalid; do
    [[ -s "$marker" ]] || continue
    unit_id="$(basename "$marker")"
    unit_id="${unit_id#verify-}"
    unit_id="${unit_id%.postcheck.invalid}"
    verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    [[ -s "$verifier" ]] || continue
    verifier_accepts_unit_raw "$unit_id" || continue
    if verifier_acceptance_uses_worktree_evidence "$unit_id" "$verifier"; then
      continue
    fi
    clear_verifier_postcheck_invalid "$unit_id"
    packets_csv="$(unit_packets_csv "$unit_id" 2>/dev/null || true)"
    if [[ -n "$packets_csv" ]] && artifact_mentions_all_packets "$verifier" "$packets_csv"; then
      write_verifier_input_fingerprint "$unit_id" 2>/dev/null || true
    fi
    printf '[postcheck-recover] cleared stale verifier postcheck marker for %s\n' "$unit_id" >&2
  done
  shopt -u nullglob
}

normalize_reconciliation_category() {
  local category="$1"
  if [[ "$category" =~ [Vv]ia[[:space:]-]+named[[:space:]-]+children ]]; then
    printf 'accept-via-named-children\n'
    return 0
  fi
  category="$(printf '%s\n' "$category" | sed -E 's/`//g; s/\*\*//g; s/[[:space:]]*\(.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  category="${category//_/-}"
  case "$category" in
    accepted|accept) printf 'accepted\n' ;;
    accepted-evidence-pending|accept-evidence-pending|accept-with-pending-child) printf 'accepted_evidence_pending\n' ;;
    accepted-with-carry-over|accept-with-carry-over) printf 'accepted_with_carry_over\n' ;;
    accept-via-named-children|accepted-via-named-children|accept-via-named-child) printf 'accept-via-named-children\n' ;;
    *) return 1 ;;
  esac
}

unit_reconciliation_category() {
  local unit_id="$1"
  local review="$REMEDIATION_DIR/04-final-remediation-review.md"
  [[ -s "$review" ]] || return 1

  local category
  category="$(
    awk -F '|' -v unit="$unit_id" '
      function trim(v) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        return v
      }
      /^[[:space:]]*\|/ {
        col1 = trim($2)
        if (col1 != unit) next
        col3 = trim($4)
        col4 = trim($5)
        if (col4 ~ /^(accepted|accept)/) {
          category = col4
        } else if (col3 ~ /^(accepted|accept)/) {
          category = col3
        }
      }
      END {
        if (category != "") print category
      }
    ' "$review"
  )"
  if [[ -n "$category" ]]; then
    normalize_reconciliation_category "$category"
    return 0
  fi

  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  if [[ -s "$verifier" ]] && file_matches 'Decision[^[:alnum:]]+`?accept-via-named-children`?' "$verifier"; then
    printf 'accept-via-named-children\n'
    return 0
  fi

  return 1
}

verifier_queue_category() {
  local unit_id="$1"
  local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
  local findings
  findings="$(verifier_findings_tsv_for_unit "$unit_id")"

  local reconciliation_category
  if reconciliation_category="$(unit_reconciliation_category "$unit_id")"; then
    printf '%s\n' "$reconciliation_category"
    return 0
  fi

  if verifier_postcheck_invalid "$unit_id"; then
    printf 'needs_targeted_revision\n'
    return 0
  fi

  if unit_has_split_children "$unit_id" || unit_packets_marked_split_parent "$unit_id"; then
    if unit_split_children_pending "$unit_id"; then
      printf 'split_children_pending\n'
    else
      printf 'split_decomposed\n'
    fi
    return 0
  fi

  if unit_implementation_newer_than_verifier "$unit_id"; then
    printf 'not_verified\n'
    return 0
  fi

  if verifier_accepts_unit "$unit_id"; then
    if verifier_has_non_evidence_findings "$findings"; then
      printf 'needs_targeted_revision\n'
    elif verifier_has_unresolved_evidence_findings "$unit_id" "$findings"; then
      printf 'accepted_evidence_pending\n'
    elif unit_evidence_has_failed_status "$unit_id"; then
      printf 'evidence_failed\n'
    else
      printf 'accepted\n'
    fi
    return 0
  fi

  if verifier_finding_type_exists "$findings" "contract_conflict"; then
    printf 'contract_conflict\n'
  elif verifier_has_only_coordinator_or_evidence_findings "$unit_id"; then
    printf 'coordinator_cleanup\n'
  elif verifier_finding_type_exists "$findings" "test_harness"; then
    printf 'test_harness\n'
  elif verifier_finding_type_exists "$findings" "split_required"; then
    printf 'split_required\n'
  elif verifier_finding_type_exists "$findings" "blocked"; then
    printf 'blocked\n'
  elif [[ ! -s "$verifier" ]]; then
    printf 'not_verified\n'
  elif file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(stop)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(blocked)' "$verifier"; then
    printf 'blocked\n'
  elif file_matches '(^|[-*[:space:]])(\*\*)?Decision[^[:alnum:]]+`?(revise)|(^|[-*[:space:]])(\*\*)?Implementation decision[^[:alnum:]]+`?(revise)' "$verifier"; then
    printf 'needs_targeted_revision\n'
  else
    printf 'needs_review\n'
  fi
}

write_remediation_queue_summary() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ ! -f "$UNITS_TSV" ]] && return 0
  reconcile_verifier_postcheck_markers
  aggregate_verifier_findings

  local queue="$REMEDIATION_DIR/07-remediation-queue.tsv"
  printf 'unit_id\tgroup\tmodel_class\tpackets\tcategory\tfinding_count\tverifier_artifact\tfindings_tsv\n' > "$queue"

  while IFS=$'\t' read -r unit_id packets_csv group model_class _severity _unit_rationale; do
    [[ -z "${unit_id:-}" ]] && continue
    local verifier="$REMEDIATION_DIR/artifacts/verify-$unit_id.md"
    local findings category finding_count
    findings="$(verifier_findings_tsv_for_unit "$unit_id")"
    category="$(verifier_queue_category "$unit_id")"
    if [[ "$category" == "not_verified" ]]; then
      finding_count=0
    else
      finding_count="$(verifier_unresolved_findings_count "$unit_id" "$findings")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$unit_id" \
      "$group" \
      "$model_class" \
      "$packets_csv" \
      "$category" \
      "$finding_count" \
      "$verifier" \
      "$findings" >> "$queue"
  done < <(tail -n +2 "$UNITS_TSV")

  printf 'Queue: %s\n' "$queue"
  awk -F '\t' 'NR > 1 { count[$5] += 1 } END { for (category in count) printf "  %s: %d\n", category, count[category] }' "$queue" | sort
}

printf 'Remediation run directory: %s\n' "$REMEDIATION_DIR"
printf 'Master Px list: %s\n' "$PX_MD"
printf 'Blocker ledger: %s\n' "$BLOCKER_LEDGER_MD"
printf 'Workstreams: %s\n' "$WORKSTREAMS_TSV"
printf 'Implementation units: %s\n' "$UNITS_TSV"
printf 'Packets: %s/packets\n' "$REMEDIATION_DIR"

if [[ "$RECOORDINATE" == "1" && -f "$CHECKPOINT_FILE" ]]; then
  _rc_before=$(grep -c "^coordinate-" "$CHECKPOINT_FILE" 2>/dev/null || true)
  grep -v "^coordinate-" "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" && mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
  _rc_after=$(grep -c "^coordinate-" "$CHECKPOINT_FILE" 2>/dev/null || true)
  [[ "$_rc_before" =~ ^[0-9]+$ ]] || _rc_before=0
  [[ "$_rc_after" =~ ^[0-9]+$ ]] || _rc_after=0
  printf '[recoordinate] cleared %d coordinate-* checkpoint entries; workstream coordinators will re-run against incomplete packets\n' \
    "$(( _rc_before - _rc_after ))"
fi

if [[ "$STATE_RESUME" == "1" ]]; then
  if [[ "$REMEDIATION_AUTO_DRAIN_QUEUE" == "1" ]]; then
    printf '[resume] deriving and executing deterministic queue actions from existing remediation state\n'
    execute_queue_drain
  else
    execute_state_resume
  fi
elif [[ "$REVISE_NEXT" == "1" ]]; then
  execute_revise_next
elif [[ "$DRAIN_QUEUE" == "1" ]]; then
  execute_queue_drain
elif [[ "$SUMMARY_ONLY" == "1" ]]; then
  aggregate_verifier_findings
elif [[ "$VERIFY_ONLY" == "1" ]]; then
  execute_verifiers
elif [[ "$FINALIZE_ONLY" == "1" ]]; then
  execute_final_review
elif [[ "$SPLIT_SKIP_EXECUTION" == "1" ]]; then
  printf 'No split candidates or child units to execute.\n'
elif [[ "$EXECUTE" == "1" || "$DRY_RUN" == "1" ]]; then
  execute_workstreams
  if [[ "$EXECUTE" == "1" && "$DRY_RUN" != "1" && "$REMEDIATION_VERIFY_AFTER_EXECUTE" == "1" ]]; then
    VERIFY=1
  fi
  if [[ "$REVISE_EXISTING" == "1" && "$EXECUTE" == "1" && "$DRY_RUN" != "1" ]]; then
    VERIFY=1
    FORCE_VERIFY=1
    printf '[revise-existing] implementation pass complete; forcing verifier rerun for selected units\n'
  elif [[ "$VERIFY" == "1" && "$EXECUTE" == "1" && "$DRY_RUN" != "1" && "$REMEDIATION_VERIFY_AFTER_EXECUTE" == "1" ]]; then
    printf '[execute] implementation pass complete; running verifier/final-review drain by default\n'
  fi
  if [[ "$VERIFY" == "1" ]]; then
    if [[ "$REVISE_EXISTING" == "1" && -n "${ONLY_UNIT:-}" ]]; then
      integrate_units_before_verification "$ONLY_UNIT"
    fi
    run_static_prechecks
    execute_verifier_units
    execute_revision_rounds
    execute_metadata_closeout_repairs
    execute_missing_verifiers_from_queue
    execute_evidence_collection_rounds
    execute_final_review
  fi
else
  printf 'Plan generated only. Re-run with --execute to launch remediation agents.\n'
fi

if ! write_run_summary; then
  printf '[warn] run summary generation failed; remediation execution already completed\n' >&2
fi
if ! write_remediation_queue_summary; then
  printf '[warn] remediation queue summary generation failed; remediation execution already completed\n' >&2
fi
