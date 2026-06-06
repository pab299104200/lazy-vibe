#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_feature_verify() {
  local repo="$1" run_dir="$2" output="$3"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --verify-only >"$output" 2>&1
}

run_feature_execute() {
  local repo="$1" run_dir="$2" output="$3"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --execute >"$output" 2>&1
}

run_feature_execute_with_fake_agent() {
  local repo="$1" run_dir="$2" output="$3" bin_dir="$4"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  FEATURE_BUILD_IMPLEMENTER_AGENT=codex \
  PATH="$bin_dir:$PATH" \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --execute >"$output" 2>&1
}

run_feature_execute_verify_with_fake_agent() {
  local repo="$1" run_dir="$2" output="$3" bin_dir="$4"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  FEATURE_BUILD_IMPLEMENTER_AGENT=codex \
  PATH="$bin_dir:$PATH" \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --execute \
      --verify >"$output" 2>&1
}

run_feature_verify_with_gates() {
  local repo="$1" run_dir="$2" output="$3"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --verify-only \
      --verify >"$output" 2>&1
}

run_feature_verify_with_agent_repair() {
  local repo="$1" run_dir="$2" output="$3" bin_dir="$4"
  REPO_ROOT="$repo" \
  FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 \
  FEATURE_BUILD_IMPLEMENTER_AGENT=codex \
  PATH="$bin_dir:$PATH" \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m lazy_vibe.feature_build \
      --feature fixture \
      --run-dir "$run_dir" \
      --verify-only \
      --verify >"$output" 2>&1
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/lazy-vibe-feature-build.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/repo"
run_dir="$repo/docs/plans/fixture"
mkdir -p "$repo/docs/new-feature" "$run_dir/results"
printf '# Fixture\n' > "$repo/docs/new-feature/fixture.md"
printf 'implemented\n' > "$repo/feature.txt"

cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T01",
      "title": "API session feature",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt", "bash -c 'count=$(grep -c \"Fixture\" docs/new-feature/fixture.md); [ $count -ge 1 ]'"]
    }
  ]
}
EOF

cat > "$run_dir/results/T01.md" <<'EOF'
# T01

- Files created/modified: feature.txt
- Verification commands and outputs: not listed
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

if run_feature_verify "$repo" "$run_dir" "$tmp_root/missing-command.out"; then
  fail "feature verify unexpectedly passed without listing the exact verification command"
fi
grep -q 'does not list verification command' "$tmp_root/missing-command.out" ||
  fail "missing-command failure reason was not explicit"

cat > "$run_dir/results/T01.md" <<'EOF'
# T01

- Files created/modified: feature.txt
- Verification commands and outputs: test -f feature.txt -> pass; bash -c 'count=$(grep -c "Fixture" docs/new-feature/fixture.md); echo "fixture references: $count"; [ $count -ge 1 ]' -> pass; `rg -n "TODO|FIXME|placeholder" feature.txt` -> no matches
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable

## Final status

- `complete`
EOF

run_feature_verify "$repo" "$run_dir" "$tmp_root/pass.out" ||
  fail "feature verify failed with complete result artifact: $(cat "$tmp_root/pass.out")"

PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" REPO="$repo" python3 - <<'PY'
import os
from pathlib import Path

from lazy_vibe.feature_build.runner import (
    contains_deferral_marker,
    run_shell,
    standard_gate_infra_flake_retry_commands,
)

repo = Path(os.environ["REPO"])
result = run_shell(
    'rg -n "Fixture" docs/new-feature/fixture.md',
    repo,
    extra_env={"PATH": "/usr/bin:/bin"},
)
assert result.returncode == 0, result
assert "docs/new-feature/fixture.md:1:# Fixture" in result.output
assert not contains_deferral_marker(
    "Replaced stale future workload-identity plan entries so later task verification uses the package path."
)
assert not contains_deferral_marker(
    "Residue scan found no stale routes, TODO/FIXME markers, or stub paths in changed files."
)
assert contains_deferral_marker("Leave the product integration for future work.")
assert contains_deferral_marker("TODO: implement the product integration later.")
assert standard_gate_infra_flake_retry_commands(
    "cd frontend && npm run test",
    "[vitest-pool]: Failed to start forks worker. Timeout waiting for worker to respond",
) == ["cd frontend && npm run test -- --pool=threads --maxWorkers=1"]
assert not standard_gate_infra_flake_retry_commands(
    "cd frontend && npm run test",
    "expected accessible name to match",
)
PY

cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T01",
      "title": "API session feature",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["bash -c 'test -f feature.txt'"]
    }
  ]
}
EOF

cat > "$run_dir/results/T01.md" <<'EOF'
# T01

- Files created/modified: feature.txt
- Verification commands and outputs: bash -c 'test -f feature.txt && echo ok' -> ok
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify "$repo" "$run_dir" "$tmp_root/bash-prefix-pass.out" ||
  fail "feature verify failed when result documented a bash -c command with an echo suffix: $(cat "$tmp_root/bash-prefix-pass.out")"

mkdir -p "$repo/backend"
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T01",
      "title": "Backend migration proof",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["cd backend && printf 'iu0020s02svctok (head)\\n' | grep -E 'iu0020s02svctok \\(head\\)'"]
    }
  ]
}
EOF

cat > "$run_dir/results/T01.md" <<EOF
# T01

- Files created/modified: feature.txt
- Verification commands and outputs: cd $repo/backend && printf 'iu0020s02svctok (head)\\n' | grep -E "iu0020s02svctok \\(head\\)" -> iu0020s02svctok (head)
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify "$repo" "$run_dir" "$tmp_root/repo-relative-command-pass.out" ||
  fail "feature verify failed when result documented an equivalent absolute cd command: $(cat "$tmp_root/repo-relative-command-pass.out")"

cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T01",
      "title": "Python import proof",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["python3 -c \"assert 1 == 1\""]
    },
    {
      "task_id": "T02",
      "title": "Sequenced follow-on task",
      "task_type": "backend",
      "depends_on": ["T01"],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF

cat > "$run_dir/results/T01.md" <<'EOF'
# T01

- Files created/modified: feature.txt
- Verification commands and outputs: python3 -c "assert 1 == 1; print('ok')" -> ok
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: runtime wiring is deferred to T02.
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: covered by later review gate task.
- Final status: complete
EOF

cat > "$run_dir/results/T02.md" <<'EOF'
# T02

- Files created/modified: feature.txt
- Verification commands and outputs: test -f feature.txt -> pass; test -d backend -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify "$repo" "$run_dir" "$tmp_root/python-prefix-sequencing-pass.out" ||
  fail "feature verify rejected equivalent python -c proof or scoped task sequencing: $(cat "$tmp_root/python-prefix-sequencing-pass.out")"

cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T02",
      "title": "Unverified implementation",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "pending",
      "files_expected": ["feature.txt"],
      "verification_commands": []
    }
  ]
}
EOF

if run_feature_verify "$repo" "$run_dir" "$tmp_root/no-command.out"; then
  fail "feature verify unexpectedly passed a task with no verification command"
fi
grep -q 'no runnable verification commands' "$tmp_root/no-command.out" ||
  fail "no-command failure reason was not explicit"

rm -rf "$run_dir"
mkdir -p "$run_dir"
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T03",
      "title": "Already satisfied task",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "pending",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF

run_feature_execute "$repo" "$run_dir" "$tmp_root/already-ok.out" ||
  fail "already-ok execution failed: $(cat "$tmp_root/already-ok.out")"
grep -q '\[already-ok\] task=T03' "$tmp_root/already-ok.out" ||
  fail "already-ok task was not closed by verification"
grep -q 'Final status: complete' "$run_dir/results/T03.md" ||
  fail "already-ok result artifact was not written"
grep -q 'test -f feature.txt' "$run_dir/results/T03.md" ||
  fail "already-ok result artifact did not list verification command"

rm -rf "$run_dir"
mkdir -p "$run_dir"
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T04",
      "title": "Recovered stale running task",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "running",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF

run_feature_execute "$repo" "$run_dir" "$tmp_root/stale-running.out" ||
  fail "stale-running execution failed: $(cat "$tmp_root/stale-running.out")"
grep -q '\[already-ok\] task=T04' "$tmp_root/stale-running.out" ||
  fail "stale running task was not recovered and executed"
grep -q '"status": "complete"' "$run_dir/tasks.json" ||
  fail "stale running task was not marked complete"

