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
grep -q 'purchase_to_pay_browser_setup.*READY' "$manifest"
grep -q 'No purchase order, receipt, bill, or match record is pre-created' "$manifest"
"$provider" prepare "$tmp_root" "$run_dir" "$plan" "$manifest"
grep -q 'file_upload.*READY' "$manifest"
upload_path="$(sed -n 's/.*Disposable file: `\([^`]*\)`.*/\1/p' "$manifest")"
[[ -f "$upload_path" ]]
grep -q 'fresh_keystone_customer_workspace.*UNAVAILABLE' "$manifest"
grep -q 'disposable_portal_identities.*UNAVAILABLE' "$manifest"
grep -q 'secondary_keystone_approver.*UNAVAILABLE' "$manifest"
grep -q "UXAUDIT run opening deposit" "$run_dir/artifacts/ux-fixtures/keystone-audit-bank-statement.csv"
grep -q "FITID>UXAUDIT-DEP-run" "$run_dir/artifacts/ux-fixtures/keystone-audit-bank-statement.ofx"
"$provider" cleanup "$tmp_root" "$run_dir" "$plan" "$manifest"
[[ ! -e "$upload_path" ]]

portal_manifest="$run_dir/artifacts/ux-fixtures/portal-manifest.md"
portal_provider="$script_dir/profiles/portal/ux-fixtures"
"$portal_provider" describe /home/pete/cadres/portal "$run_dir" "" "$portal_manifest"
grep -q 'authenticated_global_identity.*READY' "$portal_manifest"
grep -q 'resettable_customer_tenant.*READY_AFTER_PREPARE' "$portal_manifest"
grep -q 'role_context_matrix.*READY_AFTER_PREPARE' "$portal_manifest"
grep -q 'webhook_receiver.*READY_AFTER_PREPARE' "$portal_manifest"
# Portal prepare is intentionally a live dev-VPS integration path. It is
# exercised by the Portal readiness check, not this hermetic shared test.

grep -q 'inspect or search the full Playwright MCP tool catalog' "$script_dir/generic-ux-shared.md"
grep -q 'prepare_ux_fixtures' "$script_dir/run-audit.sh"
grep -q 'append_ux_fixture_manifest' "$script_dir/run-audit.sh"
! grep -A8 'write_ux_journey_evidence_index' "$script_dir/run-audit.sh" | grep -q 'STATUS: PASS'
grep -q 'describe_ux_fixture_capabilities' "$script_dir/run-audit.sh"
grep -q 'Portal fixture session was authenticated' "$script_dir/ux-browser-preflight.cjs"
grep -q 'Do not invent journey-specific provider names' "$script_dir/generic-user-journey-audit-prompt.md"
grep -q 'Provider identifiers must come verbatim' "$script_dir/generic-ux-shared.md"
grep -q 'Do not impose an arbitrary journey cap' "$script_dir/generic-user-journey-audit-prompt.md"
grep -q 'BLOCKED.*UNVERIFIED.*evidence states' "$script_dir/generic-user-journey-audit-prompt.md"
grep -q 'Never assign numerical UX dimension scores to BLOCKED or UNVERIFIED' "$script_dir/generic-ux-shared.md"
grep -q 'Failure of one setup or onboarding journey must not cascade' "$script_dir/generic-ux-shared.md"
grep -q 'source "$SCRIPT_DIR/ux-actor-lanes.sh"' "$script_dir/run-audit.sh"
grep -q 'ux_job_actors' "$script_dir/ux-actor-lanes.sh"
grep -Fq $'03-exceptions\ttenant_admin\trequester,approver' \
  "$script_dir/profiles/keystone/ux-fixtures"
grep -Fq $'03-administration\ttenant_admin\trequester,approver,reviewer,observer,operator,guest' \
  "$script_dir/profiles/keystone/ux-fixtures"
grep -q 'auth-state-{actor}.json' "$script_dir/run-audit.sh"
grep -q 'mcp_servers.playwright_secondary.command' "$script_dir/run-audit.sh"
grep -q 'playwright-secondary-init.mjs' "$script_dir/run-audit.sh"
grep -q 'auth-state-secondary.json' "$script_dir/run-audit.sh"
grep -q 'docs/ux/.creds.secondary' "$script_dir/run-audit.sh"
grep -q 'completeOAuthConsent' "$script_dir/ux-browser-auth-init.ts"
grep -q 'requires tenant_id when more than one organization is available' "$script_dir/ux-browser-auth-init.ts"
grep -q '.npm-install.lock' "$script_dir/run-audit.sh"
grep -q '.playwright-install.lock' "$script_dir/run-audit.sh"
grep -q '.chromium-install-complete' "$script_dir/run-audit.sh"
grep -q '.package-ready-' "$script_dir/run-audit.sh"
grep -q 'Guest access: grant-backed cross-tenant collaboration for the same global identity' "$script_dir/profiles/portal/ux-profile.md"
grep -q 'without requiring Portal operator-home customer authority' "$script_dir/profiles/portal/product-profile.md"
grep -q 'A product verdict of `FAIL` must not make the synthesis job itself appear as a failed harness job' "$script_dir/generic-user-journey-audit-prompt.md"
grep -q 'a failing product verdict is not a harness execution error' "$script_dir/generic-ux-shared.md"
printf 'PASS UX fixture provider fixtures\n'
