# Workflow reference — Four Hats, error recovery, delivery layer

> Full detail for CLAUDE.md §4 / §4B. The spine carries the phase names and the skip/solo rules; the checklist, the error-recovery table, and the delivery loop live here so they load on demand, not every session.

## §4. Workflow: Four Hats

Every non-trivial change goes through four phases, in order. You wear all four hats sequentially — or delegate each to its scoped subagent. **Do not skip phases. Do not combine them.** Each phase produces an explicit output before the next begins.

### 4.1 Phase 1: Architect

Delegate to `architect` (or wear the hat yourself). Before any code, answer:

- What is the minimal change that solves this?
- What existing patterns does this codebase use? Match them.
- What are the failure modes? (auth, network, concurrency, data loss, partial failure, error propagation, retry storms, cascading timeouts)
- What should this NOT do? (scope boundaries)

**Output:** a brief plan (3–8 lines) with scope, approach, and what's explicitly out of scope. Get user approval before proceeding. To make the read-only guarantee real rather than aspirational, run this phase in Claude Code's **plan mode** (Shift+Tab / the `plan` permission mode) — the harness blocks edits until you approve.

### 4.2 Phase 2: Engineer

Delegate to `senior-swe`. Implement the plan. Nothing more, nothing less.

- Follow the plan from Phase 1. If you discover the plan is wrong, stop and say so — don't silently deviate.
- One logical change per commit. Not one file per commit — one *purpose* per commit.
- Run the code. If it doesn't start, fix it before moving on.

**Output:** working code, committed to a branch, with a clear commit message referencing the issue.

### 4.3 Phase 3: Code Reviewer

Delegate to `code-reviewer`. Review the diff as if you didn't write it. Be adversarial. Check every changed line against this list:

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

- Run the full local quality gate (see the platform rule §7).
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

## §4B. Delivery Workflow (the layer that wraps the four hats)

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
