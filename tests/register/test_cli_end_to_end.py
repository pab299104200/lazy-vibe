"""End-to-end: two audit runs through the CLI demonstrate convergence
(suppression of adjudicated findings, regression detection)."""
import os
import stat
import json
import subprocess
import sys
from pathlib import Path

import pytest

from lazy_vibe.register.model import Disposition
from lazy_vibe.register.store import RegisterStore
from lazy_vibe.register.transitions import transition

REPO_ROOT = Path(__file__).resolve().parents[2]

HEADER = ("blocker_id\tcategory\ttheme\tseverity\tgroup\tmodel_class\t"
          "finding_count\trepresentative_source\trepresentative_line\t"
          "representative_title\traw_px_ids\treferences\n")
ROW_TENANT = ("B-0001\tproduct_gap\ttenant_scope_missing\tP1\tW1\tstandard\t3\t"
              "backend/routers/evidence.py\t118\t"
              "Evidence list endpoint not tenant-scoped\tP1-0001\tr1\n")
ROW_BROWSER = ("B-0002\tevidence_gap\tbrowser_evidence_missing\tP2\tW2\t"
               "standard\t1\tdocs/ux/journeys.md\t-\t"
               "No browser proof for evidence journey\tP2-0004\tr2\n")

THEMES = """\
themes:
  tenant_scope_missing:
    patterns: ["tenant scope"]
  browser_evidence_missing:
    patterns: ["browser proof"]
"""


def cli(*args):
    return subprocess.run(
        [sys.executable, "-m", "lazy_vibe.register", *args],
        cwd=REPO_ROOT, capture_output=True, text=True)


@pytest.fixture
def workspace(tmp_path):
    register_dir = tmp_path / "docs" / "audit" / "register"
    register_dir.mkdir(parents=True)
    (register_dir / "themes.yaml").write_text(THEMES)
    run1 = tmp_path / "run1"
    run1.mkdir()
    (run1 / "00-blocker-ledger.tsv").write_text(HEADER + ROW_TENANT + ROW_BROWSER)
    run2 = tmp_path / "run2"
    run2.mkdir()
    (run2 / "00-blocker-ledger.tsv").write_text(HEADER + ROW_TENANT + ROW_BROWSER)
    return tmp_path, register_dir, run1, run2


def test_two_run_convergence(workspace):
    tmp, register_dir, run1, run2 = workspace

    # Run 1: backfill -> two new findings.
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1", "--date", "2026-06-10")
    assert proc.returncode == 0, proc.stderr
    report1 = (register_dir / "reconcile-report.md").read_text()
    assert "2 new, 0 suppressed, 0 regressed" in report1

    # Adjudicate between runs: R-0001 fixed, R-0002 risk-accepted.
    store = RegisterStore(register_dir)
    findings = store.load()
    now = "2026-06-10T12:00:00+00:00"
    transition(findings["R-0001"], Disposition.OPEN, by="pete",
               reason="real", now=now, verified=True)
    transition(findings["R-0001"], Disposition.IN_REMEDIATION, by="harness",
               reason="unit U-1", now=now)
    transition(findings["R-0001"], Disposition.FIXED, by="harness",
               reason="fixed in commit abc",
               regression_test="tests/test_evidence.py::test_tenant_scope", now=now)
    transition(findings["R-0002"], Disposition.RISK_ACCEPTED, by="pete",
               reason="journey proof deferred to beta", now=now,
               review_by="2026-09-01")
    store.save(findings)

    # Run 2: same ledger -> one regression, one suppressed, zero new.
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(run2 / "00-blocker-ledger.tsv"),
               "--run-id", "run2", "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    report2 = (register_dir / "reconcile-report.md").read_text()
    assert "0 new, 1 suppressed, 1 regressed" in report2
    assert "R-0001" in report2  # the regression

    findings = RegisterStore(register_dir).load()
    assert findings["R-0001"].disposition == "regressed"
    assert findings["R-0002"].disposition == "risk_accepted"
    assert findings["R-0002"].occurrences == 2


def test_ingest_then_reconcile_separately(workspace):
    tmp, register_dir, run1, _ = workspace
    proc = cli("ingest", "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1",
               "--out", str(run1 / "register-candidates.json"))
    assert proc.returncode == 0, proc.stderr
    data = json.loads((run1 / "register-candidates.json").read_text())
    assert len(data["candidates"]) == 2

    proc = cli("reconcile", "--register-dir", str(register_dir),
               "--candidates", str(run1 / "register-candidates.json"),
               "--date", "2026-06-10")
    assert proc.returncode == 0, proc.stderr
    assert (register_dir / "register.jsonl").exists()
    assert (register_dir / "register.md").exists()


