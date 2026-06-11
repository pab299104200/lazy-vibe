import pytest

from lazy_vibe.register.model import Disposition
from lazy_vibe.register.transitions import TransitionError, reaffirm_risk, transition
from tests.register.test_model import make_finding

NOW = "2026-06-11T10:00:00+00:00"


def t(finding, to, by="pete", reason="because", **kw):
    transition(finding, Disposition(to), by=by, reason=reason, now=NOW, **kw)


def test_new_to_open_requires_verified_and_authority():
    f = make_finding()
    with pytest.raises(TransitionError, match="verified"):
        t(f, "open", by="policy:p0-security-in-scope")
    with pytest.raises(TransitionError, match="authority"):
        t(f, "open", by="agent:auditor", verified=True)
    t(f, "open", by="policy:p0-security-in-scope", verified=True)
    assert f.disposition == "open"
    assert f.history[-1]["event"] == "disposition"
    assert f.history[-1]["from"] == "new"
    assert f.history[-1]["to"] == "open"
    assert f.history[-1]["by"] == "policy:p0-security-in-scope"


def test_new_to_risk_accepted_is_pete_only_and_needs_review_by():
    f = make_finding()
    with pytest.raises(TransitionError, match="pete"):
        t(f, "risk_accepted", by="policy:dev-dep-low-cve", review_by="2026-09-01")
    f2 = make_finding()
    with pytest.raises(TransitionError, match="review_by"):
        t(f2, "risk_accepted", by="pete")
    f3 = make_finding()
    t(f3, "risk_accepted", by="pete", review_by="2026-09-01")
    assert f3.review_by == "2026-09-01"
    f4 = make_finding()
    with pytest.raises(TransitionError, match="ISO date"):
        t(f4, "risk_accepted", by="pete", review_by="next quarter")


def test_in_remediation_to_fixed_requires_regression_test():
    f = make_finding(disposition="open")
    t(f, "in_remediation", by="harness")
    with pytest.raises(TransitionError, match="regression_test"):
        t(f, "fixed", by="harness")
    t(f, "fixed", by="harness",
      regression_test="tests/test_evidence.py::test_tenant_scope")
    assert f.regression_test == "tests/test_evidence.py::test_tenant_scope"


def test_fixed_to_regressed_is_reconciler_only():
    f = make_finding(disposition="fixed",
                     regression_test="tests/test_x.py::test_y")
    with pytest.raises(TransitionError, match="authority"):
        t(f, "regressed", by="pete")
    t(f, "regressed", by="reconciler")
    assert f.disposition == "regressed"


def test_protected_states_reopen_pete_only():
    fp = make_finding(disposition="false_positive", disposition_by="pete")
    with pytest.raises(TransitionError, match="authority"):
        t(fp, "open", by="policy:anything", verified=True)
    t(fp, "open", by="pete", verified=True)

    ra = make_finding(disposition="risk_accepted", disposition_by="pete",
                      review_by="2026-09-01")
    with pytest.raises(TransitionError, match="authority"):
        t(ra, "open", by="agent:verifier", verified=True)
    t(ra, "open", by="pete", verified=True)


def test_illegal_transition_rejected():
    f = make_finding()  # new
    with pytest.raises(TransitionError, match="no transition"):
        t(f, "fixed", by="pete", regression_test="tests/test_x.py::test_y")


def test_reaffirm_risk_updates_review_by_with_history():
    f = make_finding(disposition="risk_accepted", disposition_by="pete",
                     review_by="2026-06-01")
    reaffirm_risk(f, review_by="2026-12-01", by="pete", now=NOW,
                  reason="customer launch slipped")
    assert f.review_by == "2026-12-01"
    assert f.history[-1]["event"] == "risk_reaffirmed"
    assert f.history[-1]["reason"] == "customer launch slipped"
    with pytest.raises(TransitionError, match="pete"):
        reaffirm_risk(f, review_by="2027-01-01", by="policy:x", now=NOW,
                      reason="customer launch slipped")
    g = make_finding()  # not risk_accepted
    with pytest.raises(TransitionError, match="risk_accepted"):
        reaffirm_risk(g, review_by="2027-01-01", by="pete", now=NOW,
                      reason="customer launch slipped")
    h = make_finding(disposition="risk_accepted", disposition_by="pete",
                     review_by="2026-06-01")
    with pytest.raises(TransitionError, match="ISO date"):
        reaffirm_risk(h, review_by="whenever", by="pete", now=NOW,
                      reason="x")
