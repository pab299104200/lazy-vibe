"""Per-product theme vocabulary (spec §4.1).

Unmapped themes become `_candidate:<slug>` entries; the reconcile report
flags them and the readiness predicate treats in-scope candidates as
untriaged (spec §12) so vocabulary gaps cannot leak findings.
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

from .model import RegisterError

_SLUG_RE = re.compile(r"[^a-z0-9]+")


def slugify(raw: str) -> str:
    return _SLUG_RE.sub("_", raw.strip().lower()).strip("_")


def load_vocabulary(path: Path) -> dict[str, list[str]]:
    """Load themes.yaml -> {theme_slug: [lowercase substring patterns]}."""
    if not path.exists():
        raise RegisterError(
            f"theme vocabulary not found: {path} — create themes.yaml with the "
            f"product's theme slugs (spec §4.1)")
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("themes"), dict):
        raise RegisterError(f"{path}: expected a top-level 'themes' mapping")
    vocab: dict[str, list[str]] = {}
    for raw_slug, spec in data["themes"].items():
        slug = slugify(str(raw_slug))
        if not slug:
            raise RegisterError(
                f"{path}: theme key {raw_slug!r} slugifies to an empty slug — "
                f"use a key with at least one alphanumeric character")
        if spec is not None and not isinstance(spec, dict):
            raise RegisterError(
                f"{path}: theme '{raw_slug}' must be a mapping (or empty), "
                f"got {spec!r}")
        patterns = (spec or {}).get("patterns", [])
        if not isinstance(patterns, list):
            raise RegisterError(
                f"{path}: theme '{raw_slug}': 'patterns' must be a list of "
                f"strings, got {patterns!r}")
        for pattern in patterns:
            if not isinstance(pattern, str) or not pattern.strip():
                raise RegisterError(
                    f"{path}: theme '{raw_slug}': pattern {pattern!r} must be "
                    f"a non-empty string — an empty pattern would match every "
                    f"theme and bypass the _candidate safety net")
        vocab[slug] = [p.lower() for p in patterns]
    return vocab


def map_theme(raw: str, vocab: dict[str, list[str]]) -> str:
    if raw.startswith("_candidate:"):
        return raw
    slug = slugify(raw)
    if slug in vocab:
        return slug
    lowered = raw.lower()
    for theme, patterns in vocab.items():
        if any(p in lowered for p in patterns):
            return theme
    return f"_candidate:{slug}"
