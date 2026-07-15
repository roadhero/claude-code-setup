# Stacked PR workflow

> Full detail for CLAUDE.md §9. The spine carries the one-line rule; the rebase discipline lives here.

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
