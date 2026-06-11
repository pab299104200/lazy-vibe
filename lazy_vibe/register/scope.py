"""Per-product launch scope: customer-facing surface + bar + gates (spec §7.1)."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .fingerprint import normalize_path
from .model import Finding, RegisterError

_VALID_BAR = {
    "P0": {"zero_open"},
    "P1": {"zero_open", "zero_open_or_risk_accepted"},
    "P2": {"zero_open", "zero_open_or_risk_accepted", "triaged"},
    "P3": {"triaged", "ignored"},
}
_VALID_GATE_TYPES = {"command", "artifact_json", "artifact_exists"}
_GATE_REQUIRED = {
    "command": {"command"},
    "artifact_json": {"path", "key", "op", "value"},
    "artifact_exists": {"path"},
}


@dataclass(frozen=True)
class Surface:
    slug: str
    paths: tuple[str, ...]
    routes: tuple[str, ...]


@dataclass(frozen=True)
class Gate:
    gate_id: str
    gate_type: str
    params: dict


@dataclass(frozen=True)
class Scope:
    product: str
    default_in_scope: bool
    surfaces: tuple[Surface, ...]
    severity_bar: dict[str, str]
    gates: tuple[Gate, ...]


def load_scope(path: Path) -> Scope:
    if not path.exists():
        raise RegisterError(
            f"launch-scope file not found: {path} — create launch-scope.yaml "
            f"(spec §7.1)")
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise RegisterError(f"{path}: expected a top-level mapping")
    product = data.get("product")
    if not isinstance(product, str) or not product:
        raise RegisterError(f"{path}: 'product' must be a non-empty string")
    surfaces = []
    for raw in data.get("surfaces") or []:
        if not isinstance(raw, dict) or not raw.get("slug"):
            raise RegisterError(f"{path}: each surface needs a 'slug' mapping")
        paths = raw.get("paths") or []
        routes = raw.get("routes") or []
        if not isinstance(paths, list) or not isinstance(routes, list):
            raise RegisterError(
                f"{path}: surface {raw['slug']!r}: 'paths' and 'routes' "
                f"must be lists")
        surfaces.append(Surface(slug=raw["slug"],
                                paths=tuple(str(p) for p in paths),
                                routes=tuple(str(r) for r in routes)))
    bar = data.get("severity_bar") or {}
    if not isinstance(bar, dict):
        raise RegisterError(f"{path}: 'severity_bar' must be a mapping")
    for sev, rule in bar.items():
        if sev not in _VALID_BAR or rule not in _VALID_BAR[sev]:
            raise RegisterError(
                f"{path}: severity_bar {sev}: {rule!r} is not a valid rule "
                f"(valid for {sev}: {sorted(_VALID_BAR.get(sev, []))})")
    gates = []
    for raw in data.get("gates") or []:
        if not isinstance(raw, dict) or not raw.get("id"):
            raise RegisterError(f"{path}: each gate needs an 'id'")
        gate_type = raw.get("type")
        if gate_type not in _VALID_GATE_TYPES:
            raise RegisterError(
                f"{path}: gate {raw['id']!r}: type {gate_type!r} invalid "
                f"(valid: {sorted(_VALID_GATE_TYPES)})")
        missing = _GATE_REQUIRED[gate_type] - set(raw)
        if missing:
            raise RegisterError(
                f"{path}: gate {raw['id']!r}: missing {sorted(missing)}")
        params = {k: v for k, v in raw.items() if k not in ("id", "type")}
        gates.append(Gate(gate_id=raw["id"], gate_type=gate_type,
                          params=params))
    return Scope(product=product,
                 default_in_scope=bool(data.get("default_in_scope", True)),
                 surfaces=tuple(surfaces),
                 severity_bar=dict(bar),
                 gates=tuple(gates))


def matches(finding: Finding, scope: Scope) -> bool:
    """Deterministic scope match: surface path-prefix against the finding's
    fingerprint path, or surface route substring against path/title."""
    path = normalize_path(finding.fingerprint_inputs.get("path", ""))
    haystack = f"{path} {finding.title}"
    for surface in scope.surfaces:
        if any(path.startswith(prefix) for prefix in surface.paths):
            return True
        if any(route and route in haystack for route in surface.routes):
            return True
    return scope.default_in_scope
