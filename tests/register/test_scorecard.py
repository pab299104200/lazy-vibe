from pathlib import Path

import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.scorecard import ScorecardParse, parse_scorecard

CORPUS_DIR = Path("/home/pete/cadres/meridian/docs/scorecards")

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


def cands_by_id(path, slug="cloud-connectors", run_id="r"):
    result = parse_scorecard(path, slug=slug, run_id=run_id)
    return {c.blocker_id: c for c in result.candidates}


# ---------------------------------------------------------------- base format


def test_returns_scorecard_parse(scorecard):
    result = parse_scorecard(scorecard, slug="cloud-connectors", run_id="r")
    assert isinstance(result, ScorecardParse)
    assert result.problems == []


def test_parses_only_open_findings(scorecard):
    result = parse_scorecard(scorecard, slug="cloud-connectors",
                             run_id="scorecards-2026-06-10")
    ids = [c.blocker_id for c in result.candidates]
    assert ids == ["cloud-connectors:B-05", "cloud-connectors:B-07",
                   "cloud-connectors:G-03", "cloud-connectors:A-06",
                   "cloud-connectors:M-01"]


def test_severity_mapping(scorecard):
    cands = cands_by_id(scorecard)
    assert cands["cloud-connectors:B-05"].severity == "P0"   # Critical
    assert cands["cloud-connectors:B-07"].severity == "P2"   # Med
    assert cands["cloud-connectors:M-01"].severity == "P3"   # Low


def test_taxonomy_from_id_prefix(scorecard):
    cands = cands_by_id(scorecard)
    assert cands["cloud-connectors:B-05"].taxonomy == "B"
    assert cands["cloud-connectors:G-03"].taxonomy == "G"
    assert cands["cloud-connectors:A-06"].taxonomy == "A"
    assert cands["cloud-connectors:M-01"].taxonomy == "M"


def test_path_from_detail_section_evidence(scorecard):
    cands = cands_by_id(scorecard)
    assert cands["cloud-connectors:B-05"].path == \
        "core/cloud_connector_sweeps.py"
    assert cands["cloud-connectors:B-05"].line == "131"
    assert cands["cloud-connectors:B-07"].path == "connectors/azure.py"


def test_path_falls_back_to_scorecard(scorecard):
    cands = cands_by_id(scorecard)
    # G-03, A-06, M-01 have no detail sections
    assert cands["cloud-connectors:G-03"].path.endswith("cloud-connectors.md")
    assert cands["cloud-connectors:G-03"].line == "-"


def test_theme_is_slug_and_candidate_fields(scorecard):
    c = parse_scorecard(scorecard, slug="cloud-connectors",
                        run_id="r").candidates[0]
    assert c.theme_raw == "cloud-connectors"
    assert c.category == "product_gap"
    assert c.run_id == "r"
    assert "cloud-connectors.md#B-05" in c.references


def test_detail_headings_do_not_double_count(scorecard):
    # B-05 / B-07 appear in the table AND as `### B-05:` detail sections;
    # the table is authoritative and the headings must not duplicate them.
    result = parse_scorecard(scorecard, slug="cloud-connectors", run_id="r")
    ids = [c.blocker_id for c in result.candidates]
    assert len(ids) == len(set(ids))


# --------------------------------------------------------------- hard errors


def test_missing_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="scorecard"):
        parse_scorecard(tmp_path / "nope.md", slug="x", run_id="r")


def test_no_findings_structure_is_hard_error(tmp_path):
    p = tmp_path / "empty.md"
    p.write_text("# Scorecard\n\nNo table here.\n\n## Score: 9/10\n")
    with pytest.raises(RegisterError, match="findings table"):
        parse_scorecard(p, slug="x", run_id="r")


# --------------------------------------------- row problems instead of abort


