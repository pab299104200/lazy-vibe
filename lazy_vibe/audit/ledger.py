"""Audit run artifacts -> blocker ledger TSV.

The register ingest path already trusts the remediation blocker-ledger schema.
This module gives `run-audit.sh` the same deterministic ledger contract without
waiting for `run-remediation.sh` to scrape the audit output first.
"""
from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path

PASS_RESULTS = {"PASS", "completed"}
SEVERITY_RE = re.compile(r"\bP[0-3]\b", re.IGNORECASE)
HEADING_RE = re.compile(r"^\s*(?:#{1,6}|\d+[.)]|[-*])\s+(.+?)\s*$")
WORD_RE = re.compile(r"[^a-z0-9]+")


@dataclass(frozen=True)
class SummaryRow:
    job_id: str
    kind: str
    result: str
    group: str
    title: str
    output: Path | None
    log_path: Path
    remediation_context: str


@dataclass(frozen=True)
class FindingRow:
    severity: str
    category: str
    theme: str
    group: str
    model_class: str
    source: str
    line: str
    title: str
    raw_id: str
    references: str


def _args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate audit blocker ledger.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--summary-file", required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def _read_summary(path: Path) -> list[SummaryRow]:
    if not path.exists():
        return []
    rows: list[SummaryRow] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for record in reader:
            output = record.get("output") or ""
            rows.append(SummaryRow(
                job_id=record.get("job_id", ""),
                kind=record.get("kind", ""),
                result=record.get("result", ""),
                group=record.get("group", ""),
                title=record.get("title", ""),
                output=Path(output) if output else None,
                log_path=Path(record.get("log_path", "")),
                remediation_context=record.get("remediation_context", ""),
            ))
    return rows


def _rel(path: Path, run_dir: Path) -> str:
    try:
        return str(path.resolve().relative_to(run_dir.resolve()))
    except ValueError:
        return str(path)


def _source_path(row: SummaryRow, run_dir: Path) -> Path:
    if row.output and row.output.exists():
        return row.output
    return row.log_path


def _source_text(path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8", errors="replace")
    return ""


def _severity(text: str, result: str) -> str:
    match = SEVERITY_RE.search(text)
    if match:
        return match.group(0).upper()
    if result == "FAIL":
        return "P1"
    if result == "INCOMPLETE":
        return "P2"
    return "P2"


def _heading(text: str, fallback: str) -> tuple[str, str]:
    for lineno, line in enumerate(text.splitlines(), start=1):
        if "RESULT:" in line:
            continue
        match = HEADING_RE.match(line)
        if match and SEVERITY_RE.search(line):
            return str(lineno), _clean_title(match.group(1))
        if SEVERITY_RE.search(line) and len(line.strip()) > 8:
            return str(lineno), _clean_title(line)
    return "-", _clean_title(fallback)


def _clean_title(value: str) -> str:
    value = re.sub(r"^[`*_ \t-]+|[`*_ \t-]+$", "", value)
    value = re.sub(r"^\[?P[0-3]\]?[ :\u2014-]+", "", value, flags=re.I)
    value = re.sub(r"\s+", " ", value).strip()
    return value or "Audit job did not produce a specific finding title"


def _category(row: SummaryRow, text: str) -> str:
    hay = f"{row.remediation_context} {row.title} {text}".lower()
    if "runner_unavailable" in hay or "timeout" in hay or "timed out" in hay:
        return "runtime_unavailable"
    if any(token in hay for token in ("browser", "playwright", "lighthouse",
                                      "axe", "e2e", "unverified")):
        return "evidence_gap"
    if any(token in hay for token in ("missing-output", "harness",
                                      "command not found", "native command")):
        return "harness_gap"
    return "product_gap"


def _theme(row: SummaryRow, text: str) -> str:
    hay = f"{row.remediation_context} {row.title} {text}".lower()
    if "tenant" in hay or "rls" in hay:
        return "tenant_scope_missing"
    if any(token in hay for token in ("browser", "playwright", "lighthouse",
                                      "axe", "e2e")):
        return "browser_evidence_missing"
    if "openapi" in hay or "api contract" in hay or "schema" in hay:
        return "api_contract_docs_missing"
    if "runner_unavailable" in hay:
        return "runner_unavailable"
    key = WORD_RE.sub("_", row.title.lower()).strip("_")
    return f"finding_{key[:80]}" if key else "finding_audit_job"


def _model_class(category: str, severity: str) -> str:
    if severity in {"P0", "P1"} or category == "product_gap":
        return "high-risk"
    if category in {"runtime_unavailable", "harness_gap"}:
        return "complex"
    return "standard"


def _dedupe_key(row: FindingRow) -> tuple[str, str, str, str]:
    return (row.category, row.theme, row.source, row.title.lower())


def build_ledger(run_dir: Path, summary_file: Path) -> list[FindingRow]:
    rows: list[FindingRow] = []
    for index, row in enumerate(_read_summary(summary_file), start=1):
        if row.result in PASS_RESULTS:
            continue
        source = _source_path(row, run_dir)
        text = _source_text(source)
        severity = _severity(text, row.result)
        line, title = _heading(text, row.title or row.job_id)
        category = _category(row, text)
        theme = _theme(row, text)
        rel_source = _rel(source, run_dir)
        raw_id = f"{severity}-{index:04d}"
        rows.append(FindingRow(
            severity=severity,
            category=category,
            theme=theme,
            group=row.group or row.kind or "audit",
            model_class=_model_class(category, severity),
            source=rel_source,
            line=line,
            title=title,
            raw_id=raw_id,
            references=f"{row.job_id}:{rel_source}:{line}",
        ))
    deduped: dict[tuple[str, str, str, str], FindingRow] = {}
    for row in rows:
        deduped.setdefault(_dedupe_key(row), row)
    return list(deduped.values())


def write_ledger(rows: list[FindingRow], out: Path) -> None:
    if not rows:
        if out.exists():
            out.unlink()
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow([
            "blocker_id", "category", "theme", "severity", "group",
            "model_class", "finding_count", "representative_source",
            "representative_line", "representative_title", "raw_px_ids",
            "references",
        ])
        for index, row in enumerate(rows, start=1):
            writer.writerow([
                f"B-{index:04d}", row.category, row.theme, row.severity,
                row.group, row.model_class, "1", row.source, row.line,
                row.title, row.raw_id, row.references,
            ])


def main() -> int:
    args = _args()
    rows = build_ledger(Path(args.run_dir), Path(args.summary_file))
    write_ledger(rows, Path(args.out))
    if rows:
        print(f"wrote {len(rows)} blocker rows to {args.out}")
    else:
        print("no non-pass audit rows; blocker ledger not written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
