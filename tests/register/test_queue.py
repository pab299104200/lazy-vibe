import io

import pytest

from lazy_vibe.register.fingerprint import compute
from lazy_vibe.register.ingest import Candidate
from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.queue import QueueItem, build_queue, render_queue, run_triage
from lazy_vibe.register.reconcile import reconcile
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
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    kinds = {i.kind for i in items}
    assert "risk_accept" in kinds


def test_severity_review_section(store):
    f = with_history(make_finding(finding_id="R-0001", disposition="open",
                                  disposition_by="pete",
                                  severity_source="adjudicated"))
    f.history.append({"ts": "t", "event": "severity_review_proposed",
                      "current": "P2", "proposed": "P0", "run_id": "run2"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
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
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "reopen" for i in items)


def test_no_reopen_on_identical_evidence(store):
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/routers/evidence.py:118"})  # identical
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_scope_proposals_section(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[
        ScopeProposal("R-0001", "park", "left scope")], today="2026-06-11")
    assert any(i.kind == "scope" for i in items)


def test_unverified_section(store):
    f = _new("R-0001")  # new, no verification event
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "unverified" and i.finding_id == "R-0001"
               for i in items)


def test_verified_new_not_in_unverified(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "unverified" for i in items)


def test_fuzzy_confirm_pending_section(store):
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "fuzzy_confirm" for i in items)


