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


# ---------------------------------------------------------------------------
# Quality-review hardening: verifier-input attack paths + idempotency
# ---------------------------------------------------------------------------

def test_consume_rejects_self_duplicate(store):  # C1
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0001")
    with pytest.raises(RegisterError, match="duplicate of itself"):
        consume_results(store)
    # loud rejection aborts before save: finding stays new, untouched
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert last_verification(f2) is None


def test_consume_rejects_non_string_evidence(store):  # C2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED",
                  evidence=[{"ref": "x"}, None])
    with pytest.raises(RegisterError, match=r"evidence\[0\]"):
        consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert last_verification(f2) is None  # no polluted history event


def test_consume_rejects_non_string_duplicate_of(store):  # C2 root cause
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", duplicate_of=["R-0002"])
    with pytest.raises(RegisterError, match="duplicate_of"):
        consume_results(store)


def test_consume_rejects_non_string_split_paths(store):  # C2 root cause
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="split", split_paths=[1, "a.py"])
    with pytest.raises(RegisterError, match="split_paths"):
        consume_results(store)


def test_consume_refuses_duplicate_absorb_into_adjudicated(store):  # I3
    from tests.register.helpers import with_history
    orig = with_history(make_finding(finding_id="R-0001",
                                     disposition="false_positive",
                                     disposition_by="pete"))
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["y.py:9"])
    with pytest.raises(RegisterError, match="adjudicated"):
        consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "new"  # batch aborted, no save
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "y.py:9" not in refs  # adjudicated entry not tampered with


def test_consume_duplicate_absorb_into_active_target(store):  # I3
    from tests.register.helpers import with_history
    orig = with_history(make_finding(finding_id="R-0001", disposition="open",
                                     disposition_by="pete"))
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["y.py:9"])
    consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "false_positive"
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "y.py:9" in refs  # active target absorbs the evidence


def test_absorb_dedups_on_ref_alone(store):  # I1
    orig = _new("R-0001")
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    # duplicate cites the exact ref the original already carries, but from a
    # different run -- (ref, run_id) keying would wrongly re-append it
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["backend/routers/evidence.py:118"])
    consume_results(store)
    refs = [e["ref"] for e in store.load()["R-0001"].evidence]
    assert refs.count("backend/routers/evidence.py:118") == 1


def test_consume_is_idempotent(store):  # I2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    first = consume_results(store)
    second = consume_results(store)
    events = [h for h in store.load()["R-0001"].history
              if h.get("event") == "verification"]
    assert len(events) == 1  # second run found no pending result
    assert first.verified == ["R-0001"]
    assert second.verified == []
    assert second.unverified == []  # already verified, not "unverified"
    assert second.false_positive == [] and second.split == []


def test_consumed_result_moves_to_consumed_dir(store):  # I2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    consume_results(store)
    assert not result_path(store, "R-0001").exists()
    consumed = (store.register_dir / "triage" / "results" / "consumed"
                / "R-0001.json")
    assert consumed.exists()


def test_stray_result_for_non_new_is_archived(store):  # I2
    from tests.register.helpers import with_history
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    store.save({fp.finding_id: fp})
    _write_result(store, "R-0001", verdict="UNSUPPORTED", evidence=["x.py:1"])
    consume_results(store)
    assert not result_path(store, "R-0001").exists()  # stray result archived


def test_consume_rejects_unsolicited_duplicate_claim(store):
    # packet pinned duplicate_of: null (no fuzzy candidate) -- the verifier
    # cannot close its own finding by naming an arbitrary real target
    f = _new("R-0001")
    other = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f.finding_id: f, other.finding_id: other})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0002")
    with pytest.raises(RegisterError, match="unsolicited duplicate claim"):
        consume_results(store)
    findings = store.load()
    assert findings["R-0001"].disposition == "new"  # both findings untouched
    assert last_verification(findings["R-0001"]) is None
    refs = {e["ref"] for e in findings["R-0002"].evidence}
    assert "x.py:1" not in refs  # no evidence injected into the named target
    assert result_path(store, "R-0001").exists()  # nothing archived


def test_consume_rejects_duplicate_claim_for_wrong_candidate(store):
    # packet pinned R-0001; the verifier names a different (here nonexistent)
    # id -- previously a nonexistent duplicate_of vanished silently
    orig = _new("R-0001")
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, f.finding_id: f})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0004")
    with pytest.raises(RegisterError, match="unsolicited duplicate claim"):
        consume_results(store)
    assert store.load()["R-0002"].disposition == "new"
    assert result_path(store, "R-0002").exists()  # nothing archived


def test_consume_rejects_pinned_candidate_missing_from_register(store):
    # register inconsistency: the pinned candidate id does not exist; a
    # matching duplicate claim must still fail loudly, never fall through
    # silently to verified (the pre-binding behavior)
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0099", "run_id": "run1"})
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0099")
    with pytest.raises(RegisterError, match="not in register"):
        consume_results(store)
    assert store.load()["R-0001"].disposition == "new"
