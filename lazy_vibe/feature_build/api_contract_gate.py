from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


API_SURFACE_PREFIXES = (
    "backend/routers/",
    "backend/schemas/",
    "backend/main.py",
    "backend/app.py",
    "frontend/src/services/api",
)
CONTRACT_DOC_PREFIXES = (
    "docs/api/",
    "docs/openapi",
    "docs/architecture/",
    "docs/functional/",
    "docs/manual/",
)
OPENAPI_FILENAMES = {
    "openapi.json",
    "openapi.yaml",
    "openapi.yml",
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate API contract documentation and OpenAPI generation for feature builds."
    )
    parser.add_argument("--repo", default=".", help="Repository root.")
    parser.add_argument(
        "--task-file",
        action="append",
        default=[],
        help="Expected file from the task plan. May be supplied multiple times.",
    )
    parser.add_argument(
        "--mode",
        choices=("task", "final"),
        default="final",
        help="Task mode checks supplied task files; final mode checks git diff against HEAD.",
    )
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    changed = relevant_paths(repo, args.mode, args.task_file)
    api_paths = [path for path in changed if is_api_surface(path)]
    if not api_paths:
        print("api-contract-gate: no API surface changes detected")
        return 0

    docs_paths = [path for path in changed if is_contract_doc(path)]
    if not docs_paths:
        print(
            "api-contract-gate: API surface changed without contract documentation updates.",
            file=sys.stderr,
        )
        print("Changed API files:", file=sys.stderr)
        for path in api_paths:
            print(f"  - {path}", file=sys.stderr)
        print(
            "Expected at least one docs/api, docs/openapi, docs/architecture, "
            "docs/functional, or docs/manual update covering endpoints, schemas, "
            "permissions, errors, audit events, lifecycle/state transitions, and examples.",
            file=sys.stderr,
        )
        return 1

    openapi_status = validate_fastapi_openapi(repo)
    if openapi_status != 0:
        return openapi_status

    print("api-contract-gate: API docs touched and OpenAPI generation validated")
    return 0


def relevant_paths(repo: Path, mode: str, task_files: list[str]) -> list[str]:
    if mode == "task":
        return normalize_paths(task_files)
    return normalize_paths(git_changed_paths(repo))


def normalize_paths(paths: list[str]) -> list[str]:
    normalized: list[str] = []
    for raw in paths:
        path = raw.strip().lstrip("./")
        if path and path not in normalized:
            normalized.append(path)
    return normalized


def git_changed_paths(repo: Path) -> list[str]:
    diff_result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=ACMRT", "HEAD"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if diff_result.returncode != 0:
        print(
            "api-contract-gate: unable to inspect git diff; skipping final diff-based contract check",
            file=sys.stderr,
        )
        return []
    others_result = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    paths = diff_result.stdout.splitlines()
    if others_result.returncode == 0:
        paths.extend(others_result.stdout.splitlines())
    return paths


def is_api_surface(path: str) -> bool:
    return path in API_SURFACE_PREFIXES or any(path.startswith(prefix) for prefix in API_SURFACE_PREFIXES)


def is_contract_doc(path: str) -> bool:
    if Path(path).name in OPENAPI_FILENAMES:
        return True
    return any(path.startswith(prefix) for prefix in CONTRACT_DOC_PREFIXES)


def validate_fastapi_openapi(repo: Path) -> int:
    backend = repo / "backend"
    if not backend.is_dir():
        return 0
    app_file = backend / "main.py"
    if not app_file.exists():
        app_file = backend / "app.py"
    if not app_file.exists() or "FastAPI" not in app_file.read_text(encoding="utf-8", errors="replace"):
        return 0

    code = (
        "import json\n"
        "from main import app\n"
        "schema = app.openapi()\n"
        "assert schema.get('openapi'), 'missing openapi version'\n"
        "assert isinstance(schema.get('paths'), dict) and schema['paths'], 'missing paths'\n"
        "print(json.dumps({'paths': len(schema['paths'])}, sort_keys=True))\n"
    )
    env = os.environ.copy()
    env.setdefault("DEBUG", "true")
    env["PYTHONPATH"] = "."
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=backend,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        print("api-contract-gate: FastAPI OpenAPI generation failed", file=sys.stderr)
        if result.stdout:
            print(result.stdout[-4000:], file=sys.stderr)
        if result.stderr:
            print(result.stderr[-4000:], file=sys.stderr)
        return result.returncode
    payload = json.loads(result.stdout.strip())
    print(f"api-contract-gate: generated FastAPI OpenAPI schema paths={payload['paths']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
