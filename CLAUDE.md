# CLAUDE.md — Universal Software Engineering

> Universal engineering spine — applies to every project regardless of stack. Platform-specific rules (the architecture / release / quality-gate / testing / concurrency / compliance sections — §5–8, §12, §13) load automatically from `~/.claude/rules/{web,android,ios}.md` when the matching tech is detected.
> **Don't water down the workflow rules.** Every one exists because a real bug shipped without it.
> **Cache boundary discipline.** Everything above the `===== CACHE BOUNDARY =====` marker near the end is static across releases and gets prompt-cached. Only §19 Project Context (below the boundary) is per-project; edits there don't invalidate the cached spine.

------

## 1. Subagent Roster

Agents live under `.claude/agents/` (project) or `~/.claude/agents/` (user, all projects). Invoke them by name, or let them auto-dispatch on their description. They're scoped — each loads only the context it needs, so they're faster and less drift-prone than one mega-agent. In an Android repo, the project-scoped Android-flavored agents override the generic ones of the same name.

**Core four-hat chain (§4 execution loop):**

| Agent              | Phase / Purpose              | Concurrency | Invoke when                                                  |
| ------------------ | ---------------------------- | ----------- | ------------------------------------------------------------ |
| `architect`        | Phase 1 planner              | Read-only   | Any non-trivial change. Produces the scoped plan before code is written. |
| `senior-swe`       | Phase 2 implementer          | Mutating    | After plan approval. Writes code matching existing patterns. |
| `code-reviewer`    | Phase 3 adversarial reviewer | Read-only   | Before pushing. Walks the review checklist against the diff. |
| `qa`               | Phase 4 verifier             | Read-only   | After review. Generates the test plan and runs the local gate. |
| `release-engineer` | Release prep                 | Mutating    | Bumping versions, writing CHANGELOG, tagging.                |
| `docs-reconciler`  | Drift detection              | Read-only   | Every 3–5 merged PRs. Surfaces drift between specs ↔ code ↔ CHANGELOG ↔ README ↔ open issues. |

**Specialists & contributors (pulled in around the four-hat chain — design upstream, ops downstream, the rest as the change warrants):**

| Agent                      | Purpose                          | Concurrency | Invoke when                                          |
| -------------------------- | -------------------------------- | ----------- | ---------------------------------------------------- |
| `security-reviewer`        | Security + supply-chain audit    | Read-only   | Change touches auth, crypto, input, secrets, deps; pre-release. |
| `performance-engineer`     | Performance analysis             | Read-only   | Hot path, query, startup, memory; latency/jank regressions. |
| `db-migration-specialist`  | Safe schema migrations           | Mutating    | Any column/table/entity/data-shape change.           |
| `debugger`                 | Reproduce → root-cause           | Read-only   | A failing test/crash/regression whose cause isn't obvious. |
| `tech-writer`              | Authors docs                     | Mutating    | Writing/updating README, API docs, ADRs, guides.     |
| `product-designer`         | UX/IA/interaction/a11y spec + critique | Mutating | UI work: defines the design intent (Claude Design renders visuals); reviews the built UI. |
| `devops-sre`               | CI/CD, IaC, deploy, observability, on-call | Mutating | Pipelines, infra, deploy strategy + rollback, SLO/alerts, incident readiness. |

**Delivery layer (§4B — wraps the execution loop):**

| Agent                        | Purpose                              | Concurrency | Invoke when                                      |
| ---------------------------- | ------------------------------------ | ----------- | ------------------------------------------------ |
| `technical-program-manager`  | Scope, sequence, risk, stakeholders  | Mutating    | Planning an initiative, prioritizing, status/RAID, change control. |
| `scrum-master`               | Cadence, flow, impediments, health   | Mutating    | Sprint planning/daily/retro, flow health, removing blockers. |

