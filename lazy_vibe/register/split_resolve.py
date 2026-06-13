"""Agent-driven resolution for verifier split findings.

A verifier returns ``split`` when cited evidence appears to cover materially
different file sets. That should not force Pete into hand-adjudicating every
row. This module creates a second, narrower packet that asks an agent to make
the operational disposition decision for the existing register finding:

* ``open`` when the finding is real/actionable enough to remediate as one item;
* ``false_positive`` when the current repository disproves it;
* ``park`` when it is real but intentionally out-of-scope/deferred.

It deliberately does not auto-create child findings yet. Splitting a register
record into multiple durable findings needs stronger identity rules than a
single verifier can safely invent.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from .model import Disposition, RegisterError
from .store import RegisterStore
from .transitions import transition

RESULT_SCHEMA_VERSION = 1
_TRIAGE_SUBDIR = "triage"
_VALID_DECISIONS = {"open", "false_positive", "park"}


@dataclass
class SplitResolveOutcome:
    opened: list[str] = field(default_factory=list)
    false_positive: list[str] = field(default_factory=list)
    parked: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    unresolved: list[str] = field(default_factory=list)


def split_packet_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "split-packets" / f"{finding_id}.md"


def split_result_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "split-results" / f"{finding_id}.json"


def consumed_split_result_path(store: RegisterStore, finding_id: str) -> Path:
    return (store.register_dir / _TRIAGE_SUBDIR / "split-results" / "consumed"
            / f"{finding_id}.json")


def _now(date: str) -> str:
    return f"{date}T00:00:00+00:00"


def _last_split(finding) -> dict | None:
    for event in reversed(finding.history):
        if event.get("event") == "split_proposed":
            return event
    return None


def _split_candidates(findings) -> list:
    return sorted(
        (f for f in findings.values()
         if f.disposition == "new" and _last_split(f) is not None),
        key=lambda f: f.finding_id,
    )


def _render_packet(store: RegisterStore, finding) -> str:
    out = split_result_path(store, finding.finding_id)
    split_ev = _last_split(finding) or {}
    split_paths = split_ev.get("split_paths") or []
    evidence = "\n".join(
        f"- {e.get('type', '?')}: `{e.get('ref', '-')}` "
        f"(run {e.get('run_id', '-')})" for e in finding.evidence) or "- (none)"
    paths = "\n".join(f"- `{p}`" for p in split_paths) or "- (none supplied)"
    return f"""\
# Split-resolution packet — {finding.finding_id}

You are resolving a verifier `split` verdict. Decide whether the existing
register finding should enter remediation, be suppressed, or be parked. Do not
ask Pete to decide and do not create child findings.

## Finding

- id: {finding.finding_id}
- severity: {finding.severity}
- taxonomy: {finding.taxonomy}
- path: `{finding.fingerprint_inputs.get('path', '-')}`
- symbol: `{finding.fingerprint_inputs.get('symbol', '-')}`
- title: {finding.title}

{finding.description}

### Existing evidence

{evidence}

### Divergent paths reported by verifier

{paths}

## Repository path resolution

Cited paths can be relative to repo root, `backend/`, `frontend/`,
`frontend/src/`, or `src/`. Search by basename/suffix before deciding a path
is missing.

## Decision contract

Choose exactly one:

- `open`: at least one real, actionable defect remains and this register title
  is a reasonable remediation unit.
- `false_positive`: current code/docs/tests disprove the finding.
- `park`: real or possibly real, but out of current remediation scope or too
  broad to remediate safely as one unit.

Write EXACTLY this JSON object to `{out}` and nothing else:

    {{
      "schema_version": {RESULT_SCHEMA_VERSION},
      "finding_id": "{finding.finding_id}",
      "decision": "open | false_positive | park",
      "evidence": ["path:line citation supporting the decision", "..."],
      "reason": "short operational reason for the disposition"
    }}

