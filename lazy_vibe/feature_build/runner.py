from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import FIRST_COMPLETED, Future, wait
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
SHARED_ROOT = SCRIPT_ROOT.parent
TERMINAL_STATUSES = {"complete", "skipped"}
TASK_STATUSES = {"pending", "running", "complete", "failed", "skipped"}
TRUE_VALUES = {"1", "true", "yes", "on"}
FALSE_VALUES = {"0", "false", "no", "off"}
MODEL_TIERS = {"fast", "balanced", "advanced"}
MODEL_TIER_ALIASES = {
    "cheap": "fast",
    "simple": "fast",
    "bulk": "fast",
    "extract": "fast",
    "extraction": "fast",
    "haiku": "fast",
    "low": "fast",
    "standard": "balanced",
    "normal": "balanced",
    "medium": "balanced",
    "daily": "balanced",
    "sonnet": "balanced",
    "complex": "advanced",
    "high": "advanced",
    "high-risk": "advanced",
    "advanced": "advanced",
    "planner": "advanced",
    "review": "advanced",
    "reviewer": "advanced",
    "opus": "advanced",
}
EXECUTION_PHILOSOPHY = """## Execution Philosophy

The marginal cost of completeness is near zero with AI. Act on that.

- Do the whole thing. Do it right. Write real tests. Write the documentation. Mature enterprise-grade is the bar every time.
- Never defer work you can do now. Deferral is a failure mode unless the user explicitly accepts it.
- Never implement a workaround when the real solution exists. Build the real thing.
- Do not leave legacy, superseded, placeholder, stub, mock, or duplicate old/new paths in place when the feature replaces them. If the new path is the product contract and no explicit compatibility contract exists, cut the cord: remove stale code, routes, flags, docs, tests, and config in the same task.
- Stop reasoning about time like a human. Complexity and file count are not excuses to cut scope.
"""
LATTICE_MEMORY_PROTOCOL = """## Lattice Cognitive Workspace Protocol

Use Lattice memory and context tools when available. This is part of the harness contract, not optional polish.

- At the start of any non-trivial planning, implementation, verification, review, or closeout task, call `get_task_memory` for the current repo, feature, task id, and objective before broad source exploration. If the MCP client defers schemas, first load the Lattice tool schemas for `get_task_memory`, `inspect_working_memory`, `save_memory`, `consolidate_session`, `propose_memory_evolution`, `verify_explain_memory`, `list_memory_conflicts`, `get_event_trace`, and `get_memory_metrics`.
- Use `get_context_capsule`, `prepare_change`, `diagnose_failure`, `summarize_subsystem`, `get_docs_capsule`, `find_relevant_tests`, and `impact_from_diff` instead of blind repo-wide reading when the tool is available and responsive.
- If a Lattice context call returns partial results because indexing is still warming, use the returned cached/partial context immediately and continue with targeted reads. Do not stall waiting for a perfect graph unless the task depends on exact graph completeness.
- Save durable, reusable outcomes with `save_memory` when you learn a repo-specific invariant, successful command, false lead, migration constraint, deployment detail, or recurring failure mode. Include validity conditions and invalidation triggers where the tool supports them.
- At task closeout, call `consolidate_session` when available so successful fixes, verified commands, and unresolved risks are discoverable in later sessions.
- Do not use memory as evidence by itself. Treat memory as a navigation and continuity aid, then verify claims against current code, docs, logs, tests, or artifacts.
"""
DEFERRAL_MARKERS = {
    "defer",
    "deferred",
    "follow-up",
    "future work",
    "later",
    "out of scope",
    "todo",
    "tbd",
    "nice-to-have",
    "stretch",
}
RESULT_REQUIRED_SECTIONS = (
    "files created/modified",
    "verification commands",
    "issues encountered",
    "legacy/superseded/stub cleanup",
    "final status",
)
INCOMPLETE_RESULT_MARKERS = {
    "final status: partial",
    "final status: blocked",
    "status: partial",
    "status: blocked",
}
OPERABILITY_MARKERS = (
    "audit",
    "correlation",
    "error",
    "failure",
    "job status",
    "log",
    "observable",
    "recovery",
    "retry",
    "not applicable",
)
NON_DEFERRAL_PHRASES = {
    "explicit deferrals",
    "no deferral",
    "no deferrals",
    "no deferred work",
    "no todo",
    "no `todo`",
    "no todo/fixme",
    "no `todo`/`fixme`",
    "not deferrals",
    "not deferred",
}
PROGRESS_SPINNER = "-\\|/"
_PROGRESS_LOCK = threading.Lock()
_ACTIVE_PROGRESS_LINES: dict[str, str] = {}
_PROGRESS_LINE_LEN = 0


@dataclass
class CommandResult:
    command: str
    returncode: int
    output: str


