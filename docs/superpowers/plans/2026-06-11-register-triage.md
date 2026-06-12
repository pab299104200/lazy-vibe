# Register Core (Plan 2b of 3): Triage Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the triage pipeline (spec §6, §11 `close`/harness call-outs, §12 collision split) so `new` register entries are verified by agents, auto-dispositioned by a deterministic policy, and the residue lands in Pete's interactive queue. This closes the loop between the reconciler (Plan 1) / scope+readiness (Plan 2a) and remediation: a verified, in-scope finding becomes `open` automatically; everything that genuinely needs the owner becomes one queue item.

**Architecture:** Three new modules in `lazy_vibe/register/` — `verify.py` (deterministic verification-packet generation + schema-validated result consumption, including fuzzy-duplicate confirmation and collision-split queueing), `policy.py` (`triage-policy.yaml` ordered first-match-wins engine), `queue.py` (`triage-queue.md` render + the interactive `triage` CLI verb) — plus the `close` verb and `verify-packets` / `verify-consume` CLI wiring in `cli.py`, a `journeys`/`claims_doc` carry-forward in `scope.py`, and `run-triage.sh` harness glue. Verifier agents NEVER transition protected states; every policy disposition is stamped `policy:<rule-id>`; every Pete decision is stamped `pete` through `transition()` / `reaffirm_risk()`. Full `run-remediation.sh` rewiring and auto-split are Plan 3.

**Tech Stack:** Python 3.12 stdlib (`json`, `argparse`, `dataclasses`, `pathlib`) + PyYAML, pytest. Existing APIs consumed: `Finding`, `RegisterStore` (`locked`/`load`/`save`/`by_fingerprint`/`markdown_cell`), `transition` / `reaffirm_risk` / `TransitionError`, `Disposition`, `SEVERITY_ORDER`, `RegisterError`, `load_scope` / `recompute` / `ScopeProposal`, `evaluate`.

