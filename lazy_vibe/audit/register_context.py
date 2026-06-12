from __future__ import annotations

import argparse
from pathlib import Path

from lazy_vibe.register.model import SEVERITY_ORDER, Finding
from lazy_vibe.register.store import RegisterStore


OPEN_DISPOSITIONS = {"new", "open", "in_remediation", "regressed"}
SUPPRESSED_DISPOSITIONS = {"false_positive", "risk_accepted", "parked", "fixed"}
DEFAULT_LIMIT = 40


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render compact register context for audit prompts.")
    parser.add_argument("--register-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    return parser.parse_args()


def evidence_refs(finding: Finding, limit: int = 2) -> str:
    refs: list[str] = []
    for item in finding.evidence:
        ref = str(item.get("ref") or item.get("path") or "").strip()
        if ref and ref not in refs:
            refs.append(ref)
        if len(refs) >= limit:
            break
    return ", ".join(refs) if refs else "-"


def finding_priority(finding: Finding) -> tuple[int, int, int, str]:
    severity = SEVERITY_ORDER.get(finding.severity, 99)
    return (0 if finding.in_scope else 1, -int(finding.occurrences or 0), severity, finding.finding_id)


def row(finding: Finding) -> str:
    fingerprint = finding.fingerprint[:20] + "..." if len(finding.fingerprint) > 23 else finding.fingerprint
    theme = finding.fingerprint_inputs.get("theme") or "-"
    details = [
        f"`{finding.finding_id}`",
        finding.disposition,
        finding.severity,
        theme,
        f"`{fingerprint}`",
        finding.title,
        f"refs: {evidence_refs(finding)}",
        f"occurrences: {finding.occurrences}",
    ]
    if finding.review_by:
        details.append(f"review_by: {finding.review_by}")
    if finding.regression_test:
        details.append(f"regression_test: {finding.regression_test}")
    return "- " + " | ".join(details)


def selected(findings: dict[str, Finding], dispositions: set[str], limit: int) -> list[Finding]:
    candidates = [f for f in findings.values() if f.in_scope and f.disposition in dispositions]
    candidates.sort(key=finding_priority)
    return candidates[:limit]


def render(register_dir: Path, limit: int = DEFAULT_LIMIT) -> str:
    store = RegisterStore(register_dir)
    findings = store.load()
    open_items = selected(findings, OPEN_DISPOSITIONS, limit)
    suppressed_items = selected(findings, SUPPRESSED_DISPOSITIONS, limit)
    lines = [
        "# Register Context",
        "",
        "Use this as duplicate/suppression context, not as a substitute for current-code evidence.",
        "Do not report a new finding that is materially identical to an open or adjudicated in-scope register entry.",
        "If current evidence is materially different from a suppressed entry, cite the new evidence and explain why it is not the same fingerprint.",
        "",
        f"## Open / Active ({len(open_items)} shown)",
        "",
    ]
    lines.extend(row(finding) for finding in open_items)
    if not open_items:
        lines.append("- none")
    lines.extend(["", f"## Suppressed / Adjudicated ({len(suppressed_items)} shown)", ""])
    lines.extend(row(finding) for finding in suppressed_items)
    if not suppressed_items:
        lines.append("- none")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(Path(args.register_dir), max(1, args.limit)), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
