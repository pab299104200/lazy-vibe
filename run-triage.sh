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
set -euo pipefail

REGISTER_DIR=""
TRIAGE_AGENT="${TRIAGE_AGENT:-claude}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
TRIAGE_DATE="${TRIAGE_DATE:-$(date +%F)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: run-triage.sh --register-dir DIR [--agent AGENT]" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --register-dir) REGISTER_DIR="$2"; shift 2 ;;
    --agent) TRIAGE_AGENT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[[ -n "$REGISTER_DIR" ]] || usage

PACKETS_DIR="$REGISTER_DIR/triage/packets"
RESULTS_DIR="$REGISTER_DIR/triage/results"

# 1. (Re)generate packets for current `new` findings.
python3 -m lazy_vibe.register verify-packets --register-dir "$REGISTER_DIR"
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
    $TRIAGE_AGENT -p --dangerously-skip-permissions < "$packet" \
      > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  elif [[ "$TRIAGE_AGENT" == codex* ]]; then
    # shellcheck disable=SC2086
    $TRIAGE_AGENT exec --full-auto --skip-git-repo-check -C "$REPO_ROOT" - \
      < "$packet" > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  else
    # stub / custom agent: receives packet on stdin, writes the result file.
    # shellcheck disable=SC2086
    $TRIAGE_AGENT < "$packet" > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  fi
}
export -f run_one
export RESULTS_DIR TRIAGE_AGENT REPO_ROOT

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