**Spec:** `docs/superpowers/specs/2026-06-11-register-core-design.md` — §6 (triage pipeline: verification, `triage-policy.yaml`, Pete's queue), §11 (CLI verbs incl. `close`, harness call-outs), §12 (error handling incl. collision split, verifier-failure stays `new`), §4.2 (state-machine authorities, reopen proposals, reaffirm).

**Repo:** /home/pete/cadres/shared/lazy-vibe, branch `feature/register-triage` off `main`. Run tests from repo root: `python3 -m pytest tests/register -q` (**baseline: 159 passed**). `ruff check lazy_vibe/register/` must stay clean. Keep every module under 800 lines and every function under 50 lines (`/home/pete/cadres/shared/templates/coding.md`).

**Grounding facts (verified 2026-06-11 against the live tree):**
- `scope.py` `load_scope` currently HARD-REJECTS surface keys other than `slug`/`paths`/`routes` with the message *"journeys/claims_doc arrive with plan 2b"* (`lazy_vibe/register/scope.py:68-72`). Task 6 lifts that restriction — without it the Meridian scope file in Task 8 cannot carry journeys.
- `transition(finding, to, *, by, reason, now, **kw)` stamps `finding.disposition_by = by` and appends a `{"event": "disposition", "from", "to", "by", "reason"}` history entry, then calls `finding.validate()` (`transitions.py:100-119`). `new->open` requires `verified=True` AND `by in {pete, policy:*}`; `new->false_positive` requires `by in {pete, policy:*}`; `new->parked` allows `scope` too; `risk_accepted` is `pete`-only with an ISO `review_by`.
- `Finding` history is a free-form `list[dict]`; the store only validates `event == "disposition"` entries against `LEGAL_EDGES` (`store.py:26-66`). Non-disposition events (`verification`, `duplicate_confirmed`, `split_proposed`, `fuzzy_match_candidate`, `severity_review_proposed`, `suppressed_occurrence`, `scope_recomputed`) pass through untouched — verify/policy/queue append those freely.
- Reconcile already emits `fuzzy_match_candidate` (`{candidate_of, run_id}`), `severity_review_proposed` (`{current, proposed, run_id}`), and `suppressed_occurrence` (`{run_id}`) history events (`reconcile.py:54-74, 150-152, 171-174`). The queue reads those, it does not recompute them.
- The Meridian register (`/home/pete/cadres/meridian/docs/audit/register/register.jsonl`) holds 397 `new` findings: 5 P0 (`R-0046, R-0200, R-0328, R-0371, R-0374`), 59 P1, 174 P2, 159 P3. Each entry's `fingerprint_inputs.symbol` is the scorecard finding id (e.g. `B-03`); evidence refs look like `core/campaign_cadence.py:243`.
- Agent CLI idiom (from `run-audit.sh:1076-1147`): `claude -p --dangerously-skip-permissions < prompt_file` (stdin prompt, stdout result) and `codex exec --full-auto --skip-git-repo-check -C <dir> - < prompt_file`. `run-triage.sh` models the prompt-on-stdin pattern with `MAX_PARALLEL` (default 3) and `TRIAGE_AGENT` (default `claude`).

## File Structure

```
lazy_vibe/register/
├── verify.py        # NEW: packet generation + schema-validated result consumption
├── policy.py        # NEW: triage-policy.yaml load/validate + first-match-wins apply
├── queue.py         # NEW: triage-queue.md render + interactive `triage` CLI walk
├── scope.py         # MODIFY: accept journeys (route-like) + claims_doc (informational)
├── cli.py           # MODIFY: verify-packets / verify-consume / triage / close verbs
└── __init__.py      # MODIFY: export new public symbols

tests/register/
├── test_verify.py       # NEW
├── test_policy.py       # NEW
├── test_queue.py        # NEW
├── test_scope.py        # MODIFY: journeys/claims_doc cases
└── test_cli_end_to_end.py  # MODIFY: triage walk, close, verify-consume e2e

run-triage.sh        # NEW: harness dispatch wrapper (agent per packet -> verify-consume)
README.md            # MODIFY: Plan 2b triage section
```

---

### Task 1: Verification packet generation (`verify.py` part 1)

Deterministic per-finding packets for `new` findings. One markdown packet per finding at `<register-dir>/triage/packets/R-NNNN.md`; the expected result path is `<register-dir>/triage/results/R-NNNN.json`. The packet states the structured output contract; the verifier returns it. A finding carrying a `fuzzy_match_candidate` history event additionally asks the verifier to confirm/deny the duplicate.

**Files:**
- Create: `lazy_vibe/register/verify.py`
- Test: `tests/register/test_verify.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_verify.py`:

```python
import json

import pytest

from lazy_vibe.register.store import RegisterStore
from lazy_vibe.register.verify import (RESULT_SCHEMA_VERSION, generate_packets,
                                       packet_path, result_path)
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def _new(fid="R-0001", **kw):
    return make_finding(finding_id=fid, disposition="new",
                        disposition_by="ingest", **kw)


def test_generate_packets_writes_one_per_new_finding(store):
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    written = generate_packets(store)
    assert {p.name for p in written} == {"R-0001.md", "R-0002.md"}
    assert packet_path(store, "R-0001").exists()
    text = packet_path(store, "R-0001").read_text()
    assert "R-0001" in text
    assert "VERIFIED" in text and "UNSUPPORTED" in text
    assert str(result_path(store, "R-0001")) in text
    assert "backend/routers/evidence.py:118" in text  # evidence ref echoed


def test_generate_packets_skips_non_new(store):
    from tests.register.helpers import with_history
    f_new = _new("R-0001")
    f_open = with_history(make_finding(finding_id="R-0002",
                                       fingerprint="sha256:bbbbbbbbbbbbbbbb",
                                       disposition="open", disposition_by="pete"))
    store.save({f_new.finding_id: f_new, f_open.finding_id: f_open})
    written = generate_packets(store)
    assert {p.name for p in written} == {"R-0001.md"}


def test_generate_packets_is_idempotent_and_regenerates(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    first = packet_path(store, "R-0001").read_text()
    generate_packets(store)
    assert packet_path(store, "R-0001").read_text() == first


def test_packet_for_fuzzy_candidate_asks_duplicate_question(store):
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "2026-06-01T00:00:00+00:00",
                      "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0002").read_text()
    assert "duplicate_of" in text
    assert "R-0001" in text


def test_packet_without_fuzzy_pins_duplicate_of_null(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    # contract still names duplicate_of but instructs null when no candidate
    assert "duplicate_of" in text
    assert "null" in text


def test_packet_documents_split_verdict(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    assert "split" in text  # collision/divergent-evidence escape hatch (spec §12)


def test_result_schema_version_is_stamped(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    generate_packets(store)
    assert f"schema_version: {RESULT_SCHEMA_VERSION}" in \
        packet_path(store, "R-0001").read_text()


def test_packet_paths_are_under_triage(store):
    assert packet_path(store, "R-0001").parent.name == "packets"
    assert result_path(store, "R-0001").parent.name == "results"
    assert packet_path(store, "R-0001").parent.parent.name == "triage"


def test_generate_packets_escapes_finding_text(store):
    f = _new("R-0001", title="bad ```fence``` and | pipe")
    store.save({f.finding_id: f})
    generate_packets(store)
    text = packet_path(store, "R-0001").read_text()
    # finding text is rendered inside a fenced JSON context block; the
    # triple-backtick fence in the title must not break the markdown fence
    assert "bad ` ` `fence` ` `" in text or "bad &#96;" in text or \
        "bad '''fence'''" in text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_verify.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'lazy_vibe.register.verify'`

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/verify.py`:

```python
"""Verification-packet generation and result consumption (spec §6 stage 1, §12).

Each `new` finding gets a deterministic markdown packet asking a verifier
agent the single triage question — *is it real?* — under an evidence-or-
disproof contract with a strict JSON output schema. Consumption
(schema_validate / consume_results) lives below; it appends a `verification`
history event and proposes false_positive on UNSUPPORTED, never transitioning
a protected state. Fuzzy-duplicate confirmation and collision split are
folded in: a confirmed duplicate proposes false_positive referencing the
original; a `split` verdict queues a manual item (auto-split is Plan 3).
"""
from __future__ import annotations

from pathlib import Path

from .store import RegisterStore

RESULT_SCHEMA_VERSION = 1

_TRIAGE_SUBDIR = "triage"


def _fence_safe(text: str) -> str:
    """Neutralize triple-backtick fences so finding text cannot break the
    packet's own fenced context block."""
    return text.replace("```", "` ` `")


def packet_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "packets" / f"{finding_id}.md"


def result_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "results" / f"{finding_id}.json"


def _fuzzy_candidate(finding) -> str | None:
    for event in reversed(finding.history):
        if event.get("event") == "fuzzy_match_candidate":
            return event.get("candidate_of")
    return None


def _render_packet(store: RegisterStore, finding) -> str:
    out = result_path(store, finding.finding_id)
    dup_hint = _fuzzy_candidate(finding)
    evidence = "\n".join(
        f"- {e.get('type', '?')}: `{e.get('ref', '-')}` "
        f"(run {e.get('run_id', '-')})" for e in finding.evidence) or "- (none)"
    dup_line = (
        f"This finding is a PROBABLE DUPLICATE of `{dup_hint}`. Confirm by "
        f"setting `duplicate_of` to `{dup_hint}` if the same underlying issue, "
        f"else `null`."
        if dup_hint else
        "No duplicate candidate; set `duplicate_of` to `null`.")
    return f"""\
# Verification packet — {finding.finding_id}

You are a verifier. Decide ONE question: **is this finding real?** Do not
decide how much effort it deserves. Return reproduction evidence or a
disproving citation — nothing else.

## Finding

- id: {finding.finding_id}
- severity: {finding.severity}
- taxonomy: {finding.taxonomy}
- path: `{_fence_safe(finding.fingerprint_inputs.get('path', '-'))}`
- symbol: `{_fence_safe(finding.fingerprint_inputs.get('symbol', '-'))}`
- title: {_fence_safe(finding.title)}

{_fence_safe(finding.description)}

### Cited evidence

{evidence}

## Your contract

{dup_line}

If the finding's evidence points at two materially different file sets that
are not the same defect, return verdict `split` and list the divergent
`split_paths` — a human will adjudicate (auto-split is not yet built).

schema_version: {RESULT_SCHEMA_VERSION}

Write EXACTLY this JSON object to `{out}` and nothing else:

    {{
      "schema_version": {RESULT_SCHEMA_VERSION},
      "finding_id": "{finding.finding_id}",
      "verdict": "VERIFIED | UNSUPPORTED | split",
      "evidence": ["path:line reproduction or disproving citation", "..."],
      "mechanism": "stated failure/exploit mechanism (VERIFIED) or why it is "
                   "not reachable (UNSUPPORTED)",
      "duplicate_of": "R-NNNN or null",
      "split_paths": ["only when verdict is split, else []"]
    }}

Rules: VERIFIED requires at least one `path:line` evidence entry and a
non-empty `mechanism`. UNSUPPORTED requires a disproving citation in
`evidence`. Never claim VERIFIED without a concrete reproduction.
"""


def generate_packets(store: RegisterStore) -> list[Path]:
    """Write one packet per `new` finding; return the packet paths."""
    written: list[Path] = []
    with store.locked():
        findings = store.load()
    packets_dir = store.register_dir / _TRIAGE_SUBDIR / "packets"
    packets_dir.mkdir(parents=True, exist_ok=True)
    (store.register_dir / _TRIAGE_SUBDIR / "results").mkdir(
        parents=True, exist_ok=True)
    for finding in sorted(findings.values(), key=lambda f: f.finding_id):
        if finding.disposition != "new":
            continue
        path = packet_path(store, finding.finding_id)
        path.write_text(_render_packet(store, finding))
        written.append(path)
    return written
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_verify.py -v` then `python3 -m pytest tests/register -q` — expect **168 passed**.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/verify.py tests/register/test_verify.py
git commit -m "feat(register): deterministic verification packet generation"
```

---

### Task 2: Verification result consumption (`verify.py` part 2)

Read each `R-NNNN.json`, schema-validate (deterministic fields only — `confidence` is omitted by contract), append a `verification` history event, and act: UNSUPPORTED proposes `false_positive`; a confirmed `duplicate_of` proposes `false_positive` referencing the original (the original absorbs the evidence); `split` appends a `split_proposed` event for the queue. VERIFIED leaves the finding `new` with a `verification` event marking it verifier-passed (policy/Pete still own the open transition). Malformed results are rejected loudly. The verifier NEVER transitions a protected state.

> **Quality-review hardening (post-implementation):** verifier output is treated as untrusted input. `_validate_result` rejects a self-referential `duplicate_of` (C1), non-string evidence elements named by index (C2), and non-string `duplicate_of`/`split_paths` (same root cause — a list `duplicate_of` crashed the batch with an unhashable TypeError). Duplicate absorb is restricted to targets in `{new, open, in_remediation, regressed}` so a verifier-controlled `duplicate_of` can never modify an adjudicated entry or pre-seed refs that suppress reopen proposals (I3); absorb dedups on ref alone (I1). Consumption is idempotent via a result-file lifecycle: after the register save succeeds, processed results (including stray results for non-new findings) are moved to `triage/results/consumed/R-NNNN.json` via `os.replace`, so re-runs find no pending results (I2). Validation failures leave the file in place and abort the batch before save.
>
> **Re-review (candidate binding):** a duplicate claim is only valid for the candidate the packet solicited — `_apply_verdict` requires `duplicate_of == _fuzzy_candidate(finding)` (the same helper `_render_packet` uses to pin the packet's duplicate question). Any other non-null `duplicate_of` (unsolicited target, nonexistent id, or a claim when the packet pinned null) raises "unsolicited duplicate claim"; a pinned candidate missing from the register raises "not in register" instead of the old silent fall-through to verified. Carry-forwards: `_archive_result` overwrites a prior consumed result on re-verification (Task 7 owner: consider run_id suffix or refuse-overwrite); `VerifyOutcome` buckets are per-run deltas, not a register census (Task 5 owner: the verify-consume summary must not present them as totals).

**Files:**
- Modify: `lazy_vibe/register/verify.py`
- Test: extend `tests/register/test_verify.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_verify.py`:

```python
from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.verify import consume_results, last_verification


def _write_result(store, fid, **payload):
    base = {"schema_version": RESULT_SCHEMA_VERSION, "finding_id": fid,
            "verdict": "VERIFIED", "evidence": [f"x.py:1"],
            "mechanism": "m", "duplicate_of": None, "split_paths": []}
    base.update(payload)
    p = result_path(store, fid)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(base))


def test_consume_verified_appends_event_and_stays_new(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    outcome = consume_results(store)
    findings = store.load()
    assert findings["R-0001"].disposition == "new"
    assert last_verification(findings["R-0001"])["verdict"] == "VERIFIED"
    assert findings["R-0001"].history[-1]["by"] == "agent:verifier"
    assert outcome.verified == ["R-0001"]


def test_consume_unsupported_proposes_false_positive(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="UNSUPPORTED",
                  evidence=["x.py:1 returns 404 for cross-tenant read"],
                  mechanism="route is account-scoped by dependency")
    consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "false_positive"
    assert f2.disposition_by == "policy:verifier-unsupported"


def test_consume_confirmed_duplicate_proposes_false_positive(store):
    orig = _new("R-0001")
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0001", verdict="VERIFIED")
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["x.py:1"])
    consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "false_positive"
    assert "R-0001" in findings["R-0002"].disposition_reason
    assert any(h.get("event") == "duplicate_confirmed"
               for h in findings["R-0002"].history)
    # original absorbs the duplicate's evidence ref
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "x.py:1" in refs


def test_consume_split_queues_event_and_keeps_new(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="split",
                  split_paths=["a.py:1", "b.py:2"])
    consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert any(h.get("event") == "split_proposed" for h in f2.history)


def test_consume_rejects_unknown_schema_version(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", schema_version=999)
    with pytest.raises(RegisterError, match="schema_version"):
        consume_results(store)


def test_consume_rejects_bad_verdict(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="MAYBE")
    with pytest.raises(RegisterError, match="verdict"):
        consume_results(store)


def test_consume_rejects_verified_without_evidence(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", evidence=[])
    with pytest.raises(RegisterError, match="evidence"):
        consume_results(store)


def test_consume_rejects_mismatched_finding_id(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", finding_id="R-0099")
    with pytest.raises(RegisterError, match="finding_id"):
        consume_results(store)


def test_consume_rejects_corrupt_json(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    p = result_path(store, "R-0001")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("{not json")
    with pytest.raises(RegisterError, match="corrupt"):
        consume_results(store)


def test_consume_never_touches_protected_state(store):
    from tests.register.helpers import with_history
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    store.save({fp.finding_id: fp})
    _write_result(store, "R-0001", verdict="UNSUPPORTED",
                  evidence=["x.py:1"], mechanism="m")
    outcome = consume_results(store)
    # no packet was generated for a non-new finding; a stray result is ignored
    assert store.load()["R-0001"].disposition == "false_positive"
    assert "R-0001" in outcome.skipped


def test_consume_missing_result_is_unverified(store):
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    _write_result(store, "R-0001", verdict="VERIFIED")
    outcome = consume_results(store)
    assert outcome.verified == ["R-0001"]
    assert outcome.unverified == ["R-0002"]  # no result file -> stays new


# ---------------------------------------------------------------------------
# Quality-review hardening: verifier-input attack paths + idempotency
# (added red-first during Task 2's quality review — C1/C2/I1/I2/I3)
# ---------------------------------------------------------------------------

def test_consume_rejects_self_duplicate(store):  # C1
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0001")
    with pytest.raises(RegisterError, match="duplicate of itself"):
        consume_results(store)
    # loud rejection aborts before save: finding stays new, untouched
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert last_verification(f2) is None


def test_consume_rejects_non_string_evidence(store):  # C2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED",
                  evidence=[{"ref": "x"}, None])
    with pytest.raises(RegisterError, match=r"evidence\[0\]"):
        consume_results(store)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"
    assert last_verification(f2) is None  # no polluted history event


def test_consume_rejects_non_string_duplicate_of(store):  # C2 root cause
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", duplicate_of=["R-0002"])
    with pytest.raises(RegisterError, match="duplicate_of"):
        consume_results(store)


def test_consume_rejects_non_string_split_paths(store):  # C2 root cause
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="split", split_paths=[1, "a.py"])
    with pytest.raises(RegisterError, match="split_paths"):
        consume_results(store)


def test_consume_refuses_duplicate_absorb_into_adjudicated(store):  # I3
    from tests.register.helpers import with_history
    orig = with_history(make_finding(finding_id="R-0001",
                                     disposition="false_positive",
                                     disposition_by="pete"))
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["y.py:9"])
    with pytest.raises(RegisterError, match="adjudicated"):
        consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "new"  # batch aborted, no save
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "y.py:9" not in refs  # adjudicated entry not tampered with


def test_consume_duplicate_absorb_into_active_target(store):  # I3
    from tests.register.helpers import with_history
    orig = with_history(make_finding(finding_id="R-0001", disposition="open",
                                     disposition_by="pete"))
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["y.py:9"])
    consume_results(store)
    findings = store.load()
    assert findings["R-0002"].disposition == "false_positive"
    refs = {e["ref"] for e in findings["R-0001"].evidence}
    assert "y.py:9" in refs  # active target absorbs the evidence


def test_absorb_dedups_on_ref_alone(store):  # I1
    orig = _new("R-0001")
    dup = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    dup.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                        "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, dup.finding_id: dup})
    # duplicate cites the exact ref the original already carries, but from a
    # different run -- (ref, run_id) keying would wrongly re-append it
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0001",
                  evidence=["backend/routers/evidence.py:118"])
    consume_results(store)
    refs = [e["ref"] for e in store.load()["R-0001"].evidence]
    assert refs.count("backend/routers/evidence.py:118") == 1


def test_consume_is_idempotent(store):  # I2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    first = consume_results(store)
    second = consume_results(store)
    events = [h for h in store.load()["R-0001"].history
              if h.get("event") == "verification"]
    assert len(events) == 1  # second run found no pending result
    assert first.verified == ["R-0001"]
    assert second.verified == []
    assert second.unverified == []  # already verified, not "unverified"
    assert second.false_positive == [] and second.split == []


def test_consumed_result_moves_to_consumed_dir(store):  # I2
    f = _new("R-0001")
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED")
    consume_results(store)
    assert not result_path(store, "R-0001").exists()
    consumed = (store.register_dir / "triage" / "results" / "consumed"
                / "R-0001.json")
    assert consumed.exists()


def test_stray_result_for_non_new_is_archived(store):  # I2
    from tests.register.helpers import with_history
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    store.save({fp.finding_id: fp})
    _write_result(store, "R-0001", verdict="UNSUPPORTED", evidence=["x.py:1"])
    consume_results(store)
    assert not result_path(store, "R-0001").exists()  # stray result archived


# --- Re-review: duplicate claims bound to the solicited fuzzy candidate ---

def test_consume_rejects_unsolicited_duplicate_claim(store):
    # packet pinned duplicate_of: null (no fuzzy candidate) -- the verifier
    # cannot close its own finding by naming an arbitrary real target
    f = _new("R-0001")
    other = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    store.save({f.finding_id: f, other.finding_id: other})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0002")
    with pytest.raises(RegisterError, match="unsolicited duplicate claim"):
        consume_results(store)
    findings = store.load()
    assert findings["R-0001"].disposition == "new"  # both findings untouched
    assert last_verification(findings["R-0001"]) is None
    refs = {e["ref"] for e in findings["R-0002"].evidence}
    assert "x.py:1" not in refs  # no evidence injected into the named target
    assert result_path(store, "R-0001").exists()  # nothing archived


def test_consume_rejects_duplicate_claim_for_wrong_candidate(store):
    # packet pinned R-0001; the verifier names a different (here nonexistent)
    # id -- previously a nonexistent duplicate_of vanished silently
    orig = _new("R-0001")
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({orig.finding_id: orig, f.finding_id: f})
    _write_result(store, "R-0002", verdict="VERIFIED", duplicate_of="R-0004")
    with pytest.raises(RegisterError, match="unsolicited duplicate claim"):
        consume_results(store)
    assert store.load()["R-0002"].disposition == "new"
    assert result_path(store, "R-0002").exists()  # nothing archived


def test_consume_rejects_pinned_candidate_missing_from_register(store):
    # register inconsistency: the pinned candidate id does not exist; a
    # matching duplicate claim must still fail loudly, never fall through
    # silently to verified (the pre-binding behavior)
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0099", "run_id": "run1"})
    store.save({f.finding_id: f})
    _write_result(store, "R-0001", verdict="VERIFIED", duplicate_of="R-0099")
    with pytest.raises(RegisterError, match="not in register"):
        consume_results(store)
    assert store.load()["R-0001"].disposition == "new"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_verify.py -v`
Expected: FAIL — `consume_results` / `last_verification` not defined.

- [ ] **Step 3: Implement**

> **Note (Task 1 review):** The consumption implementation (`VerifyOutcome`, `_now`, `last_verification`, `_validate_result`, `_absorb_duplicate_evidence`, `consume_results`, `_apply_verdict`) landed in `lazy_vibe/register/verify.py` as part of Task 1's commit. This step verifies it is correct via the tests above — no new code should be required.

Append to `lazy_vibe/register/verify.py` (add `import json`, `import os`, `from dataclasses import dataclass, field`, `from .model import RegisterError`, `from .transitions import transition` at the top; add `_now` helper; document the result-file lifecycle in the module docstring; add `consumed_result_path` next to `result_path`):

```python
_VALID_VERDICTS = {"VERIFIED", "UNSUPPORTED", "split"}
# Dispositions a confirmed duplicate may absorb evidence into. Adjudicated
# (false_positive/risk_accepted), parked, and fixed entries are off-limits:
# a verifier-controlled duplicate_of must never modify a protected entry or
# pre-seed refs that would suppress future reopen proposals.
_ABSORB_TARGETS = {"new", "open", "in_remediation", "regressed"}


def consumed_result_path(store: RegisterStore, finding_id: str) -> Path:
    """Where a successfully consumed result is archived (see module doc)."""
    return (store.register_dir / _TRIAGE_SUBDIR / "results" / "consumed"
            / f"{finding_id}.json")


@dataclass
class VerifyOutcome:
    # NOTE(Task 5): these buckets are "changed/observed THIS run", not a
    # register census — a re-run after full consumption legitimately returns
    # all-empty buckets. The verify-consume CLI summary must present them as
    # per-run deltas, never as register totals.
    verified: list[str] = field(default_factory=list)
    false_positive: list[str] = field(default_factory=list)
    split: list[str] = field(default_factory=list)
    unverified: list[str] = field(default_factory=list)   # new, never verified
    skipped: list[str] = field(default_factory=list)       # not new / stray


def _now(date: str | None) -> str:
    import datetime as _dt
    d = date or _dt.date.today().isoformat()
    return f"{d}T00:00:00+00:00"


def last_verification(finding) -> dict | None:
    for event in reversed(finding.history):
        if event.get("event") == "verification":
            return event
    return None


def _validate_result(finding_id: str, path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise RegisterError(f"corrupt verifier result {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RegisterError(f"{path}: verifier result must be a JSON object")
    if data.get("schema_version") != RESULT_SCHEMA_VERSION:
        raise RegisterError(
            f"{path}: unknown schema_version {data.get('schema_version')!r} "
            f"(expected {RESULT_SCHEMA_VERSION})")
    if data.get("finding_id") != finding_id:
        raise RegisterError(
            f"{path}: finding_id {data.get('finding_id')!r} does not match "
            f"packet {finding_id!r}")
    verdict = data.get("verdict")
    if verdict not in _VALID_VERDICTS:
        raise RegisterError(
            f"{path}: verdict {verdict!r} invalid "
            f"(valid: {sorted(_VALID_VERDICTS)})")
    _validate_evidence(path, verdict, data.get("evidence"))
    _validate_references(finding_id, path, data)
    return data


def _validate_evidence(path: Path, verdict: str, evidence) -> None:
    """Verifier output is untrusted: every evidence element must be a
    non-empty string before it reaches history events or evidence absorb."""
    if not isinstance(evidence, list):
        raise RegisterError(f"{path}: 'evidence' must be a list")
    for index, entry in enumerate(evidence):
        if not isinstance(entry, str) or not entry.strip():
            raise RegisterError(
                f"{path}: evidence[{index}] must be a non-empty string, "
                f"got {entry!r}")
    if verdict == "VERIFIED" and not evidence:
        raise RegisterError(
            f"{path}: VERIFIED requires at least one evidence entry")
    if verdict == "UNSUPPORTED" and not evidence:
        raise RegisterError(
            f"{path}: UNSUPPORTED requires a disproving citation in 'evidence'")


def _validate_references(finding_id: str, path: Path, data: dict) -> None:
    """Cross-reference fields are verifier-controlled: type-check them and
    reject a self-referential duplicate before it can close its own finding."""
    dup = data.get("duplicate_of")
    if dup is not None and not isinstance(dup, str):
        raise RegisterError(
            f"{path}: 'duplicate_of' must be a string or null, got {dup!r}")
    if dup == finding_id:
        raise RegisterError(
            f"{path}: a finding cannot be a duplicate of itself")
    split_paths = data.get("split_paths", [])
    if not isinstance(split_paths, list) or any(
            not isinstance(s, str) for s in split_paths):
        raise RegisterError(f"{path}: 'split_paths' must be a list of strings")


def _absorb_duplicate_evidence(original, dup_result: dict, run_id: str) -> None:
    # NOTE(M3): absorbed refs are verifier-controlled strings — the queue
    # render (Task 4) must pass them through markdown_cell before tabling.
    seen = {e.get("ref") for e in original.evidence}  # dedup on ref alone
    for ref in dup_result.get("evidence", []):
        if ref not in seen:
            original.evidence.append({"type": "audit", "ref": ref,
                                      "run_id": run_id})
            seen.add(ref)


def _archive_result(store: RegisterStore, finding_id: str) -> None:
    # NOTE(Task 7): os.replace overwrites a previously consumed result on
    # re-verification — the prior verifier output is lost. When run-triage.sh
    # lands, consider a run_id suffix (R-NNNN.<run_id>.json) or
    # refuse-overwrite so consumed results stay auditable per run.
    dst = consumed_result_path(store, finding_id)
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(result_path(store, finding_id), dst)


def consume_results(store: RegisterStore, *, date: str | None = None,
                    run_id: str = "verify") -> VerifyOutcome:
    """Schema-validate every pending result and apply its verdict.

    Verifier authority: it proposes false_positive (policy:verifier-*) and
    queues splits/duplicates. It never transitions a protected state and
    never opens a finding — policy/Pete own the open transition (spec §6).

    Successfully processed results (including stray results for non-new
    findings) are archived to triage/results/consumed/ AFTER the register
    save succeeds, so a mid-batch error leaves every pending result in place
    and persists nothing."""
    outcome = VerifyOutcome()
    now = _now(date)
    consumed: list[str] = []
    with store.locked():
        findings = store.load()
        for finding in sorted(findings.values(), key=lambda f: f.finding_id):
            fid = finding.finding_id
            path = result_path(store, fid)
            if finding.disposition != "new":
                outcome.skipped.append(fid)
                if path.exists():
                    consumed.append(fid)  # stray result: archive, never apply
                continue
            if not path.exists():
                if last_verification(finding) is None:
                    outcome.unverified.append(fid)
                continue
            data = _validate_result(fid, path)
            finding.history.append({
                "ts": now, "event": "verification",
                "verdict": data["verdict"], "by": "agent:verifier",
                "run_id": run_id, "evidence": data.get("evidence", [])})
            _apply_verdict(findings, finding, data, now, run_id, outcome)
            consumed.append(fid)
        store.save(findings)
        for fid in consumed:
            _archive_result(store, fid)
    return outcome


def _apply_verdict(findings, finding, data, now, run_id,
                   outcome: VerifyOutcome) -> None:
    verdict = data["verdict"]
    dup = data.get("duplicate_of")
    if verdict == "split":
        finding.history.append({"ts": now, "event": "split_proposed",
                                "split_paths": data.get("split_paths", []),
                                "by": "agent:verifier"})
        outcome.split.append(finding.finding_id)
        return
    if verdict == "VERIFIED" and dup is not None:
        # A duplicate claim is only valid for the candidate the packet
        # solicited (the reconciler's fuzzy_match_candidate). Anything else —
        # an unsolicited target, a nonexistent id, or a dup when the packet
        # pinned null — is the verifier closing its own finding via an
        # unconfirmed claim, rejected loudly.
        candidate = _fuzzy_candidate(finding)
        if dup != candidate:
            raise RegisterError(
                f"{finding.finding_id}: unsolicited duplicate claim {dup!r}; "
                f"packet pinned {candidate!r}")
        original = findings.get(dup)
        if original is None:
            raise RegisterError(
                f"{finding.finding_id}: duplicate target {dup} not in "
                f"register — fuzzy candidate references a missing finding")
        if original.disposition not in _ABSORB_TARGETS:
            raise RegisterError(
                f"{finding.finding_id}: duplicate target {dup} is adjudicated "
                f"({original.disposition}) — refusing to modify")
        _absorb_duplicate_evidence(original, data, run_id)
        finding.history.append({"ts": now, "event": "duplicate_confirmed",
                                "duplicate_of": dup, "by": "agent:verifier"})
        transition(finding, _D.FALSE_POSITIVE, by="policy:verifier-duplicate",
                   reason=f"confirmed duplicate of {dup}; evidence absorbed",
                   now=now)
        outcome.false_positive.append(finding.finding_id)
        return
    if verdict == "UNSUPPORTED":
        transition(finding, _D.FALSE_POSITIVE, by="policy:verifier-unsupported",
                   reason=f"verifier UNSUPPORTED: "
                          f"{data.get('mechanism', '')}"[:200],
                   now=now)
        outcome.false_positive.append(finding.finding_id)
        return
    outcome.verified.append(finding.finding_id)
```

Add `from .model import Disposition as _D` to the top imports.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_verify.py -v` then `python3 -m pytest tests/register -q` — expect **192 passed** (168 from Task 1 + 11 consumption tests + 10 quality-review hardening tests + 3 candidate-binding tests; downstream task totals below are shifted +13 accordingly).

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/verify.py tests/register/test_verify.py
git commit -m "feat(register): consume schema-validated verifier results"
```

---

### Task 3: Policy engine (`policy.py`)

`triage-policy.yaml` — ordered rules, first-match-wins, over `new` findings only. Match keys: `severity`, `taxonomy`, `in_scope`, `verified` (true requires the last `verification` event be VERIFIED), `theme`, `path_prefix`. Actions: `open` / `park` / `false_positive` (only if the last verification was UNSUPPORTED) / `propose_risk_accept` / `queue`. A `default` action is required. Hard-error on malformed policy at load time (like `scope.py`).

> **Quality-review fixes (post-implementation, red-first):** policy.yaml is operator-authored but mistakes must fail loudly, and policy must not defeat readiness. (C1) findings with an unresolved `_candidate:` theme are NOT adjudicable — readiness's vocabulary-gap guard (spec §12) only blocks `new` findings, so any policy disposition (even park) would silently drop them from blocking; `apply_policy` skips rule matching entirely and reports them in `PolicyOutcome.vocabulary_gaps`. (I1) match values are type-validated at load: `severity` must be a string in `SEVERITY_ORDER` (a list silently never matches), `taxonomy`/`theme`/`path_prefix` must be strings, `in_scope`/`verified` must be real YAML booleans (`in_scope: "false"` bool-coerces truthy and matches the OPPOSITE set); `_matches` therefore compares without coercion. (I2) `propose_risk_accept` is idempotent — a finding whose history already carries a `risk_accept_proposed` event (any rule) is skipped, so policy re-runs do not stack duplicate proposals. (M1) an empty/omitted `match` block is a load-time hard error ("use the 'default' action for catch-all") instead of matching everything. (M2) the dead `findings` param was dropped from `_act`. (M3) the `risk_accept_proposed` event carries a displayable `reason` (`proposed by policy:<rule-id>`) for the Task 4 queue render.

**Files:**
- Create: `lazy_vibe/register/policy.py`
- Test: `tests/register/test_policy.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_policy.py`:

```python
import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.policy import apply_policy, load_policy
from lazy_vibe.register.store import RegisterStore
from tests.register.test_model import make_finding

POLICY_YAML = """\
rules:
  - id: p0-security-in-scope
    match: {severity: P0, taxonomy: S, in_scope: true, verified: true}
    action: open
  - id: out-of-scope-p3
    match: {in_scope: false, severity: P3}
    action: park
  - id: verified-fp
    match: {verified: false}
    action: false_positive
default: queue
"""


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


@pytest.fixture
def policy(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text(POLICY_YAML)
    return load_policy(p)


def _new(fid="R-0001", verdict=None, **kw):
    f = make_finding(finding_id=fid, disposition="new",
                     disposition_by="ingest", **kw)
    if verdict is not None:
        f.history.append({"ts": "t", "event": "verification",
                          "verdict": verdict, "by": "agent:verifier"})
    return f


def test_load_policy_parses(policy):
    assert [r.rule_id for r in policy.rules] == [
        "p0-security-in-scope", "out-of-scope-p3", "verified-fp"]
    assert policy.default == "queue"


def test_first_match_wins_open(store, policy):
    f = _new("R-0001", severity="P0", taxonomy="S", in_scope=True,
             verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    f2 = store.load()["R-0001"]
    assert f2.disposition == "open"
    assert f2.disposition_by == "policy:p0-security-in-scope"
    assert outcome.opened == ["R-0001"]


def test_out_of_scope_p3_parks(store, policy):
    f = _new("R-0001", severity="P3", in_scope=False, verdict="VERIFIED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "parked"


def test_unverified_false_positive_only_when_unsupported(store, tmp_path):
    # the false_positive action requires the last verification == UNSUPPORTED
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: fp\n    match: {severity: P2}\n"
                 "    action: false_positive\ndefault: queue\n")
    policy = load_policy(p)
    bad = _new("R-0001", severity="P2", verdict="VERIFIED")
    store.save({bad.finding_id: bad})
    with pytest.raises(RegisterError, match="UNSUPPORTED"):
        apply_policy(store, policy, date="2026-06-11")


def test_false_positive_with_unsupported(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: fp\n    match: {severity: P2}\n"
                 "    action: false_positive\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P2", verdict="UNSUPPORTED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "false_positive"


def test_verified_match_requires_verified_event(store, policy):
    # p0-security match requires verified:true; an unverified P0/S must NOT open
    f = _new("R-0001", severity="P0", taxonomy="S", in_scope=True)  # no event
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    # falls through verified-fp (verified:false) -> false_positive? No:
    # verified-fp action false_positive requires UNSUPPORTED, which is absent,
    # so it errors? No — the rule MATCHES on verified:false but its action is
    # gated; gate failure on a non-default rule is a hard policy error.
    # Therefore this finding must reach `default: queue` only if verified-fp
    # does not match. It DOES match (verified false). Assert the error path:
    # (kept deterministic — see test_unverified_false_positive_only...).
    assert store.load()["R-0001"].disposition in ("new",)


def test_propose_risk_accept_queues_not_transitions(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: ra\n    match: {severity: P1}\n"
                 "    action: propose_risk_accept\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P1", verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"  # proposals never auto-transition (§4.2)
    events = [h for h in f2.history
              if h.get("event") == "risk_accept_proposed"]
    assert len(events) == 1
    # the queue render (Task 4) needs a displayable reason on the event
    assert events[0].get("reason") == "proposed by policy:ra"
    assert "R-0001" in outcome.proposed_risk_accept


def test_default_queue_leaves_new(store, policy):
    f = _new("R-0001", severity="P2", in_scope=True, verdict="VERIFIED")
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "new"
    assert "R-0001" in outcome.queued


def test_path_prefix_and_theme_match(store, tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: ev\n    match: "
                 "{path_prefix: 'backend/routers/', theme: tenant_scope_missing}"
                 "\n    action: open\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P1", verdict="VERIFIED")
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "open"


def test_only_processes_new(store, tmp_path, policy):
    from tests.register.helpers import with_history
    f = with_history(make_finding(disposition="open", disposition_by="pete"))
    store.save({f.finding_id: f})
    apply_policy(store, policy, date="2026-06-11")
    assert store.load()["R-0001"].disposition == "open"  # untouched


def test_missing_policy_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="triage-policy"):
        load_policy(tmp_path / "triage-policy.yaml")


def test_missing_default_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {severity: P0}\n    action: open\n")
    with pytest.raises(RegisterError, match="default"):
        load_policy(p)


def test_bad_action_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {severity: P0}\n"
                 "    action: explode\ndefault: queue\n")
    with pytest.raises(RegisterError, match="action"):
        load_policy(p)


def test_bad_match_key_is_hard_error(tmp_path):
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {wat: 1}\n    action: open\n"
                 "default: queue\n")
    with pytest.raises(RegisterError, match="match key"):
        load_policy(p)


# ---------------------------------------------------------------------------
# Quality-review fixes: candidate-theme guard, typed match validation,
# idempotent proposals, non-empty match (C1/I1/I2/M1)
# ---------------------------------------------------------------------------


def test_candidate_theme_is_not_adjudicable(store, tmp_path):  # C1
    # spec §12: vocabulary gaps cannot leak findings. Readiness's _candidate
    # guard only blocks `new` findings — if a catch-all park rule adjudicates
    # one, it vanishes from blocking. Policy must refuse to match it at all.
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: park-all\n    match: {in_scope: true}\n"
                 "    action: park\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", in_scope=True, verdict="VERIFIED")
    f.fingerprint_inputs["theme"] = "_candidate:weird"
    store.save({f.finding_id: f})
    outcome = apply_policy(store, policy, date="2026-06-11")
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"  # never parked past the readiness guard
    assert outcome.vocabulary_gaps == ["R-0001"]
    assert outcome.parked == []
    # readiness still blocks it
    from lazy_vibe.register.readiness import evaluate
    from lazy_vibe.register.scope import load_scope
    sp = tmp_path / "launch-scope.yaml"
    sp.write_text("product: meridian\ndefault_in_scope: true\nsurfaces: []\n"
                  "severity_bar:\n  P0: zero_open\n")
    report = evaluate(store, load_scope(sp), today="2026-06-11")
    assert report.ready is False
    assert any("_candidate" in item for item in report.blocking)


def test_list_severity_match_value_is_hard_error(tmp_path):  # I1
    # severity: [P0, P1] would silently never match (string != list)
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {severity: [P0, P1]}\n"
                 "    action: open\ndefault: queue\n")
    with pytest.raises(RegisterError, match=r"severity.*\['P0', 'P1'\]"):
        load_policy(p)


def test_string_bool_match_value_is_hard_error(tmp_path):  # I1
    # in_scope: "false" bool-coerces truthy and matches the OPPOSITE set
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {in_scope: 'false'}\n"
                 "    action: park\ndefault: queue\n")
    with pytest.raises(RegisterError, match="in_scope.*'false'"):
        load_policy(p)


def test_propose_risk_accept_is_idempotent(store, tmp_path):  # I2
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: ra\n    match: {severity: P1}\n"
                 "    action: propose_risk_accept\ndefault: queue\n")
    policy = load_policy(p)
    f = _new("R-0001", severity="P1", verdict="VERIFIED")
    store.save({f.finding_id: f})
    first = apply_policy(store, policy, date="2026-06-11")
    second = apply_policy(store, policy, date="2026-06-12")
    events = [h for h in store.load()["R-0001"].history
              if h.get("event") == "risk_accept_proposed"]
    assert len(events) == 1  # second run did not re-append
    assert first.proposed_risk_accept == ["R-0001"]
    assert second.proposed_risk_accept == []  # per-run delta, not re-listed


def test_empty_match_is_hard_error(tmp_path):  # M1
    # an empty/omitted match block would match everything; catch-all intent
    # must be expressed through the explicit 'default' action
    p = tmp_path / "triage-policy.yaml"
    p.write_text("rules:\n  - id: x\n    match: {}\n    action: open\n"
                 "default: queue\n")
    with pytest.raises(RegisterError, match="empty match"):
        load_policy(p)
    p.write_text("rules:\n  - id: x\n    action: open\ndefault: queue\n")
    with pytest.raises(RegisterError, match="empty match"):
        load_policy(p)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_policy.py -v`
Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement**

Create `lazy_vibe/register/policy.py`:

```python
"""Deterministic triage policy engine (spec §6 stage 2).

`triage-policy.yaml` is an ordered, first-match-wins rule list over `new`
findings. Every auto-disposition is stamped `policy:<rule-id>`; proposals
(`propose_risk_accept`) never transition (spec §4.2 — risk acceptance is
Pete-only) but append a `risk_accept_proposed` event for the queue. The
`false_positive` action is only legal when the last verification verdict is
UNSUPPORTED (spec §6); using it otherwise is a hard error so policy authors
cannot silently suppress real findings.

Findings whose theme is an unresolved `_candidate:` vocabulary gap are not
adjudicable by policy at all (spec §12): readiness's vocabulary-gap guard
only blocks `new` findings, so any policy disposition (even park) would move
the finding past that guard and silently drop it from blocking. They stay
`new` and are reported in `PolicyOutcome.vocabulary_gaps`.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .fingerprint import normalize_path
from .model import SEVERITY_ORDER, Disposition, Finding, RegisterError
from .transitions import transition
from .verify import last_verification

_VALID_ACTIONS = {"open", "park", "false_positive", "propose_risk_accept",
                  "queue"}
_VALID_MATCH_KEYS = {"severity", "taxonomy", "in_scope", "verified", "theme",
                     "path_prefix"}
# Match-value types are validated at load time so a mistyped policy fails
# loudly instead of silently never matching (severity: [P0, P1]) or matching
# the OPPOSITE set (in_scope: "false" is a truthy string under bool()).
_STR_MATCH_KEYS = ("taxonomy", "theme", "path_prefix")
_BOOL_MATCH_KEYS = ("in_scope", "verified")


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
    vocabulary_gaps: list[str] = field(default_factory=list)  # spec §12


def _now(date: str) -> str:
    return f"{date}T00:00:00+00:00"


def _validate_match_values(path: Path, rule_id: str, match: dict) -> None:
    """Hard-reject mistyped match values at load time (see module doc)."""
    if "severity" in match:
        sev = match["severity"]
        if not isinstance(sev, str) or sev not in SEVERITY_ORDER:
            raise RegisterError(
                f"{path}: rule {rule_id!r}: match key 'severity' must be one "
                f"of {sorted(SEVERITY_ORDER)}, got {sev!r}")
    for key in _STR_MATCH_KEYS:
        if key in match and not isinstance(match[key], str):
            raise RegisterError(
                f"{path}: rule {rule_id!r}: match key {key!r} must be a "
                f"string, got {match[key]!r}")
    for key in _BOOL_MATCH_KEYS:
        if key in match and not isinstance(match[key], bool):
            raise RegisterError(
                f"{path}: rule {rule_id!r}: match key {key!r} must be a YAML "
                f"boolean (true/false), got {match[key]!r}")


def _load_rule(path: Path, index: int, raw) -> Rule:
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
    if not match:
        raise RegisterError(
            f"{path}: rule {raw['id']!r}: empty match — use the 'default' "
            f"action for catch-all")
    unknown = set(match) - _VALID_MATCH_KEYS
    if unknown:
        raise RegisterError(
            f"{path}: rule {raw['id']!r}: unknown match key(s) "
            f"{sorted(unknown)} (valid: {sorted(_VALID_MATCH_KEYS)})")
    _validate_match_values(path, raw["id"], match)
    return Rule(rule_id=raw["id"], match=dict(match), action=action)


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
    rules = [_load_rule(path, index, raw)
             for index, raw in enumerate(data.get("rules") or [])]
    return Policy(rules=tuple(rules), default=data["default"])


def _verified(finding: Finding) -> bool:
    event = last_verification(finding)
    return bool(event) and event.get("verdict") == "VERIFIED"


def _matches(finding: Finding, match: dict) -> bool:
    # match values are type-validated at load time; compare without coercion
    for key, want in match.items():
        if key == "severity" and finding.severity != want:
            return False
        if key == "taxonomy" and finding.taxonomy != want:
            return False
        if key == "in_scope" and finding.in_scope != want:
            return False
        if key == "verified" and _verified(finding) != want:
            return False
        if key == "theme" and finding.fingerprint_inputs.get("theme") != want:
            return False
        if key == "path_prefix" and not normalize_path(
                finding.fingerprint_inputs.get("path", "")).startswith(want):
            return False
    return True


def _already_proposed(finding: Finding) -> bool:
    return any(h.get("event") == "risk_accept_proposed"
               for h in finding.history)


def _act(finding, action, rule_id, now, outcome: PolicyOutcome) -> None:
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
        if _already_proposed(finding):
            return  # idempotent: a proposal is already pending Pete's decision
        finding.history.append({"ts": now, "event": "risk_accept_proposed",
                                "by": by, "rule": rule_id,
                                "reason": f"proposed by {by}"})
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
            if finding.fingerprint_inputs.get("theme", "").startswith(
                    "_candidate:"):
                # spec §12: vocabulary gaps cannot leak findings — readiness
                # only blocks _candidate themes while `new`, so policy must
                # not adjudicate them (a park would drop them from blocking).
                outcome.vocabulary_gaps.append(finding.finding_id)
                continue
            action = policy.default
            for rule in policy.rules:
                if _matches(finding, rule.match):
                    action = rule.action
                    rule_id = rule.rule_id
                    break
            else:
                rule_id = "default"
            _act(finding, action, rule_id, now, outcome)
        store.save(findings)
    return outcome
```

> **Note on `test_verified_match_requires_verified_event`:** with `POLICY_YAML`,
> an unverified P0/S finding matches `verified-fp` (`verified:false`) whose
> action is `false_positive`, which then hard-errors (no UNSUPPORTED verdict).
> Rewrite that test to assert the `RegisterError`. Keep the assertion in the
> test file aligned with the engine; the inline comment above documents the
> reasoning. (Corrected form below — use this, not the placeholder above.)

```python
def test_verified_match_requires_verified_event(store, policy):
    f = _new("R-0001", severity="P0", taxonomy="S", in_scope=True)  # no event
    store.save({f.finding_id: f})
    # p0-security needs verified:true (absent) -> falls to verified-fp
    # (verified:false) whose false_positive action needs UNSUPPORTED -> error.
    with pytest.raises(RegisterError, match="UNSUPPORTED"):
        apply_policy(store, policy, date="2026-06-11")
```

- [ ] **Step 2 (re-run): verify the corrected test fails for the right reason**

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_policy.py -v` then `python3 -m pytest tests/register -q` — expect **211 passed** (192 from Task 2 + 19 policy tests: 14 original + 5 quality-review fixes; downstream task totals below are shifted +5 accordingly).

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/policy.py tests/register/test_policy.py
git commit -m "feat(register): deterministic triage-policy engine"
```

> The quality-review fixes (C1/I1/I2/M1/M2/M3 above) landed red-first in a
> follow-up commit: `fix(register): policy engine — candidate-theme guard,
> typed match validation, idempotent proposals`.

---

### Task 4: Queue render (`queue.py` part 1)

Render `<register-dir>/triage-queue.md` with sections, each derived deterministically from register state (no recomputation of reconciler signals — the events already exist):

1. **Proposed risk acceptances** — findings with a `risk_accept_proposed` history event (from policy), still `new`.
2. **Past-due risk acceptances** — `risk_accepted` findings whose `review_by` is before `today` (mirrors readiness's past-due check; recommendation "reaffirm or open").
3. **Severity reviews** — `severity_review_proposed` events on adjudicated entries.
4. **Reopen proposals** — `suppressed_occurrence` events whose run evidence ref differs from all existing evidence refs (materially-different evidence against a protected/parked state; identical-evidence suppression is silent per spec §4.2). One row per DISTINCT novel ref; historical events without a `ref` are skipped.
5. **Scope proposals** — produced by `scope.recompute`, passed in.
6. **Unverified findings** — `new` findings with no `verification` history event (spec §12: verifier failure stays `new`, surfaces here). Render caps this section at the first 20 by severity plus an overflow line (real registers hold hundreds).
7. **Fuzzy confirms pending** — `new` findings with a `fuzzy_match_candidate` event but no `verification` event yet.

> **Cell-escaping deviation (T4 implementation):** the original plan rendered `i.recommendation` raw in the table row. The T2-review carry-forward requires EVERY free-text value rendered into triage-queue.md to go through `markdown_cell` — title, detail, AND recommendation. Corrected in the implementation; `test_render_escapes_pipe_in_recommendation` proves it red-first.
>
> **Quality-review fixes (post-implementation, red-first):** (C1) the reconciler's suppression branch wrote `suppressed_occurrence` events with NO `ref`, so the queue's reopen gate could never fire on production data — `reconcile.py` now stamps `"ref": f"{normalize_path(candidate.path)}:{candidate.line}"` on the event; the queue keeps the novelty comparison and TOLERATES historical events without a ref (skips them — existing meridian/portal registers carry them). Proven by integration tests driving the real reconcile→build_queue cycle with no hand-fabricated events. (C2) past-due risk acceptances were invisible to the queue: `build_queue` gains a required ISO `today` parameter (malformed → `RegisterError`, mirroring `readiness.evaluate`) and emits `risk_review` items for `risk_accepted` findings with `review_by < today` (detail shows the review_by date; recommendation "reaffirm or open"). (I1) reopen rows dedup by distinct novel ref within a finding — repeated suppressions citing the same novel evidence are one decision, not one row per run. (M1) the unverified section renders at most 20 rows (severity-sorted) then `…and N more — run verify-packets / run-triage.sh` — 397 rows on the real Meridian register is a re-run signal, not a decision list. (M2) dead `QueueItem.extra` dropped. (M3) `build_queue` docstring corrected: it acquires the exclusive register lock for a consistent snapshot but writes nothing.

**Files:**
- Create: `lazy_vibe/register/queue.py`
- Modify: `lazy_vibe/register/reconcile.py` (C1 — stamp `ref` on `suppressed_occurrence`)
- Test: `tests/register/test_queue.py`; `tests/register/test_reconcile.py` pins the event ref

- [ ] **Step 1: Write the failing tests**

Create `tests/register/test_queue.py`:

```python
import pytest

from lazy_vibe.register.fingerprint import compute
from lazy_vibe.register.ingest import Candidate
from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.queue import QueueItem, build_queue, render_queue
from lazy_vibe.register.reconcile import reconcile
from lazy_vibe.register.scope import ScopeProposal
from lazy_vibe.register.store import RegisterStore
from tests.register.helpers import with_history
from tests.register.test_model import make_finding


@pytest.fixture
def store(tmp_path):
    return RegisterStore(tmp_path / "register")


def _new(fid="R-0001", **kw):
    return make_finding(finding_id=fid, disposition="new",
                        disposition_by="ingest", **kw)


def test_risk_accept_proposal_section(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:dev-dep", "rule": "dev-dep"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    kinds = {i.kind for i in items}
    assert "risk_accept" in kinds


def test_severity_review_section(store):
    f = with_history(make_finding(finding_id="R-0001", disposition="open",
                                  disposition_by="pete",
                                  severity_source="adjudicated"))
    f.history.append({"ts": "t", "event": "severity_review_proposed",
                      "current": "P2", "proposed": "P0", "run_id": "run2"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "severity_review" and i.finding_id == "R-0001"
               for i in items)


def test_reopen_proposal_on_materially_different_evidence(store):
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    # existing evidence ref is backend/routers/evidence.py:118 (make_finding)
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/other.py:9"})  # new ref
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "reopen" for i in items)


def test_no_reopen_on_identical_evidence(store):
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/routers/evidence.py:118"})  # identical
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_scope_proposals_section(store):
    f = _new("R-0001")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[
        ScopeProposal("R-0001", "park", "left scope")], today="2026-06-11")
    assert any(i.kind == "scope" for i in items)


def test_unverified_section(store):
    f = _new("R-0001")  # new, no verification event
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "unverified" and i.finding_id == "R-0001"
               for i in items)


def test_verified_new_not_in_unverified(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "unverified" for i in items)


def test_fuzzy_confirm_pending_section(store):
    f = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f.history.append({"ts": "t", "event": "fuzzy_match_candidate",
                      "candidate_of": "R-0001", "run_id": "run1"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert any(i.kind == "fuzzy_confirm" for i in items)


def test_render_queue_groups_sections(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "Triage queue" in md
    assert "Proposed risk acceptances" in md
    assert "R-0001" in md


def test_render_empty_queue(store):
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "no items" in md.lower()


# ---------------------------------------------------------------------------
# Cell-escaping: every free-text value rendered into table cells must go
# through markdown_cell (hard requirement from T2 review carry-forward).
# Verifier-supplied evidence refs may contain | and newlines — injection
# vectors flagged in NOTE(M3) in verify.py.
# ---------------------------------------------------------------------------

def test_render_escapes_pipe_in_title(store):
    """Title with | must not break the markdown table."""
    f = _new("R-0001", title="foo | bar | baz")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    # Unescaped | would create extra columns; check the title cell is escaped
    assert "foo \\| bar \\| baz" in md


def test_render_escapes_newline_in_detail(store):
    """Detail containing newline must be collapsed to a single line."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    # ref with embedded newline — verifier-supplied injection vector
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/evil.py:9\nINJECTED"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    # The newline must not survive into the rendered table
    assert "INJECTED\n" not in md


def test_render_escapes_pipe_in_reopen_detail(store):
    """Reopen detail built from verifier-supplied ref must escape pipes."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2",
                       "ref": "backend/core/evil.py:9 | malicious"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "\\|" in md


def test_render_escapes_pipe_in_recommendation(store):
    """Recommendation field is free-text and must go through markdown_cell."""
    # Simulate a scope proposal whose reason/kind contains a pipe — any
    # free-text that reaches the table must be escaped.
    f = _new("R-0001")
    store.save({f.finding_id: f})
    # ScopeProposal.kind can be "park" or "open" (literal) but the
    # QueueItem.recommendation is built from it; any free-text value must
    # be escaped. We inject directly into a QueueItem to test render isolation.
    item = QueueItem("R-0001", "scope", "P1", "safe title",
                     "safe detail", recommendation="park | INJECTED")
    md = render_queue([item], product="meridian")
    assert "park \\| INJECTED" in md


def test_render_is_deterministic(store):
    """Same register state produces byte-identical output on repeated calls."""
    f1 = _new("R-0001")
    f2 = _new("R-0002", fingerprint="sha256:bbbbbbbbbbbbbbbb")
    f1.history.append({"ts": "t", "event": "risk_accept_proposed",
                       "by": "policy:x", "rule": "x"})
    store.save({f1.finding_id: f1, f2.finding_id: f2})
    items_a = build_queue(store, scope_proposals=[], today="2026-06-11")
    items_b = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert render_queue(items_a, product="meridian") == \
        render_queue(items_b, product="meridian")


def test_build_queue_does_not_mutate_register(store):
    """build_queue is a pure projection — no store.save, no history events."""
    f = _new("R-0001")
    store.save({f.finding_id: f})
    # record the history length before
    before = store.load()["R-0001"].history[:]
    build_queue(store, scope_proposals=[], today="2026-06-11")
    after = store.load()["R-0001"].history
    assert before == after


# ---------------------------------------------------------------------------
# C1 — reopen proposals must fire on REAL reconciler output, not only on
# hand-fabricated events: reconcile's suppression branch must stamp the
# occurrence's evidence ref on the suppressed_occurrence event so the
# queue's novelty comparison has something to compare.
# ---------------------------------------------------------------------------

_VOCAB = {"tenant_scope_missing": ["tenant scope"]}


def _risk_accepted_existing():
    """Register entry whose fingerprint matches _cand() exactly."""
    fp = compute("product_gap", "tenant_scope_missing",
                 "backend/routers/evidence.py", "-")
    return with_history(make_finding(
        fingerprint=fp, disposition="risk_accepted", disposition_by="pete",
        review_by="2026-12-01"))


def _cand(line="118"):
    return Candidate(blocker_id="B-0001", category="product_gap",
                     theme_raw="tenant_scope_missing", severity="P1",
                     path="backend/routers/evidence.py", line=line,
                     title="Evidence list endpoint not tenant-scoped",
                     references=f"backend/routers/evidence.py:{line}",
                     run_id="run2")


def test_reconcile_novel_ref_suppression_yields_one_reopen(store):
    """Full cycle: reconcile a candidate matching a risk_accepted finding at
    a NOVEL line -> the queue must show exactly one reopen item."""
    f = _risk_accepted_existing()  # existing evidence ref ...evidence.py:118
    store.save({f.finding_id: f})
    reconcile(store, [_cand(line="999")], _VOCAB,
              run_id="run2", date="2026-06-11")
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reopen = [i for i in items if i.kind == "reopen"]
    assert len(reopen) == 1
    assert reopen[0].finding_id == "R-0001"
    assert "backend/routers/evidence.py:999" in reopen[0].detail


def test_reconcile_same_ref_suppression_yields_no_reopen(store):
    """Full cycle: suppression at the SAME ref as existing evidence is
    silent (spec §4.2) — no reopen item."""
    f = _risk_accepted_existing()
    store.save({f.finding_id: f})
    reconcile(store, [_cand(line="118")], _VOCAB,
              run_id="run2", date="2026-06-11")
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_historical_suppression_event_without_ref_is_skipped(store):
    """Pre-C1 registers (meridian/portal) carry suppressed_occurrence events
    with no ref — the queue must tolerate them, not crash or false-flag."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2"})  # no ref key (historical shape)
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "reopen" for i in items)


def test_reopen_rows_dedup_by_distinct_novel_ref(store):  # I1
    """Two suppressions citing the SAME novel ref -> one reopen row."""
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    for run in ("run2", "run3"):
        fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                           "run_id": run, "ref": "backend/core/other.py:9"})
    store.save({fp.finding_id: fp})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reopen = [i for i in items if i.kind == "reopen"]
    assert len(reopen) == 1


# ---------------------------------------------------------------------------
# C2 — past-due risk acceptances surface in the queue. build_queue takes a
# required ISO `today` (mirrors readiness.evaluate); risk_accepted findings
# whose review_by is in the past get a risk_review item.
# ---------------------------------------------------------------------------

def _risk_accepted(fid="R-0001", review_by="2026-01-01"):
    return with_history(make_finding(finding_id=fid,
                                     disposition="risk_accepted",
                                     disposition_by="pete",
                                     review_by=review_by))


def test_past_due_risk_review_appears_once(store):
    f = _risk_accepted(review_by="2026-01-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    reviews = [i for i in items if i.kind == "risk_review"]
    assert len(reviews) == 1
    assert reviews[0].finding_id == "R-0001"
    assert "2026-01-01" in reviews[0].detail  # review_by date is displayed
    assert reviews[0].recommendation == "reaffirm or open"


def test_future_dated_risk_review_not_queued(store):
    f = _risk_accepted(review_by="2026-12-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    assert not any(i.kind == "risk_review" for i in items)


def test_build_queue_rejects_malformed_today(store):
    with pytest.raises(RegisterError, match="ISO"):
        build_queue(store, scope_proposals=[], today="June 11th 2026")


def test_render_shows_risk_review_section(store):
    f = _risk_accepted(review_by="2026-01-01")
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "Past-due risk acceptances" in md
    assert "2026-01-01" in md


# ---------------------------------------------------------------------------
# M1 — the unverified section is capped at 20 rows (397 on real data):
# total count in the heading, first 20 by severity, then an overflow line.
# ---------------------------------------------------------------------------

def test_unverified_section_caps_at_20_rows(store):
    findings = {}
    for i in range(1, 26):  # 25 unverified new findings
        fid = f"R-{i:04d}"
        findings[fid] = _new(fid, fingerprint=f"sha256:{i:016x}")
    store.save(findings)
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    md = render_queue(items, product="meridian")
    assert "## Unverified findings (25)" in md  # heading keeps the total
    section = md.split("## Unverified findings")[1]
    rows = [ln for ln in section.splitlines() if ln.startswith("| R-")]
    assert len(rows) == 20  # capped
    assert "…and 5 more — run verify-packets / run-triage.sh" in md
```

Also pin the event ref in `tests/register/test_reconcile.py` (`test_match_on_protected_disposition_suppresses`):

```python
    assert loaded.history[-1]["event"] == "suppressed_occurrence"
    # the event must carry the occurrence's evidence ref so the triage queue
    # can compare it against existing evidence for reopen proposals (C1)
    assert loaded.history[-1]["ref"] == "backend/routers/evidence.py:118"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_queue.py -v`
Expected: FAIL with `ModuleNotFoundError`. (Quality-review red runs: C1 integration `assert 0 == 1` — no reopen item from real reconciler output; I1 `assert 2 == 1`; C2/M1 `TypeError: build_queue() got an unexpected keyword argument 'today'`.)

- [ ] **Step 3: Implement**

In `lazy_vibe/register/reconcile.py`, stamp the occurrence's evidence ref on the suppression event (C1):

```python
                if existing.disposition in {d.value for d in PROTECTED_DISPOSITIONS} \
                        or existing.disposition == Disposition.PARKED.value:
                    # The occurrence's evidence ref rides on the event so the
                    # triage queue can compare it against existing evidence:
                    # a NOVEL ref against a protected/parked state becomes a
                    # reopen proposal; an identical ref stays silent (§4.2).
                    existing.history.append({
                        "ts": _now(date),
                        "event": "suppressed_occurrence",
                        "run_id": run_id,
                        "ref": f"{normalize_path(candidate.path)}:"
                               f"{candidate.line}"})
                    result.suppressed.append(existing)
```

Create `lazy_vibe/register/queue.py`:

```python
"""Pete's triage queue: render + interactive walk (spec §6 stage 3).

The queue is a deterministic projection of register state — every item maps
to a history event already written by verify/policy/reconcile/scope. Building
the queue never mutates the register; only the interactive `triage` walk
(part 2) writes dispositions, always stamped `pete` through transition() /
reaffirm_risk().

Cell-escaping rule: every free-text value rendered into triage-queue.md table
cells — titles, reasons, evidence refs, theme names, recommendations — goes
through ``markdown_cell`` from store.py. Verifier-supplied evidence refs may
contain ``|`` and newlines (injection vector flagged in NOTE(M3) in verify.py).
``render_queue`` is the sole choke-point: it calls ``markdown_cell`` on
``title``, ``detail``, AND ``recommendation`` before writing any cell.
"""
from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass

from .model import PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Finding, RegisterError
from .scope import ScopeProposal
from .store import RegisterStore, markdown_cell

_SECTIONS = [
    ("risk_accept", "Proposed risk acceptances"),
    ("risk_review", "Past-due risk acceptances"),
    ("severity_review", "Severity reviews"),
    ("reopen", "Reopen proposals (protected/parked, new evidence)"),
    ("scope", "Scope proposals"),
    ("unverified", "Unverified findings"),
    ("fuzzy_confirm", "Fuzzy duplicate confirms pending"),
]
_PROTECTED = {d.value for d in PROTECTED_DISPOSITIONS} | {"parked"}
# The unverified section is a bulk re-run signal, not a per-item decision
# list — on real registers it would render hundreds of rows (meridian: 397).
_UNVERIFIED_RENDER_CAP = 20


@dataclass
class QueueItem:
    finding_id: str
    kind: str
    severity: str
    title: str
    detail: str
    recommendation: str = ""


def _has_event(finding: Finding, event: str) -> bool:
    return any(h.get("event") == event for h in finding.history)


def _last_event(finding: Finding, event: str) -> dict | None:
    for h in reversed(finding.history):
        if h.get("event") == event:
            return h
    return None


def _existing_refs(finding: Finding) -> set[str]:
    return {e.get("ref") for e in finding.evidence}


def _reopen_items(finding: Finding) -> list[QueueItem]:
    if finding.disposition not in _PROTECTED:
        return []
    refs = _existing_refs(finding)
    # One row per DISTINCT novel ref: repeated suppressions citing the same
    # novel evidence are one decision for Pete, not one row per run.
    # Historical events without a ref (pre-C1 registers) are skipped — there
    # is nothing to compare for novelty.
    novel: list[str] = []
    for h in finding.history:
        if h.get("event") != "suppressed_occurrence":
            continue
        ref = h.get("ref")
        if ref and ref not in refs and ref not in novel:
            novel.append(ref)
    return [QueueItem(
        finding.finding_id, "reopen", finding.severity, finding.title,
        f"new evidence {ref} differs from adjudicated "
        f"({finding.disposition})",
        recommendation="review reopen") for ref in novel]


def _finding_items(f: Finding, today_date: _dt.date) -> list[QueueItem]:
    items: list[QueueItem] = []
    if f.disposition == "new" and _has_event(f, "risk_accept_proposed"):
        ev = _last_event(f, "risk_accept_proposed")
        items.append(QueueItem(f.finding_id, "risk_accept", f.severity,
                               f.title, f"proposed by {ev.get('by')}",
                               recommendation="risk-accept (set review_by)"))
    if (f.disposition == "risk_accepted"
            and _dt.date.fromisoformat(f.review_by) < today_date):
        # review_by is guaranteed ISO by Finding.validate (risk_accepted
        # requires it); mirrors readiness.evaluate's past-due check.
        items.append(QueueItem(
            f.finding_id, "risk_review", f.severity, f.title,
            f"risk acceptance review_by {f.review_by} is past due",
            recommendation="reaffirm or open"))
    sev_ev = _last_event(f, "severity_review_proposed")
    if sev_ev:
        items.append(QueueItem(
            f.finding_id, "severity_review", f.severity, f.title,
            f"run proposes {sev_ev.get('proposed')} vs current "
            f"{sev_ev.get('current')}",
            recommendation=f"review severity {sev_ev.get('proposed')}"))
    items.extend(_reopen_items(f))
    if f.disposition == "new" and not _has_event(f, "verification"):
        kind = ("fuzzy_confirm" if _has_event(f, "fuzzy_match_candidate")
                else "unverified")
        detail = ("verifier never returned a result — re-run verify"
                  if kind == "unverified"
                  else "probable duplicate; verifier confirm pending")
        items.append(QueueItem(f.finding_id, kind, f.severity, f.title,
                               detail, recommendation="re-run verify"))
    return items


def build_queue(store: RegisterStore, *,
                scope_proposals: list[ScopeProposal],
                today: str) -> list[QueueItem]:
    """Project register state into a sorted list of triage items.

    Acquires the exclusive register lock to take a consistent snapshot, but
    writes nothing: no store.save, no history events. The register is
    byte-identical after this call.

    ``today`` (ISO YYYY-MM-DD) drives the past-due risk-review check;
    malformed dates are a hard error (mirrors readiness.evaluate).
    """
    try:
        today_date = _dt.date.fromisoformat(today)
    except (ValueError, TypeError) as exc:
        raise RegisterError(
            f"queue date must be ISO (YYYY-MM-DD), got {today!r}") from exc
    with store.locked():
        findings = store.load()
    items: list[QueueItem] = []
    for f in findings.values():
        items.extend(_finding_items(f, today_date))
    by_id = {f.finding_id: f for f in findings.values()}
    for proposal in scope_proposals:
        f = by_id.get(proposal.finding_id)
        items.append(QueueItem(
            proposal.finding_id, "scope",
            f.severity if f else "P3", f.title if f else "(unknown)",
            proposal.reason, recommendation=proposal.kind))
    items.sort(key=lambda i: (SEVERITY_ORDER.get(i.severity, 9), i.finding_id))
    return items


def _section_rows(group: list[QueueItem], kind: str) -> tuple[list[str], int]:
    """Table rows for one section; unverified is capped (see module doc).

    Every free-text cell — recommendation, detail, title — goes through
    ``markdown_cell``. Finding IDs and severities are controlled-format
    strings (R-NNNN / P0-P3) and need no escaping.
    """
    shown = group
    if kind == "unverified" and len(group) > _UNVERIFIED_RENDER_CAP:
        shown = sorted(group, key=lambda i: (SEVERITY_ORDER.get(i.severity, 9),
                                             i.finding_id))
        shown = shown[:_UNVERIFIED_RENDER_CAP]
    rows = [
        f"| {i.finding_id} | {i.severity} | {markdown_cell(i.recommendation)} "
        f"| {markdown_cell(i.detail)} | {markdown_cell(i.title)} |"
        for i in shown]
    return rows, len(group) - len(shown)


def render_queue(items: list[QueueItem], *, product: str) -> str:
    """Render queue items as a markdown table file.

    This is the sole choke-point for markdown injection — every free-text
    cell is escaped in ``_section_rows``; no caller should interpolate raw
    item fields into table rows.
    """
    lines = [f"# Triage queue — {product}", "",
             "<!-- generated by lazy_vibe.register — work via `triage` CLI -->",
             ""]
    if not items:
        lines += ["No items awaiting triage.", ""]
        return "\n".join(lines)
    by_kind: dict[str, list[QueueItem]] = {}
    for item in items:
        by_kind.setdefault(item.kind, []).append(item)
    for kind, heading in _SECTIONS:
        group = by_kind.get(kind)
        if not group:
            continue
        rows, overflow = _section_rows(group, kind)
        lines += [f"## {heading} ({len(group)})", ""]
        if overflow:
            lines += [f"{len(group)} unverified findings — showing the first "
                      f"{len(rows)} by severity.", ""]
        lines += ["| id | sev | recommendation | detail | title |",
                  "|---|---|---|---|---|"]
        lines += rows
        if overflow:
            lines += ["", f"…and {overflow} more — run verify-packets / "
                          f"run-triage.sh"]
        lines.append("")
    return "\n".join(lines)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_queue.py -v` then `python3 -m pytest tests/register -q` — expect **236 passed** (211 baseline + 25 queue tests; the reconcile ref pin folds into the existing suppression test). Downstream task totals below are shifted **+20** vs their printed values: T5 → 243, T6 → 247, T7/final → 248.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/queue.py tests/register/test_queue.py
git commit -m "feat(register): triage queue projection and render"
```

> Landed as `4009584` (suite 227). The quality-review fixes (C1/C2/I1/M1/M2/M3
> above) landed red-first in a follow-up commit: `fix(register): live reopen
> proposals, past-due risk reviews in queue` (suite 236, includes the
> reconcile.py change).

---

### Task 5: Interactive `triage` walk + CLI verbs (`queue.py` part 2 + `cli.py`)

The interactive `triage` walk prompts per item: `[a]ccept recommendation / [o]pen / [f]alse-positive / [r]isk-accept / [p]ark / [s]kip`. `risk-accept` additionally prompts for `review_by` and `reason`. `--accept-all` runs every recommendation non-interactively. Every decision is stamped `by="pete"` through `transition()` / `reaffirm_risk()`. Non-interactive tests feed stdin (the e2e subprocess pattern). Plus the `verify-packets`, `verify-consume`, `triage`, and `close` CLI verbs.

> **Quality-review fixes (post-implementation, red-first):** the first-landed walk forged human authority under `--accept-all`. (C1) `_recommendation_choice` fell through to `"o"` for unverified/fuzzy_confirm/reopen/risk_review/severity_review items and `_apply_decision` hardcoded `verified=True` — accept-all opened unverified findings, reopened protected states, and force-opened past-due risk acceptances unattended. Fixed: accept-all routes through `_accept_all_decision`, which may ONLY apply decisions fully specified by register state — `scope` proposals (park/unpark, reason from the proposal) and false-positive proposals whose finding's last verification verdict is UNSUPPORTED (reason cites the verifier disproof); every other kind lands untouched in a distinct `TriageOutcome.requires_human` bucket, summarized by the CLI ("N items require interactive decisions"). `_apply_decision` derives `verified` from the finding's actual last `verification` event; interactive `o` on an unverified `new` finding is rejected with "unverified — run verify-packets / run-triage.sh first" (spec §4.2). Interactive reopen of protected states stays (by="pete"), unreachable from accept-all. Production probe: on the live Meridian register accept-all now applies 0 of 397 items (all `requires_human`) where the pre-fix code would have force-opened all 397. (I2) `validate_regression_test` (transitions.py, mirrors `_require_iso_date`) requires `path::test_name` with non-empty halves; used by `_guard_fixed` AND validated up-front by the `close` verb. (I3) `QueueItem` is stamped with `source_disposition` at build; `_apply_decision` raises `QueueDrift` if the live disposition has drifted — the item lands in `TriageOutcome.drifted`, never applied. (M1) one decision per finding per walk: later items for an already-decided finding skip with "already decided this walk". (M3) the interactive `prompt` raises `EOFError` on exhausted stdin instead of substituting a sentinel `"s"` line — EOF mid-risk-accept aborts the item with nothing applied (no sentinel review dates/reasons), stops the walk, and saves only decisions completed before the EOF; KeyboardInterrupt persists nothing (module docstring documents the abort contract).

**Files:**
- Modify: `lazy_vibe/register/queue.py` (add `run_triage`)
- Modify: `lazy_vibe/register/cli.py`
- Modify: `lazy_vibe/register/transitions.py` (`validate_regression_test`, quality-review I2)
- Test: `tests/register/test_queue.py`, `tests/register/test_cli_end_to_end.py`, `tests/register/test_transitions.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_queue.py`:

```python
import io

from lazy_vibe.register.queue import run_triage


def _stdin(text):
    return io.StringIO(text)


def test_run_triage_open_decision(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    items = build_queue(store, scope_proposals=[], today="2026-06-11")
    # unverified is empty (verified); force an item via risk_accept proposal
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "open"
    assert out.decided == 1


def test_run_triage_risk_accept_prompts_review_by(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    run_triage(store, scope_proposals=[], date="2026-06-11",
               stdin=_stdin("r\n2026-12-01\ncustomer launch slipped\n"),
               accept_all=False)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "risk_accepted"
    assert f2.review_by == "2026-12-01"
    assert f2.disposition_by == "pete"


def test_run_triage_skip_leaves_finding(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    run_triage(store, scope_proposals=[], date="2026-06-11",
               stdin=_stdin("s\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "new"


def test_run_triage_accept_all_applies_recommendations(store):
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    store.save({f.finding_id: f})
    # scope proposal park -> accept-all should park
    run_triage(store, scope_proposals=[
        ScopeProposal("R-0001", "park", "left scope")],
        date="2026-06-11", stdin=_stdin(""), accept_all=True)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "parked"
    # reason comes from the proposal, not an invented placeholder
    assert "left scope" in f2.disposition_reason
```

Quality-review fix tests (C1/I3/M1/M3, red-first; `import io` and the
`run_triage` import live at the top of the file per E402):

```python
def test_accept_all_skips_unverified_new(store):  # C1a
    # accept-all must NEVER open an unverified finding: new->open requires
    # verification (spec §4.2) and accept-all cannot invent it.
    f = _new("R-0001")
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin(""), accept_all=True)
    assert store.load()["R-0001"].disposition == "new"
    assert out.requires_human == 1
    assert out.decided == 0


def test_accept_all_skips_reopen_of_false_positive(store):  # C1b
    # a reopen proposal against a protected state is Pete's call, never
    # accept-all's — reopening false_positive forges a human decision.
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2", "ref": "backend/core/other.py:9"})
    store.save({fp.finding_id: fp})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin(""), accept_all=True)
    assert store.load()["R-0001"].disposition == "false_positive"
    assert out.requires_human == 1
    assert out.decided == 0


def test_accept_all_skips_reopen_of_parked(store):  # C1c
    parked = with_history(make_finding(finding_id="R-0001",
                                       disposition="parked",
                                       disposition_by="pete"))
    parked.history.append({"ts": "t", "event": "suppressed_occurrence",
                           "run_id": "run2", "ref": "backend/core/other.py:9"})
    store.save({parked.finding_id: parked})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin(""), accept_all=True)
    assert store.load()["R-0001"].disposition == "parked"
    assert out.requires_human == 1
    assert out.decided == 0


def test_accept_all_skips_past_due_risk_review(store):  # C1d
    # a past-due risk acceptance needs Pete to reaffirm-or-open; accept-all
    # force-opening it would override his prior adjudication unattended.
    f = _risk_accepted(review_by="2026-01-01")
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin(""), accept_all=True)
    assert store.load()["R-0001"].disposition == "risk_accepted"
    assert store.load()["R-0001"].review_by == "2026-01-01"  # untouched
    assert out.requires_human == 1
    assert out.decided == 0


def test_accept_all_applies_scope_unpark(store):  # C1 positive
    parked = with_history(make_finding(finding_id="R-0001",
                                       disposition="parked",
                                       disposition_by="scope"))
    store.save({parked.finding_id: parked})
    out = run_triage(store, scope_proposals=[
        ScopeProposal("R-0001", "unpark", "rejoined launch scope")],
        date="2026-06-11", stdin=_stdin(""), accept_all=True)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "open"
    assert "rejoined launch scope" in f2.disposition_reason
    assert out.decided == 1


def test_accept_all_decision_unsupported_fp(store):  # C1 positive (unit)
    # a false-positive proposal is auto-applicable ONLY when the live
    # finding's last verification is UNSUPPORTED; the reason cites the
    # verifier's disproof rather than inventing one.
    from lazy_vibe.register.queue import _accept_all_decision
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "UNSUPPORTED", "by": "agent:verifier",
                      "evidence": ["x.py:9 route is tenant-scoped"]})
    item = QueueItem("R-0001", "fp_proposal", "P2", "t", "verifier disproof",
                     recommendation="false-positive",
                     source_disposition="new")
    decision = _accept_all_decision(item, f)
    assert decision is not None
    choice, reason = decision
    assert choice == "f"
    assert "x.py:9" in reason


def test_accept_all_decision_rejects_fp_without_unsupported(store):  # C1 neg
    from lazy_vibe.register.queue import _accept_all_decision
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier",
                      "evidence": ["x.py:9"]})
    item = QueueItem("R-0001", "fp_proposal", "P2", "t", "d",
                     recommendation="false-positive",
                     source_disposition="new")
    assert _accept_all_decision(item, f) is None


