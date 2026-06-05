from __future__ import annotations

import argparse
import csv
import re
import shlex
from dataclasses import dataclass
from pathlib import Path


PASS_RESULTS = {"PASS", "completed"}
RESULT_RE = re.compile(r"RESULT:\s*([A-Za-z/]+)")
RUNNER_UNAVAILABLE_RE = re.compile(
    r"rate limit|too many requests|temporarily unavailable|service unavailable|"
    r"overloaded|quota exceeded|authentication failed|invalid api key|"
    r"api[\s_-]*(error|unavailable)|claude.*(down|unavailable|overloaded)|"
    r"anthropic.*(down|unavailable|overloaded)|openai.*(down|unavailable|overloaded)|"
    r"provider.*(down|unavailable|overloaded)|HTTP\s*(429|503).*model",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class JobRow:
    job_id: str
    group: str
    kind: str
    title: str
    output: str
    ref: str
    result: str
    log_path: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write audit run summary artifacts.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--jobs-file", required=True)
    parser.add_argument("--checkpoint-file", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--script-path", required=True)
    parser.add_argument("--summary-file", required=True)
    parser.add_argument("--next-actions-file", required=True)
    parser.add_argument("--from-group", default="")
    parser.add_argument("--to-group", default="")
    parser.add_argument("--only-job", default="")
    parser.add_argument("--load-test-enabled", default="0")
    parser.add_argument("--jobs-file-env", default="")
    parser.add_argument("--product-profile", default="")
    parser.add_argument("--profile", default="")
    parser.add_argument("--runner", default="")
    parser.add_argument("--audit-runner", default="")
    return parser.parse_args()


def read_completed(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}


def group_selected(group: str, from_group: str, to_group: str) -> bool:
    if from_group and group < from_group:
        return False
    if to_group and group > to_group:
        return False
    return True


def extract_result(log_path: Path) -> str:
    if not log_path.exists():
        return "completed"
    matches = RESULT_RE.findall(log_path.read_text(encoding="utf-8", errors="replace"))
    return matches[-1] if matches else "completed"


def job_result(job_id: str, log_path: Path, completed: set[str]) -> str:
    if job_id in completed:
        return extract_result(log_path)
    if log_path.exists():
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if not RESULT_RE.search(text) and RUNNER_UNAVAILABLE_RE.search(text):
            return "RUNNER_UNAVAILABLE"
        return "FAIL"
    return "not-run"


def read_manifest_jobs(args: argparse.Namespace, run_dir: Path, completed: set[str]) -> list[JobRow]:
    jobs: list[JobRow] = []
    with Path(args.jobs_file).open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            group = (row.get("group") or "").strip()
            job_id = (row.get("job_id") or "").strip()
            kind = (row.get("kind") or "").strip()
            if not job_id:
                continue
            if args.only_job and job_id != args.only_job:
                continue
            if not group_selected(group, args.from_group, args.to_group):
                continue
            log_path = run_dir / "logs" / f"{job_id}.log"
            title = (row.get("title") or "").strip()
            output = (row.get("output") or "").strip()
            ref = (row.get("ref") or "").strip()
            jobs.append(JobRow(job_id, group, kind, title, output, ref, job_result(job_id, log_path, completed), log_path))
    return jobs


def read_dynamic_jobs(run_dir: Path, completed: set[str]) -> list[JobRow]:
    queued_file = run_dir / "artifacts" / "queued-deep-dives.txt"
    if not queued_file.exists():
        return []
    jobs: list[JobRow] = []
    seen: set[str] = set()
    for raw in queued_file.read_text(encoding="utf-8").splitlines():
        job_id = raw.strip()
        if not job_id or job_id in seen:
            continue
        seen.add(job_id)
        log_path = run_dir / "logs" / f"{job_id}.log"
        jobs.append(JobRow(job_id, "", "deep-dive", "", "", "", job_result(job_id, log_path, completed), log_path))
    return jobs


def load_test_job(run_dir: Path, completed: set[str], enabled: str) -> list[JobRow]:
    if enabled != "1":
        return []
    log_path = run_dir / "logs" / "load-test.log"
    return [JobRow("load-test", "", "load", "Load test", "", "", job_result("load-test", log_path, completed), log_path)]


def output_artifact_path(run_dir: Path, row: JobRow) -> Path | None:
    if not row.output:
        return None
    output = Path(row.output)
    if output.is_absolute():
        return output
    return run_dir / "artifacts" / output


def native_summary_paths(run_dir: Path, row: JobRow) -> list[Path]:
    candidates = [
        run_dir / "artifacts" / f"{row.job_id}-native-summary.md",
        run_dir / "artifacts" / f"{row.job_id}-native-summary.tsv",
        run_dir / "artifacts" / f"{row.job_id}-e2e-summary.md",
        run_dir / "artifacts" / f"{row.job_id}-e2e-summary.tsv",
        run_dir / "artifacts" / f"{row.job_id}-lighthouse-summary.md",
        run_dir / "artifacts" / f"{row.job_id}-lighthouse-summary.tsv",
        run_dir / "artifacts" / f"{row.job_id}-accessibility-summary.md",
        run_dir / "artifacts" / f"{row.job_id}-accessibility-summary.tsv",
    ]
    return [path for path in candidates if path.exists()]


def remediation_context(args: argparse.Namespace, row: JobRow) -> str:
    run_dir = Path(args.run_dir)
    output_path = output_artifact_path(run_dir, row)
    native_paths = native_summary_paths(run_dir, row)
    details: list[str] = []
    if row.group:
        details.append(f"group={row.group}")
    if row.title:
        details.append(f"title={row.title}")
    if row.ref:
        details.append(f"ref={row.ref}")
    if output_path is not None:
        status = "exists" if output_path.exists() else "missing"
        details.append(f"output={output_path} ({status})")
    if native_paths:
        details.append("native_artifacts=" + ",".join(str(path) for path in native_paths[:4]))
    details.append("class=" + remediation_class(row, output_path, native_paths))
    return "; ".join(details)


def remediation_class(
    row: JobRow,
    output_path: Path | None,
    native_paths: list[Path],
) -> str:
    if row.result == "RUNNER_UNAVAILABLE":
        return "runner_unavailable"
    if row.result == "not-run":
        return "not_run"
    text_parts: list[str] = []
    if row.log_path.exists():
        text_parts.append(row.log_path.read_text(encoding="utf-8", errors="replace")[-12000:])
    for path in native_paths:
        text_parts.append(path.read_text(encoding="utf-8", errors="replace")[-12000:])
    text = "\n".join(text_parts).lower()
    if any(token in text for token in ("command not found", "no such file", "cannot find module", "unknown argument")):
        return "harness_or_native_command"
    if any(token in text for token in ("playwright", "lighthouse", "axe", "accessibility", "browser", "e2e")):
        return "runtime_or_browser_evidence"
    if output_path is not None and not output_path.exists():
        return "audit_output_missing"
    if any(token in text for token in ("401", "403", "rbac", "tenant", "permission", "authorization", "auth")):
        return "security_boundary"
    if any(token in text for token in ("openapi", "api contract", "request schema", "response schema")):
        return "api_contract"
    if any(token in text for token in ("audit log", "correlation", "request id", "job status", "retry")):
        return "operability"
    return "implementation_or_docs_gap"


def write_tsv(path: Path, args: argparse.Namespace, rows: list[JobRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["job_id", "kind", "result", "group", "title", "output", "log_path", "remediation_context"])
        for row in rows:
            writer.writerow(
                [
                    row.job_id,
                    row.kind,
                    row.result,
                    row.group,
                    row.title,
                    str(output_artifact_path(Path(args.run_dir), row) or ""),
                    str(row.log_path),
                    remediation_context(args, row),
                ]
            )


def summarize_counts(rows: list[JobRow]) -> tuple[int, int, int]:
    passed = incomplete = failed = 0
    for row in rows:
        if row.result in PASS_RESULTS:
            passed += 1
        elif row.result == "INCOMPLETE":
            incomplete += 1
        else:
            failed += 1
    return passed, incomplete, failed


def log_hint(log_path: Path) -> str:
    if not log_path.exists():
        return "No log was written. The job likely did not start."
    text = log_path.read_text(encoding="utf-8", errors="replace")
    checks = [
        ("[runner-unavailable]", "The model runner or provider appears unavailable; rerun with another RUNNER or after provider recovery."),
        ("[stall-kill]", "The runner stalled with no log growth and was terminated."),
        ("[missing-output]", "The runner exited but did not produce the required output artifact."),
        ("Cannot find module", "Native Node audit tooling is incomplete or was pruned before execution."),
        ("TimeoutExpired", "A subprocess timed out."),
        ("timed out", "A subprocess or tool timed out."),
        ("Traceback", "A Python traceback is present in the log."),
        ("syntax error", "A shell syntax error is present in the log."),
    ]
    lower = text.lower()
    if not RESULT_RE.search(text) and RUNNER_UNAVAILABLE_RE.search(text):
        return "The model runner or provider appears unavailable; rerun with another RUNNER or after provider recovery."
    for needle, hint in checks:
        if needle.lower() in lower:
            return hint
    tail = [line.strip() for line in text.splitlines()[-6:] if line.strip()]
    if tail:
        return "Last log lines: " + " | ".join(tail)[-800:]
    return "Log exists but contains no useful failure marker."


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def rerun_command(args: argparse.Namespace, row: JobRow) -> str:
    if row.kind == "deep-dive":
        return (
            "Dynamic deep-dive jobs are spawned from artifacts/pending-jobs.tsv. "
            "Review the pending row and rerun the parent audit scope after fixing the blocker."
        )
    env_parts = [
        shell_assign("REPO_ROOT", args.repo_root),
        shell_assign("RUN_DIR", args.run_dir),
        shell_assign("MAX_PARALLEL", "1"),
        shell_assign("AUDIT_STALL_INTERVALS", "30"),
    ]
    if args.jobs_file_env:
        env_parts.append(shell_assign("JOBS_FILE", args.jobs_file_env))
    if args.product_profile:
        env_parts.append(shell_assign("PRODUCT_PROFILE", args.product_profile))
    if args.profile:
        env_parts.append(shell_assign("PROFILE", args.profile))
    if args.runner:
        env_parts.append(shell_assign("RUNNER", args.runner))
    if args.audit_runner:
        env_parts.append(shell_assign("AUDIT_RUNNER", args.audit_runner))
    command = [shlex.quote(args.script_path), "--only", shlex.quote(row.job_id)]
    return "cd " + shlex.quote(args.repo_root) + " && " + " ".join(env_parts + command)


def write_next_actions(path: Path, args: argparse.Namespace, rows: list[JobRow]) -> None:
    non_pass = [row for row in rows if row.result not in PASS_RESULTS]
    lines = [
        "# Failed Jobs Next Actions",
        "",
        "Generated by the audit harness from job checkpoints and logs.",
        "",
    ]
    if not non_pass:
        lines.append("No failed, incomplete, or not-run jobs were detected.")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    lines.extend(
        [
            "| Job | Kind | Result | Output | Log | Likely reason | Remediation context |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for row in non_pass:
        output_path = output_artifact_path(Path(args.run_dir), row)
        output_display = str(output_path) if output_path else ""
        log_display = str(row.log_path)
        lines.append(
            f"| `{row.job_id}` | `{row.kind}` | `{row.result}` | `{output_display}` | `{log_display}` | {log_hint(row.log_path)} | {remediation_context(args, row)} |"
        )
    lines.append("")
    lines.append("## Rerun Commands")
    lines.append("")
    for row in non_pass:
        lines.append(f"### {row.job_id}")
        lines.append("")
        lines.append("```bash")
        lines.append(rerun_command(args, row))
        lines.append("```")
        lines.append("")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def print_console_summary(rows: list[JobRow], summary_file: Path, next_actions_file: Path) -> None:
    passed, incomplete, failed = summarize_counts(rows)
    print(f"\n=== Audit Run Summary ({len(rows)} jobs) ===")
    print(f"PASS/completed: {passed}  INCOMPLETE: {incomplete}  FAIL/not-run: {failed}")
    if incomplete > 0 or failed > 0:
        print("Non-pass:")
        for row in rows:
            if row.result not in PASS_RESULTS:
                print(f"  {row.job_id} ({row.kind}): {row.result}")
        print(f"Next actions: {next_actions_file}")
    print(f"Summary: {summary_file}")
    print("===================================")


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir)
    completed = read_completed(Path(args.checkpoint_file))
    rows = read_manifest_jobs(args, run_dir, completed)
    rows.extend(read_dynamic_jobs(run_dir, completed))
    rows.extend(load_test_job(run_dir, completed, args.load_test_enabled))

    summary_file = Path(args.summary_file)
    next_actions_file = Path(args.next_actions_file)
    write_tsv(summary_file, args, rows)
    write_next_actions(next_actions_file, args, rows)
    print_console_summary(rows, summary_file, next_actions_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
