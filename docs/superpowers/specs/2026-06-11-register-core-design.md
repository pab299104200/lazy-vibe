# Register Core (lazy-vibe v3) — Design

**Date:** 2026-06-11
**Status:** Approved design, pending implementation plan
**Owner:** Pete
**Scope:** lazy-vibe (this repo) + integration contracts for product repos (meridian, portal, keystone) and the Meridian `.claude/skills` layer.

## 1. Problem

Repeated audit/remediation cycles do not converge. Every run produces hundreds of
"new" findings regardless of product quality. Root causes, verified against the
current harness and skills:

1. **Finding-generation incentives.** Review prompts instruct agents that zero
   findings means insufficient effort (`feature-review`: "If you find zero bugs and
   zero gaps, you didn't look hard enough"). LLMs comply unconditionally; finding
   count is a property of the prompt, not the product. Observed false-positive rate:
   64% (documented in `feature-remediation`).
2. **No persistent adjudication.** The blocker ledger (`run-remediation.sh`)
   deduplicates within a run only. Nothing records that a finding was previously
   fixed, disproven, or risk-accepted, so every run re-litigates the entire product
   and nondeterminism guarantees new phrasings of old issues.
3. **Release-readiness is an agent judgment.** Agents are asked to agree the product
   is ready. They never will, structurally. Readiness must be a deterministic
   predicate over persistent state that agents feed but do not vote on.

## 2. Goals

- Convergence is measurable: each audit run reports *new / suppressed / regressed /
  still-open* against a persistent register.
- Adjudication decisions (fix / false-positive / risk-accepted / parked) are made
  once and persist forever.
- Human involvement is limited to a batch triage queue of pre-verified,
  pre-filtered decisions that genuinely require the owner (risk acceptance,
  severity downgrades, won't-fix, reopening protected states).
- "Release ready" is computed by a deterministic script from the register, a
  per-product launch scope, and native gate artifacts. Zero LLM calls.
- Audit cost drops via differential mode: only changed surface is re-audited;
  full sweeps are release-candidate events.
- Every `fixed` disposition is backed by a permanent regression test — the
  deterministic test suite is the accumulating quality floor (the ratchet).

### Non-goals

- Rewriting `run-audit.sh` / `run-remediation.sh` orchestration. They remain the
  evidence collectors and fix executors. All new logic is Python in
  `lazy_vibe/register/`; bash gains thin call-outs only.
- A web UI for triage. The queue is markdown + a CLI.
- Cross-product finding correlation (each product repo has its own register).

## 3. Architecture overview

```
audit run (run-audit.sh)                feature build (run-feature-build.sh)
        │  blocker ledger + artifacts            │  build diff
        ▼                                        ▼
┌──────────────────────────── lazy_vibe/register ────────────────────────────┐
│  ingest ──► reconciler ──► triage pipeline ──► register.jsonl (in product  │
│                │               │  ▲                 repo, git-committed)   │
│                │               │  └─ pete: `lazy-vibe triage` CLI          │
│                │               └─ verifier agents (evidence-or-disproof)   │
│                └─ reconcile-report.md (new/suppressed/regressed/open)      │
│                                                                            │
│  readiness ◄── launch-scope.yaml + gate artifacts + register               │
└────────────────────────────────────────────────────────────────────────────┘
        │ open findings                          ▲ fixed + regression test
        ▼                                        │
   remediation (run-remediation.sh) ─────────────┘
```

Per product repo (meridian, portal, keystone):

```
docs/audit/register/
├── register.jsonl        # canonical, append-mutate, git-committed
├── register.md           # generated human view (never hand-edited)
├── baseline.json         # git SHA + run id of last reconciled run
├── launch-scope.yaml     # customer-facing surface + severity bar + gates
├── triage-policy.yaml    # deterministic auto-disposition rules
├── themes.yaml           # per-product theme vocabulary for fingerprinting
└── triage-queue.md       # generated queue awaiting Pete (regenerated each run)
```

## 4. Findings register

### 4.1 Entry schema (one JSON object per line in `register.jsonl`)

```json
{
  "finding_id": "R-0042",
  "fingerprint": "sha256:8c1f0b2a9d4e6f31",
  "fingerprint_inputs": {
    "category": "product_gap",
    "theme": "tenant_scope_missing",
    "path": "backend/routers/evidence.py",
    "symbol": "list_evidence"
  },
  "title": "Evidence list endpoint not tenant-scoped",
  "description": "…",
  "severity": "P1",
  "severity_source": "adjudicated",
  "taxonomy": "S",
  "in_scope": true,
  "disposition": "open",
  "disposition_by": "policy:p0-security-in-scope",
  "disposition_reason": "…",
  "evidence": [
    {"type": "code", "ref": "backend/routers/evidence.py:118", "run_id": "2026-06-10-1402"}
  ],
  "regression_test": null,
  "first_seen": {"run_id": "2026-06-10-1402", "date": "2026-06-10"},
  "last_seen": {"run_id": "2026-06-10-1402", "date": "2026-06-10"},
  "occurrences": 1,
  "history": [
    {"ts": "2026-06-10T14:30:00Z", "event": "created", "by": "ingest"},
    {"ts": "2026-06-10T14:41:00Z", "event": "disposition", "from": "new",
     "to": "open", "by": "policy:p0-security-in-scope", "reason": "…"}
  ]
}
```

Field rules:

- `finding_id` — `R-NNNN`, monotonically assigned, never reused.
- `fingerprint` — `sha256(category|theme|normalized_path|symbol)[:16]`. Excludes
  finding text deliberately: a rephrased duplicate from a different model/run
  produces the same fingerprint. `normalized_path` is repo-relative; `symbol` is
  the enclosing function/class/route id, or `-` for file-level findings.
- `theme` — must come from the product's `themes.yaml` vocabulary (the generalized
  successor of the Meridian-specific themes hard-coded in `run-remediation.sh`
  awk categorization). Ingest maps free-text agent themes onto the vocabulary;
  unmapped themes are added as candidates flagged in the reconcile report.
- `severity_source` — `proposed` (agent) or `adjudicated` (policy or Pete).
  Adjudicated severity wins; later runs cannot re-inflate it. A new run proposing a
  *higher* severity on an adjudicated entry queues a severity-review item for Pete
  instead of changing the value.
- `taxonomy` — `B` bug, `S` security, `G` gap, `A` autonomy gap, `U` UX,
  `M` competitive, `F-*` acceptance forced-intervention codes (`F-CRASH`,
  `F-SILENT`, `F-TRUST`, …), `RC-*` UX root-cause codes (`RC-1` wiring gap …
  `RC-7` design issue). Absorbed from the retired `feature-review` /
  `feature-ux-audit` skills (§10).
- `evidence[].type` — `"code"` (agent-cited code location) or `"audit"` (imported
  audit-run reference).
- `regression_test` — `path::test_name`; **required** for disposition `fixed`.

### 4.2 Disposition state machine

States: `new`, `open`, `in_remediation`, `fixed`, `false_positive`,
`risk_accepted`, `parked`, `regressed`.

| From | To | Guard |
|---|---|---|
| new | open | verifier returned VERIFIED **and** policy/Pete dispositioned it open |
| new | false_positive | verifier returned UNSUPPORTED with disproving citation; auto if policy permits, else Pete |
| new | parked | out of launch scope (scope matcher), or Pete |
| new | risk_accepted | Pete only (policy may *propose*) |
| open | risk_accepted | Pete only — accepting a verified-real risk (§6) |
| open | in_remediation | remediation unit created for it |
| in_remediation | fixed | verifier pass **and** `regression_test` set |
| in_remediation | open | remediation unit failed/abandoned |
| fixed | regressed | reconciler matched a new occurrence |
| regressed | in_remediation | remediation re-queued (automatic) |
| parked | open | launch-scope expansion re-evaluation, or Pete |
| false_positive / risk_accepted | open | **Pete only**, via reopen proposal in triage queue |

Protected states: `false_positive` and `risk_accepted` are never reopened by
agents or policy. A new occurrence whose evidence differs materially from the
adjudicated evidence (different file/symbol, or new exploit mechanism stated)
creates a **reopen proposal** in Pete's queue; identical evidence is suppressed
silently and counted in the reconcile report.

`risk_accepted` **requires** `review_by` (ISO date). A past-due acceptance
reverts to blocking: it surfaces in the triage queue and **fails the readiness
predicate** until Pete re-affirms (new `review_by`) or moves it to `open`.
Risk acceptances are time-boxed exceptions, never permanent dispositions —
this is the anti-tech-debt guard.

### 4.3 Storage

`register.jsonl` is canonical and git-committed in the product repo — every
disposition change is in git history with the commit that made it. The tool loads
it into in-memory SQLite for queries; `register.md` is regenerated on every write
(table grouped by disposition, then severity). Concurrent-write safety: a
`.register.lock` file taken by the tool; harness invocations are already
serialized per repo.

## 5. Reconciler

Deterministic Python. Input: a run's `00-blocker-ledger.tsv` + raw PX list +
artifacts. For each blocker:

1. **Exact fingerprint match** against the register:
   - matched `false_positive` / `risk_accepted` / `parked` → **suppress** (count
     in report; no agent, no Pete).
   - matched `open` / `in_remediation` → merge evidence, bump
     `last_seen`/`occurrences`. Severity proposals are deduplicated per
     (proposed severity, run id), so within-run duplicates and replays cannot
     drop or duplicate escalation signals.
   - matched `fixed` → set `regressed`, re-queue remediation, flag prominently.
2. **Fuzzy match** — candidate set: same `normalized_path` + `category`; match if
   Jaccard similarity of normalized title tokens ≥ 0.5. Deterministic (no
   embeddings). Result is routed to a verifier agent as "probable duplicate of
   R-NNNN: confirm or split"; confirm merges, split creates a new entry. Fuzzy
   matching deliberately includes entries created earlier in the same run:
   theme-fragmented duplicates of one underlying issue are flagged for verifier
   merge, and the report's disposition suffix (`(new)`) identifies same-run
   hints.
3. **No match** → create entry with disposition `new` → triage pipeline (§6).

Output: `reconcile-report.md` — headline `N new, M suppressed, K regressed,
J still open` plus per-section tables and theme-vocabulary candidates. This
headline, trending to zero new on unchanged surface, is the convergence metric.

Backfill: a one-time `ingest --backfill` consumes the most recent completed audit
run per product (e.g. portal `2026-06-01-launch-readiness-run`, the meridian
remediation ledgers) so existing adjudication effort is not lost.

## 6. Triage pipeline

Triage adjudicates exactly one question per finding: **is it real?** It never
decides how much effort a real problem deserves. A verified, in-scope finding
defaults to `open` — the fix queue. There is no disposition for "mitigated" or
"workaround": the only exits from `open` are a root-cause fix with a permanent
regression test (`fixed`), or an explicit Pete-only decision (`risk_accepted`,
time-boxed per §4.2). The remediation standard remains root-cause-or-nothing.

Three stages, in order, for `new` entries only:

1. **Verification (agents).** Each new finding is dispatched to a verifier agent
   with the finding, cited code, and the evidence-or-silence contract: return
   `VERIFIED` with reproduction evidence (file:line + stated failure/exploit
   mechanism) or `UNSUPPORTED` with a disproving citation. Output is structured
   (JSON, schema-validated by the harness — not prose-scraped). UNSUPPORTED
   becomes a proposed `false_positive`.
2. **Policy auto-disposition.** `triage-policy.yaml`, evaluated top-down, first
   match wins:

   ```yaml
   rules:
     - id: p0-security-in-scope
       match: {severity: P0, taxonomy: S, in_scope: true, verified: true}
       action: open            # straight to remediation queue
     - id: out-of-scope-p3
       match: {in_scope: false, severity: P3}
       action: park
     - id: dev-dep-low-cve
       match: {source: dependency_audit, dependency_scope: dev, cvss_below: 7.0}
       action: propose_risk_accept   # lands in Pete's queue with recommendation
   default: queue
   ```

   Actions: `open`, `park`, `false_positive` (only when verifier said
   UNSUPPORTED), `propose_risk_accept`, `queue`. Every auto-disposition is stamped
   `disposition_by: policy:<rule-id>`.
3. **Pete's queue.** Everything `queue`d or proposed: risk acceptances, severity
   downgrades/upgrades on adjudicated entries, won't-fixes, reopen proposals,
   past-due risk reviews. Rendered as `triage-queue.md` (finding, evidence links,
   agent recommendation + reason) and worked through `lazy-vibe triage` — an
   interactive CLI that walks the queue and writes dispositions back stamped
   `disposition_by: pete`. Batch-friendly: accept-all-recommendations with
   per-item override.

## 7. Launch scope and readiness predicate

### 7.1 `launch-scope.yaml`

Scope principle (Pete, 2026-06-11): **customer-facing surface for every product.**
Portal's scope is its full IdP/SSO/IGA/marketplace customer surface (it is the
wedge product and the identity layer — highest security bar). Meridian's scope is
its GRC launch claims. Keystone's starts minimal (internal-facing initially).

