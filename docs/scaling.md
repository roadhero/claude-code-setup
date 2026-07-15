# Scaling beyond solo

> Full detail for CLAUDE.md §17. The spine carries the one-line pointer; the four scaling concerns live here.

When a second engineer joins this codebase (or this CLAUDE.md gets dropped into a second project), four things need to scale. Designing for them now is an order of magnitude cheaper than retrofitting later.

## 17.1 State across sessions

- `docs/decisions/` captures non-obvious choices with dates. Future engineers (human or AI) read this before re-deriving. Format: `YYYY-MM-DD-<slug>.md` per decision, with **Context / Decision / Consequences** sections (the ADR pattern).
- **Session summaries.** When ending a session with WIP, write a `WIP.md` at the branch root with three sections: what's done, what's left, blocker (if any). Commit it. The next session — yours or someone else's — starts from a known state.
- **Memory tiers.** Per-user / per-machine memory (Claude Code's `~/.claude/CLAUDE.md`) holds personal context — your preferred tools, your working hours, your project list. Per-project memory (a repo's `CLAUDE.md`) is committed and shared. Don't conflate them: personal preferences in the repo file pollute everyone else's context.

## 17.2 Permissions at team scale

- `.claude/settings.json` (committed) — patterns the team agrees on. Conservative — only what everyone needs.
- `.claude/settings.local.json` (gitignored) — individual preferences. Pre-approve patterns that you personally trust but that the team hasn't ratified.
- Never commit `--dangerously-skip-permissions` aliases or shell functions that bypass the permission system. The audit trail matters; per-pattern allowlists are the right granularity.

## 17.3 Parallelism / coordination

- **Read-only subagents** (architect, code-reviewer, qa, docs-reconciler) can be invoked concurrently by different team members on the same branch. They don't touch files — no race conditions.
- **Mutating subagents** (senior-swe, release-engineer) coordinate via PR review. Only one mutating agent in flight per branch at a time.
- **Long-running reconciliation passes** belong in CI on a schedule (weekly cron, or post-release hook), not in a developer's interactive session. The `docs-reconciler` agent runs at tier 1 (cheap greps) interactively; tier 3 (full re-read) runs in CI.

## 17.4 Shared subagent library

- Subagents in `.claude/agents/` are committed and travel with the repo. Everyone on the team gets the same architect / reviewer / qa personas — that's the point.
- Personal extensions live in `~/.claude/agents/` (your home, not the repo). Don't fork the repo's agents in-place; layer personal agents on top.
- When a personal agent proves valuable across multiple PRs, propose adding it to the repo via a `chore/agent: ...` PR. The team can review, refine, and adopt.
- **Read-only vs mutating is set by the `tools:` allowlist, not a frontmatter flag** — a read-only agent omits `Edit`/`Write`; a mutating one includes them. The authoritative read-only/mutating index is the Concurrency column of the roster table in `~/.claude/docs/agents.md`. Don't add a `concurrency:` frontmatter key — it is not a supported sub-agent field, so the harness silently ignores it; confirm any key against the sub-agents docs first.
