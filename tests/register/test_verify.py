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
