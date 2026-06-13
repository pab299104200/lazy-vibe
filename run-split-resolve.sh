#!/usr/bin/env bash
# run-split-resolve.sh — agent resolver for verifier split findings.
#
# For each register finding left `new` with a split_proposed event, dispatch an
# agent packet that must choose open / false_positive / park. The consumer then
# applies the decision with policy:split-resolver authority so real findings can
# enter remediation without Pete hand-adjudicating every split row.
#
# Env mirrors run-triage.sh:
#   TRIAGE_AGENT   agent command (default: claude)
#   MAX_PARALLEL   max concurrent agent invocations (default: 3)
#   TRIAGE_DATE    ISO date stamped on disposition events (default: today)
#   PROFILE        Profile name under profiles/ (sets register + repo root)
#   PRODUCT_PROFILE / PRODUCT_REPO_ROOT / PROFILES_DIR as in run-triage.sh
set -euo pipefail

REGISTER_DIR=""
GENERATE_PACKETS=1
TRIAGE_AGENT="${TRIAGE_AGENT:-claude}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
TRIAGE_DATE="${TRIAGE_DATE:-$(date +%F)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_PROFILE="${PRODUCT_PROFILE:-}"
PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"
PROFILE="${PROFILE:-}"
PRODUCT_REPO_ROOT="${PRODUCT_REPO_ROOT:-}"

usage() {
  echo "usage: run-split-resolve.sh [--register-dir DIR] [--agent AGENT] [--no-generate]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --register-dir) REGISTER_DIR="$2"; shift 2 ;;
    --agent) TRIAGE_AGENT="$2"; shift 2 ;;
    --no-generate) GENERATE_PACKETS=0; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

repo_root_from_profile() {
  local profile_file="$1"
  sed -nE 's/^- Repo root:[[:space:]]*`?([^`]+)`?.*$/\1/p' \
    "$profile_file" | head -1
}

if [[ -n "$PROFILE" ]]; then
  _profile_dir="$PROFILE"
  [[ "$PROFILE" != /* ]] && _profile_dir="$PROFILES_DIR/$PROFILE"
  if [[ ! -d "$_profile_dir" ]]; then
    printf 'Profile not found: %s\n' "$_profile_dir" >&2
    exit 2
  fi
  [[ -z "$PRODUCT_PROFILE" && -f "$_profile_dir/product-profile.md" ]] && \
    PRODUCT_PROFILE="$_profile_dir/product-profile.md"
fi

if [[ -z "$PRODUCT_REPO_ROOT" && -n "$PRODUCT_PROFILE" ]]; then
  if [[ ! -f "$PRODUCT_PROFILE" ]]; then
    printf 'Product profile not found: %s\n' "$PRODUCT_PROFILE" >&2
    exit 2
  fi
  PRODUCT_REPO_ROOT="$(repo_root_from_profile "$PRODUCT_PROFILE")"
fi

if [[ -z "$REGISTER_DIR" && -n "$PRODUCT_REPO_ROOT" ]]; then
  REGISTER_DIR="$PRODUCT_REPO_ROOT/docs/audit/register"
fi
if [[ -z "$PRODUCT_REPO_ROOT" && "$REGISTER_DIR" == */docs/audit/register ]]; then
  PRODUCT_REPO_ROOT="${REGISTER_DIR%/docs/audit/register}"
fi
[[ -n "$REGISTER_DIR" ]] || usage
PRODUCT_REPO_ROOT="${PRODUCT_REPO_ROOT:-$SCRIPT_DIR}"

PACKETS_DIR="$REGISTER_DIR/triage/split-packets"
RESULTS_DIR="$REGISTER_DIR/triage/split-results"

if [[ "$GENERATE_PACKETS" == 1 ]]; then
  python3 -m lazy_vibe.register split-packets --register-dir "$REGISTER_DIR"
fi
mkdir -p "$RESULTS_DIR"

run_one() {
  local packet="$1" fid result
  fid="$(basename "$packet" .md)"
  result="$RESULTS_DIR/$fid.json"
  [[ -f "$result" ]] && return 0
  [[ -f "$RESULTS_DIR/consumed/$fid.json" ]] && return 0
  if [[ "$TRIAGE_AGENT" == claude* ]]; then
    # shellcheck disable=SC2086
    (cd "$PRODUCT_REPO_ROOT" && \
      $TRIAGE_AGENT -p --dangerously-skip-permissions < "$packet") \
      > "/tmp/split-resolve-$fid.log" 2>&1 || \
      echo "warning: split resolver failed for $fid (see /tmp/split-resolve-$fid.log)" >&2
  elif [[ "$TRIAGE_AGENT" == codex* ]]; then
    # shellcheck disable=SC2086
    $TRIAGE_AGENT exec --full-auto --skip-git-repo-check \
      -C "$PRODUCT_REPO_ROOT" - \
      < "$packet" > "/tmp/split-resolve-$fid.log" 2>&1 || \
      echo "warning: split resolver failed for $fid (see /tmp/split-resolve-$fid.log)" >&2
  else
    # shellcheck disable=SC2086
    (cd "$PRODUCT_REPO_ROOT" && $TRIAGE_AGENT < "$packet") \
      > "/tmp/split-resolve-$fid.log" 2>&1 || \
      echo "warning: split resolver failed for $fid (see /tmp/split-resolve-$fid.log)" >&2
  fi
}
export -f run_one
export RESULTS_DIR TRIAGE_AGENT PRODUCT_REPO_ROOT

if compgen -G "$PACKETS_DIR/*.md" > /dev/null 2>&1; then
  printf '%s\0' "$PACKETS_DIR"/*.md \
    | xargs -0 -P "$MAX_PARALLEL" -I {} bash -c 'run_one "$@"' _ {}
fi

python3 -m lazy_vibe.register split-consume \
  --register-dir "$REGISTER_DIR" --date "$TRIAGE_DATE"

echo "split resolution complete — review queue with:" \
     "python3 -m lazy_vibe.register triage --register-dir $REGISTER_DIR" \
     "--policy $REGISTER_DIR/triage-policy.yaml --render-only"
