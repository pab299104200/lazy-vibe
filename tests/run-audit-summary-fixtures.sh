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
04	04a-openapi	discovery	OpenAPI contract	04-contract/04a-openapi.md	PHASE 4A
EOF

cat > "$checkpoint" <<'EOF'
01a-auth
02a-browser
04a-openapi
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

cat > "$run_dir/logs/04a-openapi.log" <<'EOF'
RESULT: INCOMPLETE
OpenAPI request schema and response schema docs do not match the route contract.
EOF

mkdir -p "$run_dir/artifacts/04-contract"
cat > "$run_dir/artifacts/04-contract/04a-openapi.md" <<'EOF'
# OpenAPI contract

RESULT: INCOMPLETE
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
grep -q 'class=api_contract' "$summary" || fail "OpenAPI/API contract remediation class missing"
grep -q 'native_artifacts=' "$summary" || fail "native artifact context missing"
grep -q 'class=audit_output_missing' "$summary" || fail "missing-output class missing"
grep -q 'Remediation context' "$next_actions" || fail "next-actions context column missing"
grep -q '02a-browser-e2e-summary.md' "$next_actions" || fail "native summary not linked in next actions"

audit_repo="$tmp_root/audit-register-repo"
audit_run="$audit_repo/docs/audit/2026-06-12-launch-readiness-run"
audit_register="$audit_repo/docs/audit/register"
audit_jobs="$tmp_root/register-jobs.tsv"
mkdir -p "$audit_run" "$audit_register"
cat > "$audit_jobs" <<'EOF'
group	job_id	kind	title	output	ref
01	01a-tenant	discovery	Tenant scope	01-domain/01a-tenant.md	PHASE 1A
EOF
cat > "$audit_run/completed-jobs.txt" <<'EOF'
01a-tenant
EOF
mkdir -p "$audit_run/logs" "$audit_run/artifacts/01-domain"
cat > "$audit_run/logs/01a-tenant.log" <<'EOF'
RESULT: INCOMPLETE
EOF
cat > "$audit_run/artifacts/01-domain/01a-tenant.md" <<'EOF'
# P1 Tenant data is not scoped

RESULT: INCOMPLETE

backend/a.py:10 returns rows without tenant scope.
EOF
cat > "$audit_register/themes.yaml" <<'EOF'
themes:
  tenant_scope_missing:
    patterns: ["tenant"]
EOF

REPO_ROOT="$audit_repo" \
RUN_DIR="$audit_run" \
JOBS_FILE="$audit_jobs" \
REGISTER_DIR="$audit_register" \
MAX_PARALLEL=1 \
"$SCRIPT_DIR/run-audit.sh" >/tmp/lazy-vibe-audit-register-fixture.out 2>/tmp/lazy-vibe-audit-register-fixture.err || {
  sed -n '1,120p' /tmp/lazy-vibe-audit-register-fixture.out >&2 || true
  sed -n '1,160p' /tmp/lazy-vibe-audit-register-fixture.err >&2 || true
  fail "audit register reconcile hook failed"
}

[[ -s "$audit_run/00-blocker-ledger.tsv" ]] || fail "audit hook did not generate blocker ledger"
[[ -s "$audit_register/register.jsonl" ]] || fail "audit hook did not write register.jsonl"
[[ -s "$audit_register/baseline.json" ]] || fail "audit hook did not write baseline.json"
grep -q 'Tenant data is not scoped' "$audit_register/register.md" || fail "audit hook register report missing finding"
grep -q '2026-06-12-launch-readiness-run' "$audit_register/baseline.json" || fail "baseline missing run id"

