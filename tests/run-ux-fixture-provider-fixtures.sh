#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lazy-vibe-ux-fixtures.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
run_dir="$tmp_root/run"
mkdir -p "$run_dir/artifacts/ux-fixtures"
plan="$run_dir/artifacts/journey-plan.tsv"
manifest="$run_dir/artifacts/ux-fixtures/manifest.md"
printf 'journey_id\texecution_job\trole\tpriority\tstarting_state\ttask\tcompletion_oracle\tfixture_strategy\n' > "$plan"
printf 'UX-J12\t03-administration\tAuditor\tP1\tEmpty\tUpload\tRestored\tHarness file\n' >> "$plan"

provider="$script_dir/profiles/keystone/ux-fixtures"
"$provider" describe "$tmp_root" "$run_dir" "" "$manifest"
grep -q 'browser_record_creation.*READY' "$manifest"
"$provider" prepare "$tmp_root" "$run_dir" "$plan" "$manifest"
grep -q 'file_upload.*READY' "$manifest"
upload_path="$(sed -n 's/.*Disposable file: `\([^`]*\)`.*/\1/p' "$manifest")"
[[ -f "$upload_path" ]]
grep -q 'fresh_portal_tenant.*READY' "$manifest"
grep -q 'disposable_portal_identities.*READY' "$manifest"
"$provider" cleanup "$tmp_root" "$run_dir" "$plan" "$manifest"
[[ ! -e "$upload_path" ]]

grep -q 'inspect or search the full Playwright MCP tool catalog' "$script_dir/generic-ux-shared.md"
grep -q 'prepare_ux_fixtures' "$script_dir/run-audit.sh"
grep -q 'append_ux_fixture_manifest' "$script_dir/run-audit.sh"
grep -q 'describe_ux_fixture_capabilities' "$script_dir/run-audit.sh"
grep -q 'Do not invent journey-specific provider names' "$script_dir/generic-user-journey-audit-prompt.md"
grep -q 'Provider identifiers must come verbatim' "$script_dir/generic-ux-shared.md"
printf 'PASS UX fixture provider fixtures\n'
