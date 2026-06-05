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
      "verification_commands": ["test -f feature.txt"]
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
- Verification commands and outputs: test -f feature.txt -> pass
- Issues encountered: none
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept: none
- Boundary/failure/operability proof, or why not applicable: not applicable
- Documentation/contract updates, or why not applicable: not applicable
- Final status: complete
EOF

run_feature_verify "$repo" "$run_dir" "$tmp_root/pass.out" ||
  fail "feature verify failed with complete result artifact: $(cat "$tmp_root/pass.out")"

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

printf 'PASS feature-build fixture gates\n'
