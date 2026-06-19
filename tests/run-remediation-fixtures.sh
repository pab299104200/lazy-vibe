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

next_action() {
  local plan="$1" unit_id="$2"
  awk -F '\t' -v unit="$unit_id" 'NR > 1 && $1 == unit { print $3; found = 1; exit } END { if (!found) exit 1 }' "$plan"
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

register_repo="$tmp_root/register-repo"
register_audit="$register_repo/docs/audit/fixture-launch-readiness-run"
register_dir="$register_repo/docs/audit/register"
register_remediation="$register_repo/docs/audit/register-remediation-run"
mkdir -p "$register_audit" "$register_dir"
python3 - "$register_dir" <<'PY'
import sys
from pathlib import Path

from lazy_vibe.register.model import Disposition
from lazy_vibe.register.store import RegisterStore
from lazy_vibe.register.transitions import transition
from tests.register.test_model import make_finding

register_dir = Path(sys.argv[1])
now = "2026-06-11T00:00:00+00:00"

open_finding = make_finding(
    finding_id="R-0001",
    fingerprint="sha256:1",
    fingerprint_inputs={
        "category": "product_gap",
        "theme": "tenant_scope_missing",
        "path": "backend/a.py",
        "symbol": "A",
    },
    title="Open finding",
    description="Open register-backed finding.",
    evidence=[{"type": "code", "ref": "backend/a.py:10", "run_id": "run1"}],
    occurrences=2,
)
transition(open_finding, Disposition.OPEN, by="pete", reason="real",
           now=now, verified=True)

regressed = make_finding(
    finding_id="R-0002",
    fingerprint="sha256:2",
    fingerprint_inputs={
        "category": "product_gap",
        "theme": "tenant_scope_missing",
        "path": "backend/b.py",
        "symbol": "B",
    },
    title="Regressed finding",
    description="Regressed register-backed finding.",
    severity="P0",
    evidence=[{"type": "code", "ref": "backend/b.py:20", "run_id": "run2"}],
)
transition(regressed, Disposition.OPEN, by="pete", reason="real",
           now=now, verified=True)
transition(regressed, Disposition.IN_REMEDIATION, by="harness",
           reason="unit", now=now)
transition(regressed, Disposition.FIXED, by="harness", reason="fixed",
           now=now, regression_test="tests/test_b.py::test_old")
transition(regressed, Disposition.REGRESSED, by="reconciler",
           reason="reappeared", now=now)

new_finding = make_finding(
    finding_id="R-0003",
    fingerprint="sha256:3",
    fingerprint_inputs={
        "category": "product_gap",
        "theme": "tenant_scope_missing",
        "path": "backend/c.py",
        "symbol": "C",
    },
    title="New finding",
    description="New register-backed finding.",
    evidence=[{"type": "code", "ref": "backend/c.py:30", "run_id": "run1"}],
)

false_positive = make_finding(
    finding_id="R-0004",
    fingerprint="sha256:4",
    fingerprint_inputs={
        "category": "product_gap",
        "theme": "tenant_scope_missing",
        "path": "backend/d.py",
        "symbol": "D",
    },
    title="False positive finding",
    description="False-positive register-backed finding.",
    evidence=[{"type": "code", "ref": "backend/d.py:40", "run_id": "run1"}],
)
transition(false_positive, Disposition.FALSE_POSITIVE, by="pete",
           reason="unsupported", now=now)

no_line_open = make_finding(
    finding_id="R-0005",
    fingerprint="sha256:5",
    fingerprint_inputs={
        "category": "product_gap",
        "theme": "tenant_scope_missing",
        "path": "backend/no_line.py",
        "symbol": "NoLine",
    },
    title="Open finding without numeric source line",
    description="Open register-backed finding with file-level evidence.",
    evidence=[{"type": "code", "ref": "backend/no_line.py:-", "run_id": "run1"}],
)
transition(no_line_open, Disposition.OPEN, by="pete", reason="real",
           now=now, verified=True)

RegisterStore(register_dir).save({
    finding.finding_id: finding
    for finding in [
        open_finding,
        regressed,
        new_finding,
        false_positive,
        no_line_open,
    ]
})
PY

REPO_ROOT="$register_repo" \
REPO_ROOT="$register_repo" \
REGISTER_DIR="$register_dir" \
REMEDIATION_DIR="$register_remediation" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
"$SCRIPT_DIR/run-remediation.sh" \
  --audit-run "$register_audit" \
  --no-catalog >/tmp/lazy-vibe-register-remediation-fixture.out 2>/tmp/lazy-vibe-register-remediation-fixture.err || {
    sed -n '1,120p' /tmp/lazy-vibe-register-remediation-fixture.out >&2 || true
    sed -n '1,160p' /tmp/lazy-vibe-register-remediation-fixture.err >&2 || true
    fail "register-backed remediation plan generation failed"
  }

assert_equals "3" "$(tail -n +2 "$register_remediation/00-register-px-map.tsv" | wc -l | tr -d ' ')" "register-backed packet count"
grep -q $'PX-0001\tR-0002\tregressed' "$register_remediation/00-register-px-map.tsv" || fail "regressed finding not first by severity"
grep -q $'PX-0002\tR-0001\topen' "$register_remediation/00-register-px-map.tsv" || fail "open finding missing"
grep -q $'PX-0003\tR-0005\topen' "$register_remediation/00-register-px-map.tsv" || fail "open no-line finding missing"
if grep -Eq 'R-0003|R-0004' "$register_remediation/00-register-px-map.tsv"; then
  fail "register-backed remediation included non-open/non-regressed finding"
fi
grep -q 'Register finding: `R-0002`' "$register_remediation/packets/PX-0001.md" || fail "packet missing register context"
grep -q 'Source: `backend/no_line.py:-`' "$register_remediation/packets/PX-0003.md" || fail "packet did not normalize file-level evidence source"

rm -f "$register_remediation/packets/PX-0003.md"
REPO_ROOT="$register_repo" \
REGISTER_DIR="$register_dir" \
REMEDIATION_DIR="$register_remediation" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
"$SCRIPT_DIR/run-remediation.sh" \
  --audit-run "$register_audit" \
  --dry-run \
  --no-catalog >/tmp/lazy-vibe-register-remediation-resume-fixture.out 2>/tmp/lazy-vibe-register-remediation-resume-fixture.err || {
    sed -n '1,120p' /tmp/lazy-vibe-register-remediation-resume-fixture.out >&2 || true
    sed -n '1,160p' /tmp/lazy-vibe-register-remediation-resume-fixture.err >&2 || true
    fail "register-backed remediation resume after partial packet generation failed"
  }
[[ -f "$register_remediation/packets/PX-0003.md" ]] || fail "resume did not recreate missing packet"

register_remediation_no_audit="$register_repo/docs/audit/register-remediation-no-audit-run"
REPO_ROOT="$register_repo" \
REGISTER_DIR="$register_dir" \
REMEDIATION_REGISTER_SOURCE=1 \
REMEDIATION_DIR="$register_remediation_no_audit" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
"$SCRIPT_DIR/run-remediation.sh" \
  --no-catalog >/tmp/lazy-vibe-register-remediation-no-audit.out 2>/tmp/lazy-vibe-register-remediation-no-audit.err || {
    sed -n '1,120p' /tmp/lazy-vibe-register-remediation-no-audit.out >&2 || true
    sed -n '1,160p' /tmp/lazy-vibe-register-remediation-no-audit.err >&2 || true
    fail "register-backed remediation without --audit-run failed"
  }
grep -q '\[register\] using register remediation source:' \
  /tmp/lazy-vibe-register-remediation-no-audit.out || fail "register source was not selected without --audit-run"
assert_equals "3" "$(tail -n +2 "$register_remediation_no_audit/00-register-px-map.tsv" | wc -l | tr -d ' ')" \
  "register-backed packet count without audit-run"

register_verifier="$tmp_root/register-verifier.sh"
cat > "$register_verifier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
_prompt="$1"
remediation="$2"
workstream="$3"
mkdir -p "$remediation/artifacts"
case "$workstream" in
  verify-*)
    unit="${workstream#verify-}"
    cat > "$remediation/artifacts/verify-$unit.md" <<VERIFY