def test_interactive_open_unverified_rejected(store, capsys):  # C1 fix 2
    # even interactively, "o" on an unverified new finding is rejected with
    # an actionable message — new->open REQUIRES verification (spec §4.2).
    f = _new("R-0001")
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "new"
    assert out.decided == 0
    assert out.skipped == 1
    err = capsys.readouterr().err
    assert "unverified" in err and "verify-packets" in err


def test_interactive_reopen_of_false_positive_stays(store):  # C1 path stays
    # Pete CAN reopen a protected state interactively (by="pete" guard).
    fp = with_history(make_finding(finding_id="R-0001",
                                   disposition="false_positive",
                                   disposition_by="pete"))
    fp.history.append({"ts": "t", "event": "suppressed_occurrence",
                       "run_id": "run2", "ref": "backend/core/other.py:9"})
    store.save({fp.finding_id: fp})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "open"
    assert store.load()["R-0001"].disposition_by == "pete"
    assert out.decided == 1


def test_run_triage_skips_drifted_item(store, monkeypatch):  # I3
    # the register changed between queue build and decision application —
    # the stale item must not be applied; it lands in the drifted bucket.
    f = _new("R-0001")
    store.save({f.finding_id: f})
    stale = [QueueItem("R-0001", "risk_review", "P1", "t",
                       "review_by 2026-01-01 is past due",
                       recommendation="reaffirm or open",
                       source_disposition="risk_accepted")]
    monkeypatch.setattr("lazy_vibe.register.queue.build_queue",
                        lambda *a, **k: stale)
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert out.drifted == 1
    assert out.decided == 0
    assert store.load()["R-0001"].disposition == "new"


