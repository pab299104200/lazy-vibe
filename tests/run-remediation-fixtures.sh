#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

write_packet() {
  local dir="$1" packet_id="$2" status="$3"
  cat > "$dir/packets/$packet_id.md" <<EOF
# $packet_id

## Work Log

- Status: \`$status\`
EOF
}

write_verifier() {
  local dir="$1" unit_id="$2" decision="$3" implementation_decision="$4" launch_decision="${5:-complete}"
  cat > "$dir/artifacts/verify-$unit_id.md" <<EOF
# Verification: $unit_id

- Decision: $decision
- Implementation decision: $implementation_decision
- Launch evidence decision: $launch_decision

Packets checked for $unit_id.
EOF
}

write_findings() {
  local dir="$1" unit_id="$2"
  shift 2
  local file="$dir/artifacts/verify-$unit_id-findings.tsv"
  printf 'unit_id\tseverity\ttype\tfile\tline\tfinding\trequired_fix\n' > "$file"
  local row
  for row in "$@"; do
    printf '%s\n' "$row" >> "$file"
  done
}

write_summary() {
  local dir="$1" unit_id="$2" result="$3"
  cat > "$dir/artifacts/$unit_id-summary.md" <<EOF
# $unit_id implementation summary

IMPLEMENTATION_RESULT: $result
EOF
}

queue_category() {
  local queue="$1" unit_id="$2"
  awk -F '\t' -v unit="$unit_id" 'NR > 1 && $1 == unit { print $5; found = 1; exit } END { if (!found) exit 1 }' "$queue"
}

summary_decision() {
  local summary="$1" unit_id="$2"
  awk -F '\t' -v unit="$unit_id" 'NR > 1 && $1 == unit { print $4 "\t" $5; found = 1; exit } END { if (!found) exit 1 }' "$summary"
}

run_summary_only() {
  local repo="$1" audit="$2" remediation="$3"
  REPO_ROOT="$repo" \
  REMEDIATION_DIR="$remediation" \
  REMEDIATION_SCRIPT_SNAPSHOT=1 \
  "$SCRIPT_DIR/run-remediation.sh" \
    --audit-run "$audit" \
    --summary-only \
    --no-catalog >/tmp/lazy-vibe-remediation-fixture.out 2>/tmp/lazy-vibe-remediation-fixture.err || {
      sed -n '1,120p' /tmp/lazy-vibe-remediation-fixture.out >&2 || true
      sed -n '1,160p' /tmp/lazy-vibe-remediation-fixture.err >&2 || true
      fail "summary-only run failed"
    }
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lazy-vibe-remediation-fixtures.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/repo"
audit="$repo/docs/audit/fixture-launch-readiness-run"
remediation="$repo/docs/audit/fixture-remediation-run"
mkdir -p "$audit" "$repo" "$remediation"/{packets,prompts,logs,artifacts}

cat > "$remediation/00-master-px-list.tsv" <<'EOF'
packet_id	severity	group	title	source_file	source_line	finding	rationale
PX-0001	P1	quality	Accepted	fixture.md	1	accepted	row
PX-0002	P1	quality	Evidence pending	fixture.md	2	evidence	row
PX-0003	P1	quality	API contract	fixture.md	3	api	row
PX-0004	P1	quality	No verifier	fixture.md	4	missing	row
PX-0005	P1	quality	Test harness	fixture.md	5	harness	row
PX-0006	P1	quality	Contract conflict	fixture.md	6	contract	row
PX-0007	P1	quality	Split parent pending	fixture.md	7	split	row
PX-0007-S01	P1	quality	Split child pending	fixture.md	8	child	row
PX-0008	P1	quality	Split parent done	fixture.md	9	split	row
PX-0008-S01	P1	quality	Split child done	fixture.md	10	child	row
PX-0009	P1	quality	Stale verifier	fixture.md	11	stale	row
PX-0010	P1	quality	Postcheck invalid	fixture.md	12	postcheck	row
PX-0011	P1	quality	Evidence failed	fixture.md	13	evidence	row
PX-0012	P1	quality	Resolved evidence	fixture.md	14	resolved	row
PX-0013	P1	quality	Blocked	fixture.md	15	blocked	row
PX-0014	P1	quality	Boundary tests	fixture.md	16	boundary	row
PX-0015	P1	quality	Operability	fixture.md	17	operability	row
PX-0016	P1	quality	Static analysis	fixture.md	18	static	row
EOF

cat > "$remediation/02-workstreams.tsv" <<'EOF'
group	packets	model_class	rationale
quality	PX-0001,PX-0002,PX-0003,PX-0004,PX-0005,PX-0006,PX-0007,PX-0008,PX-0009,PX-0010,PX-0011,PX-0012,PX-0013,PX-0014,PX-0015,PX-0016	standard	fixture
EOF

cat > "$remediation/03-implementation-units.tsv" <<'EOF'
unit_id	packets	group	model_class	severity	rationale
IU-0001	PX-0001	quality	standard	P1	accepted
IU-0002	PX-0002	quality	standard	P1	evidence pending
IU-0003	PX-0003	quality	standard	P1	api contract
IU-0004	PX-0004	quality	standard	P1	no verifier
IU-0005	PX-0005	quality	standard	P1	test harness
IU-0006	PX-0006	quality	standard	P1	contract conflict
IU-0007	PX-0007	quality	standard	P1	split parent pending
IU-0007-S01	PX-0007-S01	quality	standard	P1	split child pending
IU-0008	PX-0008	quality	standard	P1	split parent done
IU-0008-S01	PX-0008-S01	quality	standard	P1	split child done
IU-0009	PX-0009	quality	standard	P1	stale verifier
IU-0010	PX-0010	quality	standard	P1	postcheck invalid
IU-0011	PX-0011	quality	standard	P1	evidence failed
IU-0012	PX-0012	quality	standard	P1	resolved evidence
IU-0013	PX-0013	quality	standard	P1	blocked
IU-0014	PX-0014	quality	standard	P1	boundary tests
IU-0015	PX-0015	quality	standard	P1	operability
IU-0016	PX-0016	quality	standard	P1	static analysis
EOF

for packet in PX-0001 PX-0002 PX-0003 PX-0004 PX-0005 PX-0006 PX-0009 PX-0010 PX-0011 PX-0012 PX-0013 PX-0014 PX-0015 PX-0016; do
  write_packet "$remediation" "$packet" complete
done
write_packet "$remediation" PX-0007 split-into-child-units
write_packet "$remediation" PX-0007-S01 not-started
write_packet "$remediation" PX-0008 split-into-child-units
write_packet "$remediation" PX-0008-S01 complete

for unit in IU-0001 IU-0002 IU-0003 IU-0005 IU-0006 IU-0008-S01 IU-0009 IU-0010 IU-0011 IU-0012 IU-0013 IU-0014 IU-0015 IU-0016; do
  write_verifier "$remediation" "$unit" accept fixed complete
  write_findings "$remediation" "$unit"
  write_summary "$remediation" "$unit" fixed
done

write_findings "$remediation" IU-0002 $'IU-0002\tP1\tlaunch_evidence\te2e\t1\tbrowser proof pending\trun supported browser proof'
write_findings "$remediation" IU-0003 $'IU-0003\tP1\tapi_contract\tdocs/api.md\t1\tcontract docs missing\tadd request response permissions errors'
write_verifier "$remediation" IU-0005 revise revise pending
write_findings "$remediation" IU-0005 $'IU-0005\tP1\ttest_harness\ttests/e2e.spec.ts\t1\tflaky broad suite\tprovide targeted command'
write_verifier "$remediation" IU-0006 stop blocked blocked
write_findings "$remediation" IU-0006 $'IU-0006\tP1\tcontract_conflict\tdocs/contract.md\t1\tcode and docs disagree\tmake product decision'
write_findings "$remediation" IU-0012 $'IU-0012\tP1\tlaunch_evidence\te2e\t1\tdepends on IU-0001 proof\tIU-0001 accepted covers this evidence'
write_verifier "$remediation" IU-0013 stop blocked blocked
write_findings "$remediation" IU-0013 $'IU-0013\tP1\tblocked\texternal\t1\tneeds credentials\tprovide credentials'
write_summary "$remediation" IU-0013 blocked
write_findings "$remediation" IU-0014 $'IU-0014\tP1\tboundary_tests\ttests/boundary.py\t1\tmissing tenant negative\tadd permanent boundary test'
write_findings "$remediation" IU-0015 $'IU-0015\tP1\toperability\tjobs/sync.py\t1\tmissing job status\tadd logs and recovery state'
write_findings "$remediation" IU-0016 $'IU-0016\tP1\tstatic_analysis\tsrc/service.py\t1\tcomplexity gate missing\trun radon or profile command'
cat > "$remediation/artifacts/IU-0016-summary.md" <<'EOF'
# IU-0016 implementation summary

**IMPLEMENTATION_RESULT:** fixed
EOF

for verifier in "$remediation"/artifacts/verify-*.md; do
  [[ "$verifier" == *verify-IU-0009.md ]] && continue
  touch "$verifier"
done

mkdir -p "$remediation/artifacts/IU-0011"
cat > "$remediation/artifacts/IU-0011/browser.status" <<'EOF'
COMMAND: npx playwright test e2e/proof.spec.ts
STATUS: fail
EOF

printf 'stale active-checkout evidence\n' > "$remediation/artifacts/verify-IU-0010.postcheck.invalid"
cat >> "$remediation/artifacts/verify-IU-0010.md" <<'EOF'

Acceptance signed off using remediation worktree evidence under /tmp/remediation/worktrees/IU-0010.
EOF

# Make IU-0009 implementation evidence newer than its verifier so the queue
# cannot accept stale verifier signoff.
sleep 1
write_summary "$remediation" IU-0009 fixed

run_summary_only "$repo" "$audit" "$remediation"

queue="$remediation/07-remediation-queue.tsv"
summary="$remediation/06-run-summary.tsv"
triage="$remediation/08-manual-triage.md"
[[ -s "$queue" ]] || fail "queue was not generated"
[[ -s "$summary" ]] || fail "summary was not generated"
[[ -s "$triage" ]] || fail "manual triage index was not generated"

assert_equals accepted "$(queue_category "$queue" IU-0001)" "accepted category"
assert_equals accepted_evidence_pending "$(queue_category "$queue" IU-0002)" "launch evidence category"
assert_equals needs_targeted_revision "$(queue_category "$queue" IU-0003)" "api_contract category"
assert_equals not_verified "$(queue_category "$queue" IU-0004)" "missing verifier category"
assert_equals test_harness "$(queue_category "$queue" IU-0005)" "test harness category"
assert_equals contract_conflict "$(queue_category "$queue" IU-0006)" "contract conflict category"
assert_equals split_children_pending "$(queue_category "$queue" IU-0007)" "split pending category"
assert_equals split_decomposed "$(queue_category "$queue" IU-0008)" "split decomposed category"
assert_equals not_verified "$(queue_category "$queue" IU-0009)" "stale verifier category"
assert_equals needs_targeted_revision "$(queue_category "$queue" IU-0010)" "postcheck invalid category"
assert_equals evidence_failed "$(queue_category "$queue" IU-0011)" "failed evidence category"
assert_equals accepted "$(queue_category "$queue" IU-0012)" "dependency-resolved evidence category"
assert_equals blocked "$(queue_category "$queue" IU-0013)" "blocked category"
assert_equals needs_targeted_revision "$(queue_category "$queue" IU-0014)" "boundary_tests category"
assert_equals needs_targeted_revision "$(queue_category "$queue" IU-0015)" "operability category"
assert_equals needs_targeted_revision "$(queue_category "$queue" IU-0016)" "static_analysis category"

assert_equals $'fixed\taccept' "$(summary_decision "$summary" IU-0001)" "accepted summary"
assert_equals $'blocked\tstop' "$(summary_decision "$summary" IU-0013)" "blocked summary"
assert_equals $'fixed\taccept' "$(summary_decision "$summary" IU-0016)" "bold implementation result summary"

for unit in IU-0005 IU-0006 IU-0013; do
  [[ -s "$remediation/artifacts/triage-$unit.md" ]] || fail "triage artifact missing for $unit"
done
grep -q 'flaky broad suite' "$remediation/artifacts/triage-IU-0005.md" || fail "test harness reason missing"
grep -q 'code and docs disagree' "$remediation/artifacts/triage-IU-0006.md" || fail "contract conflict reason missing"
grep -q 'needs credentials' "$remediation/artifacts/triage-IU-0013.md" || fail "blocked reason missing"
grep -q 'Do not rerun broad product-code remediation blindly' "$remediation/artifacts/triage-IU-0005.md" || fail "test harness next action missing"
grep -q 'Resolve the product/security contract first' "$remediation/artifacts/triage-IU-0006.md" || fail "contract next action missing"
grep -q 'External input, access, dependency, or human decision is required' "$remediation/artifacts/triage-IU-0013.md" || fail "blocked next action missing"
grep -q 'command_is_long_running_server' "$SCRIPT_DIR/run-remediation.sh" || fail "long-running command guard missing"
grep -q 'refused long-running server command' "$SCRIPT_DIR/run-remediation.sh" || fail "long-running command refusal log missing"
grep -q 'npm run dev' "$SCRIPT_DIR/run-remediation.sh" || fail "npm dev-server guard missing"
grep -q 'command_is_unscoped_broad_native_test' "$SCRIPT_DIR/run-remediation.sh" || fail "broad native-test guard missing"
grep -q 'refused unscoped broad verification command' "$SCRIPT_DIR/run-remediation.sh" || fail "broad native-test refusal log missing"
grep -q 'cd frontend && npx playwright test' "$SCRIPT_DIR/run-remediation.sh" || fail "unscoped Playwright guard missing"
if grep -q 'test_status=124' "$SCRIPT_DIR/run-remediation.sh"; then
  fail "long-running command refusal must not fail the implementation step"
fi

printf 'PASS run-remediation fixture categories\n'
