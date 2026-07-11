# Full Product Audit + Remediation — Reusable Master Prompt (Wave 1–3 + Market)

Copy everything below the line into a fresh Claude Code session at the root of the product repo you want to audit. Replace the three `{{...}}` values. It runs the same Wave 1 (static audit) → Wave 2 (live browser UX + runtime) → Market analysis → Wave 3 (remediation) pipeline used on Cadres Portal, with the hard-won guardrails baked in.

Prereqs: a git repo; a dev deploy path (script or command) that stands the app up on its real database; browser creds for the dev app if you want Wave 2; Playwright MCP available for Wave 2.

---

You are running a full launch-readiness audit and remediation of **{{PRODUCT_NAME}}** (repo root: current directory). Work autonomously in waves — do not stop to ask permission for reversible work; only stop for genuinely destructive actions or true scope changes. Commit as you go. Deliverables go in `docs/audit/$(date +%Y-%m-%d)-audit/`.

## Ground rules (read first — these are the lessons that make or break the run)
- **"systemd active" ≠ healthy.** A crash-looping service still reports active. After every deploy, hit the real health endpoint on the real port and confirm 200 (not 000) before trusting the app. Read the journal for boot errors.
- **Tests lie about runtime.** If the suite runs on SQLite (or mocks the DB) but prod is Postgres, whole classes of bugs (schema drift where models declare columns no migration adds, `FOR UPDATE` + window functions, RLS posture, `ON CONFLICT`, hot-row lock contention) are invisible until you actually boot the app on its real DB and click through it. Wave 2 exists to catch these.
- **One migration head.** After any wave that adds migrations, assert exactly one head (`alembic heads` or the framework's equivalent). Parallel agents branching migrations off the same base is the #1 way to brick deploys. Merge before deploying.
- **Fix bugs you find, don't defer** — but for anything security-sensitive or touching >1 call site, plumb the fix through a shared helper rather than patching one site; audits repeatedly find "guard added at one call site, not the others."
- **Verify before claiming done** — run the tests / build; paste evidence. Commit per finding referencing its ID. Never `git stash` in a shared worktree (parallel agents share it) — use `git add <specific files>`.
- **Spawn code-fix / audit sub-agents on your default fast model, not the biggest one, unless a task is genuinely cross-cutting.** Respect any repo/user model preference.
- **Deduplicate against any existing findings register** so you don't re-report known issues; cite prior IDs when you rediscover one.

## Setup (do this first)
1. Commit the dirty working tree on a work branch. Deploy to dev with `{{DEPLOY_CMD}}` and **prove the app boots** (health 200). If the deploy or boot fails, fix the blockers (they are findings — write them up) until it's green. This alone often surfaces the highest-severity issues.
2. Create `docs/audit/<date>-audit/{findings,ux,tasks,artifacts}`. Write `artifacts/shared-instructions.md`: the product's priorities (frictionless UX / autonomy / best-on-market — state the owner's actual bar), the posture (ruthlessly critical, red-is-good, cite `file:line` for every claim working OR broken, both-directions doc alignment, hunt bugs + security not just gaps, score conservatively), and the required per-finding format: `[PREFIX-NN] title · Severity P0–P3 · Type (bug/security/gap/autonomy/ux/docs/competitive) · Evidence file:line · User impact · Fix sketch · Suggested model (haiku/sonnet/opus) · Effort (S/M/L)`.

## Wave 1 — Static audit (parallel domain agents)
Enumerate the product's domains (routers/pages/docs) and dispatch one read-only sub-agent per domain (typically 10–14: auth/sessions/MFA; users/directory/groups; tenancy/RBAC; the core product objects; each integration/protocol; async/webhooks/jobs; billing; audit/logging; plus cross-cutting: frontend quality (IA, i18n, UI-spec compliance, a11y — with per-rule violation counts), backend quality (code standards, test coverage, tech debt, ops readiness), and whole-repo docs coverage both directions). Each agent:
- audits code ↔ architecture/functional/manual docs **both directions** (documented-but-missing AND built-but-undocumented), RBAC on every mutation, tenant isolation (trace the actual query), protocol/spec correctness, autonomy/friction (count clicks; flag every manual step a policy could decide), and competitive table-stakes gaps vs the named market leaders.
- writes `findings/NN-<domain>.md` in the required format. **Instruct parents to WRITE the file, not just return a message** (if an agent fans out to its own sub-agents, it must merge their reports to disk). Preserve every sub-agent transcript so nothing is lost if one is truncated.