**Concurrency classification.** Read-only agents are safe to invoke in parallel (they don't touch files); mutating agents must run serially against the same branch (they edit files and create commits). Today, Claude Code orchestrates this serially by default; the metadata future-proofs the system for orchestrators that parallelize the safe subset, which is typically a 2–5× speedup on multi-step turns.

**Trust-but-verify rule.** Subagents return narrative summaries that can hallucinate file paths, line numbers, or recent activity. Always verify a subagent's specific claims (file content, line refs, issue numbers) before acting on them. Treat the agent's report as a hypothesis to confirm with `Read` / `Grep`, not as ground truth.

**Subagents have no memory across invocations.** A subagent doesn't know what a previous invocation of itself decided. Pass forward decisions explicitly in the prompt or via a written artifact (a draft PR description, a comment in the issue, an entry in `docs/decisions/`).

------

## 2. Git Rules

- Never add `Co-authored-by` lines in commit messages.
- Never add `Generated with Claude Code` or similar attribution lines in PR descriptions or commit bodies.
- All commits must use the repo's configured git user name and email — do not override.
- Never commit as "claude", "Claude", "Cursor Agent", "cursoragent", or any AI tool name.
- Before committing, verify with `git config user.name` — if it's not a human name, fix it.
- **No AI tool mentions in any version-control artifact.** No mention of AI assistants (Claude, ChatGPT, Cursor, Copilot, Codex, Gemini, etc.), no mention of LLMs / AI in general, in commit messages, PR descriptions, PR review comments, branch names, or tag annotations. The provenance of the code is not part of the public record.
- **No AI tool mentions in code comments.** No `// generated by AI`, `// Claude wrote this`, `// see Claude conversation for context`, or similar. Code is judged on its merits, not its origin.
- **No AI tool mentions in user-facing artifacts.** No mention in CHANGELOG, release notes, README, docs/, or any text that ships to users, customers, or external collaborators. Internal scratch notes (your local TODO file, your `WIP.md`) are exempt — but anything that gets committed or shipped is not.
- Branch naming: `feat/<ticket-or-short-desc>`, `chore/<desc>`, `docs/<desc>`, `fix/<issue-num>-<short-desc>`, `refactor/<desc>`, `perf/<desc>`.
- Branch protection on `main` (or `master` / `trunk`) blocks direct push — always use PR. Never `git push --force` to the protected branch.
- Squash-merge PRs (single commit per ticket on the protected branch), unless your team has explicitly chosen merge-commits or rebase-merge for traceability reasons.

------

## 3. Coding Guidelines

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 3.1 Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 3.2 Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3.3 Surgical Changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### 3.4 Goal-Driven Execution

Define success criteria. Loop until verified.

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"
- "Optimize Y" → "Benchmark before and after; show the delta"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

------

## 4. Workflow: Four Hats

Every non-trivial change goes through four phases, in order. You wear all four hats sequentially — or delegate each to its scoped subagent. **Do not skip phases. Do not combine them.** Each phase produces an explicit output before the next begins.

### 4.1 Phase 1: Architect

Delegate to `architect` (or wear the hat yourself). Before any code, answer:

- What is the minimal change that solves this?
- What existing patterns does this codebase use? Match them.
- What are the failure modes? (auth, network, concurrency, data loss, partial failure, error propagation, retry storms, cascading timeouts)
- What should this NOT do? (scope boundaries)

**Output:** a brief plan (3–8 lines) with scope, approach, and what's explicitly out of scope. Get user approval before proceeding.

### 4.2 Phase 2: Engineer

Delegate to `senior-swe`. Implement the plan. Nothing more, nothing less.

- Follow the plan from Phase 1. If you discover the plan is wrong, stop and say so — don't silently deviate.
- One logical change per commit. Not one file per commit — one *purpose* per commit.
- Run the code. If it doesn't start, fix it before moving on.

**Output:** working code, committed to a branch, with a clear commit message referencing the issue.

### 4.3 Phase 3: Code Reviewer

Delegate to `code-reviewer`. Review the diff as if you didn't write it. Be adversarial.

Check every changed line against this list:

- [ ] Does this line trace to the task? If not, revert it.
- [ ] Any hardcoded values that should be config/env/feature-flag/constant?
- [ ] Any missing error handling for *realistic* failure cases? (not hypothetical ones)
- [ ] Any security issues? (unsanitized input, leaked secrets, injection — SQL/command/template, SSRF, deserialization, broken auth, broken access control)
- [ ] Does this match the existing code style? (naming, patterns, indentation, formatter rules)
- [ ] Any leftover debug code, `console.log` / `println` / `dbg!`, TODOs without ticket reference, commented-out blocks?
- [ ] State management: single source of truth maintained? No mutation of inputs?
- [ ] Boundaries respected: no leaking persistence types into UI, no leaking UI types into business logic, no global mutable state added?
- [ ] Backwards compatibility: does this break any public API? Schema migration safe to roll back? Feature-flagged if risky?
- [ ] Concurrency: any new shared mutable state? Cancellation propagated? Timeouts on external calls?
- [ ] Observability: new error paths logged with structured context? New metrics named consistently with existing ones?
- [ ] Tests: every new logic branch covered? Test names describe behavior, not implementation?
- [ ] CHANGELOG entry added for any user-visible change?

**Zero open comments rule:** every issue found must be fixed or explicitly justified before proceeding. No "we can fix this later." No parking.

**Output:** a clean diff with every review item resolved.

### 4.4 Phase 4: QA

Delegate to `qa`. Verify the change works end-to-end.

- Run the full local quality gate (see §7).
- Test the happy path manually or with a script.
- Test at least one realistic error case (bad input, missing config, network down, permission denied, dependency unavailable, disk full, etc.).
- Test that existing functionality still works (no regressions).
- If the change has a UI surface, verify it renders correctly. If it has an API surface, verify the contract.

If any test fails, diagnose the failure class before reacting (see §4.7). Do not push broken code.

**Output:** a summary of what was tested and the results.

### 4.5 When to skip phases

- Typo fix or config-only change: skip Phase 1 and Phase 4.
- `type:chore`, `type:docs`, `type:qa`: can skip Phases 1, 3, and 4 when the change is text-only, config-only, or test-config-only. Use judgement; if the change has real surface area (e.g. a new test infrastructure module), keep all four phases.
- Everything else: all four phases, every time.

### 4.6 Solo mode (no subagents)

When operating without subagent infrastructure, wear all four hats yourself, in order. Don't combine Phase 1 and Phase 2 into "I'll plan while coding" — the discipline of writing the plan down first is what catches the scope creep.

### 4.7 Error recovery by class

When something fails, the recovery path depends on the failure type. Don't reflexively "go back to Phase 2" — diagnose first. Mis-classifying a flake as a real bug wastes a Phase 2 cycle; mis-classifying a real bug as a flake ships the bug.

| Failure                                                      | Stays in current phase? | Recovery                                                     |
| ------------------------------------------------------------ | ----------------------- | ------------------------------------------------------------ |
| Rate limit (API 429)                                         | Yes                     | Exponential backoff. Don't restart the phase.                |
| Context overflow                                             | Yes                     | Invoke compaction or split the task. Don't restart.          |
| Auth failure                                                 | No                      | Stop, surface to user. Don't auto-retry.                     |
| Network error (transient)                                    | Yes                     | One retry with backoff, then surface.                        |
| Test failure (real bug)                                      | No                      | Back to Phase 2 (engineer).                                  |
| Test failure (flake)                                         | Yes                     | One retry of the test; if still red, treat as real bug.      |
| External service blip (CI infrastructure, package registry, container registry) | Yes                     | One retry; if still red, escalate to status page.            |
| Lint / type-check finding                                    | No                      | Back to Phase 2 — but narrow fix, not "fix all lint findings." |
| Formatter diff                                               | Yes                     | Apply formatter, recommit — stay in current phase.           |
| Visual snapshot / golden diff (intentional)                  | Yes                     | Regenerate goldens, eyeball diff, recommit — stay in current phase. |
| Visual snapshot / golden diff (unintentional)                | No                      | Back to Phase 2 — real regression.                           |
| Production build fails when dev build passes (build-variant-specific) | No                      | Back to Phase 2 — fix the import/dep that's debug-only.      |
| Subagent timeout                                             | Yes                     | Smaller scope (split the task), re-invoke. Don't pad the prompt. |
| Subagent hallucination caught in verify step                 | No                      | Re-invoke with explicit correction in the prompt. Don't trust narrative. |

The principle: a recovery strategy that retries indiscriminately accumulates state corruption; a strategy that always restarts the whole phase wastes cycles on transient noise. Each error class gets its own path inside the state machine, not an outer try-catch.

------

## 4B. Delivery Workflow (the layer that wraps the four hats)

§4's four hats are the *execution* loop for one change. The *delivery* layer decides which changes, in what order, at what risk, and keeps the team flowing. Two roles own it; neither writes code.

- **`technical-program-manager`** — owns the *what / why / when / risk*. Turns a goal into a scoped, sequenced, dependency- and risk-managed plan; prioritizes the backlog (RICE/WSJF/MoSCoW); runs change control; produces stakeholder/status comms. Frames product options and recommends — does not decide unilaterally.
- **`scrum-master`** — owns the *flow*. Runs the cadence (planning, daily, refinement, review, retro), enforces Definition of Ready/Done, tracks flow metrics, drives impediments out, guards team health. Orders work *within* a sprint; does not set priority.

**The loop, end to end:**
1. `technical-program-manager` — frame outcome + scope (in/out) + sequence + dependencies + RAID. Output: a delivery plan.
2. (UI work) `product-designer` — spec the experience, IA, states, and accessibility; **Claude Design** produces the visuals; hand the interaction contract to build.
3. `scrum-master` — capacity-plan the next increment; admit only items that meet Definition of Ready.
4. Per item, the §4 four-hat execution loop runs: `architect` → `senior-swe` → `code-reviewer` (+ `security-reviewer` / `performance-engineer` / `db-migration-specialist` as the change warrants) → `qa`.
5. `release-engineer` — preps the release per §6 (platform rule) and §9 (stacked PR); `devops-sre` runs the pipeline, deploys with a rollback path, and confirms the observability signals are green.
6. `docs-reconciler` (§10) + `scrum-master` — reconcile docs/board reality and report sprint/flow health; `tech-writer` updates user-facing docs; `product-designer` reviews the shipped UI against the spec.
7. `technical-program-manager` — update status (RAG), stakeholders, and the RAID register; feed learnings into the next plan. On a production incident: `devops-sre` + `debugger` lead, postmortem feeds back here.

**Boundary:** value & priority & risk = `technical-program-manager`; process & flow & team health = `scrum-master`; execution = the §4 agents. A priority dispute routes to the TPM/owner; a process or capacity dispute routes to the scrum-master. When the pod is one or two people, both delivery roles collapse into solo mode (§4.6) — the human wears the hats — but the artifacts (plan, RAID, DoD) still apply.

------

## 9. Stacked PR Workflow

When shipping multiple related PRs in a session:

1. **Local feature branch** off the protected branch, work the ticket.
2. **Commit** locally with the version bump + CHANGELOG entry.
3. **Don't push the version-bump + CHANGELOG combo until the prior PR has merged** — otherwise both PRs touch the same version lines and the second one hits a rebase conflict.
4. When the prior PR merges:
   - `git checkout <protected> && git pull --ff-only`
   - `git checkout <next-branch> && git rebase <protected>` (Git skips cherry-picks already in the protected branch)
   - Resolve any remaining conflicts (usually CHANGELOG section ordering + the version bump).
   - Push + open the next PR.

**Don't push and rely on platform conflict-resolution.** The squash-merge SHAs don't match local commits; rebasing locally is cleaner.

**Stash-and-checkout pitfall.** If you `git stash` mid-edit and `git checkout main`, the stash includes only the modified-and-tracked files. Untracked new files ARE included by default in modern git, but verify with `git stash show -u`. If you switch branches and lose work-in-progress, check `git fsck --lost-found` before panicking.

------

## 10. Reconciliation Cadence

Every 3–5 merged PRs, run a reconciliation pass before queueing the next feature. Delegate to `docs-reconciler` (it does exactly this, and applies a cheap-first tier discipline — single greps before full re-reads).

1. **Spec ↔ code:** scan spec / PRD / RFC sections touched by recent work; flag drift (a feature shipped that the spec still describes as "planned"; a feature the spec describes that's actually deferred under a follow-up issue).
2. **Roadmap ↔ shipped versions:** annotate phase rows with "(shipped vX.Y.Z)" or "(partial: shipped X, deferred Y)" — explicit partial-ship is better than silent drift.
3. **Open issues ↔ reality:** close issues whose deliverable shipped; comment on owner-bound issues with current state so the next session knows what's pending.
4. **CHANGELOG ↔ tags:** verify the section heads match the git tag history; the release workflow extracts these verbatim, so drift here ships an empty release body.
5. **README ↔ code:** does the elevator pitch still match? Are the badges current (build status, package version, license)? Are quickstart commands still correct?

Default fallback work when no ticket is queued: **reconciliation pass + ticket hygiene**, not speculative refactors. Don't invent work to fill time.

------

## 11. Secrets & Credentials

- Never commit secrets, tokens, API keys, certificates, private keys, signing keys.
- All secrets live in `.env` (gitignored) for local dev, and in CI secret stores / cloud KMS / vault for CI + production.
- Add `.env`, `.env.*`, `*.pem`, `*.key`, `*.keystore`, `*.jks`, `*.p12`, `credentials.json`, `service-account*.json`, etc. to `.gitignore` BEFORE the first commit.
- If a secret leaks into a commit (even a deleted line in history): **rotate first, scrub history second.** A removed-but-public secret is still a leaked secret.
- When pasting logs, diffs, or config into chats or issues, redact: `Authorization: Bearer ***REDACTED***`, `password=***`, `apikey=sk-***REDACTED***`.
- Use a secret scanner (gitleaks, trufflehog, GitHub secret scanning) in CI. Fail the build on detected secrets.

### 11.1 Secrets inventory

Document every secret the project needs. Suggested baseline (delete what doesn't apply, add domain-specific ones):

| Secret                                      | Used by                     | Purpose                                          | Rotation cadence                        |
| ------------------------------------------- | --------------------------- | ------------------------------------------------ | --------------------------------------- |
| `<artifact-registry>_TOKEN`                 | release workflow            | Publish package to npm/PyPI/crates.io/Maven/etc. | Every 90 days                           |
| `<container-registry>_TOKEN`                | release workflow            | Push container images                            | Every 90 days                           |
| `DATABASE_URL`                              | runtime + integration tests | Connect to primary database                      | Per-environment, rotated on team change |
| `OAUTH_CLIENT_SECRET` (per provider)        | runtime                     | OAuth flows                                      | Every 90 days                           |
| `WEBHOOK_SIGNING_SECRET`                    | runtime                     | Verify inbound webhooks                          | On team change                          |
| `SLACK_WEBHOOK_URL` / `DISCORD_WEBHOOK_URL` | release workflow            | Release notifications                            | On team change                          |
| `SENTRY_DSN` (or equivalent error tracker)  | runtime                     | Crash reporting                                  | Rarely (rotation breaks attribution)    |
| Signing keys (binary, package, container)   | release workflow            | Sign published artifacts                         | Never (rotation breaks trust chain)     |

Maintain this table in `docs/SECRETS.md`. Audit CI logs for any secret name that's been removed but is still referenced.

------

## 14. Anti-Patterns (learned-the-hard-way)

- **Don't reach for a new dependency** when stdlib + 20 lines solve it. Every dep adds attack surface, transitive risk, license review, supply-chain risk, and resolution time. The bar to add a dep should be roughly "what we'd write would be substantially worse than the lib."
- **Don't silence the linter / type-checker / test** to make CI pass. The signal is doing its job. Fix the underlying problem or document the deliberate exception with a comment naming the issue link.
- **Don't `--no-verify` to skip a failing pre-commit hook.** Investigate the hook failure; the hook usually catches real problems.
- **Don't `--amend` after a failed pre-commit hook.** The hook failure means the commit didn't happen — `--amend` would modify the PREVIOUS commit, destroying that work. Fix the issue, re-stage, create a NEW commit.
- **Don't trust subagent "I remember from earlier" claims.** Subagents have no memory across invocations. Confirm specific file paths, line numbers, or commit SHAs with `Read` / `Grep` / `Bash` before acting on them.
- **Don't catch broad exception types** (`except Exception:`, `catch (Throwable e)`, `catch(_)`) unless you're at a request/job boundary and intend to log+continue. Narrow catches at the point of failure.
- **Don't use mocking frameworks for repository-shaped interfaces.** Hand-rolled fakes with real state are simpler and survive refactors better.
- **Don't refactor adjacent code** while implementing a feature. Separate refactor PRs from feature PRs; each gets cleaner review.
- **Don't push directly to the protected branch.** The PR gate exists for a reason. If you genuinely need to bypass it (production emergency), document why and re-add the protection after.
- **Don't merge with red CI.** Even "I know it's a flake." If it's a flake, fix the flake; if it's a real failure, the gate did its job. Override is a smell.
- **Don't ship test config changes alongside feature changes.** When the feature regression you didn't catch ships, you want to bisect cleanly.
- **Don't write tests that test the framework, not your code.** A test that asserts `JSON.parse('{"a":1}').a === 1` tests the runtime. A test that asserts your domain logic handles the parsed object correctly tests you.
- **Don't use real wall-clock time in tests.** Inject a clock. Tests that pass at 9 AM and fail at midnight haunt CI.
- **Don't use unseeded random data in tests.** Use a fixed seed; reproducibility is non-negotiable. If a test exposes a real bug only under certain random inputs, that's a property-based test; capture the seed and turn it into a deterministic regression.
- **Don't depend on test execution order.** Parallel-safe + order-independent. A test that breaks when run in isolation is broken.
- **Don't commit large binary blobs** without Git LFS. The repo grows monotonically; cloning slows for everyone forever.
- **Don't change formatter rules incidentally.** A diff that's 90% reformatted and 10% feature is unreviewable. Run the formatter, commit it separately, then the feature.
- **Don't add TODOs without ticket references.** A TODO becomes a permanent fixture without a deadline. `// TODO(#123): handle empty input` is acceptable; `// TODO: fix this` is debt with no owner.
- **Don't wholesale disable security features** ("temporarily" turn off CSRF, "just for this endpoint" skip auth). Temporary becomes permanent. Add the exception with explicit justification or design around the constraint.

------

## 15. Memory & Continuity (when working as an AI agent)

These tips assume operation with persistent file-based memory across sessions (e.g. Claude Code's CLAUDE.md / memory tooling):

- **Save user feedback as it arrives.** Especially "no, not that" corrections — they don't repeat unless you ask the user to. Also save confirmations of non-obvious decisions ("the bundled PR was right here").
- **Save project context but not code patterns.** Code can be re-read; "the maintainer is the only QA tester" can't be derived from `git log`.
- **Convert relative dates to absolute** when saving ("Thursday" → "2026-03-05"). Memory outlives the conversation.
- **Don't trust your own memory as ground truth.** Before recommending from memory ("the X function exists in Y file"), grep / `Read` to verify it's still there.
- **Subagents have no memory.** A subagent invocation starts blank every time. Pass forward decisions explicitly in the prompt; don't say "as we decided earlier" — the subagent wasn't there.

------

## 16. PR Description Template

> **Per §2: no mention of AI tools, LLMs, or assistants** in PR descriptions, test plans, or anywhere else in the PR. The template below contains no such mentions and you shouldn't add any.

```markdown
## Summary

<1–3 sentences explaining what this PR does and why>

- **<key change 1>** — <one-line description>
- **<key change 2>** — <one-line description>

### Deferred / out of scope

- <thing you intentionally didn't do, with reason>

## Test plan

- [x] Local quality gate green: `<formatter>`, `<linter>`, `<type-checker>`, `<unit-tests>`, `<build>`, `<integration-tests>` (delete what doesn't apply)
- [x] Any domain-specific audits clean
- [ ] On-target verification:
  - <specific check 1>
  - <specific check 2>

<Closes #N OR Refs #N>
```

------

## 17. Scaling beyond solo

When a second engineer joins this codebase (or this CLAUDE.md gets dropped into a second project), four things need to scale. Designing for them now is an order of magnitude cheaper than retrofitting later.

### 17.1 State across sessions

- `docs/decisions/` captures non-obvious choices with dates. Future engineers (human or AI) read this before re-deriving. Format: `YYYY-MM-DD-<slug>.md` per decision, with **Context / Decision / Consequences** sections (the ADR pattern).
- **Session summaries.** When ending a session with WIP, write a `WIP.md` at the branch root with three sections: what's done, what's left, blocker (if any). Commit it. The next session — yours or someone else's — starts from a known state.
- **Memory tiers.** Per-user / per-machine memory (Claude Code's `~/.claude/CLAUDE.md`) holds personal context — your preferred tools, your working hours, your project list. Per-project memory (this `CLAUDE.md`) is committed and shared. Don't conflate them: personal preferences in the repo file pollute everyone else's context.

### 17.2 Permissions at team scale

- `.claude/settings.json` (committed) — patterns the team agrees on. Conservative — only what everyone needs.
- `.claude/settings.local.json` (gitignored) — individual preferences. Pre-approve patterns that you personally trust but that the team hasn't ratified.
- Never commit `--dangerously-skip-permissions` aliases or shell functions that bypass the permission system. The audit trail matters; per-pattern allowlists are the right granularity.

### 17.3 Parallelism / coordination

- **Read-only subagents** (architect, code-reviewer, qa, docs-reconciler) can be invoked concurrently by different team members on the same branch. They don't touch files — no race conditions.
- **Mutating subagents** (senior-swe, release-engineer) coordinate via PR review. Only one mutating agent in flight per branch at a time.
- **Long-running reconciliation passes** belong in CI on a schedule (weekly cron, or post-release hook), not in a developer's interactive session. The `docs-reconciler` agent runs at tier 1 (cheap greps) interactively; tier 3 (full re-read) runs in CI.

### 17.4 Shared subagent library

- Subagents in `.claude/agents/` are committed and travel with the repo. Everyone on the team gets the same architect / reviewer / qa personas — that's the point.
- Personal extensions live in `~/.claude/agents/` (your home, not the repo). Don't fork the repo's agents in-place; layer personal agents on top.
- When a personal agent proves valuable across multiple PRs, propose adding it to the repo via a `chore/agent: ...` PR. The team can review, refine, and adopt.
- **Concurrency metadata travels with the agent.** Always include `concurrency: read-only` or `concurrency: mutating` in the frontmatter. Future orchestrators rely on it for parallelization decisions.

------

## 18. Extension Points

The agent infrastructure supports four no-code extensions. If you find yourself wanting to fork or patch the Claude Code binary, stop — one of these likely covers it.

| Extension       | Format                                            | Location                            | Use case                                                     |
| --------------- | ------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------ |
| **Subagents**   | Markdown with YAML frontmatter                    | `.claude/agents/*.md`               | New personas (e.g. `security-reviewer`, `performance-engineer`, `db-migration-specialist`) |
| **Skills**      | Markdown with YAML frontmatter + supporting files | `.claude/skills/<name>/SKILL.md`    | Reusable workflows (e.g. `release-prep`, `add-feature-flag`, `db-migration`, `dependency-upgrade`) |
| **Hooks**       | Shell scripts                                     | `.claude/hooks/*.sh`                | Pre/post-tool-call validation, audit logging, custom permission gates |
| **MCP servers** | Protocol-based (any language)                     | Configured in user/project settings | Tool integrations (issue tracker, error tracking service, package registry, custom databases) |

The discipline: if a use case doesn't fit any of these, the architecture has a gap worth reporting upstream rather than working around. Forking the binary trades extensibility for ownership burden — every Claude Code release becomes a merge conflict.

------

<!-- ===== CACHE BOUNDARY ===== --> <!-- Everything above this line is static across releases. Edits invalidate the     entire prompt cache for this file. Make changes to workflow rules, patterns,     and anti-patterns above sparingly.      Everything below this line is per-project and edited frequently. Cache     invalidations are scoped to the bottom partition only. Put dynamic content     here: current version, stack details, project-specific overrides, links to     live spec/roadmap files, etc.      If you find yourself wanting to put project-specific content above this     boundary, ask whether it's truly project-specific (then below) or actually     a general pattern worth promoting (then above, with care). -->


## 19. Project Context

### 19.1 What is this project?

- **One-paragraph description:** 
  - TODO: one-paragraph description (the product, the user, the value).

### 19.2 Stack

State versions specifically. "Latest" rots; pinned versions document reality.

- **Language(s):** TODO
  - *Example:* `TypeScript 5.6, with a small Rust binary (1.81) for the diff engine`
- **Runtime / platform:** TODO
  - *Example:* `Node.js 22 LTS on Alpine 3.20 containers`
- **Framework(s):** TODO
  - *Example:* `Fastify 5 for HTTP, BullMQ for jobs, Drizzle ORM`
- **Storage:** TODO
  - *Example:* `PostgreSQL 16 (primary), Redis 7 (queue + cache), S3-compatible object store for diffs`
- **Build / package:** TODO
  - *Example:* `pnpm 9, with Turborepo for the monorepo`
- **Test runner:** TODO
  - *Example:* `vitest for unit + integration, Playwright for end-to-end`
- **CI:** TODO
  - *Example:* `GitHub Actions, self-hosted runners for the integration tests, GitHub-hosted for everything else`
- **Distribution channel:** TODO
  - *Example:* `Container image pushed to GHCR, deployed via ArgoCD to internal Kubernetes`

### 19.3 Local quality gate

Concrete commands a fresh clone can run. Order matches §7.1 (fail fast on cheap steps).

bash

```bash
# Example — replace with your project's actual commands.
pnpm format:check               # prettier --check .
pnpm lint                       # eslint . --max-warnings=0
pnpm typecheck                  # tsc --noEmit
pnpm test                       # vitest run --coverage
pnpm build                      # next build && tsc -p tsconfig.build.json
pnpm test:integration           # vitest run --config vitest.integration.config.ts
```

Principle: every command must be runnable from a fresh clone without further setup beyond `pnpm install`. If a step needs Docker, scaffolded fixtures, or env vars, document the prerequisite explicitly.

### 19.4 Current release pointers

- **Live version:** TODO
  - *Example:* `v2.14.3 (released 2026-04-22)`
- **In flight:** TODO
  - *Example:* `v2.15.0 — theme: "webhook retry hardening", ETA 2026-05-15`
- **CHANGELOG:** ./CHANGELOG.md
- **Spec / PRD:** ./docs/SPEC.md
  - *If specs live elsewhere (Notion, Linear, Confluence), put the canonical link here. Don't maintain two sources of truth.*
- **Roadmap:** ./docs/ROADMAP.md
- **WIP file:** ./WIP.md
  - *Only exists when a session ended mid-task; deleted on next merge. See §17.1.*

### 19.5 Compliance scope

- TODO
  - *Example (B2B SaaS in EU + US):* `GDPR (EU users), CCPA (CA users), SOC 2 Type II (in audit, target 2026-Q4). No HIPAA. No PCI-DSS — payment data is tokenized by Stripe; we never see PAN.`
  - *Example (internal tool):* `None — internal-only, no external users, no regulated data.`
  - *Principle:* be specific about what applies AND what explicitly doesn't. "SOC 2 doesn't apply because X" is more useful than silence.

### 19.6 Project-specific overrides

> Each override erodes the predictability §1–18 provides; treat them as debt with a documented reason. Review quarterly: can any be removed?

- *(none — defaults apply)*
- *Example override:* `§7.1 quality gate skips integration tests on PR (runs nightly instead) — reason: integration suite takes 25 min, blocks PR throughput. Tracked in #1247 for a fix.`
- *Example override:* `§2 squash-merge replaced with rebase-merge — reason: we use a release-train workflow that depends on commit-level traceability.`

------

## Closing thought

These rules trade speed for predictability. The payoff is that a future agent (human or AI) picking up this codebase mid-stream doesn't have to learn the bugs by hitting them. If a rule here doesn't apply to your project, delete it — but think twice before loosening one.

When in doubt, ask. When the answer is "it depends," document the decision in `docs/decisions/` so the next person doesn't have to re-derive it.
