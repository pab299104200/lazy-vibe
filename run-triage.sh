#!/usr/bin/env bash
# run-triage.sh — harness glue for the register triage verification stage.
#
# For each verification packet that has no result yet, invoke the agent CLI
# with the packet on stdin (the packet states the JSON output contract and the
# exact result path to write), then fold all results into the register via
# `verify-consume`. This is the verification half of the triage pipeline
# (spec §6 stage 1, §11); policy + queue are driven by `triage`. Full
# run-remediation.sh rewiring is Plan 3.
#
# Env:
#   TRIAGE_AGENT   agent command (default: claude). Receives the packet on
#                  stdin. For claude: invoked with -p --dangerously-skip-permissions.
#                  For codex: invoked with exec --full-auto --skip-git-repo-check -.
#                  For any other command: receives the packet on stdin directly
#                  (stub / custom agent pattern).
#   MAX_PARALLEL   max concurrent agent invocations (default: 3).
#   TRIAGE_DATE    ISO date stamped on verification events (default: today).
#   PROFILE        Profile name (under PROFILES_DIR) or absolute profile dir.
#                  Sets PRODUCT_PROFILE and, when --register-dir is omitted,
#                  infers docs/audit/register from the profile's Repo root.
#   PROFILES_DIR   Directory containing named profile dirs (default: profiles/).
#   PRODUCT_PROFILE Optional product-profile.md. Its "Repo root" line is used
#                  as the verifier working directory.
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
  echo "usage: run-triage.sh [--register-dir DIR] [--agent AGENT] [--no-generate]" >&2
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

PACKETS_DIR="$REGISTER_DIR/triage/packets"
RESULTS_DIR="$REGISTER_DIR/triage/results"

# 1. (Re)generate packets for current `new` findings unless the caller has
# pre-bounded packets for a sampled dry-run.
if [[ "$GENERATE_PACKETS" == 1 ]]; then
  python3 -m lazy_vibe.register verify-packets --register-dir "$REGISTER_DIR"
fi
mkdir -p "$RESULTS_DIR"

# 2. For each packet without a result, dispatch the agent (bounded parallel).
run_one() {
  local packet="$1" fid result
  fid="$(basename "$packet" .md)"
  result="$RESULTS_DIR/$fid.json"
  # Skip if a fresh result is already waiting to be consumed.
  [[ -f "$result" ]] && return 0
  # A consumed result (results/consumed/, moved there by verify-consume) means
  # this finding was already verified on a previous run and is awaiting
  # policy/Pete — do not re-dispatch the agent for it. Findings the queue
  # flags "re-run verify" have no consumed result and still dispatch.
  [[ -f "$RESULTS_DIR/consumed/$fid.json" ]] && return 0
  if [[ "$TRIAGE_AGENT" == claude* ]]; then
    # shellcheck disable=SC2086
    (cd "$PRODUCT_REPO_ROOT" && \
      $TRIAGE_AGENT -p --dangerously-skip-permissions < "$packet") \
      > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  elif [[ "$TRIAGE_AGENT" == codex* ]]; then
    # shellcheck disable=SC2086
    $TRIAGE_AGENT exec --full-auto --skip-git-repo-check \
      -C "$PRODUCT_REPO_ROOT" - \
      < "$packet" > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  else
    # stub / custom agent: receives packet on stdin, writes the result file.
    # shellcheck disable=SC2086
    (cd "$PRODUCT_REPO_ROOT" && $TRIAGE_AGENT < "$packet") \
      > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  fi
}
export -f run_one
export RESULTS_DIR TRIAGE_AGENT PRODUCT_REPO_ROOT

if compgen -G "$PACKETS_DIR/*.md" > /dev/null 2>&1; then
  printf '%s\n' "$PACKETS_DIR"/*.md \
    | xargs -P "$MAX_PARALLEL" -I {} bash -c 'run_one "$@"' _ {}
fi

# 3. Fold every present result into the register (schema-validated).
python3 -m lazy_vibe.register verify-consume \
  --register-dir "$REGISTER_DIR" --date "$TRIAGE_DATE"

echo "triage verification complete — review queue with:" \
     "python3 -m lazy_vibe.register triage --register-dir $REGISTER_DIR" \
     "--policy $REGISTER_DIR/triage-policy.yaml --render-only"
