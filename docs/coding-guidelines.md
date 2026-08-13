# Coding guidelines — full detail & worked examples

> Full detail for CLAUDE.md §3. The spine carries the four headline principles as tight bullets; the worked examples live here, plus §3.5 (design for testability), which stays in this on-demand tier only.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 3.1 Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 3.2 Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3.3 Surgical Changes

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

## 3.4 Goal-Driven Execution

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

## 3.5 Design for Testability

Structure code so the logic worth testing can be exercised without ceremony. This is the design constraint that makes the §8 coverage rules achievable in the first place, so a reviewer can check it up front rather than discovering it when the tests get hard to write.

- **Separate the pure core from the environment-unsuitable boundary.** Modules that open GUIs, touch external devices or the network, read the wall clock, spawn processes, or hang under automation belong at the edges. Keep the business logic (the part worth testing) pure and dependency-free. Maximize that testable core; shrink the unsuitable boundary. The stack rules already apply this shape: a pure compute numeric kernel, a stateless snapshot-testable Compose `XContent`, and a web unit tier that does no I/O.
- **A change that is hard to test is usually a design smell, not a testing problem.** If a behavior needs a live browser, a real clock, or a real socket to exercise, extract the logic out of that boundary before writing the test, rather than reaching for heavier test machinery.
- **Coverage proves tests exist; it does not prove they would catch a regression.** For high-stakes logic (money, auth, data integrity, a numeric kernel), an optional mutation-testing pass (Stryker for JS/TS, mutmut for Python, PIT for the JVM, cargo-mutants for Rust) measures test _strength_: a surviving mutant is an assertion you are missing. On-demand for the code that matters, never a default CI gate.