```yaml
product: meridian
claims_doc: docs/functional/launch-claims.md
surfaces:
  - slug: evidence-collection          # ties to docs trifecta
    routes: ["/api/evidence", "/evidence"]
    journeys: ["connector-to-evidence", "evidence-expiry-alert"]
  # …
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted_by: pete
  P2: triaged            # may be open, must not be `new`
gates:
  - id: tests          # profile-listed test commands exit 0
  - id: sast_critical  # no critical SAST finding in prod deps
  - id: journeys       # all in-scope critical journeys pass simulation (07)
  - id: accessibility  # serious axe-core violations == 0 on in-scope pages
```

`in_scope` on a register entry is computed by matching its path/route/journey
against `surfaces`; recomputed when the scope file changes (parked entries
re-evaluate to `open` proposals).

### 7.2 Readiness

`lazy-vibe readiness --product meridian` (also `python -m lazy_vibe.register
readiness`): evaluates severity bar against the register and each gate against
the latest native artifacts (paths from the product profile). Prints a table —
each bar/gate, PASS/FAIL, and the exact blocking items (`R-0042 open P1 …`).
Exit 0 = READY, 1 = NOT READY, 2 = stale evidence (gate artifacts older than
baseline). No LLM calls. Past-due risk acceptances are FAIL (§4.2). The report
**always** lists active risk acceptances (with review dates) and parked counts,
so every deferred item is visible at every release decision — deferral never
means buried. This command's output **is** the release decision input;
audit job `09-final-decision` is reduced to narrating it, not making it.

