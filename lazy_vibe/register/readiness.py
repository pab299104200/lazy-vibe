"""Deterministic release-readiness predicate (spec §7.2). Zero LLM calls.

Exit codes: 0 READY, 1 NOT READY, 2 stale/missing gate evidence.
Past-due risk acceptances FAIL the predicate (spec §4.2 anti-debt guard).
The report always lists active risk acceptances and parked counts so
deferred work is visible at every release decision.
"""
from __future__ import annotations

import datetime as _dt
import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .model import Finding, RegisterError
from .scope import VALID_OPS, Gate, Scope

_OPEN_LIKE = {"new", "open", "in_remediation", "regressed"}
# Executor for scope.VALID_OPS — load_scope validates against that set, so
# the two must stay in sync; the assert makes drift a startup failure.
_OPS = {"eq": lambda a, b: a == b,
        "le": lambda a, b: a <= b,
        "ge": lambda a, b: a >= b}
assert set(_OPS) == VALID_OPS, "gate op executor out of sync with scope.VALID_OPS"


@dataclass
class ReadinessReport:
    product: str
    ready: bool
    exit_code: int
    blocking: list[str] = field(default_factory=list)
    gate_results: list[tuple[str, str]] = field(default_factory=list)
    risk_acceptances: list[str] = field(default_factory=list)
    parked_count: int = 0
    not_gated_count: int = 0


def _bar_blocks(finding: Finding, rule: str) -> str | None:
    if rule in ("zero_open", "zero_open_or_risk_accepted"):
        if finding.disposition in _OPEN_LIKE:
            return (f"{finding.finding_id} {finding.severity} "
                    f"{finding.disposition}: {finding.title}")
        if rule == "zero_open" and finding.disposition == "risk_accepted":
            return (f"{finding.finding_id} {finding.severity} risk_accepted "
                    f"but bar requires zero_open: {finding.title}")
        return None
    if rule == "triaged":
        if finding.disposition == "new":
            return (f"{finding.finding_id} {finding.severity} untriaged: "
                    f"{finding.title}")
        return None
    return None  # "ignored"


def _eval_gate(gate: Gate) -> tuple[str, str]:
    """Returns (status, detail) with status PASS|FAIL|STALE."""
    params = gate.params
    if gate.gate_type == "command":
        try:
            # shell=True is deliberate: gate commands are operator-authored,
            # git-committed launch-scope.yaml config (same trust model as a
            # Makefile/CI step) and need `cd x && y` composition. They are
            # never derived from finding content or any untrusted input.
            proc = subprocess.run(params["command"], shell=True,
                                  capture_output=True, text=True,
                                  timeout=params.get("timeout", 1800),
                                  cwd=params.get("cwd"))
        except subprocess.TimeoutExpired:
            return "FAIL", f"command timed out: {params['command']}"
        if proc.returncode == 0:
            return "PASS", params["command"]
        return "FAIL", (f"exit {proc.returncode}: {params['command']} — "
                        f"{(proc.stderr or proc.stdout).strip()[-200:]}")
    artifact = Path(params["path"])
    if not artifact.exists():
        return "STALE", f"artifact missing: {artifact}"
    max_age = params.get("max_age_days")
    if max_age is not None:
        age = (_dt.datetime.now(tz=_dt.timezone.utc)
               - _dt.datetime.fromtimestamp(artifact.stat().st_mtime,
                                            tz=_dt.timezone.utc)).days
        if age > int(max_age):
            return "STALE", f"artifact older than {max_age}d: {artifact}"
    if gate.gate_type == "artifact_exists":
        return "PASS", str(artifact)
    try:
        data = json.loads(artifact.read_text())
    except json.JSONDecodeError as exc:
        return "STALE", f"artifact unparseable: {artifact}: {exc}"
    value = data
    for part in str(params["key"]).split("."):
        if not isinstance(value, dict) or part not in value:
            return "STALE", f"key {params['key']!r} missing in {artifact}"
        value = value[part]
    op = _OPS.get(params["op"])
    if op is None:
        raise RegisterError(f"gate {gate.gate_id}: unknown op {params['op']!r}")
    if op(value, params["value"]):
        return "PASS", f"{params['key']}={value}"
    return "FAIL", (f"{params['key']}={value!r}, wanted "
                    f"{params['op']} {params['value']!r}")


def evaluate(store, scope: Scope, *, today: str) -> ReadinessReport:
    report = ReadinessReport(product=scope.product, ready=True, exit_code=0)
    try:
        today_date = _dt.date.fromisoformat(today)
    except (ValueError, TypeError) as exc:
        raise RegisterError(
            f"readiness date must be ISO (YYYY-MM-DD), got {today!r}"
        ) from exc
    findings = store.load()
    for finding in findings.values():
        if finding.disposition == "parked":
            report.parked_count += 1
        if finding.disposition == "risk_accepted":
            report.risk_acceptances.append(
                f"{finding.finding_id} {finding.severity} review by "
                f"{finding.review_by}: {finding.title}")
            if _dt.date.fromisoformat(finding.review_by) < today_date:
                report.blocking.append(
                    f"{finding.finding_id} risk acceptance past due "
                    f"({finding.review_by}) — reaffirm or fix")
        if not finding.in_scope:
            continue
        if finding.fingerprint_inputs.get("theme", "").startswith(
                "_candidate:") and finding.disposition == "new":
            report.blocking.append(
                f"{finding.finding_id} unresolved theme "
                f"{finding.fingerprint_inputs['theme']} — vocabulary gap "
                f"(spec §12)")
            continue
        rule = scope.severity_bar.get(finding.severity)
        if rule is None:
            if finding.disposition in _OPEN_LIKE:
                report.not_gated_count += 1
            continue
        blocked = _bar_blocks(finding, rule)
        if blocked:
            report.blocking.append(blocked)
    for gate in scope.gates:
        status, detail = _eval_gate(gate)
        report.gate_results.append((gate.gate_id, f"{status}: {detail}"))
        if status == "STALE":
            report.exit_code = 2
            report.ready = False
        elif status == "FAIL":
            report.ready = False
    if report.blocking:
        report.ready = False
    if not report.ready and report.exit_code == 0:
        report.exit_code = 1
    return report


def render_readiness(report: ReadinessReport) -> str:
    if report.ready:
        verdict = "READY"
    elif report.exit_code == 2:
        n = len(report.blocking)
        verdict = f"STALE EVIDENCE ({n} blocking)" if n else "STALE EVIDENCE"
    else:
        verdict = "NOT READY"
    lines = [f"# Readiness — {report.product}: {verdict}", ""]
    if report.blocking:
        lines += ["## Blocking", ""]
        lines += [f"- {item}" for item in report.blocking] + [""]
    if report.gate_results:
        lines += ["## Gates", ""]
        lines += [f"- {gid}: {res}" for gid, res in report.gate_results] + [""]
    lines += ["## Active risk acceptances", ""]
    lines += ([f"- {a}" for a in report.risk_acceptances] or ["- none"])
    lines += ["", f"Parked: {report.parked_count}",
              f"Not gated: {report.not_gated_count}", ""]
    return "\n".join(lines)
