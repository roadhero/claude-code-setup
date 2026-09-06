# PR workflow — stacked PRs, and what happens after the PR is open

> Full detail for CLAUDE.md §9. The spine carries the one-line rule; the rebase discipline and the PR-open-to-merge loop live here.

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

## After the PR is open

A PR is not done when it is opened. Between `gh pr create` and merge:

1. **Wait for CI.** `gh pr checks <n> --watch`. On red, classify the failure per `workflow.md` §4.7 before touching anything. Auto-fix only formatter / lint / type errors and tests you wrote in this PR; ask before changing tests you did not write or CI config; never `--no-verify` (§14, and the commit guard blocks it).
2. **Reply to every top-level review comment, human or bot.** One of: `Fixed in <sha>` where `<sha>` is `git rev-parse --short origin/<branch>` _after_ the push (never a local-only commit); `Deferred: #<issue>` with the issue actually opened; or a technical disagreement with the reason. Never silent. Reply before resolving, and follow the repo's convention on who resolves. Per §2, no AI mention in replies.
3. **Re-check after every push.** Bot reviewers re-review each commit, so repeat steps 1 and 2 until both are clean. To list top-level review comments that still have no reply:
   ```bash
   gh api "repos/{owner}/{repo}/pulls/<n>/comments" --paginate | jq -rs 'add
     | ([.[] | select(.in_reply_to_id != null) | .in_reply_to_id]) as $replied
     | .[] | select(.in_reply_to_id == null and ((.id as $i | $replied | index($i)) == null))
     | "\(.id) \(.user.login) \(.path):\(.line // .original_line)"'
   ```
4. **Done means:** CI green after the last push, that list is empty, and nothing is left on your side. Report and stop. Merging is the user's call (the `qa` agent does not merge); once it merges, the stacked-PR steps above apply to the next branch.
