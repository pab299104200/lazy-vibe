import pytest

from lazy_vibe.register.fingerprint import compute
from lazy_vibe.register.ingest import Candidate
from lazy_vibe.register.reconcile import reconcile, render_report
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

VOCAB = {"tenant_scope_missing": ["tenant scope"],
         "browser_evidence_missing": ["browser proof"]}
RUN = "2026-06-11-0900"
DATE = "2026-06-11"


def cand(**overrides):
    base = dict(blocker_id="B-0001", category="product_gap",
                theme_raw="tenant_scope_missing", severity="P1",
                path="backend/routers/evidence.py", line="118",
                title="Evidence list endpoint not tenant-scoped",
                references="backend/routers/evidence.py:118", run_id=RUN)
    base.update(overrides)
    return Candidate(**base)


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def existing(**overrides):
    """Register entry whose fingerprint matches cand() exactly.

    Wrapped in with_history so adjudicated dispositions satisfy the
    store's history invariant (see Task 5)."""
    fp = compute("product_gap", "tenant_scope_missing",
                 "backend/routers/evidence.py", "-")
    return with_history(make_finding(fingerprint=fp, **overrides))


def test_no_match_creates_new_finding(store):
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    # Post-reconcile state travels with the result so callers can render
    # the report without an unlocked second store.load().
    assert set(result.findings) == {"R-0001"}
    loaded = store.load()
    f = loaded["R-0001"]
    assert f.disposition == "new"
    assert f.severity == "P1"
    assert f.fingerprint_inputs["theme"] == "tenant_scope_missing"
    assert f.evidence[0]["ref"] == "backend/routers/evidence.py:118"
    assert f.history[0]["event"] == "created"


def test_match_on_protected_disposition_suppresses(store):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.suppressed] == ["R-0001"]
    assert result.new == []
    loaded = store.load()["R-0001"]
    assert loaded.disposition == "risk_accepted"
    assert loaded.occurrences == 2
    assert loaded.last_seen == {"run_id": RUN, "date": DATE}
    assert loaded.history[-1]["event"] == "suppressed_occurrence"


def test_match_on_open_merges_evidence(store):
    f = existing(disposition="open", disposition_by="pete",
                 evidence=[{"type": "code",
                            "ref": "backend/routers/evidence.py:118",
                            "run_id": "old-run"}])
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.merged] == ["R-0001"]
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 2
    refs = {(e["ref"], e["run_id"]) for e in loaded.evidence}
    assert ("backend/routers/evidence.py:118", RUN) in refs
    assert ("backend/routers/evidence.py:118", "old-run") in refs


def test_match_on_fixed_flags_regression(store):
    f = existing(disposition="fixed",
                 regression_test="tests/test_evidence.py::test_tenant_scope")
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.regressed] == ["R-0001"]
    assert store.load()["R-0001"].disposition == "regressed"


def test_higher_proposed_severity_on_adjudicated_entry_queues_review(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="adjudicated")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    loaded = store.load()["R-0001"]
    assert loaded.severity == "P2"  # adjudicated value untouched
    assert loaded.history[-1]["event"] == "severity_review_proposed"
    assert loaded.history[-1]["proposed"] == "P0"


def test_higher_proposed_severity_on_proposed_entry_escalates(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="proposed")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    assert store.load()["R-0001"].severity == "P0"


def test_fuzzy_match_recorded_on_new_entry(store):
    f = existing(disposition="open", disposition_by="pete")
    store.save({f.finding_id: f})
    # Same path + category, different theme -> different fingerprint,
    # title overlaps heavily -> fuzzy candidate.
    c = cand(theme_raw="weird new theme wording",
             title="Evidence list endpoint not scoped to tenant")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert len(result.new) == 1
    new = store.load()[result.new[0].finding_id]
    assert new.history[-1]["event"] == "fuzzy_match_candidate"
    assert new.history[-1]["candidate_of"] == "R-0001"
    assert (result.new[0].finding_id, "R-0001") in result.fuzzy


def test_same_run_siblings_fuzzy_link(store):
    a = cand()
    b = cand(blocker_id="B-0002", theme_raw="fragmented theme wording",
             title="Evidence list endpoint not scoped to tenant")
    result = reconcile(store, [a, b], VOCAB, run_id=RUN, date=DATE)
    assert len(result.new) == 2
    ids = [f.finding_id for f in result.new]
    assert (ids[1], ids[0]) in result.fuzzy


def test_unmapped_theme_becomes_candidate_theme(store):
    c = cand(theme_raw="totally novel concern")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    f = store.load()[result.new[0].finding_id]
    assert f.fingerprint_inputs["theme"] == "_candidate:totally_novel_concern"
    assert "_candidate:totally_novel_concern" in result.theme_candidates