def test_unknown_severity_is_problem_not_abort(tmp_path, scorecard):
    p = tmp_path / "bad.md"
    p.write_text(scorecard.read_text().replace("**Critical**", "Mega"))
    result = parse_scorecard(p, slug="x", run_id="r")
    ids = [c.blocker_id for c in result.candidates]
    assert "x:B-05" not in ids                       # bad row skipped
    assert "x:B-07" in ids and "x:M-01" in ids       # others survive
    assert any("B-05" in prob and "severity" in prob and "Mega" in prob
               for prob in result.problems)


def test_unparseable_id_in_findings_table_is_problem(tmp_path):
    p = tmp_path / "ids.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| ??? | High | Broken id row | OPEN |
| B-01 | High | Good row | OPEN |
""")
    result = parse_scorecard(p, slug="x", run_id="r")
    assert [c.blocker_id for c in result.candidates] == ["x:B-01"]
    assert any("???" in prob for prob in result.problems)


# ------------------------------------------------- real corpus format classes


def test_format_a_evidence_column(tmp_path):
    p = tmp_path / "api-keys.md"
    p.write_text("""\
| ID | Severity | Type | Finding | Status | Evidence |
|----|----------|------|---------|--------|----------|
| S-01 | High | Security | Webhook secret logged | OPEN | `core/webhooks.py:88` |
| S-02 | Low | Security | Verbose error body | Fixed — verified | `core/errors.py:12` |
""")
    result = parse_scorecard(p, slug="api-keys", run_id="r")
    assert result.problems == []
    assert len(result.candidates) == 1
    c = result.candidates[0]
    assert c.blocker_id == "api-keys:S-01"
    assert c.path == "core/webhooks.py"
    assert c.line == "88"


def test_format_b_sev_alias_and_column_order(tmp_path):
    p = tmp_path / "auditor-portal.md"
    p.write_text("""\
| ID | Sev | Status | Finding |
|----|-----|--------|---------|
| B-01 | High | OPEN (new) | Page-view trail dead on PG |
| B-02 | Med | Resolved | Principal-id collision |
""")
    result = parse_scorecard(p, slug="auditor-portal", run_id="r")
    assert result.problems == []
    assert [c.blocker_id for c in result.candidates] == ["auditor-portal:B-01"]
    assert result.candidates[0].severity == "P1"
    assert result.candidates[0].title == "Page-view trail dead on PG"


def test_format_c_no_status_column_closed_markers(tmp_path):
    p = tmp_path / "audit-workflow.md"
    p.write_text("""\
| ID | Sev | Type | One-line summary | Key citation |
|----|-----|------|------------------|--------------|
| B-01 | High | Bug | Allocator loop blocks event loop | `core/bulk.py:10` |
| B-02 | Med | Bug | Old defect `[FIXED]` 2026-06-09 | `core/bulk.py:99` |
| U-01 | Low-Med | UX | Dead-end flow on closure | `pages/Bulk.tsx:5` |
""")
    result = parse_scorecard(p, slug="audit-workflow", run_id="r")
    assert result.problems == []
    ids = [c.blocker_id for c in result.candidates]
    assert ids == ["audit-workflow:B-01", "audit-workflow:U-01"]
    by_id = {c.blocker_id: c for c in result.candidates}
    # severity grades Low-Med -> P2 (decision 4)
    assert by_id["audit-workflow:U-01"].severity == "P2"
    # path from the Key citation column
    assert by_id["audit-workflow:B-01"].path == "core/bulk.py"
    assert by_id["audit-workflow:B-01"].line == "10"


def test_no_status_table_prose_marker_words_stay_open(tmp_path):
    # Real corpus rows (audit-workflow B-10/S-01, audit-reporting B-03/M-02):
    # marker WORDS in prose must not close a row — only explicit markers do
    # (bracketed `[FIXED]`, standalone ALL-CAPS, or a cell starting with the
    # marker like `Resolved.`). A silently dropped open finding is data loss.
    p = tmp_path / "prose.md"
    p.write_text("""\