rm -rf "$run_dir"
mkdir -p "$run_dir" "$tmp_root/bin-contract-refresh"
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T04B",
      "title": "Refresh agent-repaired task contract",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "pending",
      "files_expected": ["stale/old_model.py"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF
cat > "$tmp_root/bin-contract-refresh/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
python3 - <<'PY'
import json
from pathlib import Path

tasks_file = Path("docs/plans/fixture/tasks.json")
data = json.loads(tasks_file.read_text())
task = data["tasks"][0]
task["files_expected"] = ["feature.txt"]
task["last_error"] = ""
tasks_file.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")

result = Path("docs/plans/fixture/results/T04B.md")
result.parent.mkdir(parents=True, exist_ok=True)
result.write_text(
    """# T04B

- Files created/modified: feature.txt
- Verification commands and outputs: test -f feature.txt -> pass; test -d backend -> pass
- Issues encountered: Repaired stale expected-file metadata from stale/old_model.py to feature.txt.
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
"""
)
PY
EOF
chmod +x "$tmp_root/bin-contract-refresh/codex"

run_feature_execute_with_fake_agent "$repo" "$run_dir" "$tmp_root/contract-refresh.out" "$tmp_root/bin-contract-refresh" ||
  fail "agent-repaired task contract was not refreshed in the same run: $(cat "$tmp_root/contract-refresh.out")"
grep -q '\[ok\] task=T04B' "$tmp_root/contract-refresh.out" ||
  fail "agent-repaired task contract did not close without a second run"
grep -q '"files_expected": \[' "$run_dir/tasks.json" ||
  fail "refreshed task contract was not persisted"
grep -q '"feature.txt"' "$run_dir/tasks.json" ||
  fail "refreshed expected file was not persisted"

rm -rf "$run_dir"
mkdir -p "$run_dir/results" "$repo/backend"
cat > "$repo/backend/pyproject.toml" <<'EOF'
[tool.ruff]
line-length = 100
EOF
cat > "$repo/backend/ruff_dirty.py" <<'EOF'
import sys
import os

print("ok")
EOF
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T05",
      "title": "Standard gate repair",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF

cat > "$run_dir/results/T05.md" <<'EOF'
# T05

- Files created/modified: feature.txt
- Verification commands and outputs: test -f feature.txt -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify_with_gates "$repo" "$run_dir" "$tmp_root/standard-repair.out" ||
  fail "standard gate repair failed: $(cat "$tmp_root/standard-repair.out")"
grep -q '\[standard-gate-repair\] cd backend && python3 -m ruff check .' "$tmp_root/standard-repair.out" ||
  fail "standard gate repair did not run for Ruff check"
grep -q 'print("ok")' "$repo/backend/ruff_dirty.py" ||
  fail "Ruff repair removed expected executable statement"

rm -rf "$run_dir"
mkdir -p "$run_dir/results" "$repo/frontend" "$tmp_root/bin"
cat > "$repo/frontend/package.json" <<'EOF'
{
  "scripts": {
    "lint": "test -f lint_fixed.txt"
  },
  "devDependencies": {}
}
EOF
cat > "$tmp_root/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
touch frontend/lint_fixed.txt
EOF
chmod +x "$tmp_root/bin/codex"
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T06",
      "title": "Agent standard gate repair",
      "task_type": "frontend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["feature.txt"],
      "verification_commands": ["test -f feature.txt"]
    }
  ]
}
EOF

cat > "$run_dir/results/T06.md" <<'EOF'
# T06

- Files created/modified: feature.txt
- Verification commands and outputs: test -f feature.txt -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify_with_agent_repair "$repo" "$run_dir" "$tmp_root/standard-agent-repair.out" "$tmp_root/bin" ||
  fail "standard gate agent repair failed: $(cat "$tmp_root/standard-agent-repair.out")"
grep -q '\[standard-gate-agent-repair\] gate=.*agent=codex' "$tmp_root/standard-agent-repair.out" ||
  fail "standard gate agent repair was not dispatched"
test -f "$repo/frontend/lint_fixed.txt" ||
  fail "standard gate agent repair did not modify the active checkout"

rm -rf "$run_dir" "$repo/backend" "$repo/frontend"
mkdir -p "$run_dir/results" "$repo/backend/routers"
git -C "$repo" init -q
git -C "$repo" config user.email "fixture@example.com"
git -C "$repo" config user.name "Fixture"
git -C "$repo" add .
git -C "$repo" commit -qm "fixture baseline"
cat > "$repo/backend/routers/api_contract_fixture.py" <<'EOF'
def route_contract_fixture():
    return {"ok": True}
