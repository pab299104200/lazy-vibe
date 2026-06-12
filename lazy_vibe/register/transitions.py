"""Disposition state machine (spec §4.2)."""
from __future__ import annotations

import datetime as _dt

from .model import Disposition, Finding, RegisterError

D = Disposition


class TransitionError(RegisterError):
    """Illegal or unguarded disposition transition."""


def _require_iso_date(finding: Finding, value: str) -> None:
    try:
        _dt.date.fromisoformat(value)
    except ValueError:
        raise TransitionError(f"{finding.finding_id}: review_by must be an "
                              f"ISO date (YYYY-MM-DD), got {value!r}") from None


def validate_regression_test(finding_id: str, value: str) -> None:
    """Shared guard: a closing regression test must be ``path::test_name``
    with a non-empty path and test name, so the fixed state stays rerunnable
    (mirrors ``_require_iso_date``; used by ``_guard_fixed`` and the close
    CLI verb)."""
    path, sep, name = (value or "").partition("::")
    if not (sep and path.strip() and name.strip()):
        raise TransitionError(
            f"{finding_id}: regression_test must be 'path::test_name' "
            f"(e.g. tests/test_x.py::test_y), got {value!r}")


def _require_pete_or_policy(finding: Finding, by: str, kw: dict) -> None:
    if not (by == "pete" or by.startswith("policy:")):
        raise TransitionError(f"{finding.finding_id}: authority 'pete' or "
                              f"'policy:*' required, got {by!r}")


def _guard_new_open(finding: Finding, by: str, kw: dict) -> None:
    if not kw.get("verified"):
        raise TransitionError(f"{finding.finding_id}: new->open requires verified=True")
    _require_pete_or_policy(finding, by, kw)


def _guard_new_false_positive(finding: Finding, by: str, kw: dict) -> None:
    _require_pete_or_policy(finding, by, kw)


def _guard_new_parked(finding: Finding, by: str, kw: dict) -> None:
    if not (by == "pete" or by == "scope" or by.startswith("policy:")):
        raise TransitionError(f"{finding.finding_id}: authority 'pete', 'scope' or "
                              f"'policy:*' required, got {by!r}")


def _guard_risk_accept(finding: Finding, by: str, kw: dict) -> None:
    if by != "pete":
        raise TransitionError(f"{finding.finding_id}: risk_accepted requires "
                              f"authority 'pete', got {by!r}")
    if not kw.get("review_by"):
        raise TransitionError(f"{finding.finding_id}: risk_accepted requires review_by")
    _require_iso_date(finding, kw["review_by"])


def _guard_fixed(finding: Finding, by: str, kw: dict) -> None:
    if not kw.get("regression_test"):
        raise TransitionError(f"{finding.finding_id}: fixed requires regression_test")
    validate_regression_test(finding.finding_id, kw["regression_test"])


def _guard_regressed(finding: Finding, by: str, kw: dict) -> None:
    if by != "reconciler":
        raise TransitionError(f"{finding.finding_id}: authority 'reconciler' "
                              f"required, got {by!r}")


def _guard_reopen_protected(finding: Finding, by: str, kw: dict) -> None:
    if by != "pete":
        raise TransitionError(f"{finding.finding_id}: reopening a protected "
                              f"disposition requires authority 'pete', got {by!r}")


def _guard_parked_open(finding: Finding, by: str, kw: dict) -> None:
    if by not in ("pete", "scope"):
        raise TransitionError(f"{finding.finding_id}: authority 'pete' or 'scope' "
                              f"required, got {by!r}")


def _no_guard(finding: Finding, by: str, kw: dict) -> None:
    return None


_TRANSITIONS = {
    (D.NEW, D.OPEN): _guard_new_open,
    (D.NEW, D.FALSE_POSITIVE): _guard_new_false_positive,
    (D.NEW, D.PARKED): _guard_new_parked,
    (D.NEW, D.RISK_ACCEPTED): _guard_risk_accept,
    (D.OPEN, D.IN_REMEDIATION): _no_guard,
    (D.OPEN, D.RISK_ACCEPTED): _guard_risk_accept,
    (D.IN_REMEDIATION, D.FIXED): _guard_fixed,
    (D.IN_REMEDIATION, D.OPEN): _no_guard,
    (D.FIXED, D.REGRESSED): _guard_regressed,
    (D.REGRESSED, D.IN_REMEDIATION): _no_guard,
    (D.PARKED, D.OPEN): _guard_parked_open,
    (D.FALSE_POSITIVE, D.OPEN): _guard_reopen_protected,
    (D.RISK_ACCEPTED, D.OPEN): _guard_reopen_protected,
}

LEGAL_EDGES = frozenset(_TRANSITIONS)


def transition(finding: Finding, to: Disposition, *, by: str, reason: str,
               now: str, **kw) -> None:
    """Apply a guarded disposition transition, mutating the finding in place."""
    src = Disposition(finding.disposition)
    guard = _TRANSITIONS.get((src, to))
    if guard is None:
        raise TransitionError(f"{finding.finding_id}: no transition "
                              f"{src.value} -> {to.value}")
    guard(finding, by, kw)
    if kw.get("regression_test"):
        finding.regression_test = kw["regression_test"]
    if kw.get("review_by"):
        finding.review_by = kw["review_by"]
    finding.disposition = to.value
    finding.disposition_by = by
    finding.disposition_reason = reason
    finding.history.append({"ts": now, "event": "disposition",
                            "from": src.value, "to": to.value,
                            "by": by, "reason": reason})
    finding.validate()


def reaffirm_risk(finding: Finding, *, review_by: str, by: str, now: str,
                  reason: str) -> None:
    """Extend a risk acceptance's review date (spec §4.2 anti-debt guard)."""
    if Disposition(finding.disposition) is not D.RISK_ACCEPTED:
        raise TransitionError(f"{finding.finding_id}: reaffirm requires "
                              f"disposition risk_accepted")
    if by != "pete":
        raise TransitionError(f"{finding.finding_id}: reaffirm requires "
                              f"authority 'pete', got {by!r}")
    _require_iso_date(finding, review_by)
    old = finding.review_by
    finding.review_by = review_by
    finding.history.append({"ts": now, "event": "risk_reaffirmed",
                            "from": old, "to": review_by, "by": by,
                            "reason": reason})
    finding.validate()