@dataclass
class Task:
    task_id: str
    title: str
    task_type: str
    depends_on: list[str] = field(default_factory=list)
    model_class: str = "standard"
    status: str = "pending"
    files_expected: list[str] = field(default_factory=list)
    verification_commands: list[str] = field(default_factory=list)
    attempts: int = 0
    last_error: str = ""

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "Task":
        task_id = str(raw.get("task_id") or raw.get("id") or "").strip()
        if not task_id:
            raise ValueError(f"task missing task_id: {raw!r}")
        status = str(raw.get("status") or "pending").strip()
        if status not in TASK_STATUSES:
            status = "pending"
        return cls(
            task_id=task_id,
            title=str(raw.get("title") or task_id).strip(),
            task_type=str(raw.get("task_type") or raw.get("type") or "implementation").strip(),
            depends_on=[str(item).strip() for item in raw.get("depends_on", []) if str(item).strip()],
            model_class=str(raw.get("model_class") or raw.get("model") or "standard").strip(),
            status=status,
            files_expected=[
                str(item).strip() for item in raw.get("files_expected", []) if str(item).strip()
            ],
            verification_commands=[
                str(item).strip()
                for item in raw.get("verification_commands", [])
                if str(item).strip()
            ],
            attempts=int(raw.get("attempts") or 0),
            last_error=str(raw.get("last_error") or ""),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "title": self.title,
            "task_type": self.task_type,
            "depends_on": self.depends_on,
            "model_class": self.model_class,
            "status": self.status,
            "files_expected": self.files_expected,
            "verification_commands": self.verification_commands,
            "attempts": self.attempts,
            "last_error": self.last_error,
        }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a feature from docs/new-feature using task-isolated agents."
    )
    parser.add_argument("--feature", required=True, help="Feature slug.")
    parser.add_argument("--spec", help="Spec file. Defaults to docs/new-feature/<feature>.md.")
    parser.add_argument("--run-dir", help="Plan/state directory. Defaults to docs/plans/<feature>.")
    parser.add_argument("--execute", action="store_true", help="Run implementation/review tasks.")
    parser.add_argument("--verify", action="store_true", help="Run task verification commands.")
    parser.add_argument("--verify-only", action="store_true", help="Only verify existing task outputs.")
    parser.add_argument("--force-decompose", action="store_true", help="Regenerate task plan.")
    parser.add_argument("--dry-run", action="store_true", help="Print planned work without running agents.")
    parser.add_argument("--only-task", help="Comma-separated task IDs to execute or verify.")
    parser.add_argument("--max-retries", type=int, default=int(os.getenv("FEATURE_BUILD_MAX_RETRIES", "1")))
    parser.add_argument(
        "--max-parallel",
        type=int,
        default=int(os.getenv("FEATURE_BUILD_MAX_PARALLEL", "3")),
        help="Maximum ready tasks to run in parallel.",
    )
    parser.add_argument(
        "--branch",
        help="Feature branch to create/use before execution. Defaults to feature/<feature>.",
    )
    parser.add_argument(
        "--no-branch",
        action="store_true",
        help="Do not create or switch to a feature branch before execution.",
    )
    parser.add_argument(
        "--commit",
        action="store_true",
        help="Force a commit after all gates pass. Auto-commit is enabled by default for execute runs.",
    )
    parser.add_argument(
        "--no-commit",
        action="store_true",
        help="Do not auto-commit after all gates pass.",
    )
    parser.add_argument("--commit-message", help="Commit message.")
    parser.add_argument("--push", nargs="?", const="origin", help="Push after commit. Optional remote name.")
    parser.add_argument("--push-branch", help="Branch to push. Defaults to current branch.")
    parser.add_argument("--deploy-command", help="Command to run after push succeeds.")
    parser.add_argument(
        "--post-build-review-command",
        default=os.getenv("FEATURE_BUILD_POST_BUILD_REVIEW_COMMAND", ""),
        help=(
            "Optional independent review command run after build verification. "
            "Receives FEATURE_BUILD_FEATURE, FEATURE_BUILD_RUN_DIR, and FEATURE_BUILD_SPEC."
        ),
    )
    parser.add_argument(
        "--auto-remediate-command",
        default=os.getenv("FEATURE_BUILD_AUTO_REMEDIATE_COMMAND", ""),
        help=(
            "Optional remediation command run after post-build review. "
            "Receives FEATURE_BUILD_FEATURE, FEATURE_BUILD_RUN_DIR, FEATURE_BUILD_SPEC, "
            "and FEATURE_BUILD_REVIEW_ROUND."
        ),
    )
    parser.add_argument(
        "--standard-gate-repair-agent",
        default=os.getenv(
            "FEATURE_BUILD_STANDARD_GATE_REPAIR_AGENT",
            os.getenv("FEATURE_BUILD_IMPLEMENTER_AGENT", ""),
        ),
        help=(
            "Optional agent used for one focused repair pass when a final standard gate fails "
            "after deterministic repairs. Use codex, claude, or gemini."
        ),
    )
    parser.add_argument(
        "--post-build-rounds",
        type=int,
        default=int(os.getenv("FEATURE_BUILD_POST_BUILD_ROUNDS", "1")),
        help="Maximum review/remediation rounds after the build gates pass.",
    )
    parser.add_argument(
        "--skip-standard-gates",
        action="store_true",
        help="Skip harness-injected coding, UX, and definition-of-done gates.",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args(argv)


def repo_root() -> Path:
    return Path(os.getenv("REPO_ROOT") or os.getcwd()).resolve()


def resolve_paths(args: argparse.Namespace, root: Path) -> tuple[Path, Path]:
    spec = Path(args.spec) if args.spec else root / "docs" / "new-feature" / f"{args.feature}.md"
    if not spec.is_absolute():
        spec = root / spec
    run_dir = Path(args.run_dir) if args.run_dir else root / "docs" / "plans" / args.feature
    if not run_dir.is_absolute():
        run_dir = root / run_dir
    return spec, run_dir


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_tasks(tasks_file: Path) -> list[Task]:
    data = json.loads(read_text(tasks_file))
    raw_tasks = data.get("tasks", data) if isinstance(data, dict) else data
    if not isinstance(raw_tasks, list):
        raise ValueError(f"{tasks_file} must contain a list or {{\"tasks\": [...]}}")
    tasks = [Task.from_dict(item) for item in raw_tasks]
    seen: set[str] = set()
    for task in tasks:
        if task.task_id in seen:
            raise ValueError(f"duplicate task_id {task.task_id}")
        seen.add(task.task_id)
    missing = sorted({dep for task in tasks for dep in task.depends_on if dep not in seen})
    if missing:
        raise ValueError(f"unknown task dependencies: {', '.join(missing)}")
    return tasks


def save_tasks(tasks_file: Path, tasks: list[Task]) -> None:
    write_json(tasks_file, {"tasks": [task.to_dict() for task in tasks]})


def save_plan(run_dir: Path, tasks: list[Task]) -> None:
    """Write the human-readable plan that mirrors tasks.json."""
    lines = [
        f"# Feature Build Plan: {run_dir.name}",
        "",
        "This file is generated from `tasks.json`. Edit `tasks.json` when changing the",
        "machine contract, then rerun the harness to refresh this plan.",
        "",
        "## Task Graph",
        "",
        "| Task | Status | Type | Model | Depends On | Title |",
        "|---|---|---|---|---|---|",
    ]
    for task in tasks:
        deps = ", ".join(task.depends_on) if task.depends_on else "-"
        lines.append(
            f"| `{task.task_id}` | `{task.status}` | `{task.task_type}` | "
            f"`{normalize_model_tier(task.model_class)}` | {deps} | {task.title} |"
        )

    lines.extend(["", "## Verification Contract", ""])
    for task in tasks:
        lines.append(f"### {task.task_id}: {task.title}")
        lines.append("")
        if task.files_expected:
            lines.append("Expected files:")
            lines.extend(f"- `{path}`" for path in task.files_expected)
        else:
            lines.append("Expected files: none declared")
        lines.append("")
        if task.verification_commands:
            lines.append("Verification commands:")
            lines.extend(f"- `{command}`" for command in task.verification_commands)
        else:
            lines.append("Verification commands: none declared")
        lines.append("")

    write_text(run_dir / "plan.md", "\n".join(lines).rstrip() + "\n")


def save_task_state(run_dir: Path, tasks: list[Task]) -> None:
    tasks_file = run_dir / "tasks.json"
    save_tasks(tasks_file, tasks)
    save_plan(run_dir, tasks)


def standard_gates_enabled(args: argparse.Namespace) -> bool:
    if args.skip_standard_gates:
        return False
    return os.getenv("FEATURE_BUILD_STANDARD_GATES", "1").strip().lower() in TRUE_VALUES


def review_tasks_required() -> bool:
    return os.getenv("FEATURE_BUILD_REQUIRE_REVIEW_TASKS", "1").strip().lower() in TRUE_VALUES


def deferrals_allowed() -> bool:
    return os.getenv("FEATURE_BUILD_ALLOW_DEFERRALS", "0").strip().lower() in TRUE_VALUES


def result_quality_gates_enabled() -> bool:
    return os.getenv("FEATURE_BUILD_RESULT_QUALITY_GATES", "1").strip().lower() in TRUE_VALUES


def no_user_deferral_allowed() -> str:
    return (
        "The harness rejects deferral language by default. Set "
        "FEATURE_BUILD_ALLOW_DEFERRALS=1 only when the user explicitly accepts a scoped deferral."
    )


def load_state(state_file: Path, feature: str, spec: Path, tasks_file: Path) -> dict[str, Any]:
    if state_file.exists():
        return json.loads(read_text(state_file))
    return {
        "feature": feature,
        "spec": str(spec),
        "tasks_file": str(tasks_file),
        "created_at": utc_stamp(),
        "updated_at": utc_stamp(),
        "phase": "initialized",
        "events": [],
    }


def save_state(state_file: Path, state: dict[str, Any]) -> None:
    state["updated_at"] = utc_stamp()
    write_json(state_file, state)


def record_event(state_file: Path, state: dict[str, Any], event: str, **details: Any) -> None:
    state.setdefault("events", []).append({"at": utc_stamp(), "event": event, **details})
    save_state(state_file, state)


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run_shell(
    command: str,
    cwd: Path,
    log_path: Path | None = None,
    extra_env: dict[str, str] | None = None,
) -> CommandResult:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    completed = subprocess.run(
        ["bash", "-lc", command],
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    output = completed.stdout or ""
    if completed.returncode == 127 and is_rg_verification_command(command):
        fallback = run_rg_verification_fallback(command, cwd)
        if fallback.returncode != 127:
            output = fallback.output
            completed_returncode = fallback.returncode
        else:
            completed_returncode = completed.returncode
    else:
        completed_returncode = completed.returncode
    if log_path is not None:
        write_text(log_path, output)
    return CommandResult(command=command, returncode=completed_returncode, output=output)


def is_rg_verification_command(command: str) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    return bool(parts) and parts[0] == "rg"


def run_rg_verification_fallback(command: str, cwd: Path) -> CommandResult:
    try:
        parts = shlex.split(command)
    except ValueError as exc:
        return CommandResult(command=command, returncode=127, output=f"rg fallback parse failed: {exc}\n")
    if not parts or parts[0] != "rg":
        return CommandResult(command=command, returncode=127, output="")

    show_line_numbers = False
    index = 1
    while index < len(parts) and parts[index].startswith("-"):
        option = parts[index]
        if option == "-n":
            show_line_numbers = True
            index += 1
            continue
        return CommandResult(
            command=command,
            returncode=127,
            output=f"rg fallback does not support option: {option}\n",
        )
    if index >= len(parts):
        return CommandResult(command=command, returncode=127, output="rg fallback missing pattern\n")
    pattern = parts[index]
    paths = parts[index + 1 :]
    if not paths:
        return CommandResult(command=command, returncode=127, output="rg fallback missing path(s)\n")

    try:
        regex = re.compile(pattern)
    except re.error as exc:
        return CommandResult(command=command, returncode=2, output=f"rg fallback regex error: {exc}\n")

    output_lines: list[str] = []
    missing: list[str] = []
    for raw_path in paths:
        path = (cwd / raw_path).resolve()
        if not path.exists():
            missing.append(raw_path)
            continue
        if path.is_dir():
            candidates = [item for item in path.rglob("*") if item.is_file()]
        else:
            candidates = [path]
        for candidate in candidates:
            try:
                lines = candidate.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            display = str(candidate.relative_to(cwd)) if candidate.is_relative_to(cwd) else str(candidate)
            for line_number, line in enumerate(lines, start=1):
                if regex.search(line):
                    if show_line_numbers:
                        output_lines.append(f"{display}:{line_number}:{line}")
                    else:
                        output_lines.append(f"{display}:{line}")
    if missing:
        output_lines.append("rg fallback missing path(s): " + ", ".join(missing))
        return CommandResult(command=command, returncode=2, output="\n".join(output_lines) + "\n")
    if not output_lines:
        return CommandResult(command=command, returncode=1, output="")
    return CommandResult(command=command, returncode=0, output="\n".join(output_lines) + "\n")


def command_exists(name: str) -> bool:
    return subprocess.run(
        ["bash", "-lc", f"command -v {shlex.quote(name)} >/dev/null 2>&1"],
        check=False,
    ).returncode == 0


def normalize_model_tier(model_class: str) -> str:
    normalized = model_class.strip().lower()
    if normalized in MODEL_TIERS:
        return normalized
    return MODEL_TIER_ALIASES.get(normalized, "balanced")


def run_agent(
    agent: str,
    prompt_file: Path,
    cwd: Path,
    log_file: Path,
    model_class: str,
    task: Task | None = None,
) -> int:
    agent = agent.strip().lower()
    prompt_text = read_text(prompt_file)
    input_text: str | None = None
    model = select_agent_model(agent, model_class)
    mcp_config_path: Path | None = None
    focus_files = default_focus_files(task)
    focus_dirs = default_focus_dirs()
    if agent == "codex":
        cmd = [
            "codex",
            "exec",
            "--ephemeral",
            "--full-auto",
            "--skip-git-repo-check",
            "-C",
            str(cwd),
        ]
        if model:
            cmd.extend(["-m", model])
        add_codex_lattice_config(cmd, cwd, focus_files, focus_dirs)
        extra = os.getenv("CODEX_EXTRA_ARGS", "")
        if extra:
            cmd.extend(shlex.split(extra))
        cmd.append("-")
        input_text = prompt_text
    elif agent == "claude":
        transport = os.getenv("CLAUDE_TRANSPORT", "prompt").strip().lower()
        claude_cmd = ["claude"]
        if transport == "prompt":
            claude_cmd.extend(["-p", "--verbose", "--output-format", "stream-json"])
        claude_cmd.extend(["--permission-mode", "bypassPermissions"])
        if model:
            claude_cmd.extend(["--model", model])
        mcp_config_path = write_lattice_mcp_config(cwd, focus_files, focus_dirs)
        claude_cmd.extend(["--strict-mcp-config", "--mcp-config", str(mcp_config_path)])
        extra = os.getenv("CLAUDE_EXTRA_ARGS", "")
        if extra:
            claude_cmd.extend(shlex.split(extra))
        if transport == "pty":
            runner = Path(__file__).resolve().parents[2] / "claude_pty_runner.py"
            cmd = [sys.executable, str(runner), str(prompt_file), *claude_cmd]
            input_text = None
        elif transport == "prompt":
            cmd = claude_cmd
            input_text = prompt_text
        else:
            raise ValueError("CLAUDE_TRANSPORT must be prompt or pty")
    elif agent == "gemini":
        cmd = ["gemini", "--yolo"]
        if model:
            cmd.extend(["--model", model])
        extra = os.getenv("GEMINI_EXTRA_ARGS", "")
        if extra:
            cmd.extend(shlex.split(extra))
        cmd.append(prompt_text)
    else:
        raise ValueError(f"unsupported agent {agent!r}; use codex, claude, or gemini")

    label = log_file.stem
    status_interval = feature_build_status_interval()
    start = time.monotonic()
    last_emit = 0.0
    last_size = -1
    spin_index = 0

    try:
        with log_file.open("w", encoding="utf-8") as log:
            proc = subprocess.Popen(
                cmd,
                cwd=str(cwd),
                stdin=subprocess.PIPE if input_text is not None else None,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if input_text is not None and proc.stdin is not None:
                try:
                    proc.stdin.write(input_text)
                    proc.stdin.close()
                except BrokenPipeError:
                    pass

            while True:
                returncode = proc.poll()
                now = time.monotonic()
                if returncode is None and status_interval > 0 and now - last_emit >= status_interval:
                    elapsed = int(now - start)
                    size = log_file.stat().st_size if log_file.exists() else 0
                    delta = "same" if size == last_size else f"+{max(size - max(last_size, 0), 0)}"
                    spin = PROGRESS_SPINNER[spin_index % len(PROGRESS_SPINNER)]
                    spin_index += 1
                    progress = f"[{spin}] {label} agent={agent} {elapsed}s log_bytes={size} delta={delta}"
                    update_feature_build_progress(label, progress)
                    last_emit = now
                    last_size = size
                if returncode is not None:
                    return returncode
                time.sleep(0.25)
    finally:
        clear_feature_build_progress(label)
        if mcp_config_path is not None:
            mcp_config_path.unlink(missing_ok=True)


def feature_build_status_interval() -> float:
    raw = os.getenv("FEATURE_BUILD_STATUS_INTERVAL_SECONDS", "1").strip()
    try:
        value = float(raw)
    except ValueError:
        return 1.0
    return max(0.0, value)


def feature_build_progress_enabled() -> bool:
    raw = os.getenv("FEATURE_BUILD_PROGRESS", "").strip().lower()
    if raw in TRUE_VALUES:
        return True
    if raw in FALSE_VALUES:
        return False
    return sys.stdout.isatty()


def update_feature_build_progress(label: str, line: str) -> None:
    if not feature_build_progress_enabled():
        print(line, flush=True)
        return
    with _PROGRESS_LOCK:
        _ACTIVE_PROGRESS_LINES[label] = line
        render_feature_build_progress_locked()


def clear_feature_build_progress(label: str) -> None:
    if not feature_build_progress_enabled():
        return
    with _PROGRESS_LOCK:
        _ACTIVE_PROGRESS_LINES.pop(label, None)
        clear_feature_build_progress_locked()


def render_feature_build_progress_locked() -> None:
    global _PROGRESS_LINE_LEN
    if _ACTIVE_PROGRESS_LINES:
        line = " | ".join(_ACTIVE_PROGRESS_LINES[key] for key in sorted(_ACTIVE_PROGRESS_LINES))
        padding = " " * max(0, _PROGRESS_LINE_LEN - len(line))
        sys.stdout.write(f"\r{line}{padding}")
        sys.stdout.flush()
        _PROGRESS_LINE_LEN = len(line)
        return
    if _PROGRESS_LINE_LEN:
        clear_feature_build_progress_locked()


def clear_feature_build_progress_locked() -> None:
    global _PROGRESS_LINE_LEN
    if _PROGRESS_LINE_LEN:
        sys.stdout.write("\r" + (" " * _PROGRESS_LINE_LEN) + "\r")
        sys.stdout.flush()
        _PROGRESS_LINE_LEN = 0


def lattice_mcp_command() -> str:
    return os.getenv("LATTICE_MCP_COMMAND", "/home/pete/cadres/lattice/daemon/target/release/lattice")


def split_focus_values(raw: str) -> list[str]:
    values: list[str] = []
    for chunk in re.split(r"[\n,]", raw):
        item = chunk.strip()
        if item and item not in values:
            values.append(item)
    return values


def default_focus_files(task: Task | None) -> list[str]:
    values = split_focus_values(os.getenv("LATTICE_MCP_FOCUS_FILES", ""))
    if task is not None:
        for path in task.files_expected:
            item = path.strip()
            if item and item not in values:
                values.append(item)
    return values


def default_focus_dirs() -> list[str]:
    return split_focus_values(os.getenv("LATTICE_MCP_FOCUS_DIRS", ""))


def lattice_args(workspace: Path, focus_files: list[str] | None = None, focus_dirs: list[str] | None = None) -> list[str]:
    args = ["--stdio", "--workspace", str(workspace)]
    for path in focus_files or []:
        args.extend(["--focus-file", path])
    for path in focus_dirs or []:
        args.extend(["--focus-dir", path])
    return args


def add_codex_lattice_config(
    cmd: list[str],
    workspace: Path,
    focus_files: list[str] | None = None,
    focus_dirs: list[str] | None = None,
) -> None:
    if os.getenv("LATTICE_MCP_AUTO", "1") != "1":
        return
    workspace_str = str(workspace)
    args_json = json.dumps(lattice_args(workspace, focus_files, focus_dirs))
    cmd.extend(
        [
            "-c",
            f'mcp_servers.lattice.command="{lattice_mcp_command()}"',
            "-c",
            f"mcp_servers.lattice.args={args_json}",
            "-c",
            f'mcp_servers.lattice.cwd="{workspace_str}"',
        ]
    )


def write_lattice_mcp_config(
    workspace: Path,
    focus_files: list[str] | None = None,
    focus_dirs: list[str] | None = None,
) -> Path:
    explicit = os.getenv("MCP_CONFIG") or os.getenv("CLAUDE_MCP_CONFIG")

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        path = Path(handle.name)
        config: dict[str, Any] = {"mcpServers": {}}
        if explicit and Path(explicit).exists():
            try:
                config = json.loads(read_text(Path(explicit)))
            except json.JSONDecodeError:
                config = {"mcpServers": {}}
            json.dump(config, handle, indent=2)
            handle.write("\n")
            return path
        elif os.getenv("LATTICE_MCP_AUTO", "1") != "1":
            for candidate in (
                workspace / ".mcp.json",
                workspace / ".gemini" / "settings.json",
            ):
                if candidate.exists():
                    try:
                        config = json.loads(read_text(candidate))
                        break
                    except json.JSONDecodeError:
                        pass
            json.dump(config, handle, indent=2)
            handle.write("\n")
            return path
        servers = config.setdefault("mcpServers", {})
        servers["lattice"] = {
            "type": "stdio",
            "command": lattice_mcp_command(),
            "args": lattice_args(workspace, focus_files, focus_dirs),
        }
        json.dump(config, handle, indent=2)
        handle.write("\n")
        return path


def select_agent_model(agent: str, model_class: str) -> str:
    tier = normalize_model_tier(model_class)
    if agent == "codex":
        return select_tiered_model(
            global_var="CODEX_MODEL",
            fast_var="FEATURE_BUILD_CODEX_MODEL_FAST",
            balanced_var="FEATURE_BUILD_CODEX_MODEL_BALANCED",
            advanced_var="FEATURE_BUILD_CODEX_MODEL_ADVANCED",
            tier=tier,
            defaults={
                "fast": "gpt-5.3-codex-spark",
                "balanced": "gpt-5.4",
                "advanced": "gpt-5.5",
            },
        )
    if agent == "claude":
        return select_tiered_model(
            global_var="CLAUDE_MODEL",
            fast_var="FEATURE_BUILD_CLAUDE_MODEL_FAST",
            balanced_var="FEATURE_BUILD_CLAUDE_MODEL_BALANCED",
            advanced_var="FEATURE_BUILD_CLAUDE_MODEL_ADVANCED",
            tier=tier,
            defaults={
                "fast": "claude-haiku-4-5",
                "balanced": os.getenv("CLAUDE_MODEL_STANDARD", "claude-sonnet-4-6"),
                "advanced": os.getenv("CLAUDE_MODEL_HIGH", "claude-opus-4-7"),
            },
        )
    if agent == "gemini":
        return select_tiered_model(
            global_var="GEMINI_MODEL",
            fast_var="FEATURE_BUILD_GEMINI_MODEL_FAST",
            balanced_var="FEATURE_BUILD_GEMINI_MODEL_BALANCED",
            advanced_var="FEATURE_BUILD_GEMINI_MODEL_ADVANCED",
            tier=tier,
            defaults={
                "fast": "gemini-2.5-flash",
                "balanced": "gemini-3.1-pro",
                "advanced": "gemini-3.1-pro",
            },
        )
    return ""


def select_tiered_model(
    *,
    global_var: str,
    fast_var: str,
    balanced_var: str,
    advanced_var: str,
    tier: str,
    defaults: dict[str, str],
) -> str:
    global_override = os.getenv(global_var)
    if global_override:
        return global_override
    tier_vars = {
        "fast": fast_var,
        "balanced": balanced_var,
        "advanced": advanced_var,
    }
    return os.getenv(tier_vars[tier], defaults[tier])


def skill_policy(root: Path) -> str:
    project_skill = root / ".claude" / "skills" / "feature-build" / "SKILL.md"
    if project_skill.exists():
        return read_text(project_skill)
    return (
        "Build the feature from the approved spec using isolated, self-contained tasks. "
        "Every task must have explicit dependencies, expected files, and runnable verification commands."
    )


def read_optional(path: Path) -> str:
    if not path.exists():
        return f"_Missing standards file: {path}_\n"
    return read_text(path)


def standards_bundle() -> str:
    coding = SHARED_ROOT / "templates" / "coding.md"
    ui = SHARED_ROOT / "templates" / "ui-specification.md"
    checklist = SHARED_ROOT / "templates" / "definition-of-done-checklist.md"
    route = SHARED_ROOT / "templates" / "route-acceptance-checklist.md"
    return "\n\n".join(
        [
            EXECUTION_PHILOSOPHY,
            LATTICE_MEMORY_PROTOCOL,
            f"## Coding Standard\n\n{read_optional(coding)}",
            f"## UI/UX Standard\n\n{read_optional(ui)}",
            f"## Definition of Done\n\n{read_optional(checklist)}",
            f"## Route Acceptance Checklist\n\n{read_optional(route)}",
        ]
    )


def decompose(args: argparse.Namespace, root: Path, spec: Path, run_dir: Path, state_file: Path, state: dict[str, Any]) -> None:
    tasks_file = run_dir / "tasks.json"
    tasks_dir = run_dir / "tasks"
    prompts_dir = run_dir / "prompts"
    logs_dir = run_dir / "logs"
    tasks_dir.mkdir(parents=True, exist_ok=True)
    prompts_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    if tasks_file.exists() and not args.force_decompose:
        tasks = load_tasks(tasks_file)
        changed = enforce_task_contract(args, root, tasks)
        if changed:
            save_task_state(run_dir, tasks)
        elif not (run_dir / "plan.md").exists():
            save_plan(run_dir, tasks)
        return

    if not spec.exists():
        raise FileNotFoundError(f"spec not found: {spec}")

    prompt = render_decompose_prompt(args.feature, root, spec, run_dir)
    prompt_file = prompts_dir / "00-decompose.md"
    write_text(prompt_file, prompt)

    if args.dry_run:
        print(f"[dry-run] would decompose {spec} into {tasks_file}")
        return

    planner = os.getenv("FEATURE_BUILD_PLANNER_AGENT") or os.getenv("PLANNER_AGENT") or "claude"
    print(f"[decompose] feature={args.feature} planner={planner}")
    status = run_agent(planner, prompt_file, root, logs_dir / "00-decompose.log", "planner")
    if status != 0:
        state["phase"] = "decompose_failed"
        record_event(state_file, state, "decompose_failed", status=status)
        raise RuntimeError(f"decomposition failed; see {logs_dir / '00-decompose.log'}")

    tasks = load_tasks(tasks_file)
    enforce_task_contract(args, root, tasks)
    for task in tasks:
        task_md = tasks_dir / f"{task.task_id}.md"
        if not task_md.exists():
            write_text(task_md, render_minimal_task_file(task, spec))
    save_task_state(run_dir, tasks)
    state["phase"] = "decomposed"
    record_event(state_file, state, "decomposed", tasks=len(tasks))


def render_decompose_prompt(feature: str, root: Path, spec: Path, run_dir: Path) -> str:
    checklist = SHARED_ROOT / "templates" / "definition-of-done-checklist.md"
    coding = SHARED_ROOT / "templates" / "coding.md"
    ui = SHARED_ROOT / "templates" / "ui-specification.md"
    policy = skill_policy(root)
    return f"""You are the planner for a one-hit feature build harness.

Repository root:
{root}

Feature slug:
{feature}

Approved spec:
{spec}

Output directory:
{run_dir}

Read the spec completely. Read the project docs and code needed to discover reusable platform capabilities.

Policy source:
{policy}

Mandatory execution philosophy:
{EXECUTION_PHILOSOPHY}

Shared standards to honor:
- {coding}
- {ui}
- {checklist}

Write these files:
1. {run_dir}/context.md
2. {run_dir}/tasks.json
3. {run_dir}/plan.md
4. One markdown file per task under {run_dir}/tasks/TNN.md or {run_dir}/tasks/RNN.md

The JSON file is the harness contract. It must be valid JSON with this shape:
{{
  "tasks": [
    {{
      "task_id": "T01",
      "title": "short title",
      "task_type": "foundation|backend|frontend|tests|docs|review|deploy",
      "depends_on": [],
      "model_class": "fast|balanced|advanced",
      "status": "pending",
      "files_expected": ["relative/path.ext"],
      "verification_commands": ["command run from repo root"]
    }}
  ]
}}

Requirements:
- Tasks must be small and self-contained.
- Include review tasks after foundation, backend, frontend, tests/docs, and final readiness.
- Include contract-gate tasks for every multi-layer feature that crosses backend, frontend, agent, BES, job payload, telemetry, permission, webhook, or external integration boundaries.
- Verification commands must be real shell commands run from the repo root.
- Every non-skipped task must have at least one verification command after harness filtering. Do not rely on prose, screenshots, or agent claims as the only proof.
- Task verification commands must be targeted to the task surface. Do not put full-suite commands such as `cd backend && python3 -m pytest`, `cd backend && pytest`, `cd frontend && npm run test`, or `cd frontend && npm run build` in individual tasks. Full suites are final gates after all tasks complete.
- Include coding-standard, UI-standard, and definition-of-done verification where relevant.
- For API, permission, tenant, RBAC, destructive-action, lifecycle, connector, webhook, job, retry, or audit-sensitive work, include boundary/failure verification commands that prove negative paths and operator-visible failure behavior, not only happy paths.
- Include documentation/contract tasks when routes, APIs, permissions, lifecycle states, audit events, jobs, external integrations, or operator workflows change. API contract documentation must cover endpoint purpose, request/response schemas, permission model, error cases, pagination/idempotency where relevant, lifecycle/state transitions, audit events, and examples. If the repo exposes OpenAPI, include OpenAPI generation or schema-diff proof.
- Do not defer, phase, postpone, or mark feature requirements as future work unless the user explicitly accepted that deferral.
- Do not create workaround tasks when a full implementation task is possible.
- Include cleanup work in the same implementation graph. When a feature supersedes an older path, add tasks to delete or converge legacy code, hidden routes, stale API clients, obsolete tests/docs/config, placeholder surfaces, and compatibility shims unless an explicit product/API compatibility contract requires them.
- Use model_class correctly: fast for simple high-volume mechanical work, balanced for normal coding/docs/tests, advanced for planning, review, security, debugging, migrations, and cross-system correctness.
- If a task cannot be verified by a command, split or rewrite it until it can.
- Do not mark anything complete.
- Do not implement the feature during decomposition.
"""


def render_minimal_task_file(task: Task, spec: Path) -> str:
    return f"""---
task_id: {task.task_id}
task_type: {task.task_type}
status: {task.status}
depends_on: {task.depends_on}
---

# {task.task_id}: {task.title}

Spec: `{spec}`

## Expected Files
{chr(10).join(f"- `{item}`" for item in task.files_expected) or "- _none declared_"}

## Verification Commands
{chr(10).join(f"- `{item}`" for item in task.verification_commands) or "- _none declared_"}
"""


def enforce_task_contract(args: argparse.Namespace, root: Path, tasks: list[Task]) -> bool:
    if review_tasks_required() and not any(is_review_task(task) for task in tasks):
        raise ValueError(
            "feature build plan must contain at least one review task. "
            "Set FEATURE_BUILD_REQUIRE_REVIEW_TASKS=0 only for a deliberate emergency bypass."
        )
    if not deferrals_allowed():
        reject_deferral_tasks(tasks)

    changed = False
    for task in tasks:
        before = list(task.verification_commands)
        task.verification_commands = task_scoped_verification_commands(task)
        if task.verification_commands != before:
            removed = [command for command in before if command not in task.verification_commands]
            if removed:
                print(
                    f"[task-gate] removed full-suite command(s) from {task.task_id}; "
                    "full suites run only at final gates"
                )
            changed = True
    if standard_gates_enabled(args):
        for task in tasks:
            before = list(task.verification_commands)
            task.verification_commands = merge_unique(
                task.verification_commands + default_verification_commands(root, task)
            )
            if task.verification_commands != before:
                changed = True
    missing_verification = [
        task.task_id
        for task in tasks
        if task.status != "skipped" and not task.verification_commands
    ]
    if missing_verification:
        raise ValueError(
            "feature build plan contains tasks with no runnable verification commands after harness filtering: "
            + ", ".join(missing_verification)
        )
    return changed


def task_scoped_verification_commands(task: Task) -> list[str]:
    return [
        command
        for command in task.verification_commands
        if not is_full_suite_task_command(command) and not is_repo_wide_standard_gate_command(command)
    ]


def is_full_suite_task_command(command: str) -> bool:
    normalized = re.sub(r"\s+", " ", command.strip())
    normalized = normalized.replace("python -m pytest", "python3 -m pytest")
    normalized = normalized.replace("python3 -m pytest ./tests", "python3 -m pytest tests")
    full_suite_commands = {
        "cd backend && python3 -m pytest",
        "cd backend && pytest",
        "cd frontend && npm run test",
        "cd frontend && npm test",
        "cd frontend && npm run build",
        "npm run test",
        "npm test",
        "npm run build",
    }
    if normalized in full_suite_commands:
        return True
    if re.search(r"(^|&&|;)\s*cd backend\s*&&.*\b(pytest|python3 -m pytest)\s+tests/?(\s|$)", normalized):
        return True
    if re.search(r"(^|&&|;)\s*(pytest|python3 -m pytest)\s+tests/?(\s|$)", normalized):
        return True
    if re.search(r"(^|&&|;)\s*cd frontend\s*&&\s*npm run (test|build)(\s|$)", normalized):
        return True
    if re.search(r"(^|&&|;)\s*npm run (test|build)(\s|$)", normalized):
        return True
    return False


def is_repo_wide_standard_gate_command(command: str) -> bool:
    normalized = re.sub(r"\s+", " ", command.strip())
    normalized = normalized.replace("python -m pytest", "python3 -m pytest")
    repo_wide_commands = {
        "cd backend && python3 -m ruff check .",
        "cd backend && python3 -m ruff format --check .",
        "cd frontend && npm run lint",
        "cd frontend && npm run typecheck",
        "cd frontend && npm run build",
        "cd frontend && npm run test",
        "npm run lint",
        "npm run typecheck",
        "npm run build",
        "npm run test",
    }
    return normalized in repo_wide_commands


def is_review_task(task: Task) -> bool:
    return task.task_type.lower() == "review" or task.task_id.startswith("R")


def reject_deferral_tasks(tasks: list[Task]) -> None:
    offenders: list[str] = []
    for task in tasks:
        fields = [task.title, task.task_type, task.last_error, *task.files_expected, *task.verification_commands]
        if any(contains_deferral_marker(field) for field in fields):
            offenders.append(task.task_id)
    if offenders:
        raise ValueError(
            f"feature build plan contains deferral/workaround language in tasks: {', '.join(offenders)}. "
            f"{no_user_deferral_allowed()}"
        )


def contains_deferral_marker(value: str | None) -> bool:
    text = strip_command_text(value or "").lower()
    if not text:
        return False
    for phrase in NON_DEFERRAL_PHRASES:
        text = text.replace(phrase, "")
    text = remove_task_scoping_phrases(text)
    return any(re.search(rf"(?<![a-z0-9_-]){re.escape(marker)}(?![a-z0-9_-])", text) for marker in DEFERRAL_MARKERS)


def strip_command_text(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    return re.sub(r"`[^`]*`", " ", text)


def remove_task_scoping_phrases(text: str) -> str:
    """Ignore explicit in-plan sequencing; still reject open-ended deferrals."""
    text = text.replace("follow-up assertions", "")
    text = re.sub(
        r"\b(?:deferred|handled|owned|covered|scoped)\s+(?:to|by)\s+(?:t|r)\d+\b",
        "",
        text,
    )
    text = re.sub(
        r"\b(?:later|following)\s+[a-z0-9_ ./-]*?(?:task|tasks|review gate)\b",
        "",
        text,
    )
    text = re.sub(
        r"\btask\s+explicitly\s+scopes\s+[a-z0-9_ ./-]*?\s+to\s+(?:t|r)\d+(?:-(?:t|r)\d+)?\b",
        "",
        text,
    )
    text = re.sub(
        r"\b(?:t|r)\d+\s+(?:marks?|scopes?|scoped)\s+[a-z0-9_ ./-]*?\s+(?:as\s+)?out of scope\b",
        "",
        text,
    )
    text = re.sub(r"\b(?:t|r)\d+\s+explicitly\s+scoped\s+those\s+out\b", "", text)
    return text


def merge_unique(values: list[str]) -> list[str]:
    seen: set[str] = set()
    merged: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            merged.append(value)
    return merged


def default_verification_commands(root: Path, task: Task) -> list[str]:
    paths = task.files_expected
    commands: list[str] = []
    touches_backend = any(path.startswith("backend/") and path.endswith(".py") for path in paths)
    touches_frontend = any(
        path.startswith("frontend/") and path.endswith((".ts", ".tsx", ".js", ".jsx", ".css"))
        for path in paths
    )
    touches_docs = any(path.startswith("docs/") and path.endswith(".md") for path in paths)
    touches_routes = any("router" in path.lower() or "/pages/" in path for path in paths)
    touches_contract = contract_gate_needed(task)

    if touches_backend:
        commands.extend(backend_standard_commands(root, task))
    if touches_frontend:
        commands.extend(frontend_standard_commands(root, task))
    if touches_docs:
        commands.append("test -d docs")
    if touches_routes:
        commands.append("test -f /home/pete/cadres/shared/templates/route-acceptance-checklist.md")
    if is_review_task(task):
        commands.append("test -f /home/pete/cadres/shared/templates/definition-of-done-checklist.md")
    if touches_contract:
        commands.extend(contract_gate_commands(root, task))
    return commands


def contract_gate_needed(task: Task) -> bool:
    text = " ".join([task.title, task.task_type, *task.files_expected]).lower()
    markers = (
        "agent/",
        "bes",
        "job",
        "payload",
        "telemetry",
        "permission",
        "webhook",
        "integration",
        "contract",
    )
    return any(marker in text for marker in markers)


def contract_gate_commands(root: Path, task: Task) -> list[str]:
    commands: list[str] = []
    if (root / "backend").is_dir():
        commands.append("test -d backend")
    if (root / "frontend").is_dir():
        commands.append("test -d frontend")
    if any(path.startswith("agent/") for path in task.files_expected):
        commands.append("test -d agent")
    if any(path.startswith("docs/") for path in task.files_expected):
        commands.append("test -d docs")
    return commands


def api_contract_gate_command(mode: str, files: list[str] | None = None) -> str:
    module_root = shlex.quote(str(SCRIPT_ROOT))
    command = (
        f"PYTHONPATH={module_root} python3 -m lazy_vibe.feature_build.api_contract_gate "
        f"--repo . --mode {shlex.quote(mode)}"
    )
    for path in files or []:
        command += f" --task-file {shlex.quote(path)}"
    return command


def backend_standard_commands(root: Path, task: Task | None = None) -> list[str]:
    backend = root / "backend"
    if not backend.is_dir():
        return []
    commands: list[str] = []
    task_files = task.files_expected if task is not None else []
    backend_py_files = [
        path.removeprefix("backend/")
        for path in task_files
        if path.startswith("backend/") and path.endswith(".py")
    ]
    backend_py_args = " ".join(shlex.quote(path) for path in backend_py_files)
    if (backend / "ruff.toml").exists() or (backend / "pyproject.toml").exists():
        if backend_py_args:
            commands.extend(
                [
                    f"cd backend && python3 -m ruff check {backend_py_args}",
                    f"cd backend && python3 -m ruff format --check {backend_py_args}",
                ]
            )
        elif task is None:
            commands.extend(
                [
                    "cd backend && python3 -m ruff check .",
                    "cd backend && python3 -m ruff format --check .",
                ]
            )
    backend_test_files = [
        path.removeprefix("backend/")
        for path in task_files
        if path.startswith("backend/tests/") and path.endswith(".py")
    ]
    if backend_test_files:
        test_args = " ".join(shlex.quote(path) for path in backend_test_files)
        commands.append(f"cd backend && python3 -m pytest {test_args}")
    return commands


def frontend_standard_commands(root: Path, task: Task | None = None) -> list[str]:
    frontend = root / "frontend"
    package_json = frontend / "package.json"
    if not package_json.exists():
        return []
    if task is not None:
        return []
    scripts = package_scripts(package_json)
    commands: list[str] = []
    scripts_to_run = ("lint", "typecheck", "build", "test")
    for script in scripts_to_run:
        if script in scripts:
            commands.append(f"cd frontend && npm run {script}")
    return commands


def package_scripts(package_json: Path) -> set[str]:
    try:
        data = json.loads(read_text(package_json))
    except json.JSONDecodeError:
        return set()
    scripts = data.get("scripts", {})
    if not isinstance(scripts, dict):
        return set()
    return {str(key) for key in scripts}


def selected_ids(args: argparse.Namespace) -> set[str] | None:
    if not args.only_task:
        return None
    return {item.strip() for item in args.only_task.split(",") if item.strip()}


def ready_tasks(tasks: list[Task], only: set[str] | None) -> list[Task]:
    by_id = {task.task_id: task for task in tasks}
    ready: list[Task] = []
    for task in tasks:
        if only is not None and task.task_id not in only:
            continue
        if task.status != "pending":
            continue
        if all(by_id[dep].status in TERMINAL_STATUSES for dep in task.depends_on):
            ready.append(task)
    return ready


def recover_stale_running_tasks(tasks: list[Task]) -> bool:
    changed = False
    for task in tasks:
        if task.status != "running":
            continue
        task.status = "pending"
        task.last_error = task.last_error or "Recovered stale running task from previous interrupted run."
        changed = True
    return changed


def execute_tasks(args: argparse.Namespace, root: Path, run_dir: Path, state_file: Path, state: dict[str, Any]) -> None:
    tasks_file = run_dir / "tasks.json"
    tasks = load_tasks(tasks_file)
    changed = recover_stale_running_tasks(tasks)
    if enforce_task_contract(args, root, tasks):
        changed = True
    if changed:
        save_task_state(run_dir, tasks)
    only = selected_ids(args)
    prompts_dir = run_dir / "prompts"
    logs_dir = run_dir / "logs"
    results_dir = run_dir / "results"
    prompts_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    results_dir.mkdir(parents=True, exist_ok=True)

    if args.verify_only:
        verify_all(args, root, run_dir, state_file, state)
        return

    if args.dry_run:
        print_schedule(tasks, only)
        return

    while True:
        batch = ready_tasks(tasks, only)
        if not batch:
            break
        run_ready_batch(args, root, run_dir, state_file, state, tasks, batch)
        refresh_task_contracts_from_disk(tasks, run_dir)
        save_task_state(run_dir, tasks)

    incomplete = [
        task.task_id
        for task in tasks
        if (only is None or task.task_id in only) and task.status not in TERMINAL_STATUSES
    ]
    if incomplete:
        state["phase"] = "failed"
        record_event(state_file, state, "incomplete_tasks", tasks=incomplete)
        raise RuntimeError(f"incomplete tasks remain: {', '.join(incomplete)}")
    state["phase"] = "implemented"
    record_event(state_file, state, "tasks_complete")


def run_ready_batch(
    args: argparse.Namespace,
    root: Path,
    run_dir: Path,
    state_file: Path,
    state: dict[str, Any],
    tasks: list[Task],
    batch: list[Task],
) -> None:
    max_workers = max(1, min(args.max_parallel, len(batch)))
    if max_workers == 1:
        for task in batch:
            run_task(args, root, run_dir, state_file, state, task, threading.Lock())
        return

    state_lock = threading.Lock()
    active: dict[Future[None], Task] = {}
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        for task in batch[:max_workers]:
            active[executor.submit(run_task, args, root, run_dir, state_file, state, task, state_lock)] = task

        next_index = max_workers
        while active:
            done, _pending = wait(active, return_when=FIRST_COMPLETED)
            for future in done:
                task = active.pop(future)
                future.result()
                refresh_task_contracts_from_disk(tasks, run_dir)
                save_task_state(run_dir, tasks)
                if next_index < len(batch):
                    next_task = batch[next_index]
                    next_index += 1
                    active[
                        executor.submit(
                            run_task,
                            args,
                            root,
                            run_dir,
                            state_file,
                            state,
                            next_task,
                            state_lock,
                        )
                    ] = next_task


def locked_record_event(
    lock: threading.Lock,
    state_file: Path,
    state: dict[str, Any],
    event: str,
    **details: Any,
) -> None:
    with lock:
        record_event(state_file, state, event, **details)


def run_task(
    args: argparse.Namespace,
    root: Path,
    run_dir: Path,
    state_file: Path,
    state: dict[str, Any],
    task: Task,
    state_lock: threading.Lock,
) -> None:
    ok, error = verify_task(task, root, run_dir)
    if ok:
        write_already_ok_result(task, run_dir)
        result_ok, result_error = verify_task(task, root, run_dir, require_result=True)
        if result_ok:
            task.status = "complete"
            task.last_error = ""
            print(f"[already-ok] task={task.task_id}")
            locked_record_event(state_lock, state_file, state, "task_already_complete", task_id=task.task_id)
            return
        if args.verify_only:
            task.status = "failed"
            task.last_error = result_error
            locked_record_event(
                state_lock,
                state_file,
                state,
                "task_verify_only_failed",
                task_id=task.task_id,
                error=result_error,
            )
            raise RuntimeError(f"{task.task_id} verification failed: {result_error}")
        task.last_error = result_error
        print(f"[result-repair] task={task.task_id} {result_error}")
    if args.verify_only:
        task.status = "failed"
        task.last_error = error
        locked_record_event(
            state_lock,
            state_file,
            state,
            "task_verify_only_failed",
            task_id=task.task_id,
            error=error,
        )
        raise RuntimeError(f"{task.task_id} verification failed: {error}")

    task.attempts += 1
    task.status = "running"
    locked_record_event(
        state_lock,
        state_file,
        state,
        "task_started",
        task_id=task.task_id,
        attempt=task.attempts,
    )

    agent = agent_for_task(task)
    task_file = run_dir / "tasks" / f"{task.task_id}.md"
    prompt_file = run_dir / "prompts" / f"{task.task_id}.md"
    log_file = run_dir / "logs" / f"{task.task_id}.log"
    result_file = run_dir / "results" / f"{task.task_id}.md"
    write_text(prompt_file, render_task_prompt(task, task_file, result_file))

    print(f"[start] task={task.task_id} type={task.task_type} agent={agent}")
    status = run_agent(agent, prompt_file, root, log_file, task.model_class, task)
    if status != 0:
        task.status = "failed"
        task.last_error = f"agent exited {status}; see {log_file}"
        locked_record_event(
            state_lock,
            state_file,
            state,
            "task_agent_failed",
            task_id=task.task_id,
            status=status,
        )
        if task.attempts <= args.max_retries:
            task.status = "pending"
            print(f"[retry] task={task.task_id} attempt={task.attempts}/{args.max_retries}")
            return
        raise RuntimeError(task.last_error)

    ok, error = verify_task(task, root, run_dir, require_result=True)
    if ok:
        task.status = "complete"
        task.last_error = ""
        print(f"[ok] task={task.task_id}")
        locked_record_event(state_lock, state_file, state, "task_complete", task_id=task.task_id)
        return

    task.status = "failed"
    task.last_error = error
    locked_record_event(
        state_lock,
        state_file,
        state,
        "task_verify_failed",
        task_id=task.task_id,
        error=error,
    )
    if task.attempts <= args.max_retries:
        task.status = "pending"
        print(f"[retry] task={task.task_id} verify failed: {error}")
        return
    raise RuntimeError(f"{task.task_id} verification failed: {error}")


def agent_for_task(task: Task) -> str:
    if task.task_type == "review" or task.task_id.startswith("R"):
        return os.getenv("FEATURE_BUILD_REVIEWER_AGENT") or os.getenv("REVIEWER_AGENT") or "claude"
    return os.getenv("FEATURE_BUILD_IMPLEMENTER_AGENT") or os.getenv("IMPLEMENTER_AGENT") or "codex"


def render_task_prompt(task: Task, task_file: Path, result_file: Path) -> str:
    previous_failure = ""
    if task.last_error:
        previous_failure = f"""
Previous verifier failure that must be fixed in this attempt:

```text
{task.last_error}
```

If the failure is caused by stale or impossible task metadata, update both the task markdown and `tasks.json` to match the real repository contract, then rerun verification.
"""
    return f"""Your complete assignment is in this task file:
{task_file}

Mandatory execution philosophy and standards:
{standards_bundle()}

Read the task file. Execute every item in scope. Do not work outside the declared task scope unless a small integration fix is required for the task verification to pass.

Do the whole task. Do not defer, phase, postpone, stub, mock away, or create a workaround when the full implementation can be completed now.
{previous_failure}

Reduce future tech debt as part of the task. If your change replaces an older implementation path, remove or converge the legacy path now: stale code, duplicate helpers, hidden routes, old feature flags, obsolete docs/tests, placeholder UI/API surfaces, mocks, no-op shims, and compatibility glue. Keep a legacy path only when the task/spec names an explicit compatibility contract; if you keep one, document the contract and add verification that both the current path and the compatibility path behave correctly.

Before reporting done:
1. Run every verification command declared in the task file and tasks.json.
2. Confirm expected files exist.
3. Search the changed surface for stale/superseded/stub residue and either remove it or document the explicit compatibility contract that requires it.
4. For API, permission, tenant, RBAC, destructive-action, lifecycle, connector, webhook, job, retry, or audit-sensitive work, document the negative/failure proof and operator-visible error, audit, log, retry, or recovery behavior.
5. Confirm docs/contracts/manual material were updated when the task changes APIs, permissions, lifecycle states, audit events, jobs, external integrations, or operator workflows.
6. Write your result to:
{result_file}

Result format:
- Files created/modified
- Verification commands and outputs
- Issues encountered
- Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept
- Boundary/failure/operability proof, or why not applicable
- Documentation/contract updates, or why not applicable
- Final status: complete, partial, or blocked
"""


def refresh_task_from_disk(task: Task, run_dir: Path) -> bool:
    tasks_file = run_dir / "tasks.json"
    if not tasks_file.exists():
        return False
    try:
        current = {candidate.task_id: candidate for candidate in load_tasks(tasks_file)}
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    fresh = current.get(task.task_id)
    if fresh is None:
        return False

    changed = False
    for attr in (
        "title",
        "task_type",
        "depends_on",
        "model_class",
        "files_expected",
        "verification_commands",
    ):
        value = getattr(fresh, attr)
        if getattr(task, attr) != value:
            setattr(task, attr, value)
            changed = True
    return changed


def refresh_task_contracts_from_disk(tasks: list[Task], run_dir: Path) -> bool:
    tasks_file = run_dir / "tasks.json"
    if not tasks_file.exists():
        return False
    try:
        current = {candidate.task_id: candidate for candidate in load_tasks(tasks_file)}
    except (OSError, ValueError, json.JSONDecodeError):
        return False

    changed = False
    for task in tasks:
        fresh = current.get(task.task_id)
        if fresh is None:
            continue
        for attr in (
            "title",
            "task_type",
            "depends_on",
            "model_class",
            "files_expected",
            "verification_commands",
        ):
            value = getattr(fresh, attr)
            if getattr(task, attr) != value:
                setattr(task, attr, value)
                changed = True
    return changed


def verify_task(task: Task, root: Path, run_dir: Path, require_result: bool = False) -> tuple[bool, str]:
    refresh_task_from_disk(task, run_dir)
    missing = [path for path in task.files_expected if not (root / path).exists()]
    if missing:
        return False, f"missing expected files: {', '.join(missing)}"

    verify_dir = run_dir / "verify" / task.task_id
    verify_dir.mkdir(parents=True, exist_ok=True)
    for index, command in enumerate(task.verification_commands, start=1):
        result = run_shell(command, root, verify_dir / f"{index:02d}.log")
        if result.returncode != 0:
            return False, f"command failed ({result.returncode}): {command}"
    if require_result or task.status == "complete":
        ok, error = verify_task_result_quality(task, root, run_dir)
        if not ok:
            return False, error
    return True, ""


def verify_task_result_quality(task: Task, root: Path, run_dir: Path) -> tuple[bool, str]:
    if not result_quality_gates_enabled():
        return True, ""
    result_file = run_dir / "results" / f"{task.task_id}.md"
    if not result_file.exists():
        return False, f"missing task result artifact: {result_file}"
    text = read_text(result_file)
    lower = text.lower()
    if not deferrals_allowed() and contains_deferral_marker(text):
        return False, f"task result contains deferral/workaround language: {result_file}"
    missing_sections = [section for section in RESULT_REQUIRED_SECTIONS if section not in lower]
    if missing_sections:
        return False, (
            f"task result missing required closeout section(s): {', '.join(missing_sections)}"
        )
    if any(marker in lower for marker in INCOMPLETE_RESULT_MARKERS):
        return False, "task result final status is not complete"
    if not result_has_complete_final_status(text):
        return False, "task result must declare `Final status: complete`"
    missing_commands = [
        command for command in task.verification_commands if not result_documents_command(command, text, root)
    ]
    if missing_commands:
        return False, (
            "task result does not list verification command(s): "
            + "; ".join(missing_commands[:3])
        )
    if task_needs_operability_closeout(task) and not any(marker in lower for marker in OPERABILITY_MARKERS):
        return False, (
            "task result must document boundary/failure/operability proof or explicitly say not applicable"
        )
    return True, ""


def result_has_complete_final_status(text: str) -> bool:
    normalized = text.lower()
    if "final status: complete" in normalized:
        return True
    return bool(
        re.search(
            r"final status\s*(?:\n|:)\s*(?:[-*]\s*)?(?:`+)?complete(?:`+)?\b",
            normalized,
        )
    )


def result_documents_command(command: str, text: str, root: Path) -> bool:
    if command in text:
        return True
    normalized_texts = {
        normalize_command_text(text),
        normalize_command_for_result_matching(text, root),
    }
    normalized_texts |= {quote_insensitive_command_text(value) for value in normalized_texts}
    normalized_commands = {
        normalize_command_text(command),
        normalize_command_for_result_matching(command, root),
    }
    normalized_commands |= command_prefix_candidates(normalized_commands)
    normalized_commands |= {quote_insensitive_command_text(value) for value in normalized_commands}
    for normalized_command in normalized_commands:
        if normalized_command and any(normalized_command in value for value in normalized_texts):
            return True
    shell_script = extract_bash_c_script(command)
    if shell_script:
        normalized_scripts = {
            normalize_command_text(shell_script),
            normalize_command_for_result_matching(shell_script, root),
        }
        normalized_scripts |= command_prefix_candidates(normalized_scripts)
        normalized_scripts |= {quote_insensitive_command_text(value) for value in normalized_scripts}
        for normalized_script in normalized_scripts:
            if normalized_script and any(normalized_script in value for value in normalized_texts):
                return True
    return False


def normalize_command_text(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def normalize_command_for_result_matching(value: str, root: Path) -> str:
    normalized = normalize_command_text(value)
    root_text = str(root.resolve())
    escaped = re.escape(root_text.rstrip("/"))
    normalized = re.sub(rf"\bcd\s+{escaped}/([^;&|]+)", r"cd \1", normalized)
    normalized = re.sub(rf"\bcd\s+{escaped}\s*&&\s*", "", normalized)
    normalized = re.sub(r";\s*echo\s+(['\"]).*?\1", "", normalized)
    return normalized


def quote_insensitive_command_text(value: str) -> str:
    return value.replace('"', "'")


def command_prefix_candidates(commands: set[str]) -> set[str]:
    candidates: set[str] = set()
    for command in commands:
        if command.endswith(("'", '"')):
            candidates.add(command[:-1])
    return candidates


def extract_bash_c_script(command: str) -> str:
    match = re.search(r"\bbash\s+-c\s+(['\"])(.+?)\1", command, flags=re.DOTALL)
    return match.group(2).strip() if match else ""


def write_already_ok_result(task: Task, run_dir: Path) -> None:
    result_file = run_dir / "results" / f"{task.task_id}.md"
    if result_file.exists():
        return
    command_lines = "\n".join(f"- {command} -> pass" for command in task.verification_commands)
    file_lines = "\n".join(f"- {path}" for path in task.files_expected) or "- No expected files declared"
    write_text(
        result_file,
        f"""# {task.task_id}: {task.title}

## Files created/modified
{file_lines}

## Verification commands and outputs
{command_lines}

## Issues encountered
No implementation agent was run; the current checkout already satisfied this task's verification contract.

## Legacy/superseded/stub cleanup performed, or explicit compatibility contract kept
Not applicable; no implementation agent was run.

## Boundary/failure/operability proof, or why not applicable
Not applicable; no implementation agent was run.

## Documentation/contract updates, or why not applicable
Not applicable; no implementation agent was run.

## Final status
Final status: complete
""",
    )


def task_needs_operability_closeout(task: Task) -> bool:
    text = " ".join([task.title, task.task_type, *task.files_expected]).lower()
    markers = (
        "api",
        "audit",
        "auth",
        "connector",
        "destructive",
        "idempot",
        "integration",
        "job",
        "lifecycle",
        "permission",
        "rbac",
        "retry",
        "session",
        "sync",
        "tenant",
        "webhook",
    )
    return any(marker in text for marker in markers)


def verify_all(args: argparse.Namespace, root: Path, run_dir: Path, state_file: Path, state: dict[str, Any]) -> None:
    tasks_file = run_dir / "tasks.json"
    tasks = load_tasks(tasks_file)
    changed = recover_stale_running_tasks(tasks)
    if enforce_task_contract(args, root, tasks):
        changed = True
    if changed:
        save_task_state(run_dir, tasks)
    only = selected_ids(args)
    failed: list[str] = []
    for task in tasks:
        if only is not None and task.task_id not in only:
            continue
        ok, error = verify_task(task, root, run_dir, require_result=task.status == "complete")
        if ok:
            print(f"[verify-ok] {task.task_id}")
        else:
            print(f"[verify-fail] {task.task_id}: {error}")
            failed.append(task.task_id)
    if failed:
        state["phase"] = "verify_failed"
        record_event(state_file, state, "verify_failed", tasks=failed)
        raise RuntimeError(f"verification failed: {', '.join(failed)}")
    record_event(state_file, state, "verify_complete")


def print_schedule(tasks: list[Task], only: set[str] | None) -> None:
    for task in tasks:
        if only is None or task.task_id in only:
            deps = ",".join(task.depends_on) if task.depends_on else "-"
            print(f"{task.task_id}\t{task.status}\t{task.task_type}\tdeps={deps}\t{task.title}")


def final_gates(args: argparse.Namespace, root: Path, run_dir: Path, state_file: Path, state: dict[str, Any]) -> None:
    if args.verify:
        verify_all(args, root, run_dir, state_file, state)
        if standard_gates_enabled(args):
            run_final_standard_gates(args, root, run_dir)
            record_event(state_file, state, "standard_gates_complete")
        run_post_build_closeout(args, root, run_dir, state_file, state)


def successful_build_closeout(
    args: argparse.Namespace,
    root: Path,
    run_dir: Path,
    state_file: Path,
    state: dict[str, Any],
) -> None:
    should_commit = feature_build_commit_enabled(args)
    should_push = bool(args.push)
    should_deploy = bool(args.deploy_command)
    if should_commit or should_push or should_deploy:
        record_event(
            state_file,
            state,
            "closeout_ready",
            commit=should_commit,
            push=args.push or "",
            deploy=should_deploy,
        )
    if should_commit:
        commit_changes(args, root)
    if should_push:
        push_changes(args, root)
    if should_deploy:
        result = run_shell(args.deploy_command, root, run_dir / "logs" / "deploy.log")
        if result.returncode != 0:
            raise RuntimeError(f"deploy command failed: {args.deploy_command}")


def feature_build_branch_enabled(args: argparse.Namespace) -> bool:
    if args.no_branch:
        return False
    if not args.execute or args.verify_only or args.dry_run:
        return False
    raw = os.getenv("FEATURE_BUILD_AUTO_BRANCH", "1").strip().lower()
    return raw not in FALSE_VALUES


def feature_build_commit_enabled(args: argparse.Namespace) -> bool:
    if args.no_commit:
        return False
    if args.commit:
        return True
    if not args.execute or not args.verify or args.verify_only or args.dry_run:
        return False
    raw = os.getenv("FEATURE_BUILD_AUTO_COMMIT", "1").strip().lower()
    return raw not in FALSE_VALUES


def default_feature_branch(feature: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._/-]+", "-", feature.strip())
    slug = re.sub(r"-+", "-", slug).strip("-/")
    return f"feature/{slug or 'feature-build'}"


def feature_branch_name(args: argparse.Namespace) -> str:
    return args.branch or os.getenv("FEATURE_BUILD_BRANCH") or default_feature_branch(args.feature)


def is_git_repo(root: Path) -> bool:
    return run_shell("git rev-parse --is-inside-work-tree", root).returncode == 0


def ensure_feature_branch(args: argparse.Namespace, root: Path) -> None:
    if not feature_build_branch_enabled(args):
        return
    if not is_git_repo(root):
        print("[branch] not a git repository; skipping feature branch")
        return
    target = feature_branch_name(args)
    current = current_branch(root)
    if current == target:
        print(f"[branch] {target}")
        return
    if git_branch_exists(root, target):
        result = run_shell(f"git switch {shlex.quote(target)}", root)
    else:
        result = run_shell(f"git switch -c {shlex.quote(target)}", root)
    if result.returncode != 0:
        raise RuntimeError(
            f"could not switch to feature branch {target!r}. "
            "Commit/stash conflicting work or rerun with --no-branch.\n"
            f"{result.output}"
        )
    print(f"[branch] {target}")


def git_branch_exists(root: Path, branch: str) -> bool:
    result = run_shell(f"git show-ref --verify --quiet {shlex.quote('refs/heads/' + branch)}", root)
    return result.returncode == 0


def run_final_standard_gates(args: argparse.Namespace, root: Path, run_dir: Path) -> None:
    commands = merge_unique(
        backend_standard_commands(root)
        + frontend_standard_commands(root)
        + [api_contract_gate_command("final")]
    )
    if not commands:
        print("[standard-gates] no backend/frontend gates detected")
        return
    gate_dir = run_dir / "verify" / "standard-gates"
    gate_dir.mkdir(parents=True, exist_ok=True)
    for index, command in enumerate(commands, start=1):
        print(f"[standard-gate] {command}")
        log_file = gate_dir / f"{index:02d}.log"
        result = run_shell(command, root, log_file)
        if result.returncode != 0:
            repaired = repair_standard_gate(command, root, gate_dir, index)
            if repaired:
                result = run_shell(command, root, log_file)
            if result.returncode != 0 and repair_standard_gate_with_agent(
                args,
                command,
                root,
                run_dir,
                gate_dir,
                index,
                result,
            ):
                result = run_shell(command, root, log_file)
            if result.returncode != 0:
                raise RuntimeError(f"standard gate failed ({result.returncode}): {command}")


def repair_standard_gate(command: str, root: Path, gate_dir: Path, index: int) -> bool:
    repairs = standard_gate_repair_commands(command)
    if not repairs:
        return False
    print(f"[standard-gate-repair] {command}")
    for repair_index, repair_command in enumerate(repairs, start=1):
        print(f"[standard-gate-repair] {repair_command}")
        result = run_shell(
            repair_command,
            root,
            gate_dir / f"{index:02d}.repair-{repair_index:02d}.log",
        )
        if result.returncode != 0:
            return False
    return True


def standard_gate_repair_commands(command: str) -> list[str]:
    normalized = normalize_command_text(command)
    if normalized == "cd backend && python3 -m ruff check .":
        return [
            "cd backend && python3 -m ruff check --fix .",
            "cd backend && python3 -m ruff format .",
        ]
    if normalized == "cd backend && python3 -m ruff format --check .":
        return ["cd backend && python3 -m ruff format ."]
    return []


def repair_standard_gate_with_agent(
    args: argparse.Namespace,
    command: str,
    root: Path,
    run_dir: Path,
    gate_dir: Path,
    index: int,
    result: CommandResult,
) -> bool:
    agent = str(getattr(args, "standard_gate_repair_agent", "") or "").strip().lower()
    if not agent:
        return False
    prompt_file = gate_dir / f"{index:02d}.agent-repair.md"
    log_file = gate_dir / f"{index:02d}.agent-repair.log"
    prompt_file.write_text(
        build_standard_gate_repair_prompt(args, command, root, run_dir, result),
        encoding="utf-8",
    )
    print(f"[standard-gate-agent-repair] gate={index:02d} agent={agent} command={command}")
    returncode = run_agent(agent, prompt_file, root, log_file, "advanced", None)
    if returncode != 0:
        print(f"[standard-gate-agent-repair] failed rc={returncode} log={log_file}")
        return False
    return True


def build_standard_gate_repair_prompt(
    args: argparse.Namespace,
    command: str,
    root: Path,
    run_dir: Path,
    result: CommandResult,
) -> str:
    output = result.output[-16000:]
    return f"""You are repairing a failed final feature-build standard gate.

Repository: {root}
Feature: {args.feature}
Run directory: {run_dir}
Failed command: {command}

{EXECUTION_PHILOSOPHY}

Requirements:
- Fix the real root cause in the active checkout.
- Do not bypass, weaken, delete, or suppress the standard gate.
- Do not add placeholder callers or fake evidence to satisfy dead-code checks.
- If the failure identifies unused/dead API surface, remove it unless a real product caller should exist; if a caller should exist, implement the real product caller.
- If the failure is formatting or lint cleanup, make the smallest correct code changes and preserve behavior.
- Rerun the failed command before finishing.

Failed command output:

```text
{output}
```
"""


def run_post_build_closeout(
    args: argparse.Namespace,
    root: Path,
    run_dir: Path,
    state_file: Path,
    state: dict[str, Any],
) -> None:
    if not args.post_build_review_command:
        return

    artifact_dir = run_dir / "artifacts"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    env = {
        "FEATURE_BUILD_FEATURE": args.feature,
        "FEATURE_BUILD_RUN_DIR": str(run_dir),
        "FEATURE_BUILD_SPEC": str(resolve_paths(args, root)[0]),
        "FEATURE_BUILD_SCORECARD": str(root / "docs" / "scorecard" / f"{args.feature}.md"),
    }

    rounds = max(1, args.post_build_rounds)
    for round_index in range(1, rounds + 1):
        env["FEATURE_BUILD_REVIEW_ROUND"] = str(round_index)
        review_log = run_dir / "logs" / f"post-build-review-{round_index:02d}.log"
        print(f"[post-build-review] round={round_index}")
        review = run_shell(args.post_build_review_command, root, review_log, env)
        if review.returncode != 0:
            raise RuntimeError(
                f"post-build review failed ({review.returncode}); see {review_log}"
            )
        record_event(state_file, state, "post_build_review_complete", round=round_index)

        decision = read_post_build_decision(artifact_dir)
        if decision in {"accept", "accepted", "ready", "pass"}:
            print(f"[post-build-review] accepted round={round_index}")
            record_event(state_file, state, "post_build_accepted", round=round_index)
            return

        if not args.auto_remediate_command:
            if decision in {"revise", "remediate", "fail", "blocked", "stop"}:
                raise RuntimeError(f"post-build review returned {decision}; no remediation command set")
            print("[post-build-review] no structured decision; treating zero exit as accepted")
            record_event(state_file, state, "post_build_accepted_unstructured", round=round_index)
            return

        remediation_log = run_dir / "logs" / f"post-build-remediation-{round_index:02d}.log"
        print(f"[post-build-remediation] round={round_index}")
        remediation = run_shell(args.auto_remediate_command, root, remediation_log, env)
        if remediation.returncode != 0:
            raise RuntimeError(
                f"post-build remediation failed ({remediation.returncode}); see {remediation_log}"
            )
        record_event(state_file, state, "post_build_remediation_complete", round=round_index)
        verify_all(args, root, run_dir, state_file, state)
        if standard_gates_enabled(args):
            run_final_standard_gates(args, root, run_dir)

    raise RuntimeError("post-build review/remediation rounds exhausted without accepted verdict")


def read_post_build_decision(artifact_dir: Path) -> str:
    decision_file = artifact_dir / "post-build-review.json"
    if not decision_file.exists():
        return ""
    try:
        data = json.loads(read_text(decision_file))
    except json.JSONDecodeError:
        return ""
    if data.get("accepted") is True:
        return "accepted"
    if data.get("accepted") is False:
        return "revise"
    return str(data.get("verdict") or data.get("decision") or "").strip().lower()


def commit_changes(args: argparse.Namespace, root: Path) -> None:
    if not is_git_repo(root):
        print("[commit] not a git repository; skipping")
        return
    status = run_shell("git status --porcelain", root).output.strip()
    if not status:
        print("[commit] no changes")
        return
    message = args.commit_message or f"feat: build {args.feature}"
    run_shell("git add -A", root)
    result = run_shell(f"git commit -m {shlex.quote(message)}", root)
    if result.returncode != 0:
        raise RuntimeError(f"git commit failed:\n{result.output}")
    print("[commit] complete")


def current_branch(root: Path) -> str:
    result = run_shell("git rev-parse --abbrev-ref HEAD", root)
    if result.returncode != 0:
        raise RuntimeError("could not determine current git branch")
    return result.output.strip()


def push_changes(args: argparse.Namespace, root: Path) -> None:
    remote = args.push or "origin"
    branch = args.push_branch or current_branch(root)
    result = run_shell(f"git push {shlex.quote(remote)} {shlex.quote(branch)}", root)
    if result.returncode != 0:
        raise RuntimeError(f"git push failed:\n{result.output}")
    print(f"[push] {remote} {branch}")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = repo_root()
    spec, run_dir = resolve_paths(args, root)
    ensure_feature_branch(args, root)
    state_file = run_dir / "state.json"
    tasks_file = run_dir / "tasks.json"
    state = load_state(state_file, args.feature, spec, tasks_file)
    save_state(state_file, state)

    try:
        decompose(args, root, spec, run_dir, state_file, state)
        if args.execute or args.verify_only:
            execute_tasks(args, root, run_dir, state_file, state)
        elif args.dry_run and tasks_file.exists():
            print_schedule(load_tasks(tasks_file), selected_ids(args))
        if (args.execute or args.verify_only) and not args.dry_run:
            final_gates(args, root, run_dir, state_file, state)
        state["phase"] = "complete"
        save_state(state_file, state)
        successful_build_closeout(args, root, run_dir, state_file, state)
        print(f"Feature build state: {state_file}")
        return 0
    except Exception as exc:
        state["phase"] = "failed"
        record_event(state_file, state, "failed", error=str(exc))
        print(f"feature-build failed: {exc}", file=sys.stderr)
        print(f"Feature build state: {state_file}", file=sys.stderr)
        return 1