differential_jobs="$tmp_root/differential-jobs.tsv"
cat > "$differential_jobs" <<'EOF'
group	job_id	kind	title	output	ref
00	00-bootstrap	discovery	Bootstrap inventories	00-orchestrator-plan.md	PHASE 0
01	01a-auth-sessions	discovery	Authentication and session handling	01-domain/01a-auth.md	PHASE 1A
01	01b-tenant-isolation	discovery	Tenant isolation and RLS	01-domain/01b-tenant.md	PHASE 1B
02	02a-backend-api	discovery	Backend API contracts	01-domain/02a-backend-api.md	PHASE 2A
02	02b-frontend-browser	discovery	Frontend browser UX	01-domain/02b-frontend-browser.md	PHASE 2B
03	03a-docs-contract	discovery	Documentation and API contracts	01-domain/03a-docs-contract.md	PHASE 3A
14	14a-runtime-backend	runtime	Backend runtime tests	10-runtime-verification.md#Backend	PHASE 14A
14	14b-runtime-frontend	runtime	Frontend runtime browser journeys	10-runtime-verification.md#Frontend	PHASE 14B
16	16a-adversarial-security	adversarial	Security boundaries	13-adversarial-review.md#Security	PHASE 16A
17	17-final-decision	final	Final release decision	14-final-release-decision.md	PHASE 17
EOF

diff_repo="$tmp_root/differential-repo"
diff_run="$diff_repo/docs/audit/differential-run"
diff_register="$diff_repo/docs/audit/register"
mkdir -p "$diff_repo/backend" "$diff_repo/docs/api" "$diff_register" "$diff_run"
git -C "$diff_repo" init -q
git -C "$diff_repo" config user.email lazy-vibe@example.invalid
git -C "$diff_repo" config user.name "Lazy Vibe Fixture"
cat > "$diff_repo/backend/a.py" <<'EOF'
def handler():
    return {"ok": True}
EOF
cat > "$diff_repo/docs/api/routes.md" <<'EOF'
# Routes
EOF
git -C "$diff_repo" add backend/a.py docs/api/routes.md
git -C "$diff_repo" commit -q -m baseline
baseline_sha="$(git -C "$diff_repo" rev-parse HEAD)"
cat > "$diff_register/baseline.json" <<EOF
{"git_sha": "$baseline_sha", "run_id": "baseline", "date": "2026-06-12"}
EOF
cat > "$diff_repo/backend/a.py" <<'EOF'
def handler(account_id):
    return {"account_id": account_id}
EOF
git -C "$diff_repo" add backend/a.py
git -C "$diff_repo" commit -q -m "backend change"

REPO_ROOT="$diff_repo" \
RUN_DIR="$diff_run" \
JOBS_FILE="$differential_jobs" \
REGISTER_DIR="$diff_register" \
AUDIT_REGISTER_RECONCILE=0 \
ACCESSIBILITY_SCAN=0 \
E2E_BROWSER_PROOF=0 \
EXTERNAL_SERVICES_TEST=0 \
LIGHTHOUSE_SCAN=0 \
SAST_ENABLED=0 \
"$SCRIPT_DIR/run-audit.sh" --dry-run --differential >/tmp/lazy-vibe-differential-backend.out 2>/tmp/lazy-vibe-differential-backend.err || {
  sed -n '1,120p' /tmp/lazy-vibe-differential-backend.out >&2 || true
  sed -n '1,160p' /tmp/lazy-vibe-differential-backend.err >&2 || true
  fail "backend differential dry-run failed"
}

backend_selected="$diff_run/artifacts/differential-jobs.tsv"
grep -q $'\t02a-backend-api\t' "$backend_selected" || fail "backend differential did not select backend API job"
grep -q $'\t14a-runtime-backend\t' "$backend_selected" || fail "backend differential did not select backend runtime job"
grep -q $'\t16a-adversarial-security\t' "$backend_selected" || fail "backend differential did not select security job"
grep -q $'\t17-final-decision\t' "$backend_selected" || fail "backend differential did not select final gate"
if grep -q $'\t14b-runtime-frontend\t' "$backend_selected"; then
  fail "backend differential selected frontend runtime job"
