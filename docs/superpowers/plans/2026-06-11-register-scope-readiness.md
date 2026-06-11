# Register Core (Plan 2a of 3): Scorecard Ingest + Launch Scope + Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate the register from post-remediation feature-review scorecards, scope it against a per-product launch surface, and compute release-readiness deterministically (spec §7, §10 scorecard flow, §14 step 4 plus scorecard adapter).

**Architecture:** Three new modules in `lazy_vibe/register/` — `scorecard.py` (markdown scorecard → `Candidate`s), `scope.py` (launch-scope.yaml load/match/recompute), `readiness.py` (severity bar + gates → READY/NOT READY/STALE) — plus a `taxonomy` field on `Candidate`, scope wiring in `reconcile`, and three CLI verbs. Plan 2b adds the verifier/policy/queue triage pipeline.

**Tech Stack:** Python 3.12 stdlib + PyYAML, pytest. Existing Plan 1 APIs: `Candidate`, `reconcile`, `RegisterStore`, `transition`, `map_theme`, `SEVERITY_ORDER`, `markdown_cell`.

**Repo:** /home/pete/cadres/shared/lazy-vibe, branch `feature/register-scope-readiness` off main. Run tests from repo root: `python3 -m pytest tests/register -q` (baseline: 80 passed).

**Grounding facts (re-verified 2026-06-11 against all 50 files; the original one-file generalization was wrong):**
- Real Meridian scorecards live at `/home/pete/cadres/meridian/docs/scorecards/*.md` (50 files) in TWO layouts. (1) Findings tables (14 files): column order varies, parse by header name; severity column is `Severity` or `Sev`; title column is one of Title/Summary/Finding/Issue/One-line summary/Item; `Status` column is optional — without one, closure is marked by explicit markers (`[FIXED]`, ALL-CAPS `RESOLVED`, cell-leading `Resolved.`), never by prose-case marker words ("never cleared", '"Done" claim' are bug text in open rows). (2) Heading findings (36 files, no findings table): `### <ID>: <title>` sections with `**Severity:** <grade>` body lines or inline `(High)`; closure via explicit marker after `—`/`✅` in the heading, `(Cleared …)` parentheticals, or Status/Severity body lines (`~~High~~ → **FIXED**`); `Med — partially fixed` / `still open` stay open. Severities: Critical/High/Med(ium)/Low plus compound grades (Low-Med→P2, Med-High→P1) and `Informational (no finding)` = verified-clean non-finding. Finding IDs: `B-05`, `CLOUD-B01`, `B-NEW-01 (CODE-ITSM-B01)`, `S-01b`, `U-05 (new)`, compound `B-02/A-01`, `A-01 / Scale`. Detail sections `### B-05: …` contain backticked `path:line` evidence refs; table layouts may carry an Evidence/Location/Key citation column instead. Corpus result: 50/50 files parse, 397 open candidates, 0 problems, 7.3% path fallback (29 findings without an extractable evidence path).
- Meridian profile: `profiles/meridian/product-profile.md` — backend tests `cd backend && python -m pytest`, frontend `cd frontend && npm run typecheck`.

## File Structure

```
lazy_vibe/register/
├── scorecard.py     # scorecard markdown -> list[Candidate]
├── scope.py         # launch-scope.yaml: load, validate, match, recompute
├── readiness.py     # severity bar + gates evaluation -> ReadinessReport
├── ingest.py        # MODIFY: Candidate gains taxonomy field (default "G")
├── reconcile.py     # MODIFY: optional scope param -> in_scope + auto-park new
└── cli.py           # MODIFY: scorecard-ingest / scope-recompute / readiness verbs

tests/register/
├── test_scorecard.py
├── test_scope.py
├── test_readiness.py
└── (extend) test_ingest.py, test_reconcile.py, test_cli_end_to_end.py
```

---

### Task 1: `Candidate.taxonomy` field

**Files:**
- Modify: `lazy_vibe/register/ingest.py` (Candidate dataclass)
- Modify: `lazy_vibe/register/reconcile.py` (`_create_finding`)
- Test: extend `tests/register/test_ingest.py`, `tests/register/test_reconcile.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_ingest.py`:

```python
def test_candidate_taxonomy_defaults_to_gap(ledger):
    candidates = parse_ledger(ledger, run_id="x")
    assert candidates[0].taxonomy == "G"
```

Append to `tests/register/test_reconcile.py`:

```python
def test_candidate_taxonomy_flows_to_finding(store):
    c = cand(taxonomy="S")
    result = reconcile(store, [c], VOCAB, run_id=RUN, date=DATE)
    assert store.load()[result.new[0].finding_id].taxonomy == "S"
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_ingest.py tests/register/test_reconcile.py -v`
Expected: FAIL — `Candidate` has no `taxonomy` attribute / unexpected keyword.

- [ ] **Step 3: Implement**

In `lazy_vibe/register/ingest.py`, add to the `Candidate` dataclass as the LAST field (frozen dataclass — defaulted fields must follow non-defaulted):

```python
    taxonomy: str = "G"
```

In `lazy_vibe/register/reconcile.py` `_create_finding`, replace the hardcoded taxonomy line (keep the comment, reworded):

```python
        # taxonomy from the source adapter; refinement is a triage-stage
        # concern (plan 2b), like in_scope
        taxonomy=candidate.taxonomy,
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register -q` — expect 82 passed.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/ingest.py lazy_vibe/register/reconcile.py tests/register/test_ingest.py tests/register/test_reconcile.py
git commit -m "feat(register): carry source taxonomy on candidates"
```

---

### Task 2: Launch scope (`scope.py`)

**Files:**
- Create: `lazy_vibe/register/scope.py`
- Test: `tests/register/test_scope.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_scope.py`:

```python
import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.scope import load_scope, matches
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