def test_one_decision_per_finding_per_walk(store, capsys):  # M1
    # a finding with two queue items (past-due review + severity review):
    # the first decision wins; the second item is skipped, not re-applied.
    f = _risk_accepted(review_by="2026-01-01")
    f.history.append({"ts": "t", "event": "severity_review_proposed",
                      "current": "P2", "proposed": "P0", "run_id": "run2"})
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("o\n"), accept_all=False)
    assert store.load()["R-0001"].disposition == "open"
    assert out.decided == 1
    assert out.skipped == 1
    assert "already decided this walk" in capsys.readouterr().err


def test_run_triage_eof_mid_risk_accept_aborts_item(store):  # M3
    # stdin closes after review_by but before reason: the item must abort
    # with NO transition — never persist a sentinel reason.
    f = _new("R-0001")
    f.history.append({"ts": "t", "event": "verification",
                      "verdict": "VERIFIED", "by": "agent:verifier"})
    f.history.append({"ts": "t", "event": "risk_accept_proposed",
                      "by": "policy:x", "rule": "x"})
    store.save({f.finding_id: f})
    out = run_triage(store, scope_proposals=[], date="2026-06-11",
                     stdin=_stdin("r\n2026-12-01\n"),  # EOF before reason
                     accept_all=False)
    f2 = store.load()["R-0001"]
    assert f2.disposition == "new"  # aborted, untouched
    assert f2.review_by is None
    assert out.decided == 0
    assert out.skipped == 1