# Verification: $unit

- Decision: accept
- Implementation decision: fixed
- Launch evidence decision: complete
- Regression test: tests/test_register_fix.py::test_register_fix

Packet $unit accepted from active checkout.
VERIFY
    printf 'unit_id\tseverity\ttype\tfile\tline\tfinding\trequired_fix\n' \
      > "$remediation/artifacts/verify-$unit-findings.tsv"
    ;;
  99-final-review)
    printf '# Final Review\n\nPASS\n' > "$remediation/04-final-remediation-review.md"
    ;;
esac
EOF
chmod +x "$register_verifier"

REGISTER_DIR="$register_dir" \
REPO_ROOT="$register_repo" \
REMEDIATION_DIR="$register_remediation" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
REVIEWER_AGENT=none \
VERIFICATION_RUNNER="$register_verifier" \
REVIEW_RUNNER="$register_verifier" \
"$SCRIPT_DIR/run-remediation.sh" \
  --audit-run "$register_audit" \
  --verify-only \
  --only-unit PX-0002 \
  --no-catalog >/tmp/lazy-vibe-register-close-fixture.out 2>/tmp/lazy-vibe-register-close-fixture.err || {
    sed -n '1,140p' /tmp/lazy-vibe-register-close-fixture.out >&2 || true
    sed -n '1,180p' /tmp/lazy-vibe-register-close-fixture.err >&2 || true
    fail "register-backed verifier close failed"
  }

