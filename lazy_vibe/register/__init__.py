"""Persistent findings register (lazy-vibe v3 register core, spec §4-§6).

Canonical store: docs/audit/register/register.jsonl in each product repo.
CLI: python -m lazy_vibe.register {ingest,reconcile,backfill,report,
     scorecard-ingest,scope-recompute,readiness,verify-packets,
     verify-consume,triage,close}
Spec: docs/superpowers/specs/2026-06-11-register-core-design.md
"""
from .ingest import Candidate, parse_ledger, read_candidates, write_candidates
from .model import (PROTECTED_DISPOSITIONS, SEVERITY_ORDER, Disposition,
                    Finding, RegisterError, Severity)
from .policy import Policy, PolicyOutcome, Rule, apply_policy, load_policy
from .queue import (QueueDrift, QueueItem, TriageOutcome, build_queue,
                    render_queue, run_triage)
from .readiness import ReadinessReport, evaluate, render_readiness
from .reconcile import ReconcileResult, reconcile, render_report
from .scope import (Gate, Scope, ScopeProposal, Surface, load_scope, matches,
                    recompute)
from .scorecard import ScorecardParse, parse_scorecard
from .store import RegisterStore, markdown_cell
from .themes import load_vocabulary, map_theme
from .transitions import (LEGAL_EDGES, TransitionError, reaffirm_risk,
                           transition, validate_regression_test)
from .verify import (RESULT_SCHEMA_VERSION, VerifyOutcome, consume_results,
                     consumed_result_path, generate_packets,
                     last_verification, packet_path, result_path)

__all__ = [
    "Candidate", "Disposition", "Finding", "Gate", "LEGAL_EDGES",
    "Policy", "PolicyOutcome",
    "PROTECTED_DISPOSITIONS", "QueueDrift", "QueueItem",
    "RESULT_SCHEMA_VERSION", "ReadinessReport", "ReconcileResult",
    "RegisterError", "RegisterStore", "Rule", "SEVERITY_ORDER", "Scope",
    "ScopeProposal", "ScorecardParse", "Severity", "Surface",
    "TransitionError", "TriageOutcome",
    "VerifyOutcome",
    "apply_policy", "build_queue", "consume_results", "consumed_result_path",
    "evaluate", "generate_packets", "last_verification",
    "load_policy", "load_scope", "load_vocabulary", "map_theme",
    "markdown_cell", "matches", "packet_path", "parse_ledger",
    "parse_scorecard", "read_candidates", "reaffirm_risk", "recompute",
    "reconcile", "render_queue", "render_readiness", "render_report",
    "result_path", "run_triage", "transition", "validate_regression_test",
    "write_candidates",
]