def test_missing_themes_yaml_fails_loudly(workspace, tmp_path):
    _, _, run1, _ = workspace
    empty_dir = tmp_path / "no-themes"
    empty_dir.mkdir()
    proc = cli("backfill", "--register-dir", str(empty_dir),
               "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1", "--date", "2026-06-10")
    assert proc.returncode == 1
    assert "themes.yaml" in proc.stderr


def test_cli_reports_clean_error_on_os_failure(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(tmp_path),  # a directory, not a file
               "--run-id", "x", "--date", "2026-06-10")
    assert proc.returncode == 1
    assert "error:" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_report_regenerates_markdown(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    (register_dir / "register.md").unlink()
    proc = cli("report", "--register-dir", str(register_dir))
    assert proc.returncode == 0, proc.stderr
    assert (register_dir / "register.md").exists()


SCORECARD_MD = """\
# Widget Scorecard

## Findings Table

| ID | Severity | Type | Title | Status |
|----|----------|------|-------|--------|
| B-01 | Critical | Bug | Widget breaks tenancy | OPEN (new) |
| G-01 | Low | Gap | Widget lacks docs | Fixed — verified |
"""

LAUNCH_SCOPE = """\
product: testprod
default_in_scope: true
surfaces: []
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted
  P2: triaged
gates:
  - id: trivially-green
    type: command
    command: "true"
"""


def test_scorecard_ingest_then_readiness(workspace, tmp_path):
    _, register_dir, _, _ = workspace
    (register_dir / "themes.yaml").write_text(
        "themes:\n  widget:\n    patterns: []\n")
    scorecard = tmp_path / "widget.md"
    scorecard.write_text(SCORECARD_MD)
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(LAUNCH_SCOPE)

    proc = cli("scorecard-ingest", "--register-dir", str(register_dir),
               "--scorecard", str(scorecard), "--slug", "widget",
               "--run-id", "sc-run-1", "--date", "2026-06-11",
               "--scope", str(scope_path))
    assert proc.returncode == 0, proc.stderr
    assert "1 new" in proc.stdout

    proc = cli("readiness", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 1          # open P0 blocks
    assert "NOT READY" in proc.stdout
    assert "B-01" in proc.stdout or "R-0001" in proc.stdout


def test_scope_recompute_cli(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text("product: testprod\ndefault_in_scope: false\n"
                          "surfaces: []\nseverity_bar: {}\n")
    proc = cli("scope-recompute", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    assert "park" in proc.stdout


def test_bad_review_by_in_register_gives_clean_error(workspace, tmp_path):
    """Part C: hand-edited bad review_by gives clean error: line, no Traceback."""
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    # Manually corrupt a finding: risk_accepted with non-ISO review_by
    import json
    jsonl_path = register_dir / "register.jsonl"
    lines = jsonl_path.read_text().splitlines()
    corrupted = []
    for line in lines:
        data = json.loads(line)
        if data["finding_id"] == "R-0001":
            data["disposition"] = "risk_accepted"
            data["disposition_by"] = "pete"
            data["review_by"] = "whenever"
        corrupted.append(json.dumps(data, sort_keys=True))
    jsonl_path.write_text("\n".join(corrupted) + "\n")

    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(LAUNCH_SCOPE.replace("testprod", "testprod"))
    proc = cli("readiness", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 1
    assert "error:" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_narrowed_scope_parks_and_readiness_excludes(workspace, tmp_path):
    """Composed flow: narrowed scope -> ingest parks out-of-scope P0 ->
    readiness excludes it from blocking (final-review seam test)."""
    _, register_dir, _, _ = workspace
    (register_dir / "themes.yaml").write_text(
        "themes:\n  widget:\n    patterns: []\n")
    scorecard = tmp_path / "widget.md"
    scorecard.write_text(SCORECARD_MD)  # B-01 path falls back to tmp scorecard
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(
        "product: testprod\ndefault_in_scope: false\n"
        "surfaces:\n  - slug: backend\n    paths: ['backend/']\n"
        "severity_bar:\n  P0: zero_open\n  P1: zero_open_or_risk_accepted\n"
        "  P2: triaged\n")
    proc = cli("scorecard-ingest", "--register-dir", str(register_dir),
               "--scorecard", str(scorecard), "--slug", "widget",
               "--run-id", "sc-1", "--date", "2026-06-11",
               "--scope", str(scope_path))
    assert proc.returncode == 0, proc.stderr
    proc = cli("readiness", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stdout  # parked P0 must not block
    assert "NOT READY" not in proc.stdout
    assert "Parked: 1" in proc.stdout


# ---------------------------------------------------------------------------
# Task 5: verify-packets / verify-consume / triage / close CLI verbs
# ---------------------------------------------------------------------------

TRIAGE_POLICY = """\
rules:
  - id: open-verified-in-scope
    match: {verified: true, in_scope: true}
    action: open
default: queue
"""


def test_verify_and_triage_e2e(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    # generate packets
    proc = cli("verify-packets", "--register-dir", str(register_dir))
    assert proc.returncode == 0, proc.stderr
    packets = register_dir / "triage" / "packets"
    assert (packets / "R-0001.md").exists()
    # simulate verifier results
    results = register_dir / "triage" / "results"
    results.mkdir(parents=True, exist_ok=True)
    for fid in ("R-0001", "R-0002"):
        (results / f"{fid}.json").write_text(json.dumps({
            "schema_version": 1, "finding_id": fid, "verdict": "VERIFIED",
            "evidence": ["x.py:1"], "mechanism": "m",
            "duplicate_of": None, "split_paths": []}))
    proc = cli("verify-consume", "--register-dir", str(register_dir),
               "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    # policy + queue via triage --accept-all with a policy that opens verified
    policy_path = register_dir / "triage-policy.yaml"
    policy_path.write_text(TRIAGE_POLICY)
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(LAUNCH_SCOPE)
    proc = cli("triage", "--register-dir", str(register_dir),
               "--policy", str(policy_path), "--scope", str(scope_path),
               "--date", "2026-06-11", "--accept-all")
    assert proc.returncode == 0, proc.stderr
    from lazy_vibe.register.store import RegisterStore as RS
    findings = RS(register_dir).load()
    assert findings["R-0001"].disposition == "open"
    assert (register_dir / "triage-queue.md").exists()


def test_close_verb_open_to_fixed(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    from lazy_vibe.register.store import RegisterStore as RS
    from lazy_vibe.register.transitions import transition
    from lazy_vibe.register.model import Disposition
    store = RS(register_dir)
    findings = store.load()
    transition(findings["R-0001"], Disposition.OPEN, by="pete", reason="real",
               now="2026-06-10T00:00:00+00:00", verified=True)
    store.save(findings)
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001",
               "--test", "tests/test_evidence.py::test_tenant_scope",
               "--reason", "fixed in PR-9")
    assert proc.returncode == 0, proc.stderr
    f = RS(register_dir).load()["R-0001"]
    assert f.disposition == "fixed"
    assert f.regression_test == "tests/test_evidence.py::test_tenant_scope"
    assert f.disposition_by == "harness"


def test_close_requires_open_or_remediation(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001",
               "--test", "tests/t.py::t")
    assert proc.returncode == 1  # R-0001 is `new`, not open
    assert "error:" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_close_rejects_malformed_test_format(workspace):
    # quality-review I2: --test must be 'path::test_name'; free text would
    # persist an unrerunnable regression link on the fixed state.
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    from lazy_vibe.register.store import RegisterStore as RS
    from lazy_vibe.register.transitions import transition
    from lazy_vibe.register.model import Disposition
    store = RS(register_dir)
    findings = store.load()
    transition(findings["R-0001"], Disposition.OPEN, by="pete", reason="real",
               now="2026-06-10T00:00:00+00:00", verified=True)
    store.save(findings)
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001", "--test", "garbage")
    assert proc.returncode == 1
    assert "path::test_name" in proc.stderr
    assert "Traceback" not in proc.stderr
    f = RS(register_dir).load()["R-0001"]
    assert f.disposition == "open"  # untouched — rejected before any transition
    assert f.regression_test is None


# ---------------------------------------------------------------------------
# Task 7: run-triage.sh dispatch wrapper smoke test
# ---------------------------------------------------------------------------



def test_run_triage_sh_dispatches_stub_agent(workspace, tmp_path):
    """run-triage.sh: stub TRIAGE_AGENT writes a VERIFIED result per packet,
    then verify-consume folds it in."""
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    cli("verify-packets", "--register-dir", str(register_dir))
    # stub agent: reads packet on stdin, extracts the result path + finding id,
    # writes a minimal VERIFIED result there.
    stub = tmp_path / "stub-agent.sh"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        "packet=$(cat)\n"
        "fid=$(printf '%s' \"$packet\" | grep -oE 'R-[0-9]{4}' | head -1)\n"
        "out=$(printf '%s' \"$packet\" | grep -oE '/[^ ]*results/[^ ]*.json' "
        "| head -1)\n"
        "printf '{\"schema_version\":1,\"finding_id\":\"%s\",\"verdict\":"
        "\"VERIFIED\",\"evidence\":[\"x.py:1\"],\"mechanism\":\"m\","
        "\"duplicate_of\":null,\"split_paths\":[]}' \"$fid\" > \"$out\"\n")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ, TRIAGE_AGENT=str(stub), MAX_PARALLEL="1")
    proc = subprocess.run(
        ["bash", str(REPO_ROOT / "run-triage.sh"),
         "--register-dir", str(register_dir)],
        cwd=REPO_ROOT, capture_output=True, text=True, env=env)
    assert proc.returncode == 0, proc.stderr
    findings = RegisterStore(register_dir).load()
    assert all("verification" in [h.get("event") for h in f.history]
               for f in findings.values())
