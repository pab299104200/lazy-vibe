#!/usr/bin/env python3
"""Provider-agnostic multi-agent coordinator."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


TOOL_ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = TOOL_ROOT / "config.json"
ISO_SECONDS = "%Y-%m-%dT%H:%M:%S%z"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(payload, file, indent=2, sort_keys=True)
        file.write("\n")


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(payload, sort_keys=True) + "\n")


def append_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(text)


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8") as file:
        return file.read()


def copy_file_if_exists(source: Path, target: Path) -> None:
    if source.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def now_iso() -> str:
    return dt.datetime.now().astimezone().strftime(ISO_SECONDS)


def print_status(message: str) -> None:
    print(message, flush=True)


def slugify(value: str, fallback: str = "instruction") -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.lower()).strip("-")
    return slug[:64] or fallback


def instruction_title(value: str) -> str:
    first_line = value.strip().splitlines()[0] if value.strip() else "instruction"
    return slugify(first_line, fallback="instruction")[:80]


def instruction_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:10]


def load_instruction(args: argparse.Namespace) -> str:
    if args.instruction_file:
        return read_text(Path(args.instruction_file).expanduser().resolve()).strip()
    if args.instruction:
        return args.instruction.strip()
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    raise SystemExit("Provide --instruction, --instruction-file, or stdin.")


def merge_role_overrides(
    config: dict[str, Any],
    role_overrides: str | None,
) -> dict[str, Any]:
    roles = dict(config["roles"])
    if not role_overrides:
        return roles

    overrides = json.loads(role_overrides)
    for role, value in overrides.items():
        if isinstance(value, str):
            existing = dict(roles.get(role, {}))
            existing["provider"] = value
            roles[role] = existing
        elif isinstance(value, dict):
            existing = dict(roles.get(role, {}))
            existing.update(value)
            roles[role] = existing
        else:
            raise SystemExit(f"Invalid role override for {role}: {value!r}")
    return roles


def resolve_model(config: dict[str, Any], role_config: dict[str, Any]) -> str:
    provider = role_config["provider"]
    profile = role_config.get("model_profile", "balanced")
    profile_models = config["model_profiles"].get(profile)
    if not profile_models:
        raise SystemExit(f"Unknown model profile: {profile}")
    model = role_config.get("model") or profile_models.get(provider)
    if not model:
        raise SystemExit(f"No model configured for provider={provider} profile={profile}")
    return model


def resolve_schema_refs(schema: Any, schema_dir: Path) -> Any:
    if isinstance(schema, dict):
        ref = schema.get("$ref")
        if ref and not ref.startswith("#"):
            return resolve_schema_refs(load_json(schema_dir / ref), schema_dir)
        return {key: resolve_schema_refs(value, schema_dir) for key, value in schema.items()}
    if isinstance(schema, list):
        return [resolve_schema_refs(item, schema_dir) for item in schema]
    return schema


def render_template(template_path: Path, values: dict[str, str]) -> str:
    rendered = read_text(template_path)
    for key, value in values.items():
        rendered = rendered.replace("{" + key + "}", value)
    return rendered


def transcript_text(session_dir: Path) -> str:
    transcript = session_dir / "transcript.md"
    if not transcript.exists():
        return "(no prior turns)"
    content = read_text(transcript).strip()
    return content or "(no prior turns)"


def current_diff(repo: Path) -> str:
    if not (repo / ".git").exists():
        return "(repository has no .git directory; diff unavailable)"

    command = ["git", "-C", str(repo), "diff", "--"]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return f"(git diff failed)\n{result.stderr.strip()}"
    return result.stdout.strip() or "(no diff)"


def compact_current_diff(repo: Path, limit: int = 40000) -> str:
    return compact_json(current_diff(repo), limit)


def command_from_template(
    command: str,
    args: list[str],
    values: dict[str, str],
) -> list[str]:
    rendered = [command]
    for arg in args:
        rendered.append(arg.format(**values))
    return rendered


def extract_json_object(text: str) -> Any:
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    first = stripped.find("{")
    last = stripped.rfind("}")
    if first == -1 or last == -1 or first >= last:
        return None
    try:
        return json.loads(stripped[first : last + 1])
    except json.JSONDecodeError:
        return None


def normalize_parsed_output(parsed: Any) -> Any:
    if not isinstance(parsed, dict):
        return parsed

    structured_output = parsed.get("structured_output")
    if isinstance(structured_output, dict):
        return normalize_parsed_output(structured_output)

    response = parsed.get("response")
    if isinstance(response, dict):
        return normalize_parsed_output(response)
    if isinstance(response, str):
        nested = extract_json_object(response)
        if nested is not None:
            return normalize_parsed_output(nested)

    result = parsed.get("result")
    if isinstance(result, str):
        nested = extract_json_object(result)
        if nested is not None:
            return normalize_parsed_output(nested)
    normalize_consensus_contract(parsed)
    return parsed


def normalize_consensus_contract(parsed: dict[str, Any]) -> None:
    contract = parsed.get("consensus_contract")
    if not isinstance(contract, dict):
        return

    strategy = contract.get("implementation_strategy")
    if not isinstance(strategy, dict):
        return

    for key in [
        "task_plan",
        "remote_log_plan",
        "required_tests",
        "required_docs",
        "review_focus",
    ]:
        if key not in strategy and key in contract:
            strategy[key] = contract[key]


def run_provider(
    *,
    config: dict[str, Any],
    session_dir: Path,
    repo: Path,
    turn: int,
    phase: dict[str, Any],
    role_config: dict[str, Any],
    prompt: str,
    schema: dict[str, Any],
    execute: bool,
    timeout: int,
) -> dict[str, Any]:
    provider_name = role_config["provider"]
    provider = config["providers"][provider_name]
    mode = phase["mode"]
    model = resolve_model(config, role_config)

    output_last_message = session_dir / "outputs" / f"{turn:02d}-{phase['name']}.last.md"
    schema_file = session_dir / "schemas" / f"{turn:02d}-{phase['name']}.schema.json"
    write_json(schema_file, schema)

    values = {
        "repo": str(repo),
        "schema_file": str(schema_file),
        "schema_inline": json.dumps(schema),
        "output_last_message": str(output_last_message),
        "model": model,
        "prompt": prompt,
    }
    command = command_from_template(provider["command"], provider["modes"][mode], values)

    command_record = {
        "provider": provider_name,
        "model": model,
        "mode": mode,
        "command": command,
    }

    if not execute:
        return {
            "status": "prepared",
            "command": command_record,
            "stdout": "",
            "stderr": "",
            "parsed": None,
            "returncode": None,
        }

    if not shutil.which(provider["command"]):
        return {
            "status": "missing_command",
            "command": command_record,
            "stdout": "",
            "stderr": f"Command not found: {provider['command']}",
            "parsed": None,
            "returncode": 127,
        }

    prompt_delivery = provider.get("prompt_delivery", "arg")
    stdin = prompt if prompt_delivery == "stdin" else None
    try:
        result = subprocess.run(
            command,
            input=stdin,
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        timeout_message = f"Command timed out after {timeout} seconds"
        return {
            "status": "failed",
            "command": command_record,
            "stdout": stdout,
            "stderr": "\n".join(part for part in [stderr, timeout_message] if part),
            "parsed": None,
            "returncode": None,
        }
    except OSError as error:
        return {
            "status": "failed",
            "command": command_record,
            "stdout": "",
            "stderr": f"Failed to launch {provider['command']}: {error}",
            "parsed": None,
            "returncode": None,
        }
    combined_output = "\n".join(part for part in [result.stdout, result.stderr] if part)
    parsed = normalize_parsed_output(
        extract_json_object(result.stdout) or extract_json_object(combined_output)
    )

    return {
        "status": "completed" if result.returncode == 0 else "failed",
        "command": command_record,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "parsed": parsed,
        "returncode": result.returncode,
    }


def default_model_routing(config: dict[str, Any], provider: str) -> dict[str, str]:
    profiles = config["model_profiles"]
    return {
        "code_search_summary": profiles["cheap_fast"][provider],
        "docs_update": profiles["cheap_fast"][provider],
        "mechanical_edits": profiles["cheap_fast"][provider],
        "test_generation": profiles["balanced"][provider],
        "normal_implementation": profiles["balanced"][provider],
        "architecture_sensitive_code": profiles["deep"][provider],
        "security_or_tenancy_review": profiles["deep"][provider],
        "schema_or_migration": profiles["deep"][provider],
    }


def compact_json(value: Any, limit: int = 1600) -> str:
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, indent=2, sort_keys=True)
    if len(text) <= limit:
        return text
    return text[: limit - 20].rstrip() + "\n... [truncated]"


def latest_phase_parsed(session_dir: Path, phase_name: str) -> dict[str, Any] | None:
    latest: dict[str, Any] | None = None
    for event in load_transcript_events(session_dir):
        if event.get("phase") != phase_name:
            continue
        parsed = event.get("parsed")
        if isinstance(parsed, dict):
            latest = parsed
    return latest


def latest_phase_parsed_matching(session_dir: Path, phase_prefix: str) -> dict[str, Any] | None:
    latest: dict[str, Any] | None = None
    for event in load_transcript_events(session_dir):
        phase = event.get("phase")
        if not isinstance(phase, str) or not phase.startswith(phase_prefix):
            continue
        parsed = event.get("parsed")
        if isinstance(parsed, dict):
            latest = parsed
    return latest


def latest_architecture_parsed(session_dir: Path) -> dict[str, Any] | None:
    latest: dict[str, Any] | None = None
    for event in load_transcript_events(session_dir):
        phase = event.get("phase")
        if phase != "architecture" and not (
            isinstance(phase, str) and phase.startswith("architecture_revision")
        ):
            continue
        parsed = event.get("parsed")
        if isinstance(parsed, dict):
            latest = parsed
    return latest


def latest_verification_remediation_brief(session_dir: Path) -> str:
    verification = latest_phase_parsed(session_dir, "evidence_verification")
    if not verification:
        return "(no prior evidence verification blockers)"

    blockers = verification_blockers(verification)
    if not blockers:
        return "(latest evidence verification accepted; no remediation brief)"

    lines = [
        "# Mandatory Verifier Remediation Brief",
        "",
        "The latest Evidence Verifier blocked signoff. The next implementation pass must "
        "resolve these items by editing the relevant code/docs/artifacts or by downgrading "
        "unsupported claims so they no longer overstate the evidence.",
        "",
        "Do not treat these as optional review comments. Do not move them to unresolved "
        "issues when a file can be corrected.",
        "",
        "## Coordinator Blockers",
    ]
    lines.extend(f"- {blocker}" for blocker in blockers)

    for key, heading in [
        ("required_revisions", "Required Revisions"),
        ("failed_findings", "Failed Findings"),
        ("missing_evidence", "Missing Evidence"),
        ("register_inconsistencies", "Register Inconsistencies"),
    ]:
        values = verification.get(key)
        if isinstance(values, list) and values:
            lines.extend(["", f"## {heading}"])
            for index, value in enumerate(values, start=1):
                lines.append(f"{index}. {compact_json(value)}")

    assertion_checks = verification.get("assertion_checks")
    failed_checks = []
    if isinstance(assertion_checks, list):
        failed_checks = [
            check
            for check in assertion_checks
            if isinstance(check, dict) and check.get("verdict") in {"fail", "partial"}
        ]
    if failed_checks:
        lines.extend(["", "## Failed Or Partial Assertion Checks"])
        for index, check in enumerate(failed_checks, start=1):
            lines.append(f"{index}. `{check.get('finding_id', 'unknown')}`: {check.get('verdict')}")
            for field in ["artifact", "claim", "reason"]:
                if check.get(field):
                    lines.append(f"   - {field}: {compact_json(check[field], 2200)}")

    lines.extend(
        [
            "",
            "## Required Implementer Output",
            "- List every required revision above and the concrete file/code/doc change that resolves it.",
            "- If evidence is unavailable, change the underlying claim/status to say so explicitly.",
            "- If the verifier is wrong, cite the exact code/docs/evidence proving why.",
        ]
    )
    return "\n".join(lines)


def implementation_transcript_text(session_dir: Path) -> str:
    sections = [
        "# Compact Implementation Context",
        "",
        "Full transcript is intentionally omitted for implementation phases. Use the latest "
        "architecture, critique, consensus contract, implementation result, verifier result, "
        "review result, and current diff instead of re-reading the whole session.",
    ]

    for title, parsed in [
        ("Latest Architecture", latest_architecture_parsed(session_dir)),
        ("Latest Critique", latest_phase_parsed_matching(session_dir, "architecture_critique")),
        ("Latest Consensus", latest_phase_parsed(session_dir, "consensus_moderation")),
        ("Latest Implementation", latest_phase_parsed(session_dir, "implementation")),
        ("Latest Evidence Verification", latest_phase_parsed(session_dir, "evidence_verification")),
        ("Latest Review", latest_phase_parsed_matching(session_dir, "implementation_review")),
    ]:
        if parsed:
            sections.extend(["", f"## {title}", "```json", compact_json(parsed, 20000), "```"])

    return "\n".join(sections)


def review_moderation_transcript_text(session_dir: Path) -> str:
    sections = [
        "# Compact Review Moderation Context",
        "",
        "Full transcript is intentionally omitted for chair review moderation. Decide from "
        "the latest consensus, implementation, evidence verification, implementation review, "
        "and current diff summary.",
    ]

    for title, parsed, limit in [
        ("Latest Consensus", latest_phase_parsed(session_dir, "consensus_moderation"), 18000),
        ("Latest Implementation", latest_phase_parsed(session_dir, "implementation"), 18000),
        ("Latest Evidence Verification", latest_phase_parsed(session_dir, "evidence_verification"), 22000),
        (
            "Latest Implementation Review",
            latest_phase_parsed_matching(session_dir, "implementation_review"),
            36000,
        ),
    ]:
        if parsed:
            sections.extend(["", f"## {title}", "```json", compact_json(parsed, limit), "```"])

    return "\n".join(sections)


def phase_values(
    *,
    config: dict[str, Any],
    session_dir: Path,
    repo: Path,
    workflow: str,
    task_type: str,
    instruction: str,
    role_config: dict[str, Any],
) -> dict[str, str]:
    provider = role_config["provider"]
    max_subagents = role_config.get("max_subagents", 0)
    max_subagent_context_tokens = role_config.get("max_subagent_context_tokens", 200000)
    model_routing = default_model_routing(config, provider)
    return {
        "repo": str(repo),
        "workflow": workflow,
        "task_type": task_type,
        "instruction": instruction,
        "transcript": transcript_text(session_dir),
        "remediation_brief": latest_verification_remediation_brief(session_dir),
        "diff": current_diff(repo),
        "max_subagents": str(max_subagents),
        "max_subagent_context_tokens": str(max_subagent_context_tokens),
        "model_routing": json.dumps(model_routing, indent=2, sort_keys=True),
        "shared_dir": config.get("shared_dir", ""),
    }


def record_turn(
    *,
    session_dir: Path,
    turn: int,
    phase: dict[str, Any],
    role: str,
    role_config: dict[str, Any],
    result: dict[str, Any],
) -> None:
    event = {
        "created_at": now_iso(),
        "turn": turn,
        "phase": phase["name"],
        "role": role,
        "provider": role_config["provider"],
        "model_profile": role_config.get("model_profile", "balanced"),
        "status": result["status"],
        "returncode": result["returncode"],
        "parsed": result["parsed"],
        "stderr": result["stderr"],
        "command": result["command"],
    }
    append_jsonl(session_dir / "transcript.jsonl", event)

    markdown = [
        f"\n## Turn {turn}: {phase['name']}\n\n",
        f"- Role: `{role}`\n",
        f"- Provider: `{role_config['provider']}`\n",
        f"- Model profile: `{role_config.get('model_profile', 'balanced')}`\n",
        f"- Status: `{result['status']}`\n\n",
    ]
    if result["parsed"] is not None:
        markdown.extend(["```json\n", json.dumps(result["parsed"], indent=2), "\n```\n"])
    elif result["stdout"]:
        markdown.extend(["```text\n", result["stdout"].strip(), "\n```\n"])
    elif result["stderr"]:
        markdown.extend(["```text\n", result["stderr"].strip(), "\n```\n"])
    else:
        markdown.append("_Prepared only; not executed._\n")
    append_text(session_dir / "transcript.md", "".join(markdown))


def record_user_guidance(
    *,
    session_dir: Path,
    turn: int,
    reason: str,
    blockers: list[str],
    guidance: str,
) -> None:
    append_jsonl(
        session_dir / "transcript.jsonl",
        {
            "created_at": now_iso(),
            "turn": turn,
            "phase": "user_guidance",
            "role": "user",
            "provider": "user",
            "reason": reason,
            "blockers": blockers,
            "content": guidance,
        },
    )
    append_text(
        session_dir / "transcript.md",
        "\n## User Guidance\n\n"
        f"- Reason: {reason}\n"
        f"- Blockers: {json.dumps(blockers)}\n\n"
        f"{guidance}\n",
    )


def maybe_write_contract(session_dir: Path, turn: int, phase_name: str, parsed: Any) -> None:
    if not isinstance(parsed, dict):
        return
    contract = parsed.get("consensus_contract")
    if isinstance(contract, dict):
        write_json(session_dir / "contracts" / f"{turn:02d}-{phase_name}.json", contract)


def should_stop_after_phase(phase_name: str, parsed: Any) -> bool:
    if not isinstance(parsed, dict):
        return False
    decision = parsed.get("decision")
    if phase_name == "consensus_moderation" and decision != "proceed":
        return True
    if phase_name == "review_moderation" and decision in {"ask_user", "stop"}:
        return True
    return False


def verification_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    blockers: list[str] = []
    decision = parsed.get("decision")
    if decision and decision != "accept":
        blockers.append(f"verification decision is {decision}")

    for key in ["failed_findings", "required_revisions"]:
        values = parsed.get(key)
        if isinstance(values, list) and values:
            blockers.append(f"{key} has {len(values)} item(s)")

    if decision != "accept":
        for key in ["missing_evidence", "register_inconsistencies"]:
            values = parsed.get(key)
            if isinstance(values, list) and values:
                blockers.append(f"{key} has {len(values)} item(s)")

    assertion_checks = parsed.get("assertion_checks")
    if isinstance(assertion_checks, list):
        failed_checks = [
            check
            for check in assertion_checks
            if isinstance(check, dict) and check.get("verdict") in {"fail", "partial"}
        ]
        if failed_checks:
            blockers.append(f"assertion_checks has {len(failed_checks)} fail/partial item(s)")

    return blockers


def consensus_plan_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    contract = parsed.get("consensus_contract")
    if not isinstance(contract, dict):
        return ["missing consensus_contract"]

    open_disagreements = contract.get("open_disagreements")
    if isinstance(open_disagreements, list) and open_disagreements:
        return [f"open_disagreements has {len(open_disagreements)} item(s)"]

    strategy = contract.get("implementation_strategy")
    if not isinstance(strategy, dict):
        return ["missing implementation_strategy"]

    task_plan = strategy.get("task_plan")
    if not isinstance(task_plan, list) or not task_plan:
        return ["implementation_strategy.task_plan is missing or empty"]

    required_fields = {
        "task_id",
        "objective",
        "task_class",
        "effort_estimate",
        "risk_class",
        "recommended_model_profile",
        "context_budget_tokens",
        "subagent_suitable",
        "expected_files_or_subsystems",
        "dependencies",
        "required_tests",
        "required_docs",
    }
    blockers: list[str] = []
    for index, task in enumerate(task_plan, start=1):
        if not isinstance(task, dict):
            blockers.append(f"task_plan[{index}] is not an object")
            continue
        task_id = task.get("task_id") or f"#{index}"
        missing = sorted(field for field in required_fields if field not in task)
        if missing:
            blockers.append(f"{task_id} missing fields: {', '.join(missing)}")
        context_budget = task.get("context_budget_tokens")
        if not isinstance(context_budget, int):
            blockers.append(f"{task_id} context_budget_tokens is not an integer")
        elif context_budget > 200000:
            blockers.append(f"{task_id} context_budget_tokens exceeds 200000")

    return blockers


def bug_log_plan_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    contract = parsed.get("consensus_contract")
    if not isinstance(contract, dict):
        return ["missing consensus_contract"]
    strategy = contract.get("implementation_strategy")
    if not isinstance(strategy, dict):
        return ["missing implementation_strategy"]
    remote_log_plan = strategy.get("remote_log_plan")
    if not isinstance(remote_log_plan, dict):
        return ["missing implementation_strategy.remote_log_plan"]

    required = remote_log_plan.get("required")
    reason = remote_log_plan.get("reason")
    sources = remote_log_plan.get("sources_to_check")
    blockers: list[str] = []
    if required is True and not sources:
        blockers.append("remote_log_plan is required but sources_to_check is empty")
    if required is False and not reason:
        blockers.append("remote_log_plan is not required but reason is empty")
    if required not in {True, False}:
        blockers.append("remote_log_plan.required must be boolean")
    return blockers


def critic_agreement_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return ["critic output missing or unparsable"]

    blockers: list[str] = []
    decision = parsed.get("decision")
    plan_agreement = parsed.get("plan_agreement")
    if decision != "accept":
        blockers.append(f"critic decision is {decision}")
    if plan_agreement != "agree":
        blockers.append(f"critic plan_agreement is {plan_agreement}")
    return blockers


def implementation_report_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    blockers: list[str] = []
    unresolved_issues = parsed.get("unresolved_issues")
    if isinstance(unresolved_issues, list):
        permission_patterns = [
            "write permission",
            "write tool blocked",
            "write operations are blocked",
            "write operations denied",
            "blocked by permissions",
            "permission block",
        ]
        for issue in unresolved_issues:
            if not isinstance(issue, str):
                continue
            issue_lower = issue.lower()
            if any(pattern in issue_lower for pattern in permission_patterns):
                blockers.append("implementation reported write permission block")
                break

    subagents = parsed.get("subagents")
    if not isinstance(subagents, list):
        return blockers

    for index, subagent in enumerate(subagents, start=1):
        if not isinstance(subagent, dict):
            blockers.append(f"subagents[{index}] is not an object")
            continue
        context_budget = subagent.get("context_budget_tokens")
        if not isinstance(context_budget, int):
            blockers.append(f"subagents[{index}] missing integer context_budget_tokens")
        elif context_budget > 200000:
            blockers.append(f"subagents[{index}] context_budget_tokens exceeds 200000")
    return blockers


def bug_log_implementation_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    logs_checked = parsed.get("remote_logs_checked")
    if not isinstance(logs_checked, list) or not logs_checked:
        return ["remote_logs_checked is missing or empty"]
    if not any(isinstance(item, dict) and item.get("checked") is True for item in logs_checked):
        return ["remote_logs_checked has no checked=true source"]
    return []


def review_standard_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    standards_review = parsed.get("standards_review")
    if not isinstance(standards_review, dict):
        return ["missing standards_review"]

    required_checks = [
        "spec_checked",
        "coding_standard_checked",
        "ui_standard_checked",
        "definition_of_done_checked",
        "execution_philosophy_checked",
        "model_routing_checked",
        "context_budgets_checked",
    ]
    blockers = [
        f"standards_review.{field} is not true"
        for field in required_checks
        if standards_review.get(field) is not True
    ]
    return blockers


def bug_log_review_blockers(parsed: Any) -> list[str]:
    if not isinstance(parsed, dict):
        return []

    bug_log_review = parsed.get("bug_log_review")
    if not isinstance(bug_log_review, dict):
        return ["missing bug_log_review"]
    if bug_log_review.get("applicable") is True and bug_log_review.get("remote_logs_checked") is not True:
        return ["bug_log_review.remote_logs_checked is not true"]
    return []


def create_session(
    *,
    instruction: str,
    repo: Path,
    workflow: str,
    task_type: str,
    config: dict[str, Any],
    roles: dict[str, Any],
) -> Path:
    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    short_hash = instruction_hash(instruction)
    session_name = f"{timestamp}-{task_type}-{short_hash}"
    session_dir = TOOL_ROOT / "sessions" / session_name
    suffix = 2
    while session_dir.exists():
        session_dir = TOOL_ROOT / "sessions" / f"{session_name}-{suffix}"
        suffix += 1
    session_dir.mkdir(parents=True, exist_ok=False)
    for child in ["prompts", "outputs", "contracts", "diffs", "schemas"]:
        (session_dir / child).mkdir()

    (session_dir / "instruction.md").write_text(instruction + "\n", encoding="utf-8")
    write_json(
        session_dir / "metadata.json",
        {
            "created_at": now_iso(),
            "repo": str(repo),
            "workflow": workflow,
            "task_type": task_type,
            "instruction_title": instruction_title(instruction),
            "instruction_hash": short_hash,
        },
    )
    write_json(
        session_dir / "run_config.json",
        {
            "repo": str(repo),
            "workflow": workflow,
            "task_type": task_type,
            "roles": roles,
            "config": config,
            "created_at": now_iso(),
        },
    )
    append_text(
        session_dir / "transcript.md",
        f"# Agent Session: {session_dir.name}\n\n## Instruction\n\n{instruction}\n",
    )
    append_jsonl(
        session_dir / "transcript.jsonl",
        {
            "created_at": now_iso(),
            "turn": 0,
            "phase": "instruction",
            "role": "user",
            "provider": "user",
            "content": instruction,
        },
    )
    return session_dir


def load_transcript_events(session_dir: Path) -> list[dict[str, Any]]:
    transcript = session_dir / "transcript.jsonl"
    if not transcript.exists():
        return []

    events: list[dict[str, Any]] = []
    with transcript.open("r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def first_failed_event(session_dir: Path) -> dict[str, Any] | None:
    for event in load_transcript_events(session_dir):
        if event.get("status") == "failed":
            return event
    return None


def next_workflow_phase(session_dir: Path, phase_name: str) -> str | None:
    try:
        run_config = load_json(session_dir / "run_config.json")
        workflow_name = run_config["workflow"]
        phases = run_config["config"]["workflows"][workflow_name]["phases"]
    except (KeyError, FileNotFoundError, json.JSONDecodeError):
        return None

    phase_names = [phase.get("name") for phase in phases]
    if phase_name not in phase_names:
        return None
    index = phase_names.index(phase_name)
    if index + 1 >= len(phase_names):
        return None
    next_name = phase_names[index + 1]
    return str(next_name) if isinstance(next_name, str) else None


def transcript_event_by_turn(session_dir: Path, turn: int, phase_name: str) -> dict[str, Any] | None:
    for event in load_transcript_events(session_dir):
        if event.get("turn") == turn and event.get("phase") == phase_name:
            return event
    return None


def latest_transcript_event(session_dir: Path, phase_name: str) -> dict[str, Any] | None:
    latest: dict[str, Any] | None = None
    for event in load_transcript_events(session_dir):
        if event.get("phase") == phase_name:
            latest = event
    return latest


def retry_start_event(session_dir: Path) -> dict[str, Any] | None:
    failed_event = first_failed_event(session_dir)
    if failed_event:
        return failed_event

    contracts = session_dir / "contracts"
    if (contracts / "03-critic-agreement-blockers.json").exists():
        return {"phase": "consensus_moderation", "turn": 3}

    blocker_files = sorted(contracts.glob("*-critic-agreement-blockers.json"))
    if blocker_files:
        blocker_contract = load_json(blocker_files[-1])
        phase = blocker_contract.get("phase")
        if phase == "consensus_moderation":
            stem = blocker_files[-1].name.split("-", 1)[0]
            turn = int(stem) if stem.isdigit() else 3
            if turn > 3:
                return {"phase": "architecture_revision", "turn": turn}
            return {"phase": "consensus_moderation", "turn": 3}
        return {"phase": "architecture_critique", "turn": 2}

    phase_by_contract = [
        ("*-consensus-plan-blockers.json", "consensus_moderation"),
        ("*-implementation-blockers.json", "implementation"),
    ]
    for pattern, phase in phase_by_contract:
        matches = sorted(contracts.glob(pattern))
        if matches:
            stem = matches[-1].name.split("-", 1)[0]
            turn = int(stem) if stem.isdigit() else 1
            return {"phase": phase, "turn": turn}

    implementation_retry_contracts = [
        "*-verification-blockers.json",
        "*-review-standard-blockers.json",
    ]
    latest_verification_event = latest_transcript_event(session_dir, "evidence_verification")
    if latest_verification_event:
        parsed = latest_verification_event.get("parsed")
        latest_verification_turn = latest_verification_event.get("turn")
        if verification_blockers(parsed):
            turn = (
                int(latest_verification_turn)
                if isinstance(latest_verification_turn, int)
                else 1
            )
            return {"phase": "implementation", "turn": max(1, turn - 1)}

    for pattern in implementation_retry_contracts:
        matches = sorted(contracts.glob(pattern))
        if matches:
            if pattern == "*-verification-blockers.json" and latest_verification_event:
                continue
            stem = matches[-1].name.split("-", 1)[0]
            turn = int(stem) if stem.isdigit() else 1
            if pattern == "*-verification-blockers.json":
                event = transcript_event_by_turn(session_dir, turn, "evidence_verification")
                parsed = event.get("parsed") if event else None
                if not verification_blockers(parsed):
                    continue
            return {"phase": "implementation", "turn": max(1, turn - 1)}

    for event in reversed(load_transcript_events(session_dir)):
        if event.get("phase") != "evidence_verification":
            continue
        parsed = event.get("parsed")
        if verification_blockers(parsed):
            event_turn = event.get("turn")
            turn = int(event_turn) if isinstance(event_turn, int) else 1
            return {"phase": "implementation", "turn": max(1, turn - 1)}
        break

    completed_events = [
        event
        for event in load_transcript_events(session_dir)
        if event.get("status") == "completed" and isinstance(event.get("phase"), str)
    ]
    if completed_events:
        latest_completed = completed_events[-1]
        latest_phase = latest_completed.get("phase")
        if isinstance(latest_phase, str) and latest_phase.startswith("architecture_critique"):
            turn = latest_completed.get("turn")
            return {
                "phase": "consensus_moderation",
                "turn": int(turn) + 1 if isinstance(turn, int) else 3,
            }
        if isinstance(latest_phase, str):
            next_phase = next_workflow_phase(session_dir, latest_phase)
            if next_phase:
                turn = latest_completed.get("turn")
                return {
                    "phase": next_phase,
                    "turn": int(turn) if isinstance(turn, int) else 1,
                }
        return latest_completed
    return None


def create_retry_session(
    *,
    source_session: Path,
    config: dict[str, Any],
    refresh_config: bool,
    role_overrides: str | None = None,
) -> Path:
    source_config = load_json(source_session / "run_config.json")
    instruction = read_text(source_session / "instruction.md").strip()
    repo = Path(source_config["repo"]).expanduser().resolve()
    workflow = source_config["workflow"]
    task_type = source_config.get("task_type", workflow)
    roles = source_config["roles"]
    if refresh_config:
        source_role_overrides = {
            role: role_config
            for role, role_config in roles.items()
            if isinstance(role_config, dict)
        }
        roles = merge_role_overrides(config, json.dumps(source_role_overrides))
    else:
        config = source_config["config"]
    roles = merge_role_overrides({"roles": roles}, role_overrides)

    retry_dir = create_session(
        instruction=instruction,
        repo=repo,
        workflow=workflow,
        task_type=task_type,
        config=config,
        roles=roles,
    )
    retry_marker = retry_dir / "retry_of.txt"
    retry_marker.write_text(str(source_session) + "\n", encoding="utf-8")
    copy_file_if_exists(source_session / "transcript.md", retry_dir / "transcript.md")
    copy_file_if_exists(source_session / "transcript.jsonl", retry_dir / "transcript.jsonl")
    append_text(
        retry_dir / "transcript.md",
        f"\n## Retry\n\nRetry session created from `{source_session}` at {now_iso()}.\n",
    )
    append_jsonl(
        retry_dir / "transcript.jsonl",
        {
            "created_at": now_iso(),
            "phase": "retry",
            "provider": "coordinator",
            "role": "coordinator",
            "source_session": str(source_session),
            "refresh_config": refresh_config,
            "role_overrides": json.loads(role_overrides) if role_overrides else None,
        },
    )
    return retry_dir


def run_session(
    *,
    session_dir: Path,
    execute: bool,
    timeout: int,
    start_phase_name: str | None = None,
    initial_turn: int = 0,
    interactive_plan: bool = False,
    stop_after_phase: str | None = None,
) -> None:
    run_config = load_json(session_dir / "run_config.json")
    config = run_config["config"]
    roles = run_config["roles"]
    repo = Path(run_config["repo"]).expanduser().resolve()
    workflow_name = run_config["workflow"]
    task_type = run_config.get("task_type", workflow_name)
    instruction = read_text(session_dir / "instruction.md").strip()
    workflow = config["workflows"][workflow_name]
    schema_dir = TOOL_ROOT / "schemas"
    latest_verification_blockers: list[str] = []
    latest_review_standard_blockers: list[str] = []
    latest_critic_agreement_blockers: list[str] = []
    total_phases = len(workflow["phases"])
    turn = initial_turn

    print_status(f"Session: {session_dir}")
    print_status(f"Repo: {repo}")
    print_status(f"Workflow: {workflow_name}  Task type: {task_type}")

    def run_one_phase(turn: int, phase: dict[str, Any]) -> dict[str, Any]:
        role = phase["role"]
        role_config = roles[role]
        provider_name = role_config["provider"]
        model = resolve_model(config, role_config)
        phase_label = f"[{turn}/{total_phases}] {phase['name']} ({role}: {provider_name}/{model})"
        action = "starting" if execute else "preparing"
        print_status(f"{phase_label}: {action}")
        started_at = time.monotonic()
        values = phase_values(
            config=config,
            session_dir=session_dir,
            repo=repo,
            workflow=workflow_name,
            task_type=task_type,
            instruction=instruction,
            role_config=role_config,
        )
        if phase["name"] == "implementation":
            values["transcript"] = implementation_transcript_text(session_dir)
        if phase["name"] == "review_moderation":
            values["transcript"] = review_moderation_transcript_text(session_dir)
            values["diff"] = compact_current_diff(repo)
        values["planning_round"] = str(phase.get("planning_round", 1))
        values["max_plan_rounds"] = str(workflow.get("max_plan_rounds", 1))
        values["review_round"] = str(phase.get("review_round", 1))
        values["max_review_rounds"] = str(workflow.get("max_review_rounds", 1))
        prompt = render_template(TOOL_ROOT / "prompts" / phase["prompt"], values)
        (session_dir / "prompts" / f"{turn:02d}-{phase['name']}.md").write_text(prompt, encoding="utf-8")

        raw_schema = load_json(schema_dir / phase["schema"])
        schema = resolve_schema_refs(raw_schema, schema_dir)
        result = run_provider(
            config=config,
            session_dir=session_dir,
            repo=repo,
            turn=turn,
            phase=phase,
            role_config=role_config,
            prompt=prompt,
            schema=schema,
            execute=execute,
            timeout=timeout,
        )

        output_base = session_dir / "outputs" / f"{turn:02d}-{phase['name']}"
        (output_base.with_suffix(".stdout.txt")).write_text(result["stdout"], encoding="utf-8")
        (output_base.with_suffix(".stderr.txt")).write_text(result["stderr"], encoding="utf-8")
        write_json(output_base.with_suffix(".result.json"), result)
        record_turn(
            session_dir=session_dir,
            turn=turn,
            phase=phase,
            role=role,
            role_config=role_config,
            result=result,
        )
        maybe_write_contract(session_dir, turn, phase["name"], result["parsed"])

        if phase["mode"] == "write":
            diff = current_diff(repo)
            (session_dir / "diffs" / f"{turn:02d}-{phase['name']}.diff").write_text(
                diff + "\n", encoding="utf-8",
            )

        if result["status"] == "failed":
            elapsed = time.monotonic() - started_at
            print_status(f"{phase_label}: failed in {elapsed:.1f}s")
            raise SystemExit(f"Phase failed: {phase['name']} ({role})")
        elapsed = time.monotonic() - started_at
        print_status(f"{phase_label}: {result['status']} in {elapsed:.1f}s")
        return result

    def collect_user_guidance(reason: str, blockers: list[str]) -> str:
        if not sys.stdin.isatty():
            raise SystemExit("Interactive planning requires a TTY for user guidance.")
        print_status("")
        print_status("Interactive planning pause")
        print_status(f"Reason: {reason}")
        if blockers:
            print_status("Blockers:")
            for blocker in blockers:
                print_status(f"- {blocker}")
        print_status(
            "Enter guidance for Chair re-analysis. This will not automatically force an "
            "Architect revision."
        )
        guidance = input("guidance> ").strip()
        return guidance or "(no additional guidance provided)"

    def write_blocker_contract(phase_name: str, kind: str, blockers: list[str]) -> None:
        write_json(
            session_dir / "contracts" / f"{turn:02d}-{kind}.json",
            {"phase": phase_name, "blockers": blockers, "created_at": now_iso()},
        )

    def enforce_implementation_checks(result: dict[str, Any], phase_name: str) -> None:
        blockers = implementation_report_blockers(result["parsed"])
        if task_type == "bug":
            blockers.extend(bug_log_implementation_blockers(result["parsed"]))
        if blockers:
            write_blocker_contract(phase_name, "implementation-blockers", blockers)
            raise SystemExit("Implementation report blocked review/signoff: " + "; ".join(blockers))

    def enforce_verification_checks(result: dict[str, Any], phase_name: str) -> None:
        nonlocal latest_verification_blockers
        latest_verification_blockers = verification_blockers(result["parsed"])
        if latest_verification_blockers:
            latest_verification_blockers = run_evidence_remediation_loop(latest_verification_blockers)
        if latest_verification_blockers:
            write_blocker_contract(phase_name, "verification-blockers", latest_verification_blockers)
            raise SystemExit(
                "Evidence verification blocked review/signoff: "
                + "; ".join(latest_verification_blockers)
            )

    def enforce_review_standard_checks(result: dict[str, Any], phase_name: str) -> None:
        nonlocal latest_review_standard_blockers
        latest_review_standard_blockers = review_standard_blockers(result["parsed"])
        if task_type == "bug":
            latest_review_standard_blockers.extend(bug_log_review_blockers(result["parsed"]))
        if latest_review_standard_blockers:
            write_blocker_contract(phase_name, "review-standard-blockers", latest_review_standard_blockers)
            raise SystemExit(
                "Review blocked signoff on standards coverage: "
                + "; ".join(latest_review_standard_blockers)
            )

    def run_evidence_remediation_loop(blockers: list[str]) -> list[str]:
        nonlocal turn
        latest_blockers = blockers
        for remediation_round in range(1, max_review_rounds + 1):
            print_status(
                "Evidence verification requires remediation: "
                + "; ".join(latest_blockers)
                + f" (round {remediation_round}/{max_review_rounds})"
            )
            turn += 1
            enforce_implementation_checks(
                run_one_phase(turn, phase_by_name["implementation"]), "implementation"
            )
            turn += 1
            latest_blockers = verification_blockers(
                run_one_phase(turn, phase_by_name["evidence_verification"])["parsed"]
            )
            if not latest_blockers:
                return []
        return latest_blockers

    def run_planning_revision_loop(
        initial_blockers: list[str],
        start_round: int,
        arch_phase: dict[str, Any],
        critique_phase: dict[str, Any],
        revision_label: str,
        critique_label: str,
        fixed_planning_round: int | None = None,
    ) -> tuple[int, list[str]]:
        """Run Architect/Critic revision rounds until agreement or max_plan_rounds.
        Returns (final_round, remaining_blockers)."""
        nonlocal turn
        latest_blockers = initial_blockers
        current_round = start_round
        while latest_blockers and current_round < max_plan_rounds:
            current_round += 1
            planning_round = fixed_planning_round if fixed_planning_round is not None else current_round
            print_status(
                "Plan revision required: "
                + "; ".join(latest_blockers)
                + f" (round {planning_round}/{max_plan_rounds})"
            )
            turn += 1
            run_one_phase(turn, {
                "name": f"{revision_label}_{current_round}",
                "role": "architect",
                "mode": arch_phase["mode"],
                "prompt": arch_phase["prompt"],
                "schema": arch_phase["schema"],
                "planning_round": planning_round,
            })
            turn += 1
            critique_result = run_one_phase(turn, {
                "name": f"{critique_label}_{current_round}",
                "role": "critic",
                "mode": critique_phase["mode"],
                "prompt": critique_phase["prompt"],
                "schema": critique_phase["schema"],
                "planning_round": planning_round,
            })
            latest_blockers = (
                [] if critique_result["status"] == "prepared"
                else critic_agreement_blockers(critique_result["parsed"])
            )
        return current_round, latest_blockers

    phases = workflow["phases"]
    phase_by_name = {phase["name"]: phase for phase in phases}
    review_loop_names = set(
        workflow.get(
            "review_loop_phases",
            ["implementation", "implementation_review", "review_moderation"],
        )
    )
    plan_rounds = 1
    review_rounds = 0
    max_plan_rounds = int(workflow.get("max_plan_rounds", 1))
    max_review_rounds = int(workflow.get("max_review_rounds", 1))

    start_index = 0
    if start_phase_name == "architecture_revision":
        start_index = next(
            (i for i, p in enumerate(phases) if p["name"] == "consensus_moderation"), -1
        )
        if start_index == -1:
            raise SystemExit("Cannot retry architecture revision without consensus_moderation phase")

        if not interactive_plan:
            _, latest_critic_agreement_blockers = run_planning_revision_loop(
                initial_blockers=["retrying from latest critic feedback"],
                start_round=0,
                arch_phase=phase_by_name["architecture"],
                critique_phase=phase_by_name["architecture_critique"],
                revision_label="architecture_revision_retry",
                critique_label="architecture_critique_retry",
                fixed_planning_round=max_plan_rounds,
            )
            if latest_critic_agreement_blockers:
                write_blocker_contract(
                    "architecture_critique", "critic-agreement-blockers", latest_critic_agreement_blockers
                )
                raise SystemExit(
                    "Plan agreement blocked consensus after retry revision rounds: "
                    + "; ".join(latest_critic_agreement_blockers)
                )
    elif start_phase_name:
        start_index = next(
            (i for i, p in enumerate(phases) if p["name"] == start_phase_name), -1
        )
        if start_index == -1:
            raise SystemExit(f"Cannot retry unknown phase: {start_phase_name}")

    for phase in phases[start_index:]:
        if phase["name"] in review_loop_names and review_rounds > 0:
            continue

        turn += 1
        result = run_one_phase(turn, phase)
        enforce = result["status"] != "prepared"

        if enforce and phase["name"] == "architecture_critique":
            latest_critic_agreement_blockers = critic_agreement_blockers(result["parsed"])
            if latest_critic_agreement_blockers and not interactive_plan:
                plan_rounds, latest_critic_agreement_blockers = run_planning_revision_loop(
                    initial_blockers=latest_critic_agreement_blockers,
                    start_round=plan_rounds,
                    arch_phase=phase_by_name["architecture"],
                    critique_phase=phase,
                    revision_label="architecture_revision",
                    critique_label="architecture_critique_round",
                )

        if enforce and phase["name"] == "consensus_moderation":
            interactive_reanalysis_used = False

            def run_interactive_reanalysis(reason: str, ia_blockers: list[str]) -> dict[str, Any]:
                nonlocal turn, interactive_reanalysis_used
                if interactive_reanalysis_used:
                    raise SystemExit(reason + ": " + "; ".join(ia_blockers))
                interactive_reanalysis_used = True
                guidance = collect_user_guidance(reason, ia_blockers)
                record_user_guidance(
                    session_dir=session_dir,
                    turn=turn,
                    reason=reason,
                    blockers=ia_blockers,
                    guidance=guidance,
                )
                turn += 1
                return run_one_phase(turn, {
                    "name": "consensus_reanalysis",
                    "role": "chair",
                    "mode": phase["mode"],
                    "prompt": "chair-reanalysis.md",
                    "schema": phase["schema"],
                    "planning_round": phase.get("planning_round", 1),
                })

            if latest_critic_agreement_blockers:
                if interactive_plan:
                    result = run_interactive_reanalysis(
                        "Architect/Critic agreement is missing", latest_critic_agreement_blockers
                    )
                    enforce = result["status"] != "prepared"
                    latest_critic_agreement_blockers = []
                else:
                    write_blocker_contract(
                        phase["name"], "critic-agreement-blockers", latest_critic_agreement_blockers
                    )
                    raise SystemExit(
                        "Consensus blocked because Architect/Critic agreement is missing: "
                        + "; ".join(latest_critic_agreement_blockers)
                    )

            if enforce and should_stop_after_phase("consensus_moderation", result["parsed"]):
                parsed = result["parsed"] if isinstance(result["parsed"], dict) else {}
                decision = parsed.get("decision")
                blocker_list = parsed.get("blocking_issues") or []
                if interactive_plan and decision in {"revise", "ask_user"}:
                    result = run_interactive_reanalysis(
                        f"Chair decision is {decision}", [str(b) for b in blocker_list]
                    )
                    enforce = result["status"] != "prepared"
                else:
                    break

            plan_blockers = consensus_plan_blockers(result["parsed"])
            if task_type == "bug":
                plan_blockers.extend(bug_log_plan_blockers(result["parsed"]))
            if plan_blockers:
                if interactive_plan:
                    result = run_interactive_reanalysis(
                        "Consensus contract failed coordinator validation", plan_blockers
                    )
                    enforce = result["status"] != "prepared"
                    plan_blockers = consensus_plan_blockers(result["parsed"])
                    if task_type == "bug":
                        plan_blockers.extend(bug_log_plan_blockers(result["parsed"]))
                    if not plan_blockers:
                        continue
                write_blocker_contract(phase["name"], "consensus-plan-blockers", plan_blockers)
                raise SystemExit("Consensus plan blocked implementation: " + "; ".join(plan_blockers))

        if enforce and phase["name"] == "implementation":
            enforce_implementation_checks(result, phase["name"])

        if stop_after_phase and phase["name"] == stop_after_phase:
            print_status(f"Stopping after requested phase: {stop_after_phase}")
            break

        if enforce and phase["name"] == "evidence_verification":
            enforce_verification_checks(result, phase["name"])

        if enforce and phase["name"] == "implementation_review":
            enforce_review_standard_checks(result, phase["name"])

        if should_stop_after_phase(phase["name"], result["parsed"]):
            break

        if phase["name"] != "review_moderation":
            continue

        if latest_verification_blockers:
            raise SystemExit(
                "Review moderation cannot sign off with unresolved verification blockers: "
                + "; ".join(latest_verification_blockers)
            )
        if latest_review_standard_blockers:
            raise SystemExit(
                "Review moderation cannot sign off with unresolved standards blockers: "
                + "; ".join(latest_review_standard_blockers)
            )

        review_rounds += 1
        parsed = result["parsed"] if isinstance(result["parsed"], dict) else {}
        decision = parsed.get("decision")
        while decision == "revise" and review_rounds < max_review_rounds:
            for loop_phase_name in workflow.get(
                "review_loop_phases",
                ["implementation", "implementation_review", "review_moderation"],
            ):
                loop_phase = {**phase_by_name[loop_phase_name], "review_round": review_rounds + 1}
                turn += 1
                loop_result = run_one_phase(turn, loop_phase)
                enforce_loop = loop_result["status"] != "prepared"

                if enforce_loop and loop_phase_name == "implementation":
                    enforce_implementation_checks(loop_result, loop_phase_name)
                if enforce_loop and loop_phase_name == "evidence_verification":
                    enforce_verification_checks(loop_result, loop_phase_name)
                if enforce_loop and loop_phase_name == "implementation_review":
                    enforce_review_standard_checks(loop_result, loop_phase_name)

                if loop_phase_name == "review_moderation":
                    review_rounds += 1
                    loop_parsed = loop_result["parsed"] if isinstance(loop_result["parsed"], dict) else {}
                    decision = loop_parsed.get("decision")
                if should_stop_after_phase(loop_phase_name, loop_result["parsed"]):
                    return


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a provider-agnostic agent loop.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Create and run a new instruction session.")
    run_parser.add_argument("--repo", required=True, help="Target repository path.")
    run_parser.add_argument("--instruction", help="Instruction text.")
    run_parser.add_argument("--instruction-file", help="Path to instruction markdown.")
    run_parser.add_argument(
        "--task-type",
        choices=["audit", "bug", "implement"],
        help="Task type. Selects the workflow unless --workflow is provided.",
    )
    run_parser.add_argument("--workflow", help="Workflow name from config.")
    run_parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="Config JSON path.")
    run_parser.add_argument("--roles", help="JSON role overrides.")
    run_parser.add_argument("--execute", action="store_true", help="Launch configured agent CLIs.")
    run_parser.add_argument(
        "--interactive-plan",
        action="store_true",
        help="Pause for user guidance when planning consensus is blocked.",
    )
    run_parser.add_argument(
        "--stop-after-phase",
        help="Stop after this phase completes successfully.",
    )
    run_parser.add_argument("--timeout", type=int, default=3600, help="Per-phase timeout seconds.")

    resume_parser = subparsers.add_parser("resume", help="Resume an existing session folder.")
    resume_parser.add_argument("session", help="Session directory.")
    resume_parser.add_argument("--execute", action="store_true", help="Launch configured agent CLIs.")
    resume_parser.add_argument(
        "--interactive-plan",
        action="store_true",
        help="Pause for user guidance when planning consensus is blocked.",
    )
    resume_parser.add_argument(
        "--stop-after-phase",
        help="Stop after this phase completes successfully.",
    )
    resume_parser.add_argument("--timeout", type=int, default=3600, help="Per-phase timeout seconds.")

    retry_parser = subparsers.add_parser("retry", help="Retry a failed session in a new session folder.")
    retry_parser.add_argument("session", help="Failed session directory.")
    retry_parser.add_argument(
        "--from-failed",
        action="store_true",
        help="Start from the first failed phase in the source session.",
    )
    retry_parser.add_argument(
        "--refresh-config",
        action="store_true",
        help="Use current config.json while preserving role overrides from the source session.",
    )
    retry_parser.add_argument(
        "--from-phase",
        help="Override retry start phase. Useful after prompt/policy fixes.",
    )
    retry_parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="Config JSON path.")
    retry_parser.add_argument("--roles", help="JSON role overrides for this retry.")
    retry_parser.add_argument("--execute", action="store_true", help="Launch configured agent CLIs.")
    retry_parser.add_argument(
        "--interactive-plan",
        action="store_true",
        help="Pause for user guidance when planning consensus is blocked.",
    )
    retry_parser.add_argument(
        "--stop-after-phase",
        help="Stop after this phase completes successfully.",
    )
    retry_parser.add_argument(
        "--no-verify",
        action="store_true",
        help="Shortcut for --stop-after-phase implementation.",
    )
    retry_parser.add_argument("--timeout", type=int, default=3600, help="Per-phase timeout seconds.")

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "run":
        config_path = Path(args.config).expanduser().resolve()
        config = load_json(config_path)
        task_type = args.task_type or config.get("default_task_type", "implement")
        task_config = config.get("task_types", {}).get(task_type)
        if not task_config:
            raise SystemExit(f"Unknown task type: {task_type}")
        workflow = args.workflow or task_config.get("workflow") or config["default_workflow"]
        if workflow not in config["workflows"]:
            raise SystemExit(f"Unknown workflow: {workflow}")
        roles = merge_role_overrides(config, args.roles)
        instruction = load_instruction(args)
        repo = Path(args.repo).expanduser().resolve()
        session_dir = create_session(
            instruction=instruction,
            repo=repo,
            workflow=workflow,
            task_type=task_type,
            config=config,
            roles=roles,
        )
        run_session(
            session_dir=session_dir,
            execute=args.execute,
            timeout=args.timeout,
            interactive_plan=args.interactive_plan,
            stop_after_phase=args.stop_after_phase,
        )
        print(session_dir)
        return

    if args.command == "resume":
        session_dir = Path(args.session).expanduser().resolve()
        if not (session_dir / "run_config.json").exists():
            raise SystemExit(f"Not an agent-orchestrator session: {session_dir}")
        run_session(
            session_dir=session_dir,
            execute=args.execute,
            timeout=args.timeout,
            interactive_plan=args.interactive_plan,
            stop_after_phase=args.stop_after_phase,
        )
        print(session_dir)
        return

    if args.command == "retry":
        source_session = Path(args.session).expanduser().resolve()
        if not (source_session / "run_config.json").exists():
            raise SystemExit(f"Not an agent-orchestrator session: {source_session}")
        start_event = retry_start_event(source_session) if args.from_failed else None
        if args.from_failed and not start_event:
            raise SystemExit(f"No failed or blocked phase found in session: {source_session}")
        start_phase_name = args.from_phase or (
            start_event.get("phase") if args.from_failed and start_event else None
        )
        initial_turn = int(start_event.get("turn", 0)) - 1 if start_event and not args.from_phase else 0
        if initial_turn < 0:
            initial_turn = 0
        config = load_json(Path(args.config).expanduser().resolve())
        retry_dir = create_retry_session(
            source_session=source_session,
            config=config,
            refresh_config=args.refresh_config,
            role_overrides=args.roles,
        )
        run_session(
            session_dir=retry_dir,
            execute=args.execute,
            timeout=args.timeout,
            start_phase_name=start_phase_name,
            initial_turn=initial_turn,
            interactive_plan=args.interactive_plan,
            stop_after_phase="implementation" if args.no_verify else args.stop_after_phase,
        )
        print(retry_dir)
        return

    raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
