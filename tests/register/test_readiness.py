import json

import pytest

from lazy_vibe.register.readiness import evaluate, render_readiness
from lazy_vibe.register.scope import load_scope
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

TODAY = "2026-06-12"


def scope_yaml(gates: str = "") -> str:
    return ("product: meridian\ndefault_in_scope: true\nsurfaces: []\n"
            "severity_bar:\n  P0: zero_open\n  P1: zero_open_or_risk_accepted\n"
            "  P2: triaged\n" + ("gates:\n" + gates if gates else ""))


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def make_scope(tmp_path, gates: str = ""):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(scope_yaml(gates))
    return load_scope(p)


def finding(fid, sev, disposition, **kw):
    fp = f"sha256:{fid[-4:]:0>16}".replace("R", "a").replace("-", "b").lower()
    return with_history(make_finding(
        finding_id=fid, fingerprint=fp, severity=sev,
        disposition=disposition, **kw))


def test_ready_when_empty(store, tmp_path):
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert report.exit_code == 0


def test_open_p0_blocks(store, tmp_path):
    f = finding("R-0001", "P0", "open", disposition_by="pete")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert report.exit_code == 1
    assert any("R-0001" in item for item in report.blocking)


def test_new_p2_blocks_triaged_bar(store, tmp_path):
    f = finding("R-0001", "P2", "new", disposition_by="ingest")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False


def test_candidate_theme_blocks_even_if_triaged_elsewhere(store, tmp_path):
    f = finding("R-0001", "P3", "new", disposition_by="ingest")
    f.fingerprint_inputs["theme"] = "_candidate:weird"
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert any("_candidate" in item for item in report.blocking)


def test_risk_accepted_p1_passes_and_is_listed(store, tmp_path):
    f = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                review_by="2026-12-01")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert any("R-0001" in a for a in report.risk_acceptances)


def test_past_due_risk_acceptance_blocks(store, tmp_path):
    f = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                review_by="2026-06-01")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert any("past due" in item for item in report.blocking)


def test_out_of_scope_open_does_not_block(store, tmp_path):
    f = finding("R-0001", "P0", "open", disposition_by="pete", in_scope=False)
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert report.parked_count == 0  # out-of-scope but not parked


def test_command_gate_pass_and_fail(store, tmp_path):
    ok = evaluate(store, make_scope(
        tmp_path, "  - id: ok\n    type: command\n    command: 'true'\n"),
        today=TODAY)
    assert ok.ready is True
    bad = evaluate(store, make_scope(
        tmp_path, "  - id: bad\n    type: command\n    command: 'false'\n"),
        today=TODAY)
    assert bad.ready is False


def test_artifact_json_gate(store, tmp_path):
    art = tmp_path / "sast.json"
    art.write_text(json.dumps({"summary": {"critical": 0}}))
    gates = (f"  - id: sast\n    type: artifact_json\n    path: {art}\n"
             f"    key: summary.critical\n    op: eq\n    value: 0\n")
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.ready is True
    art.write_text(json.dumps({"summary": {"critical": 2}}))
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.ready is False


def test_missing_artifact_is_stale(store, tmp_path):
    gates = ("  - id: sast\n    type: artifact_json\n"
             "    path: /nonexistent/sast.json\n"
             "    key: a\n    op: eq\n    value: 0\n")
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.exit_code == 2
    assert report.ready is False


def test_render_always_lists_acceptances_and_parked(store, tmp_path):
    ra = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    pk = finding("R-0002", "P3", "parked", disposition_by="scope",
                 in_scope=False)
    store.save({f.finding_id: f for f in (ra, pk)})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    text = render_readiness(report)
    assert "READY" in text
    assert "R-0001" in text and "2026-12-01" in text
    assert "Parked: 1" in text