fi
grep -q 'backend/a.py' "$diff_run/artifacts/differential-scope.md" || fail "backend differential scope missing changed path"
grep -q 'changed endpoint, route, permission, state transition' "$diff_run/prompts/02a-backend-api.md" ||
  fail "backend differential prompt missing scoped enumeration contract"

docs_repo="$tmp_root/differential-docs-repo"
docs_run="$docs_repo/docs/audit/differential-run"
docs_register="$docs_repo/docs/audit/register"
mkdir -p "$docs_repo/docs/api" "$docs_register" "$docs_run"
git -C "$docs_repo" init -q
git -C "$docs_repo" config user.email lazy-vibe@example.invalid
git -C "$docs_repo" config user.name "Lazy Vibe Fixture"
cat > "$docs_repo/docs/api/routes.md" <<'EOF'
# Routes
EOF
git -C "$docs_repo" add docs/api/routes.md
git -C "$docs_repo" commit -q -m baseline
docs_baseline_sha="$(git -C "$docs_repo" rev-parse HEAD)"
cat > "$docs_register/baseline.json" <<EOF
{"git_sha": "$docs_baseline_sha", "run_id": "baseline", "date": "2026-06-12"}
EOF
cat > "$docs_repo/docs/api/routes.md" <<'EOF'
# Routes

GET /v1/accounts requires account:read.
EOF
git -C "$docs_repo" add docs/api/routes.md
git -C "$docs_repo" commit -q -m "docs change"

REPO_ROOT="$docs_repo" \
RUN_DIR="$docs_run" \
JOBS_FILE="$differential_jobs" \
REGISTER_DIR="$docs_register" \
AUDIT_REGISTER_RECONCILE=0 \
ACCESSIBILITY_SCAN=0 \
E2E_BROWSER_PROOF=0 \
EXTERNAL_SERVICES_TEST=0 \
LIGHTHOUSE_SCAN=0 \
SAST_ENABLED=0 \
"$SCRIPT_DIR/run-audit.sh" --dry-run --differential >/tmp/lazy-vibe-differential-docs.out 2>/tmp/lazy-vibe-differential-docs.err || {
  sed -n '1,120p' /tmp/lazy-vibe-differential-docs.out >&2 || true
  sed -n '1,160p' /tmp/lazy-vibe-differential-docs.err >&2 || true
  fail "docs differential dry-run failed"
}
docs_selected="$docs_run/artifacts/differential-jobs.tsv"
grep -q $'\t03a-docs-contract\t' "$docs_selected" || fail "docs differential did not select docs contract job"
grep -q $'\t17-final-decision\t' "$docs_selected" || fail "docs differential did not select final gate"
if grep -q $'\t14a-runtime-backend\t' "$docs_selected"; then
  fail "docs differential selected backend runtime job"
fi

missing_repo="$tmp_root/differential-missing-baseline"
missing_run="$missing_repo/docs/audit/differential-run"
missing_register="$missing_repo/docs/audit/register"
mkdir -p "$missing_repo/backend" "$missing_register" "$missing_run"
git -C "$missing_repo" init -q
git -C "$missing_repo" config user.email lazy-vibe@example.invalid
git -C "$missing_repo" config user.name "Lazy Vibe Fixture"
cat > "$missing_repo/backend/a.py" <<'EOF'
print("x")
EOF
git -C "$missing_repo" add backend/a.py
git -C "$missing_repo" commit -q -m baseline
if REPO_ROOT="$missing_repo" \
  RUN_DIR="$missing_run" \
  JOBS_FILE="$differential_jobs" \
  REGISTER_DIR="$missing_register" \
  AUDIT_REGISTER_RECONCILE=0 \
  "$SCRIPT_DIR/run-audit.sh" --dry-run --differential >/tmp/lazy-vibe-differential-missing.out 2>/tmp/lazy-vibe-differential-missing.err; then
  fail "differential audit succeeded without baseline"
