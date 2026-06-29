#!/usr/bin/env bash
# PreToolUse(Bash) — block AI attribution, secrets, and force-push before they happen.
INPUT=$(cat)

# jq is required to parse the tool payload. Fail loud and closed — never silently no-op.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: guard-commit.sh needs 'jq' but it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# block force-push: --force / -f / --force-with-lease anywhere in a `git push` command
if printf '%s' "$CMD" | grep -qiE 'git +push[^;&|]*(--force-with-lease|--force|-f)([^[:alnum:]]|$)'; then
  echo "Blocked: force-push. Protected-branch discipline (CLAUDE.md §9)." >&2; exit 2
fi

# only inspect commit operations further
printf '%s' "$CMD" | grep -qiE 'git +commit' || exit 0

# committer must be a human — match whole tokens / known bot identities, not substrings
NAME=$(git config user.name 2>/dev/null || echo "")
if printf '%s' "$NAME" | grep -qiE '(^|[^[:alnum:]])(claude|chatgpt|copilot|cursor|cursoragent|github-actions|assistant|bot|ai)([^[:alnum:]]|$)'; then
  echo "Blocked: git user.name '$NAME' is not a human (CLAUDE.md §2)." >&2; exit 2
fi

# no AI attribution in the commit message — scan the command only, not the staged diff.
# (This is a repo *about* Claude Code; legit messages will say "Claude Code". Only
#  attribution-SHAPED phrases are blocked, not bare mentions of a tool.)
if printf '%s' "$CMD" | grep -qiE 'co-authored-by:.*(claude|gpt|copilot|cursor)|generated with (claude|chatgpt|copilot|ai)|🤖|AI[- ](assisted|generated)'; then
  echo "Blocked: AI attribution detected in commit message (CLAUDE.md §2). Remove it." >&2; exit 2
fi

# no obvious secrets staged
if git diff --cached 2>/dev/null | grep -qiE '(api[_-]?key|secret[_-]?key|password|bearer )[^=]*[=:] *["'"'"']?[A-Za-z0-9/_+-]{16,}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY'; then
  echo "Blocked: a secret appears to be staged (CLAUDE.md §11). Unstage it." >&2; exit 2
fi
exit 0