| ID | Sev | Type | One-line summary | Key citation |
|----|-----|------|------------------|--------------|
| B-10 | Low | Bug | Error banner never cleared on successful refetch | `pages/Queue.tsx:62` |
| S-01 | Med | Security | RLS untested despite "Done (2026-06-10)" claim | `tests/test_pg.py:1` |
| M-02 | Low | Competitive | No custom report builder — fixed sections per type | `docs/x.md:1` |
| B-03 | Med | Bug | Counts `implemented` MAPs as overdue (excludes only `closed`) | `core/maps.py:9` |
| U-04 | Med | UX | Resolved.** The 409 dead-end is gone; superseded by direct sync | `pages/Sync.tsx:2` |
| U-05 | Med | UX | Stale banner | RESOLVED (2026-06-08) |
""")
    result = parse_scorecard(p, slug="x", run_id="r")
    assert result.problems == []
    ids = [c.blocker_id for c in result.candidates]
    assert ids == ["x:B-10", "x:S-01", "x:M-02", "x:B-03"]


def test_heading_tail_prose_marker_words_stay_open(tmp_path):
    # `— package half fixed` (prose-case) and `— PARTIALLY RESOLVED` must
    # not close; `— RESOLVED` / `— [FIXED]` (explicit) must.
    p = tmp_path / "tails.md"
    p.write_text("""\
## Findings

### G-01: Evidence export — package half fixed

**Severity:** Med

### U-02: Roster sync — PARTIALLY RESOLVED (training-assignment-roster)

**Severity:** Low

### B-01: Old defect — RESOLVED

Body prose.

### B-02: Other defect — `[FIXED]` 2026-06-08

Body prose.
""")
    result = parse_scorecard(p, slug="t", run_id="r")
    assert result.problems == []
    assert [c.blocker_id for c in result.candidates] == ["t:G-01", "t:U-02"]


def test_compound_severity_grades(tmp_path):
    p = tmp_path / "grades.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| B-01 | Low-Med | one | OPEN |
| B-02 | Med-Low | two | OPEN |
| B-03 | Med-High | three | OPEN |
| B-04 | High-Med | four | OPEN |
""")
    result = parse_scorecard(p, slug="g", run_id="r")
    assert result.problems == []
    sevs = [c.severity for c in result.candidates]
    assert sevs == ["P2", "P2", "P1", "P1"]


def test_format_e_decorated_ids(tmp_path):
    p = tmp_path / "decorated.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| U-05 (new) | Low | Trailing parenthetical | OPEN |
| B-01b | High | Lowercase suffix | OPEN |
| B-02/A-01 | Med | Compound id | OPEN |
""")
    result = parse_scorecard(p, slug="d", run_id="r")
    assert result.problems == []
    assert [c.blocker_id for c in result.candidates] == \
        ["d:U-05", "d:B-01b", "d:B-02"]
    assert result.candidates[1].taxonomy == "B"


def test_unknown_taxonomy_prefix_maps_to_gap(tmp_path):
    p = tmp_path / "tax.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| D-01 | Low | Docs drift | OPEN |
| C-02 | Med | Coverage gap | OPEN |
""")
    result = parse_scorecard(p, slug="t", run_id="r")
    assert [c.taxonomy for c in result.candidates] == ["G", "G"]


def test_severity_less_status_table_open_row_is_problem(tmp_path):
    # `| ID | Finding | Status |` tables (scim.md, event-subscriptions.md)
    # carry no severity. Closed rows are skipped; an open row cannot become
    # a candidate but must be reported loudly, never dropped in silence.
    p = tmp_path / "scim.md"
    p.write_text("""\
| ID | Finding | Status |
|----|---------|--------|
| S-01 | Old leak, since fixed | **[FIXED]** |
| S-02 | New leak | OPEN |
""")
    result = parse_scorecard(p, slug="scim", run_id="r")
    assert result.candidates == []
    assert any("S-02" in prob and "severity" in prob.lower()
               for prob in result.problems)


