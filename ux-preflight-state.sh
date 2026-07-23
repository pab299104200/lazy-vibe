#!/usr/bin/env bash

ux_preflight_is_fresh_pass() {
  local run_dir="$1"
  local max_age_seconds="${2:-600}"
  local preflight_dir="$run_dir/artifacts/browser-preflight"
  local auth_state="$preflight_dir/auth-state.json"
  local summary="$preflight_dir/summary.json"

  [[ "$max_age_seconds" =~ ^[0-9]+$ ]] || return 1
  [[ -s "$auth_state" && -s "$summary" ]] || return 1

  local state_modified_at
  if [[ "$(uname -s)" == "Darwin" ]]; then
    state_modified_at="$(stat -f %m "$auth_state" 2>/dev/null || printf '0')"
  else
    state_modified_at="$(stat -c %Y "$auth_state" 2>/dev/null || printf '0')"
  fi
  (( $(date +%s) - state_modified_at <= max_age_seconds )) || return 1

  node - "$summary" <<'NODE'
const fs = require('fs');

try {
  const summary = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  process.exit(summary.status === 'PASS' ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}