def test_within_run_duplicate_fingerprint_does_not_double_count(store):
    dup = cand(blocker_id="B-0009", line="240",
               references="backend/routers/evidence.py:240")
    result = reconcile(store, [cand(), dup], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    assert result.merged == []
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 1
    refs = {e["ref"] for e in loaded.evidence}
    assert "backend/routers/evidence.py:118" in refs
    assert "backend/routers/evidence.py:240" in refs


def test_within_run_duplicate_higher_severity_escalates(store):
    dup = cand(blocker_id="B-0009", severity="P0", line="240")
    result = reconcile(store, [cand(), dup], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    loaded = store.load()["R-0001"]
    assert loaded.severity == "P0"
    assert loaded.occurrences == 1


def test_replay_does_not_duplicate_severity_review(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="adjudicated")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    loaded = store.load()["R-0001"]
    events = [h for h in loaded.history
              if h["event"] == "severity_review_proposed"]
    assert len(events) == 1


def test_reconcile_same_run_is_idempotent(store):
    first = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert len(first.new) == 1
    replay = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert replay.new == [] and replay.merged == []
    assert store.load()["R-0001"].occurrences == 1


def test_replay_does_not_double_suppress(store):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    second = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert second.suppressed == []
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 2  # bumped by the first run only
    events = [h for h in loaded.history if h["event"] == "suppressed_occurrence"]
    assert len(events) == 1


def test_render_report_headline(store, tmp_path):
    f_fixed = existing(disposition="fixed",
                       regression_test="tests/test_evidence.py::test_x")
    store.save({f_fixed.finding_id: f_fixed})
    result = reconcile(
        store,
        [cand(),
         cand(blocker_id="B-0002", category="evidence_gap",
              theme_raw="browser_evidence_missing", severity="P2",
              path="docs/ux/journeys.md", line="-",
              title="No browser proof for evidence journey")],
        VOCAB, run_id=RUN, date=DATE)
    report_path = tmp_path / "reconcile-report.md"
    render_report(result, store.load(), report_path, run_id=RUN)
    text = report_path.read_text()
    assert "1 new, 0 suppressed, 1 regressed" in text
    assert "## Regressions" in text
    assert "## New findings" in text


def test_candidate_taxonomy_flows_to_finding(store):
    c = cand(taxonomy="S")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert store.load()[result.new[0].finding_id].taxonomy == "S"


def test_render_report_shows_fuzzy_duplicate_disposition(store, tmp_path):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    c = cand(theme_raw="weird new theme wording",
             title="Evidence list endpoint not scoped to tenant")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert (result.new[0].finding_id, "R-0001") in result.fuzzy
    report_path = tmp_path / "reconcile-report.md"
    render_report(result, store.load(), report_path, run_id=RUN)
    text = report_path.read_text()
    # Triager must see the duplicate target was adjudicated away.
    assert "R-0001 (risk_accepted)" in text


def test_reconcile_with_scope_parks_out_of_scope_new(store, tmp_path):
    from lazy_vibe.register.scope import load_scope
    p = tmp_path / "launch-scope.yaml"
    p.write_text("product: meridian\ndefault_in_scope: false\n"
                 "surfaces:\n  - slug: other\n    paths: ['frontend/']\n")
    scope = load_scope(p)
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE,
                       scope=scope)
    f = store.load()[result.new[0].finding_id]
    assert f.in_scope is False
    assert f.disposition == "parked"
    assert f.disposition_by == "scope"


def test_reconcile_with_scope_keeps_in_scope_new(store, tmp_path):
    from lazy_vibe.register.scope import load_scope
    p = tmp_path / "launch-scope.yaml"
    p.write_text("product: meridian\ndefault_in_scope: false\n"
                 "surfaces:\n  - slug: ev\n    paths: ['backend/routers/']\n")
    scope = load_scope(p)
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE,
                       scope=scope)
    f = store.load()[result.new[0].finding_id]
    assert f.in_scope is True
    assert f.disposition == "new"


def test_distinct_symbols_same_path_do_not_merge(store):
    # Two different findings citing the same file in the same run must stay
    # two register entries — symbol is part of fingerprint identity
    # (spec §4.1; real case: cloud-connectors B-05 vs B-06).
    a = cand(blocker_id="cc:B-05", symbol="B-05",
             title="Multi-account sync runs with no RLS context")
    b = cand(blocker_id="cc:B-06", symbol="B-06",
             title="Sweep session misattributes bindings")
    result = reconcile(store, [a, b], VOCAB, run_id=RUN, date=DATE)
    assert len(result.new) == 2
    findings = store.load()
    assert len(findings) == 2
    assert len({f.fingerprint for f in findings.values()}) == 2
    assert {f.fingerprint_inputs["symbol"] for f in findings.values()} == \
        {"B-05", "B-06"}


def test_ledger_candidates_default_symbol_dash(store):
    # Ledger-sourced candidates carry no symbol; identity stays
    # (category|theme|path|-) exactly as before.
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    f = store.load()[result.new[0].finding_id]
    assert f.fingerprint_inputs["symbol"] == "-"