def test_multiple_findings_tables_all_parsed(tmp_path):
    # cloud-connectors.md has a second `| ID | Severity | Issue |` table.
    p = tmp_path / "two-tables.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| B-01 | High | Bug one | OPEN |

## UX Issues

| ID | Severity | Issue |
|----|----------|-------|
| U-01 | Low | Dead-end flow |
""")
    result = parse_scorecard(p, slug="x", run_id="r")
    assert [c.blocker_id for c in result.candidates] == ["x:B-01", "x:U-01"]


# ------------------------------------------------------ heading-only format


HEADING_SCORECARD = """\
# Tasks Scorecard

## Score: 9/10

## Bugs (`B-XX`)

### B-01: `list_tasks` has no tags filter

**Severity:** Low
**Type:** Bug

**Evidence**
- `routers/tasks.py:162` — list endpoint filters.

### B-02: Notifications double-fire on rollback

**Severity:** ~~High~~ → **FIXED** (2026-06-10)
**Type:** Bug

### B-03 (High): Sync runs serially — FIXED (2026-06-09)

Body prose.

## Security Issues (`S-XX`)

### S-01: PG/RLS test lane is a fraction of what "Done" claimed

**Severity:** Med — still open.

### S-02 (Cleared — verified secure): Privilege escalation tenant-admin path

Documented here as a verified-secure finding, not a vulnerability.

### S-03: 404-vs-403 behavior is correct (verified, not a finding — recorded for completeness)

Cross-tenant access returns 404. No issue.

### S-04: (Verified clean) Tenant isolation enforced — no exploitable gap found

**Severity:** Informational (no finding)

## Findings

### G-01: No frontend whatsoever ✅ FIXED

Body prose.

### G-02: Docs page missing for half the connectors

**Severity:** Med — partially fixed.

### A-01 / Scale: Retry drain is single-leader

**Severity:** High · **Type:** Autonomy Gap / Scale

**Evidence**
- `core/event_bridge.py:807` — drain loop.

### U-01: Section with no severity marker at all

Prose only, no severity line.
"""


@pytest.fixture
def heading_scorecard(tmp_path):
    p = tmp_path / "tasks.md"
    p.write_text(HEADING_SCORECARD)
    return p


def test_heading_findings_parsed(heading_scorecard):
    result = parse_scorecard(heading_scorecard, slug="tasks", run_id="r")
    ids = [c.blocker_id for c in result.candidates]
    assert ids == ["tasks:B-01", "tasks:S-01", "tasks:G-02", "tasks:A-01"]


def test_heading_severities_and_evidence(heading_scorecard):
    cands = cands_by_id(heading_scorecard, slug="tasks")
    assert cands["tasks:B-01"].severity == "P3"
    assert cands["tasks:B-01"].path == "routers/tasks.py"
    assert cands["tasks:B-01"].line == "162"
    assert cands["tasks:S-01"].severity == "P2"
    assert cands["tasks:A-01"].severity == "P1"
    assert cands["tasks:A-01"].path == "core/event_bridge.py"


def test_heading_closed_variants_excluded(heading_scorecard):
    ids = set(cands_by_id(heading_scorecard, slug="tasks"))
    assert "tasks:B-02" not in ids   # severity line struck through -> FIXED
    assert "tasks:B-03" not in ids   # `— FIXED (date)` heading tail
    assert "tasks:G-01" not in ids   # `✅ FIXED` heading tail


def test_heading_non_findings_excluded_silently(heading_scorecard):
    result = parse_scorecard(heading_scorecard, slug="tasks", run_id="r")
    ids = {c.blocker_id for c in result.candidates}
    assert "tasks:S-02" not in ids   # (Cleared — verified secure)
    assert "tasks:S-03" not in ids   # "not a finding"
    assert "tasks:S-04" not in ids   # Severity: Informational (no finding)
    assert not any("S-02" in prob or "S-03" in prob or "S-04" in prob
                   for prob in result.problems)


def test_heading_marker_words_in_title_do_not_close(heading_scorecard):
    # S-01's title quotes the word "Done"; G-02 is "partially fixed".
    # Neither may be silently closed — a dropped open finding is silent loss.
    ids = set(cands_by_id(heading_scorecard, slug="tasks"))
    assert "tasks:S-01" in ids
    assert "tasks:G-02" in ids


def test_heading_compound_id_takes_first_segment(heading_scorecard):
    cands = cands_by_id(heading_scorecard, slug="tasks")
    assert "tasks:A-01" in cands     # from `### A-01 / Scale: ...`


def test_heading_without_severity_is_problem(heading_scorecard):
    result = parse_scorecard(heading_scorecard, slug="tasks", run_id="r")
    assert not any(c.blocker_id == "tasks:U-01" for c in result.candidates)
    assert any("U-01" in prob and "severity" in prob.lower()
               for prob in result.problems)


def test_heading_inline_severity(tmp_path):
    p = tmp_path / "policies.md"
    p.write_text("""\
