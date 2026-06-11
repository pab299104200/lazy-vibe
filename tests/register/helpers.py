"""Shared test helpers for register tests."""


def with_history(finding):
    """Append a disposition history event matching the finding's current
    disposition, satisfying the store's history invariant (test setup)."""
    if finding.disposition != "new":
        finding.history.append({"ts": "2026-06-01T00:00:00+00:00",
                                "event": "disposition", "from": "new",
                                "to": finding.disposition,
                                "by": finding.disposition_by,
                                "reason": "test setup"})
    return finding