SCOPE_YAML = """\
product: meridian
default_in_scope: false
surfaces:
  - slug: evidence-collection
    paths: ["backend/routers/evidence", "backend/core/evidence"]
    routes: ["/api/evidence"]
  - slug: cloud-connectors
    paths: ["backend/connectors/"]
    routes: []
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted
  P2: triaged
gates:
  - id: backend-tests
    type: command
    command: "true"
  - id: sast-critical
    type: artifact_json
    path: artifacts/sast-summary.json
    key: critical_count
    op: eq
    value: 0
    max_age_days: 14
"""


@pytest.fixture
def scope(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML)
    return load_scope(p)


def test_load_scope_parses(scope):
    assert scope.product == "meridian"
    assert scope.default_in_scope is False
    assert [s.slug for s in scope.surfaces] == ["evidence-collection",
                                                "cloud-connectors"]
    assert scope.severity_bar["P1"] == "zero_open_or_risk_accepted"
    assert scope.gates[1].params["max_age_days"] == 14


def test_match_by_path_prefix(scope):
    f = make_finding()  # path backend/routers/evidence.py
    assert matches(f, scope) is True


def test_match_by_route_in_title(scope):
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "docs/functional/evidence.md",
                            "symbol": "-"},
        title="GET /api/evidence returns rows for all accounts")
    assert matches(f, scope) is True


def test_no_match_uses_default(scope):
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "backend/internal/billing.py",
                            "symbol": "-"},
        title="internal billing rounding")
    assert matches(f, scope) is False


def test_default_in_scope_true(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("default_in_scope: false",
                                    "default_in_scope: true"))
    scope = load_scope(p)
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "backend/internal/billing.py",
                            "symbol": "-"},
        title="internal billing rounding")
    assert matches(f, scope) is True


def test_missing_scope_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="launch-scope"):
        load_scope(tmp_path / "launch-scope.yaml")


