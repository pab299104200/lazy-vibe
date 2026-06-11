import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def test_load_empty_register(store):
    assert store.load() == {}


def test_save_and_load_round_trip(store):
    f1 = make_finding()
    f2 = make_finding(finding_id="R-0002", fingerprint="sha256:aaaaaaaaaaaaaaaa",
                      title="Other finding")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    loaded = store.load()
    assert set(loaded) == {"R-0001", "R-0002"}
    assert loaded["R-0001"] == f1


def test_save_creates_directory_and_markdown(store):
    f = make_finding()
    store.save({f.finding_id: f})
    assert store.jsonl_path.exists()
    md = store.markdown_path.read_text()
    assert "generated" in md.lower()
    assert "R-0001" in md
    assert "Evidence list endpoint not tenant-scoped" in md


def test_corrupt_line_is_hard_error_with_line_number(store):
    f = make_finding()
    store.save({f.finding_id: f})
    with store.jsonl_path.open("a") as fh:
        fh.write("{broken\n")
    with pytest.raises(RegisterError, match="line 2"):
        store.load()


def test_next_id(store):
    assert store.next_id({}) == "R-0001"
    f = make_finding(finding_id="R-0041")
    assert store.next_id({f.finding_id: f}) == "R-0042"


def test_by_fingerprint_index(store):
    f = make_finding()
    store.save({f.finding_id: f})
    findings = store.load()
    index = store.by_fingerprint(findings)
    assert index["sha256:8c1f0b2a9d4e6f31"].finding_id == "R-0001"


def test_markdown_groups_by_disposition_and_severity(store):
    f_open = with_history(make_finding(finding_id="R-0001",
                                       fingerprint="sha256:aaaaaaaaaaaaaaa1",
                                       disposition="open", severity="P1"))
    f_open_p0 = with_history(make_finding(finding_id="R-0002",
                                          fingerprint="sha256:aaaaaaaaaaaaaaa2",
                                          disposition="open", severity="P0"))
    f_parked = with_history(make_finding(finding_id="R-0003",
                                         fingerprint="sha256:aaaaaaaaaaaaaaa3",
                                         disposition="parked"))
    store.save({f.finding_id: f for f in (f_open, f_open_p0, f_parked)})
    md = store.markdown_path.read_text()
    assert md.index("## open") < md.index("## parked")
    # P0 row renders before P1 row within the open section
    assert md.index("R-0002") < md.index("R-0001")


def test_save_rejects_disposition_without_matching_history(store):
    smuggled = make_finding(disposition="open")  # no disposition event
    with pytest.raises(RegisterError, match="history"):
        store.save({smuggled.finding_id: smuggled})


def test_save_rejects_disposition_contradicting_history(store):
    f = with_history(make_finding(disposition="open"))
    f.disposition = "fixed"  # mutated around transition()
    f.regression_test = "tests/test_x.py::test_y"
    with pytest.raises(RegisterError, match="history"):
        store.save({f.finding_id: f})


def test_load_rejects_hand_edited_disposition(store):
    f = with_history(make_finding(disposition="open"))
    store.save({f.finding_id: f})
    text = store.jsonl_path.read_text().replace('"disposition": "open"',
                                                '"disposition": "parked"')
    store.jsonl_path.write_text(text)
    with pytest.raises(RegisterError, match="history"):
        store.load()


def test_save_rejects_illegal_history_edge(store):
    f = make_finding(disposition="fixed",
                     regression_test="tests/test_x.py::test_y")
    f.history.append({"ts": "t", "event": "disposition", "from": "new",
                      "to": "fixed", "by": "x", "reason": "fabricated"})
    with pytest.raises(RegisterError, match="illegal edge"):
        store.save({f.finding_id: f})


def test_save_rejects_broken_history_chain(store):
    f = make_finding(disposition="in_remediation")
    f.history.append({"ts": "t", "event": "disposition", "from": "open",
                      "to": "in_remediation", "by": "x", "reason": "no start"})
    with pytest.raises(RegisterError, match="chain"):
        store.save({f.finding_id: f})


def test_markdown_escapes_pipes_and_newlines(store):
    f = make_finding(title="SQLi in users | OR 1=1")
    store.save({f.finding_id: f})
    md = store.markdown_path.read_text()
    assert "SQLi in users \\| OR 1=1" in md


def test_save_seeds_gitignore(store):
    f = make_finding()
    store.save({f.finding_id: f})
    gi = (store.register_dir / ".gitignore").read_text()
    assert ".register.lock" in gi and "*.tmp" in gi
