from __future__ import annotations

import argparse
import csv
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


ALWAYS_SELECTED_KINDS = {"final"}
ALWAYS_SELECTED_JOB_IDS = {"00-bootstrap", "11-synthesis"}


@dataclass(frozen=True)
class Job:
    group: str
    job_id: str
    kind: str
    title: str
    output: str
    ref: str

    @property
    def search_text(self) -> str:
        return " ".join((self.job_id, self.kind, self.title, self.output, self.ref)).lower()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a differential audit job manifest.")
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--register-dir", required=True)
    parser.add_argument("--jobs-file", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--out-jobs-file", required=True)
    parser.add_argument("--baseline-sha", default="")
    parser.add_argument("--include-worktree", action="store_true")
    return parser.parse_args()


def run_git(repo_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def load_baseline(register_dir: Path, override_sha: str) -> str:
    if override_sha:
        return override_sha
    baseline_path = register_dir / "baseline.json"
    if not baseline_path.exists():
        raise SystemExit(
            f"Differential audit requires {baseline_path}. "
            "Run a full audit first or rerun with --full."
        )
    try:
        data = json.loads(baseline_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Differential audit baseline is invalid JSON: {baseline_path}: {exc}") from exc
    sha = str(data.get("git_sha") or "").strip()
    if not sha or sha == "unknown":
        raise SystemExit(
            f"Differential audit baseline at {baseline_path} does not contain a usable git_sha. "
            "Run a full audit first or rerun with --full."
        )
    return sha


def worktree_changed_paths(repo_root: Path) -> list[str]:
    paths: list[str] = []
    for args in (
        ("diff", "--name-only"),
        ("diff", "--cached", "--name-only"),
        ("ls-files", "--others", "--exclude-standard"),
    ):
        output = run_git(repo_root, *args)
        paths.extend(line.strip() for line in output.splitlines() if line.strip())
    return paths


def changed_paths(repo_root: Path, baseline_sha: str, include_worktree: bool) -> tuple[str, list[str]]:
    run_git(repo_root, "rev-parse", "--verify", f"{baseline_sha}^{{commit}}")
    head_sha = run_git(repo_root, "rev-parse", "--verify", "HEAD^{commit}")
    merge_base = run_git(repo_root, "merge-base", baseline_sha, "HEAD")
    if merge_base != baseline_sha:
        raise SystemExit(
            "Differential audit baseline is not an ancestor of HEAD. "
            "Run a full audit to refresh docs/audit/register/baseline.json, or rerun with --full."
        )
    output = run_git(repo_root, "diff", "--name-only", f"{baseline_sha}..HEAD")
    paths = [line.strip() for line in output.splitlines() if line.strip()]
    if include_worktree:
        paths.extend(worktree_changed_paths(repo_root))
    paths = sorted(dict.fromkeys(paths))
    return head_sha, paths


def read_jobs(path: Path) -> tuple[list[str], list[Job]]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        header = reader.fieldnames or []
        jobs = [
            Job(
                group=(row.get("group") or "").strip(),
                job_id=(row.get("job_id") or "").strip(),
                kind=(row.get("kind") or "").strip(),
                title=(row.get("title") or "").strip(),
                output=(row.get("output") or "").strip(),
                ref=(row.get("ref") or "").strip(),
            )
            for row in reader
            if (row.get("job_id") or "").strip()
        ]
    return header, jobs


def path_categories(path: str) -> set[str]:
    lower = path.lower()
    categories: set[str] = set()
    if lower.startswith(("backend/", "api/", "server/")) or lower.endswith(".py"):
        categories.update({"backend", "api", "runtime", "security", "test"})
    if "migration" in lower or "alembic" in lower or "schema" in lower:
        categories.update({"backend", "database", "migration", "runtime"})
    if lower.startswith(("frontend/", "web/", "ui/")) or lower.endswith((".tsx", ".ts", ".jsx", ".js", ".css")):
        categories.update({"frontend", "browser", "ux", "runtime", "simulation", "test"})
    if lower.startswith(("docs/", "documentation/")) or lower.endswith((".md", ".mdx", ".rst")):
        categories.update({"docs", "contract", "api", "spec"})
    if "openapi" in lower or "contract" in lower:
        categories.update({"contract", "api", "openapi", "docs"})
    if "tenant" in lower or "account" in lower or "rls" in lower:
        categories.update({"tenant", "isolation", "security", "permission"})
    if "auth" in lower or "rbac" in lower or "permission" in lower or "role" in lower:
        categories.update({"auth", "rbac", "security", "permission"})
    if "connector" in lower or "integration" in lower or "webhook" in lower:
        categories.update({"connector", "integration", "runtime"})
    if "test" in lower or "spec" in lower:
        categories.update({"test", "coverage", "runtime"})
    return categories or {"general"}


def tokens_for_categories(categories: set[str]) -> set[str]:
    tokens: set[str] = set()
    if categories & {"backend", "database", "migration"}:
        tokens.update({"backend", "database", "migration", "startup", "config"})
    if "api" in categories:
        tokens.update({"api", "contract", "openapi"})
    if categories & {"security", "auth", "rbac", "tenant", "isolation", "permission"}:
        tokens.update({"security", "auth", "rbac", "tenant", "isolation", "permission", "access", "boundary"})
    if categories & {"frontend", "browser", "ux"}:
        tokens.update({"frontend", "browser", "ux", "accessibility", "journey", "operator", "runtime"})
    if categories & {"docs", "contract", "openapi", "spec"}:
        tokens.update({"docs", "contract", "api", "openapi", "spec", "manual", "synthesis"})
    if categories & {"connector", "integration"}:
        tokens.update({"connector", "integration", "runtime", "external"})
    if categories & {"test", "coverage"}:
        tokens.update({"test", "coverage"})
    if not tokens:
        tokens.update(categories)
    return tokens


def select_jobs(jobs: list[Job], paths: list[str]) -> tuple[list[Job], list[str]]:
    categories: set[str] = set()
    for path in paths:
        categories.update(path_categories(path))
    tokens = tokens_for_categories(categories)
    selected: list[Job] = []
    for job in jobs:
        text = job.search_text
        always = job.kind in ALWAYS_SELECTED_KINDS or job.job_id in ALWAYS_SELECTED_JOB_IDS or job.group == "00"
        matched = any(token in text for token in tokens)
        if always or matched:
            selected.append(job)
    if not selected and jobs:
        selected = [job for job in jobs if job.kind in ALWAYS_SELECTED_KINDS or job.job_id in ALWAYS_SELECTED_JOB_IDS]
    return selected, sorted(tokens)


def write_jobs(path: Path, header: list[str], jobs: list[Job]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    columns = header or ["group", "job_id", "kind", "title", "output", "ref"]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, delimiter="\t", fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        for job in jobs:
            writer.writerow({
                "group": job.group,
                "job_id": job.job_id,
                "kind": job.kind,
                "title": job.title,
                "output": job.output,
                "ref": job.ref,
            })


def write_scope(
    run_dir: Path,
    baseline_sha: str,
    head_sha: str,
    paths: list[str],
    selected_jobs: list[Job],
    tokens: list[str],
) -> None:
    lines = [
        "# Differential Audit Scope",
        "",
        f"- Baseline SHA: `{baseline_sha}`",
        f"- Head SHA: `{head_sha}`",
        f"- Changed paths: {len(paths)}",
        f"- Selected jobs: {len(selected_jobs)}",
        f"- Selection tokens: {', '.join(tokens) if tokens else '(none)'}",
        "",
        "## Changed Paths",
        "",
    ]
    if paths:
        lines.extend(f"- `{path}`" for path in paths)
    else:
        lines.append("- (none)")
    lines.extend(
        [
            "",
            "## Selected Jobs",
            "",
        ]
    )
    lines.extend(f"- `{job.job_id}` ({job.kind}) - {job.title}" for job in selected_jobs)
    lines.extend(
        [
            "",
            "## Required Differential Enumeration",
            "",
            "Every selected job must enumerate changed endpoints, routes, permissions, state transitions, docs, and tests that fall inside its scope.",
            "If a category is not touched, say so explicitly with the changed-path evidence instead of inferring coverage.",
        ]
    )
    (run_dir / "artifacts" / "differential-scope.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root)
    run_dir = Path(args.run_dir)
    baseline_sha = load_baseline(Path(args.register_dir), args.baseline_sha)
    head_sha, paths = changed_paths(repo_root, baseline_sha, args.include_worktree)
    header, jobs = read_jobs(Path(args.jobs_file))
    selected_jobs, tokens = select_jobs(jobs, paths)
    write_jobs(Path(args.out_jobs_file), header, selected_jobs)
    write_scope(run_dir, baseline_sha, head_sha, paths, selected_jobs, tokens)
    print(f"[differential] baseline={baseline_sha} head={head_sha} changed_paths={len(paths)} selected_jobs={len(selected_jobs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