def test_malformed_scope_is_hard_error(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text("just a string")
    with pytest.raises(RegisterError, match="mapping"):
        load_scope(p)


def test_bad_severity_bar_rejected(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("zero_open\n", "whatever\n", 1))
    with pytest.raises(RegisterError, match="severity_bar"):
        load_scope(p)


def test_bad_gate_type_rejected(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("type: command", "type: magic"))
    with pytest.raises(RegisterError, match="gate"):
        load_scope(p)
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_scope.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/scope.py`:

```python
"""Per-product launch scope: customer-facing surface + bar + gates (spec §7.1)."""
from __future__ import annotations

from dataclasses import dataclass
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
    fingerprint path, or surface route substring against path/title.

    Prefixes are literal startswith matches — end a prefix with '/' to
    enforce a directory boundary. Both matchers deliberately over-include
    (scope IN) on ambiguity; the dangerous direction is silent scope-OUT."""
    path = normalize_path(finding.fingerprint_inputs.get("path", ""))
    haystack = f"{path} {finding.title}"
    for surface in scope.surfaces:
        if any(path.startswith(prefix) for prefix in surface.paths):
            return True
        if any(route and route in haystack for route in surface.routes):
            return True
    return scope.default_in_scope
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register/test_scope.py -v` then `python3 -m pytest tests/register -q` — expect 91 passed.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/scope.py tests/register/test_scope.py
git commit -m "feat(register): launch-scope loading, validation and matching"
```

---

### Task 3: Scope wiring in reconcile + recompute

**Files:**
- Modify: `lazy_vibe/register/reconcile.py` (`reconcile` signature, `_create_finding`)
- Modify: `lazy_vibe/register/scope.py` (add `recompute`)
- Test: extend `tests/register/test_reconcile.py`, `tests/register/test_scope.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_reconcile.py`:

```python
def test_reconcile_with_scope_parks_out_of_scope_new(store, tmp_path):
    from lazy_vibe.register.scope import load_scope
    p = tmp_path / "launch-scope.yaml"
    p.write_text("product: meridian\ndefault_in_scope: false\n"
                 "surfaces:\n  - slug: other\n    paths: ['frontend/']\n")
    scope = load_scope(p)
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE,
                       scope=scope)
    f = store.load()[result.new[0].finding_id]
    assert f.in_scope is False
    assert f.disposition == "parked"
    assert f.disposition_by == "scope"


def test_reconcile_with_scope_keeps_in_scope_new(store, tmp_path):
    from lazy_vibe.register.scope import load_scope
    p = tmp_path / "launch-scope.yaml"
    p.write_text("product: meridian\ndefault_in_scope: false\n"
                 "surfaces:\n  - slug: ev\n    paths: ['backend/routers/']\n")
    scope = load_scope(p)
    result = reconcile(store, [cand()], VOCAB, run_id=RUN, date=DATE,
                       scope=scope)
    f = store.load()[result.new[0].finding_id]
    assert f.in_scope is True
    assert f.disposition == "new"
```

Append to `tests/register/test_scope.py`:

```python
def test_recompute_flags_and_proposals(tmp_path, scope):
    from lazy_vibe.register.scope import recompute
    from lazy_vibe.register.store import RegisterStore
    store = RegisterStore(tmp_path / "register")
    inside = with_history(make_finding(disposition="open",
                                       disposition_by="pete"))
    outside = make_finding(
        finding_id="R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb",
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "backend/internal/billing.py",
                            "symbol": "-"},
        title="internal billing rounding", in_scope=True)
    parked_now_in = with_history(make_finding(
        finding_id="R-0003", fingerprint="sha256:cccccccccccccccc",
        disposition="parked", disposition_by="scope", in_scope=False))
    store.save({f.finding_id: f for f in (inside, outside, parked_now_in)})
    proposals = recompute(store, scope, date="2026-06-12")
    findings = store.load()
    assert findings["R-0001"].in_scope is True
    assert findings["R-0002"].in_scope is False
    assert findings["R-0003"].in_scope is True
    # dispositions unchanged — recompute only proposes (spec §12)
    assert findings["R-0002"].disposition == "new"
    assert findings["R-0003"].disposition == "parked"
    kinds = {(p.finding_id, p.kind) for p in proposals}
    assert ("R-0002", "park") in kinds
    assert ("R-0003", "unpark") in kinds
    assert findings["R-0002"].history[-1]["event"] == "scope_recomputed"
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_reconcile.py tests/register/test_scope.py -v`
Expected: FAIL — `reconcile()` has no `scope` kwarg; no `recompute` in scope module.

- [ ] **Step 3: Implement**

In `lazy_vibe/register/reconcile.py`:
- Signature: `def reconcile(store, candidates, vocab, *, run_id, date, scope=None) -> ReconcileResult:` (import nothing new at module level; annotate `scope: "Scope | None" = None` with `from .scope import Scope` under `from __future__` — direct import is fine, no cycle: scope imports model+fingerprint only).
- In the no-match branch, after `new = _create_finding(...)` and the fuzzy block, before appending to buckets:

```python
            if scope is not None:
                from .scope import matches  # local to avoid import at hot path
                new.in_scope = matches(new, scope)
                if not new.in_scope:
                    transition(new, Disposition.PARKED, by="scope",
                               reason="outside launch scope at creation",
                               now=_now(date))
```

(Keep `result.new.append(new)` — parked-at-birth entries still count as new in the report; they are visible in the Suppressed/Still-open views via register.md.)

In `lazy_vibe/register/scope.py`, add:

```python
@dataclass(frozen=True)
class ScopeProposal:
    finding_id: str
    kind: str       # "park" | "unpark"
    reason: str


def recompute(store, scope: Scope, *, date: str) -> list[ScopeProposal]:
    """Re-evaluate in_scope across the register after a scope edit.

    Flags are updated; dispositions are NOT changed — transitions surface
    as proposals for the triage queue (spec §12)."""
    proposals: list[ScopeProposal] = []
    now = f"{date}T00:00:00+00:00"
    with store.locked():
        findings = store.load()
        for finding in findings.values():
            computed = matches(finding, scope)
            if computed == finding.in_scope:
                continue
            finding.history.append({"ts": now, "event": "scope_recomputed",
                                    "from": finding.in_scope, "to": computed,
                                    "product": scope.product})
            finding.in_scope = computed
            if not computed and finding.disposition in (
                    "new", "open", "in_remediation", "regressed"):
                proposals.append(ScopeProposal(
                    finding.finding_id, "park",
                    "left launch scope after scope edit"))
            elif computed and finding.disposition == "parked":
                proposals.append(ScopeProposal(
                    finding.finding_id, "unpark",
                    "entered launch scope after scope edit"))
        store.save(findings)
    return proposals
```

(Imports needed at top of scope.py: `from .store import RegisterStore` is NOT needed — accept the store duck-typed; do not import to avoid a cycle with future store changes. Keep the signature untyped for `store`.)

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register -q` — expect 94 passed.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/reconcile.py lazy_vibe/register/scope.py tests/register/test_reconcile.py tests/register/test_scope.py
git commit -m "feat(register): scope-aware reconcile and in_scope recompute with proposals"
```

---

### Task 4: Scorecard ingest (`scorecard.py`) — EXECUTED 2026-06-11 (revised after corpus review)

**Files:**
- Created: `lazy_vibe/register/scorecard.py`
- Test: `tests/register/test_scorecard.py` (33 tests incl. a real-corpus integration test)

> **Revision note:** the original Task 4 design (single findings-table layout,
> whole-file abort on unknown severity) handled 2/50 real scorecards. The
> landed implementation was redesigned against the full corpus; the code blocks
> originally embedded here are superseded by the committed files, which are the
> source of truth. Commits: `6e000d2` (first pass), `fix(register): scorecard
> parser hardened against the real 50-file corpus` (redesign).

- [x] **Step 1: Failing tests** — `tests/register/test_scorecard.py`: fixtures
  for every real format class (evidence-column tables, `Sev` alias + shuffled
  columns, status-less tables with explicit closed markers, compound severity
  grades, decorated/compound IDs, severity-less status tables, multi-table
  files, heading-only scorecards with all closure variants, mixed
  table+heading files) plus a corpus integration test guarded by
  `pytest.mark.skipif(not Path('/home/pete/cadres/meridian/docs/scorecards').exists(), ...)`
  asserting zero exceptions, >= 100 candidates, zero problems across all 50
  real files.
- [x] **Step 2: Red** — `ModuleNotFoundError` / `ImportError` confirmed.
- [x] **Step 3: Implementation** — `lazy_vibe/register/scorecard.py`. Contract:

```python
@dataclass
class ScorecardParse:
    candidates: list[Candidate]
    problems: list[str]   # actionable, file+row specific


def parse_scorecard(path: Path, *, slug: str, run_id: str) -> ScorecardParse: ...
```

  Design decisions (all corpus-grounded):
  1. **Two extraction strategies.** Findings tables first (severity column
     `severity|sev`, title column `title|summary|finding|issue|one-line
     summary|item`, `status` optional); then `### <ID>: <title>` heading
     sections for IDs not already seen in a table (36/50 real files have no
     findings table — without this strategy the corpus integration test
     cannot pass). Heading severity: inline `(High)` or `**Severity:**` body
     line. Table IDs suppress same-ID headings (detail sections).
  2. **Open/closed.** Status column: open iff "open" in status. No status
     column: closed only on EXPLICIT markers — bracketed `[FIXED]` (any
     case), standalone ALL-CAPS (`RESOLVED`), or cell-leading `Resolved.` —
     because case-insensitive substring matching (the originally specified
     rule) falsely closes real open findings whose prose contains marker
     words (audit-workflow B-10 "never cleared", S-01 '"Done" claim',
     audit-reporting B-03/M-02). Headings: explicit marker after the last
     `—`/`✅` separator, closure parenthetical on the ID (`(Cleared …)`), or
     Status/Severity body lines (case-insensitive there — `Resolved (W2)`,
     `Fixed and verified` are genuine) with an open/partial counter-signal
     guard (`still open`, `partially fixed`, `PARTIALLY RESOLVED` stay open).
  3. **Loud per-row problems.** Unknown severity, unparseable ID, and open
     rows in severity-less status tables append to `problems` and parsing
     continues. Hard `RegisterError` only for missing file and
     no-findings-structure (no qualifying table AND no finding headings).
  4. **Severity map** adds low-med/med-low→P2, med-high/high-med→P1, direct
     P0–P3 tokens; `informational` = verified-clean non-finding, skipped by
     design (as are "not a finding"/"no finding" headings).
  5. **ID cleaning**: strip trailing parentheticals (`U-05 (new)`), take the
     first compound segment (`B-02/A-01`, `A-01 / Scale`), accept lowercase
     suffix (`B-01b`); `_ID_RE = ^[A-Z][A-Z-]*-?\d+[a-z]?$`.
  6. **Taxonomy** from the trailing ID letter; letters outside the model's
     `_SIMPLE_TAXONOMY` (imported — single source of truth) map to "G".
  7. **Evidence path**: detail-section backticked ref first, then an
     Evidence/Location/Key-citation table cell, then the scorecard file.
- [x] **Step 4: Green** — `python3 -m pytest tests/register -q` → 133 passed
  (132 passed + 1 skipped without the Meridian corpus). Corpus integration:
  50/50 files, 397 open candidates, 0 problems, parse-twice idempotent.
- [x] **Step 5: Committed.**
- [x] **Step 6 (re-review fixes, 2026-06-11):** six corpus-integrity fixes,
  TDD red-first each: (1) `_PATH_PATTERN` extensions longest-first
  (`tsx|ts`, `json|jsx|js`) plus `(?!\w)` guard — the old alternation
  truncated `Foo.tsx:123` to `Foo.ts` with the line dropped, corrupting 59
  of the corpus' evidence paths (and therefore fingerprint identity);
  (2) bracket-tagged heading IDs (`### B-02 [FIXED]: …` closes,
  `### B-09 [NEW]: …` yields a candidate — previously both vanished
  silently); (3) `_OPENISH_RE` word boundary (`\bopen\b`) so
  "api.openai.com" is not an open counter-signal (real instance:
  questionnaires S-04); (4) `**Resolution (date):**` body lines scanned as
  closure evidence (closed portal-app-access S-02, training B-03);
  (5) ` — ` accepted as an id/title heading separator alongside `:`;
  (6) a Status/Resolution line whose leading token is a closed marker
  closes even when later prose says another finding "remains open"
  (closed portal-directory-sync B-03, sox-deficiency-aggregation B-01).
  Exact old→new diff: 0 gained, 5 closed (all verified genuine), 59
  path/line corrections. Remaining false-open estimate: 0 (the one
  explicit-marker suspect, connector-framework G-02, is `PARTIALLY FIXED`
  and correctly open).

---

### Task 5: Readiness predicate (`readiness.py`) — EXECUTED 2026-06-11

**Files:**
- Created: `lazy_vibe/register/readiness.py`
- Test: `tests/register/test_readiness.py`

> **Carry-forward fixes landed in Task 6 session (Part B, 2026-06-11):**
> - `Finding.validate()` now enforces ISO-date format on `review_by` when
>   `disposition == "risk_accepted"` — catches hand-edited registers at
>   `store.load` before `evaluate` runs (Part B.1). Test:
>   `test_risk_accepted_review_by_must_be_iso_date` in `test_model.py`.
> - `evaluate()` wraps `_dt.date.fromisoformat(today)` — malformed `today`
>   raises `RegisterError("readiness date must be ISO …")` instead of
>   `ValueError` (Part B.2). Test: `test_evaluate_malformed_today_raises_register_error`.
> - `ReadinessReport` gains `not_gated_count` field; `evaluate()` increments it
>   for in-scope open-like findings below the severity bar; `render_readiness()`
>   appends `Not gated: N` and uses `STALE EVIDENCE (N blocking)` headline when
>   exit_code==2 and blocking is non-empty (Part B.3). Tests:
>   `test_render_stale_headline_includes_blocking_count`,
>   `test_render_not_gated_line_counts_in_scope_open_without_bar`.

- [x] **Step 1: Write the failing tests**

Create `tests/register/test_readiness.py`:

```python
import json

import pytest

from lazy_vibe.register.readiness import evaluate, render_readiness
from lazy_vibe.register.scope import load_scope
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

TODAY = "2026-06-12"


def scope_yaml(gates: str = "") -> str:
    return ("product: meridian\ndefault_in_scope: true\nsurfaces: []\n"
            "severity_bar:\n  P0: zero_open\n  P1: zero_open_or_risk_accepted\n"
            "  P2: triaged\n" + ("gates:\n" + gates if gates else ""))


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def make_scope(tmp_path, gates: str = ""):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(scope_yaml(gates))
    return load_scope(p)


def finding(fid, sev, disposition, **kw):
    fp = f"sha256:{fid[-4:]:0>16}".replace("R", "a").replace("-", "b").lower()
    return with_history(make_finding(
        finding_id=fid, fingerprint=fp, severity=sev,
        disposition=disposition, **kw))


def test_ready_when_empty(store, tmp_path):
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert report.exit_code == 0


def test_open_p0_blocks(store, tmp_path):
    f = finding("R-0001", "P0", "open", disposition_by="pete")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert report.exit_code == 1
    assert any("R-0001" in item for item in report.blocking)


def test_new_p2_blocks_triaged_bar(store, tmp_path):
    f = finding("R-0001", "P2", "new", disposition_by="ingest")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False


def test_candidate_theme_blocks_even_if_triaged_elsewhere(store, tmp_path):
    f = finding("R-0001", "P3", "new", disposition_by="ingest")
    f.fingerprint_inputs["theme"] = "_candidate:weird"
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert any("_candidate" in item for item in report.blocking)


def test_risk_accepted_p1_passes_and_is_listed(store, tmp_path):
    f = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                review_by="2026-12-01")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert any("R-0001" in a for a in report.risk_acceptances)


def test_past_due_risk_acceptance_blocks(store, tmp_path):
    f = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                review_by="2026-06-01")
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is False
    assert any("past due" in item for item in report.blocking)


def test_out_of_scope_open_does_not_block(store, tmp_path):
    f = finding("R-0001", "P0", "open", disposition_by="pete", in_scope=False)
    store.save({f.finding_id: f})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    assert report.ready is True
    assert report.parked_count == 0  # out-of-scope but not parked


def test_command_gate_pass_and_fail(store, tmp_path):
    ok = evaluate(store, make_scope(
        tmp_path, "  - id: ok\n    type: command\n    command: 'true'\n"),
        today=TODAY)
    assert ok.ready is True
    bad = evaluate(store, make_scope(
        tmp_path, "  - id: bad\n    type: command\n    command: 'false'\n"),
        today=TODAY)
    assert bad.ready is False


def test_artifact_json_gate(store, tmp_path):
    art = tmp_path / "sast.json"
    art.write_text(json.dumps({"summary": {"critical": 0}}))
    gates = (f"  - id: sast\n    type: artifact_json\n    path: {art}\n"
             f"    key: summary.critical\n    op: eq\n    value: 0\n")
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.ready is True
    art.write_text(json.dumps({"summary": {"critical": 2}}))
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.ready is False


def test_missing_artifact_is_stale(store, tmp_path):
    gates = ("  - id: sast\n    type: artifact_json\n"
             "    path: /nonexistent/sast.json\n"
             "    key: a\n    op: eq\n    value: 0\n")
    report = evaluate(store, make_scope(tmp_path, gates), today=TODAY)
    assert report.exit_code == 2
    assert report.ready is False


def test_render_always_lists_acceptances_and_parked(store, tmp_path):
    ra = finding("R-0001", "P1", "risk_accepted", disposition_by="pete",
                 review_by="2026-12-01")
    pk = finding("R-0002", "P3", "parked", disposition_by="scope",
                 in_scope=False)
    store.save({f.finding_id: f for f in (ra, pk)})
    report = evaluate(store, make_scope(tmp_path), today=TODAY)
    text = render_readiness(report)
    assert "READY" in text
    assert "R-0001" in text and "2026-12-01" in text
    assert "Parked: 1" in text
```

- [x] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_readiness.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [x] **Step 3: Implement**

Create `lazy_vibe/register/readiness.py`:

```python
"""Deterministic release-readiness predicate (spec §7.2). Zero LLM calls.

Exit codes: 0 READY, 1 NOT READY, 2 stale/missing gate evidence.
Past-due risk acceptances FAIL the predicate (spec §4.2 anti-debt guard).
The report always lists active risk acceptances and parked counts so
deferred work is visible at every release decision.
"""
from __future__ import annotations

import datetime as _dt
import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .model import Finding, RegisterError
from .scope import Gate, Scope

_OPEN_LIKE = {"new", "open", "in_remediation", "regressed"}
_OPS = {"eq": lambda a, b: a == b,
        "le": lambda a, b: a <= b,
        "ge": lambda a, b: a >= b}


@dataclass
class ReadinessReport:
    product: str
    ready: bool
    exit_code: int
    blocking: list[str] = field(default_factory=list)
    gate_results: list[tuple[str, str]] = field(default_factory=list)
    risk_acceptances: list[str] = field(default_factory=list)
    parked_count: int = 0


def _bar_blocks(finding: Finding, rule: str) -> str | None:
    if rule in ("zero_open", "zero_open_or_risk_accepted"):
        if finding.disposition in _OPEN_LIKE:
            return (f"{finding.finding_id} {finding.severity} "
                    f"{finding.disposition}: {finding.title}")
        if rule == "zero_open" and finding.disposition == "risk_accepted":
            return (f"{finding.finding_id} {finding.severity} risk_accepted "
                    f"but bar requires zero_open: {finding.title}")
        return None
    if rule == "triaged":
        if finding.disposition == "new":
            return (f"{finding.finding_id} {finding.severity} untriaged: "
                    f"{finding.title}")
        return None
    return None  # "ignored"


def _eval_gate(gate: Gate) -> tuple[str, str]:
    """Returns (status, detail) with status PASS|FAIL|STALE."""
    params = gate.params
    if gate.gate_type == "command":
        try:
            # shell=True is deliberate: gate commands are operator-authored,
            # git-committed launch-scope.yaml config (same trust model as a
            # Makefile/CI step) and need `cd x && y` composition. They are
            # never derived from finding content or any untrusted input.
            proc = subprocess.run(params["command"], shell=True,
                                  capture_output=True, text=True,
                                  timeout=params.get("timeout", 1800),
                                  cwd=params.get("cwd"))
        except subprocess.TimeoutExpired:
            return "FAIL", f"command timed out: {params['command']}"
        if proc.returncode == 0:
            return "PASS", params["command"]
        return "FAIL", (f"exit {proc.returncode}: {params['command']} — "
                        f"{(proc.stderr or proc.stdout).strip()[-200:]}")
    artifact = Path(params["path"])
    if not artifact.exists():
        return "STALE", f"artifact missing: {artifact}"
    max_age = params.get("max_age_days")
    if max_age is not None:
        age = (_dt.datetime.now(tz=_dt.timezone.utc)
               - _dt.datetime.fromtimestamp(artifact.stat().st_mtime,
                                            tz=_dt.timezone.utc)).days
        if age > int(max_age):
            return "STALE", f"artifact older than {max_age}d: {artifact}"
    if gate.gate_type == "artifact_exists":
        return "PASS", str(artifact)
    try:
        data = json.loads(artifact.read_text())
    except json.JSONDecodeError as exc:
        return "STALE", f"artifact unparseable: {artifact}: {exc}"
    value = data
    for part in str(params["key"]).split("."):
        if not isinstance(value, dict) or part not in value:
            return "STALE", f"key {params['key']!r} missing in {artifact}"
        value = value[part]
    op = _OPS.get(params["op"])
    if op is None:
        raise RegisterError(f"gate {gate.gate_id}: unknown op {params['op']!r}")
    if op(value, params["value"]):
        return "PASS", f"{params['key']}={value}"
    return "FAIL", (f"{params['key']}={value}, wanted "
                    f"{params['op']} {params['value']}")


def evaluate(store, scope: Scope, *, today: str) -> ReadinessReport:
    report = ReadinessReport(product=scope.product, ready=True, exit_code=0)
    today_date = _dt.date.fromisoformat(today)
    findings = store.load()
    for finding in findings.values():
        if finding.disposition == "parked":
            report.parked_count += 1
        if finding.disposition == "risk_accepted":
            report.risk_acceptances.append(
                f"{finding.finding_id} {finding.severity} review by "
                f"{finding.review_by}: {finding.title}")
            if _dt.date.fromisoformat(finding.review_by) < today_date:
                report.blocking.append(
                    f"{finding.finding_id} risk acceptance past due "
                    f"({finding.review_by}) — reaffirm or fix")
        if not finding.in_scope:
            continue
        if finding.fingerprint_inputs.get("theme", "").startswith(
                "_candidate:") and finding.disposition == "new":
            report.blocking.append(
                f"{finding.finding_id} unresolved theme "
                f"{finding.fingerprint_inputs['theme']} — vocabulary gap "
                f"(spec §12)")
            continue
        rule = scope.severity_bar.get(finding.severity)
        if rule is None:
            continue
        blocked = _bar_blocks(finding, rule)
        if blocked:
            report.blocking.append(blocked)
    for gate in scope.gates:
        status, detail = _eval_gate(gate)
        report.gate_results.append((gate.gate_id, f"{status}: {detail}"))
        if status == "STALE":
            report.exit_code = 2
            report.ready = False
        elif status == "FAIL":
            report.ready = False
    if report.blocking:
        report.ready = False
    if not report.ready and report.exit_code == 0:
        report.exit_code = 1
    return report


def render_readiness(report: ReadinessReport) -> str:
    verdict = ("READY" if report.ready
               else "STALE EVIDENCE" if report.exit_code == 2
               else "NOT READY")
    lines = [f"# Readiness — {report.product}: {verdict}", ""]
    if report.blocking:
        lines += ["## Blocking", ""]
        lines += [f"- {item}" for item in report.blocking] + [""]
    if report.gate_results:
        lines += ["## Gates", ""]
        lines += [f"- {gid}: {res}" for gid, res in report.gate_results] + [""]
    lines += ["## Active risk acceptances", ""]
    lines += ([f"- {a}" for a in report.risk_acceptances] or ["- none"])
    lines += ["", f"Parked: {report.parked_count}", ""]
    return "\n".join(lines)
```

- [x] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register/test_readiness.py -v` then full suite — expect 144 passed (143 passed + 1 skipped where the Meridian scorecard corpus is absent).

- [x] **Step 5: Committed.**

---

### Task 6: CLI verbs + exports + e2e — EXECUTED 2026-06-11

**Files:**
- Modify: `lazy_vibe/register/cli.py`
- Modify: `lazy_vibe/register/__init__.py` (exports)
- Modify: `README.md` (extend the Findings register section)
- Test: extend `tests/register/test_cli_end_to_end.py`

> **Part B carry-forwards and Part C e2e test also landed in this session (2026-06-11):**
> See Task 5 note above for Part B.1 (validate ISO date), Part B.2 (evaluate
> malformed today), and Part B.3 (headline + not-gated line). Part C adds
> `test_bad_review_by_in_register_gives_clean_error` to
> `test_cli_end_to_end.py` — proves the store.load validation fires before
> evaluate and surfaces via the existing `RegisterError` handler (clean
> `error:` line, no Traceback).
>
> Final test count: 151 passed, 0 skipped (Meridian corpus present on this
> machine, so corpus integration test ran). 7 new tests landed: B.1 model
> validate, B.2 evaluate today, B.3a stale headline, B.3b not-gated line,
> T6 scorecard-ingest e2e, T6 scope-recompute e2e, Part C bad review_by.

- [x] **Step 1: Write the failing test**

Append to `tests/register/test_cli_end_to_end.py`:

```python
SCORECARD_MD = """\
# Widget Scorecard

## Findings Table

| ID | Severity | Type | Title | Status |
|----|----------|------|-------|--------|
| B-01 | Critical | Bug | Widget breaks tenancy | OPEN (new) |
| G-01 | Low | Gap | Widget lacks docs | Fixed — verified |
"""

LAUNCH_SCOPE = """\
product: testprod
default_in_scope: true
surfaces: []
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted
  P2: triaged
gates:
  - id: trivially-green
    type: command
    command: "true"
"""


def test_scorecard_ingest_then_readiness(workspace, tmp_path):
    _, register_dir, _, _ = workspace
    (register_dir / "themes.yaml").write_text(
        "themes:\n  widget:\n    patterns: []\n")
    scorecard = tmp_path / "widget.md"
    scorecard.write_text(SCORECARD_MD)
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(LAUNCH_SCOPE)

    proc = cli("scorecard-ingest", "--register-dir", str(register_dir),
               "--scorecard", str(scorecard), "--slug", "widget",
               "--run-id", "sc-run-1", "--date", "2026-06-11",
               "--scope", str(scope_path))
    assert proc.returncode == 0, proc.stderr
    assert "1 new" in proc.stdout

    proc = cli("readiness", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 1          # open P0 blocks
    assert "NOT READY" in proc.stdout
    assert "B-01" in proc.stdout or "R-0001" in proc.stdout


def test_scope_recompute_cli(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text("product: testprod\ndefault_in_scope: false\n"
                          "surfaces: []\nseverity_bar: {}\n")
    proc = cli("scope-recompute", "--register-dir", str(register_dir),
               "--scope", str(scope_path), "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    assert "park" in proc.stdout
```

- [x] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_cli_end_to_end.py -v`
Expected: new tests FAIL (argparse: invalid choice).

- [x] **Step 3: Implement**

In `lazy_vibe/register/cli.py`:

Add imports: `from .readiness import evaluate, render_readiness`, `from .scope import load_scope, recompute`, `from .scorecard import parse_scorecard`.

Extend `_reconcile_candidates` to accept and pass scope: change signature to `def _reconcile_candidates(register_dir, candidates, run_id, date, scope_path=None):` and inside, before calling `reconcile`: `scope = load_scope(Path(scope_path)) if scope_path else None`, pass `scope=scope` to `reconcile(...)`. Update the two existing callers (`_cmd_reconcile`, `_cmd_backfill`) to pass `getattr(args, "scope", None)`, and add `p.add_argument("--scope")` to the `reconcile` and `backfill` subparsers.

Add handlers:

```python
def _cmd_scorecard_ingest(args: argparse.Namespace) -> int:
    if len(args.scorecard) != len(args.slug):
        raise RegisterError(
            "--scorecard and --slug must be given the same number of times")
    candidates = []
    problems = []
    for sc_path, slug in zip(args.scorecard, args.slug):
        parsed = parse_scorecard(Path(sc_path), slug=slug, run_id=args.run_id)
        candidates.extend(parsed.candidates)
        problems.extend(parsed.problems)
    for problem in problems:
        print(f"warning: {problem}", file=sys.stderr)
    if args.strict and problems:
        print(f"refusing to ingest: {len(problems)} parse problems "
              f"(--strict)", file=sys.stderr)
        return 1
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 args.run_id, args.date or _today(),
                                 scope_path=args.scope)


def _cmd_scope_recompute(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    scope = load_scope(Path(args.scope))
    proposals = recompute(store, scope, date=args.date or _today())
    for proposal in proposals:
        print(f"{proposal.finding_id}: propose {proposal.kind} "
              f"({proposal.reason})")
    print(f"{len(proposals)} scope proposals")
    return 0


def _cmd_readiness(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    scope = load_scope(Path(args.scope))
    report = evaluate(store, scope, today=args.date or _today())
    print(render_readiness(report))
    return report.exit_code
```

Subparsers (inside `build_parser`):

```python
    p = sub.add_parser("scorecard-ingest",
                       help="ingest open findings from feature-review scorecards")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--scorecard", action="append", required=True)
    p.add_argument("--slug", action="append", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--date", default=None)
    p.add_argument("--scope", default=None)
    p.add_argument("--strict", action="store_true",
                   help="exit 1 if any scorecard rows failed to parse")
    p.set_defaults(func=_cmd_scorecard_ingest)

    p = sub.add_parser("scope-recompute",
                       help="re-evaluate in_scope after a launch-scope edit")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--scope", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_scope_recompute)

    p = sub.add_parser("readiness",
                       help="deterministic release-readiness verdict")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--scope", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_readiness)
```

`parse_scorecard` returns `ScorecardParse` (candidates + problems): problems are printed as `warning: <problem>` to stderr and ingestion continues unless `--strict` is set. `sys` is already imported in `cli.py`.

In `lazy_vibe/register/__init__.py`: add exports `Gate, ReadinessReport, Scope, ScopeProposal, Surface, evaluate, load_scope, matches, parse_scorecard, recompute, render_readiness` (import `evaluate as evaluate_readiness`? No — keep the name `evaluate` unexported to avoid genericity; export it as part of readiness usage via `from .readiness import ReadinessReport, evaluate, render_readiness`). Update `__all__` accordingly (keep sorted).

In `README.md` Findings register section, append:

```markdown
Plan 2a adds: `scorecard-ingest` (feature-review scorecards -> register),
`scope-recompute` (re-evaluate `in_scope` after editing
`launch-scope.yaml`), and `readiness` (deterministic verdict; exit 0
READY / 1 NOT READY / 2 stale gate evidence). The readiness report always
lists active risk acceptances and parked counts.
```

- [x] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register -q` — 151 passed, 0 skipped (Meridian corpus present).

- [x] **Step 5: Committed.**

---

### Task 7: Seed Meridian from post-remediation scorecards (production use)

No new lazy-vibe code. Work against the real Meridian repo. Treat anomalies as findings to report, not problems to silently work around.

- [ ] **Step 1: Extend Meridian themes.yaml with feature slugs**

The scorecard adapter uses the feature slug as theme. Append every scorecard's slug to `/home/pete/cadres/meridian/docs/audit/register/themes.yaml` (keep the existing 19 + header comment):

```bash
cd /home/pete/cadres/meridian/docs/scorecards
python3 - <<'EOF'
from pathlib import Path
themes_path = Path("/home/pete/cadres/meridian/docs/audit/register/themes.yaml")
import yaml
data = yaml.safe_load(themes_path.read_text())
slugs = sorted(p.stem for p in Path(".").glob("*.md"))
for slug in slugs:
    key = slug.replace("-", "_")
    data["themes"].setdefault(slug, {"patterns": []})
themes_path.write_text(yaml.safe_dump(data, sort_keys=True))
EOF
python3 -c "import yaml; v=yaml.safe_load(open('/home/pete/cadres/meridian/docs/audit/register/themes.yaml')); print(len(v['themes']))"
```

NOTE: `map_theme` slugifies, so `cloud-connectors` and `cloud_connectors` are the same slug — the setdefault key must be the RAW scorecard stem (slugify happens at load). Expected count: 19 + number of unique scorecard stems not colliding with existing themes (~69). The yaml round-trip drops the header comment — re-add a one-line comment at the top stating themes are seeded from ledger slugs + scorecard feature slugs.

- [ ] **Step 2: Write Meridian launch-scope.yaml**

Create `/home/pete/cadres/meridian/docs/audit/register/launch-scope.yaml`:

```yaml
# Meridian launch scope (spec §7.1). Customer-facing surface for launch.
# Initial scope: everything in scope; narrow surfaces as launch claims
# firm up. Severity bar per Pete (2026-06-11): P0 zero, P1 zero or
# risk-accepted, P2 triaged.
product: meridian
default_in_scope: true
surfaces: []
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted
  P2: triaged
gates:
  - id: backend-tests
    type: command
    command: "cd /home/pete/cadres/meridian/backend && python -m pytest -q"
    timeout: 3600
  - id: frontend-typecheck
    type: command
    command: "cd /home/pete/cadres/meridian/frontend && npm run typecheck"
    timeout: 900
```

- [ ] **Step 3: Ingest all 50 scorecards**

```bash
cd /home/pete/cadres/shared/lazy-vibe
ARGS=()
for f in /home/pete/cadres/meridian/docs/scorecards/*.md; do
  ARGS+=(--scorecard "$f" --slug "$(basename "$f" .md)")
done
python3 -m lazy_vibe.register scorecard-ingest \
  --register-dir /home/pete/cadres/meridian/docs/audit/register \
  "${ARGS[@]}" \
  --run-id scorecards-2026-06-10 \
  --scope /home/pete/cadres/meridian/docs/audit/register/launch-scope.yaml
```

Expected: exit 0, `N new, 0 suppressed, 0 regressed` where N ≈ 397 (corpus-verified 2026-06-11 after re-review fixes: 50/50 files parse, 397 open candidates, 0 problems; reconcile may merge same-fingerprint duplicates, so N can be slightly lower). Any `warning:` lines on stderr are per-row parse problems — report them verbatim; add `--strict` to refuse ingestion on problems. If a scorecard fails outright (missing file, no findings structure), report the exact file and failure — fix the PARSER only if the format is legitimately common; never edit historical scorecards.

- [ ] **Step 4: Idempotency check on real data**

Re-run the exact same command. Expected: `0 new, 0 suppressed, 0 regressed` and byte-identical register.jsonl (sha256sum before/after).

- [ ] **Step 5: Readiness dry run (skip slow gates)**

```bash
python3 -m lazy_vibe.register readiness \
  --register-dir /home/pete/cadres/meridian/docs/audit/register \
  --scope /home/pete/cadres/meridian/docs/audit/register/launch-scope.yaml \
  || true
```

Expected: `NOT READY` (exit 1) with the open P0/P1s listed — this is the honest current verdict, not a failure. Capture the blocking count in your report. (The command gates will run the real meridian suites; if the backend suite is red or slow, report what happened — do not mark the seed failed because the product has failing tests; that is precisely the signal.)

- [ ] **Step 6: Commit in meridian**

```bash
cd /home/pete/cadres/meridian
git add docs/audit/register/
git commit -m "chore(register): seed register from post-remediation scorecards

Ingested open findings from docs/scorecards (run scorecards-2026-06-10),
launch-scope.yaml with initial severity bar and test gates."
```

- [ ] **Step 7: Report** — scorecards parsed/skipped, findings ingested by severity, fuzzy-duplicate count, readiness verdict + blocking count, gate outcomes, anomalies.

---

## Self-Review (completed at plan-writing time)

- **Spec coverage:** §7.1 launch-scope format + scope principle → Tasks 2, 7; §7.2 readiness (bar, gates, exit codes, past-due FAIL, always-list acceptances/parked) → Task 5; §10 scorecards→register → Task 4, 7; §12 scope-edit recompute-as-proposals + `_candidate` blocks readiness → Tasks 3, 5; §14 step 4 → whole plan. **Deferred to Plan 2b:** triage pipeline (§6: verifier packets, triage-policy.yaml engine, queue + `triage` CLI, run-triage.sh dispatch wrapper), severity-review queue consumption, reopen proposals, `close` verb, §11 harness wiring into run-audit/run-remediation, fuzzy confirm/split, §12 collision split.
- **Placeholder scan:** all code steps carry complete code; Task 7 is operational with exact commands and explicit stop-and-report rules.
- **Type consistency:** `Candidate.taxonomy` (Task 1) consumed in Task 4 constructor and reconcile `_create_finding`; `Scope`/`Gate`/`Surface` (Task 2) consumed by Tasks 3/5/6 with matching field names (`gate_id`, `gate_type`, `params`); `recompute` returns `list[ScopeProposal]` consumed in `_cmd_scope_recompute`; `evaluate(store, scope, *, today)` matches CLI handler; `ScorecardParse` (Task 4) consumed by Task 6 `_cmd_scorecard_ingest`; expected test counts: 80 → 82 → 91 → 94 → 133 → 144 → 146 (original arithmetic 104/116/118 miscounted Task 4's tests and predates the corpus-hardening rework + re-review fixes; subtract 1 passed / add 1 skipped on machines without `/home/pete/cadres/meridian/docs/scorecards`).
