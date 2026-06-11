# Register Core (Plan 1 of 3): Register Module + Reconciler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the persistent findings register and deterministic reconciler (spec §4–§5, rollout steps 1–2) so audit runs diff against adjudicated history instead of starting fresh.

**Architecture:** A new stdlib+PyYAML Python package `lazy_vibe/register/` — data model with validated disposition state machine, git-committed JSONL store with generated markdown view, blocker-ledger ingest, and a reconciler that classifies every incoming blocker as suppressed / merged / regressed / new. CLI via `python -m lazy_vibe.register`. Triage pipeline, readiness predicate, and differential mode are Plans 2–3.

**Tech Stack:** Python 3.12, stdlib (`json`, `hashlib`, `csv`, `fcntl`, `argparse`, `dataclasses`), PyYAML (already installed system-wide), pytest.

**Spec:** `docs/superpowers/specs/2026-06-11-register-core-design.md` — §4 (register), §5 (reconciler), §12 (error handling), §13 (testing), §14 steps 1–2.

**Working conventions for this repo:** no pyproject/requirements file exists; code must run with system python3. New pytest tests live under `tests/register/`. Run tests from the repo root: `python3 -m pytest tests/register -v`.

## File Structure

```
lazy_vibe/register/
├── __init__.py        # public API re-exports
├── model.py           # Finding dataclass, Severity/Disposition enums, validation, JSON (de)serialization
├── transitions.py     # disposition state machine with guards (spec §4.2)
├── fingerprint.py     # path normalization, fingerprint hash, title tokens, Jaccard similarity
├── themes.py          # themes.yaml vocabulary loading + theme mapping
├── store.py           # RegisterStore: locked atomic JSONL persistence, ID allocation, register.md rendering
├── ingest.py          # blocker-ledger TSV → candidates JSON
├── reconcile.py       # matching engine + reconcile-report.md rendering
├── cli.py             # argparse CLI: ingest / reconcile / backfill / report
└── __main__.py        # python -m lazy_vibe.register entry point

tests/register/
├── __init__.py
├── helpers.py         # shared test helpers (history-invariant setup)
├── test_model.py
├── test_transitions.py
├── test_fingerprint.py
├── test_themes.py
├── test_store.py
├── test_ingest.py
├── test_reconcile.py
└── test_cli_end_to_end.py
```

---

### Task 1: Data model (`model.py`)

**Files:**
- Create: `lazy_vibe/register/__init__.py`
- Create: `lazy_vibe/register/model.py`
- Create: `tests/register/__init__.py`
- Test: `tests/register/test_model.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/__init__.py` (empty) and `tests/register/test_model.py`:

```python
import pytest

from lazy_vibe.register.model import Finding, RegisterError


def make_finding(**overrides):
    base = dict(
        finding_id="R-0001",
        fingerprint="sha256:8c1f0b2a9d4e6f31",
        fingerprint_inputs={
            "category": "product_gap",
            "theme": "tenant_scope_missing",
            "path": "backend/routers/evidence.py",
            "symbol": "-",
        },
        title="Evidence list endpoint not tenant-scoped",
        description="GET /api/evidence returns rows for all accounts.",
        severity="P1",
        severity_source="proposed",
        taxonomy="S",
        in_scope=True,
        disposition="new",
        disposition_by="ingest",
        disposition_reason="created from run 2026-06-10-1402",
        evidence=[{"type": "code", "ref": "backend/routers/evidence.py:118",
                   "run_id": "2026-06-10-1402"}],
        first_seen={"run_id": "2026-06-10-1402", "date": "2026-06-10"},
        last_seen={"run_id": "2026-06-10-1402", "date": "2026-06-10"},
    )
    base.update(overrides)
    return Finding(**base)


def test_round_trip_json():
    f = make_finding()
    line = f.to_json_line()
    assert "\n" not in line
    g = Finding.from_json_line(line)
    assert g == f


def test_validate_rejects_bad_severity():
    with pytest.raises(RegisterError, match="severity"):
        make_finding(severity="P9").validate()


def test_validate_rejects_bad_finding_id():
    with pytest.raises(RegisterError, match="finding_id"):
        make_finding(finding_id="X-1").validate()


def test_validate_rejects_unknown_disposition():
    with pytest.raises(RegisterError, match="disposition"):
        make_finding(disposition="mitigated").validate()


def test_fixed_requires_regression_test():
    f = make_finding(disposition="fixed", regression_test=None)
    with pytest.raises(RegisterError, match="regression_test"):
        f.validate()
    make_finding(disposition="fixed",
                 regression_test="tests/test_evidence.py::test_tenant_scope").validate()


def test_risk_accepted_requires_review_by():
    f = make_finding(disposition="risk_accepted", disposition_by="pete")
    with pytest.raises(RegisterError, match="review_by"):
        f.validate()
    make_finding(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-09-01").validate()


def test_taxonomy_accepts_acceptance_and_rc_codes():
    make_finding(taxonomy="F-SILENT").validate()
    make_finding(taxonomy="RC-3").validate()
    with pytest.raises(RegisterError, match="taxonomy"):
        make_finding(taxonomy="Z").validate()


def test_fingerprint_inputs_must_be_complete():
    with pytest.raises(RegisterError, match="fingerprint_inputs"):
        make_finding(fingerprint_inputs={"category": "x"}).validate()


def test_from_json_line_reports_line_number_on_corrupt_input():
    with pytest.raises(RegisterError, match="line 7"):
        Finding.from_json_line("{not json", lineno=7)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_model.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'lazy_vibe.register'`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/__init__.py`:

```python
"""Persistent findings register (lazy-vibe v3 register core, spec §4-§5)."""
```

Create `lazy_vibe/register/model.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_model.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/__init__.py lazy_vibe/register/model.py tests/register/__init__.py tests/register/test_model.py
git commit -m "feat(register): add Finding data model with validation"
```

---

### Task 2: Disposition state machine (`transitions.py`)

**Files:**
- Create: `lazy_vibe/register/transitions.py`
- Test: `tests/register/test_transitions.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_transitions.py`:

```python
import pytest

from lazy_vibe.register.model import Disposition
from lazy_vibe.register.transitions import TransitionError, reaffirm_risk, transition
from tests.register.test_model import make_finding

NOW = "2026-06-11T10:00:00+00:00"


def t(finding, to, by="pete", reason="because", **kw):
    transition(finding, Disposition(to), by=by, reason=reason, now=NOW, **kw)


def test_new_to_open_requires_verified_and_authority():
    f = make_finding()
    with pytest.raises(TransitionError, match="verified"):
        t(f, "open", by="policy:p0-security-in-scope")
    with pytest.raises(TransitionError, match="authority"):
        t(f, "open", by="agent:auditor", verified=True)
    t(f, "open", by="policy:p0-security-in-scope", verified=True)
    assert f.disposition == "open"
    assert f.history[-1]["event"] == "disposition"
    assert f.history[-1]["from"] == "new"
    assert f.history[-1]["to"] == "open"
    assert f.history[-1]["by"] == "policy:p0-security-in-scope"


def test_new_to_risk_accepted_is_pete_only_and_needs_review_by():
    f = make_finding()
    with pytest.raises(TransitionError, match="pete"):
        t(f, "risk_accepted", by="policy:dev-dep-low-cve", review_by="2026-09-01")
    f2 = make_finding()
    with pytest.raises(TransitionError, match="review_by"):
        t(f2, "risk_accepted", by="pete")
    f3 = make_finding()
    t(f3, "risk_accepted", by="pete", review_by="2026-09-01")
    assert f3.review_by == "2026-09-01"
    f4 = make_finding()
    with pytest.raises(TransitionError, match="ISO date"):
        t(f4, "risk_accepted", by="pete", review_by="next quarter")


def test_in_remediation_to_fixed_requires_regression_test():
    f = make_finding(disposition="open")
    t(f, "in_remediation", by="harness")
    with pytest.raises(TransitionError, match="regression_test"):
        t(f, "fixed", by="harness")
    t(f, "fixed", by="harness",
      regression_test="tests/test_evidence.py::test_tenant_scope")
    assert f.regression_test == "tests/test_evidence.py::test_tenant_scope"


def test_fixed_to_regressed_is_reconciler_only():
    f = make_finding(disposition="fixed",
                     regression_test="tests/test_x.py::test_y")
    with pytest.raises(TransitionError, match="authority"):
        t(f, "regressed", by="pete")
    t(f, "regressed", by="reconciler")
    assert f.disposition == "regressed"


