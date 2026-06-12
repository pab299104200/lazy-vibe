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
(inside ``store.locked()``). EOF mid-walk aborts the in-flight item (nothing
partial — no sentinel review dates or reasons), stops the walk, and saves
only the decisions completed before the EOF; each is a complete, valid
transition. KeyboardInterrupt propagates before the save and persists
nothing. Either way the register never holds a half-applied decision.
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
    # Disposition the finding had when the queue was built. The triage walk
    # refuses to apply a decision if the live disposition has drifted (I3).
    source_disposition: str = ""


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
        recommendation="review reopen",
        source_disposition=finding.disposition) for ref in novel]


def _finding_items(f: Finding, today_date: _dt.date) -> list[QueueItem]:
    items: list[QueueItem] = []
    if f.disposition == "new" and _has_event(f, "risk_accept_proposed"):
        ev = _last_event(f, "risk_accept_proposed")
        items.append(QueueItem(f.finding_id, "risk_accept", f.severity,
                               f.title, f"proposed by {ev.get('by')}",
                               recommendation="risk-accept (set review_by)",
                               source_disposition=f.disposition))
    if (f.disposition == "risk_accepted"
            and _dt.date.fromisoformat(f.review_by) < today_date):
        # review_by is guaranteed ISO by Finding.validate (risk_accepted
        # requires it); mirrors readiness.evaluate's past-due check.
        items.append(QueueItem(
            f.finding_id, "risk_review", f.severity, f.title,
            f"risk acceptance review_by {f.review_by} is past due",
            recommendation="reaffirm or open",
            source_disposition=f.disposition))
    sev_ev = _last_event(f, "severity_review_proposed")
    if sev_ev:
        items.append(QueueItem(
            f.finding_id, "severity_review", f.severity, f.title,
            f"run proposes {sev_ev.get('proposed')} vs current "
            f"{sev_ev.get('current')}",
            recommendation=f"review severity {sev_ev.get('proposed')}",
            source_disposition=f.disposition))
    items.extend(_reopen_items(f))
    if f.disposition == "new" and not _has_event(f, "verification"):
        kind = ("fuzzy_confirm" if _has_event(f, "fuzzy_match_candidate")
                else "unverified")
        detail = ("verifier never returned a result — re-run verify"
                  if kind == "unverified"
                  else "probable duplicate; verifier confirm pending")
        items.append(QueueItem(f.finding_id, kind, f.severity, f.title,
                               detail, recommendation="re-run verify",
                               source_disposition=f.disposition))
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
            proposal.reason, recommendation=proposal.kind,
            source_disposition=f.disposition if f else ""))
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