## Wave 2 — Live browser UX + runtime (Playwright on the running dev app)
Lens: **user perception, journey friction, wow-factor** — the UI is how customers experience the product; backend correctness is invisible if the workflow is hard. Score each interaction: autonomous / designed-intervention / forced-intervention (avoidable friction = defect).
- Log in; walk the primary journeys first (onboarding/first-run, the top admin task, invite/create flows completed end-to-end, each integration setup, the governance/lifecycle flows), then end-user self-service, power-user (keyboard/command palette), and responsive/mobile.
- On every page: capture console errors, screenshot friction, grade against the UI spec (perceived performance, WCAG 2.2 AA, mandatory searchable-dropdowns/pagination/currency, modals, error/empty/loading states, no raw-ID inputs, error messages actionable).
- **Runtime health is part of Wave 2:** every 500 you hit is a finding — get the real traceback from the server log and root-cause it (schema drift? Postgres-only query? lock contention? missing migration?). Fix the clear blockers so the app is actually usable, and catalog the rest with root causes. Note: a monitoring/audit side-effect must never 500 the endpoint it instruments — isolate such hooks best-effort.
- Write `ux/WAVE2-ux-audit.md` (UX-NN findings + a runtime-500 catalog with root causes + a "what's genuinely good" section). Defer axe/Lighthouse quantitative scans as a follow-up lane unless asked.

## Market analysis lane (competitive positioning)
Use the Wave-1 findings as the **verified** internal capability baseline (never guess what the product has — cite code/docs, the false-positive rate on unverified claims is high). Dispatch parallel research agents (2–3 competitors each) that WebSearch/WebFetch competitor capabilities AND community pain (Reddit r/sysadmin/r/msp/r/netsec, G2/Capterra/TrustRadius, vendor idea boards, HN) with sourced URLs and signal strength. Synthesize: a capability matrix (us vs them), ranked **table-stakes gaps** that block adoption, **differentiators** to double down on, and **innovation white-space**. Write it to `market-analysis.md` and use it to reprioritize Wave 3.

## Synthesis — emit register-ingestable output (this is what makes the run consumable by remediation)
The remediation harness (`run-remediation.sh`) is **register-sourced**: it reads findings from `docs/audit/register/register.jsonl` (dispositions `new`/`open`/`regressed`), NOT from free-form audit prose or a `BACKLOG.tsv`. So the audit's machine-readable deliverable must be a **blocker ledger in the exact schema the register ingest expects**, and you must actually ingest it. A human-readable backlog the register can't parse is the #1 reason an audit's findings never reach remediation — do not stop at prose.

1. **Parse every finding** (all waves, incl. the ux lane) into `artifacts/00-blocker-ledger.tsv` — plain tab-separated, no quoting, this EXACT 12-column header, one row per finding:
   `blocker_id\tcategory\ttheme\tseverity\tgroup\tmodel_class\tfinding_count\trepresentative_source\trepresentative_line\trepresentative_title\traw_px_ids\treferences`
   Column contract:
   - `blocker_id` — unique per row: `B-0001`, `B-0002`, …
   - `category` — stable fingerprint class from the harness vocabulary: `product_gap` (bugs / security / gaps / autonomy — the default for real product findings), `evidence_gap` (browser/e2e/unverified-only), `harness_gap`, `runtime_unavailable`. The finding's fine-grained type (bug/security/ux/…) lives in the title/theme; keep `category` stable run-to-run so re-audits **dedup** instead of duplicating.
   - `theme` — short stable `snake_case` slug of the problem area (e.g. `tenant_scope_missing`, `onboarding_friction`); the register normalizes it. Same underlying issue ⇒ same theme across runs.
   - `severity` — exactly one of `P0` `P1` `P2` `P3` (ingest rejects anything else).
   - `group` — the domain (`auth`, `tenancy`, `billing`, …).
   - `model_class` — `high-risk` for P0/P1 or security/tenant findings, `complex` for runtime/harness infra, else `standard`.
   - `finding_count` — `1`.
   - `representative_source` — the evidence FILE path, repo-relative, **no line number**.
   - `representative_line` — the line number, or `-`.
   - `representative_title` — the finding title (strip the `[PREFIX-NN]` and severity prefix).
   - `raw_px_ids` — the finding's own ID (e.g. `TEN-01`).
   - `references` — `<finding_id>:<source>:<line>` (or the `findings/NN-*.md` path).
   Fingerprint identity is `(category, theme, representative_source, title)` — get these stable or a later `run-audit.sh` pass won't dedup against this one. Save the generator as `artifacts/build_ledger.py` so it's reproducible.
