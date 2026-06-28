---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.vue"
  - "**/*.svelte"
  - "**/*.py"
  - "**/*.go"
  - "**/*.rs"
  - "**/*.rb"
  - "**/package.json"
  - "**/tsconfig*.json"
  - "**/pyproject.toml"
  - "**/go.mod"
  - "**/Cargo.toml"
  - "**/next.config.*"
  - "**/vite.config.*"
---

# Web / Backend Overlay (general software)

> Loads when web/backend source is detected (TS/JS, Python, Go, Rust, Ruby, …). This is the non-mobile flavor of the architecture/release/testing/concurrency/compliance sections. §13 retains all distribution targets (web, mobile, backend, libraries, CLI) as a cross-reference.

## 5. Architecture Patterns

These are principles, not preferences. The specific names and tools differ by stack — the discipline doesn't. Match the patterns your codebase already uses unless you have a documented reason to deviate; if you're starting from scratch, the defaults below apply.

### 5.1 Separation of concerns

Three layers, in order: **presentation / API surface ↔ business logic ↔ data / persistence**. Dependencies point inward. Business logic doesn't know about HTTP, doesn't know about SQL, doesn't know about React/Vue/Compose. Presentation calls business logic; business logic calls data; never the reverse.

- **Don't leak persistence types upward.** A SQL row, an ORM entity, a Mongo document — none of these belong in a controller or a UI handler. Map at the boundary.
- **Don't leak presentation types downward.** Business logic doesn't know about request objects, response objects, or framework-specific contexts.
- **Test the layers independently.** Business logic tests should run with no HTTP server, no database — only language stdlib.

### 5.2 State management

Pick a discipline and enforce it.

- **Single source of truth** for any piece of state. If two components both own the user's name, you have a bug waiting to happen.
- **Immutable updates** for shared state. Copy-and-modify, not in-place mutation. (Performance-critical hot loops are exceptions, deliberately marked.)
- **Unidirectional data flow.** Events go one way (user → handler → state mutation); state goes the other way (state → view). No cycles.
- **State machines are explicit, not implicit.** A field called `status: 'loading' | 'success' | 'error'` is a state machine; document its transitions in code (a sealed type, an enum, a state-pattern object), not in comments.

### 5.3 Dependency boundaries

- **Interfaces / protocols at every boundary.** Production code depends on the abstraction; test code swaps in fakes.
- **Composition root:** one place where concrete implementations get wired together (a `main` function, a DI container, a manual wiring file). Everywhere else accepts dependencies as parameters.
- **Test doubles**:
  - **Fakes** (working implementations with simplified storage — e.g. an in-memory repository) for behavior tests.
  - **Mocks / spies** only when you specifically want to assert "method X was called with arguments Y" — never as a default. Mocks are an anti-pattern for repository-shaped surfaces.

### 5.4 Error handling

Pick one of two disciplines and stick with it across the codebase:

