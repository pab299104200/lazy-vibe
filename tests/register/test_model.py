import pytest

from lazy_vibe.register.model import Finding, RegisterError


def make_finding(**overrides):
    base = dict(
        finding_id="R-0001",
        fingerprint="sha256:8c1f0b2a9d4e6f31",
        fingerprint_inputs={
            "category": "product_gap",
            "theme": "tenant_scope_missing",
            "path": "backend/routers/evidence.py",
            "symbol": "-",
        },
        title="Evidence list endpoint not tenant-scoped",
        description="GET /api/evidence returns rows for all accounts.",
        severity="P1",
        severity_source="proposed",
        taxonomy="S",
        in_scope=True,
        disposition="new",
        disposition_by="ingest",
        disposition_reason="created from run 2026-06-10-1402",
        evidence=[{"type": "code", "ref": "backend/routers/evidence.py:118",
                   "run_id": "2026-06-10-1402"}],
        first_seen={"run_id": "2026-06-10-1402", "date": "2026-06-10"},
        last_seen={"run_id": "2026-06-10-1402", "date": "2026-06-10"},
    )
    base.update(overrides)
    return Finding(**base)


def test_round_trip_json():
    f = make_finding()
    line = f.to_json_line()
    assert "\n" not in line
    g = Finding.from_json_line(line)
    assert g == f


def test_validate_rejects_bad_severity():
    with pytest.raises(RegisterError, match="severity"):
        make_finding(severity="P9").validate()


def test_validate_rejects_bad_finding_id():
    with pytest.raises(RegisterError, match="finding_id"):
        make_finding(finding_id="X-1").validate()


def test_validate_rejects_unknown_disposition():
    with pytest.raises(RegisterError, match="disposition"):
        make_finding(disposition="mitigated").validate()


def test_fixed_requires_regression_test():
    f = make_finding(disposition="fixed", regression_test=None)
    with pytest.raises(RegisterError, match="regression_test"):
        f.validate()
    make_finding(disposition="fixed",
                 regression_test="tests/test_evidence.py::test_tenant_scope").validate()


def test_risk_accepted_requires_review_by():
    f = make_finding(disposition="risk_accepted", disposition_by="pete")
    with pytest.raises(RegisterError, match="review_by"):
        f.validate()
    make_finding(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-09-01").validate()


def test_taxonomy_accepts_acceptance_and_rc_codes():
    make_finding(taxonomy="F-SILENT").validate()
    make_finding(taxonomy="RC-3").validate()
    with pytest.raises(RegisterError, match="taxonomy"):
        make_finding(taxonomy="Z").validate()


def test_fingerprint_inputs_must_be_complete():
    with pytest.raises(RegisterError, match="fingerprint_inputs"):
        make_finding(fingerprint_inputs={"category": "x"}).validate()


def test_from_json_line_reports_line_number_on_corrupt_input():
    with pytest.raises(RegisterError, match="line 7"):
        Finding.from_json_line("{not json", lineno=7)
