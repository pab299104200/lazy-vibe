#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_tsv_field() {
  local file="$1" job_id="$2" column="$3" expected="$4" actual
  actual="$(awk -F '\t' -v job="$job_id" -v col="$column" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i == col) idx = i
      }
      next
    }
    $1 == job {
      print $idx
      found = 1
      exit
    }
    END {
      if (!found) exit 1
    }
  ' "$file")" || fail "missing $job_id/$column in $file"
  [[ "$actual" == "$expected" ]] || fail "$job_id/$column: expected '$expected', got '$actual'"
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lazy-vibe-audit-summary.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/repo"
run_dir="$repo/docs/audit/fixture-run"
jobs_file="$tmp_root/jobs.tsv"
checkpoint="$run_dir/.completed-jobs"
summary="$run_dir/00-run-summary.tsv"
next_actions="$run_dir/failed-jobs-next-actions.md"
mkdir -p "$run_dir"/{artifacts,logs} "$repo"

cat > "$jobs_file" <<'EOF'
group	job_id	kind	title	output	ref
01	01a-auth	discovery	Auth sessions	01-domain/01a-auth.md	PHASE 1A
02	02a-browser	runtime	Browser workflow	02-runtime/02a-browser.md	PHASE 2A
03	03a-contract	discovery	API contracts	03-contract/03a-contract.md	PHASE 3A
EOF

cat > "$checkpoint" <<'EOF'
01a-auth
02a-browser
EOF

cat > "$run_dir/logs/01a-auth.log" <<'EOF'
RESULT: PASS
EOF

cat > "$run_dir/logs/02a-browser.log" <<'EOF'
RESULT: INCOMPLETE
Playwright browser proof failed with 401 from /auth/session.
EOF

mkdir -p "$run_dir/artifacts/02-runtime"
cat > "$run_dir/artifacts/02-runtime/02a-browser.md" <<'EOF'
# Browser workflow

RESULT: INCOMPLETE
EOF

cat > "$run_dir/artifacts/02a-browser-e2e-summary.md" <<'EOF'
# Browser summary

STATUS: fail
playwright session bootstrap failed
EOF

cat > "$run_dir/logs/03a-contract.log" <<'EOF'
[missing-output] runner exited without artifact
EOF

PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m lazy_vibe.audit.summary \
  --run-dir "$run_dir" \
  --jobs-file "$jobs_file" \
  --checkpoint-file "$checkpoint" \
  --repo-root "$repo" \
  --script-path "$SCRIPT_DIR/run-audit.sh" \
  --summary-file "$summary" \
  --next-actions-file "$next_actions"

[[ -s "$summary" ]] || fail "summary not written"
[[ -s "$next_actions" ]] || fail "next actions not written"

header="$(head -1 "$summary")"
[[ "$header" == $'job_id\tkind\tresult\tgroup\ttitle\toutput\tlog_path\tremediation_context' ]] ||
  fail "unexpected summary header: $header"

assert_tsv_field "$summary" 01a-auth result PASS
assert_tsv_field "$summary" 02a-browser result INCOMPLETE
assert_tsv_field "$summary" 02a-browser group 02
grep -q 'class=runtime_or_browser_evidence' "$summary" || fail "browser remediation class missing"
grep -q 'native_artifacts=' "$summary" || fail "native artifact context missing"
grep -q 'class=audit_output_missing' "$summary" || fail "missing-output class missing"
grep -q 'Remediation context' "$next_actions" || fail "next-actions context column missing"
grep -q '02a-browser-e2e-summary.md' "$next_actions" || fail "native summary not linked in next actions"

printf 'PASS audit summary fixtures\n'
