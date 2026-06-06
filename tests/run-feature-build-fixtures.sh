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
- Verification commands and outputs: test -f feature.txt -> pass
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

printf 'PASS feature-build fixture gates\n'
