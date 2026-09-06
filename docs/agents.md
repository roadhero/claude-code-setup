# Subagent roster — full tables & rationale

> Full detail for CLAUDE.md §1. The spine carries a compact index and the invocation rules; the full per-agent tables and the concurrency rationale live here.

Agents live under `.claude/agents/` (project) or `~/.claude/agents/` (user, all projects). Invoke them by name, or let them auto-dispatch on their description. They're scoped — each loads only the context it needs, so they're faster and less drift-prone than one mega-agent. In an Android repo, the project-scoped Android-flavored agents override the generic ones of the same name.

**Core four-hat chain (§4 execution loop):**

| Agent              | Phase / Purpose              | Concurrency | Invoke when                                                                                   |
| ------------------ | ---------------------------- | ----------- | --------------------------------------------------------------------------------------------- |
| `architect`        | Phase 1 planner              | Read-only   | Any non-trivial change. Produces the scoped plan before code is written.                      |
| `senior-swe`       | Phase 2 implementer          | Mutating    | After plan approval. Writes code matching existing patterns.                                  |
| `code-reviewer`    | Phase 3 adversarial reviewer | Read-only   | Before pushing. Walks the review checklist against the diff, and the diff against the plan.   |
| `qa`               | Phase 4 verifier             | Read-only   | After review. Generates the test plan and runs the local gate.                                |
| `release-engineer` | Release prep                 | Mutating    | Bumping versions, writing CHANGELOG, tagging.                                                 |
| `docs-reconciler`  | Drift detection              | Read-only   | Every 3–5 merged PRs. Surfaces drift between specs ↔ code ↔ CHANGELOG ↔ README ↔ open issues. |

**Specialists & contributors (pulled in around the four-hat chain — design upstream, ops downstream, the rest as the change warrants):**

| Agent                     | Purpose                                    | Concurrency | Invoke when                                                                               |
| ------------------------- | ------------------------------------------ | ----------- | ----------------------------------------------------------------------------------------- |
| `security-reviewer`       | Security + supply-chain audit              | Read-only   | Change touches auth, crypto, input, secrets, deps; pre-release.                           |
| `performance-engineer`    | Performance analysis                       | Read-only   | Hot path, query, startup, memory; latency/jank regressions.                               |
| `db-migration-specialist` | Safe schema migrations                     | Mutating    | Any column/table/entity/data-shape change.                                                |
| `debugger`                | Reproduce → root-cause                     | Read-only   | A failing test/crash/regression whose cause isn't obvious.                                |
| `tech-writer`             | Authors docs                               | Mutating    | Writing/updating README, API docs, ADRs, guides.                                          |
| `product-designer`        | UX/IA/interaction/a11y spec + critique     | Mutating    | UI work: defines the design intent (Claude Design renders visuals); reviews the built UI. |
| `devops-sre`              | CI/CD, IaC, deploy, observability, on-call | Mutating    | Pipelines, infra, deploy strategy + rollback, SLO/alerts, incident readiness.             |

**Delivery layer (§4B — wraps the execution loop):**

| Agent                       | Purpose                             | Concurrency | Invoke when                                                        |
| --------------------------- | ----------------------------------- | ----------- | ------------------------------------------------------------------ |
| `technical-program-manager` | Scope, sequence, risk, stakeholders | Mutating    | Planning an initiative, prioritizing, status/RAID, change control. |
| `scrum-master`              | Cadence, flow, impediments, health  | Mutating    | Sprint planning/daily/retro, flow health, removing blockers.       |

**Concurrency classification.** Mutating agents hold `Edit`/`Write` and must run serially against the same branch; read-only agents omit `Edit`/`Write` and are safe to invoke in parallel. (Read-only agents may still hold `Bash` for inspection, so the boundary is a documented convention backed by the `tools:` list, not a hard sandbox — the Concurrency column above is the authoritative index.) Claude Code orchestrates serially today; an orchestrator that parallelized the read-only subset could read each agent's `tools:` allowlist to derive the safe set — typically a 2–5× speedup on multi-step turns. The read-only/mutating class is signalled by the `tools:` allowlist, **not** a frontmatter flag — `concurrency:` is not a supported sub-agent field, so the harness silently ignores it; the Concurrency column here is documentation for humans.

**Per-stack override packs.** The generic roster ships in `agents/` (15). Stack-specific packs — `agents-android/` (7), `agents-ios/` (7), `agents-compute/` (13) — override the global agent of the same `name:` when dropped into a repo's `.claude/agents/`. See `STRUCTURE.md` → "Agent override model" for which names each pack overrides and which globals fall through.