EOF
cat > "$run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T07",
      "title": "API contract gate",
      "task_type": "backend",
      "depends_on": [],
      "model_class": "balanced",
      "status": "complete",
      "files_expected": ["backend/routers/api_contract_fixture.py"],
      "verification_commands": ["test -f backend/routers/api_contract_fixture.py"]
    }
  ]
}
EOF

cat > "$run_dir/results/T07.md" <<'EOF'
# T07

- Files created/modified: backend/routers/api_contract_fixture.py
- Verification commands and outputs: test -f backend/routers/api_contract_fixture.py -> pass; test -f /home/pete/cadres/shared/templates/route-acceptance-checklist.md -> pass; test -d backend -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

if run_feature_verify_with_gates "$repo" "$run_dir" "$tmp_root/api-contract-missing-docs.out"; then
  fail "API contract gate unexpectedly passed without docs"
fi
grep -q 'API surface changed without contract documentation updates' "$run_dir"/verify/standard-gates/*.log ||
  fail "API contract gate did not explain missing docs: $(cat "$tmp_root/api-contract-missing-docs.out")"

mkdir -p "$repo/docs/functional"
cat > "$repo/docs/functional/api-contract-fixture.md" <<'EOF'
# API contract fixture

Documents endpoint purpose, request schema, response schema, permissions, errors,
audit events, state transitions, idempotency, pagination, and examples.
EOF

run_feature_verify_with_gates "$repo" "$run_dir" "$tmp_root/api-contract-with-docs.out" ||
  fail "API contract gate failed after docs were added: $(cat "$tmp_root/api-contract-with-docs.out")"
grep -q 'api-contract-gate: API docs touched' "$run_dir"/verify/standard-gates/*.log ||
  fail "API contract gate did not report successful docs validation"

auto_repo="$tmp_root/auto-branch-repo"
auto_run_dir="$auto_repo/docs/plans/fixture"
mkdir -p "$auto_repo/docs/new-feature" "$auto_run_dir" "$tmp_root/bin-auto-branch"
git -C "$auto_repo" init -q
git -C "$auto_repo" config user.email "fixture@example.com"
git -C "$auto_repo" config user.name "Fixture"
printf '# Fixture\n' > "$auto_repo/docs/new-feature/fixture.md"
git -C "$auto_repo" add .
git -C "$auto_repo" commit -qm "fixture baseline"
cat > "$auto_run_dir/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "task_id": "T08",
      "title": "Auto branch and commit",
      "task_type": "docs",
      "depends_on": [],
      "model_class": "balanced",
      "status": "pending",
      "files_expected": ["auto_feature.txt"],
      "verification_commands": ["test -f auto_feature.txt"]
    }
  ]
}
EOF
cat > "$tmp_root/bin-auto-branch/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'done\n' > auto_feature.txt
mkdir -p docs/plans/fixture/results
cat > docs/plans/fixture/results/T08.md <<'RESULT'
# T08

- Files created/modified: auto_feature.txt
- Verification commands and outputs: test -f auto_feature.txt -> pass; test -d docs -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
RESULT
EOF
chmod +x "$tmp_root/bin-auto-branch/codex"

run_feature_execute_verify_with_fake_agent "$auto_repo" "$auto_run_dir" "$tmp_root/auto-branch-commit.out" "$tmp_root/bin-auto-branch" ||
  fail "auto branch/commit feature build failed: $(cat "$tmp_root/auto-branch-commit.out")"
branch="$(git -C "$auto_repo" rev-parse --abbrev-ref HEAD)"
[ "$branch" = "feature/fixture" ] ||
  fail "feature build did not switch to default feature branch; got $branch"
git -C "$auto_repo" log -1 --pretty=%s | grep -q 'feat: build fixture' ||
  fail "feature build did not auto-commit with default message"
git -C "$auto_repo" status --porcelain | grep -q '^$' &&
  fail "git status unexpectedly printed an empty-line entry"
[ -z "$(git -C "$auto_repo" status --porcelain)" ] ||
  fail "auto-committed feature build left tracked changes dirty"

printf 'PASS feature-build fixture gates\n'
