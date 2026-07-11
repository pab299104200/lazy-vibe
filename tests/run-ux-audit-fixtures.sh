#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

profile_dir="$fixture_root/profiles/example"
repo_root="$fixture_root/product"
run_dir="$fixture_root/run"
mkdir -p "$profile_dir" "$repo_root"

cat > "$profile_dir/product-profile.md" <<'PROFILE'
# Product Profile

- Repo root: REPO_ROOT_PLACEHOLDER
- Staging URL: https://example.invalid
PROFILE
sed -i "s#REPO_ROOT_PLACEHOLDER#$repo_root#" "$profile_dir/product-profile.md"

cat > "$profile_dir/ux-profile.md" <<'PROFILE'
## Priority Roles

- Operator: completes the product's primary work.
PROFILE

PROFILES_DIR="$fixture_root/profiles" \
REPO_ROOT="$repo_root" \
RUN_DIR="$run_dir" \
"$SCRIPT_DIR/run-ux-audit.sh" --profile example --dry-run >/dev/null

test -f "$run_dir/artifacts/ux-product-context.md"
test -f "$run_dir/prompts/03-primary-work.md"
grep -q 'Operator: completes' "$run_dir/artifacts/ux-product-context.md"
grep -q 'Use the supplied `playwright` MCP tools for every execution job' "$run_dir/prompts/03-primary-work.md"
grep -q 'UX PHASE 3A' "$run_dir/prompts/03-primary-work.md"
grep -q 'browser-preflight/summary.md' "$run_dir/prompts/03-primary-work.md"
if grep -q 'Static Analysis and Dependency CVE Scanning' "$run_dir/prompts/03-primary-work.md"; then
  printf 'launch security scan instructions leaked into UX execution prompt\n' >&2
  exit 1
fi

cat > "$run_dir/artifacts/journey-plan.tsv" <<'PLAN'
journey_id	execution_job	role	priority	starting_state	task	completion_oracle	fixture_strategy
J01-primary	03-primary-work	Operator	P0	Signed out	Complete primary work	Outcome is visible	Create a prefixed fixture
J02-admin	03-administration	Administrator	P1	Signed in	Configure access	Access is visible	Create a prefixed fixture
PLAN

PROFILES_DIR="$fixture_root/profiles" \
REPO_ROOT="$repo_root" \
RUN_DIR="$run_dir" \
"$SCRIPT_DIR/run-ux-audit.sh" --profile example --dry-run --only 03-primary-work >/dev/null

grep -q 'J01-primary.*03-primary-work' "$run_dir/prompts/03-primary-work.md"
if grep -q 'J02-admin' "$run_dir/prompts/03-primary-work.md"; then
  printf 'cross-lane journey leaked into primary-work prompt\n' >&2
  exit 1
fi
grep -q 'artifacts/03-primary-work/journeys/<journey_id>/trace.md' "$run_dir/prompts/03-primary-work.md"
grep -q 'journey-results.tsv' "$run_dir/prompts/03-primary-work.md"

fake_runner="$fixture_root/fake-audit-runner.sh"
cat > "$fake_runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="$1"
run_dir="$2"
job_id="$3"
output="$(sed -n 's#^- Required output: ##p' "$prompt_file")"
mkdir -p "$(dirname "$output")" "$run_dir/artifacts/$job_id/journeys/J01-primary"
printf '# Execution Report\n\nRESULT: PASS\n' > "$output"
printf '# Journey Trace\n\nRESULT: PASS\n' > "$run_dir/artifacts/$job_id/journeys/J01-primary/trace.md"
cat > "$run_dir/artifacts/$job_id/journey-results.tsv" <<RESULTS
journey_id	result	fixture_status	oracle_status	trace_path	cleanup_status	blocker
J01-primary	PASS	CREATED	PROVEN	artifacts/$job_id/journeys/J01-primary/trace.md	CLEANED	
RESULTS
if [[ "${INJECT_FOREIGN_JOURNEY:-0}" == "1" ]]; then
  mkdir -p "$run_dir/artifacts/$job_id/journeys/J02-admin"
  printf '# Journey Trace\n\nRESULT: PASS\n' > "$run_dir/artifacts/$job_id/journeys/J02-admin/trace.md"
  printf 'J02-admin\tPASS\tCREATED\tPROVEN\tartifacts/%s/journeys/J02-admin/trace.md\tCLEANED\t\n' "$job_id" >> "$run_dir/artifacts/$job_id/journey-results.tsv"
