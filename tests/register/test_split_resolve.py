import json

import pytest

from lazy_vibe.register.split_resolve import (
    RESULT_SCHEMA_VERSION,
    consume_split_results,
    generate_split_packets,
    split_packet_path,
    split_result_path,
)
from lazy_vibe.register.store import RegisterStore
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def _split_finding(fid="R-0001"):
    f = make_finding(finding_id=fid, disposition="new", disposition_by="ingest")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "split", "by": "agent:verifier"})
    f.history.append({"ts": "t", "event": "split_proposed",
                      "split_paths": ["backend/a.py", "frontend/b.tsx"],
                      "by": "agent:verifier"})
    return f


def _write_result(store, fid, decision="open", **payload):
    data = {
        "schema_version": RESULT_SCHEMA_VERSION,
        "finding_id": fid,
        "decision": decision,
        "evidence": ["backend/a.py:1"],
        "reason": "agent resolved split",
    }
    data.update(payload)
    path = split_result_path(store, fid)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


def test_generate_split_packets_targets_split_proposed_new_findings(store):
    f = _split_finding()
    other = make_finding(finding_id="R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb",
                         disposition="new", disposition_by="ingest")
    store.save({f.finding_id: f, other.finding_id: other})

    written = generate_split_packets(store)

    assert [p.name for p in written] == ["R-0001.md"]
    text = split_packet_path(store, "R-0001").read_text()
    assert "Split-resolution packet" in text
    assert "backend/a.py" in text
    assert '"decision": "open | false_positive | park"' in text


def test_consume_split_open_adds_verified_event_and_opens(store):
    f = _split_finding()
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", "open")

    outcome = consume_split_results(store, date="2026-06-12")

    loaded = store.load()["R-0001"]
    assert outcome.opened == ["R-0001"]
    assert loaded.disposition == "open"
    assert loaded.disposition_by == "policy:split-resolver"
    assert any(h.get("event") == "split_resolved" for h in loaded.history)
    assert any(h.get("event") == "verification" and h.get("verdict") == "VERIFIED"
               for h in loaded.history)
    assert not split_result_path(store, "R-0001").exists()


def test_consume_split_false_positive(store):
    f = _split_finding()
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", "false_positive")

    outcome = consume_split_results(store, date="2026-06-12")

    loaded = store.load()["R-0001"]
    assert outcome.false_positive == ["R-0001"]
    assert loaded.disposition == "false_positive"
    assert loaded.disposition_by == "policy:split-resolver"


def test_consume_split_park(store):
    f = _split_finding()
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", "park", evidence=[])

    outcome = consume_split_results(store, date="2026-06-12")

    loaded = store.load()["R-0001"]
    assert outcome.parked == ["R-0001"]
    assert loaded.disposition == "parked"
    assert loaded.disposition_by == "policy:split-resolver"


def test_consume_split_rejects_open_without_evidence(store):
    f = _split_finding()
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", "open", evidence=[])

    with pytest.raises(ValueError, match="open requires evidence"):
        consume_split_results(store, date="2026-06-12")
