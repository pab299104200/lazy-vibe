"""Blocker-ledger TSV -> reconcile candidates (spec §5, §11).

``parse_ledger`` is the untrusted-harness boundary; ``read_candidates`` reads
a regenerable intermediate but enforces the same invariants.
"""
from __future__ import annotations

import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path

from .model import SEVERITY_ORDER, RegisterError

EXPECTED_HEADER = ["blocker_id", "category", "theme", "severity", "group",
                   "model_class", "finding_count", "representative_source",
                   "representative_line", "representative_title",
                   "raw_px_ids", "references"]


@dataclass(frozen=True)
class Candidate:
    blocker_id: str
    category: str
    theme_raw: str
    severity: str
    path: str
    line: str
    title: str
    references: str
    run_id: str
    taxonomy: str = "G"


def _validate_severity(value: str, where: str) -> None:
    if value not in SEVERITY_ORDER:
        raise RegisterError(f"{where}: invalid severity {value!r}")


def parse_ledger(path: Path, *, run_id: str) -> list[Candidate]:
    if not path.exists():
        raise RegisterError(f"blocker ledger not found: {path}")
    with path.open(newline="") as fh:
        # QUOTE_NONE: the ledger is awk-generated plain TSV, not RFC 4180 —
        # a literal leading '"' in a field must not trigger quote parsing.
        reader = csv.reader(fh, delimiter="\t", quoting=csv.QUOTE_NONE)
        try:
            header = next(reader)
        except StopIteration:
            raise RegisterError(f"{path}: empty ledger") from None
        if header != EXPECTED_HEADER:
            raise RegisterError(
                f"{path}: unexpected ledger header {header!r}; "
                f"expected {EXPECTED_HEADER!r}")
        candidates = []
        for lineno, row in enumerate(reader, start=2):
            if not row or not any(field.strip() for field in row):
                continue
            if len(row) != len(EXPECTED_HEADER):
                raise RegisterError(f"{path}: line {lineno}: expected "
                                    f"{len(EXPECTED_HEADER)} columns, got {len(row)}")
            record = dict(zip(EXPECTED_HEADER, row))
            _validate_severity(record["severity"], f"{path}: line {lineno}")
            candidates.append(Candidate(
                blocker_id=record["blocker_id"],
                category=record["category"],
                theme_raw=record["theme"],
                severity=record["severity"],
                path=record["representative_source"],
                line=record["representative_line"],
                title=record["representative_title"],
                references=record["references"],
                run_id=run_id,
            ))
    return candidates


def write_candidates(candidates: list[Candidate], out_path: Path, *,
                     run_id: str) -> None:
    """Idempotently overwrite a derived artifact (intentional asymmetry
    with RegisterStore.save, which guards the durable register)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"run_id": run_id, "candidates": [asdict(c) for c in candidates]}
    out_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def read_candidates(path: Path) -> list[Candidate]:
    if not path.exists():
        raise RegisterError(f"candidates file not found: {path}")
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise RegisterError(f"{path}: corrupt candidates file: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("candidates"), list):
        raise RegisterError(f"{path}: expected a 'candidates' list")
    run_id = data.get("run_id")
    candidates = []
    for index, entry in enumerate(data["candidates"]):
        try:
            candidate = Candidate(**entry)
        except TypeError as exc:
            raise RegisterError(
                f"{path}: candidate {index}: {exc}") from exc
        _validate_severity(candidate.severity, f"{path}: candidate {index}")
        if run_id is not None and candidate.run_id != run_id:
            raise RegisterError(
                f"{path}: candidate {index}: run_id {candidate.run_id!r} "
                f"disagrees with file run_id {run_id!r}")
        candidates.append(candidate)
    return candidates