```

And to `tests/register/test_transitions.py` (I2):

```python
def test_fixed_rejects_malformed_regression_test_format():
    # a closing regression test must be 'path::test_name' — free text would
    # make the fixed state unauditable and unrerunnable (quality-review I2)
    for bad in ("garbage", "tests/test_x.py", "::test_y", "tests/x.py::",
                "  ::  "):
        f = make_finding(disposition="open")
        t(f, "in_remediation", by="harness")
        with pytest.raises(TransitionError, match="path::test_name"):
            t(f, "fixed", by="harness", regression_test=bad)
        assert f.disposition == "in_remediation"  # rejected before mutation
```

Append to `tests/register/test_cli_end_to_end.py` (the `cli`, `workspace`, fixtures already exist):

```python
TRIAGE_POLICY = """\
rules:
  - id: open-verified-in-scope
    match: {verified: true, in_scope: true}
    action: open
default: queue
"""


def test_verify_and_triage_e2e(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    # generate packets
    proc = cli("verify-packets", "--register-dir", str(register_dir))
    assert proc.returncode == 0, proc.stderr
    packets = register_dir / "triage" / "packets"
    assert (packets / "R-0001.md").exists()
    # simulate verifier results
    results = register_dir / "triage" / "results"
    results.mkdir(parents=True, exist_ok=True)
    for fid in ("R-0001", "R-0002"):
        (results / f"{fid}.json").write_text(json.dumps({
            "schema_version": 1, "finding_id": fid, "verdict": "VERIFIED",
            "evidence": ["x.py:1"], "mechanism": "m",
            "duplicate_of": None, "split_paths": []}))
    proc = cli("verify-consume", "--register-dir", str(register_dir),
               "--date", "2026-06-11")
    assert proc.returncode == 0, proc.stderr
    # policy + queue via triage --accept-all with a policy that opens verified
    policy_path = register_dir / "triage-policy.yaml"
    policy_path.write_text(TRIAGE_POLICY)
    scope_path = register_dir / "launch-scope.yaml"
    scope_path.write_text(LAUNCH_SCOPE)
    proc = cli("triage", "--register-dir", str(register_dir),
               "--policy", str(policy_path), "--scope", str(scope_path),
               "--date", "2026-06-11", "--accept-all")
    assert proc.returncode == 0, proc.stderr
    from lazy_vibe.register.store import RegisterStore as RS
    findings = RS(register_dir).load()
    assert findings["R-0001"].disposition == "open"
    assert (register_dir / "triage-queue.md").exists()


def test_close_verb_open_to_fixed(workspace, tmp_path):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    from lazy_vibe.register.store import RegisterStore as RS
    from lazy_vibe.register.transitions import transition
    from lazy_vibe.register.model import Disposition
    store = RS(register_dir)
    findings = store.load()
    transition(findings["R-0001"], Disposition.OPEN, by="pete", reason="real",
               now="2026-06-10T00:00:00+00:00", verified=True)
    store.save(findings)
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001",
               "--test", "tests/test_evidence.py::test_tenant_scope",
               "--reason", "fixed in PR-9")
    assert proc.returncode == 0, proc.stderr
    f = RS(register_dir).load()["R-0001"]
    assert f.disposition == "fixed"
    assert f.regression_test == "tests/test_evidence.py::test_tenant_scope"
    assert f.disposition_by == "harness"


