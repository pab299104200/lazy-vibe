import json  # noqa: F401  # used by Task-2 helpers appended to this file

import pytest

from lazy_vibe.register.store import RegisterStore
from lazy_vibe.register.verify import (RESULT_SCHEMA_VERSION, generate_packets,
                                       packet_path, result_path)
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def _new(fid="R-0001", **kw):
    return make_finding(finding_id=fid, disposition="new",
                        disposition_by="ingest", **kw)


def test_generate_packets_writes_one_per_new_finding(store):
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    written = generate_packets(store)
    assert {p.name for p in written} == {"R-0001.md", "R-0002.md"}
    assert packet_path(store, "R-0001").exists()
    text = packet_path(store, "R-0001").read_text()
    assert "R-0001" in text
    assert "VERIFIED" in text and "UNSUPPORTED" in text
    assert str(result_path(store, "R-0001")) in text
    assert "backend/routers/evidence.py:118" in text  # evidence ref echoed


def test_generate_packets_skips_non_new(store):
    from tests.register.helpers import with_history
    f_new = _new("R-0001")
    f_open = with_history(make_finding(finding_id="R-0002",
                                       fingerprint="sha256:bbbbbbbbbbbbbbbb",
                                       disposition="open", disposition_by="pete"))
    store.save({f_new.finding_id: f_new, f_open.finding_id: f_open})
    written = generate_packets(store)
    assert {p.name for p in written} == {"R-0001.md"}


def test_generate_packets_is_idempotent_and_regenerates(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    first = packet_path(store, "R-0001").read_text()
    generate_packets(store)
    assert packet_path(store, "R-0001").read_text() == first


def test_packet_for_fuzzy_candidate_asks_duplicate_question(store):
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "2026-06-01T00:00:00+00:00",
                      "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0002").read_text()
    assert "duplicate_of" in text
    assert "R-0001" in text


def test_packet_without_fuzzy_pins_duplicate_of_null(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    # contract still names duplicate_of but instructs null when no candidate
    assert "duplicate_of" in text
    assert "null" in text


def test_packet_documents_split_verdict(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    assert "split" in text  # collision/divergent-evidence escape hatch (spec §12)


def test_result_schema_version_is_stamped(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    assert f"schema_version: {RESULT_SCHEMA_VERSION}" in \
        packet_path(store, "R-0001").read_text()


def test_packet_paths_are_under_triage(store):
    assert packet_path(store, "R-0001").parent.name == "packets"
    assert result_path(store, "R-0001").parent.name == "results"
    assert packet_path(store, "R-0001").parent.parent.name == "triage"


def test_generate_packets_escapes_finding_text(store):
    f = _new("R-0001", title="bad ```fence``` and | pipe")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    # finding text is rendered inside a fenced JSON context block; the
    # triple-backtick fence in the title must not break the markdown fence
    assert "bad ` ` `fence` ` `" in text or "bad &#96;" in text or \
        "bad '''fence'''" in text


# ---------------------------------------------------------------------------
# Task 2: result consumption tests
# ---------------------------------------------------------------------------

from lazy_vibe.register.model import RegisterError  # noqa: E402
from lazy_vibe.register.verify import consume_results, last_verification  # noqa: E402


def _write_result(store, fid, **payload):
    base = {"schema_version": RESULT_SCHEMA_VERSION, "finding_id": fid,
            "verdict": "VERIFIED", "evidence": ["x.py:1"],
            "mechanism": "m", "duplicate_of": None, "split_paths": []}
    base.update(payload)
    p = result_path(store, fid)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(base))


def test_consume_verified_appends_event_and_stays_new(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    outcome = consume_results(store)
    findings = store.load()
    assert findings["R-0001"].disposition == "new"
    assert last_verification(findings["R-0001"])["verdict"] == "VERIFIED"
    assert findings["R-0001"].history[-1]["by"] == "agent:verifier"
    assert outcome.verified == ["R-0001"]


def test_consume_unsupported_proposes_false_positive(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="UNSUPPORTED",
                  evidence=["x.py:1 returns 404 for cross-tenant read"],
                  mechanism="route is account-scoped by dependency")
    consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "false_positive"
    assert f2.disposition_by == "policy:verifier-unsupported"


def test_consume_confirmed_duplicate_proposes_false_positive(store):
    orig = _new("R-0001")
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0001", verdict="VERIFIED")
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["x.py:1"])
    consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "false_positive"
    assert "R-0001" in findings["R-0002"].disposition_reason
    assert any(h.get("event") == "duplicate_confirmed"
               for h in findings["R-0002"].history)
    # original absorbs the duplicate's evidence ref
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "x.py:1" in refs


def test_consume_split_queues_event_and_keeps_new(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="split",
                  split_paths=["a.py:1", "b.py:2"])
    consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert any(h.get("event") == "split_proposed" for h in f2.history)


def test_consume_rejects_unknown_schema_version(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", schema_version=999)
    with pytest.raises(RegisterError, match="schema_version"):
        consume_results(store)


def test_consume_rejects_bad_verdict(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="MAYBE")
    with pytest.raises(RegisterError, match="verdict"):
        consume_results(store)


def test_consume_rejects_verified_without_evidence(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", evidence=[])
    with pytest.raises(RegisterError, match="evidence"):
        consume_results(store)


def test_consume_rejects_mismatched_finding_id(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", finding_id="R-0099")
    with pytest.raises(RegisterError, match="finding_id"):
        consume_results(store)


def test_consume_rejects_corrupt_json(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    p = result_path(store, "R-0001")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("{not json")
    with pytest.raises(RegisterError, match="corrupt"):
        consume_results(store)


def test_consume_never_touches_protected_state(store):
    from tests.register.helpers import with_history
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    store.save({fp.finding_id: fp})
    _write_result(store, "R-0001", verdict="UNSUPPORTED",
                  evidence=["x.py:1"], mechanism="m")
    outcome = consume_results(store)
    # no packet was generated for a non-new finding; a stray result is ignored
    assert store.load()["R-0001"].disposition == "false_positive"
    assert "R-0001" in outcome.skipped


def test_consume_missing_result_is_unverified(store):
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    _write_result(store, "R-0001", verdict="VERIFIED")
    outcome = consume_results(store)
    assert outcome.verified == ["R-0001"]
    assert outcome.unverified == ["R-0002"]  # no result file -> stays new