## 8. Differential audit mode

- After each reconciled run, `baseline.json` records `{git_sha, run_id, date}`.
- `run-audit.sh --differential`: `git diff --name-only <baseline_sha>..HEAD` →
  map changed files to surfaces/jobs via (a) `launch-scope.yaml` surfaces,
  (b) docs-trifecta links, (c) Lattice impact graph where available. Run only
  affected discovery/deep-dive jobs; scope group 06/07 to affected test commands
  and journeys. Deterministic cheap gates (tests, SAST on diff, lint) always run.
- **Coverage rule is scope-dependent:** product sweeps prioritize P0/P1 (current
  behavior); **feature-scoped/differential runs enumerate exhaustively** — every
  endpoint, route, state transition, and permission check in the diff. This is
  the absorbed `feature-review` exhaustiveness contract.
- Post-build pipeline: `run-feature-build.sh` completes → differential audit on
  the feature branch → reconciler → triage → remediation of `open` entries.
  One pipeline; no separate per-feature review step.
- Full sweeps remain available (`--full`) and are expected only at release
  candidates; they reconcile through the register like every other run, so they
  cannot reset progress.

## 9. Prompt calibration

Exact changes:

1. **Remove finding-generation incentives.** Delete "If you find zero bugs and
   zero gaps, you didn't look hard enough", "Red is good" framing, and any
   instruction equating finding count with effort (files:
   `generic-launch-readiness-audit-prompt.md`, `generic-shared.md`, Meridian
   skills that survive §10). Replace with: *"Your job is accurate dispositions,
   not finding count. Zero new findings on unchanged, previously audited surface
   is a valid and expected outcome."*
