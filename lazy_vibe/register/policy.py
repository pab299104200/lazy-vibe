"""Deterministic triage policy engine (spec §6 stage 2).

`triage-policy.yaml` is an ordered, first-match-wins rule list over `new`
findings. Every auto-disposition is stamped `policy:<rule-id>`; proposals
(`propose_risk_accept`) never transition (spec §4.2 — risk acceptance is
Pete-only) but append a `risk_accept_proposed` event for the queue. The
`false_positive` action is only legal when the last verification verdict is
UNSUPPORTED (spec §6); using it otherwise is a hard error so policy authors
cannot silently suppress real findings.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .fingerprint import normalize_path
from .model import Disposition, Finding, RegisterError
from .transitions import transition
from .verify import last_verification

_VALID_ACTIONS = {"open", "park", "false_positive", "propose_risk_accept",
                  "queue"}
_VALID_MATCH_KEYS = {"severity", "taxonomy", "in_scope", "verified", "theme",
                     "path_prefix"}


@dataclass(frozen=True)
class Rule:
    rule_id: str
    match: dict
    action: str


@dataclass(frozen=True)
class Policy:
    rules: tuple[Rule, ...]
    default: str


@dataclass
class PolicyOutcome:
    opened: list[str] = field(default_factory=list)
    parked: list[str] = field(default_factory=list)
    false_positive: list[str] = field(default_factory=list)
    proposed_risk_accept: list[str] = field(default_factory=list)
    queued: list[str] = field(default_factory=list)


def _now(date: str) -> str:
    return f"{date}T00:00:00+00:00"


def load_policy(path: Path) -> Policy:
    if not path.exists():
        raise RegisterError(
            f"triage-policy file not found: {path} — create triage-policy.yaml "
            f"(spec §6)")
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise RegisterError(f"{path}: expected a top-level mapping")
    if "default" not in data or data["default"] not in _VALID_ACTIONS:
        raise RegisterError(
            f"{path}: a top-level 'default' action is required "
            f"(valid: {sorted(_VALID_ACTIONS)})")
    rules = []
    for index, raw in enumerate(data.get("rules") or []):
        if not isinstance(raw, dict) or not raw.get("id"):
            raise RegisterError(f"{path}: rule {index}: missing 'id'")
        action = raw.get("action")
        if action not in _VALID_ACTIONS:
            raise RegisterError(
                f"{path}: rule {raw['id']!r}: action {action!r} invalid "
                f"(valid: {sorted(_VALID_ACTIONS)})")
        match = raw.get("match") or {}
        if not isinstance(match, dict):
            raise RegisterError(f"{path}: rule {raw['id']!r}: 'match' must be "
                                f"a mapping")
        unknown = set(match) - _VALID_MATCH_KEYS
        if unknown:
            raise RegisterError(
                f"{path}: rule {raw['id']!r}: unknown match key(s) "
                f"{sorted(unknown)} (valid: {sorted(_VALID_MATCH_KEYS)})")
        rules.append(Rule(rule_id=raw["id"], match=dict(match), action=action))
    return Policy(rules=tuple(rules), default=data["default"])


def _verified(finding: Finding) -> bool:
    event = last_verification(finding)
    return bool(event) and event.get("verdict") == "VERIFIED"


def _matches(finding: Finding, match: dict) -> bool:
    for key, want in match.items():
        if key == "severity" and finding.severity != want:
            return False
        if key == "taxonomy" and finding.taxonomy != want:
            return False
        if key == "in_scope" and finding.in_scope != bool(want):
            return False
        if key == "verified" and _verified(finding) != bool(want):
            return False
        if key == "theme" and finding.fingerprint_inputs.get("theme") != want:
            return False
        if key == "path_prefix" and not normalize_path(
                finding.fingerprint_inputs.get("path", "")).startswith(str(want)):
            return False
    return True


def _act(findings, finding, action, rule_id, now,
         outcome: PolicyOutcome) -> None:
    by = f"policy:{rule_id}"
    if action == "open":
        transition(finding, Disposition.OPEN, by=by,
                   reason=f"auto-opened by {rule_id}", now=now, verified=True)
        outcome.opened.append(finding.finding_id)
    elif action == "park":
        transition(finding, Disposition.PARKED, by=by,
                   reason=f"auto-parked by {rule_id}", now=now)
        outcome.parked.append(finding.finding_id)
    elif action == "false_positive":
        event = last_verification(finding)
        if not event or event.get("verdict") != "UNSUPPORTED":
            raise RegisterError(
                f"{finding.finding_id}: rule {rule_id!r} action "
                f"false_positive requires a verifier UNSUPPORTED verdict "
                f"(spec §6); last verdict is "
                f"{event.get('verdict') if event else 'none'}")
        transition(finding, Disposition.FALSE_POSITIVE, by=by,
                   reason=f"auto false_positive by {rule_id}", now=now)
        outcome.false_positive.append(finding.finding_id)
    elif action == "propose_risk_accept":
        finding.history.append({"ts": now, "event": "risk_accept_proposed",
                                "by": by, "rule": rule_id})
        outcome.proposed_risk_accept.append(finding.finding_id)
    else:  # queue
        outcome.queued.append(finding.finding_id)


def apply_policy(store, policy: Policy, *, date: str) -> PolicyOutcome:
    outcome = PolicyOutcome()
    now = _now(date)
    with store.locked():
        findings = store.load()
        for finding in sorted(findings.values(), key=lambda f: f.finding_id):
            if finding.disposition != "new":
                continue
            action = policy.default
            for rule in policy.rules:
                if _matches(finding, rule.match):
                    action = rule.action
                    rule_id = rule.rule_id
                    break
            else:
                rule_id = "default"
            _act(findings, finding, action, rule_id, now, outcome)
        store.save(findings)
    return outcome
