"""Feature-review scorecard markdown -> reconcile candidates (spec §10).

Scorecards are the post-build review artifact in product repos
(docs/scorecards/<slug>.md). The corpus uses two layouts, both supported:

1. **Findings tables** — parsed by header name (column order varies):
   an ``id`` column, a severity column (``severity``/``sev``) and a
   title-like column (``title``/``summary``/``finding``/``issue``/
   ``one-line summary``/``item``). A ``status`` column is optional: when
   present a row is open iff its status contains "open"; when absent a row
   is open unless a cell carries an EXPLICIT closed marker — bracketed
   ``[FIXED]``, standalone ALL-CAPS (``RESOLVED``), or a cell starting
   with the marker (``Resolved.``). Marker words mid-prose ("never
   cleared", '"Done" claim') do not close: in the real corpus those are
   bug descriptions. Tables with a status column but no severity column
   are also scanned: closed rows are skipped, open rows are reported as
   problems (never dropped silently).
2. **Finding headings** — ``### <ID>: <title>`` or ``### <ID> — <title>``
   sections (used by ~70% of real scorecards, which have no findings
   table). Severity comes from an inline ``(High)`` in the heading or a
   ``**Severity:** <grade>`` body line. A heading finding is closed when
   an explicit closed marker follows a ``—``/``✅`` separator in the
   heading (``— FIXED``, ``— RESOLVED``; prose-case tails like "— package
   half fixed" stay open), when the ID carries a closure parenthetical or
   bracket tag (``(Cleared ...)``, ``[FIXED]`` — while ``[NEW]`` stays
   open), or when a body Status/Severity/Resolution line carries a closed
   marker without an open/partial counter-signal (``~~High~~ → FIXED``
   and ``**Resolution (date):** fixed ...`` are closed, ``Med — partially
   fixed`` is open). Headings whose ID already appeared in a table are
   detail sections, not new findings.

Verified-clean non-findings (severity ``Informational`` or "not a
finding"/"no finding" in the heading) are excluded by design. Row-level
defects (unknown severity, unparseable ID, open row without severity)
surface in ``ScorecardParse.problems`` — actionable and file-specific —
while the rest of the file still parses. Only whole-file conditions
(missing file, no findings structure at all) raise ``RegisterError``.

A finding's stable identity is (category=product_gap, theme=<feature
slug>, path=<first evidence ref or the scorecard file>, symbol=<finding
id>), so re-ingesting the same scorecard is idempotent through the
reconciler. Open/closed resolution deliberately over-includes: triage
verification catches a stale-open, but a silently dropped open finding is
unrecoverable loss.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .ingest import Candidate
from .model import (  # single source of truth for taxonomy/severity codes
    SEVERITY_ORDER,
    _SIMPLE_TAXONOMY,
    RegisterError,
)

_SEVERITY_MAP = {
    "critical": "P0", "high": "P1", "med": "P2", "medium": "P2", "low": "P3",
    "low-med": "P2", "med-low": "P2", "med-high": "P1", "high-med": "P1",
}
_NON_FINDING_SEVERITIES = {"informational"}
_SEV_COLUMNS = ("severity", "sev")
_TITLE_COLUMNS = ("title", "summary", "finding", "issue",
                  "one-line summary", "item")
_EVIDENCE_COLUMNS = ("location", "key citation", "citation")
_ID_RE = re.compile(r"^[A-Z][A-Z-]*-?\d+[a-z]?$")
_TAXONOMY_RE = re.compile(r"([A-Z])\d+[a-z]?$")
# Extensions longest-first (tsx before ts, json/jsx before js) plus a
# trailing guard — otherwise `Foo.tsx:123` matches as `Foo.ts` and the
# line ref is dropped, corrupting fingerprint identity.
_PATH_PATTERN = (
    r"([\w./-]+\.(?:py|tsx|ts|json|jsx|js|go|rs|java|rb|sh|sql|yaml|yml|md))"
    r"(?!\w)(?::(\d+))?")
_EVIDENCE_RE = re.compile("`" + _PATH_PATTERN)
_BARE_PATH_RE = re.compile(_PATH_PATTERN)
_MARKER_WORDS = "fixed|resolved|superseded|closed|done|wontfix|cleared"
_CLOSED_RE = re.compile(rf"\b(?:{_MARKER_WORDS})\b", re.I)
# Explicit closure: bracketed (any case) or standalone ALL-CAPS. Prose-case
# marker words ("never cleared", '"Done" claim', "fixed sections") are bug
# descriptions in the real corpus, not statuses — matching them silently
# drops open findings.
_EXPLICIT_CLOSED_RE = re.compile(
    rf"(?i:\[[^\]]*(?:{_MARKER_WORDS})[^\]]*\])"
    rf"|\b(?:{_MARKER_WORDS.upper()})\b")
_CELL_START_CLOSED_RE = re.compile(rf"^(?:{_MARKER_WORDS})\b", re.I)
# `\bopen\b` not `\bopen` — "api.openai.com" is not an open signal.
_OPENISH_RE = re.compile(r"\bopen\b|\bpartial", re.I)
_NON_FINDING_RE = re.compile(r"\b(?:not a finding|no finding)\b", re.I)
_HEADING_RE = re.compile(r"^(#{2,4})\s+(.*\S)\s*$")
_STATUS_LINE_RE = re.compile(r"^[*~\s]*(?:status|severity|resolution)\b", re.I)
# A Status/Resolution line whose FIRST token after the label is a closed
# marker is a closure even if later prose says "A-01 remains open" — the
# "open" refers to a different finding (real corpus pattern).
_LEADING_CLOSED_RE = re.compile(
    rf"^[*~\s]*(?:status|resolution)\b(?:\s*\([^)]*\))?[^A-Za-z0-9]*"
    rf"(?:{_MARKER_WORDS})\b", re.I)
_SEVERITY_TOKEN_RE = re.compile(
    r"severity\b[^A-Za-z0-9]*([A-Za-z][A-Za-z0-9-]*)", re.I)
_TAIL_SPLIT_RE = re.compile(r"—|✅")
_PARENTHETICAL_RE = re.compile(r"\(([^)]*)\)")
_BRACKET_TAG_RE = re.compile(r"\[([^\]]*)\]")


@dataclass
class ScorecardParse:
    candidates: list[Candidate]
    problems: list[str]   # actionable, file+row specific


@dataclass(frozen=True)
class _Table:
    id_col: int
    sev_col: int | None
    title_col: int
    status_col: int | None
    evidence_col: int | None
    data_start: int

    @property
    def max_col(self) -> int:
        cols = [self.id_col, self.sev_col, self.title_col, self.status_col]
        return max(c for c in cols if c is not None)


def _clean_cell(cell: str) -> str:
    return cell.strip().strip("*").strip("`").strip()


def _split_row(line: str) -> list[str]:
    return [_clean_cell(c) for c in line.strip().strip("|").split("|")]


def _clean_id(raw: str) -> str:
    """`U-05 (new)` -> U-05; `B-02 [FIXED]` -> B-02; `B-02/A-01` -> B-02."""
    raw = _PARENTHETICAL_RE.sub("", _clean_cell(raw))
    raw = _BRACKET_TAG_RE.sub("", raw).strip()
    return raw.split("/")[0].strip()


def _taxonomy(finding_id: str) -> str:
    match = _TAXONOMY_RE.search(finding_id.replace("-", ""))
    letter = match.group(1) if match else "G"
    return letter if letter in _SIMPLE_TAXONOMY else "G"


def _grade(token: str) -> str | None:
    token = token.strip().lower()
    if token in _SEVERITY_MAP:
        return _SEVERITY_MAP[token]
    if token.upper() in SEVERITY_ORDER:
        return token.upper()
    return None


def _cell_is_closed(cell: str) -> bool:
    """Closure in a status-less table cell: explicit marker or a cell that
    STARTS with one (`Resolved.** ...`), never marker words mid-prose."""
    if _OPENISH_RE.search(cell):
        return False   # "PARTIALLY RESOLVED", "Partially fixed; open"
    return bool(_EXPLICIT_CLOSED_RE.search(cell)
                or _CELL_START_CLOSED_RE.match(cell))


def _find_tables(lines: list[str]) -> list[_Table]:
    """All findings/status tables. Feature-gap tables (no severity AND no
    status column) are inventory views, not findings sources — ignored."""
    tables = []
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("|"):
            continue
        header = [c.lower() for c in _split_row(line)]
        if "id" not in header:
            continue
        index = {name: idx for idx, name in enumerate(header)}
        sev_col = next((index[c] for c in _SEV_COLUMNS if c in index), None)
        title_col = next((index[c] for c in _TITLE_COLUMNS if c in index),
                         None)
        status_col = index.get("status")
        if title_col is None or (sev_col is None and status_col is None):
            continue
        evidence_col = next(
            (idx for name, idx in index.items()
             if name in _EVIDENCE_COLUMNS or name.startswith("evidence")),
            None)
        tables.append(_Table(id_col=index["id"], sev_col=sev_col,
                             title_col=title_col, status_col=status_col,
                             evidence_col=evidence_col, data_start=i + 2))
    return tables


def _detail_evidence(text: str, finding_id: str) -> tuple[str, str] | None:
    """First backticked path[:line] ref in the finding's `### <ID>:` section."""
    pattern = re.compile(rf"^#{{2,4}}\s+\**{re.escape(finding_id)}\**[:\s]",
                         re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return None
    section_end = text.find("\n#", match.end())
    section = text[match.end():section_end if section_end != -1 else None]
    ref = _EVIDENCE_RE.search(section)
    if not ref:
        return None
    return ref.group(1), ref.group(2) or "-"


def _row_evidence(text: str, finding_id: str, table: _Table,
                  cells: list[str], path: Path) -> tuple[str, str]:
    detail = _detail_evidence(text, finding_id)
    if detail is not None:
        return detail
    if table.evidence_col is not None and len(cells) > table.evidence_col:
        ref = _BARE_PATH_RE.search(cells[table.evidence_col])
        if ref:
            return ref.group(1), ref.group(2) or "-"
    return str(path), "-"


def _make_candidate(finding_id: str, severity: str, title: str,
                    ev: tuple[str, str], *, path: Path, slug: str,
                    run_id: str) -> Candidate:
    return Candidate(
        blocker_id=f"{slug}:{finding_id}", category="product_gap",
        theme_raw=slug, severity=severity, path=ev[0], line=ev[1],
        title=title, references=f"{path}#{finding_id}", run_id=run_id,
        taxonomy=_taxonomy(finding_id), symbol=finding_id)


def _parse_table(lines: list[str], table: _Table, text: str, path: Path,
                 slug: str, run_id: str, result: ScorecardParse,
                 seen: set[str]) -> None:
    for line in lines[table.data_start:]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            break
        cells = _split_row(stripped)
        if len(cells) <= table.max_col:
            result.problems.append(
                f"{path.name}: malformed table row {stripped[:60]!r}")
            continue
        finding_id = _clean_id(cells[table.id_col])
        if not _ID_RE.fullmatch(finding_id):
            result.problems.append(
                f"{path.name}: unparseable finding id "
                f"{cells[table.id_col]!r} in findings table")
            continue
        seen.add(finding_id)
        if table.status_col is not None:
            is_open = "open" in cells[table.status_col].lower()
        else:
            is_open = not any(_cell_is_closed(c) for c in cells)
        if not is_open:
            continue
        if table.sev_col is None:
            result.problems.append(
                f"{path.name} {finding_id}: open finding in a severity-less "
                f"table — add a Severity column or move it to a findings "
                f"table")
            continue
        raw_severity = cells[table.sev_col]
        if raw_severity.lower() in _NON_FINDING_SEVERITIES:
            continue   # verified-clean note recorded for completeness
        severity = _grade(raw_severity)
        if severity is None:
            result.problems.append(
                f"{path.name} {finding_id}: unknown severity "
                f"{raw_severity!r}")
            continue
        ev = _row_evidence(text, finding_id, table, cells, path)
        result.candidates.append(_make_candidate(
            finding_id, severity, cells[table.title_col], ev,
            path=path, slug=slug, run_id=run_id))


def _split_heading(text: str) -> tuple[str, str] | None:
    """(id_part, title) split on `:` or ` — `; None if no finding ID."""
    for sep in (":", " — "):
        head, found, tail = text.partition(sep)
        if found and _ID_RE.fullmatch(_clean_id(head)):
            return head, tail.strip()
    if _ID_RE.fullmatch(_clean_id(text)):
        return text, text.strip()   # bare `### B-01` heading
    return None


def _iter_finding_headings(lines: list[str]):
    """Yield (finding_id, id_part, heading, title, body) for `## <ID>: ...`
    and `## <ID> — ...` headings."""
    matches = [(i, len(m.group(1)), m.group(2))
               for i, m in ((i, _HEADING_RE.match(line))
                            for i, line in enumerate(lines)) if m]
    for n, (i, level, text) in enumerate(matches):
        parts = _split_heading(text)
        if parts is None:
            continue
        id_part, title = parts
        end = next((j for j, lvl, _ in matches[n + 1:] if lvl <= level),
                   len(lines))
        yield (_clean_id(id_part), id_part, text, title,
               "\n".join(lines[i + 1:end]))


def _heading_is_closed(id_part: str, heading: str, body: str) -> bool:
    paren = _PARENTHETICAL_RE.search(id_part)
    if paren and _grade(paren.group(1)) is None \
            and _CLOSED_RE.search(paren.group(1)):
        return True   # e.g. `### S-02 (Cleared — verified secure): ...`
    bracket = _BRACKET_TAG_RE.search(id_part)
    if bracket and _CLOSED_RE.search(bracket.group(1)):
        return True   # `### B-02 [FIXED]: ...` (while `[NEW]` stays open)
    tail = _TAIL_SPLIT_RE.split(heading)
    if len(tail) > 1 and _EXPLICIT_CLOSED_RE.search(tail[-1]) \
            and not _OPENISH_RE.search(tail[-1]):
        return True   # `... — FIXED (2026-06-09)` / `... ✅ FIXED`
    status_lines = [line for line in body.splitlines()
                    if _STATUS_LINE_RE.match(line)]
    if any(_LEADING_CLOSED_RE.match(line) for line in status_lines):
        return True   # `Status: FIXED — A-01 remains open` is a closure
    if any(_OPENISH_RE.search(line) for line in status_lines):
        return False  # "still open" / "partially fixed" wins over markers
    return any(_CLOSED_RE.search(line) for line in status_lines)


def _heading_severity(id_part: str,
                      body: str) -> tuple[str | None, str | None]:
    """(grade, raw_token) — inline `(High)` first, then a Severity line."""
    paren = _PARENTHETICAL_RE.search(id_part)
    if paren and _grade(paren.group(1)) is not None:
        return _grade(paren.group(1)), paren.group(1)
    for line in body.splitlines():
        if not re.match(r"^[*~\s]*severity\b", line, re.I):
            continue
        token = _SEVERITY_TOKEN_RE.search(line)
        if token:
            return _grade(token.group(1)), token.group(1)
        return None, None
    return None, None


def _parse_headings(lines: list[str], path: Path, slug: str, run_id: str,
                    result: ScorecardParse, seen: set[str]) -> bool:
    found = False
    for finding_id, id_part, heading, title, body in \
            _iter_finding_headings(lines):
        found = True
        if finding_id in seen:
            continue   # detail section of a table finding, or duplicate
        seen.add(finding_id)
        if _NON_FINDING_RE.search(heading):
            continue   # verified-clean entry recorded for completeness
        if _heading_is_closed(id_part, heading, body):
            continue
        severity, raw = _heading_severity(id_part, body)
        if severity is None:
            if raw is not None and raw.lower() in _NON_FINDING_SEVERITIES:
                continue   # Severity: Informational (no finding)
            result.problems.append(
                f"{path.name} {finding_id}: open finding has "
                + (f"unknown severity {raw!r}" if raw is not None
                   else "no parsable severity"))
            continue
        ref = _EVIDENCE_RE.search(body)
        ev = (ref.group(1), ref.group(2) or "-") if ref else (str(path), "-")
        result.candidates.append(_make_candidate(
            finding_id, severity, title, ev,
            path=path, slug=slug, run_id=run_id))
    return found


def parse_scorecard(path: Path, *, slug: str, run_id: str) -> ScorecardParse:
    if not path.exists():
        raise RegisterError(f"scorecard not found: {path}")
    text = path.read_text()
    lines = text.splitlines()
    result = ScorecardParse(candidates=[], problems=[])
    tables = _find_tables(lines)
    seen: set[str] = set()
    for table in tables:
        _parse_table(lines, table, text, path, slug, run_id, result, seen)
    found_headings = _parse_headings(lines, path, slug, run_id, result, seen)
    if not tables and not found_headings:
        raise RegisterError(
            f"{path}: no findings table or finding headings found (need a "
            f"table with id + severity/status + title-like columns, or "
            f"'### <ID>: <title>' sections)")
    return result