def test_protected_states_reopen_pete_only():
    fp = make_finding(disposition="false_positive", disposition_by="pete")
    with pytest.raises(TransitionError, match="authority"):
        t(fp, "open", by="policy:anything", verified=True)
    t(fp, "open", by="pete", verified=True)

    ra = make_finding(disposition="risk_accepted", disposition_by="pete",
                      review_by="2026-09-01")
    with pytest.raises(TransitionError, match="authority"):
        t(ra, "open", by="agent:verifier", verified=True)
    t(ra, "open", by="pete", verified=True)


def test_illegal_transition_rejected():
    f = make_finding()  # new
    with pytest.raises(TransitionError, match="no transition"):
        t(f, "fixed", by="pete", regression_test="tests/test_x.py::test_y")


def test_reaffirm_risk_updates_review_by_with_history():
    f = make_finding(disposition="risk_accepted", disposition_by="pete",
                     review_by="2026-06-01")
    reaffirm_risk(f, review_by="2026-12-01", by="pete", now=NOW,
                  reason="customer launch slipped")
    assert f.review_by == "2026-12-01"
    assert f.history[-1]["event"] == "risk_reaffirmed"
    assert f.history[-1]["reason"] == "customer launch slipped"
    with pytest.raises(TransitionError, match="pete"):
        reaffirm_risk(f, review_by="2027-01-01", by="policy:x", now=NOW,
                      reason="customer launch slipped")
    g = make_finding()  # not risk_accepted
    with pytest.raises(TransitionError, match="risk_accepted"):
        reaffirm_risk(g, review_by="2027-01-01", by="pete", now=NOW,
                      reason="customer launch slipped")
    h = make_finding(disposition="risk_accepted", disposition_by="pete",
                     review_by="2026-06-01")
    with pytest.raises(TransitionError, match="ISO date"):
        reaffirm_risk(h, review_by="whenever", by="pete", now=NOW,
                      reason="x")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_transitions.py -v`
Expected: FAIL with `ModuleNotFoundError` (no `transitions` module)

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/transitions.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_transitions.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/transitions.py tests/register/test_transitions.py
git commit -m "feat(register): add guarded disposition state machine"
```

---

### Task 3: Fingerprinting (`fingerprint.py`)

**Files:**
- Create: `lazy_vibe/register/fingerprint.py`
- Test: `tests/register/test_fingerprint.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_fingerprint.py`:

```python
from lazy_vibe.register.fingerprint import (compute, jaccard, normalize_path,
                                            title_tokens)


def test_normalize_path_strips_line_suffix_and_dot_prefix():
    assert normalize_path("./backend/routers/evidence.py:118") == \
        "backend/routers/evidence.py"
    assert normalize_path("backend/routers/evidence.py") == \
        "backend/routers/evidence.py"
    assert normalize_path("  backend/x.py:12-40 ") == "backend/x.py"
    assert normalize_path("backend/x.py:118:") == "backend/x.py"
    assert normalize_path("x.py:12:34") == "x.py"
    assert normalize_path("x.py:abc") == "x.py:abc"  # not a line ref


def test_compute_is_stable_and_text_independent():
    a = compute("product_gap", "tenant_scope_missing",
                "./backend/routers/evidence.py:118", "-")
    b = compute("product_gap", "tenant_scope_missing",
                "backend/routers/evidence.py", "-")
    assert a == b
    assert a.startswith("sha256:")
    assert len(a) == len("sha256:") + 16


def test_compute_differs_on_any_input():
    base = compute("product_gap", "tenant_scope_missing", "backend/x.py", "-")
    assert compute("evidence_gap", "tenant_scope_missing", "backend/x.py", "-") != base
    assert compute("product_gap", "other_theme", "backend/x.py", "-") != base
    assert compute("product_gap", "tenant_scope_missing", "backend/y.py", "-") != base
    assert compute("product_gap", "tenant_scope_missing", "backend/x.py", "f") != base


def test_compute_resists_delimiter_injection():
    assert compute("a|b", "c", "d", "-") != compute("a", "b|c", "d", "-")


def test_title_tokens_normalizes():
    assert title_tokens("Evidence list endpoint NOT tenant-scoped!") == \
        {"evidence", "list", "endpoint", "not", "tenant", "scoped"}


def test_jaccard():
    assert jaccard({"a", "b"}, {"a", "b"}) == 1.0
    assert jaccard({"a", "b"}, {"c", "d"}) == 0.0
    assert jaccard({"a", "b", "c"}, {"b", "c", "d"}) == 0.5
    assert jaccard(set(), set()) == 0.0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_fingerprint.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/fingerprint.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_fingerprint.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/fingerprint.py tests/register/test_fingerprint.py
git commit -m "feat(register): add stable fingerprints and fuzzy-match primitives"
```

---

### Task 4: Theme vocabulary (`themes.py`)

**Files:**
- Create: `lazy_vibe/register/themes.py`
- Test: `tests/register/test_themes.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_themes.py`:

```python
import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.themes import load_vocabulary, map_theme

VOCAB_YAML = """\
themes:
  tenant_scope_missing:
    patterns: ["tenant scope", "account_id filter", "cross-tenant"]
  browser_evidence_missing:
    patterns: ["browser proof", "playwright evidence"]
  rls_ssot_stale:
    patterns: []
"""


@pytest.fixture
def vocab(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text(VOCAB_YAML)
    return load_vocabulary(path)


def test_exact_slug_match(vocab):
    assert map_theme("tenant_scope_missing", vocab) == "tenant_scope_missing"
    assert map_theme("RLS_SSOT_STALE", vocab) == "rls_ssot_stale"


def test_pattern_match(vocab):
    assert map_theme("missing browser proof for journey", vocab) == \
        "browser_evidence_missing"
    assert map_theme("query lacks account_id filter", vocab) == \
        "tenant_scope_missing"


def test_unmapped_becomes_candidate(vocab):
    assert map_theme("Quantum Flux Capacitor!", vocab) == \
        "_candidate:quantum_flux_capacitor"


def test_missing_vocabulary_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="themes.yaml"):
        load_vocabulary(tmp_path / "themes.yaml")


def test_malformed_vocabulary_is_hard_error(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("just a string")
    with pytest.raises(RegisterError, match="themes"):
        load_vocabulary(path)


def test_empty_pattern_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text('themes:\n  foo:\n    patterns: [""]\n')
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_non_string_pattern_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    patterns: [123]\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_patterns_must_be_list(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    patterns: tenant scope\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_theme_node_must_be_mapping(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    - a\n    - b\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_empty_slug_key_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text('themes:\n  "!!!":\n    patterns: []\n')
    with pytest.raises(RegisterError, match="slug"):
        load_vocabulary(path)


def test_candidate_theme_is_idempotent(vocab):
    c = map_theme("Quantum Flux Capacitor!", vocab)
    assert map_theme(c, vocab) == c
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_themes.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/themes.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_themes.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/themes.py tests/register/test_themes.py
git commit -m "feat(register): add theme vocabulary with candidate fallback"
```

---

### Task 5: Persistent store (`store.py`)

**Integrity requirement (from Task 2 code review, strengthened in quality
review):** `Finding` is a mutable dataclass, so `transitions.transition()`
alone is advisory — any caller could reassign `finding.disposition` directly.
The store is the wall: `save()` and `load()` validate the full disposition
history chain — it must start from `new`, every edge must be in
`transitions.LEGAL_EDGES`, each event must continue where the previous left
off, and the final event must match the current disposition (a finding with
no disposition events must be `new`). This makes the git-committed history
the verifiable source of truth (spec §4.3). The check proves internal
consistency, not provenance — git history and `transition()` own that.

**Files:**
- Create: `lazy_vibe/register/store.py`
- Create: `tests/register/helpers.py`
- Test: `tests/register/test_store.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/helpers.py`:

```python
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
```

Create `tests/register/test_store.py`:

