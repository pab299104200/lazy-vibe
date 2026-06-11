"""Locked, atomic JSONL persistence + generated markdown view (spec §4.3)."""
from __future__ import annotations

import fcntl
import os
import re
from contextlib import contextmanager
from pathlib import Path

from .model import SEVERITY_ORDER, Disposition, Finding, RegisterError
from .transitions import LEGAL_EDGES

_DISPOSITION_RENDER_ORDER = ("regressed", "open", "in_remediation", "new",
                             "risk_accepted", "parked", "fixed", "false_positive")

_CELL_BREAK_RE = re.compile(r"[\r\n]+")

_GITIGNORE_SEED = ".register.lock\n*.tmp\n"


def markdown_cell(text: str) -> str:
    """Escape free text for a single-line markdown table cell."""
    return _CELL_BREAK_RE.sub(" ", text).replace("|", "\\|")


def _check_history_invariant(finding: Finding) -> None:
    """Persistence-boundary integrity wall (spec §4.3).

    Proves internal consistency of the disposition-event chain: it must
    start from 'new', every edge must be legal per the state machine,
    each event must continue where the previous left off, and the final
    event must match the current disposition. It does NOT prove
    provenance — git history and transitions.transition() own that;
    whoever can fabricate a coherent chain can also rewrite git.
    """
    events = [h for h in finding.history if h.get("event") == "disposition"]
    if not events:
        if finding.disposition != "new":
            raise RegisterError(
                f"{finding.finding_id}: disposition {finding.disposition!r} has no "
                f"matching disposition history event — disposition changes must go "
                f"through transitions.transition()")
        return
    prev = "new"
    for event in events:
        src, dst = event.get("from"), event.get("to")
        if src != prev:
            raise RegisterError(
                f"{finding.finding_id}: disposition history chain broken — event "
                f"from {src!r} does not follow {prev!r}")
        try:
            edge = (Disposition(src), Disposition(dst))
        except ValueError:
            raise RegisterError(
                f"{finding.finding_id}: disposition history contains unknown "
                f"state in edge {src!r} -> {dst!r}") from None
        if edge not in LEGAL_EDGES:
            raise RegisterError(
                f"{finding.finding_id}: disposition history contains illegal "
                f"edge {src!r} -> {dst!r}")
        prev = dst
    if prev != finding.disposition:
        raise RegisterError(
            f"{finding.finding_id}: disposition {finding.disposition!r} does "
            f"not match last history event {prev!r} — disposition changes "
            f"must go through transitions.transition()")


class RegisterStore:
    """Atomic JSONL register persistence with a generated markdown view.

    Locking contract: ``load()`` and ``save()`` are individually lock-free.
    Any read-modify-write sequence (load, mutate, save) must be wrapped in
    ``locked()`` to serialize against concurrent writers; the atomic rename
    in ``save()`` only protects readers from torn files, not lost updates.
    """

    def __init__(self, register_dir: Path):
        self.register_dir = Path(register_dir)
        self.jsonl_path = self.register_dir / "register.jsonl"
        self.markdown_path = self.register_dir / "register.md"
        self.lock_path = self.register_dir / ".register.lock"

    @contextmanager
    def locked(self):
        self.register_dir.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)

    def load(self) -> dict[str, Finding]:
        if not self.jsonl_path.exists():
            return {}
        findings: dict[str, Finding] = {}
        with self.jsonl_path.open() as fh:
            for lineno, line in enumerate(fh, start=1):
                if not line.strip():
                    continue
                finding = Finding.from_json_line(line, lineno=lineno)
                _check_history_invariant(finding)
                if finding.finding_id in findings:
                    raise RegisterError(
                        f"duplicate finding_id {finding.finding_id} at line {lineno}")
                findings[finding.finding_id] = finding
        return findings

    def save(self, findings: dict[str, Finding]) -> None:
        self.register_dir.mkdir(parents=True, exist_ok=True)
        gitignore = self.register_dir / ".gitignore"
        if not gitignore.exists():
            gitignore.write_text(_GITIGNORE_SEED)
        ordered = sorted(findings.values(), key=lambda f: f.finding_id)
        for finding in ordered:
            finding.validate()
            _check_history_invariant(finding)
        tmp = self.jsonl_path.with_suffix(".jsonl.tmp")
        with tmp.open("w") as fh:
            for finding in ordered:
                fh.write(finding.to_json_line() + "\n")
        os.replace(tmp, self.jsonl_path)
        md_tmp = self.markdown_path.with_suffix(".md.tmp")
        md_tmp.write_text(self.render_markdown(findings))
        os.replace(md_tmp, self.markdown_path)

    @staticmethod
    def next_id(findings: dict[str, Finding]) -> str:
        highest = max((int(fid.split("-")[1]) for fid in findings), default=0)
        return f"R-{highest + 1:04d}"

    @staticmethod
    def by_fingerprint(findings: dict[str, Finding]) -> dict[str, Finding]:
        return {f.fingerprint: f for f in findings.values()}

    @staticmethod
    def render_markdown(findings: dict[str, Finding]) -> str:
        lines = ["# Findings Register",
                 "",
                 "<!-- generated by lazy_vibe.register — do not edit by hand -->",
                 ""]
        by_disposition: dict[str, list[Finding]] = {}
        for finding in findings.values():
            by_disposition.setdefault(finding.disposition, []).append(finding)
        for disposition in _DISPOSITION_RENDER_ORDER:
            group = by_disposition.get(disposition)
            if not group:
                continue
            group.sort(key=lambda f: (SEVERITY_ORDER[f.severity], f.finding_id))
            lines += [f"## {disposition} ({len(group)})", "",
                      "| id | sev | scope | taxonomy | title | last seen | by |",
                      "|---|---|---|---|---|---|---|"]
            for f in group:
                scope = "in" if f.in_scope else "out"
                lines.append(
                    f"| {f.finding_id} | {f.severity} | {scope} | {f.taxonomy} "
                    f"| {markdown_cell(f.title)} | {f.last_seen.get('date', '-')} "
                    f"| {f.disposition_by} |")
            lines.append("")
        return "\n".join(lines)