closed_state="$(
  python3 - "$register_dir/register.jsonl" <<'PY'
import json
import sys
for line in open(sys.argv[1]):
    finding = json.loads(line)
    if finding["finding_id"] == "R-0001":
        print(finding["disposition"] + "\t" + str(finding.get("regression_test")))
PY
)"
assert_equals $'fixed\ttests/test_register_fix.py::test_register_fix' "$closed_state" "accepted verifier did not close register finding"

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
PX-0017	P1	quality	Native artifact repair	fixture.md	19	native artifact	row
PX-0018	P1	quality	Split parent blocked child	fixture.md	20	split row
PX-0018-S01	P1	quality	Split child blocked	fixture.md	21	child blocked row
EOF

cat > "$remediation/02-workstreams.tsv" <<'EOF'
group	packets	model_class	rationale
quality	PX-0001,PX-0002,PX-0003,PX-0004,PX-0005,PX-0006,PX-0007,PX-0008,PX-0009,PX-0010,PX-0011,PX-0012,PX-0013,PX-0014,PX-0015,PX-0016,PX-0017,PX-0018	standard	fixture
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
IU-0017	PX-0017	quality	standard	P1	native artifact repair
IU-0018	PX-0018	quality	standard	P1	split parent blocked child
IU-0018-S01	PX-0018-S01	quality	standard	P1	split child blocked
EOF

for packet in PX-0001 PX-0002 PX-0003 PX-0004 PX-0005 PX-0006 PX-0009 PX-0010 PX-0011 PX-0012 PX-0013 PX-0014 PX-0015 PX-0016 PX-0017; do
  write_packet "$remediation" "$packet" complete
done
write_packet "$remediation" PX-0007 split-into-child-units
write_packet "$remediation" PX-0007-S01 not-started
write_packet "$remediation" PX-0008 split-into-child-units
write_packet "$remediation" PX-0008-S01 complete
write_packet "$remediation" PX-0018 split-into-child-units
write_packet "$remediation" PX-0018-S01 complete

for unit in IU-0001 IU-0002 IU-0003 IU-0005 IU-0006 IU-0008-S01 IU-0009 IU-0010 IU-0011 IU-0012 IU-0013 IU-0014 IU-0015 IU-0016; do
  write_verifier "$remediation" "$unit" accept fixed complete
  write_findings "$remediation" "$unit"
  write_summary "$remediation" "$unit" fixed
done

write_findings "$remediation" IU-0002 $'IU-0002\tP1\tlaunch_evidence\te2e\t1\tbrowser proof pending\trun supported browser proof'
write_findings "$remediation" IU-0003 $'IU-0003\tP1\tapi_contract\tdocs/api.md\t1\tcontract docs missing\tadd request response permissions errors'
write_verifier "$remediation" IU-0005 revise revise pending
write_findings "$remediation" IU-0005 $'IU-0005\tP1\ttest_harness\ttests/e2e.spec.ts\t1\tflaky broad suite\tprovide targeted command'
write_verifier "$remediation" IU-0017 revise revise pending
write_findings "$remediation" IU-0017 "IU-0017"$'\tP1\ttest_harness\t'"$remediation"$'/artifacts/IU-0017-native-test-deadbeef.sh'$'\t3\tMalformed native-test script exits with command not found\tRegenerate native-test evidence artifact'
write_summary "$remediation" IU-0017 fixed
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
write_verifier "$remediation" IU-0018-S01 stop blocked blocked
write_findings "$remediation" IU-0018-S01 $'IU-0018-S01\tP1\tblocked\texternal\t1\tneeds production credential\tprovide credential'
write_summary "$remediation" IU-0018-S01 blocked

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
plan="$remediation/09-next-actions.tsv"
summary="$remediation/06-run-summary.tsv"
triage="$remediation/08-manual-triage.md"
[[ -s "$queue" ]] || fail "queue was not generated"
[[ -s "$plan" ]] || fail "next-action plan was not generated"
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
assert_equals test_harness "$(queue_category "$queue" IU-0017)" "native artifact category"
assert_equals split_children_pending "$(queue_category "$queue" IU-0018)" "blocked split child category"

