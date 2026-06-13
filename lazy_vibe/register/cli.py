"""CLI: python -m lazy_vibe.register {ingest,reconcile,backfill,report,
scorecard-ingest,scope-recompute,readiness,verify-packets,verify-consume,
triage,close} (spec §11)."""
from __future__ import annotations

import argparse
import datetime as _dt
import sys
from pathlib import Path

from .ingest import parse_ledger, read_candidates, write_candidates
from .model import Disposition, RegisterError
from .policy import apply_policy, load_policy
from .queue import build_queue, render_queue, run_triage
from .readiness import evaluate, render_readiness
from .reconcile import reconcile, render_report
from .scope import load_scope, recompute
from .scorecard import parse_scorecard
from .split_resolve import consume_split_results, generate_split_packets
from .store import RegisterStore
from .themes import load_vocabulary
from .transitions import transition, validate_regression_test
from .verify import consume_results, generate_packets


def _today() -> str:
    return _dt.date.today().isoformat()


def _cmd_ingest(args: argparse.Namespace) -> int:
    candidates = parse_ledger(Path(args.ledger), run_id=args.run_id)
    write_candidates(candidates, Path(args.out), run_id=args.run_id)
    print(f"wrote {len(candidates)} candidates to {args.out}")
    return 0


def _reconcile_candidates(register_dir: Path, candidates, run_id: str,
                          date: str, scope_path=None) -> int:
    store = RegisterStore(register_dir)
    vocab = load_vocabulary(register_dir / "themes.yaml")
    scope = load_scope(Path(scope_path)) if scope_path else None
    result = reconcile(store, candidates, vocab, run_id=run_id, date=date,
                       scope=scope)
    report_path = register_dir / "reconcile-report.md"
    render_report(result, result.findings, report_path, run_id=run_id)
    print(f"{len(result.new)} new, {len(result.suppressed)} suppressed, "
          f"{len(result.regressed)} regressed — report: {report_path}")
    return 0


def _cmd_reconcile(args: argparse.Namespace) -> int:
    candidates = read_candidates(Path(args.candidates))
    run_id = candidates[0].run_id if candidates else "empty-run"
    date = args.date or _today()
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 run_id, date,
                                 scope_path=getattr(args, "scope", None))


def _cmd_backfill(args: argparse.Namespace) -> int:
    candidates = parse_ledger(Path(args.ledger), run_id=args.run_id)
    date = args.date or _today()
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 args.run_id, date,
                                 scope_path=getattr(args, "scope", None))


def _cmd_report(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    with store.locked():
        findings = store.load()
        store.write_markdown(findings)
    print(f"regenerated {store.markdown_path} ({len(findings)} findings)")
    return 0


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
                                 scope_path=getattr(args, "scope", None))


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


def _cmd_split_packets(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    written = generate_split_packets(store)
    print(f"wrote {len(written)} split-resolution packets to "
          f"{store.register_dir / 'triage' / 'split-packets'}")
    return 0


def _cmd_split_consume(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    outcome = consume_split_results(store, date=args.date or _today())
    print(f"this run: {len(outcome.opened)} opened, "
          f"{len(outcome.false_positive)} false_positive, "
          f"{len(outcome.parked)} parked, "
          f"{len(outcome.skipped)} skipped, "
          f"{len(outcome.unresolved)} unresolved")
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


def _cmd_start_remediation(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    now = f"{args.date or _today()}T00:00:00+00:00"
    with store.locked():
        findings = store.load()
        if args.finding not in findings:
            raise RegisterError(f"unknown finding {args.finding}")
        finding = findings[args.finding]
        if finding.disposition == "in_remediation":
            print(f"{args.finding} already in_remediation")
            return 0
        if finding.disposition not in ("open", "regressed"):
            raise RegisterError(
                f"{args.finding}: start-remediation requires open/regressed, "
                f"is {finding.disposition}")
        reason = args.reason or f"started remediation unit {args.unit}"
        transition(finding, Disposition.IN_REMEDIATION, by="harness",
                   reason=reason, now=now)
        store.save(findings)
    print(f"{args.finding} -> in_remediation")
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
    p.add_argument("--scope", default=None)
    p.set_defaults(func=_cmd_reconcile)

    p = sub.add_parser("backfill", help="ingest + reconcile a ledger in one pass")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--ledger", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--date", default=None)
    p.add_argument("--scope", default=None)
    p.set_defaults(func=_cmd_backfill)

    p = sub.add_parser("report", help="regenerate register.md from register.jsonl")
    p.add_argument("--register-dir", required=True)
    p.set_defaults(func=_cmd_report)

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

    p = sub.add_parser("verify-packets",
                       help="write verification packets for new findings")
    p.add_argument("--register-dir", required=True)
    p.set_defaults(func=_cmd_verify_packets)

    p = sub.add_parser("verify-consume",
                       help="consume verifier result JSON into the register")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_verify_consume)

    p = sub.add_parser("split-packets",
                       help="write agent packets for verifier split findings")
    p.add_argument("--register-dir", required=True)
    p.set_defaults(func=_cmd_split_packets)

    p = sub.add_parser("split-consume",
                       help="consume split resolver JSON into the register")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_split_consume)

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

    p = sub.add_parser("start-remediation",
                       help="harness: open/regressed -> in_remediation")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--finding", required=True)
    p.add_argument("--unit", required=True)
    p.add_argument("--reason", default=None)
    p.add_argument("--date", default=None)
    p.set_defaults(func=_cmd_start_remediation)

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