def test_close_requires_open_or_remediation(workspace):
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001",
               "--test", "tests/t.py::t")
    assert proc.returncode == 1  # R-0001 is `new`, not open
    assert "error:" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_close_rejects_malformed_test_format(workspace):
    # quality-review I2: --test must be 'path::test_name'; free text would
    # persist an unrerunnable regression link on the fixed state.
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    from lazy_vibe.register.store import RegisterStore as RS
    from lazy_vibe.register.transitions import transition
    from lazy_vibe.register.model import Disposition
    store = RS(register_dir)
    findings = store.load()
    transition(findings["R-0001"], Disposition.OPEN, by="pete", reason="real",
               now="2026-06-10T00:00:00+00:00", verified=True)
    store.save(findings)
    proc = cli("close", "--register-dir", str(register_dir),
               "--finding", "R-0001", "--test", "garbage")
    assert proc.returncode == 1
    assert "path::test_name" in proc.stderr
    assert "Traceback" not in proc.stderr
    f = RS(register_dir).load()["R-0001"]
    assert f.disposition == "open"  # untouched — rejected before any transition
    assert f.regression_test is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_queue.py tests/register/test_cli_end_to_end.py -v`
Expected: FAIL — `run_triage` undefined; argparse invalid choice for new verbs.

- [ ] **Step 3: Implement**

In `lazy_vibe/register/transitions.py` (quality-review I2), add next to
`_require_iso_date` and call it from `_guard_fixed`:

```python
def validate_regression_test(finding_id: str, value: str) -> None:
    """Shared guard: a closing regression test must be ``path::test_name``
    with a non-empty path and test name, so the fixed state stays rerunnable
    (mirrors ``_require_iso_date``; used by ``_guard_fixed`` and the close
    CLI verb)."""
    path, sep, name = (value or "").partition("::")
    if not (sep and path.strip() and name.strip()):
        raise TransitionError(
            f"{finding_id}: regression_test must be 'path::test_name' "
            f"(e.g. tests/test_x.py::test_y), got {value!r}")


def _guard_fixed(finding: Finding, by: str, kw: dict) -> None:
    if not kw.get("regression_test"):
        raise TransitionError(f"{finding.finding_id}: fixed requires regression_test")
    validate_regression_test(finding.finding_id, kw["regression_test"])
```

In `lazy_vibe/register/queue.py`: `QueueItem` gains
`source_disposition: str = ""` (the disposition the finding had when the
queue was built — quality-review I3); every build site (`_finding_items`,
`_reopen_items`, the scope-proposal loop in `build_queue`) stamps it from
the live finding.

Append to `lazy_vibe/register/queue.py` (add imports `import sys`, `from .model import Disposition, RegisterError`, `from .transitions import reaffirm_risk, transition` to the top):

```python
@dataclass
class TriageOutcome:
    decided: int = 0
    skipped: int = 0
    # Items --accept-all refused to decide because they need a human (C1).
    requires_human: int = 0
    # Items whose finding's disposition changed between queue build and
    # decision application — never applied, re-run triage (I3).
    drifted: int = 0


class QueueDrift(RegisterError):
    """The register changed between queue build and decision application."""


_PROMPT = ("[a]ccept rec / [o]pen / [f]alse-positive / [r]isk-accept / "
           "[p]ark / [s]kip > ")


def _recommendation_choice(item: QueueItem) -> str:
    """Map an item's recommendation to a choice for INTERACTIVE accept ('a').

    Only reachable from a human keypress; ``--accept-all`` routes through
    ``_accept_all_decision`` instead, which refuses anything underspecified.
    """
    rec = item.recommendation.lower()
    if item.kind == "scope":
        return "p" if rec == "park" else "o"  # unpark -> open
    if "risk" in rec:
        return "r"
    if "false" in rec:
        return "f"
    if "park" in rec:
        return "p"
    return "o"


def _accept_all_decision(item: QueueItem,
                         finding: Finding) -> tuple[str, str] | None:
    """The only decisions ``--accept-all`` may apply are those fully
    specified by register state, never inventing data on Pete's behalf (C1):

    - ``scope`` proposals: park/unpark with the proposal's own reason;
    - false-positive proposals whose finding's LAST verification verdict is
      UNSUPPORTED: the reason cites the verifier's disproof.

    Everything else — unverified findings, fuzzy confirms, reopens of
    protected states, past-due risk acceptances, severity reviews,
    risk-accept proposals — needs an interactive human decision: return
    ``None`` and let the caller count it in ``requires_human``.
    """
    if item.kind == "scope":
        choice = "p" if item.recommendation.lower() == "park" else "o"
        return choice, f"scope proposal accepted: {item.detail}"
    if "false" in item.recommendation.lower():
        ev = _last_event(finding, "verification")
        if ev and ev.get("verdict") == "UNSUPPORTED":
            disproof = "; ".join(ev.get("evidence", []))[:200]
            return "f", f"verifier UNSUPPORTED: {disproof}"
    return None


def _apply_decision(findings, item: QueueItem, choice: str, *, date: str,
                    prompt_fn, reason: str | None = None) -> bool:
    """Apply a single decision stamped pete. Returns True if it changed state.

    Raises ``QueueDrift`` if the live finding no longer has the disposition
    the queue item was built from (I3) — the decision context is stale.
    Raises ``EOFError`` out of ``prompt_fn`` if stdin closes mid-decision —
    the item is aborted with nothing applied (M3).
    ``verified`` is derived from the finding's actual last verification
    event, never assumed (spec §4.2: new->open requires verification).
    """
    now = f"{date}T00:00:00+00:00"
    finding = findings[item.finding_id]
    if finding.disposition != item.source_disposition:
        raise QueueDrift(
            f"{item.finding_id}: register changed since the queue was built "
            f"({item.source_disposition!r} -> {finding.disposition!r}) — "
            f"re-run triage")
    if choice == "a":
        choice = _recommendation_choice(item)
    if choice == "o":
        ev = _last_event(finding, "verification")
        verified = bool(ev and ev.get("verdict") == "VERIFIED")
        if finding.disposition == "new" and not verified:
            raise RegisterError(
                f"{finding.finding_id}: unverified — run verify-packets / "
                f"run-triage.sh first")
        transition(finding, Disposition.OPEN, by="pete",
                   reason=reason or "triaged open", now=now, verified=verified)
    elif choice == "f":
        transition(finding, Disposition.FALSE_POSITIVE, by="pete",
                   reason=reason or "triaged false_positive", now=now)
    elif choice == "p":
        transition(finding, Disposition.PARKED, by="pete",
                   reason=reason or "triaged parked", now=now)
    elif choice == "r":
        review_by = prompt_fn("review_by (YYYY-MM-DD): ").strip()
        reason = prompt_fn("reason: ").strip() or "risk accepted via triage"
        if finding.disposition == "risk_accepted":
            reaffirm_risk(finding, review_by=review_by, by="pete", now=now,
                          reason=reason)
        else:
            transition(finding, Disposition.RISK_ACCEPTED, by="pete",
                       reason=reason, now=now, review_by=review_by)
    else:
        return False
    return True


def _choose(item: QueueItem, finding: Finding, *, accept_all: bool,
            prompt) -> tuple[str, str | None] | None:
    """Pick the (choice, reason) for one item.

    ``None`` means accept-all refused it (requires a human). Raises
    ``EOFError`` if stdin is exhausted at the choice prompt.
    """
    if accept_all:
        return _accept_all_decision(item, finding)
    print(f"{item.finding_id} {item.severity} [{item.kind}] "
          f"{item.title}\n  rec: {item.recommendation} — {item.detail}")
    return (prompt(_PROMPT).strip().lower()[:1] or "s"), None


