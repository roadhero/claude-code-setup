# CLAUDE.md — Coastline

<!--
  FICTIONAL EXAMPLE. "Coastline" is a made-up product invented only to show
  what a filled-in §19 looks like. Copy templates/CLAUDE.project.md into your
  repo as CLAUDE.md and replace this content with your own.
-->

> Spine (workflow, git, coding, secrets, anti-patterns…) loads from ~/.claude/CLAUDE.md.
> Platform rules live in ~/.claude/rules/; each loads when Claude reads a file matching its stack's `paths:` glob (path-triggered — `.kt` → android, `.swift` → ios, `.ts`/`.py` → web, `.cpp`/`.cu` → compute), so you don't reference them here.
> This file holds ONLY project-specific context. Keep it short.

## 19. Project Context

### 19.1 What is this project?

- **One-paragraph description:**
  - Coastline is a status-page and uptime monitor for small SaaS teams. It runs scheduled HTTP and TCP checks from three regions, rolls results into a public status page, and pushes incident alerts to Slack and email. The user is a solo founder or a small ops team that wants a credible status page without standing up their own monitoring stack. The value is "looks like Statuspage, costs like a side project."

### 19.2 Stack

State versions specifically. "Latest" rots; pinned versions document reality.

- **Language(s):** TypeScript 5.6 (strict), with a small Go 1.23 worker for the check runner.
- **Runtime / platform:** Node.js 22 LTS for the API; the Go worker ships as a static binary in a distroless container.
- **Framework(s):** Fastify 5 for HTTP, BullMQ for the check queue, Drizzle ORM for data access, Next.js 15 (App Router) for the dashboard and public status page.
- **Storage:** PostgreSQL 16 (primary), Redis 7 (BullMQ + rate-limit cache). No object store.
- **Build / package:** pnpm 9, Turborepo monorepo (`apps/api`, `apps/web`, `apps/worker`, `packages/shared`).
- **Test runner:** vitest for unit + integration, Playwright for the dashboard e2e.
- **CI:** GitHub Actions. GitHub-hosted runners throughout; integration job spins up Postgres + Redis as service containers.
- **Distribution channel:** Container images to GHCR, deployed to Render (API + worker) and Vercel (web), promoted on green `main`.

### 19.3 Local quality gate

Concrete commands a fresh clone can run. Order matches §7.1 (fail fast on cheap steps).

```bash
pnpm format:check               # prettier --check .
pnpm lint                       # eslint . --max-warnings=0
pnpm typecheck                  # tsc --noEmit across the workspace
pnpm test                       # vitest run --coverage
pnpm build                      # turbo run build
pnpm test:integration           # vitest run --config vitest.integration.config.ts (needs Docker)
```

Prerequisite: `pnpm install` then `docker compose up -d db redis` before `test:integration`. Everything else runs from a clean clone with no further setup.

### 19.4 Current release pointers

- **Live version:** v1.4.2 (released 2026-05-30)
- **In flight:** v1.5.0 — theme: "multi-region check fan-out", ETA 2026-06-20
- **CHANGELOG:** ./CHANGELOG.md
- **Spec / PRD:** ./docs/SPEC.md
- **Roadmap:** ./docs/ROADMAP.md
- **WIP file:** ./WIP.md (only exists when a session ended mid-task; deleted on next merge)

### 19.5 Compliance scope

- GDPR (EU users of the dashboard) and CCPA (CA users). No HIPAA, no PCI-DSS — billing is handled by Stripe Checkout and we never see card data. Public status pages contain no personal data by design. SOC 2 does not apply yet (no enterprise customers requiring it); revisit when the first one asks.

### 19.6 Project-specific overrides

> Each override erodes the predictability §1–18 provides; treat them as debt with a documented reason. Review quarterly: can any be removed?

- §7.1 quality gate runs the Playwright e2e suite nightly rather than on every PR — reason: full e2e takes ~12 min and blocks PR throughput; smoke subset still runs on PR. Tracked in #312 to re-evaluate once the suite is parallelized.

------