```python
import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def test_load_empty_register(store):
    assert store.load() == {}


def test_save_and_load_round_trip(store):
    f1 = make_finding()
    f2 = make_finding(finding_id="R-0002", fingerprint="sha256:aaaaaaaaaaaaaaaa",
                      title="Other finding")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    loaded = store.load()
    assert set(loaded) == {"R-0001", "R-0002"}
    assert loaded["R-0001"] == f1


def test_save_creates_directory_and_markdown(store):
    f = make_finding()
    store.save({f.finding_id: f})
    assert store.jsonl_path.exists()
    md = store.markdown_path.read_text()
    assert "generated" in md.lower()
    assert "R-0001" in md
    assert "Evidence list endpoint not tenant-scoped" in md


def test_corrupt_line_is_hard_error_with_line_number(store):
    f = make_finding()
    store.save({f.finding_id: f})
    with store.jsonl_path.open("a") as fh:
        fh.write("{broken\n")
    with pytest.raises(RegisterError, match="line 2"):
        store.load()


def test_next_id(store):
    assert store.next_id({}) == "R-0001"
    f = make_finding(finding_id="R-0041")
    assert store.next_id({f.finding_id: f}) == "R-0042"


def test_by_fingerprint_index(store):
    f = make_finding()
    store.save({f.finding_id: f})
    findings = store.load()
    index = store.by_fingerprint(findings)
    assert index["sha256:8c1f0b2a9d4e6f31"].finding_id == "R-0001"


def test_markdown_groups_by_disposition_and_severity(store):
    f_open = with_history(make_finding(finding_id="R-0001",
                                       fingerprint="sha256:aaaaaaaaaaaaaaa1",
                                       disposition="open", severity="P1"))
    f_open_p0 = with_history(make_finding(finding_id="R-0002",
                                          fingerprint="sha256:aaaaaaaaaaaaaaa2",
                                          disposition="open", severity="P0"))
    f_parked = with_history(make_finding(finding_id="R-0003",
                                         fingerprint="sha256:aaaaaaaaaaaaaaa3",
                                         disposition="parked"))
    store.save({f.finding_id: f for f in (f_open, f_open_p0, f_parked)})
    md = store.markdown_path.read_text()
    assert md.index("## open") < md.index("## parked")
    # P0 row renders before P1 row within the open section
    assert md.index("R-0002") < md.index("R-0001")


def test_save_rejects_disposition_without_matching_history(store):
    smuggled = make_finding(disposition="open")  # no disposition event
    with pytest.raises(RegisterError, match="history"):
        store.save({smuggled.finding_id: smuggled})


def test_save_rejects_disposition_contradicting_history(store):
    f = with_history(make_finding(disposition="open"))
    f.disposition = "fixed"  # mutated around transition()
    f.regression_test = "tests/test_x.py::test_y"
    with pytest.raises(RegisterError, match="history"):
        store.save({f.finding_id: f})


def test_load_rejects_hand_edited_disposition(store):
    f = with_history(make_finding(disposition="open"))
    store.save({f.finding_id: f})
    text = store.jsonl_path.read_text().replace('"disposition": "open"',
                                                '"disposition": "parked"')
    store.jsonl_path.write_text(text)
    with pytest.raises(RegisterError, match="history"):
        store.load()


def test_save_rejects_illegal_history_edge(store):
    f = make_finding(disposition="fixed",
                     regression_test="tests/test_x.py::test_y")
    f.history.append({"ts": "t", "event": "disposition", "from": "new",
                      "to": "fixed", "by": "x", "reason": "fabricated"})
    with pytest.raises(RegisterError, match="illegal edge"):
        store.save({f.finding_id: f})


def test_save_rejects_broken_history_chain(store):
    f = make_finding(disposition="in_remediation")
    f.history.append({"ts": "t", "event": "disposition", "from": "open",
                      "to": "in_remediation", "by": "x", "reason": "no start"})
    with pytest.raises(RegisterError, match="chain"):
        store.save({f.finding_id: f})


def test_markdown_escapes_pipes_and_newlines(store):
    f = make_finding(title="SQLi in users | OR 1=1")
    store.save({f.finding_id: f})
    md = store.markdown_path.read_text()
    assert "SQLi in users \\| OR 1=1" in md


def test_save_seeds_gitignore(store):
    f = make_finding()
    store.save({f.finding_id: f})
    gi = (store.register_dir / ".gitignore").read_text()
    assert ".register.lock" in gi and "*.tmp" in gi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_store.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/store.py`:

```python
"""Locked, atomic JSONL persistence + generated markdown view (spec §4.3)."""
from __future__ import annotations

import fcntl
import os
import re
from contextlib import contextmanager
from pathlib import Path

from .model import SEVERITY_ORDER, Disposition, Finding, RegisterError
from .transitions import LEGAL_EDGES

_DISPOSITION_RENDER_ORDER = ("regressed", "open", "in_remediation", "new",
                             "risk_accepted", "parked", "fixed", "false_positive")

_CELL_BREAK_RE = re.compile(r"[\r\n]+")

_GITIGNORE_SEED = ".register.lock\n*.tmp\n"


def markdown_cell(text: str) -> str:
    """Escape free text for a single-line markdown table cell."""
    return _CELL_BREAK_RE.sub(" ", text).replace("|", "\\|")


def _check_history_invariant(finding: Finding) -> None:
    """Persistence-boundary integrity wall (spec §4.3).

    Proves internal consistency of the disposition-event chain: it must
    start from 'new', every edge must be legal per the state machine,
    each event must continue where the previous left off, and the final
    event must match the current disposition. It does NOT prove
    provenance — git history and transitions.transition() own that;
    whoever can fabricate a coherent chain can also rewrite git.
    """
    events = [h for h in finding.history if h.get("event") == "disposition"]
    if not events:
        if finding.disposition != "new":
            raise RegisterError(
                f"{finding.finding_id}: disposition {finding.disposition!r} has no "
                f"matching disposition history event — disposition changes must go "
                f"through transitions.transition()")
        return
    prev = "new"
    for event in events:
        src, dst = event.get("from"), event.get("to")
        if src != prev:
            raise RegisterError(
                f"{finding.finding_id}: disposition history chain broken — event "
                f"from {src!r} does not follow {prev!r}")
        try:
            edge = (Disposition(src), Disposition(dst))
        except ValueError:
            raise RegisterError(
                f"{finding.finding_id}: disposition history contains unknown "
                f"state in edge {src!r} -> {dst!r}") from None
        if edge not in LEGAL_EDGES:
            raise RegisterError(
                f"{finding.finding_id}: disposition history contains illegal "
                f"edge {src!r} -> {dst!r}")
        prev = dst
    if prev != finding.disposition:
        raise RegisterError(
            f"{finding.finding_id}: disposition {finding.disposition!r} does "
            f"not match last history event {prev!r} — disposition changes "
            f"must go through transitions.transition()")


class RegisterStore:
    """Atomic JSONL register persistence with a generated markdown view.

    Locking contract: ``load()`` and ``save()`` are individually lock-free.
    Any read-modify-write sequence (load, mutate, save) must be wrapped in
    ``locked()`` to serialize against concurrent writers; the atomic rename
    in ``save()`` only protects readers from torn files, not lost updates.
    """

    def __init__(self, register_dir: Path):
        self.register_dir = Path(register_dir)
        self.jsonl_path = self.register_dir / "register.jsonl"
        self.markdown_path = self.register_dir / "register.md"
        self.lock_path = self.register_dir / ".register.lock"

    @contextmanager
    def locked(self):
        self.register_dir.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)

    def load(self) -> dict[str, Finding]:
        if not self.jsonl_path.exists():
            return {}
        findings: dict[str, Finding] = {}
        with self.jsonl_path.open() as fh:
            for lineno, line in enumerate(fh, start=1):
                if not line.strip():
                    continue
                finding = Finding.from_json_line(line, lineno=lineno)
                _check_history_invariant(finding)
                if finding.finding_id in findings:
                    raise RegisterError(
                        f"duplicate finding_id {finding.finding_id} at line {lineno}")
                findings[finding.finding_id] = finding
        return findings

    def save(self, findings: dict[str, Finding]) -> None:
        self.register_dir.mkdir(parents=True, exist_ok=True)
        gitignore = self.register_dir / ".gitignore"
        if not gitignore.exists():
            gitignore.write_text(_GITIGNORE_SEED)
        ordered = sorted(findings.values(), key=lambda f: f.finding_id)
        for finding in ordered:
            finding.validate()
            _check_history_invariant(finding)
        tmp = self.jsonl_path.with_suffix(".jsonl.tmp")
        with tmp.open("w") as fh:
            for finding in ordered:
                fh.write(finding.to_json_line() + "\n")
        os.replace(tmp, self.jsonl_path)
        self.write_markdown(findings)

    def write_markdown(self, findings: dict[str, Finding]) -> None:
        """Atomically regenerate register.md from the given findings."""
        tmp = self.markdown_path.with_suffix(".md.tmp")
        tmp.write_text(self.render_markdown(findings))
        os.replace(tmp, self.markdown_path)

    @staticmethod
    def next_id(findings: dict[str, Finding]) -> str:
        highest = max((int(fid.split("-")[1]) for fid in findings), default=0)
        return f"R-{highest + 1:04d}"

    @staticmethod
    def by_fingerprint(findings: dict[str, Finding]) -> dict[str, Finding]:
        return {f.fingerprint: f for f in findings.values()}

    @staticmethod
    def render_markdown(findings: dict[str, Finding]) -> str:
        lines = ["# Findings Register",
                 "",
                 "<!-- generated by lazy_vibe.register — do not edit by hand -->",
                 ""]
        by_disposition: dict[str, list[Finding]] = {}
        for finding in findings.values():
            by_disposition.setdefault(finding.disposition, []).append(finding)
        for disposition in _DISPOSITION_RENDER_ORDER:
            group = by_disposition.get(disposition)
            if not group:
                continue
            group.sort(key=lambda f: (SEVERITY_ORDER[f.severity], f.finding_id))
            lines += [f"## {disposition} ({len(group)})", "",
                      "| id | sev | scope | taxonomy | title | last seen | by |",
                      "|---|---|---|---|---|---|---|"]
            for f in group:
                scope = "in" if f.in_scope else "out"
                lines.append(
                    f"| {f.finding_id} | {f.severity} | {scope} | {f.taxonomy} "
                    f"| {markdown_cell(f.title)} | {f.last_seen.get('date', '-')} "
                    f"| {f.disposition_by} |")
            lines.append("")
        return "\n".join(lines)
```

