# Reconciliation cadence

> Full detail for CLAUDE.md §10. The spine carries the one-line rule ("every 3–5 merged PRs, run a reconciliation pass; delegate to `docs-reconciler`"); the five-step pass lives here.

Every 3–5 merged PRs, run a reconciliation pass before queueing the next feature. Delegate to `docs-reconciler` (it does exactly this, and applies a cheap-first tier discipline — single greps before full re-reads).

1. **Spec ↔ code:** scan spec / PRD / RFC sections touched by recent work; flag drift (a feature shipped that the spec still describes as "planned"; a feature the spec describes that's actually deferred under a follow-up issue).
2. **Roadmap ↔ shipped versions:** annotate phase rows with "(shipped vX.Y.Z)" or "(partial: shipped X, deferred Y)" — explicit partial-ship is better than silent drift.
3. **Open issues ↔ reality:** close issues whose deliverable shipped; comment on owner-bound issues with current state so the next session knows what's pending.
4. **CHANGELOG ↔ tags:** verify the section heads match the git tag history; the release workflow extracts these verbatim, so drift here ships an empty release body.
5. **README ↔ code:** does the elevator pitch still match? Are the badges current (build status, package version, license)? Are quickstart commands still correct?

Default fallback work when no ticket is queued: **reconciliation pass + ticket hygiene**, not speculative refactors. Don't invent work to fill time.