def test_render_queue_groups_sections(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "Triage queue" in md
    assert "Proposed risk acceptances" in md
    assert "R-0001" in md


def test_render_empty_queue(store):
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
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
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
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
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
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
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
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
    items_a = build_queue(store, scope_proposals=[], today="2026-06-11")
    items_b = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert render_queue(items_a, product="meridian") == \
        render_queue(items_b, product="meridian")


def test_build_queue_does_not_mutate_register(store):
    """build_queue is a pure projection — no store.save, no history events."""
    f = _new("R-0001")
    store.save({f.finding_id: f})
    # record the history length before
    before = store.load()["R-0001"].history[:]
    build_queue(store, scope_proposals=[], today="2026-06-11")
    after = store.load()["R-0001"].history
    assert before == after


# ---------------------------------------------------------------------------
# C1 — reopen proposals must fire on REAL reconciler output, not only on
# hand-fabricated events: reconcile's suppression branch must stamp the
# occurrence's evidence ref on the suppressed_occurrence event so the
# queue's novelty comparison has something to compare.
# ---------------------------------------------------------------------------

_VOCAB = {"tenant_scope_missing": ["tenant scope"]}


def _risk_accepted_existing():
    """Register entry whose fingerprint matches _cand() exactly."""
    fp = compute("product_gap", "tenant_scope_missing",
                 "backend/routers/evidence.py", "-")
    return with_history(make_finding(
        fingerprint=fp, disposition="risk_accepted", disposition_by="pete",
        review_by="2026-12-01"))


def _cand(line="118"):
    return Candidate(blocker_id="B-0001", category="product_gap",
                     theme_raw="tenant_scope_missing", severity="P1",
                     path="backend/routers/evidence.py", line=line,
                     title="Evidence list endpoint not tenant-scoped",
                     references=f"backend/routers/evidence.py:{line}",
                     run_id="run2")


def test_reconcile_novel_ref_suppression_yields_one_reopen(store):
    """Full cycle: reconcile a candidate matching a risk_accepted finding at
    a NOVEL line -> the queue must show exactly one reopen item."""
    f = _risk_accepted_existing()  # existing evidence ref ...evidence.py:118
    store.save({f.finding_id: f})
    reconcile(store, [_cand(line="999")], _VOCAB,
              run_id="run2", date="2026-06-11")
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reopen = [i for i in items if i.kind == "reopen"]
    assert len(reopen) == 1
    assert reopen[0].finding_id == "R-0001"
    assert "backend/routers/evidence.py:999" in reopen[0].detail


def test_reconcile_same_ref_suppression_yields_no_reopen(store):
    """Full cycle: suppression at the SAME ref as existing evidence is
    silent (spec §4.2) — no reopen item."""
    f = _risk_accepted_existing()
    store.save({f.finding_id: f})
    reconcile(store, [_cand(line="118")], _VOCAB,
              run_id="run2", date="2026-06-11")
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_historical_suppression_event_without_ref_is_skipped(store):
    """Pre-C1 registers (meridian/portal) carry suppressed_occurrence events
    with no ref — the queue must tolerate them, not crash or false-flag."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2"})  # no ref key (historical shape)
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_reopen_rows_dedup_by_distinct_novel_ref(store):  # I1
    """Two suppressions citing the SAME novel ref -> one reopen row."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    for run in ("run2", "run3"):
        fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                           "run_id": run, "ref": "backend/core/other.py:9"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reopen = [i for i in items if i.kind == "reopen"]
    assert len(reopen) == 1


# ---------------------------------------------------------------------------
# C2 — past-due risk acceptances surface in the queue. build_queue takes a
# required ISO `today` (mirrors readiness.evaluate); risk_accepted findings
# whose review_by is in the past get a risk_review item.
# ---------------------------------------------------------------------------

def _risk_accepted(fid="R-0001", review_by="2026-01-01"):
    return with_history(make_finding(finding_id=fid,
                                     disposition="risk_accepted",
                                     disposition_by="pete",
                                     review_by=review_by))


def test_past_due_risk_review_appears_once(store):
    f = _risk_accepted(review_by="2026-01-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reviews = [i for i in items if i.kind == "risk_review"]
    assert len(reviews) == 1
    assert reviews[0].finding_id == "R-0001"
    assert "2026-01-01" in reviews[0].detail  # review_by date is displayed
    assert reviews[0].recommendation == "reaffirm or open"


def test_future_dated_risk_review_not_queued(store):
    f = _risk_accepted(review_by="2026-12-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "risk_review" for i in items)


def test_build_queue_rejects_malformed_today(store):
    with pytest.raises(RegisterError, match="ISO"):
        build_queue(store, scope_proposals=[], today="June 11th 2026")


def test_render_shows_risk_review_section(store):
    f = _risk_accepted(review_by="2026-01-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "Past-due risk acceptances" in md
    assert "2026-01-01" in md


# ---------------------------------------------------------------------------
# M1 — the unverified section is capped at 20 rows (397 on real data):
# total count in the heading, first 20 by severity, then an overflow line.
# ---------------------------------------------------------------------------

def test_unverified_section_caps_at_20_rows(store):
    findings = {}
    for i in range(1, 26):  # 25 unverified new findings
        fid = f"R-{i:04d}"
        findings[fid] = _new(fid, fingerprint=f"sha256:{i:016x}")
    store.save(findings)
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "## Unverified findings (25)" in md  # heading keeps the total
    section = md.split("## Unverified findings")[1]
    rows = [ln for ln in section.splitlines() if ln.startswith("| R-")]
    assert len(rows) == 20  # capped
    assert "…and 5 more — run verify-packets / run-triage.sh" in md


# ---------------------------------------------------------------------------
# Task 5: run_triage interactive walk
# ---------------------------------------------------------------------------


def _stdin(text):
    return io.StringIO(text)


def test_run_triage_open_decision(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    # unverified is empty (verified); force an item via risk_accept proposal
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "open"
    assert out.decided == 1


def test_run_triage_risk_accept_prompts_review_by(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    run_triage(store, scope_proposals=[], date="2026-06-11",
               stdin=_stdin("r\n2026-12-01\ncustomer launch slipped\n"),
               accept_all=False)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "risk_accepted"
    assert f2.review_by == "2026-12-01"
    assert f2.disposition_by == "pete"


def test_run_triage_skip_leaves_finding(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    run_triage(store, scope_proposals=[], date="2026-06-11",
               stdin=_stdin("s\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "new"


def test_run_triage_accept_all_applies_recommendations(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    # scope proposal park -> accept-all should park
    run_triage(store, scope_proposals=[
        ScopeProposal("R-0001", "park", "left scope")],
        date="2026-06-11", stdin=_stdin(""), accept_all=True)
    assert store.load()["R-0001"].disposition == "parked"
