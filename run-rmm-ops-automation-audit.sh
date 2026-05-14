#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
RUNNER="${RUNNER:-claude}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/docs/reviews/$(date +%Y-%m-%d)-ops-automation-audit}"
SKILL_FILE="${RMM_OPS_AUTOMATION_AUDIT_SKILL:-$REPO_ROOT/.claude/skills/spog-ops-auditor/SKILL.md}"
PROMPT_DIR="$RUN_DIR/prompts"
LOG_DIR="$RUN_DIR/logs"
PROMPT_FILE="$PROMPT_DIR/rmm-ops-automation-audit.md"
LOG_FILE="$LOG_DIR/rmm-ops-automation-audit.log"

usage() {
  cat <<USAGE
Usage: run-rmm-ops-automation-audit.sh [--dry-run]

Runs the RMM/SPOG ops automation audit as a fixed-domain harness.

Environment:
  REPO_ROOT                        RMM repo root. Defaults to current directory.
  RUN_DIR                          Output directory. Defaults to docs/reviews/<date>-ops-automation-audit.
  RUNNER                           Agent backend: claude, codex, or gemini. Defaults to claude.
  RMM_OPS_AUTOMATION_AUDIT_SKILL   Override skill file path.
USAGE
}

DRY_RUN=0
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$SKILL_FILE" ]]; then
  printf 'Skill file not found: %s\n' "$SKILL_FILE" >&2
  exit 1
fi

if ((DRY_RUN)); then
  printf 'Prompt: %s\nLog: %s\n' "$PROMPT_FILE" "$LOG_FILE"
  exit 0
fi

mkdir -p "$PROMPT_DIR" "$LOG_DIR"

{
  printf '# RMM Ops Automation Audit Harness\n\n'
  printf 'Repository root: %s\n\n' "$REPO_ROOT"
  printf 'Run directory: %s\n\n' "$RUN_DIR"
  printf 'You are running a fixed-domain automation-chain audit. Follow the skill exactly, write durable artifacts under the run directory, cite file:line evidence, and do not modify product code.\n\n'
  printf '## Skill Policy\n\n'
  cat "$SKILL_FILE"
} > "$PROMPT_FILE"

cd "$REPO_ROOT"
case "$RUNNER" in
  claude)
    claude -p --verbose --output-format stream-json --permission-mode bypassPermissions "$(cat "$PROMPT_FILE")" > "$LOG_FILE" 2>&1
    ;;
  codex)
    codex exec --ephemeral --full-auto --skip-git-repo-check -C "$REPO_ROOT" - < "$PROMPT_FILE" > "$LOG_FILE" 2>&1
    ;;
  gemini)
    gemini --yolo "$(cat "$PROMPT_FILE")" > "$LOG_FILE" 2>&1
    ;;
  *)
    printf 'Unsupported RUNNER: %s\n' "$RUNNER" >&2
    exit 2
    ;;
esac

printf 'Ops automation audit log: %s\n' "$LOG_FILE"