2. **Severity anchors.** Add 3–4 concrete calibrated examples per severity level
   to `generic-shared.md` (e.g. P0: cross-tenant data read via unscoped query;
   P2: missing pagination on a 25-row admin list). Agents cite the closest anchor
   when assigning severity.
3. **Evidence-or-silence.** A finding without file:line evidence and a stated
   failure/exploit mechanism is not reportable. (Moves the verification burden
   into the audit instead of remediation's post-hoc 64%-false-positive cleanup.)
4. **Suppression context.** Auditor prompts receive the compact suppressed-
   fingerprint list (fingerprint + one-line title, in-scope entries only) so
   agents do not re-derive adjudicated findings. Budget-bounded: this list is
   capped and prioritized by `occurrences`.
5. **Structured outputs.** Verifier and auditor findings are emitted as
   schema-validated JSON blocks, replacing the awk/regex prose-scraping in
   `run-remediation.sh` finding extraction (which stays only as a fallback for
   legacy artifacts during backfill).

## 10. Skill consolidation (Meridian `.claude/skills`)

Per the no-prerelease-legacy rule: retire skills whose function the harness now
owns; absorb their unique assets.

| Skill | Decision | Rationale / absorbed assets |
|---|---|---|
| `feature-review` | **Retire** | ~80% duplicates audit groups 02/03/04. Absorbed: exhaustive-at-scope coverage contract (§8), B/S/G/A/U/M taxonomy (§4.1), severity calibration material (§9.2). |
| `feature-ux-audit` | **Retire** | Duplicates job 07 + differential mode. Absorbed: RC-1…RC-7 root-cause taxonomy (§4.1), wiring-map method folded into job 07 prompt. |
| `feature-acceptance` | **Keep** | A/D/F forced-intervention scoring with a live browser is a distinct measurement (serves the frictionless-UX goal). Change: findings (F-*) write to the register via `ingest`; verdict thresholds unchanged. |
| `feature-remediation` | **Keep, rewire** | Reads its work queue from the register (`open` entries) instead of scorecards; writes `fixed` + `regression_test` back. Its 64%-false-positive verification step is deleted — triage already verified. |
| `feature-design` / `feature-build` / `feature-idea` / `feature-marketresearch` | **Keep** | Unchanged, except `feature-build` ends by invoking the differential audit (§8). |

Scorecards (`docs/scorecard/*.md`) become **generated narrative views of the
register** (per-feature filter), regenerated on demand; existing scorecards are
historical records, backfilled into the register where findings are still live.

## 11. Integration contracts

- `run-audit.sh`: after summary generation, call
  `python -m lazy_vibe.register ingest --run <RUN_DIR> --repo <product>` then
  `reconcile`. New `--differential/--full` flag (§8).
- `run-remediation.sh`: build its queue from `register.jsonl` `open`/`regressed`
  entries (replacing raw PX extraction for register-enabled repos); on verifier
  pass, call `register close --finding R-NNNN --test <path::name>`.
- `run-feature-build.sh`: on completion, trigger differential audit.
- Register CLI surface: `lazy-vibe register ingest|reconcile|triage|readiness|
  report|close|backfill` (thin shell wrapper over `python -m lazy_vibe.register`).

## 12. Error handling

- **Corrupt/unparseable register line** → hard fail with line number; never skip
  silently (git history is the recovery path).
- **Fingerprint collision** (different findings, same hash inputs) → reconciler
  detects evidence divergence (different file:line set) and splits with a
  `collision` history event.
- **Unmapped theme** → entry created with `theme: _candidate:<slug>`, flagged in
  reconcile report; readiness treats in-scope `_candidate` entries as untriaged
  (`new`), i.e. blocking the P2 bar — vocabulary gaps cannot leak findings.
- **Verifier agent failure/timeout** → finding stays `new`; reconcile report
  lists unverified counts; readiness blocks on in-scope `new` entries, so
  verification failures cannot be silently dropped.
- **Stale gate artifacts** → readiness exit code 2 with the stale artifact list.
- **Scope file edits** → recompute `in_scope` across the register; transitions
  surface as proposals, never silent dispositions.

## 13. Testing

All in `lazy-vibe/tests/register/`:

- **Unit:** fingerprint stability (path normalization, symbol fallback, theme
  mapping), state-machine guards (every legal transition, every illegal one
  rejected, protected-state reopen attempts), policy rule evaluation order,
  scope matcher, severity adjudication precedence.
- **Reconciler:** fixture ledgers covering exact match per disposition, fuzzy
  match above/below threshold, regression detection, collision split, theme
  candidates.
- **End-to-end:** fixture audit run artifacts → ingest → reconcile → policy →
  queue render → simulated Pete dispositions → readiness PASS/FAIL/stale across
  bar and gate permutations → second fixture run demonstrating suppression and
  one regression.
- **Contract:** verifier JSON schema validation, malformed-output rejection.

## 14. Rollout order

1. `lazy_vibe/register/` module: schema, state machine, storage, CLI skeleton + unit tests.
2. Reconciler + ingest (including `--backfill`) + tests; backfill meridian and portal from their latest runs.
3. Triage pipeline: verifier dispatch, `triage-policy.yaml`, queue render, `lazy-vibe triage` CLI.
4. `launch-scope.yaml` for meridian, portal, keystone + readiness predicate.
5. Differential audit mode + post-feature-build hook.
6. Prompt calibration edits + skill retirement/rewiring in meridian.

Each step lands with its tests and README updates before the next begins.