fi
grep -q 'Run a full audit first or rerun with --full' /tmp/lazy-vibe-differential-missing.err ||
  fail "missing baseline error was not actionable"

context_repo="$tmp_root/register-context-repo"
context_run="$context_repo/docs/audit/context-run"
context_register="$context_repo/docs/audit/register"
context_jobs="$tmp_root/register-context-jobs.tsv"
mkdir -p "$context_repo" "$context_run" "$context_register"
cat > "$context_jobs" <<'EOF'
group	job_id	kind	title	output	ref
01	01a-context	discovery	Context check	01-domain/01a-context.md	PHASE 1A
EOF
cat > "$context_register/register.jsonl" <<'EOF'
{"description":"Known active issue","disposition":"new","disposition_by":"ingest","disposition_reason":"","evidence":[{"ref":"backend/a.py:10"}],"fingerprint":"sha256:11111111111111111111111111111111","fingerprint_inputs":{"category":"product_gap","path":"backend/a.py","symbol":"handler","theme":"tenant_scope_missing"},"finding_id":"R-0001","first_seen":{"date":"2026-06-12","run_id":"r1"},"history":[],"in_scope":true,"last_seen":{"date":"2026-06-12","run_id":"r1"},"occurrences":3,"regression_test":null,"review_by":null,"severity":"P1","severity_source":"proposed","taxonomy":"B","title":"Known active tenant scope issue"}
{"description":"Known false positive","disposition":"false_positive","disposition_by":"pete","disposition_reason":"Not exploitable in current design","evidence":[{"ref":"backend/b.py:20"}],"fingerprint":"sha256:22222222222222222222222222222222","fingerprint_inputs":{"category":"evidence_gap","path":"backend/b.py","symbol":"collector","theme":"browser_evidence_missing"},"finding_id":"R-0002","first_seen":{"date":"2026-06-12","run_id":"r1"},"history":[{"event":"disposition","from":"new","to":"false_positive"}],"in_scope":true,"last_seen":{"date":"2026-06-12","run_id":"r1"},"occurrences":5,"regression_test":null,"review_by":null,"severity":"P2","severity_source":"adjudicated","taxonomy":"G","title":"Known adjudicated browser evidence false positive"}
EOF

REPO_ROOT="$context_repo" \
RUN_DIR="$context_run" \
JOBS_FILE="$context_jobs" \
REGISTER_DIR="$context_register" \
"$SCRIPT_DIR/run-audit.sh" --dry-run >/tmp/lazy-vibe-register-context.out 2>/tmp/lazy-vibe-register-context.err || {
  sed -n '1,120p' /tmp/lazy-vibe-register-context.out >&2 || true
  sed -n '1,160p' /tmp/lazy-vibe-register-context.err >&2 || true
  fail "register context dry-run failed"
}
grep -q 'Known active tenant scope issue' "$context_run/prompts/01a-context.md" ||
  fail "audit prompt missing active register context"
grep -q 'Known adjudicated browser evidence false positive' "$context_run/prompts/01a-context.md" ||
  fail "audit prompt missing suppressed register context"
grep -q 'Do not report a new finding that is materially identical' "$context_run/prompts/01a-context.md" ||
  fail "audit prompt missing duplicate suppression instruction"

grep -q 'Your job is accurate dispositions, not finding count' "$SCRIPT_DIR/generic-shared.md" || fail "prompt calibration accuracy contract missing"
grep -q 'Closest severity anchor must be cited' "$SCRIPT_DIR/generic-shared.md" || fail "severity anchors missing"
if rg -n "If you find zero bugs|didn.t look hard|Red is good" "$SCRIPT_DIR"/generic-*.md >/tmp/lazy-vibe-prompt-calibration-grep.out 2>/tmp/lazy-vibe-prompt-calibration-grep.err; then
  cat /tmp/lazy-vibe-prompt-calibration-grep.out >&2
  fail "old finding-count incentive language is present"
fi

printf 'PASS audit summary fixtures\n'
