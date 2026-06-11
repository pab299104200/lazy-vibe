"""Stable finding fingerprints and fuzzy-match primitives (spec §4.1, §5)."""
from __future__ import annotations

import hashlib
import re

_LINE_SUFFIX_RE = re.compile(r":[\d,:-]+:?$")
_TOKEN_RE = re.compile(r"[a-z0-9]+")


def normalize_path(raw: str) -> str:
    path = raw.strip()
    path = _LINE_SUFFIX_RE.sub("", path)
    if path.startswith("./"):
        path = path[2:]
    return path


def compute(category: str, theme: str, path: str, symbol: str = "-") -> str:
    payload = "\x00".join((category, theme, normalize_path(path), symbol))
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]
    return f"sha256:{digest}"


def title_tokens(title: str) -> set[str]:
    return set(_TOKEN_RE.findall(title.lower()))


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 0.0
    return len(a & b) / len(a | b)
