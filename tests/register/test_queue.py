import pytest

from lazy_vibe.register.queue import QueueItem, build_queue, render_queue
from lazy_vibe.register.scope import ScopeProposal
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def _new(fid="R-0001", **kw):
    return make_finding(finding_id=fid, disposition="new",
                        disposition_by="ingest", **kw)


def test_risk_accept_proposal_section(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:dev-dep", "rule": "dev-dep"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    kinds = {i.kind for i in items}
    assert "risk_accept" in kinds


def test_severity_review_section(store):
    f = with_history(make_finding(finding_id="R-0001", disposition="open",
                                  disposition_by="pete",
                                  severity_source="adjudicated"))
    f.history.append({"ts": "t", "event": "severity_review_proposed",
                      "current": "P2", "proposed": "P0", "run_id": "run2"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    assert any(i.kind == "severity_review" and i.finding_id == "R-0001"
               for i in items)


def test_reopen_proposal_on_materially_different_evidence(store):
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    # existing evidence ref is backend/routers/evidence.py:118 (make_finding)
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/other.py:9"})  # new ref
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[])
    assert any(i.kind == "reopen" for i in items)


def test_no_reopen_on_identical_evidence(store):
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/routers/evidence.py:118"})  # identical
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[])
    assert not any(i.kind == "reopen" for i in items)


def test_scope_proposals_section(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[
        ScopeProposal("R-0001", "park", "left scope")])
    assert any(i.kind == "scope" for i in items)


def test_unverified_section(store):
    f = _new("R-0001")  # new, no verification event
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    assert any(i.kind == "unverified" and i.finding_id == "R-0001"
               for i in items)


def test_verified_new_not_in_unverified(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    assert not any(i.kind == "unverified" for i in items)


def test_fuzzy_confirm_pending_section(store):
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    assert any(i.kind == "fuzzy_confirm" for i in items)


def test_render_queue_groups_sections(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    md = render_queue(items, product="meridian")
    assert "Triage queue" in md
    assert "Proposed risk acceptances" in md
    assert "R-0001" in md


def test_render_empty_queue(store):
    items = build_queue(store, scope_proposals=[])
    md = render_queue(items, product="meridian")
    assert "no items" in md.lower()


# ---------------------------------------------------------------------------
# Cell-escaping: every free-text value rendered into table cells must go
# through markdown_cell (hard requirement from T2 review carry-forward).
# Verifier-supplied evidence refs may contain | and newlines — injection
# vectors flagged in NOTE(M3) in verify.py.
# ---------------------------------------------------------------------------

def test_render_escapes_pipe_in_title(store):
    """Title with | must not break the markdown table."""
    f = _new("R-0001", title="foo | bar | baz")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[])
    md = render_queue(items, product="meridian")
    # Unescaped | would create extra columns; check the title cell is escaped
    assert "foo \\| bar \\| baz" in md


def test_render_escapes_newline_in_detail(store):
    """Detail containing newline must be collapsed to a single line."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    # ref with embedded newline — verifier-supplied injection vector
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/evil.py:9\nINJECTED"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[])
    md = render_queue(items, product="meridian")
    # The newline must not survive into the rendered table
    assert "INJECTED\n" not in md


def test_render_escapes_pipe_in_reopen_detail(store):
    """Reopen detail built from verifier-supplied ref must escape pipes."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/evil.py:9 | malicious"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[])
    md = render_queue(items, product="meridian")
    assert "\\|" in md


def test_render_escapes_pipe_in_recommendation(store):
    """Recommendation field is free-text and must go through markdown_cell."""
    # Simulate a scope proposal whose reason/kind contains a pipe — any
    # free-text that reaches the table must be escaped.
    f = _new("R-0001")
    store.save({f.finding_id: f})
    # ScopeProposal.kind can be "park" or "open" (literal) but the
    # QueueItem.recommendation is built from it; any free-text value must
    # be escaped. We inject directly into a QueueItem to test render isolation.
    item = QueueItem("R-0001", "scope", "P1", "safe title",
                     "safe detail", recommendation="park | INJECTED")
    md = render_queue([item], product="meridian")
    assert "park \\| INJECTED" in md


def test_render_is_deterministic(store):
    """Same register state produces byte-identical output on repeated calls."""
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f1.history.append({"ts": "t", "event": "risk_accept_proposed",
                       "by": "policy:x", "rule": "x"})
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    items_a = build_queue(store, scope_proposals=[])
    items_b = build_queue(store, scope_proposals=[])
    assert render_queue(items_a, product="meridian") == \
        render_queue(items_b, product="meridian")


def test_build_queue_does_not_mutate_register(store):
    """build_queue is a pure projection — no store.save, no history events."""
    f = _new("R-0001")
    store.save({f.finding_id: f})
    # record the history length before
    before = store.load()["R-0001"].history[:]
    build_queue(store, scope_proposals=[])
    after = store.load()["R-0001"].history
    assert before == after