Also add to `lazy_vibe/register/transitions.py`, after the `_TRANSITIONS`
dict: `LEGAL_EDGES = frozenset(_TRANSITIONS)` (the store imports it for
chain validation).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_store.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/store.py lazy_vibe/register/transitions.py \
        tests/register/helpers.py tests/register/test_store.py
git commit -m "feat(register): add locked atomic JSONL store with markdown view"
```

---

### Task 6: Blocker-ledger ingest (`ingest.py`)

The blocker ledger produced by `run-remediation.sh` (line 2717) is a TSV with
exactly these columns: `blocker_id  category  theme  severity  group
model_class  finding_count  representative_source  representative_line
representative_title  raw_px_ids  references`.

**Files:**
- Create: `lazy_vibe/register/ingest.py`
- Test: `tests/register/test_ingest.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_ingest.py`:

```python
import json

import pytest

from lazy_vibe.register.ingest import (Candidate, parse_ledger,
                                       read_candidates, write_candidates)
from lazy_vibe.register.model import RegisterError

HEADER = ("blocker_id\tcategory\ttheme\tseverity\tgroup\tmodel_class\t"
          "finding_count\trepresentative_source\trepresentative_line\t"
          "representative_title\traw_px_ids\treferences\n")

ROW1 = ("B-0001\tproduct_gap\ttenant_scope_missing\tP1\tW1\tstandard\t3\t"
        "backend/routers/evidence.py\t118\t"
        "Evidence list endpoint not tenant-scoped\tP1-0001,P1-0007\t"
        "backend/routers/evidence.py:118,artifacts/02a.md\n")

ROW2 = ("B-0002\tevidence_gap\tbrowser_evidence_missing\tP2\tW2\tstandard\t1\t"
        "docs/ux/journeys.md\t-\tNo browser proof for evidence journey\t"
        "P2-0004\tartifacts/07-customer-simulation.md\n")


@pytest.fixture
def ledger(tmp_path):
    path = tmp_path / "00-blocker-ledger.tsv"
    path.write_text(HEADER + ROW1 + ROW2)
    return path


def test_parse_ledger(ledger):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    assert len(candidates) == 2
    c = candidates[0]
    assert c == Candidate(
        blocker_id="B-0001",
        category="product_gap",
        theme_raw="tenant_scope_missing",
        severity="P1",
        path="backend/routers/evidence.py",
        line="118",
        title="Evidence list endpoint not tenant-scoped",
        references="backend/routers/evidence.py:118,artifacts/02a.md",
        run_id="2026-06-10-1402",
    )


def test_parse_ledger_rejects_wrong_header(tmp_path):
    path = tmp_path / "bad.tsv"
    path.write_text("a\tb\tc\n1\t2\t3\n")
    with pytest.raises(RegisterError, match="header"):
        parse_ledger(path, run_id="x")


def test_parse_ledger_rejects_bad_severity(tmp_path):
    path = tmp_path / "bad-sev.tsv"
    path.write_text(HEADER + ROW1.replace("\tP1\t", "\tP9\t", 1))
    with pytest.raises(RegisterError, match="severity"):
        parse_ledger(path, run_id="x")


def test_parse_ledger_missing_file(tmp_path):
    with pytest.raises(RegisterError, match="ledger"):
        parse_ledger(tmp_path / "nope.tsv", run_id="x")


def test_parse_ledger_handles_leading_quote_in_title(tmp_path):
    row = ROW1.replace("Evidence list endpoint not tenant-scoped",
                       '"eval" is dangerous in evidence parser')
    path = tmp_path / "quoted.tsv"
    path.write_text(HEADER + row + ROW2)
    candidates = parse_ledger(path, run_id="x")
    assert len(candidates) == 2
    assert candidates[0].title == '"eval" is dangerous in evidence parser'


def test_write_candidates_round_trip(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    out = tmp_path / "register-candidates.json"
    write_candidates(candidates, out, run_id="2026-06-10-1402")
    data = json.loads(out.read_text())
    assert data["run_id"] == "2026-06-10-1402"
    assert len(data["candidates"]) == 2
    assert data["candidates"][0]["blocker_id"] == "B-0001"


def test_read_candidates_round_trip(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="2026-06-10-1402")
    out = tmp_path / "register-candidates.json"
    write_candidates(candidates, out, run_id="2026-06-10-1402")
    assert read_candidates(out) == candidates


def test_read_candidates_rejects_corrupt_json(tmp_path):
    path = tmp_path / "c.json"
    path.write_text("{not json")
    with pytest.raises(RegisterError, match="corrupt"):
        read_candidates(path)


def test_read_candidates_rejects_missing_candidates_key(tmp_path):
    path = tmp_path / "c.json"
    path.write_text('{"run_id": "x"}')
    with pytest.raises(RegisterError, match="candidates"):
        read_candidates(path)


def test_read_candidates_rejects_bad_severity(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="x")
    out = tmp_path / "c.json"
    write_candidates(candidates, out, run_id="x")
    path = tmp_path / "tampered.json"
    path.write_text(out.read_text().replace('"P1"', '"P9"'))
    with pytest.raises(RegisterError, match="severity"):
        read_candidates(path)


def test_read_candidates_rejects_missing_field(tmp_path):
    path = tmp_path / "c.json"
    path.write_text('{"run_id": "x", "candidates": [{"blocker_id": "B-0001"}]}')
    with pytest.raises(RegisterError, match="candidate 0"):
        read_candidates(path)


def test_read_candidates_rejects_run_id_mismatch(ledger, tmp_path):
    candidates = parse_ledger(ledger, run_id="x")
    out = tmp_path / "c.json"
    write_candidates(candidates, out, run_id="x")
    path = tmp_path / "tampered.json"
    path.write_text(out.read_text().replace('"run_id": "x"', '"run_id": "y"', 1))
    with pytest.raises(RegisterError, match="run_id"):
        read_candidates(path)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_ingest.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/ingest.py`:

```python
"""Blocker-ledger TSV -> reconcile candidates (spec §5, §11).

``parse_ledger`` is the untrusted-harness boundary; ``read_candidates`` reads
a regenerable intermediate but enforces the same invariants.
"""
from __future__ import annotations

import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path

from .model import SEVERITY_ORDER, RegisterError

EXPECTED_HEADER = ["blocker_id", "category", "theme", "severity", "group",
                   "model_class", "finding_count", "representative_source",
                   "representative_line", "representative_title",
                   "raw_px_ids", "references"]


@dataclass(frozen=True)
class Candidate:
    blocker_id: str
    category: str
    theme_raw: str
    severity: str
    path: str
    line: str
    title: str
    references: str
    run_id: str


def _validate_severity(value: str, where: str) -> None:
    if value not in SEVERITY_ORDER:
        raise RegisterError(f"{where}: invalid severity {value!r}")


def parse_ledger(path: Path, *, run_id: str) -> list[Candidate]:
    if not path.exists():
        raise RegisterError(f"blocker ledger not found: {path}")
    with path.open(newline="") as fh:
        # QUOTE_NONE: the ledger is awk-generated plain TSV, not RFC 4180 —
        # a literal leading '"' in a field must not trigger quote parsing.
        reader = csv.reader(fh, delimiter="\t", quoting=csv.QUOTE_NONE)
        try:
            header = next(reader)
        except StopIteration:
            raise RegisterError(f"{path}: empty ledger") from None
        if header != EXPECTED_HEADER:
            raise RegisterError(
                f"{path}: unexpected ledger header {header!r}; "
                f"expected {EXPECTED_HEADER!r}")
        candidates = []
        for lineno, row in enumerate(reader, start=2):
            if not row or not any(field.strip() for field in row):
                continue
            if len(row) != len(EXPECTED_HEADER):
                raise RegisterError(f"{path}: line {lineno}: expected "
                                    f"{len(EXPECTED_HEADER)} columns, got {len(row)}")
            record = dict(zip(EXPECTED_HEADER, row))
            _validate_severity(record["severity"], f"{path}: line {lineno}")
            candidates.append(Candidate(
                blocker_id=record["blocker_id"],
                category=record["category"],
                theme_raw=record["theme"],
                severity=record["severity"],
                path=record["representative_source"],
                line=record["representative_line"],
                title=record["representative_title"],
                references=record["references"],
                run_id=run_id,
            ))
    return candidates


def write_candidates(candidates: list[Candidate], out_path: Path, *,
                     run_id: str) -> None:
    """Idempotently overwrite a derived artifact (intentional asymmetry
    with RegisterStore.save, which guards the durable register)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"run_id": run_id, "candidates": [asdict(c) for c in candidates]}
    out_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def read_candidates(path: Path) -> list[Candidate]:
    if not path.exists():
        raise RegisterError(f"candidates file not found: {path}")
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise RegisterError(f"{path}: corrupt candidates file: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("candidates"), list):
        raise RegisterError(f"{path}: expected a 'candidates' list")
    run_id = data.get("run_id")
    candidates = []
    for index, entry in enumerate(data["candidates"]):
        try:
            candidate = Candidate(**entry)
        except TypeError as exc:
            raise RegisterError(
                f"{path}: candidate {index}: {exc}") from exc
        _validate_severity(candidate.severity, f"{path}: candidate {index}")
        if run_id is not None and candidate.run_id != run_id:
            raise RegisterError(
                f"{path}: candidate {index}: run_id {candidate.run_id!r} "
                f"disagrees with file run_id {run_id!r}")
        candidates.append(candidate)
    return candidates
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_ingest.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/ingest.py tests/register/test_ingest.py
git commit -m "feat(register): parse blocker ledgers into reconcile candidates"
```

---

### Task 7: Reconciler engine (`reconcile.py`)

**Files:**
- Create: `lazy_vibe/register/reconcile.py`
- Test: `tests/register/test_reconcile.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_reconcile.py`:

```python
import pytest

from lazy_vibe.register.fingerprint import compute
from lazy_vibe.register.ingest import Candidate
from lazy_vibe.register.reconcile import reconcile, render_report
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

VOCAB = {"tenant_scope_missing": ["tenant scope"],
         "browser_evidence_missing": ["browser proof"]}
RUN = "2026-06-11-0900"
DATE = "2026-06-11"


def cand(**overrides):
    base = dict(blocker_id="B-0001", category="product_gap",
                theme_raw="tenant_scope_missing", severity="P1",
                path="backend/routers/evidence.py", line="118",
                title="Evidence list endpoint not tenant-scoped",
                references="backend/routers/evidence.py:118", run_id=RUN)
    base.update(overrides)
    return Candidate(**base)


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def existing(**overrides):
    """Register entry whose fingerprint matches cand() exactly.

    Wrapped in with_history so adjudicated dispositions satisfy the
    store's history invariant (see Task 5)."""
    fp = compute("product_gap", "tenant_scope_missing",
                 "backend/routers/evidence.py", "-")
    return with_history(make_finding(fingerprint=fp, **overrides))


def test_no_match_creates_new_finding(store):
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    loaded = store.load()
    f = loaded["R-0001"]
    assert f.disposition == "new"
    assert f.severity == "P1"
    assert f.fingerprint_inputs["theme"] == "tenant_scope_missing"
    assert f.evidence[0]["ref"] == "backend/routers/evidence.py:118"
    assert f.history[0]["event"] == "created"


def test_match_on_protected_disposition_suppresses(store):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.suppressed] == ["R-0001"]
    assert result.new == []
    loaded = store.load()["R-0001"]
    assert loaded.disposition == "risk_accepted"
    assert loaded.occurrences == 2
    assert loaded.last_seen == {"run_id": RUN, "date": DATE}
    assert loaded.history[-1]["event"] == "suppressed_occurrence"


