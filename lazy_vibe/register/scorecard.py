"""Feature-review scorecard markdown -> reconcile candidates (spec §10).

Scorecards are the post-build review artifact in product repos
(docs/scorecards/<slug>.md). The findings table is parsed by header name
(column order varies between scorecards); only rows whose status contains
the word "open" are ingested. The finding's stable identity is
(category=product_gap, theme=<feature slug>, path=<first evidence ref or
the scorecard file>, symbol=<scorecard finding id>), so re-ingesting the
same scorecard is idempotent through the reconciler.
"""
from __future__ import annotations

import re
from pathlib import Path

from .ingest import Candidate
from .model import RegisterError

_SEVERITY_MAP = {"critical": "P0", "high": "P1", "med": "P2",
                 "medium": "P2", "low": "P3"}
_ID_RE = re.compile(r"^[A-Z][A-Z-]*-?\d+$")
_TAXONOMY_RE = re.compile(r"([A-Z])-?\d+$")
_EVIDENCE_RE = re.compile(
    r"`([\w./-]+\.(?:py|ts|tsx|js|jsx|go|rs|java|rb|sh|sql|yaml|yml|md|json))"
    r"(?::(\d+))?")
_REQUIRED_COLUMNS = {"id", "severity", "status"}


def _clean_cell(cell: str) -> str:
    return cell.strip().strip("*").strip("`").strip()


def _split_row(line: str) -> list[str]:
    return [_clean_cell(c) for c in line.strip().strip("|").split("|")]


def _find_table(lines: list[str], path: Path) -> tuple[dict[str, int], int]:
    """Return ({column_name: index}, first_data_line_index)."""
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("|"):
            continue
        header = [c.lower() for c in _split_row(line)]
        if _REQUIRED_COLUMNS.issubset(set(header)) and \
                ("title" in header or "summary" in header):
            return {name: idx for idx, name in enumerate(header)}, i + 2
    raise RegisterError(f"{path}: no findings table found (need columns "
                        f"id/severity/status plus title or summary)")


def _detail_evidence(text: str, finding_id: str) -> tuple[str, str] | None:
    """First backticked path[:line] ref in the finding's `### <ID>:` section."""
    pattern = re.compile(rf"^###\s+\**{re.escape(finding_id)}\**[:\s]",
                         re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return None
    section_end = text.find("\n### ", match.end())
    section = text[match.end():section_end if section_end != -1 else None]
    ref = _EVIDENCE_RE.search(section)
    if not ref:
        return None
    return ref.group(1), ref.group(2) or "-"


def parse_scorecard(path: Path, *, slug: str, run_id: str) -> list[Candidate]:
    if not path.exists():
        raise RegisterError(f"scorecard not found: {path}")
    text = path.read_text()
    lines = text.splitlines()
    columns, data_start = _find_table(lines, path)
    title_col = columns.get("title", columns.get("summary"))
    candidates: list[Candidate] = []
    for line in lines[data_start:]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            break
        cells = _split_row(stripped)
        if len(cells) <= max(columns.values()):
            continue
        finding_id = cells[columns["id"]]
        if not _ID_RE.fullmatch(finding_id):
            continue
        status = cells[columns["status"]].lower()
        if "open" not in status:
            continue
        severity_raw = cells[columns["severity"]].lower()
        severity = _SEVERITY_MAP.get(severity_raw)
        if severity is None:
            raise RegisterError(
                f"{path}: finding {finding_id}: unknown severity "
                f"{cells[columns['severity']]!r}")
        taxonomy_match = _TAXONOMY_RE.search(finding_id.replace("-", ""))
        taxonomy = taxonomy_match.group(1) if taxonomy_match else "G"
        evidence = _detail_evidence(text, finding_id)
        if evidence is not None:
            ev_path, ev_line = evidence
        else:
            ev_path, ev_line = str(path), "-"
        candidates.append(Candidate(
            blocker_id=f"{slug}:{finding_id}",
            category="product_gap",
            theme_raw=slug,
            severity=severity,
            path=ev_path,
            line=ev_line,
            title=cells[title_col],
            references=f"{path}#{finding_id}",
            run_id=run_id,
            taxonomy=taxonomy,
        ))
    return candidates
