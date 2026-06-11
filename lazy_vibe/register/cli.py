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
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 run_id, args.date)


def _cmd_backfill(args: argparse.Namespace) -> int:
    candidates = parse_ledger(Path(args.ledger), run_id=args.run_id)
    return _reconcile_candidates(Path(args.register_dir), candidates,
                                 args.run_id, args.date)


def _cmd_report(args: argparse.Namespace) -> int:
    store = RegisterStore(Path(args.register_dir))
    findings = store.load()
    store.markdown_path.write_text(store.render_markdown(findings))
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
    p.add_argument("--date", default=_today())
    p.set_defaults(func=_cmd_reconcile)

    p = sub.add_parser("backfill", help="ingest + reconcile a ledger in one pass")
    p.add_argument("--register-dir", required=True)
    p.add_argument("--ledger", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--date", default=_today())
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


if __name__ == "__main__":
    sys.exit(main())