fi
printf 'JOB: %s\nRESULT: PASS\n' "$job_id"
RUNNER
chmod +x "$fake_runner"

rm -f "$run_dir/completed-jobs.txt" "$run_dir/00-run-summary.tsv"
AUDIT_RUNNER="$fake_runner" \
PROFILES_DIR="$fixture_root/profiles" \
REPO_ROOT="$repo_root" \
RUN_DIR="$run_dir" \
UX_BROWSER_PREFLIGHT=0 \
"$SCRIPT_DIR/run-ux-audit.sh" --profile example --only 03-primary-work >/dev/null || {
  cat "$run_dir/artifacts/03-primary-work/evidence-validation.md" >&2
  exit 1
}

grep -q 'STATUS: PASS' "$run_dir/artifacts/03-primary-work/evidence-validation.md" || {
  cat "$run_dir/logs/03-primary-work.log" >&2
  cat "$run_dir/artifacts/03-primary-work/evidence-validation.md" >&2
  exit 1
}
grep -q $'03-primary-work\tJ01-primary\tPASS' "$run_dir/artifacts/journey-evidence-index.tsv"

rm -f "$run_dir/completed-jobs.txt" "$run_dir/00-run-summary.tsv"
if INJECT_FOREIGN_JOURNEY=1 \
  CONTINUE_ON_FAIL=0 \
  AUDIT_MAX_RETRIES=0 \
  AUDIT_RUNNER="$fake_runner" \
  PROFILES_DIR="$fixture_root/profiles" \
  REPO_ROOT="$repo_root" \
  RUN_DIR="$run_dir" \
  UX_BROWSER_PREFLIGHT=0 \
  "$SCRIPT_DIR/run-ux-audit.sh" --profile example --only 03-primary-work >/dev/null 2>&1; then
  printf 'cross-lane journey evidence unexpectedly passed validation\n' >&2
  exit 1
fi
grep -q 'contains journeys owned by another lane: J02-admin' \
  "$run_dir/artifacts/03-primary-work/evidence-validation.md"

preflight_repo="$fixture_root/preflight-product"
preflight_run="$fixture_root/preflight-run"
playwright_dir="$preflight_repo/frontend/node_modules/playwright"
mkdir -p "$playwright_dir" "$preflight_repo/docs/ux"
touch "$playwright_dir/chromium"
cat > "$playwright_dir/index.js" <<'JS'
const fs = require('fs');
const path = require('path');
const executable = path.join(__dirname, 'chromium');
module.exports = {
  chromium: {
    name: () => 'chromium',
    executablePath: () => executable,
    launch: async () => ({
      newPage: async () => ({
        goto: async () => ({ status: () => 200 }),
        screenshot: async ({ path: output }) => fs.writeFileSync(output, 'fixture'),
      }),
      close: async () => {},
    }),
  },
};
JS
cat > "$preflight_repo/docs/ux/.creds" <<'CREDS'
url=https://example.invalid
password=must-not-appear
CREDS

node "$SCRIPT_DIR/ux-browser-preflight.cjs" \
  --repo-root "$preflight_repo" \
  --run-dir "$preflight_run" \
  --auto-install 0

grep -q 'STATUS: PASS' "$preflight_run/artifacts/browser-preflight/summary.md"
test -f "$preflight_run/artifacts/browser-preflight/entry-page.png"
if rg -n 'must-not-appear' "$preflight_run" >/dev/null; then
  printf 'browser preflight leaked a credential\n' >&2
  exit 1
fi

if PROFILES_DIR="$fixture_root/profiles" REPO_ROOT="$repo_root" \
  "$SCRIPT_DIR/run-ux-audit.sh" --profile missing --dry-run >/dev/null 2>&1; then
  printf 'missing profile unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'UX audit fixtures passed\n'
