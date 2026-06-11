"""Shared test helpers for register tests."""

_CHAIN = {
    "open": ["open"],
    "in_remediation": ["open", "in_remediation"],
    "fixed": ["open", "in_remediation", "fixed"],
    "regressed": ["open", "in_remediation", "fixed", "regressed"],
    "false_positive": ["false_positive"],
    "risk_accepted": ["risk_accepted"],
    "parked": ["parked"],
}


def with_history(finding):
    """Append a legal disposition-event chain reaching the finding's current
    disposition, satisfying the store's history invariant (test setup)."""
    prev = "new"
    for state in _CHAIN.get(finding.disposition, []):
        finding.history.append({"ts": "2026-06-01T00:00:00+00:00",
                                "event": "disposition", "from": prev,
                                "to": state, "by": finding.disposition_by,
                                "reason": "test setup"})
        prev = state
    return finding
