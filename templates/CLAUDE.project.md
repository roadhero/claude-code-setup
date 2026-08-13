# CLAUDE.md — <project name>

> Spine (workflow, git, coding, secrets, anti-patterns…) loads from ~/.claude/CLAUDE.md.
> Platform rules live in ~/.claude/rules/; each loads when Claude reads a file matching its stack's `paths:` glob (path-triggered — `.kt` → android, `.swift` → ios, `.ts`/`.py` → web, `.cpp`/`.cu` → compute), so you don't reference them here.
> This file holds ONLY project-specific context. Keep it short.

## 19. Project Context

### 19.1 What is this project?

- **One-paragraph description:**
  - TODO: one-paragraph description (the product, the user, the value).

### 19.2 Stack

State versions specifically. "Latest" rots; pinned versions document reality.

- **Language(s):** TODO
  - _Example:_ `TypeScript 5.6, with a small Rust binary (1.81) for the diff engine`
- **Runtime / platform:** TODO
  - _Example:_ `Node.js 22 LTS on Alpine 3.20 containers`
- **Framework(s):** TODO
  - _Example:_ `Fastify 5 for HTTP, BullMQ for jobs, Drizzle ORM`
- **Storage:** TODO
  - _Example:_ `PostgreSQL 16 (primary), Redis 7 (queue + cache), S3-compatible object store for diffs`
- **Build / package:** TODO
  - _Example:_ `pnpm 9, with Turborepo for the monorepo`
- **Test runner:** TODO
  - _Example:_ `vitest for unit + integration, Playwright for end-to-end`
- **CI:** TODO
  - _Example:_ `GitHub Actions, self-hosted runners for the integration tests, GitHub-hosted for everything else`
- **Distribution channel:** TODO
  - _Example:_ `Container image pushed to GHCR, deployed via ArgoCD to internal Kubernetes`

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
  - _Example:_ `v2.14.3 (released 2026-04-22)`
- **In flight:** TODO
  - _Example:_ `v2.15.0 — theme: "webhook retry hardening", ETA 2026-05-15`
- **CHANGELOG:** ./CHANGELOG.md
- **Spec / PRD:** ./docs/SPEC.md
  - _If specs live elsewhere (Notion, Linear, Confluence), put the canonical link here. Don't maintain two sources of truth._
- **Roadmap:** ./docs/ROADMAP.md
- **WIP file:** ./WIP.md
  - _Only exists when a session ended mid-task; deleted on next merge. See §17.1._

### 19.5 Compliance scope

- TODO
  - _Example (B2B SaaS in EU + US):_ `GDPR (EU users), CCPA (CA users), SOC 2 Type II (in audit, target 2026-Q4). No HIPAA. No PCI-DSS — payment data is tokenized by Stripe; we never see PAN.`
  - _Example (internal tool):_ `None — internal-only, no external users, no regulated data.`
  - _Principle:_ be specific about what applies AND what explicitly doesn't. "SOC 2 doesn't apply because X" is more useful than silence.

### 19.6 Project-specific overrides

> Each override erodes the predictability §1–18 provides; treat them as debt with a documented reason. Review quarterly: can any be removed?

- _(none — defaults apply)_
- _Example override:_ `§7.1 quality gate skips integration tests on PR (runs nightly instead) — reason: integration suite takes 25 min, blocks PR throughput. Tracked in #1247 for a fix.`
- _Example override:_ `§2 squash-merge replaced with rebase-merge — reason: we use a release-train workflow that depends on commit-level traceability.`

---