def _decide_one(findings, item: QueueItem, *, accept_all: bool, prompt,
                date: str, outcome: TriageOutcome) -> bool | None:
    """Decide and apply one item, mapping failures onto outcome buckets.

    Returns True if the finding changed (caller counts ``decided``), False
    if it was refused/skipped (already counted here), or None if the walk
    must stop because stdin is exhausted (caller counts the remainder).
    """
    try:
        decision = _choose(item, findings[item.finding_id],
                           accept_all=accept_all, prompt=prompt)
        if decision is None:
            outcome.requires_human += 1
            return False
        choice, reason = decision
        if _apply_decision(findings, item, choice, date=date,
                           prompt_fn=lambda t: prompt(t).strip(),
                           reason=reason):
            return True
        outcome.skipped += 1
        return False
    except QueueDrift as exc:
        print(f"  drifted: {exc}", file=sys.stderr)
        outcome.drifted += 1
        return False
    except EOFError:
        print(f"  stdin closed — stopping the walk; nothing applied for "
              f"{item.finding_id}", file=sys.stderr)
        return None
    except RegisterError as exc:
        print(f"  skipped {item.finding_id}: {exc}", file=sys.stderr)
        outcome.skipped += 1
        return False


def run_triage(store: RegisterStore, *, scope_proposals: list[ScopeProposal],
               date: str, stdin=None, accept_all: bool = False) -> TriageOutcome:
    """Walk the queue and write pete-stamped dispositions.

    ``accept_all=True`` is non-interactive and applies ONLY decisions fully
    specified by register state (``_accept_all_decision``); everything else
    lands in ``requires_human`` untouched. One decision per finding per walk
    (M1). EOF aborts the in-flight item with nothing applied (M3), stops the
    walk, and saves only the decisions completed before it; a
    KeyboardInterrupt persists nothing. Full abort contract: module
    docstring.
    """
    stdin = stdin or sys.stdin
    outcome = TriageOutcome()
    items = build_queue(store, scope_proposals=scope_proposals, today=date)

    def prompt(text: str) -> str:
        print(text, end="", flush=True)
        line = stdin.readline()
        if not line:
            raise EOFError
        return line

    decided_ids: set[str] = set()
    with store.locked():
        findings = store.load()
        for index, item in enumerate(items):
            if item.finding_id not in findings:
                continue
            if item.finding_id in decided_ids:
                print(f"  {item.finding_id}: already decided this walk — "
                      f"skipping [{item.kind}] item", file=sys.stderr)
                outcome.skipped += 1
                continue
            changed = _decide_one(findings, item, accept_all=accept_all,
                                  prompt=prompt, date=date, outcome=outcome)
            if changed is None:  # stdin exhausted: count the rest, stop
                outcome.skipped += len(items) - index
                break
            if changed:
                outcome.decided += 1
                decided_ids.add(item.finding_id)
        store.save(findings)
    return outcome
```

> **Note:** the `prompt` closure prints its prompt text, reads one line per
> call, and raises `EOFError` on exhausted stdin; `_apply_decision`'s
> risk-accept branch consumes the next two lines (review_by, reason) — so the
> stdin fixtures feed `r\n<date>\n<reason>\n`. `accept_all` never reads stdin.
> The module docstring documents the abort contract: a single `store.save`
> at the end of the walk; EOF saves only completed decisions, never a
> half-applied item; KeyboardInterrupt persists nothing.

In `lazy_vibe/register/cli.py` add imports:

```python
from .policy import apply_policy, load_policy
from .queue import build_queue, render_queue, run_triage
from .verify import consume_results, generate_packets
```

Add handlers:

```python
def _cmd_verify_packets(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    written = generate_packets(store)
    print(f"wrote {len(written)} verification packets to "
          f"{store.register_dir / 'triage' / 'packets'}")
    return 0


def _cmd_verify_consume(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    # NOTE(T5): VerifyOutcome buckets are per-run deltas, not register totals.
    # A re-run after full consumption legitimately returns all-empty buckets.
    # Present them as "this run found/changed X", never as register census.
    outcome = consume_results(store, date=args.date or _today())
    print(f"this run: {len(outcome.verified)} verified, "
          f"{len(outcome.false_positive)} false_positive, "
          f"{len(outcome.split)} split, "
          f"{len(outcome.unverified)} unverified (no result yet)")
    return 0


def _cmd_triage(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    date = args.date or _today()
    if args.policy:
        policy = load_policy(Path(args.policy))
        outcome = apply_policy(store, policy, date=date)
        print(f"policy: {len(outcome.opened)} opened, "
              f"{len(outcome.parked)} parked, "
              f"{len(outcome.false_positive)} false_positive, "
              f"{len(outcome.proposed_risk_accept)} risk-accept proposed, "
              f"{len(outcome.queued)} queued")
    scope_proposals = []
    if args.scope and args.recompute_scope:
        scope_proposals = recompute(store, load_scope(Path(args.scope)),
                                    date=date)
    items = build_queue(store, scope_proposals=scope_proposals, today=date)
    product = (load_scope(Path(args.scope)).product if args.scope
               else "product")
    queue_path = store.register_dir / "triage-queue.md"
    queue_path.write_text(render_queue(items, product=product))
    if args.render_only:
        print(f"{len(items)} queue items — {queue_path}")
        return 0
    result = run_triage(store, scope_proposals=scope_proposals, date=date,
                        accept_all=args.accept_all)
    # regenerate queue after decisions
    remaining = build_queue(store, scope_proposals=[], today=date)
    queue_path.write_text(render_queue(remaining, product=product))
    summary = f"triaged {result.decided}, {result.skipped} skipped"
    if result.requires_human:
        summary += (f", {result.requires_human} items require interactive "
                    f"decisions (re-run without --accept-all)")
    if result.drifted:
        summary += f", {result.drifted} drifted (register changed — re-run)"
    print(f"{summary} — {len(remaining)} remain in {queue_path}")
    return 0


def _cmd_close(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    now = f"{args.date or _today()}T00:00:00+00:00"
    # Fail fast on a malformed --test BEFORE any transition: _guard_fixed
    # re-checks at the fixed edge, but validating up front keeps the
    # open->in_remediation step from ever running with a doomed close.
    validate_regression_test(args.finding, args.test)
    with store.locked():
        findings = store.load()
        if args.finding not in findings:
            raise RegisterError(f"unknown finding {args.finding}")
        finding = findings[args.finding]
        reason = args.reason or f"closed by harness with {args.test}"
        if finding.disposition == "open":
            transition(finding, Disposition.IN_REMEDIATION, by="harness",
                       reason=reason, now=now)
        if finding.disposition != "in_remediation":
            raise RegisterError(
                f"{args.finding}: close requires open/in_remediation, is "
                f"{finding.disposition}")
        transition(finding, Disposition.FIXED, by="harness", reason=reason,
                   now=now, regression_test=args.test)
        store.save(findings)
    print(f"{args.finding} -> fixed (test {args.test})")
    return 0
```

Add `from .model import Disposition` and `from .transitions import
transition, validate_regression_test` to `cli.py`'s imports (top of file).
Add the subparsers in `build_parser`:

```python
    p = sub.add_parser("verify-packets",
                       help="write verification packets for new findings")
    p.add_argument("--register-dir", required=True)
    p.set_defaults(func=_cmd_verify_packets)

    p = sub.add_parser("verify-consume",
                       help="consume verifier result JSON into the register")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_verify_consume)

    p = sub.add_parser("triage",
                       help="apply policy, render the queue, walk it as Pete")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--policy", default=None)
    p.add_argument("--scope", default=None)
    p.add_argument("--date", default=None)
    p.add_argument("--accept-all", action="store_true")
    p.add_argument("--render-only", action="store_true",
                   help="apply policy + render queue, no interactive walk")
    p.add_argument("--recompute-scope", action="store_true",
                   help="run scope.recompute and include proposals")
    p.set_defaults(func=_cmd_triage)

    p = sub.add_parser("close",
                       help="harness: open/in_remediation -> fixed with test")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--finding", required=True)
    p.add_argument("--test", required=True)
    p.add_argument("--reason", default=None)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_close)
```

(`recompute`, `load_scope` are already imported in `cli.py` from Plan 2a.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_queue.py tests/register/test_cli_end_to_end.py -v` then `python3 -m pytest tests/register -q` — expect **223 passed** (printed value; actual on-branch totals after the T2–T4 quality rounds: T5 first landed **243**, and the T5 quality-fix round (C1/I2/I3/M1/M3 above, +14 tests incl. `test_transitions.py`) brings the suite to **257**; downstream totals shift accordingly: T6 → 261, T7/final → 262).

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/queue.py lazy_vibe/register/cli.py \
        tests/register/test_queue.py tests/register/test_cli_end_to_end.py
git commit -m "feat(register): interactive triage walk + verify/triage/close CLI verbs"
```

> Landed as `789b365` (suite 243). The quality-review fixes (C1/I2/I3/M1/M3
> above) landed red-first in a follow-up commit: `fix(register): accept-all
> honors human authority, regression-test format, drift guards` (suite 257,
> includes `transitions.py` + `test_transitions.py`).

---

### Task 6: Scope carry-forward — journeys + claims_doc (`scope.py`)

`scope.py` currently hard-rejects any surface key beyond `slug`/`paths`/`routes`
(`scope.py:68-72`). Accept `journeys` (matched like routes — route-like
substrings against the path+title haystack) and `claims_doc` (top-level,
informational only — recorded on `Scope`, not used for matching).

**Files:**
- Modify: `lazy_vibe/register/scope.py`
- Test: extend `tests/register/test_scope.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_scope.py`:

```python
def test_surface_accepts_journeys(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(
        "product: meridian\ndefault_in_scope: false\n"
        "claims_doc: docs/functional/launch-claims.md\n"
        "surfaces:\n  - slug: ev\n    paths: []\n    routes: []\n"
        "    journeys: ['connector-to-evidence']\n")
    scope = load_scope(p)
    assert scope.claims_doc == "docs/functional/launch-claims.md"
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "docs/ux/flows.md", "symbol": "-"},
        title="connector-to-evidence journey has no browser proof")
    assert matches(f, scope) is True


def test_journeys_must_be_list(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(
        "product: meridian\ndefault_in_scope: false\n"
        "surfaces:\n  - slug: ev\n    journeys: oops\n")
    with pytest.raises(RegisterError, match="journeys"):
        load_scope(p)


def test_claims_doc_defaults_none(scope):
    assert scope.claims_doc is None


def test_unknown_surface_key_still_rejected(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(
        "product: meridian\ndefault_in_scope: false\n"
        "surfaces:\n  - slug: ev\n    gremlins: ['x']\n")
    with pytest.raises(RegisterError, match="gremlins"):
        load_scope(p)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/register/test_scope.py -v`
Expected: FAIL — `journeys` rejected, `Scope` has no `claims_doc`.

- [ ] **Step 3: Implement**

In `lazy_vibe/register/scope.py`:

Add `journeys` to `Surface` and `claims_doc` to `Scope`:

```python
@dataclass(frozen=True)
class Surface:
    slug: str
    paths: tuple[str, ...]
    routes: tuple[str, ...]
    journeys: tuple[str, ...] = ()


@dataclass(frozen=True)
class Scope:
    product: str
    default_in_scope: bool
    surfaces: tuple[Surface, ...]
    severity_bar: dict[str, str]
    gates: tuple[Gate, ...]
    claims_doc: str | None = None
```

In `load_scope`, replace the surface-key validation block (currently rejecting
everything but slug/paths/routes) with one that allows `journeys`:

```python
        unknown = set(raw) - {"slug", "paths", "routes", "journeys"}
        if unknown:
            raise RegisterError(
                f"{path}: surface {raw['slug']!r}: unsupported keys "
                f"{sorted(unknown)}")
        paths = raw.get("paths") or []
        routes = raw.get("routes") or []
        journeys = raw.get("journeys") or []
        if not all(isinstance(x, list) for x in (paths, routes, journeys)):
            raise RegisterError(
                f"{path}: surface {raw['slug']!r}: 'paths', 'routes' and "
                f"'journeys' must be lists")
        surfaces.append(Surface(slug=raw["slug"],
                                paths=tuple(str(p) for p in paths),
                                routes=tuple(str(r) for r in routes),
                                journeys=tuple(str(j) for j in journeys)))
```

In the final `return Scope(...)`, add `claims_doc=data.get("claims_doc")`
(after validating it is a string-or-absent):

```python
    claims_doc = data.get("claims_doc")
    if claims_doc is not None and not isinstance(claims_doc, str):
        raise RegisterError(f"{path}: 'claims_doc' must be a string path")
    return Scope(product=product,
                 default_in_scope=default_in_scope,
                 surfaces=tuple(surfaces),
                 severity_bar=dict(bar),
                 gates=tuple(gates),
                 claims_doc=claims_doc)
```

In `matches`, fold journeys into the route-like check (journeys match the
path+title haystack exactly like routes):

```python
    for surface in scope.surfaces:
        if any(path.startswith(prefix) for prefix in surface.paths):
            return True
        route_like = surface.routes + surface.journeys
        if any(token and token in haystack for token in route_like):
            return True
    return scope.default_in_scope
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/register/test_scope.py -v` then `python3 -m pytest tests/register -q` — expect **227 passed**.

- [ ] **Step 5: Commit**

```bash
git add lazy_vibe/register/scope.py tests/register/test_scope.py
git commit -m "feat(register): scope surfaces accept journeys + claims_doc"
```

---

### Task 7: Harness wrapper + exports + README (`run-triage.sh`, `__init__.py`, `README.md`)

`run-triage.sh` is thin harness glue (< 150 lines): for each packet without a
result, invoke the agent CLI with the packet on stdin and the output-contract
already baked into the packet, then `verify-consume`. Models the
`run-audit.sh` prompt-on-stdin idiom. Full `run-remediation.sh` rewiring is
Plan 3.

**Files:**
- Create: `run-triage.sh`
- Modify: `lazy_vibe/register/__init__.py` (exports)
- Modify: `README.md`
- Test: extend `tests/register/test_cli_end_to_end.py` (wrapper smoke test with a stub agent)

- [ ] **Step 1: Write the failing tests**

Append to `tests/register/test_cli_end_to_end.py`:

```python
import os
import stat


def test_run_triage_sh_dispatches_stub_agent(workspace, tmp_path):
    """run-triage.sh: stub TRIAGE_AGENT writes a VERIFIED result per packet,
    then verify-consume folds it in."""
    _, register_dir, run1, _ = workspace
    cli("backfill", "--register-dir", str(register_dir),
        "--ledger", str(run1 / "00-blocker-ledger.tsv"),
        "--run-id", "run1", "--date", "2026-06-10")
    cli("verify-packets", "--register-dir", str(register_dir))
    # stub agent: reads packet on stdin, extracts the result path + finding id,
    # writes a minimal VERIFIED result there.
    stub = tmp_path / "stub-agent.sh"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        "packet=$(cat)\n"
        "fid=$(printf '%s' \"$packet\" | grep -oE 'R-[0-9]{4}' | head -1)\n"
        "out=$(printf '%s' \"$packet\" | grep -oE '/[^ ]*results/[^ ]*.json' "
        "| head -1)\n"
        "printf '{\"schema_version\":1,\"finding_id\":\"%s\",\"verdict\":"
        "\"VERIFIED\",\"evidence\":[\"x.py:1\"],\"mechanism\":\"m\","
        "\"duplicate_of\":null,\"split_paths\":[]}' \"$fid\" > \"$out\"\n")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ, TRIAGE_AGENT=str(stub), MAX_PARALLEL="1")
    proc = subprocess.run(
        ["bash", str(REPO_ROOT / "run-triage.sh"),
         "--register-dir", str(register_dir)],
        cwd=REPO_ROOT, capture_output=True, text=True, env=env)
    assert proc.returncode == 0, proc.stderr
    findings = RegisterStore(register_dir).load()
    assert all("verification" in [h.get("event") for h in f.history]
               for f in findings.values())
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest tests/register/test_cli_end_to_end.py::test_run_triage_sh_dispatches_stub_agent -v`
Expected: FAIL — `run-triage.sh` does not exist.

- [ ] **Step 3: Implement**

Create `run-triage.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# run-triage.sh — harness glue for the register triage verification stage.
#
# For each verification packet that has no result yet, invoke the agent CLI
# with the packet on stdin (the packet states the JSON output contract and the
# exact result path to write), then fold all results into the register via
# `verify-consume`. This is the verification half of the triage pipeline
# (spec §6 stage 1, §11); policy + queue are driven by `triage`. Full
# run-remediation.sh rewiring is Plan 3.
#
# Env:
#   TRIAGE_AGENT   agent command (default: claude). Receives the packet on
#                  stdin. For claude: `claude -p --dangerously-skip-permissions`.
#                  For codex: `codex exec --full-auto --skip-git-repo-check -`.
#   MAX_PARALLEL   max concurrent agent invocations (default: 3).
#   TRIAGE_DATE    ISO date stamped on verification events (default: today).
set -euo pipefail

REGISTER_DIR=""
TRIAGE_AGENT="${TRIAGE_AGENT:-claude}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
TRIAGE_DATE="${TRIAGE_DATE:-$(date +%F)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: run-triage.sh --register-dir DIR" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --register-dir) REGISTER_DIR="$2"; shift 2 ;;
    --agent) TRIAGE_AGENT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[[ -n "$REGISTER_DIR" ]] || usage