assert_equals none "$(next_action "$plan" IU-0001)" "accepted next action"
assert_equals evidence_only "$(next_action "$plan" IU-0002)" "evidence next action"
assert_equals targeted_revision "$(next_action "$plan" IU-0003)" "api contract next action"
assert_equals implement_then_verify "$(next_action "$plan" IU-0004)" "missing implementation next action"
assert_equals manual_test_harness "$(next_action "$plan" IU-0005)" "manual test harness next action"
assert_equals manual_contract_decision "$(next_action "$plan" IU-0006)" "contract next action"
assert_equals run_split_children "$(next_action "$plan" IU-0007)" "split child next action"
assert_equals split_parent_noop "$(next_action "$plan" IU-0008)" "split parent noop next action"
assert_equals verify_only "$(next_action "$plan" IU-0009)" "stale verifier next action"
assert_equals evidence_repair "$(next_action "$plan" IU-0011)" "failed evidence next action"
assert_equals manual_blocked "$(next_action "$plan" IU-0013)" "blocked next action"
assert_equals artifact_repair "$(next_action "$plan" IU-0017)" "native-test artifact next action"
assert_equals child_manual_blockers "$(next_action "$plan" IU-0018)" "blocked split child next action"

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

parallel_repo="$tmp_root/parallel-repo"
parallel_audit="$parallel_repo/docs/audit/fixture-launch-readiness-run"
parallel_remediation="$parallel_repo/docs/audit/fixture-remediation-run"
mkdir -p "$parallel_repo" "$parallel_audit" "$parallel_remediation"/{packets,prompts,logs,artifacts}
git -C "$parallel_repo" init -q
git -C "$parallel_repo" config user.email "fixture@example.test"
git -C "$parallel_repo" config user.name "Fixture Runner"
mkdir -p "$parallel_repo/src"
printf '# fixture\n' > "$parallel_repo/README.md"
git -C "$parallel_repo" add README.md src
git -C "$parallel_repo" commit -q -m "initial fixture"

cat > "$parallel_remediation/00-master-px-list.tsv" <<'EOF'
packet_id	severity	group	title	source_file	source_line	finding	rationale
PX-1001	P1	parallel	First	fixture.md	1	first	row
PX-1002	P1	parallel	Second	fixture.md	2	second	row
EOF
cat > "$parallel_remediation/02-workstreams.tsv" <<'EOF'
group	packets	model_class	rationale
parallel	PX-1001,PX-1002	standard	fixture
EOF
cat > "$parallel_remediation/03-implementation-units.tsv" <<'EOF'
unit_id	packets	group	model_class	severity	rationale
IU-1001	PX-1001	parallel	standard	P1	first
IU-1002	PX-1002	parallel	standard	P1	second
EOF
write_packet "$parallel_remediation" PX-1001 not-started
write_packet "$parallel_remediation" PX-1002 not-started
printf '00-coordinator\ncoordinate-parallel\n' > "$parallel_remediation/completed-units.txt"

parallel_runner="$tmp_root/parallel-implementer.sh"
cat > "$parallel_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt_file="$1"
remediation="$2"
workstream="$3"
unit="${workstream#implement-}"
worktree="$(
  sed -n 's/.*Planned unit worktree: `\([^`]*\)`.*/\1/p' "$prompt_file" | head -1
)"
if [[ -z "$worktree" || ! -d "$worktree" ]]; then
  printf 'missing worktree for %s\n' "$workstream" >&2
  exit 1
fi
mkdir -p "$worktree/src" "$remediation/artifacts"
printf '%s\n' "$unit" > "$worktree/src/$unit.txt"
cat > "$remediation/artifacts/$unit-summary.md" <<SUMMARY
# $unit summary

IMPLEMENTATION_RESULT: fixed
SUMMARY
EOF
chmod +x "$parallel_runner"