def test_match_on_open_merges_evidence(store):
    f = existing(disposition="open", disposition_by="pete",
                 evidence=[{"type": "code",
                            "ref": "backend/routers/evidence.py:118",
                            "run_id": "old-run"}])
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.merged] == ["R-0001"]
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 2
    refs = {(e["ref"], e["run_id"]) for e in loaded.evidence}
    assert ("backend/routers/evidence.py:118", RUN) in refs
    assert ("backend/routers/evidence.py:118", "old-run") in refs


def test_match_on_fixed_flags_regression(store):
    f = existing(disposition="fixed",
                 regression_test="tests/test_evidence.py::test_tenant_scope")
    store.save({f.finding_id: f})
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert [x.finding_id for x in result.regressed] == ["R-0001"]
    assert store.load()["R-0001"].disposition == "regressed"


def test_higher_proposed_severity_on_adjudicated_entry_queues_review(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="adjudicated")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    loaded = store.load()["R-0001"]
    assert loaded.severity == "P2"  # adjudicated value untouched
    assert loaded.history[-1]["event"] == "severity_review_proposed"
    assert loaded.history[-1]["proposed"] == "P0"


def test_higher_proposed_severity_on_proposed_entry_escalates(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="proposed")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    assert store.load()["R-0001"].severity == "P0"


def test_fuzzy_match_recorded_on_new_entry(store):
    f = existing(disposition="open", disposition_by="pete")
    store.save({f.finding_id: f})
    # Same path + category, different theme -> different fingerprint,
    # title overlaps heavily -> fuzzy candidate.
    c = cand(theme_raw="weird new theme wording",
             title="Evidence list endpoint not scoped to tenant")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert len(result.new) == 1
    new = store.load()[result.new[0].finding_id]
    assert new.history[-1]["event"] == "fuzzy_match_candidate"
    assert new.history[-1]["candidate_of"] == "R-0001"
    assert (result.new[0].finding_id, "R-0001") in result.fuzzy


def test_unmapped_theme_becomes_candidate_theme(store):
    c = cand(theme_raw="totally novel concern")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    f = store.load()[result.new[0].finding_id]
    assert f.fingerprint_inputs["theme"] == "_candidate:totally_novel_concern"
    assert "_candidate:totally_novel_concern" in result.theme_candidates


def test_within_run_duplicate_fingerprint_does_not_double_count(store):
    dup = cand(blocker_id="B-0009", line="240",
               references="backend/routers/evidence.py:240")
    result = reconcile(store, [cand(), dup], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    assert result.merged == []
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 1
    refs = {e["ref"] for e in loaded.evidence}
    assert "backend/routers/evidence.py:118" in refs
    assert "backend/routers/evidence.py:240" in refs


def test_within_run_duplicate_higher_severity_escalates(store):
    dup = cand(blocker_id="B-0009", severity="P0", line="240")
    result = reconcile(store, [cand(), dup], VOCAB, run_id=RUN, date=DATE)
    assert [f.finding_id for f in result.new] == ["R-0001"]
    loaded = store.load()["R-0001"]
    assert loaded.severity == "P0"
    assert loaded.occurrences == 1


def test_replay_does_not_duplicate_severity_review(store):
    f = existing(disposition="open", disposition_by="pete",
                 severity="P2", severity_source="adjudicated")
    store.save({f.finding_id: f})
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    reconcile(store, [cand(severity="P0")], VOCAB, run_id=RUN, date=DATE)
    loaded = store.load()["R-0001"]
    events = [h for h in loaded.history
              if h["event"] == "severity_review_proposed"]
    assert len(events) == 1


def test_reconcile_same_run_is_idempotent(store):
    first = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert len(first.new) == 1
    replay = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert replay.new == [] and replay.merged == []
    assert store.load()["R-0001"].occurrences == 1


def test_replay_does_not_double_suppress(store):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    second = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE)
    assert second.suppressed == []
    loaded = store.load()["R-0001"]
    assert loaded.occurrences == 2  # bumped by the first run only
    events = [h for h in loaded.history if h["event"] == "suppressed_occurrence"]
    assert len(events) == 1


def test_render_report_headline(store, tmp_path):
    f_fixed = existing(disposition="fixed",
                       regression_test="tests/test_evidence.py::test_x")
    store.save({f_fixed.finding_id: f_fixed})
    result = reconcile(
        store,
        [cand(),
         cand(blocker_id="B-0002", category="evidence_gap",
              theme_raw="browser_evidence_missing", severity="P2",
              path="docs/ux/journeys.md", line="-",
              title="No browser proof for evidence journey")],
        VOCAB, run_id=RUN, date=DATE)
    report_path = tmp_path / "reconcile-report.md"
    render_report(result, store.load(), report_path, run_id=RUN)
    text = report_path.read_text()
    assert "1 new, 0 suppressed, 1 regressed" in text
    assert "## Regressions" in text
    assert "## New findings" in text