Rules: `open` and `false_positive` require concrete citations. `park` requires
a clear reason explaining why this should not enter remediation now.
"""


def generate_split_packets(store: RegisterStore) -> list[Path]:
    written: list[Path] = []
    with store.locked():
        findings = store.load()
    packets_dir = store.register_dir / _TRIAGE_SUBDIR / "split-packets"
    packets_dir.mkdir(parents=True, exist_ok=True)
    (store.register_dir / _TRIAGE_SUBDIR / "split-results").mkdir(
        parents=True, exist_ok=True)
    for finding in _split_candidates(findings):
        path = split_packet_path(store, finding.finding_id)
        path.write_text(_render_packet(store, finding))
        written.append(path)
    return written


def _validate_result(finding_id: str, path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise RegisterError(f"corrupt split result {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RegisterError(f"{path}: split result must be a JSON object")
    if data.get("schema_version") != RESULT_SCHEMA_VERSION:
        raise RegisterError(
            f"{path}: unknown schema_version {data.get('schema_version')!r}")
    if data.get("finding_id") != finding_id:
        raise RegisterError(
            f"{path}: finding_id {data.get('finding_id')!r} does not match "
            f"packet {finding_id!r}")
    decision = data.get("decision")
    if decision not in _VALID_DECISIONS:
        raise RegisterError(
            f"{path}: decision {decision!r} invalid "
            f"(valid: {sorted(_VALID_DECISIONS)})")
    evidence = data.get("evidence")
    if not isinstance(evidence, list) or any(
            not isinstance(e, str) or not e.strip() for e in evidence):
        raise RegisterError(f"{path}: 'evidence' must be a list of strings")
    if decision in {"open", "false_positive"} and not evidence:
        raise RegisterError(f"{path}: {decision} requires evidence citations")
    reason = data.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise RegisterError(f"{path}: 'reason' must be a non-empty string")
    return data


def _archive_result(store: RegisterStore, finding_id: str) -> None:
    src = split_result_path(store, finding_id)
    dst = consumed_split_result_path(store, finding_id)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst = dst.with_name(f"{finding_id}.{int(os.path.getmtime(src))}.json")
    os.replace(src, dst)


def consume_split_results(store: RegisterStore, *, date: str) -> SplitResolveOutcome:
    outcome = SplitResolveOutcome()
    results_dir = store.register_dir / _TRIAGE_SUBDIR / "split-results"
    with store.locked():
        findings = store.load()
        pending = sorted(results_dir.glob("R-*.json")) if results_dir.exists() else []
        for path in pending:
            finding_id = path.stem
            finding = findings.get(finding_id)
            if finding is None or finding.disposition != "new":
                outcome.skipped.append(finding_id)
                _archive_result(store, finding_id)
                continue
            if _last_split(finding) is None:
                outcome.skipped.append(finding_id)
                _archive_result(store, finding_id)
                continue
            data = _validate_result(finding_id, path)
            now = _now(date)
            finding.history.append({
                "ts": now,
                "event": "split_resolved",
                "by": "agent:split-resolver",
                "decision": data["decision"],
                "evidence": data["evidence"],
                "reason": data["reason"],
            })
            if data["decision"] == "open":
                finding.history.append({
                    "ts": now,
                    "event": "verification",
                    "verdict": "VERIFIED",
                    "by": "agent:split-resolver",
                    "evidence": data["evidence"],
                })
                transition(finding, Disposition.OPEN,
                           by="policy:split-resolver",
                           reason=data["reason"], now=now, verified=True)
                outcome.opened.append(finding_id)
            elif data["decision"] == "false_positive":
                transition(finding, Disposition.FALSE_POSITIVE,
                           by="policy:split-resolver",
                           reason=data["reason"], now=now)
                outcome.false_positive.append(finding_id)
            else:
                transition(finding, Disposition.PARKED,
                           by="policy:split-resolver",
                           reason=data["reason"], now=now)
                outcome.parked.append(finding_id)
            _archive_result(store, finding_id)
        split_ids = {f.finding_id for f in _split_candidates(findings)}
        resolved = set(outcome.opened + outcome.false_positive
                       + outcome.parked + outcome.skipped)
        outcome.unresolved = sorted(split_ids - resolved)
        store.save(findings)
    return outcome