REPO_ROOT="$parallel_repo" \
REMEDIATION_DIR="$parallel_remediation" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
IMPLEMENTER_AGENT=runner \
IMPLEMENTER_RUNNER="$parallel_runner" \
MAX_PARALLEL=2 \
"$SCRIPT_DIR/run-remediation.sh" \
  --audit-run "$parallel_audit" \
  --execute \
  --no-verify-after-execute \
  --no-catalog >/tmp/lazy-vibe-parallel-worktree-fixture.out 2>/tmp/lazy-vibe-parallel-worktree-fixture.err || {
    sed -n '1,160p' /tmp/lazy-vibe-parallel-worktree-fixture.out >&2 || true
    sed -n '1,200p' /tmp/lazy-vibe-parallel-worktree-fixture.err >&2 || true
    fail "parallel worktree promotion fixture failed"
  }

[[ -f "$parallel_repo/src/IU-1001.txt" ]] || fail "first parallel unit was not merged into active checkout"
[[ -f "$parallel_repo/src/IU-1002.txt" ]] || fail "second parallel unit was not merged into active checkout"
[[ ! -d "$parallel_remediation/worktrees/IU-1001" ]] || fail "first promoted worktree was not removed"
[[ ! -d "$parallel_remediation/worktrees/IU-1002" ]] || fail "second promoted worktree was not removed"
[[ -s "$parallel_remediation/artifacts/IU-1001.promotion" ]] || fail "first promotion marker missing"
[[ -s "$parallel_remediation/artifacts/IU-1002.promotion" ]] || fail "second promotion marker missing"
grep -q '\[worktree-merge\] promoting completed implementation units=IU-1001,IU-1002' \
  /tmp/lazy-vibe-parallel-worktree-fixture.out || fail "parallel wave promotion log missing"
if git -C "$parallel_repo" worktree list --porcelain | grep -q "$parallel_remediation/worktrees"; then
  fail "git worktree metadata still references promoted remediation worktrees"
fi

resume_repo="$tmp_root/resume-repo"
resume_audit="$resume_repo/docs/audit/fixture-launch-readiness-run"
resume_remediation="$resume_repo/docs/audit/fixture-remediation-run"
resume_unit="IU-2001"
resume_branch="remediation-$(basename "$resume_remediation")-$resume_unit"
resume_worktree="$resume_remediation/worktrees/$resume_unit"
mkdir -p "$resume_repo" "$resume_audit" "$resume_remediation"/{packets,prompts,logs,artifacts,worktrees}
git -C "$resume_repo" init -q
git -C "$resume_repo" config user.email "fixture@example.test"
git -C "$resume_repo" config user.name "Fixture Runner"
printf '# fixture\n' > "$resume_repo/README.md"
git -C "$resume_repo" add README.md
git -C "$resume_repo" commit -q -m "initial fixture"
git -C "$resume_repo" worktree add -q -b "$resume_branch" "$resume_worktree" HEAD
mkdir -p "$resume_worktree/src"
printf '%s\n' "$resume_unit" > "$resume_worktree/src/$resume_unit.txt"

cat > "$resume_remediation/00-master-px-list.tsv" <<'EOF'
packet_id	severity	group	title	source_file	source_line	finding	rationale
PX-2001	P1	resume	Checkpointed	fixture.md	1	resume	row
EOF
cat > "$resume_remediation/02-workstreams.tsv" <<'EOF'
group	packets	model_class	rationale
resume	PX-2001	standard	fixture
EOF
cat > "$resume_remediation/03-implementation-units.tsv" <<'EOF'
unit_id	packets	group	model_class	severity	rationale
IU-2001	PX-2001	resume	standard	P1	resume
EOF
write_packet "$resume_remediation" PX-2001 not-started
write_summary "$resume_remediation" "$resume_unit" fixed
printf '00-coordinator\ncoordinate-resume\nimplement-%s\n' "$resume_unit" > "$resume_remediation/completed-units.txt"

REPO_ROOT="$resume_repo" \
REMEDIATION_DIR="$resume_remediation" \
REMEDIATION_SCRIPT_SNAPSHOT=1 \
MAX_PARALLEL=2 \
"$SCRIPT_DIR/run-remediation.sh" \
  --audit-run "$resume_audit" \
  --execute \
  --no-verify-after-execute \
  --only-unit "$resume_unit" \
  --no-catalog >/tmp/lazy-vibe-resume-worktree-fixture.out 2>/tmp/lazy-vibe-resume-worktree-fixture.err || {
    sed -n '1,160p' /tmp/lazy-vibe-resume-worktree-fixture.out >&2 || true
    sed -n '1,200p' /tmp/lazy-vibe-resume-worktree-fixture.err >&2 || true
    fail "resume checkpointed worktree promotion fixture failed"
  }

