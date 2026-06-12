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

``run_triage`` abort behaviour: decisions are collected into the in-memory
findings dict and written via a single ``store.save`` at the end of the walk
(inside ``store.locked()``). An EOF / KeyboardInterrupt mid-walk means the
save never happens and all in-progress decisions are lost — the register is
left byte-identical to its state before ``run_triage`` was called. This is
intentional: the walk is cheap to re-run, and a partial save that commits
some items but not others is harder to reason about than a clean no-op abort.
"""
from __future__ import annotations

import datetime as _dt
import sys
from dataclasses import dataclass

from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding, RegisterError)
from .scope import ScopeProposal
from .store import RegisterStore, markdown_cell
from .transitions import reaffirm_risk, transition

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


# ---------------------------------------------------------------------------
# Interactive triage walk (spec §6 stage 3)
# ---------------------------------------------------------------------------

@dataclass
class TriageOutcome:
    decided: int = 0
    skipped: int = 0


_PROMPT = ("[a]ccept rec / [o]pen / [f]alse-positive / [r]isk-accept / "
           "[p]ark / [s]kip > ")


def _recommendation_choice(item: QueueItem) -> str:
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


def _apply_decision(findings, item: QueueItem, choice: str, *, date: str,
                    prompt_fn) -> bool:
    """Apply a single decision stamped pete. Returns True if it changed state."""
    now = f"{date}T00:00:00+00:00"
    finding = findings[item.finding_id]
    if choice == "a":
        choice = _recommendation_choice(item)
    if choice == "o":
        transition(finding, Disposition.OPEN, by="pete",
                   reason="triaged open", now=now, verified=True)
    elif choice == "f":
        transition(finding, Disposition.FALSE_POSITIVE, by="pete",
                   reason="triaged false_positive", now=now)
    elif choice == "p":
        transition(finding, Disposition.PARKED, by="pete",
                   reason="triaged parked", now=now)
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


def run_triage(store: RegisterStore, *, scope_proposals: list[ScopeProposal],
               date: str, stdin=None, accept_all: bool = False) -> TriageOutcome:
    """Walk the queue and write pete-stamped dispositions.

    Non-interactive when ``accept_all=True`` or when stdin is exhausted
    (remaining items are skipped).

    Abort behaviour: decisions are applied to the in-memory findings dict and
    the register is saved once at the end inside ``store.locked()``. An EOF or
    KeyboardInterrupt before the save completes means no decisions are
    persisted — the register is left byte-identical to its pre-call state.
    See module docstring for rationale.
    """
    stdin = stdin or sys.stdin
    outcome = TriageOutcome()
    items = build_queue(store, scope_proposals=scope_proposals, today=date)

    def prompt(text: str) -> str:
        line = stdin.readline()
        return line if line else "s\n"

    with store.locked():
        findings = store.load()
        for item in items:
            if item.finding_id not in findings:
                continue
            if accept_all:
                choice = "a"
            else:
                print(f"{item.finding_id} {item.severity} [{item.kind}] "
                      f"{item.title}\n  rec: {item.recommendation} — "
                      f"{item.detail}")
                choice = prompt(_PROMPT).strip().lower()[:1] or "s"
            try:
                changed = _apply_decision(findings, item, choice, date=date,
                                          prompt_fn=lambda t: prompt(t).strip())
            except RegisterError as exc:
                print(f"  skipped {item.finding_id}: {exc}", file=sys.stderr)
                outcome.skipped += 1
                continue
            if changed:
                outcome.decided += 1
            else:
                outcome.skipped += 1
        store.save(findings)
    return outcome
