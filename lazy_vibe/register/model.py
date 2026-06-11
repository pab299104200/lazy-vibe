"""Findings register data model (spec §4.1)."""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Any


class RegisterError(ValueError):
    """Invalid register data or operation."""


class Severity(str, Enum):
    P0 = "P0"
    P1 = "P1"
    P2 = "P2"
    P3 = "P3"


SEVERITY_ORDER = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}


class Disposition(str, Enum):
    NEW = "new"
    OPEN = "open"
    IN_REMEDIATION = "in_remediation"
    FIXED = "fixed"
    FALSE_POSITIVE = "false_positive"
    RISK_ACCEPTED = "risk_accepted"
    PARKED = "parked"
    REGRESSED = "regressed"


PROTECTED_DISPOSITIONS = frozenset(
    {Disposition.FALSE_POSITIVE, Disposition.RISK_ACCEPTED}
)

_SIMPLE_TAXONOMY = frozenset({"B", "S", "G", "A", "U", "M"})
_FINDING_ID_RE = re.compile(r"R-\d{4,}")
_FINGERPRINT_KEYS = ("category", "theme", "path", "symbol")


@dataclass
class Finding:
    finding_id: str
    fingerprint: str
    fingerprint_inputs: dict[str, str]
    title: str
    description: str
    severity: str
    severity_source: str  # "proposed" | "adjudicated"
    taxonomy: str
    in_scope: bool
    disposition: str
    disposition_by: str
    disposition_reason: str
    evidence: list[dict[str, str]] = field(default_factory=list)
    regression_test: str | None = None
    review_by: str | None = None
    first_seen: dict[str, str] = field(default_factory=dict)
    last_seen: dict[str, str] = field(default_factory=dict)
    occurrences: int = 1
    history: list[dict[str, Any]] = field(default_factory=list)

    def validate(self) -> None:
        if not _FINDING_ID_RE.fullmatch(self.finding_id):
            raise RegisterError(f"invalid finding_id: {self.finding_id!r}")
        if self.severity not in SEVERITY_ORDER:
            raise RegisterError(f"invalid severity: {self.severity!r}")
        if self.severity_source not in ("proposed", "adjudicated"):
            raise RegisterError(f"invalid severity_source: {self.severity_source!r}")
        try:
            disposition = Disposition(self.disposition)
        except ValueError:
            raise RegisterError(f"invalid disposition: {self.disposition!r}") from None
        if not (self.taxonomy in _SIMPLE_TAXONOMY
                or self.taxonomy.startswith(("F-", "RC-"))):
            raise RegisterError(f"invalid taxonomy: {self.taxonomy!r}")
        missing = [k for k in _FINGERPRINT_KEYS if not self.fingerprint_inputs.get(k)]
        if missing:
            raise RegisterError(f"fingerprint_inputs missing keys: {missing}")
        if disposition is Disposition.FIXED and not self.regression_test:
            raise RegisterError(
                f"{self.finding_id}: disposition 'fixed' requires regression_test"
            )
        if disposition is Disposition.RISK_ACCEPTED and not self.review_by:
            raise RegisterError(
                f"{self.finding_id}: disposition 'risk_accepted' requires review_by"
            )

    def to_json_line(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, ensure_ascii=False)

    @classmethod
    def from_json_line(cls, line: str, lineno: int | None = None) -> "Finding":
        where = f" at line {lineno}" if lineno is not None else ""
        try:
            data = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RegisterError(f"corrupt register entry{where}: {exc}") from exc
        try:
            finding = cls(**data)
        except TypeError as exc:
            raise RegisterError(f"invalid register entry{where}: {exc}") from exc
        finding.validate()
        return finding
