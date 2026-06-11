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
    for slug, spec in data["themes"].items():
        patterns = (spec or {}).get("patterns", [])
        vocab[slugify(slug)] = [p.lower() for p in patterns]
    return vocab


def map_theme(raw: str, vocab: dict[str, list[str]]) -> str:
    slug = slugify(raw)
    if slug in vocab:
        return slug
    lowered = raw.lower()
    for theme, patterns in vocab.items():
        if any(p in lowered for p in patterns):
            return theme
    return f"_candidate:{slug}"
