import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.policy import apply_policy, load_policy
from lazy_vibe.register.store import RegisterStore
from tests.register.test_model import make_finding

POLICY_YAML = """\
rules:
  - id: p0-security-in-scope
    match: {severity: P0, taxonomy: S, in_scope: true, verified: true}
    action: open
  - id: out-of-scope-p3
    match: {in_scope: false, severity: P3}
    action: park
  - id: verified-fp
    match: {verified: false}
    action: false_positive
default: queue
"""


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


@pytest.fixture
def policy(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text(POLICY_YAML)
    return load_policy(p)


def _new(fid="R-0001", verdict=None, **kw):
    f = make_finding(finding_id=fid, disposition="new",
                     disposition_by="ingest", **kw)
    if verdict is not None:
        f.history.append({"ts": "t", "event": "verification",
                          "verdict": verdict, "by": "agent:verifier"})
    return f


def test_load_policy_parses(policy):
    assert [r.rule_id for r in policy.rules] == [
        "p0-security-in-scope", "out-of-scope-p3", "verified-fp"]
    assert policy.default == "queue"


def test_first_match_wins_open(store, policy):
    f = _new("R-0001", severity="P0", taxonomy="S", in_scope=True,
             verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    f2 = store.load()["R-0001"]
    assert f2.disposition == "open"
    assert f2.disposition_by == "policy:p0-security-in-scope"
    assert outcome.opened == ["R-0001"]


def test_out_of_scope_p3_parks(store, policy):
    f = _new("R-0001", severity="P3", in_scope=False, verdict="VERIFIED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "parked"


def test_unverified_false_positive_only_when_unsupported(store, tmp_path):
    # the false_positive action requires the last verification == UNSUPPORTED
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: fp\n    match: {severity: P2}\n"
                 "    action: false_positive\ndefault: queue\n")
    policy = load_policy(p)
    bad = _new("R-0001", severity="P2", verdict="VERIFIED")
    store.save({bad.finding_id: bad})
    with pytest.raises(RegisterError, match="UNSUPPORTED"):
        apply_policy(store, policy, date="2026-06-11")


def test_false_positive_with_unsupported(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: fp\n    match: {severity: P2}\n"
                 "    action: false_positive\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P2", verdict="UNSUPPORTED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "false_positive"


def test_verified_match_requires_verified_event(store, policy):
    f = _new("R-0001", severity="P0", taxonomy="S", in_scope=True)  # no event
    store.save({f.finding_id: f})
    # p0-security needs verified:true (absent) -> falls to verified-fp
    # (verified:false) whose false_positive action needs UNSUPPORTED -> error.
    with pytest.raises(RegisterError, match="UNSUPPORTED"):
        apply_policy(store, policy, date="2026-06-11")


def test_propose_risk_accept_queues_not_transitions(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: ra\n    match: {severity: P1}\n"
                 "    action: propose_risk_accept\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P1", verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"  # proposals never auto-transition (§4.2)
    assert any(h.get("event") == "risk_accept_proposed" for h in f2.history)
    assert "R-0001" in outcome.proposed_risk_accept


def test_default_queue_leaves_new(store, policy):
    f = _new("R-0001", severity="P2", in_scope=True, verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "new"
    assert "R-0001" in outcome.queued


def test_path_prefix_and_theme_match(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: ev\n    match: "
                 "{path_prefix: 'backend/routers/', theme: tenant_scope_missing}"
                 "\n    action: open\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P1", verdict="VERIFIED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "open"


def test_only_processes_new(store, tmp_path, policy):
    from tests.register.helpers import with_history
    f = with_history(make_finding(disposition="open", disposition_by="pete"))
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "open"  # untouched


def test_missing_policy_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="triage-policy"):
        load_policy(tmp_path / "triage-policy.yaml")


def test_missing_default_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {severity: P0}\n    action: open\n")
    with pytest.raises(RegisterError, match="default"):
        load_policy(p)


def test_bad_action_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {severity: P0}\n"
                 "    action: explode\ndefault: queue\n")
    with pytest.raises(RegisterError, match="action"):
        load_policy(p)


def test_bad_match_key_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {wat: 1}\n    action: open\n"
                 "default: queue\n")
    with pytest.raises(RegisterError, match="match key"):
        load_policy(p)
