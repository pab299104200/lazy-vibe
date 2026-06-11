import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.scorecard import parse_scorecard

SCORECARD = """\
# Cloud Connectors Scorecard

**Review Date:** 2026-06-10

## 2. Findings Table

| ID | Severity | Type | Title | Status |
|----|:--------:|------|-------|--------|
| B-01 | High | Bug | S3 collector aborts on out-of-region bucket | **Fixed — verified** (`aws_collectors.py:589`) |
| **B-05** | **Critical** | Bug | Multi-account sync runs with no RLS context | **OPEN (new)** |
| **B-07** | **Med** | Bug | Azure NSG misses `::/0` | **OPEN (new)** |
| G-03 | Med | Gap | Partial-collection surface S3 only | **Partially fixed; open** |
| S-03 | Med | Security | RLS isolation untested | **Resolved** |
| **CLOUD-B01** | High | Bug | S3 silent partial on token expiry | **Fixed — verified** |
| **A-06** | **Med** | Autonomy | sync-all runs serially in-request | **OPEN (new)** |
| U-04 | Med | UX | sync-all dead-end 409 | **Resolved by B-04 gate removal** |
| **M-01** | **Low** | Competitive | 6h cadence vs hourly | **OPEN (new)** |

## 3. Bugs

### B-05: Multi-account sync runs with no RLS context

**Evidence**
- `core/cloud_connector_sweeps.py:131` — raw session, no RLS context.
- `core/pipeline_runtime.py:1359` — passes SessionLocal.

### B-07: Azure NSG open-to-world misses `::/0`

Some prose without backticked refs first, then `connectors/azure.py:712`.
"""


@pytest.fixture
def scorecard(tmp_path):
    p = tmp_path / "cloud-connectors.md"
    p.write_text(SCORECARD)
    return p


def test_parses_only_open_findings(scorecard):
    cands = parse_scorecard(scorecard, slug="cloud-connectors",
                            run_id="scorecards-2026-06-10")
    ids = [c.blocker_id for c in cands]
    assert ids == ["cloud-connectors:B-05", "cloud-connectors:B-07",
                   "cloud-connectors:G-03", "cloud-connectors:A-06",
                   "cloud-connectors:M-01"]


def test_severity_mapping(scorecard):
    cands = {c.blocker_id: c for c in parse_scorecard(
        scorecard, slug="cloud-connectors", run_id="r")}
    assert cands["cloud-connectors:B-05"].severity == "P0"   # Critical
    assert cands["cloud-connectors:B-07"].severity == "P2"   # Med
    assert cands["cloud-connectors:M-01"].severity == "P3"   # Low


def test_taxonomy_from_id_prefix(scorecard):
    cands = {c.blocker_id: c for c in parse_scorecard(
        scorecard, slug="cloud-connectors", run_id="r")}
    assert cands["cloud-connectors:B-05"].taxonomy == "B"
    assert cands["cloud-connectors:G-03"].taxonomy == "G"
    assert cands["cloud-connectors:A-06"].taxonomy == "A"
    assert cands["cloud-connectors:M-01"].taxonomy == "M"


def test_path_from_detail_section_evidence(scorecard):
    cands = {c.blocker_id: c for c in parse_scorecard(
        scorecard, slug="cloud-connectors", run_id="r")}
    assert cands["cloud-connectors:B-05"].path == \
        "core/cloud_connector_sweeps.py"
    assert cands["cloud-connectors:B-05"].line == "131"
    assert cands["cloud-connectors:B-07"].path == "connectors/azure.py"


def test_path_falls_back_to_scorecard(scorecard):
    cands = {c.blocker_id: c for c in parse_scorecard(
        scorecard, slug="cloud-connectors", run_id="r")}
    # G-03, A-06, M-01 have no detail sections
    assert cands["cloud-connectors:G-03"].path.endswith("cloud-connectors.md")
    assert cands["cloud-connectors:G-03"].line == "-"


def test_theme_is_slug_and_candidate_fields(scorecard):
    c = parse_scorecard(scorecard, slug="cloud-connectors", run_id="r")[0]
    assert c.theme_raw == "cloud-connectors"
    assert c.category == "product_gap"
    assert c.run_id == "r"
    assert "cloud-connectors.md#B-05" in c.references


def test_missing_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="scorecard"):
        parse_scorecard(tmp_path / "nope.md", slug="x", run_id="r")


def test_no_findings_table_is_hard_error(tmp_path):
    p = tmp_path / "empty.md"
    p.write_text("# Scorecard\n\nNo table here.\n")
    with pytest.raises(RegisterError, match="findings table"):
        parse_scorecard(p, slug="x", run_id="r")


def test_unknown_severity_is_hard_error(tmp_path, scorecard):
    p = tmp_path / "bad.md"
    p.write_text(scorecard.read_text().replace("**Critical**", "Mega"))
    with pytest.raises(RegisterError, match="severity"):
        parse_scorecard(p, slug="x", run_id="r")