- **Result / Either / sum types** (Rust, Go-with-explicit-errors, fp-ts, kotlin.Result, neverthrow, etc.) — every fallible function returns a wrapped result; the caller must handle both branches. Compiler-enforceable. Verbose.
- **Exceptions** (Java, C#, Python, Ruby, JS/TS without explicit-error culture) — fallible operations throw; specific catch boundaries handle them. Less verbose, less compiler-enforceable. Demands discipline at catch sites.

Within either:

- **Never silently swallow errors.** A catch block that logs and continues is fine; a catch block that does neither is a bug.
- **Re-throw or re-raise** unless you have a specific recovery strategy. Catch broadly only at the top of a request/job boundary.
- **Don't catch and re-throw as a generic error type** without preserving the cause. Lost stack traces are bug-investigation poison.
- **Cancellation / interruption** signals (e.g. `CancellationException` in Kotlin, `KeyboardInterrupt` in Python, `context.Canceled` in Go, `AbortError` in JS) should NEVER be caught and swallowed. They mean "stop"; let them propagate.

### 5.5 Logging and observability

- **Structured logging** (JSON or key-value). Not `print(f"user {name} did thing")` — `logger.info("user_action", user_id=..., action=...)`.
- **Log levels mean things.** `debug` = dev-only, `info` = normal operation, `warn` = unexpected but recoverable, `error` = something failed and someone should look. Don't log everything at `info`.
- **Don't log secrets.** Auth tokens, passwords, PII — redact before logging. Audit log emissions for new-secret leaks during PR review.
- **Metrics for rates and durations**, not for individual events. Use the right primitive: counter (monotonic), gauge (instantaneous), histogram (distribution).
- **Traces for cross-service flows.** A request that touches 5 services is one trace with 5 spans, not 5 disconnected log lines.
- **Error context.** When you catch and re-raise, attach context the original throw site didn't have (`user_id=42, request_id=abc, retry_count=2`).

### 5.6 Backwards compatibility

- **Public APIs follow SemVer** (see §6). Breaking changes require a major bump and a migration note.
- **Database migrations are forward-and-back compatible across one release.** Deploy: (1) add new column nullable, (2) ship code that writes to both old and new, (3) backfill, (4) ship code that reads from new only, (5) drop old. Don't fuse steps 1 and 5.
- **Feature flags for risky changes.** Default off; flip in production after canary monitoring. Remove the flag (and the old code path) when stable.
- **Deprecation, not deletion.** Mark deprecated for one minor release before removing. Log a warning when called.

### 5.7 Public API design

If the code you're writing will be consumed by other code (a library, an SDK, an internal microservice, a CLI), design the API before writing the implementation:

- **The 80% case should be one obvious call.** If users have to combine three functions to do the common thing, add a convenience function.
- **Don't expose configuration options for hypothetical needs.** Every option is a maintenance cost.
- **Errors are part of the API.** Changing the error type or error message is a breaking change. Document and version.
- **Stability over completeness.** Ship the minimum first; users will tell you what's missing.

### 5.8 Concurrency model

Pick a concurrency model deliberately (threads + locks, async/await, actors, CSP / channels, message queues, single-threaded event loop). Mixing models within a single subsystem is an anti-pattern.

- **Threads + shared mutable state requires locks.** Locks held across awaits/yields are reentrant deadlocks waiting to happen.
- **Async / await is single-threaded by default.** A `await long_computation()` blocks the whole event loop unless dispatched. Move CPU-bound work to a worker pool.
- **Actors / message passing** trades sync overhead for no-shared-state safety. Each actor processes messages serially.
- **Cancellation is a first-class concern.** Every long-running task should be cancellable; cancellation should propagate to child tasks.
- **Timeouts on every external call.** No timeout = infinite hang on a stuck dependency = cascading outage.
- **Idempotency for retry-safe operations.** "Send email" is not idempotent; "create user if not exists" is. Design for it from the start.
- **Backpressure when producer can outpace consumer.** Unbounded queues hide problems until the OOM. Use bounded buffers and surface the backpressure as a slowdown or a typed error.

See §12 for language-family-specific notes.

------

## 12. Concurrency Patterns

Beyond what §5.8 covers, language-family-specific notes:

### Async / await family (JavaScript, TypeScript, Python asyncio, Rust async, C# async, Kotlin coroutines)

- **`await` is yield-point.** Anything between `await`s runs atomically with respect to other tasks on the same thread; anything across `await` boundaries can interleave.
- **CPU-bound work blocks the event loop.** Move it to a worker (Web Workers, ProcessPoolExecutor, Tokio's `spawn_blocking`, Dispatchers.Default for Kotlin).
- **Cancellation propagation.** A cancelled parent task should cancel children. Use the language's idiomatic mechanism (`AbortSignal`, `asyncio.CancelledError`, structured concurrency with `Job`, tokio's cancellation tokens). Never swallow it.
- **Don't `await` inside loops** when concurrent work is possible (`Promise.all` / `asyncio.gather` / `tokio::join!`). Sequential awaits inside a loop multiplies latency.
- **Backpressure** — bounded channels / buffered streams when the producer can outpace the consumer.

### Thread + lock family (Java, C++, Go, traditional Python with threading, Ruby with threads)

- **Hold locks for the shortest possible duration.** Compute under the lock, copy out, release, then process.
- **Lock ordering.** If two locks are ever acquired together, acquire in a consistent order to prevent deadlock.
- **Read-write locks** when reads dominate writes, otherwise plain mutex.
- **Atomics** for single-word operations (counters, flags) — cheaper than locks, but limited to simple ops.
- **Thread-local storage** for per-thread mutable state. Don't share it across threads.
- **Goroutines (Go)** are cheap but not free — leaks accumulate. Always provide a way for the goroutine to exit (context cancellation, channel close).

### Single-threaded event loop (Node.js — also relevant context for browser JS)

- **Never block the event loop.** No synchronous file I/O, no synchronous crypto, no synchronous JSON.parse on huge payloads.
- **CPU-bound to Worker Threads.**
- **Timer callbacks aren't real-time.** `setTimeout(fn, 0)` runs after the current microtask queue drains.

### Universal across models

- **Timeouts on every external call.** Database, HTTP, gRPC, file system network mount, message broker. No exceptions.
- **Idempotency keys** for write operations that might be retried. Store request_id → result; replay returns the original result without re-executing.
- **Test the cancellation contract.** Tests that pass without exercising cancellation say nothing about behavior under load.

------

## 6. Release Engineering

### 6.1 Versioning

[Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`:

- **MAJOR** — breaking change. API removed, signature changed, behavior changed in a way callers must adapt to.
- **MINOR** — new feature, backwards-compatible. Adding an API; adding a new optional config; new output that wasn't there before.
- **PATCH** — bug fix. No new feature. No API change. Pure correctness or performance.

Pre-1.0 software follows SemVer too: bumping the MINOR (`0.7.0 → 0.8.0`) signals breaking changes; MAJOR `1.0.0` happens when you commit to API stability.

Pick **one** source of truth for the version (a `VERSION` file, `package.json`, `pyproject.toml`, `Cargo.toml`, `version.go`, `version.properties`) and stick to it. The release workflow reads it; humans bump it; the CI gate verifies tag-vs-source parity (a mismatch fails the build).

### 6.2 Tag-driven release

- Push a `vX.Y.Z` tag on the protected branch. The CI release workflow runs from the tag:
  1. Verify tag matches version-in-source. Mismatch fails.
  2. Build artifacts (binary, package, container image, etc.).
  3. Run smoke tests on the production-mode build.
  4. Publish to the artifact registry (npm, PyPI, crates.io, Maven Central, Docker Hub, GitHub Container Registry, etc.) **or** attach to a GitHub Release.
  5. Extract the corresponding CHANGELOG section as the release notes body.
- **Production rollout stays manual** (or behind a separate workflow with explicit human approval). Tag → artifact ≠ tag → production.
- **Idempotent re-runs.** A tagged release workflow should be safe to re-run on failure. Use deterministic artifact names; refuse to overwrite if the artifact already exists in the registry.

### 6.3 CHANGELOG discipline

- Format: [Keep a Changelog](https://keepachangelog.com/) — `## [X.Y.Z] — YYYY-MM-DD` sections in reverse chronological order.
- Each release section is what the release workflow extracts into the published release body (typically via `awk` / `sed` between `## [X.Y.Z]` and the next `## ` heading).
- Bullet voice: past tense for what shipped, present tense for what works today. **Per §2: never mention AI tools, LLMs, or assistants in CHANGELOG entries.** Changes describe what shipped, not what wrote it.
- Sections (only include those that apply): **Added**, **Changed**, **Deprecated**, **Removed**, **Fixed**, **Security**.
- "Deferred" subsections matter — explicit deferral is better than silent partial-ship.

### 6.4 Release notes convention

Release bodies are written for humans (users read these; engineers paste them into chat; PMs screenshot them). Format:

```
# <Version + one-line theme>
<1–2 sentence lead paragraph>
## Highlights
- <3–7 user-facing bullets, plain English>
## <Optional: Behind the scenes>  (only if material)
## Breaking changes (if any — call out prominently)
- <migration path for each>
## What's next
**Full changelog:** https://github.com/<org>/<repo>/compare/vP...vN
```

Plain English, no commit SHAs in the body, no naked ticket numbers, no emojis (unless the project's tone established them). **Per §2: no mention of AI tools, LLMs, or specific assistants anywhere in release notes** — no footers, no "AI-assisted" tags, no "thanks to Claude" lines, no mention in highlights or behind-the-scenes sections. Release notes are about what shipped to users; the toolchain that produced it is not relevant content.

------

## 7. Quality Gate (local + CI)

### 7.1 Local pre-PR gate

Standard ordering — fail fast on cheap things:

```bash
# 1. Formatter (cheap, deterministic)
<formatter-check>            # e.g. prettier --check, black --check, gofmt -l, cargo fmt -- --check

# 2. Linter (cheap, deterministic)
<linter>                     # e.g. eslint, ruff, golangci-lint, clippy

# 3. Type checker (cheap-to-medium, deterministic)
<type-checker>               # e.g. tsc --noEmit, mypy --strict, pyright, sorbet

# 4. Unit tests (medium, deterministic)
<unit-test-runner>           # e.g. vitest, jest, pytest, go test, cargo test

# 5. Build (medium-to-expensive, deterministic)
<build-production-mode>      # e.g. npm run build, cargo build --release, go build, mvn package

# 6. Integration tests (expensive, may need Docker / external deps)
<integration-test-runner>    # if applicable
```

All must pass before pushing. Configure your `.git/hooks/pre-push` (or `pre-commit`) to run at least 1–3 — they're cheap enough to catch errors before a network round-trip to CI.

### 7.2 CI structure

Split CI into **parallel jobs** with an **aggregator job** that becomes the required-status-check name. This saves N×(N−1)/2 minutes per PR where N is the number of independent stages.

Typical split for a medium-sized repo:

- **`static-checks`** — formatter, linter, type checker, any custom code guards (banned-words grep, dependency-policy grep, etc.).
- **`unit-tests`** — unit-test runner with coverage.
- **`build`** — production-mode build. Catches the "works in dev, breaks in prod-build" class of bugs.
- **`integration-tests`** — runs against ephemeral Docker / testcontainer / Docker Compose dependencies. Slower; runs on every PR but in parallel with the above.
- **`build-gate`** (aggregator) — `needs: [static-checks, unit-tests, build, integration-tests]`; the branch ruleset gates only on this single check name. Add jobs later without touching branch protection.

**Critical: the production-mode build gate.** Without it, code that imports a dev-only module compiles fine on every PR and only fails at release-tag time. The author has typically moved on; the silent failure can block QA for an entire phase. Wire the production-mode build into CI.

### 7.3 Branch protection

- PR required for the protected branch (no direct push).
- The aggregator status check must pass.
- Any tier-1 audit (security grep, secret-scan, banned-words) blocks merges on hit.
- Require linear history (squash or rebase merges only) unless your team has chosen merge-commits.
- Require at least one approving review (humans or human-approved-bots; never auto-approval).

### 7.4 Domain-specific guards (optional)

When the codebase has high-stakes vocabulary or risk surfaces, a CI grep guard catches what code review misses:

- **Health apps:** medical claim triggers ("diagnose", "treat", "cure"), named conditions, "FDA approved".
- **Financial apps:** investment-advice triggers ("guaranteed return", "risk-free", "you should buy").
- **Children's apps:** anything in the Family Policy / COPPA violation list.
- **Security-critical apps:** banned weak primitives ("MD5", "SHA1", "DES", "ECB"), banned random sources (`Math.random()` for tokens).
- **License-sensitive apps:** GPL imports in proprietary code.
- **Privacy-critical apps:** unexpected egress patterns (calls to ad networks, analytics domains).

Source list lives in `docs/COPY_REVIEW.md` or `docs/SECURITY_BANNED_PATTERNS.md`. The CI grep guard enforces it. **A grep guard catches what code review misses.**

### 7.5 Production-build smoke

Source-text tests + the CI production-build gate catch most cases, but only a real production-mode run catches issues that the source-text rules missed (tree-shaking, dead-code elimination, ahead-of-time compilation, reflection-stripping).

Per release, run a smoke checklist on the production artifact:

1. Build in production mode.
2. Run the smoke command (`./bin/start`, `docker run`, `npm start`, etc.) against the production artifact.
3. Verify no startup errors — wrong: `NoSuchClassError`, `ModuleNotFoundError`, `ENOENT`, `panic: ...`.
4. Verify the canonical user flow works end-to-end (read, write, list).
5. Verify any background jobs / scheduled tasks start.
6. If anything fails: **do not** silently re-add wholesale debug-mode flags or "compatibility shims." File a bug per failing item, narrow the fix to the minimum reproducer, re-run the full smoke on the next RC.

------

## 8. Test Coverage Policy

### 8.1 Test surfaces (the four-surface model)

Every test you write fits into exactly one of these. Pick by what you want to verify, not by where it's easiest to put.

| Surface                     | Verifies                                                     | Speed              | Where it runs                                          |
| --------------------------- | ------------------------------------------------------------ | ------------------ | ------------------------------------------------------ |
| **Unit**                    | Pure functions, state machines, business-logic primitives. No I/O, no real dependencies. | <1s per test       | Every PR                                               |
| **Integration**             | Component-to-component boundaries with real dependencies (real DB in Docker, real cache, real message broker). The "does the click actually persist" layer. | Seconds-to-minutes | Every PR (with testcontainers / ephemeral env)         |
| **End-to-end**              | Full stack from user surface to data store, in a production-like environment. | Minutes            | Every PR for critical paths; nightly for the long tail |
| **Property / fuzz / chaos** | The unknown-unknown layer. Property-based testing (Hypothesis, fast-check, proptest, quickcheck), fuzz testing, chaos engineering. | Open-ended         | Continuous, in dedicated jobs                          |

### 8.2 Coverage thresholds (set deliberately)

There is no universal correct number. Set one and enforce it. A useful baseline:

- **Unit-test line coverage:** ≥70% on production source, excluding generated code, framework boilerplate, and main / entry points. Strict enough to surface untested logic; loose enough not to gate trivial PRs.
- **Branch coverage:** ≥60%. Branch coverage catches the "I tested the happy path, not the error path" gap that line coverage misses.
- **Integration-test coverage of public API surface:** every public endpoint / RPC method / CLI command has at least one happy-path and one error-path integration test.
- **End-to-end coverage:** the top 5 user journeys, by frequency or business value.

Wire coverage measurement into CI and fail the build on regression — but raise thresholds deliberately when new modules ship, don't lower them silently when a refactor temporarily drops coverage. A "coverage went down by 2%" PR is a code smell.

### 8.3 Fixture data discipline

- **Deterministic.** Pin dates (`Date(2026, 5, 15)`, not `Date.now()`). Pin random seeds. Avoid wall-clock dependencies in tests.
- **Clock injection.** Production code reads the current time through an injectable interface (`Clock`, `time.Now()`, `Date.now()` mocked). Tests inject a fixed clock or advance it manually.
- **Hand-rolled fakes preferred over mocking frameworks** for repository-shaped interfaces. Back state with an in-memory map or list so tests can drive observed outputs directly. Mocking frameworks are fine for one-off verification of "was this method called with these args"; they're an anti-pattern for repository-shaped surfaces.
- **Test-database isolation.** Each integration test gets a clean, ephemeral database — testcontainers, an in-memory mode (SQLite, fake-redis), or a transaction that rolls back at the end. Tests must not depend on each other's data.
- **No shared mutable state between tests.** Tests must be safe to run in parallel and in any order.

### 8.4 First-render / first-call race

Some testing frameworks (UI test libraries, async runtimes) have a default-wait that doesn't actually cover all the work the system does on initial activation. The "asserted before the async load finished" race is a top source of flaky tests.

The fix is a small project-specific helper that waits for the actual ready signal — not the framework's default. Examples:

- UI tests: `assertEventually(text)` that polls until visible, instead of `assertVisible(text)` that races recomposition.
- API tests: `awaitHealth()` that polls `/healthz` until ready, instead of `setTimeout(..., 5000)`.
- Job tests: `awaitDrain(queue)` that polls until queue.length === 0.

Define the helper once, use it everywhere first-render assertions happen. Banish raw `sleep()` from tests.

------

## 13. Compliance & Distribution Watchlist

The biggest source of "release blocked at submission / deploy" surprises is platform / regulatory compliance. Track these per release, scoped to your distribution channel.

### 13.1 Web applications

- **Content Security Policy (CSP).** Tighten over time; new inline scripts or new external origins break the policy. Test in staging with CSP report-only first.
- **Browser support matrix.** Document which browsers you support. Verify with real testing (BrowserStack / Sauce Labs / Playwright on multiple targets), not "should work everywhere."
- **Accessibility.** WCAG 2.1 AA at minimum. Run automated audits (axe-core, Lighthouse); manual keyboard-only and screen-reader smoke per release.
- **Cookies.** Set `Secure`, `HttpOnly`, `SameSite=Lax` (or `Strict` for auth). Document any third-party cookies; GDPR/ePrivacy consent flows required in EU.
- **HSTS** with preload submission. Once enrolled, irreversible — verify your TLS infrastructure before submission.

### 13.2 Mobile applications

- **App store policy compliance** (Apple App Store Review Guidelines, Google Play Developer Policies). Track changes per OS release; update one minor cycle ahead.
- **OS targetSDK / deployment target treadmill.** Both Apple and Google enforce minimum targets for new submissions; missing the deadline blocks updates.
- **Permission discipline.** Request runtime permissions only when first needed, with rationale. Justify in store metadata.
- **Data Safety / Privacy Nutrition Labels.** Keep the store metadata in sync with reality. Any new SDK with data collection triggers re-review.
- **Auto-backup disabled by default** unless you have a deliberate backup strategy.

### 13.3 Backend / API services

- **Data residency.** Where is each piece of user data physically stored? Document for GDPR Article 30. Some users / customers require regional pinning.
- **Retention policy.** How long is each data class retained? Document; enforce with scheduled deletion jobs.
- **Rate limiting** on public endpoints. Per-IP and per-account. Document the limits in API docs.
- **Auth token lifetime.** Short-lived access tokens + refresh tokens. Document rotation. Refuse to issue long-lived tokens unless explicitly requested with audit trail.
- **PII redaction in logs.** Audit log emissions for new fields containing email, phone, SSN, etc. before merging.
- **CORS policy.** Allowlist explicit origins; never `*` for credentialed requests.
- **HTTPS-only.** Reject plaintext at the load balancer.

### 13.4 Libraries / SDKs / package distribution

- **SemVer discipline.** Major bump for any breaking change, including error message changes that downstream code might pattern-match on.
- **Deprecation policy.** Mark deprecated for one minor release before removing. Provide migration guide.
- **Backwards-compatibility commitment.** Document which interfaces are public-stable, which are public-unstable, which are internal.
- **Package metadata.** License field present and correct. Author / maintainer contact valid. Repository URL points to canonical source.
- **Supply chain.** Signed releases (Sigstore, GPG, signed git tags). Reproducible builds where feasible. SBOM published with release.
- **License compatibility.** Ensure dependency licenses are compatible with your distribution license; track with tooling (FOSSA, license-checker).

### 13.5 CLI tools / system utilities

- **Install methods documented and tested.** Homebrew, apt, yum, scoop, install scripts — every documented method needs CI verification.
- **Cross-platform behavior.** If the docs say "works on macOS, Linux, Windows," verify on all three per release.
- **Exit codes.** Document them. `0 = success, 1 = generic error, 2 = usage error, ...`. Don't break the convention.
- **Stdout vs stderr.** Stdout is for output that pipes to the next command; stderr is for human-readable status / errors. Don't mix.
- **`--help` / `--version` / `--json` / `--no-color`.** Standard flags; users expect them.

------