[[ -f "$resume_repo/src/$resume_unit.txt" ]] || fail "checkpointed resume worktree was not merged"
[[ ! -d "$resume_worktree" ]] || fail "checkpointed resume worktree was not removed"
[[ -s "$resume_remediation/artifacts/$resume_unit.promotion" ]] || fail "checkpointed promotion marker missing"
grep -q '\[worktree-merge\] promoting completed implementation units=IU-2001' \
  /tmp/lazy-vibe-resume-worktree-fixture.out || fail "resume checkpointed promotion log missing"
if git -C "$resume_repo" worktree list --porcelain | grep -q "$resume_remediation/worktrees"; then
  fail "git worktree metadata still references checkpointed remediation worktree"
fi

grep -q 'command_is_long_running_server' "$SCRIPT_DIR/run-remediation.sh" || fail "long-running command guard missing"
grep -q 'refused long-running server command' "$SCRIPT_DIR/run-remediation.sh" || fail "long-running command refusal log missing"
grep -q 'npm run dev' "$SCRIPT_DIR/run-remediation.sh" || fail "npm dev-server guard missing"
grep -q 'command_is_unscoped_broad_native_test' "$SCRIPT_DIR/run-remediation.sh" || fail "broad native-test guard missing"
grep -q 'refused unscoped broad verification command' "$SCRIPT_DIR/run-remediation.sh" || fail "broad native-test refusal log missing"
grep -q 'cd frontend && npx playwright test' "$SCRIPT_DIR/run-remediation.sh" || fail "unscoped Playwright guard missing"
grep -q 'unit_has_native_test_artifact_findings' "$SCRIPT_DIR/run-remediation.sh" || fail "native-test artifact finding guard missing"
grep -q 'preserving unit-generated script/log for verifier' "$SCRIPT_DIR/run-remediation.sh" || fail "native-test artifact preservation log missing"
grep -q 'artifacts/verify-\$unit_id.md' "$SCRIPT_DIR/run-remediation.sh" || fail "native-test artifact verifier-report fallback missing"
grep -q 'stale selector.+native-test' "$SCRIPT_DIR/run-remediation.sh" || fail "native-test stale selector fallback missing"
grep -q 'browser_evidence_env_preamble' "$SCRIPT_DIR/run-remediation.sh" || fail "browser evidence env preamble missing"
grep -q 'Meridian dev VPS is split-subdomain' "$SCRIPT_DIR/run-remediation.sh" || fail "Meridian split-subdomain guard missing"
grep -q 'ensure_browser_vps_deploy_ready' "$SCRIPT_DIR/run-remediation.sh" || fail "Meridian browser deploy preflight missing"
grep -q 'scripts/deploy-runtime dev' "$SCRIPT_DIR/run-remediation.sh" || fail "Meridian deploy-runtime guidance missing"
grep -q 'verifier requested revision; queued for implementer retry' "$SCRIPT_DIR/run-remediation.sh" || fail "verifier revision retry log missing"
grep -q 'finalize_verified_unit "$unit_id"' "$SCRIPT_DIR/run-remediation.sh" || fail "checkpointed verifier finalization missing"
grep -q 'merge_branch_or_head_into_root "$REPO_ROOT" "$worktree_dir" "$unit_id" "repo"' "$SCRIPT_DIR/run-remediation.sh" || fail "commit-on-verify does not use resolver-capable merge helper"
grep -q 'active workspace was dirty before implementation; refusing auto-commit' "$SCRIPT_DIR/run-remediation.sh" || fail "active workspace dirty-baseline commit guard missing"
grep -q 'REMEDIATION_COMMIT_ON_VERIFY="${REMEDIATION_COMMIT_ON_VERIFY:-1}"' "$SCRIPT_DIR/run-remediation.sh" || fail "commit-on-verify default must stay enabled"
grep -q 'REMEDIATION_COMMIT_ROOTS="$REPO_ROOT"' "$SCRIPT_DIR/run-remediation.sh" || fail "git-root commit root default missing"
grep -q 'status --porcelain=v1 -uall -- "${pathspec\[@\]}"' "$SCRIPT_DIR/run-remediation.sh" || fail "commit baseline must use merge pathspec exclusions"
grep -q 'refusing to launch a wave that cannot be merged' "$SCRIPT_DIR/run-remediation.sh" || fail "dirty-root prelaunch guard missing"
if grep -q 'test_status=124' "$SCRIPT_DIR/run-remediation.sh"; then
  fail "long-running command refusal must not fail the implementation step"
fi

printf 'PASS run-remediation fixture categories\n'
