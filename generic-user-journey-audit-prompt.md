# Generic End-User Journey Audit

## UX PHASE 0 — Product and Evidence Contract

Establish the audit contract from the product profile and repository evidence. Identify target roles, promised outcomes, business objects, deployment URL, credential source, and any hard safety boundaries. Separate verified facts from inference. Define the usability standard: a target user should recognize where they are, understand the current business state, know the next valid action, and verify the resulting outcome without internal knowledge.

Write the product contract, evidence availability, assumptions, and blockers. Do not inventory every screen yet.

Return PASS when this contract artifact is complete. Browser journey evidence is intentionally produced later and its current absence is not a Phase 0 failure.

## UX PHASE 1A — Interface Inventory

Inventory the actual operator-facing application using route definitions, navigation, manuals, permissions, and the deployed UI. Map each surface to visible purpose, primary objects, available actions, roles, and entry points. Flag orphan routes, duplicate concepts, inconsistent vocabulary, hidden prerequisites, dead ends, and pages whose purpose cannot be inferred from their first viewport.

Produce a concise route-and-capability map suitable for planning browser journeys. Do not score visual taste.

Return PASS when the inventory is complete enough to plan journeys. Findings about the product belong in the report but do not make the discovery job itself fail.

## UX PHASE 1B — Journey Portfolio

Infer the smallest portfolio that covers the product's real work. Start from promised business outcomes and lifecycle state changes, not pages. Rank journeys by business criticality, frequency, financial or operational risk, and cross-surface complexity.

Include:
- frequent primary work;
- first-use or setup work;
- review, approval, and handoff work;
- exceptions, validation failures, and recovery;
- administration only where it changes another user's experience.

For each journey state the role, starting condition, user goal, observable completion outcome, likely route sequence, fixture needs, and why it belongs in the portfolio. Cap the executable portfolio at 12 journeys, selecting coverage rather than exhaustiveness.

Return PASS when the ranked portfolio is complete and traceable to the contract and discovered interface.

## UX PHASE 2 — Executable Journey Plan

Reconcile the interface inventory and journey portfolio into an executable plan. Allocate journey ids across the three execution jobs: primary work, exceptions, and administration. Every journey must be phrased as a user task without UI instructions. Define starting state, fixture strategy, completion oracle, prohibited shortcuts, evidence checkpoints, and cleanup expectations.

Create `$RUN_DIR/artifacts/journey-plan.tsv` with this exact header:

`journey_id<TAB>execution_job<TAB>role<TAB>priority<TAB>starting_state<TAB>task<TAB>completion_oracle<TAB>fixture_strategy`

The task must not disclose routes, button labels, or click sequences. A journey that cannot be executed safely must still be included and marked with its blocking dependency.

## UX PHASE 3A — Critical Primary Work

Execute every journey assigned to `03-primary-work` in the deployed UI with Playwright. Approach each task from the role's normal entry point, not a deep link unless that is the actual product entry. Do not read source code after execution begins to discover what to click.

Before using the browser, require `artifacts/browser-preflight/summary.md` to report PASS. Use the `playwright` MCP browser tools supplied to this job. Do not launch Chromium, system Chrome, Firefox, Playwright Node scripts, or CDP from shell commands. The MCP server already uses the repo-matched Chromium proven by preflight and stores its evidence under `artifacts/03-primary-work/playwright-mcp/`.

For each assigned journey, store evidence only under the lane-owned directory supplied in the prompt and write `trace.md` containing starting state, numbered user actions, visible system responses, decision points, completion evidence, console or request failures, fixture cleanup, and result: PASS, FAIL, BLOCKED, or UNVERIFIED. Write the required lane result manifest. Do not inspect or execute journeys allocated to another lane.

Evaluate orientation, comprehension, action clarity, effort, state continuity, feedback, and outcome verification. Report friction even when the task technically completes.

## UX PHASE 3B — Exceptions and Recovery

Execute every journey assigned to `03-exceptions` using the same evidence contract as Phase 3A. Exercise realistic invalid input, conflicts, denied permissions, empty states, dependency failure states available without destructive interference, cancellation, and retry or recovery.

Require the successful browser preflight and use only the supplied `playwright` MCP browser tools. Do not attempt browser launch from shell commands. MCP evidence is stored under `artifacts/03-exceptions/playwright-mcp/`.

Judge whether errors are specific, truthful, located near the problem, preserve entered work where appropriate, and provide a viable recovery action. A generic toast plus lost work is a failure even if the backend returned the correct status.

## UX PHASE 3C — Setup, Administration, and Handoffs

Execute every journey assigned to `03-administration` using the same evidence contract as Phase 3A. Focus on first-use configuration, role boundaries, lifecycle setup, cross-role handoffs, and whether downstream users receive enough context to act.

Require the successful browser preflight and use only the supplied `playwright` MCP browser tools. Do not attempt browser launch from shell commands. MCP evidence is stored under `artifacts/03-administration/playwright-mcp/`.

Administration is not allowed to compensate for an incomprehensible daily workflow. Record any configuration knowledge that ordinary users must memorize or duplicate.

## UX PHASE 4 — Independent Evidence Review

Act as an independent evaluator. Do not inspect product source code until the evidence review is complete. Start with `artifacts/journey-evidence-index.tsv`, then read the indexed lane-owned traces, screenshots, and visible text. Execution reports are secondary narrative and cannot override the machine-validated evidence index. Reconstruct what each user would believe at every decision point.

Score each executed journey from 0 to 4 for:
- orientation: where am I and what is this for;
- state comprehension: what is true now and why;
- next-action clarity: what can or should I do;
- domain demystification: does the UI translate specialist concepts into usable decisions;
- effort: avoidable steps, memory, duplication, and navigation;
- feedback and recovery: actionable confirmation, errors, and retry path;
- outcome confidence: can the user verify the business result;
- control safety: are consequential actions understandable and appropriately guarded.

`0` means blocked or dangerously misleading, `1` severe assistance required, `2` usable with product-specific knowledge, `3` clear for the target role, and `4` unusually effective and frictionless. Cite evidence for every score below 3. Challenge false PASS results where task completion concealed confusion, unexplained state, or unverifiable outcomes.

## UX PHASE 5 — Scorecard and Remediation Register

Synthesize the product contract, journey plan, machine-validated journey evidence index, execution evidence, and independent review. Do not average away a blocked critical journey. Give an overall UX verdict of PASS, CONDITIONAL, FAIL, or UNVERIFIED and explain the gating rule. This is not the product's launch-readiness decision; it is the end-user usability decision consumed by the broader audit.

Write:
1. an executive summary focused on user outcomes;
2. a journey score table with result, dimension scores, and evidence links;
3. cross-journey root causes in navigation, terminology, information architecture, workflow, feedback, permissions, and recovery;
4. a prioritized remediation register;
5. coverage gaps and the next journeys the harness should infer on a later run.

Create `$RUN_DIR/artifacts/ux-remediation-register.tsv` with this exact header:

`finding_id<TAB>severity<TAB>journeys<TAB>role<TAB>problem<TAB>user_harm<TAB>required_outcome<TAB>evidence<TAB>verification_journey`

Remediation rows must specify the user outcome to achieve, not a guessed component-level patch. Merge duplicate symptoms that share one workflow or information-model cause.
