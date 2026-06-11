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
