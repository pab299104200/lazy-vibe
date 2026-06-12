"""Deterministic reconciler: run candidates vs register (spec §5)."""
from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path

from .fingerprint import compute, jaccard, normalize_path, title_tokens
from .ingest import Candidate
from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding)
from .scope import Scope, matches as _scope_matches
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
    collisions: list[tuple[str, str]] = field(default_factory=list)
    theme_candidates: set[str] = field(default_factory=set)
    # Post-reconcile register state, captured inside the lock so callers
    # render the report without an unlocked second store.load().
    findings: dict[str, Finding] = field(default_factory=dict)


def _now(date: str) -> str:
    return f"{date}T00:00:00+00:00"


def _bump_seen(finding: Finding, run_id: str, date: str) -> None:
    finding.last_seen = {"run_id": run_id, "date": date}
    finding.occurrences += 1


def _merge_evidence(finding: Finding, candidate: Candidate) -> None:
    ref = _candidate_ref(candidate)
    seen = {(e["ref"], e["run_id"]) for e in finding.evidence}
    if (ref, candidate.run_id) not in seen:
        finding.evidence.append({"type": "audit", "ref": ref,
                                 "run_id": candidate.run_id})


def _candidate_ref(candidate: Candidate) -> str:
    return f"{normalize_path(candidate.path)}:{candidate.line}"


def _evidence_refs(finding: Finding) -> set[str]:
    return {e["ref"] for e in finding.evidence}


def _is_collision(existing: Finding, candidate: Candidate) -> bool:
    if _candidate_ref(candidate) in _evidence_refs(existing):
        return False
    score = jaccard(title_tokens(candidate.title), title_tokens(existing.title))
    return score < FUZZY_THRESHOLD


def _existing_collision(findings: dict[str, Finding], existing: Finding,
                        candidate: Candidate) -> Finding | None:
    ref = _candidate_ref(candidate)
    for finding in findings.values():
        for event in finding.history:
            if (event.get("event") == "collision"
                    and event.get("collided_with") == existing.finding_id
                    and event.get("ref") == ref):
                return finding
    return None


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
        fingerprint=compute(candidate.category, theme, candidate.path,
                            candidate.symbol),
        fingerprint_inputs={"category": candidate.category, "theme": theme,
                            "path": normalize_path(candidate.path),
                            "symbol": candidate.symbol},
        title=candidate.title,
        description=f"Imported from {candidate.blocker_id} "
                    f"(run {candidate.run_id}). References: {candidate.references}",
        severity=candidate.severity,
        severity_source="proposed",
        # taxonomy from the source adapter; refinement is a triage-stage
        # concern (plan 2b), like in_scope
        taxonomy=candidate.taxonomy,
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


def _create_collision_finding(findings: dict[str, Finding], candidate: Candidate,
                              theme: str, run_id: str, date: str,
                              existing: Finding, original_fingerprint: str) -> Finding:
    symbol = f"{candidate.symbol}#collision:{candidate.line}"
    split_candidate = replace(candidate, symbol=symbol)
    finding = _create_finding(findings, split_candidate, theme, run_id, date)
    finding.history.append({"ts": _now(date),
                            "event": "collision",
                            "collided_with": existing.finding_id,
                            "original_fingerprint": original_fingerprint,
                            "ref": _candidate_ref(candidate),
                            "run_id": run_id})
    return finding


def reconcile(store: RegisterStore, candidates: list[Candidate],
              vocab: dict[str, list[str]], *, run_id: str,
              date: str, scope: Scope | None = None) -> ReconcileResult:
    result = ReconcileResult()
    with store.locked():
        findings = store.load()
        index = store.by_fingerprint(findings)
        for candidate in candidates:
            theme = map_theme(candidate.theme_raw, vocab)
            if theme.startswith("_candidate:"):
                result.theme_candidates.add(theme)
            fingerprint = compute(candidate.category, theme, candidate.path,
                                  candidate.symbol)
            existing = index.get(fingerprint)
            if existing is not None:
                if _is_collision(existing, candidate):
                    collision = _existing_collision(findings, existing, candidate)
                    if collision is not None:
                        if collision.last_seen.get("run_id") != run_id:
                            _bump_seen(collision, run_id, date)
                            _merge_evidence(collision, candidate)
                            _review_severity(collision, candidate, date)
                            result.merged.append(collision)
                        continue
                    new = _create_collision_finding(
                        findings, candidate, theme, run_id, date, existing,
                        fingerprint)
                    if scope is not None:
                        new.in_scope = _scope_matches(new, scope)
                        if not new.in_scope:
                            transition(new, Disposition.PARKED, by="scope",
                                       reason="outside launch scope at creation",
                                       now=_now(date))
                    findings[new.finding_id] = new
                    index[new.fingerprint] = new
                    result.new.append(new)
                    result.collisions.append((new.finding_id, existing.finding_id))
                    continue
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
            # `findings` already contains entries created earlier in this
            # run: same-run siblings are intentionally fuzzy-matchable, so
            # theme-fragmented duplicates of one underlying issue get linked
            # for verifier merge (spec §5).
            fuzzy_hit = _find_fuzzy(findings, candidate)
            new = _create_finding(findings, candidate, theme, run_id, date)
            if fuzzy_hit is not None:
                new.history.append({"ts": _now(date),
                                    "event": "fuzzy_match_candidate",
                                    "candidate_of": fuzzy_hit.finding_id,
                                    "run_id": run_id})
                result.fuzzy.append((new.finding_id, fuzzy_hit.finding_id))
            if scope is not None:
                new.in_scope = _scope_matches(new, scope)
                if not new.in_scope:
                    transition(new, Disposition.PARKED, by="scope",
                               reason="outside launch scope at creation",
                               now=_now(date))
            findings[new.finding_id] = new
            index[new.fingerprint] = new
            result.new.append(new)
        store.save(findings)
        result.findings = findings
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
    if result.collisions:
        lines += ["## Collision splits", "",
                  "Same fingerprint inputs, materially different evidence/title.", ""]
        for new_id, existing_id in result.collisions:
            new = findings[new_id]
            lines.append(f"- **{new_id}** split from `{existing_id}`: "
                         f"{markdown_cell(new.title)}")
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