2. **Ensure the register has a theme vocabulary.** `backfill` requires `docs/audit/register/themes.yaml` (it errors hard if absent). If the register already exists (re-audit), reuse it as-is and prefer its existing `snake_case`/`kebab` theme slugs for your ledger's `theme` column so findings bucket into known themes. For a first-ever audit, seed one — top-level `themes:` mapping, one key per theme slug you used, each with `patterns: []`:
   ```
   mkdir -p docs/audit/register
   # first audit only — seed the vocabulary from the theme slugs you emitted:
   printf 'themes:\n' > docs/audit/register/themes.yaml
   cut -f3 docs/audit/<date>-audit/artifacts/00-blocker-ledger.tsv | tail -n +2 | sort -u \
     | sed 's/^/  /; s/$/:\n    patterns: []/' >> docs/audit/register/themes.yaml
   ```
   An unknown theme does not fail ingest — it degrades to a `_candidate:<slug>` entry that the reconcile report flags and readiness treats as untriaged — but a real slug buckets correctly, so seed the vocabulary.
3. **Ingest the ledger into the durable register** (creates entries as `new`):
   ```
   python3 -m lazy_vibe.register backfill \
     --register-dir docs/audit/register \
     --ledger docs/audit/<date>-audit/artifacts/00-blocker-ledger.tsv \
     --run-id <date>-audit --date <date>
   ```
   **This is the step a manual audit most often skips — without it the findings never reach remediation.** `backfill` prints `<N> new, <M> suppressed, <K> regressed`; verify `<N>` equals your genuinely-new ledger rows (re-audits dedup against existing register entries, so `<N>` will be lower than the row count — that is correct, not a bug). Then `python3 -m lazy_vibe.register report --register-dir docs/audit/register` regenerates `register.md`.
4. Write the human-facing deliverables: `README.md` (exec summary, coverage table, headline blockers, verdict), `tasks/00-launch-blockers.md` (curated, self-contained P0/P1 tasks), and `artifacts/coverage-and-reruns.md` (what ran / what was truncated / how to rerun). The **register is the machine-facing source of truth** that remediation consumes; these files are for humans.

## Wave 3 — Remediation (drive the register to zero, script-driven)
Do **not** hand-orchestrate remediation from prose. Once the findings are in the register, run the deterministic harness from the product repo root:
```
PROFILE=<profile> /path/to/lazy-vibe/run-remediation.sh --execute
```
It is register-sourced, so it ignores `--audit-run` once `register.jsonl` exists. By default it **triages the `new` backlog first** (a verifier confirms each finding real vs `false_positive`, then policy promotes the confirmed ones to `open`), then remediates `open`/`regressed` in model-tagged waves — honoring the ground rules above (single migration head per wave, commit-per-finding, verify-before-done, deploy+boot-check). This makes the whole thing a two-step, hands-off `run-audit → run-remediation` loop. The sub-wave ordering below is the **priority the remediation should follow**, adapted to what the audit found:
- **3.0 Guardrails first** — add CI that catches the whole runtime-regression class at merge time: single-migration-head check; migrate a fresh prod-parity DB + boot the app + run any posture/health self-check; model-vs-DB schema-parity assertion; run the real-DB test lane. (This is the highest-leverage task — it's why the regressions went undetected.)
- **3.1 Security P0/P1** — tenant isolation & account takeover, via shared helpers not point patches.
- **3.2 "Shipped but inert" features** — things the UI implies work but don't (worse than missing).
- **3.3 Frictionless UX** (the owner's priority — the "wow" wave): session/refresh, onboarding friction, bulk operations everywhere, delegated self-service, per-integration setup wizards, the market-analysis table-stakes gaps.
- **3.4 Autonomy gaps** — scheduled/recurring jobs, auto-retry of transient failures, policy-driven decisions replacing manual steps.
- **3.5 P2/P3 long tail + doc corrections.**
- **Verification lane** — after 3.0–3.3, run axe/Lighthouse + the end-to-end mutation journeys as the acceptance gate proving Wave 3 landed.

## Close
Report: what was found, what you fixed live, the backlog counts by severity, the market verdict, and the prioritized Wave 3. Keep the audit directory as the human source of truth **and confirm the findings were ingested into `docs/audit/register/register.jsonl` as `new`** — that register, not the prose, is what the remediation harness consumes. If the register count did not climb, the run is not done: the ledger schema or the `backfill` step is wrong and the findings are stranded.

---

### `{{...}}` to replace
- `{{PRODUCT_NAME}}` — e.g. "Cadres Nexus"
- `{{DEPLOY_CMD}}` — e.g. `CADRES_USB_BACKUP_SKIP=1 ./scripts/deploy-runtime dev` (whatever stands the app up on its real DB)
- Competitor set + owner priorities — state them in `shared-instructions.md` per product.