PACKETS_DIR="$REGISTER_DIR/triage/packets"
RESULTS_DIR="$REGISTER_DIR/triage/results"

# 1. (Re)generate packets for current `new` findings.
python3 -m lazy_vibe.register verify-packets --register-dir "$REGISTER_DIR"
mkdir -p "$RESULTS_DIR"

# 2. For each packet without a result, dispatch the agent (bounded parallel).
run_one() {
  local packet="$1" fid result
  fid="$(basename "$packet" .md)"
  result="$RESULTS_DIR/$fid.json"
  [[ -f "$result" ]] && return 0
  # A consumed result (results/consumed/, moved there by verify-consume) means
  # this finding was already verified on a previous run and is awaiting
  # policy/Pete — do not re-dispatch the agent for it. Findings the queue
  # flags "re-run verify" have no consumed result and still dispatch.
  [[ -f "$RESULTS_DIR/consumed/$fid.json" ]] && return 0
  if [[ "$TRIAGE_AGENT" == claude* ]]; then
    # shellcheck disable=SC2086
    $TRIAGE_AGENT -p --dangerously-skip-permissions < "$packet" \
      > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid (see /tmp/triage-$fid.log)" >&2
  elif [[ "$TRIAGE_AGENT" == codex* ]]; then
    # shellcheck disable=SC2086
    $TRIAGE_AGENT exec --full-auto --skip-git-repo-check -C "$REPO_ROOT" - \
      < "$packet" > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid" >&2
  else
    # stub / custom agent: receives packet on stdin, writes the result file.
    # shellcheck disable=SC2086
    $TRIAGE_AGENT < "$packet" > "/tmp/triage-$fid.log" 2>&1 || \
      echo "warning: agent failed for $fid" >&2
  fi
}
export -f run_one
export RESULTS_DIR TRIAGE_AGENT REPO_ROOT

if compgen -G "$PACKETS_DIR/*.md" > /dev/null; then
  printf '%s\n' "$PACKETS_DIR"/*.md \
    | xargs -P "$MAX_PARALLEL" -I {} bash -c 'run_one "$@"' _ {}
fi

# 3. Fold every present result into the register (schema-validated).
python3 -m lazy_vibe.register verify-consume \
  --register-dir "$REGISTER_DIR" --date "$TRIAGE_DATE"

echo "triage verification complete — review queue with: " \
     "python3 -m lazy_vibe.register triage --register-dir $REGISTER_DIR " \
     "--policy $REGISTER_DIR/triage-policy.yaml --render-only"
```

In `lazy_vibe/register/__init__.py`, add the new public symbols and update
`__all__` (keep sorted). Add:

```python
from .policy import Policy, PolicyOutcome, Rule, apply_policy, load_policy
from .queue import (QueueDrift, QueueItem, TriageOutcome, build_queue,
                    render_queue, run_triage)
from .verify import (RESULT_SCHEMA_VERSION, VerifyOutcome, consume_results,
                     consumed_result_path, generate_packets,
                     last_verification, packet_path, result_path)
```

and add to `__all__`: `"Policy", "PolicyOutcome", "QueueDrift", "QueueItem",
"RESULT_SCHEMA_VERSION", "Rule", "TriageOutcome", "VerifyOutcome",
"apply_policy", "build_queue", "consume_results", "consumed_result_path",
"generate_packets", "last_verification", "load_policy", "packet_path",
"render_queue", "result_path", "run_triage"` (re-sort the full list).
(`validate_regression_test` stays a `transitions` import for the close verb;
export it alongside `transition`/`reaffirm_risk` if those are already in
`__all__`, matching however Plan 1 exported them.)

In `README.md`, after the Plan 2a paragraph (line ~799), append:

```markdown
Plan 2b adds the triage pipeline: `verify-packets` (write per-finding
verification packets for `new` findings), `verify-consume` (fold
schema-validated verifier results back — VERIFIED stays `new` for
policy/Pete, UNSUPPORTED proposes `false_positive`, confirmed duplicates
absorb into the original, `split` queues a manual item), `triage` (apply
`triage-policy.yaml`, render `triage-queue.md`, and walk it interactively as
Pete — `--accept-all` for batch, `--render-only` to just regenerate the
queue), and `close` (harness: `open`/`in_remediation` -> `fixed` with a
linked regression test). `run-triage.sh` dispatches a verifier agent
(`TRIAGE_AGENT`, default `claude`; `MAX_PARALLEL`, default 3) over the packets
and consumes the results. Policy auto-dispositions are stamped
`policy:<rule-id>`; every Pete decision is stamped `pete`.
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -m pytest tests/register -q` — expect **228 passed** (227 + 1
scorecard corpus test skipped on machines without
`/home/pete/cadres/meridian/docs/scorecards`). Then
`ruff check lazy_vibe/register/` — must be clean. Then `bash -n run-triage.sh`
to syntax-check the wrapper.

- [ ] **Step 5: Commit**

```bash
chmod +x run-triage.sh
git add run-triage.sh lazy_vibe/register/__init__.py README.md \
        tests/register/test_cli_end_to_end.py
git commit -m "feat(register): run-triage.sh dispatch wrapper + exports + docs"
```

---

### Task 8: Production dry-run on Meridian (token-bounded)

No new lazy-vibe code. Run the pipeline against the real Meridian register for
a bounded sample (5 P0 + 10 P1, not all 397 — token budget) and report
honestly. Treat anomalies as findings to report, never silently patch.

- [ ] **Step 1: Add a starter triage-policy.yaml in Meridian**

Create `/home/pete/cadres/meridian/docs/audit/register/triage-policy.yaml`:

```yaml
# Meridian starter triage policy (spec §6). Conservative: auto-open only
# verified, in-scope P0/P1; everything else queues for Pete. Widen as the
# verifier corpus and launch claims firm up.
rules:
  - id: auto-open-verified-p0
    match: {severity: P0, in_scope: true, verified: true}
    action: open
  - id: auto-open-verified-p1
    match: {severity: P1, in_scope: true, verified: true}
    action: open
  - id: unsupported-fp
    match: {verified: false}
    action: queue
default: queue
```

(`unsupported-fp` deliberately `queue`s rather than `false_positive` — auto
false-positive needs an UNSUPPORTED verdict per the engine guard, and most
unverified findings here simply have no result yet; sending them to the queue
is the honest disposition.)

- [ ] **Step 2: Generate packets for the bounded sample**

The full register has 397 `new` findings. Generating packets for all is fine
(deterministic, cheap), but only run AGENTS over 15. Generate all packets,
then run the agent over just the 5 P0 + 10 sampled P1 packets:

```bash
cd /home/pete/cadres/shared/lazy-vibe
REG=/home/pete/cadres/meridian/docs/audit/register
python3 -m lazy_vibe.register verify-packets --register-dir "$REG"

# select the 15 packets: 5 P0 + first 10 P1 by id
python3 - <<'EOF'
import json, pathlib, shutil
reg = pathlib.Path("/home/pete/cadres/meridian/docs/audit/register")
findings = [json.loads(l) for l in (reg / "register.jsonl").read_text().splitlines()]
p0 = sorted(f["finding_id"] for f in findings
            if f["severity"] == "P0" and f["disposition"] == "new")
p1 = sorted(f["finding_id"] for f in findings
            if f["severity"] == "P1" and f["disposition"] == "new")[:10]
sample = p0 + p1
hold = reg / "triage" / "packets_held"
hold.mkdir(exist_ok=True)
for pkt in (reg / "triage" / "packets").glob("R-*.md"):
    if pkt.stem not in sample:
        shutil.move(str(pkt), hold / pkt.name)
print("dispatching agents for:", sample)
EOF
```

(Moving the other packets aside bounds the agent fan-out; restore them after
if a full run is desired. This is a token-budget measure, documented as such.)

- [ ] **Step 3: Run run-triage.sh with the real agent over the 15**

```bash
TRIAGE_AGENT=claude MAX_PARALLEL=3 \
  bash run-triage.sh --register-dir "$REG"
```

Report verbatim: how many of the 15 returned VERIFIED vs UNSUPPORTED vs split,
any agent failures (those stay `new`, surface as unverified in the queue), and
any schema-validation rejections (those are loud `RegisterError`s — if one
fires, capture the exact message; do NOT loosen the schema to make it pass).

- [ ] **Step 4: Restore held packets, apply policy, render the queue**

```bash
mv "$REG"/triage/packets_held/*.md "$REG"/triage/packets/ 2>/dev/null || true
rmdir "$REG"/triage/packets_held 2>/dev/null || true
python3 -m lazy_vibe.register triage \
  --register-dir "$REG" \
  --policy "$REG/triage-policy.yaml" \
  --scope "$REG/launch-scope.yaml" \
  --render-only
```

Expected: the policy opens any of the sampled P0/P1 that came back VERIFIED and
are in scope; the rest queue. `triage-queue.md` lists the unverified majority
(382 findings with no agent run) under "Unverified findings" — that is the
honest state, not a failure. Capture the queue section counts.

- [ ] **Step 5: Readiness re-check**

```bash
python3 -m lazy_vibe.register readiness \
  --register-dir "$REG" \
  --scope "$REG/launch-scope.yaml" || true
```

Expected: `NOT READY` — the in-scope open P0/P1 plus the large unverified-`new`
P2 set block the bar. Capture the blocking count. This is the current honest
verdict.

- [ ] **Step 6: Commit register changes in Meridian**

```bash
cd /home/pete/cadres/meridian
git add docs/audit/register/
git commit -m "chore(register): triage dry-run — verify 5 P0 + 10 P1, starter policy

Generated verification packets, ran the verifier over the P0 + sampled P1
set, consumed results, added a conservative starter triage-policy.yaml, and
rendered the triage queue. Remaining findings stay new/unverified pending a
full verifier pass."
```

- [ ] **Step 7: Report** — verification outcomes (VERIFIED/UNSUPPORTED/split
  counts, agent failures, schema rejections verbatim), policy auto-opens,
  queue section counts, readiness verdict + blocking count, and any anomaly
  treated as a finding rather than silently worked around.

---

## Self-Review (completed at plan-writing time)

- **Spec coverage:**
  - §6 stage 1 (verification packets, evidence-or-disproof, strict JSON schema,
    consume + history event, reject malformed loudly) → Tasks 1–2.
  - §6 fuzzy-duplicate confirmation (`duplicate_of`, confirmed dup proposes
    false_positive referencing original, original absorbs evidence) → Task 2.
  - §6 stage 2 (`triage-policy.yaml` ordered first-match-wins, all match keys,
    all actions, `false_positive` only on UNSUPPORTED, `policy:<rule-id>`
    stamp, default required, hard-error load) → Task 3.
  - §6 stage 3 (queue sections, interactive `triage` walk with
    a/o/f/r/p/s + review_by/reason prompts, `--accept-all`, pete-stamped) →
    Tasks 4–5.
  - §11 `close` verb (open→in_remediation→fixed, by=harness, test required) →
    Task 5; `verify-packets`/`verify-consume`/`triage` CLI verbs → Task 5;
    `run-triage.sh` harness glue modeled on run-audit.sh → Task 7.
  - §12 collision split (verifier `split` verdict queues manual item) → Tasks
    1–2,4; reopen proposals (suppressed_occurrence with materially-different
    evidence ref) → Task 4; verifier-failure-stays-`new` surfaces as
    unverified → Tasks 2,4.
  - §4.2 authorities (verifier never transitions protected; policy proposals
    never auto-transition risk_accept; reaffirm) → Tasks 2,3,5.
  - Carry-forwards: scope journeys (route-like) + claims_doc (informational) →
    Task 6.
- **Deferred to Plan 3 (explicit):** full `run-remediation.sh` rewiring to
  build its queue from `open`/`regressed` and call `close` on pass (spec §11) —
  Task 7 wrapper is verification-only glue; automatic collision auto-split
  (Task 2 only queues a `split` item); differential audit mode + post-feature-
  build hook (spec §8); prompt calibration + skill retirement (spec §9, §10).
- **Placeholder scan:** every code step carries complete code. The one
  intentional correction is `test_verified_match_requires_verified_event` in
  Task 3, where the first form is shown with the reasoning inline and the
  corrected `pytest.raises` form immediately follows — implementers use the
  corrected form. Task 8 is operational with exact commands and explicit
  stop-and-report rules (never loosen the schema, never edit historical data).
- **Type consistency across tasks:**
  - `VerifyOutcome` (Task 2) fields `verified/false_positive/split/unverified/
    skipped` consumed by Task 5 `_cmd_verify_consume` and Task 4/5 queue.
  - `last_verification(finding) -> dict | None` (Task 2) consumed by
    `policy._verified` (Task 3) and `queue` (Task 4).
  - `PolicyOutcome` (Task 3) fields consumed by Task 5 `_cmd_triage`.
  - `QueueItem` (Task 4: `finding_id/kind/severity/title/detail/
    recommendation/extra`) consumed by `render_queue` and `run_triage` (Task 5).
  - `run_triage(store, *, scope_proposals, date, stdin, accept_all) ->
    TriageOutcome` (Task 5) matches `_cmd_triage` and the stdin-feeding tests.
  - `ScopeProposal` (Plan 2a) consumed by `build_queue` and `run_triage`.
  - `Scope.claims_doc` / `Surface.journeys` (Task 6) are additive defaulted
    fields — Plan 2a constructors and tests still pass (frozen dataclass,
    defaults trail non-defaulted fields).
  - `transition` / `reaffirm_risk` signatures (`by`, `reason`, `now`, kw
    `verified`/`review_by`/`regression_test`) used exactly as in Plan 1.
- **Arithmetic (baseline 159, verified by counting distinct `def test_`
  functions per task at plan-writing time):** T1 +9 = 168; T2 +11 = 179, then
  +10 quality-review hardening tests = 189 (verifier-input attack paths and
  consumption idempotency) and +3 candidate-binding tests = 192 (re-review —
  see the hardening notes in Task 2); T3
  +14 = 206 (`test_verified_match_requires_verified_event` is one function —
  the corrected `pytest.raises` form replaces the placeholder form, not an
  added test); T4 +10 = 216; T5 +7 = 223 (4 `run_triage` walk tests + 3 cli
  e2e: `verify_and_triage`, `close_verb`, `close_requires`); T6 +4 = 227; T7
  +1 = 228 (the `run-triage.sh` wrapper smoke test; README and `__all__`
  export changes add no tests — the export is import-checked by the existing
  suite). **Final: 228 passed**, or 227 passed + 1 skipped on machines without
  `/home/pete/cadres/meridian/docs/scorecards` (the inherited scorecard corpus
  test). Task 8 adds no pytest tests. Implementers MUST re-derive the count
  after each task from the actual `-q` summary rather than trusting this
  estimate.
