# Shared Generic Launch-Readiness Job Instructions

You are running one bounded job from a generic launch-readiness audit.

Repo root: provided in the job prompt as `Repo root`.

Product profile: provided in the job prompt as `Product Profile`.

Rules:

1. The product profile defines the launch bar. If the profile is incomplete, infer from repo docs only when necessary and mark assumptions explicitly.
2. Do not assume any specific product/frontend/backend conventions unless the target repo or product profile explicitly supports them.
3. Find the repo's own architecture, functional, manual, API, deployment, and test documentation before judging readiness.
4. Every finding must cite code `file:line` and docs `path#heading` where applicable. If docs are missing, cite the search performed and mark the gap.
5. Discovery and synthesis jobs do not edit code and do not edit live docs. Runtime and simulation jobs may run commands required by the prompt and must write raw artifacts under `${RUN_DIR}/artifacts/<job_id>/`.
6. Keep context bounded. Use skeleton/context tools before opening large files. If the `mcp_lattice_*` tools are available, prioritize using them for discovery (`mcp_lattice_get_context_capsule`, `mcp_lattice_summarize_subsystem`), mapping (`mcp_lattice_get_dependencies`, `mcp_lattice_get_impact_graph`), and verification (`mcp_lattice_impact_from_diff`). Do not read the full repo or full master prompt blindly.
7. Prioritize launch-blocking P0/P1 findings over exhaustive coverage.
8. Security, data isolation, data integrity, admin/support access, destructive actions, privacy, and irreversible lifecycle flows are high-risk by default when present.
9. Browser or E2E evidence must prove authenticated/product state, not just HTTP 200 or shell rendering.
10. If the repo lacks a supported runtime harness for a critical launch journey, mark the journey unverified instead of inventing unsupported proof.

## Lattice Cognitive Workspace Protocol

Use Lattice memory and context tools when available. This is part of the harness contract, not optional polish.

- At the start of any non-trivial audit, remediation, verification, review, or feature task, call `get_task_memory` for the current repo, job/unit/task id, and objective before broad source exploration. If the MCP client defers schemas, first load the Lattice tool schemas for `get_task_memory`, `inspect_working_memory`, `save_memory`, `consolidate_session`, `propose_memory_evolution`, `verify_explain_memory`, `list_memory_conflicts`, `get_event_trace`, and `get_memory_metrics`.
- Use `get_context_capsule`, `prepare_change`, `diagnose_failure`, `summarize_subsystem`, `get_docs_capsule`, `find_relevant_tests`, and `impact_from_diff` instead of blind repo-wide reading when the tool is available and responsive.
- If a Lattice context call returns partial results because indexing is still warming, use the returned cached/partial context immediately and continue with targeted reads. Do not stall waiting for a perfect graph unless the task depends on exact graph completeness.
- Save durable, reusable outcomes with `save_memory` when you learn a repo-specific invariant, successful command, false lead, migration constraint, deployment detail, or recurring failure mode. Include validity conditions and invalidation triggers where the tool supports them.
- At task closeout, call `consolidate_session` when available so successful fixes, verified commands, and unresolved risks are discoverable in later sessions.
- Do not use memory as evidence by itself. Treat memory as a navigation and continuity aid, then verify claims against current code, docs, logs, tests, or artifacts.

Severity scale:

- **P0** - blocks launch: exploitable security issue, data loss, cross-boundary leak, broken core launch claim, regulatory/compliance blocker, or unrecoverable critical workflow.
- **P1** - must fix before GA: advertised feature gap, critical UX dead end, missing audit/control evidence, unsafe recovery path, or material docs/code mismatch.
- **P2** - should fix before GA: hardening, maintainability, non-critical workflow polish, test gaps with bounded risk.
- **P3** - post-launch acceptable: nice-to-have or future improvement that does not undermine launch claims.

Output discipline:

- Write the required report path for your job.
- End with `RESULT: PASS / FAIL / INCOMPLETE`.
- If blocked, list exact missing files, commands, credentials, or repo support needed.
