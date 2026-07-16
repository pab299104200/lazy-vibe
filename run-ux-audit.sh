#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ux-preflight-state.sh"
PROFILE="${PROFILE:-}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"

usage() {
  cat <<'USAGE'
Usage: run-ux-audit.sh --profile NAME [run-audit.sh options]

Runs a user-journey audit against an already deployed product. The product
profile supplies durable context; the harness discovers routes and journeys.

Environment:
  PROFILE            Profile under profiles/ (required unless PRODUCT_PROFILE is set).
  REPO_ROOT          Product repo. Defaults to the current directory.
  RUN_DIR            Output directory. Defaults to docs/audit/<date>-ux-journey-run.
  UX_PROFILE         Optional UX contract. Defaults to profiles/<profile>/ux-profile.md.
  UX_FIXTURE_PROVIDER
                     Optional executable fixture provider. Defaults to
                     profiles/<profile>/ux-fixtures when present. It runs after
                     journey planning and before browser execution.
  PRODUCT_PROFILE    Product profile. Defaults to profiles/<profile>/product-profile.md.
  RUNNER             codex, claude, or gemini. Defaults to codex.
  UX_BROWSER_PREFLIGHT
                     1 to install/launch Chromium and probe the deployed URL before
                     scheduling agents. Defaults to 1; never disable for a real run.
  UX_BROWSER_AUTO_INSTALL
                     1 to install the repo-matched Playwright Chromium when absent.

All other options and runner variables are forwarded to run-audit.sh.
USAGE
}

forwarded_args=()
is_dry_run=0
while (($#)); do
  case "$1" in
    --profile)
      PROFILE="${2:?missing profile name}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      [[ "$1" == "--dry-run" ]] && is_dry_run=1
      forwarded_args+=("$1")
      shift
      ;;
  esac
done

profile_dir="${PROFILES_DIR:-$SCRIPT_DIR/profiles}/${PROFILE}"
product_profile="${PRODUCT_PROFILE:-$profile_dir/product-profile.md}"
ux_profile="${UX_PROFILE:-$profile_dir/ux-profile.md}"

if [[ ! -f "$product_profile" ]]; then
  printf 'Product profile not found: %s\n' "$product_profile" >&2
  exit 2
fi

run_dir="${RUN_DIR:-$REPO_ROOT/docs/audit/$(date +%Y-%m-%d)-ux-journey-run}"
mkdir -p "$run_dir/artifacts"
composed_profile="$run_dir/artifacts/ux-product-context.md"
{
  cat "$product_profile"
  if [[ -f "$ux_profile" ]]; then
    printf '\n\n# UX Audit Contract\n\n'
    cat "$ux_profile"
  fi
} > "$composed_profile"

export REPO_ROOT="$REPO_ROOT"
export RUN_DIR="$run_dir"
export MASTER_PROMPT="${MASTER_PROMPT:-$SCRIPT_DIR/generic-user-journey-audit-prompt.md}"
export SHARED_PROMPT="${SHARED_PROMPT:-$SCRIPT_DIR/generic-ux-shared.md}"
export JOBS_FILE="${JOBS_FILE:-$SCRIPT_DIR/generic-ux-jobs.tsv}"
export PRODUCT_PROFILE="$composed_profile"
export PROFILE="$PROFILE"
if [[ -z "${UX_FIXTURE_PROVIDER:-}" && -x "$profile_dir/ux-fixtures" ]]; then
  export UX_FIXTURE_PROVIDER="$profile_dir/ux-fixtures"
fi
if [[ -z "${UX_AUTH_PORTAL_URL:-}" && -s "$profile_dir/ux-portal-url" ]]; then
  export UX_AUTH_PORTAL_URL="$(head -n 1 "$profile_dir/ux-portal-url" | tr -d '\r\n')"
fi

# Journey agents use the deployed product directly. Launch-readiness native
# security, dependency, load, and generic browser gates are separate concerns.
export ACCESSIBILITY_SCAN="${ACCESSIBILITY_SCAN:-0}"
export E2E_BROWSER_PROOF="${E2E_BROWSER_PROOF:-0}"
export EXTERNAL_SERVICES_TEST="${EXTERNAL_SERVICES_TEST:-0}"
export LIGHTHOUSE_SCAN="${LIGHTHOUSE_SCAN:-0}"
export LOAD_TEST_ENABLED="${LOAD_TEST_ENABLED:-0}"
export SAST_ENABLED="${SAST_ENABLED:-0}"
export AUDIT_REGISTER_RECONCILE="${AUDIT_REGISTER_RECONCILE:-0}"
export DYNAMIC_DEPTH_CAP="${DYNAMIC_DEPTH_CAP:-0}"
export MAX_PARALLEL="${MAX_PARALLEL:-3}"

# Simulation agents use an out-of-sandbox Playwright MCP server. Their shell
# remains sandboxed; browser actions and screenshots cross only the MCP boundary.
export UX_PLAYWRIGHT_MCP="${UX_PLAYWRIGHT_MCP:-1}"
export CODEX_BYPASS_SIMULATION="${CODEX_BYPASS_SIMULATION:-1}"

if [[ "$is_dry_run" != "1" && "${UX_BROWSER_PREFLIGHT:-1}" == "1" ]]; then
  preflight_dir="$run_dir/artifacts/browser-preflight"
  mkdir -p "$preflight_dir"
  if ux_preflight_is_fresh_pass "$run_dir" "${UX_FIXTURE_AUTH_MAX_AGE_SECONDS:-600}"; then
    printf '[ux-preflight] reusing fresh successful browser authentication\n'
  else
    if ! node "$SCRIPT_DIR/ux-browser-preflight.cjs" \
      --repo-root "$REPO_ROOT" \
      --run-dir "$run_dir" \
      --auto-install "${UX_BROWSER_AUTO_INSTALL:-1}"; then
      printf 'UX browser preflight failed. See %s/summary.md\n' "$preflight_dir" >&2
      exit 3
    fi
  fi
fi

exec "$SCRIPT_DIR/run-audit.sh" "${forwarded_args[@]}"