def test_render_report_shows_fuzzy_duplicate_disposition(store, tmp_path):
    f = existing(disposition="risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    store.save({f.finding_id: f})
    c = cand(theme_raw="weird new theme wording",
             title="Evidence list endpoint not scoped to tenant")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert (result.new[0].finding_id, "R-0001") in result.fuzzy
    report_path = tmp_path / "reconcile-report.md"
    render_report(result, store.load(), report_path, run_id=RUN)
    text = report_path.read_text()
    # Triager must see the duplicate target was adjudicated away.
    assert "R-0001 (risk_accepted)" in text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_reconcile.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/reconcile.py`:

```python
"""Deterministic reconciler: run candidates vs register (spec §5)."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .fingerprint import compute, jaccard, normalize_path, title_tokens
from .ingest import Candidate
from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding)
from .store import RegisterStore, markdown_cell
from .themes import map_theme
from .transitions import transition

FUZZY_THRESHOLD = 0.5

# regressed is deliberately open-like: a re-occurrence merges evidence rather
# than re-flagging — it is already flagged and re-queued.
_OPEN_LIKE = {Disposition.NEW.value, Disposition.OPEN.value,
              Disposition.IN_REMEDIATION.value, Disposition.REGRESSED.value}


@dataclass
class ReconcileResult:
    new: list[Finding] = field(default_factory=list)
    suppressed: list[Finding] = field(default_factory=list)
    merged: list[Finding] = field(default_factory=list)
    regressed: list[Finding] = field(default_factory=list)
    fuzzy: list[tuple[str, str]] = field(default_factory=list)  # (new_id, existing_id)
    theme_candidates: set[str] = field(default_factory=set)


def _now(date: str) -> str:
    return f"{date}T00:00:00+00:00"


def _bump_seen(finding: Finding, run_id: str, date: str) -> None:
    finding.last_seen = {"run_id": run_id, "date": date}
    finding.occurrences += 1


def _merge_evidence(finding: Finding, candidate: Candidate) -> None:
    ref = f"{normalize_path(candidate.path)}:{candidate.line}"
    seen = {(e["ref"], e["run_id"]) for e in finding.evidence}
    if (ref, candidate.run_id) not in seen:
        finding.evidence.append({"type": "audit", "ref": ref,
                                 "run_id": candidate.run_id})


def _review_severity(finding: Finding, candidate: Candidate, date: str) -> None:
    if SEVERITY_ORDER[candidate.severity] >= SEVERITY_ORDER[finding.severity]:
        return  # not higher (P0 is lowest order value)
    if finding.severity_source == "adjudicated":
        already = any(h.get("event") == "severity_review_proposed"
                      and h.get("proposed") == candidate.severity
                      and h.get("run_id") == candidate.run_id
                      for h in finding.history)
        if not already:
            finding.history.append({"ts": _now(date),
                                    "event": "severity_review_proposed",
                                    "current": finding.severity,
                                    "proposed": candidate.severity,
                                    "run_id": candidate.run_id})
    else:
        old = finding.severity
        finding.severity = candidate.severity
        finding.history.append({"ts": _now(date), "event": "severity_escalated",
                                "from": old, "to": candidate.severity,
                                "run_id": candidate.run_id})


def _find_fuzzy(findings: dict[str, Finding], candidate: Candidate) -> Finding | None:
    cand_path = normalize_path(candidate.path)
    cand_tokens = title_tokens(candidate.title)
    best, best_score = None, 0.0
    for finding in findings.values():
        if finding.fingerprint_inputs["path"] != cand_path:
            continue
        if finding.fingerprint_inputs["category"] != candidate.category:
            continue
        score = jaccard(cand_tokens, title_tokens(finding.title))
        if score >= FUZZY_THRESHOLD and score > best_score:
            best, best_score = finding, score
    return best


def _create_finding(findings: dict[str, Finding], candidate: Candidate,
                    theme: str, run_id: str, date: str) -> Finding:
    finding = Finding(
        finding_id=RegisterStore.next_id(findings),
        fingerprint=compute(candidate.category, theme, candidate.path, "-"),
        fingerprint_inputs={"category": candidate.category, "theme": theme,
                            "path": normalize_path(candidate.path), "symbol": "-"},
        title=candidate.title,
        description=f"Imported from {candidate.blocker_id} "
                    f"(run {candidate.run_id}). References: {candidate.references}",
        severity=candidate.severity,
        severity_source="proposed",
        taxonomy="G",  # taxonomy refinement (B/S/A/U/...) is a triage-stage concern (plan 2), like in_scope
        in_scope=True,  # scope matching arrives with launch-scope.yaml (plan 2)
        disposition=Disposition.NEW.value,
        disposition_by="ingest",
        disposition_reason=f"created from run {run_id}",
        first_seen={"run_id": run_id, "date": date},
        last_seen={"run_id": run_id, "date": date},
        history=[{"ts": _now(date), "event": "created", "by": "ingest",
                  "blocker_id": candidate.blocker_id}],
    )
    _merge_evidence(finding, candidate)
    return finding


def reconcile(store: RegisterStore, candidates: list[Candidate],
              vocab: dict[str, list[str]], *, run_id: str,
              date: str) -> ReconcileResult:
    result = ReconcileResult()
    with store.locked():
        findings = store.load()
        index = store.by_fingerprint(findings)
        for candidate in candidates:
            theme = map_theme(candidate.theme_raw, vocab)
            if theme.startswith("_candidate:"):
                result.theme_candidates.add(theme)
            fingerprint = compute(candidate.category, theme, candidate.path, "-")
            existing = index.get(fingerprint)
            if existing is not None:
                if existing.last_seen.get("run_id") == run_id:
                    # Within-run duplicate fingerprint or same-run replay:
                    # record extra evidence and severity signal only — never
                    # double-count occurrences or re-emit report buckets
                    # (replay safety).
                    if existing.disposition in _OPEN_LIKE:
                        _merge_evidence(existing, candidate)
                        _review_severity(existing, candidate, date)
                    continue
                _bump_seen(existing, run_id, date)
                if existing.disposition in {d.value for d in PROTECTED_DISPOSITIONS} \
                        or existing.disposition == Disposition.PARKED.value:
                    existing.history.append({"ts": _now(date),
                                             "event": "suppressed_occurrence",
                                             "run_id": run_id})
                    result.suppressed.append(existing)
                elif existing.disposition == Disposition.FIXED.value:
                    transition(existing, Disposition.REGRESSED, by="reconciler",
                               reason=f"reappeared in run {run_id}", now=_now(date))
                    _merge_evidence(existing, candidate)
                    result.regressed.append(existing)
                elif existing.disposition in _OPEN_LIKE:
                    _merge_evidence(existing, candidate)
                    _review_severity(existing, candidate, date)
                    result.merged.append(existing)
                continue
            fuzzy_hit = _find_fuzzy(findings, candidate)
            new = _create_finding(findings, candidate, theme, run_id, date)
            if fuzzy_hit is not None:
                new.history.append({"ts": _now(date),
                                    "event": "fuzzy_match_candidate",
                                    "candidate_of": fuzzy_hit.finding_id,
                                    "run_id": run_id})
                result.fuzzy.append((new.finding_id, fuzzy_hit.finding_id))
            findings[new.finding_id] = new
            index[new.fingerprint] = new
            result.new.append(new)
        store.save(findings)
    return result


def render_report(result: ReconcileResult, findings: dict[str, Finding],
                  out_path: Path, *, run_id: str) -> None:
    still_open = sorted(
        (f for f in findings.values() if f.disposition in _OPEN_LIKE),
        key=lambda f: (SEVERITY_ORDER[f.severity], f.finding_id))
    lines = [f"# Reconcile Report — run {run_id}", "",
             f"**{len(result.new)} new, {len(result.suppressed)} suppressed, "
             f"{len(result.regressed)} regressed, {len(still_open)} still open**",
             ""]
    if result.regressed:
        lines += ["## Regressions", "",
                  "Previously fixed findings that reappeared — highest signal.", ""]
        for f in result.regressed:
            lines.append(f"- **{f.finding_id}** {f.severity} "
                         f"{markdown_cell(f.title)} "
                         f"(regression test: `{f.regression_test}`)")
        lines.append("")
    if result.new:
        fuzzy_of = dict(result.fuzzy)
        lines += ["## New findings", "",
                  "| id | sev | theme | title | probable duplicate of |",
                  "|---|---|---|---|---|"]
        for f in result.new:
            dup = fuzzy_of.get(f.finding_id)
            dup_cell = f"{dup} ({findings[dup].disposition})" if dup else "-"
            lines.append(f"| {f.finding_id} | {f.severity} "
                         f"| {f.fingerprint_inputs['theme']} "
                         f"| {markdown_cell(f.title)} "
                         f"| {dup_cell} |")
        lines.append("")
    if result.suppressed:
        lines += ["## Suppressed", ""]
        for f in result.suppressed:
            lines.append(f"- {f.finding_id} ({f.disposition}, "
                         f"x{f.occurrences}) {markdown_cell(f.title)}")
        lines.append("")
    if result.theme_candidates:
        lines += ["## Theme vocabulary candidates", "",
                  "Add these to themes.yaml or map them to existing themes:", ""]
        for theme in sorted(result.theme_candidates):
            lines.append(f"- `{theme}`")
        lines.append("")
    if still_open:
        lines += ["## Still open", "",
                  "| id | sev | disposition | title |", "|---|---|---|---|"]
        for f in still_open:
            lines.append(f"| {f.finding_id} | {f.severity} "
                         f"| {f.disposition} | {markdown_cell(f.title)} |")
        lines.append("")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_reconcile.py -v`
Expected: all PASS

- [ ] **Step 5: Run the full register suite for regressions**

Run: `python3 -m pytest tests/register -v`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add lazy_vibe/register/reconcile.py tests/register/test_reconcile.py
git commit -m "feat(register): add deterministic reconciler with report rendering"
```

---

### Task 8: CLI (`cli.py`, `__main__.py`) + end-to-end test

**Files:**
- Create: `lazy_vibe/register/cli.py`
- Create: `lazy_vibe/register/__main__.py`
- Test: `tests/register/test_cli_end_to_end.py`

- [ ] **Step 1: Write the failing end-to-end test**

Create `tests/register/test_cli_end_to_end.py`:

```python
"""End-to-end: two audit runs through the CLI demonstrate convergence
(suppression of adjudicated findings, regression detection)."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

from lazy_vibe.register.model import Disposition
from lazy_vibe.register.store import RegisterStore
from lazy_vibe.register.transitions import transition

REPO_ROOT = Path(__file__).resolve().parents[2]

HEADER = ("blocker_id\tcategory\ttheme\tseverity\tgroup\tmodel_class\t"
          "finding_count\trepresentative_source\trepresentative_line\t"
          "representative_title\traw_px_ids\treferences\n")
ROW_TENANT = ("B-0001\tproduct_gap\ttenant_scope_missing\tP1\tW1\tstandard\t3\t"
              "backend/routers/evidence.py\t118\t"
              "Evidence list endpoint not tenant-scoped\tP1-0001\tr1\n")
ROW_BROWSER = ("B-0002\tevidence_gap\tbrowser_evidence_missing\tP2\tW2\t"
               "standard\t1\tdocs/ux/journeys.md\t-\t"
               "No browser proof for evidence journey\tP2-0004\tr2\n")

THEMES = """\
themes:
  tenant_scope_missing:
    patterns: ["tenant scope"]
  browser_evidence_missing:
    patterns: ["browser proof"]
"""


def cli(*args):
    return subprocess.run(
        [sys.executable, "-m", "lazy_vibe.register", *args],
        cwd=REPO_ROOT, capture_output=True, text=True)


@pytest.fixture
def workspace(tmp_path):
    register_dir = tmp_path / "docs" / "audit" / "register"
    register_dir.mkdir(parents=True)
    (register_dir / "themes.yaml").write_text(THEMES)
    run1 = tmp_path / "run1"
    run1.mkdir()
    (run1 / "00-blocker-ledger.tsv").write_text(HEADER + ROW_TENANT + ROW_BROWSER)
    run2 = tmp_path / "run2"
    run2.mkdir()
    (run2 / "00-blocker-ledger.tsv").write_text(HEADER + ROW_TENANT + ROW_BROWSER)
    return tmp_path, register_dir, run1, run2


def test_two_run_convergence(workspace):
    tmp, register_dir, run1, run2 = workspace

    # Run 1: backfill -> two new findings.
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1", "--date", "2026-06-10")
    assert proc.returncode == 0, proc.stderr
    report1 = (register_dir / "reconcile-report.md").read_text()
    assert "2 new, 0 suppressed, 0 regressed" in report1

    # Adjudicate between runs: R-0001 fixed, R-0002 risk-accepted.
    store = RegisterStore(register_dir)
    findings = store.load()
    now = "2026-06-10T12:00:00+00:00"
    transition(findings["R-0001"], Disposition.OPEN, by="pete",
               reason="real", now=now, verified=True)
    transition(findings["R-0001"], Disposition.IN_REMEDIATION, by="harness",
               reason="unit U-1", now=now)
    transition(findings["R-0001"], Disposition.FIXED, by="harness",
               reason="fixed in commit abc",
               regression_test="tests/test_evidence.py::test_tenant_scope", now=now)
    transition(findings["R-0002"], Disposition.RISK_ACCEPTED, by="pete",
               reason="journey proof deferred to beta", now=now,
               review_by="2026-09-01")
    store.save(findings)

    # Run 2: same ledger -> one regression, one suppressed, zero new.
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(run2 / "00-blocker-ledger.tsv"),
               "--run-id", "run2", "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    report2 = (register_dir / "reconcile-report.md").read_text()
    assert "0 new, 1 suppressed, 1 regressed" in report2
    assert "R-0001" in report2  # the regression

    findings = RegisterStore(register_dir).load()
    assert findings["R-0001"].disposition == "regressed"
    assert findings["R-0002"].disposition == "risk_accepted"
    assert findings["R-0002"].occurrences == 2


def test_ingest_then_reconcile_separately(workspace):
    tmp, register_dir, run1, _ = workspace
    proc = cli("ingest", "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1",
               "--out", str(run1 / "register-candidates.json"))
    assert proc.returncode == 0, proc.stderr
    data = json.loads((run1 / "register-candidates.json").read_text())
    assert len(data["candidates"]) == 2

    proc = cli("reconcile", "--register-dir", str(register_dir),
               "--candidates", str(run1 / "register-candidates.json"),
               "--date", "2026-06-10")
    assert proc.returncode == 0, proc.stderr
    assert (register_dir / "register.jsonl").exists()
    assert (register_dir / "register.md").exists()


def test_missing_themes_yaml_fails_loudly(workspace, tmp_path):
    _, _, run1, _ = workspace
    empty_dir = tmp_path / "no-themes"
    empty_dir.mkdir()
    proc = cli("backfill", "--register-dir", str(empty_dir),
               "--ledger", str(run1 / "00-blocker-ledger.tsv"),
               "--run-id", "run1", "--date", "2026-06-10")
    assert proc.returncode == 1
    assert "themes.yaml" in proc.stderr


def test_cli_reports_clean_error_on_os_failure(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    proc = cli("backfill", "--register-dir", str(register_dir),
               "--ledger", str(tmp_path),  # a directory, not a file
               "--run-id", "x", "--date", "2026-06-10")
    assert proc.returncode == 1
    assert "error:" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_report_regenerates_markdown(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    (register_dir / "register.md").unlink()
    proc = cli("report", "--register-dir", str(register_dir))
    assert proc.returncode == 0, proc.stderr
    assert (register_dir / "register.md").exists()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_cli_end_to_end.py -v`
Expected: FAIL — `python -m lazy_vibe.register` exits non-zero (`No module named lazy_vibe.register.__main__`)

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/cli.py`:

```python
"""CLI: python -m lazy_vibe.register {ingest,reconcile,backfill,report} (spec §11)."""
from __future__ import annotations

import argparse
import datetime as _dt
import sys
from pathlib import Path

from .ingest import parse_ledger, read_candidates, write_candidates
from .model import RegisterError
from .reconcile import reconcile, render_report
from .store import RegisterStore
from .themes import load_vocabulary


def _today() -> str:
    return _dt.date.today().isoformat()


def _cmd_ingest(args: argparse.Namespace) -> int:
    candidates = parse_ledger(Path(args.ledger), run_id=args.run_id)
    write_candidates(candidates, Path(args.out), run_id=args.run_id)
    print(f"wrote {len(candidates)} candidates to {args.out}")
    return 0


def _reconcile_candidates(register_dir: Path, candidates, run_id: str,
                          date: str) -> int:
    store = RegisterStore(register_dir)
    vocab = load_vocabulary(register_dir / "themes.yaml")
    result = reconcile(store, candidates, vocab, run_id=run_id, date=date)
    report_path = register_dir / "reconcile-report.md"
    render_report(result, store.load(), report_path, run_id=run_id)
    print(f"{len(result.new)} new, {len(result.suppressed)} suppressed, "
          f"{len(result.regressed)} regressed — report: {report_path}")
    return 0


def _cmd_reconcile(args: argparse.Namespace) -> int:
    candidates = read_candidates(Path(args.candidates))
    run_id = candidates[0].run_id if candidates else "empty-run"
    date = args.date or _today()
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 run_id, date)


def _cmd_backfill(args: argparse.Namespace) -> int:
    candidates = parse_ledger(Path(args.ledger), run_id=args.run_id)
    date = args.date or _today()
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 args.run_id, date)


def _cmd_report(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    with store.locked():
        findings = store.load()
        store.write_markdown(findings)
    print(f"regenerated {store.markdown_path} ({len(findings)} findings)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lazy_vibe.register")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("ingest", help="parse a blocker ledger into candidates JSON")
    p.add_argument("--ledger", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=_cmd_ingest)

    p = sub.add_parser("reconcile", help="reconcile candidates against the register")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--candidates", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_reconcile)

    p = sub.add_parser("backfill", help="ingest + reconcile a ledger in one pass")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--ledger", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_backfill)

    p = sub.add_parser("report", help="regenerate register.md from register.jsonl")
    p.add_argument("--register-dir", required=True)
    p.set_defaults(func=_cmd_report)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except RegisterError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

Create `lazy_vibe/register/__main__.py`:

```python
import sys

from .cli import main

sys.exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_cli_end_to_end.py -v`
Expected: all PASS

- [ ] **Step 5: Run the entire register suite**

Run: `python3 -m pytest tests/register -v`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add lazy_vibe/register/cli.py lazy_vibe/register/__main__.py tests/register/test_cli_end_to_end.py
git commit -m "feat(register): add CLI with end-to-end convergence test"
```

---

### Task 9: Public API exports + README documentation

**Files:**
- Modify: `lazy_vibe/register/__init__.py`
- Modify: `README.md` (repo root — add a "Findings register" section after the existing remediation section)

- [ ] **Step 1: Export the public API**

Replace `lazy_vibe/register/__init__.py` content with:

```python
"""Persistent findings register (lazy-vibe v3 register core, spec §4-§5).

Canonical store: docs/audit/register/register.jsonl in each product repo.
CLI: python -m lazy_vibe.register {ingest,reconcile,backfill,report}
Spec: docs/superpowers/specs/2026-06-11-register-core-design.md
"""
from .ingest import Candidate, parse_ledger, read_candidates, write_candidates
from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding, RegisterError, Severity)
from .reconcile import ReconcileResult, reconcile, render_report
from .store import RegisterStore, markdown_cell
from .themes import load_vocabulary, map_theme
from .transitions import LEGAL_EDGES, TransitionError, reaffirm_risk, transition

__all__ = [
    "Candidate", "Disposition", "Finding", "LEGAL_EDGES",
    "PROTECTED_DISPOSITIONS", "ReconcileResult", "RegisterError",
    "RegisterStore", "SEVERITY_ORDER", "Severity", "TransitionError",
    "load_vocabulary", "map_theme", "markdown_cell", "parse_ledger",
    "read_candidates", "reaffirm_risk", "reconcile", "render_report",
    "transition", "write_candidates",
]
```

*(Note: `markdown_cell` from `.store` and `LEGAL_EDGES` from `.transitions` were added during post-plan review; both are included in the sorted `__all__` above.)*

- [ ] **Step 2: Verify imports work and suite still passes**

Run: `python3 -c "import lazy_vibe.register as r; print(sorted(r.__all__))" && python3 -m pytest tests/register -q`
Expected: prints the export list; all tests PASS

- [ ] **Step 3: Document in README.md**

Add this section to the repo-root `README.md` (place it after the remediation harness documentation; adjust heading level to match neighbors):

```markdown
## Findings register (`lazy_vibe/register`)

Persistent, adjudicated findings register — the convergence layer between
audit runs. Design: `docs/superpowers/specs/2026-06-11-register-core-design.md`.

Each product repo owns `docs/audit/register/` containing `register.jsonl`
(canonical, git-committed), generated `register.md`, `themes.yaml` (theme
vocabulary), and `reconcile-report.md` (latest run delta).

Usage after an audit/remediation run produced a blocker ledger:

    python3 -m lazy_vibe.register backfill \
      --register-dir <product>/docs/audit/register \
      --ledger <REMEDIATION_DIR>/00-blocker-ledger.tsv \
      --run-id <run-id>

The reconcile report headline (`N new, M suppressed, K regressed, J still
open`) is the run-over-run convergence metric. Dispositions: new findings are
adjudicated once (open / false_positive / risk_accepted / parked) and that
decision persists; `fixed` requires a linked regression test; reappearance of
a fixed finding is flagged as a regression. `false_positive` and
`risk_accepted` are protected — only Pete can reopen them, and risk
acceptances carry a mandatory `review_by` date.

Tests: `python3 -m pytest tests/register -v`
```

- [ ] **Step 4: Commit**

```bash
git add lazy_vibe/register/__init__.py README.md docs/superpowers/plans/2026-06-11-register-core.md
git commit -m "docs(register): export public API and document register usage"
```

---

### Task 10: Backfill the real Meridian register (first production use)

This validates the module against real data and seeds Meridian's register so
Plan 2 (triage) starts with live findings.

**Files:**
- Create: `/home/pete/cadres/meridian/docs/audit/register/themes.yaml`
- Create (generated): `/home/pete/cadres/meridian/docs/audit/register/register.jsonl`, `register.md`, `reconcile-report.md`

- [ ] **Step 1: Locate the most recent Meridian blocker ledger**

Run: `ls -t /home/pete/cadres/meridian/docs/audit/*/00-blocker-ledger.tsv 2>/dev/null | head -3; find /home/pete/cadres/meridian -name "00-blocker-ledger.tsv" -newer /home/pete/cadres/meridian/docs -mmin +0 2>/dev/null | head -5`

Pick the newest ledger. If none exists under `docs/audit/`, search remediation
run directories: `find /home/pete/cadres/meridian -name "00-blocker-ledger.tsv" 2>/dev/null`.
If there is genuinely no ledger, stop and report — do not fabricate one.

- [ ] **Step 2: Seed themes.yaml from the ledger's observed themes**

Run (substitute the ledger path found in Step 1):

```bash
LEDGER=<path-from-step-1>
mkdir -p /home/pete/cadres/meridian/docs/audit/register
{ echo "themes:"; tail -n +2 "$LEDGER" | cut -f3 | sort -u | sed 's/^/  /; s/$/:\n    patterns: []/'; } \
  > /home/pete/cadres/meridian/docs/audit/register/themes.yaml
cat /home/pete/cadres/meridian/docs/audit/register/themes.yaml
```

Verify the YAML parses: `python3 -c "import yaml,sys; yaml.safe_load(open('/home/pete/cadres/meridian/docs/audit/register/themes.yaml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Backfill**

```bash
cd /home/pete/cadres/shared/lazy-vibe
python3 -m lazy_vibe.register backfill \
  --register-dir /home/pete/cadres/meridian/docs/audit/register \
  --ledger "$LEDGER" \
  --run-id "$(basename "$(dirname "$LEDGER")")"
```

Expected: `N new, 0 suppressed, 0 regressed — report: .../reconcile-report.md`
where N equals the ledger's data row count.

- [ ] **Step 4: Sanity-check outputs**

Run: `head -2 /home/pete/cadres/meridian/docs/audit/register/register.jsonl && head -30 /home/pete/cadres/meridian/docs/audit/register/register.md`
Expected: valid JSONL entries with disposition `new`; markdown view groups them under `## new`.

- [ ] **Step 5: Commit in the meridian repo**

```bash
cd /home/pete/cadres/meridian
git add docs/audit/register/
git commit -m "chore(register): seed findings register from latest audit ledger"
```

---

## Self-Review (completed at plan-writing time)

- **Spec coverage (Plan 1 scope = spec §4, §5, §12 partial, §13, §14 steps 1–2):**
  §4.1 schema → Task 1; §4.2 state machine incl. protected states and mandatory
  `review_by` → Task 2; §4.3 storage/lock/markdown → Task 5; §5 exact/fuzzy
  matching, regression detection, report, backfill → Tasks 6–8, 10; §12 corrupt
  line, unmapped theme, missing vocabulary → Tasks 4–6 error tests; §13 unit +
  reconciler + end-to-end → Tasks 1–8.
  **Deliberately deferred to Plan 2:** triage pipeline (§6), scope matching /
  `in_scope` computation (§7 — `_create_finding` defaults `in_scope=True` with a
  comment), readiness predicate (§7.2), verifier dispatch for fuzzy candidates
  (§5 step 2 — recorded as history events for triage to consume), harness
  call-out wiring in `run-audit.sh`/`run-remediation.sh` (§11). **Plan 3:**
  differential mode (§8), prompt calibration (§9), skill consolidation (§10).
- **Placeholder scan:** every code step contains complete code; the only
  runtime-determined value is the ledger path in Task 10, with an explicit
  stop-and-report instruction if absent.
- **Type consistency:** `Finding` field names match across model/store/
  reconcile tests; `Candidate` fields match ingest/reconcile; CLI subcommand
  flags match the end-to-end test invocations; `SEVERITY_ORDER` ordering
  convention (P0 = 0 = most severe) is used consistently in `_review_severity`
  and sorting.