## Findings

### S-01 (HIGH): No separation of duties on policy approval

Body prose.
""")
    result = parse_scorecard(p, slug="policies", run_id="r")
    assert result.problems == []
    assert len(result.candidates) == 1
    assert result.candidates[0].severity == "P1"
    assert result.candidates[0].title == \
        "No separation of duties on policy approval"


def test_table_plus_extra_heading_findings(tmp_path):
    # A findings table plus a heading finding whose ID is NOT in the table:
    # the heading finding must still be captured.
    p = tmp_path / "mixed.md"
    p.write_text("""\
| ID | Severity | Title | Status |
|----|----------|-------|--------|
| B-01 | High | Table finding | OPEN |

### B-01: Table finding

**Evidence**
- `core/a.py:1` — broken.

### U-09: Heading-only finding

**Severity:** Low
""")
    result = parse_scorecard(p, slug="m", run_id="r")
    assert [c.blocker_id for c in result.candidates] == ["m:B-01", "m:U-09"]
    by_id = {c.blocker_id: c for c in result.candidates}
    assert by_id["m:B-01"].path == "core/a.py"   # detail section evidence


def test_all_closed_headings_is_not_an_error(tmp_path):
    # A 10/10 scorecard whose only findings are FIXED yields zero candidates
    # without raising: findings structure exists, it is just all closed.
    p = tmp_path / "narratives.md"
    p.write_text("""\
## Security Findings

### S-04: No entitlement boundary tests — FIXED 2026-06-09

Body prose.
""")
    result = parse_scorecard(p, slug="n", run_id="r")
    assert result.candidates == []
    assert result.problems == []


# ----------------------------------------------------- real-corpus integration


@pytest.mark.skipif(not CORPUS_DIR.exists(),
                    reason="Meridian scorecard corpus not present")
def test_real_corpus_parses_end_to_end():
    valid_taxonomy = {"B", "S", "G", "A", "U", "M"}
    total = 0
    all_problems: list[str] = []
    for path in sorted(CORPUS_DIR.glob("*.md")):
        result = parse_scorecard(path, slug=path.stem, run_id="corpus")
        print(f"{path.name}: {len(result.candidates)} candidates, "
              f"{len(result.problems)} problems")
        total += len(result.candidates)
        all_problems.extend(result.problems)
        for c in result.candidates:
            assert c.severity in {"P0", "P1", "P2", "P3"}
            assert c.taxonomy in valid_taxonomy
            assert c.blocker_id.startswith(f"{path.stem}:")
    print(f"TOTAL: {total} candidates, {len(all_problems)} problems")
    for prob in all_problems:
        print(f"  problem: {prob}")
    assert total >= 100
    assert all_problems == []
