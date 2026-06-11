"""Persistent findings register (lazy-vibe v3 register core, spec §4-§5).

Canonical store: docs/audit/register/register.jsonl in each product repo.
CLI: python -m lazy_vibe.register {ingest,reconcile,backfill,report,
     scorecard-ingest,scope-recompute,readiness}
Spec: docs/superpowers/specs/2026-06-11-register-core-design.md
"""
from .ingest import Candidate, parse_ledger, read_candidates, write_candidates
from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding, RegisterError, Severity)
from .readiness import ReadinessReport, evaluate, render_readiness
from .reconcile import ReconcileResult, reconcile, render_report
from .scope import (Gate, Scope, ScopeProposal, Surface, load_scope, matches,
                    recompute)
from .scorecard import ScorecardParse, parse_scorecard
from .store import RegisterStore, markdown_cell
from .themes import load_vocabulary, map_theme
from .transitions import LEGAL_EDGES, TransitionError, reaffirm_risk, transition

__all__ = [
    "Candidate", "Disposition", "Finding", "Gate", "LEGAL_EDGES",
    "PROTECTED_DISPOSITIONS", "ReadinessReport", "ReconcileResult",
    "RegisterError", "RegisterStore", "SEVERITY_ORDER", "Scope",
    "ScopeProposal", "ScorecardParse", "Severity", "Surface",
    "TransitionError",
    "evaluate", "load_scope", "load_vocabulary", "map_theme", "markdown_cell",
    "matches", "parse_ledger", "parse_scorecard", "read_candidates",
    "reaffirm_risk", "recompute", "reconcile", "render_readiness",
    "render_report", "transition", "write_candidates",
]
