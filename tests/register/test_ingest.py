import json

import pytest

from lazy_vibe.register.ingest import (Candidate, parse_ledger,
                                       read_candidates, write_candidates)
from lazy_vibe.register.model import RegisterError

HEADER = ("blocker_id\tcategory\ttheme\tseverity\tgroup\tmodel_class\t"
          "finding_count\trepresentative_source\trepresentative_line\t"
          "representative_title\traw_px_ids\treferences\n")

ROW1 = ("B-0001\tproduct_gap\ttenant_scope_missing\tP1\tW1\tstandard\t3\t"
        "backend/routers/evidence.py\t118\t"
        "Evidence list endpoint not tenant-scoped\tP1-0001,P1-0007\t"
        "backend/routers/evidence.py:118,artifacts/02a.md\n")

ROW2 = ("B-0002\tevidence_gap\tbrowser_evidence_missing\tP2\tW2\tstandard\t1\t"
        "docs/ux/journeys.md\t-\tNo browser proof for evidence journey\t"
        "P2-0004\tartifacts/07-customer-simulation.md\n")


@pytest.fixture
def ledger(tmp_path):
    path = tmp_path / "00-blocker-ledger.tsv"
    path.write_text(HEADER + ROW1 + ROW2)
    return path


def test_parse_ledger(ledger):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    assert len(candidates) == 2
    c = candidates[0]
    assert c == Candidate(
        blocker_id="B-0001",
        category="product_gap",
        theme_raw="tenant_scope_missing",
        severity="P1",
        path="backend/routers/evidence.py",
        line="118",
        title="Evidence list endpoint not tenant-scoped",
        references="backend/routers/evidence.py:118,artifacts/02a.md",
        run_id="2026-06-10-1402",
    )


def test_parse_ledger_rejects_wrong_header(tmp_path):
    path = tmp_path / "bad.tsv"
    path.write_text("a\tb\tc\n1\t2\t3\n")
    with pytest.raises(RegisterError, match="header"):
        parse_ledger(path, run_id="x")


def test_parse_ledger_rejects_bad_severity(tmp_path):
    path = tmp_path / "bad-sev.tsv"
    path.write_text(HEADER + ROW1.replace("\tP1\t", "\tP9\t", 1))
    with pytest.raises(RegisterError, match="severity"):
        parse_ledger(path, run_id="x")


def test_parse_ledger_missing_file(tmp_path):
    with pytest.raises(RegisterError, match="ledger"):
        parse_ledger(tmp_path / "nope.tsv", run_id="x")


def test_parse_ledger_handles_leading_quote_in_title(tmp_path):
    row = ROW1.replace("Evidence list endpoint not tenant-scoped",
                       '"eval" is dangerous in evidence parser')
    path = tmp_path / "quoted.tsv"
    path.write_text(HEADER + row + ROW2)
    candidates = parse_ledger(path, run_id="x")
    assert len(candidates) == 2
    assert candidates[0].title == '"eval" is dangerous in evidence parser'


def test_write_candidates_round_trip(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    out = tmp_path / "register-candidates.json"
    write_candidates(candidates, out, run_id="2026-06-10-1402")
    data = json.loads(out.read_text())
    assert data["run_id"] == "2026-06-10-1402"
    assert len(data["candidates"]) == 2
    assert data["candidates"][0]["blocker_id"] == "B-0001"


def test_read_candidates_round_trip(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    out = tmp_path / "register-candidates.json"
    write_candidates(candidates, out, run_id="2026-06-10-1402")
    assert read_candidates(out) == candidates


def test_read_candidates_rejects_corrupt_json(tmp_path):
    path = tmp_path / "c.json"
    path.write_text("{not json")
    with pytest.raises(RegisterError, match="corrupt"):
        read_candidates(path)


def test_read_candidates_rejects_missing_candidates_key(tmp_path):
    path = tmp_path / "c.json"
    path.write_text('{"run_id": "x"}')
    with pytest.raises(RegisterError, match="candidates"):
        read_candidates(path)


def test_read_candidates_rejects_bad_severity(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="x")
    out = tmp_path / "c.json"
    write_candidates(candidates, out, run_id="x")
    path = tmp_path / "tampered.json"
    path.write_text(out.read_text().replace('"P1"', '"P9"'))
    with pytest.raises(RegisterError, match="severity"):
        read_candidates(path)


def test_read_candidates_rejects_missing_field(tmp_path):
    path = tmp_path / "c.json"
    path.write_text('{"run_id": "x", "candidates": [{"blocker_id": "B-0001"}]}')
    with pytest.raises(RegisterError, match="candidate 0"):
        read_candidates(path)


def test_read_candidates_rejects_run_id_mismatch(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="x")
    out = tmp_path / "c.json"
    write_candidates(candidates, out, run_id="x")
    path = tmp_path / "tampered.json"
    path.write_text(out.read_text().replace('"run_id": "x"', '"run_id": "y"', 1))
    with pytest.raises(RegisterError, match="run_id"):
        read_candidates(path)


def test_candidate_taxonomy_defaults_to_gap(ledger):
    candidates = parse_ledger(ledger, run_id="x")
    assert candidates[0].taxonomy == "G"
