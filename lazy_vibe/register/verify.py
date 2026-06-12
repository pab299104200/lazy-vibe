"""Verification-packet generation and result consumption (spec §6 stage 1, §12).

Each `new` finding gets a deterministic markdown packet asking a verifier
agent the single triage question — *is it real?* — under an evidence-or-
disproof contract with a strict JSON output schema. Consumption
(schema_validate / consume_results) lives below; it appends a `verification`
history event and proposes false_positive on UNSUPPORTED, never transitioning
a protected state. Fuzzy-duplicate confirmation and collision split are
folded in: a confirmed duplicate proposes false_positive referencing the
original; a `split` verdict queues a manual item (auto-split is Plan 3).

Result-file lifecycle: a verifier writes `triage/results/R-NNNN.json`.
`consume_results` schema-validates the file, applies the verdict, saves the
register, and only then moves the file to `triage/results/consumed/
R-NNNN.json` (os.replace) — re-runs find no pending results, making
consumption idempotent. A result that fails validation stays in place to be
fixed and re-consumed; any validation or authority error aborts the whole
batch before save, so nothing is persisted and nothing is archived.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from .model import Disposition as _D
from .model import RegisterError
from .store import RegisterStore
from .transitions import transition

RESULT_SCHEMA_VERSION = 1

_TRIAGE_SUBDIR = "triage"
_VALID_VERDICTS = {"VERIFIED", "UNSUPPORTED", "split"}
# Dispositions a confirmed duplicate may absorb evidence into. Adjudicated
# (false_positive/risk_accepted), parked, and fixed entries are off-limits:
# a verifier-controlled duplicate_of must never modify a protected entry or
# pre-seed refs that would suppress future reopen proposals.
_ABSORB_TARGETS = {"new", "open", "in_remediation", "regressed"}


def _fence_safe(text: str) -> str:
    """Neutralize triple-backtick fences so finding text cannot break the
    packet's own fenced context block."""
    return text.replace("```", "` ` `")


def packet_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "packets" / f"{finding_id}.md"


def result_path(store: RegisterStore, finding_id: str) -> Path:
    return store.register_dir / _TRIAGE_SUBDIR / "results" / f"{finding_id}.json"


def consumed_result_path(store: RegisterStore, finding_id: str) -> Path:
    """Where a successfully consumed result is archived (see module doc)."""
    return (store.register_dir / _TRIAGE_SUBDIR / "results" / "consumed"
            / f"{finding_id}.json")


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


# ---------------------------------------------------------------------------
# Result consumption
# ---------------------------------------------------------------------------

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
