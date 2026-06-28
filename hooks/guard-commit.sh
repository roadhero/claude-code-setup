#!/usr/bin/env bash
# PreToolUse(Bash) — block AI attribution, secrets, and force-push before they happen.
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# block force-push / hard reset to protected refs
if printf '%s' "$CMD" | grep -qiE 'git +push +(-f|--force)([^-]|$)|git +push +.*--force-with-lease.*(main|master)'; then
  echo "Blocked: force-push. Protected-branch discipline (CLAUDE.md §9)." >&2; exit 2
fi

# only inspect commit operations further
printf '%s' "$CMD" | grep -qiE 'git +commit' || exit 0

# committer must be a human
NAME=$(git config user.name 2>/dev/null || echo "")
if printf '%s' "$NAME" | grep -qiE 'claude|ai|assistant|bot'; then
  echo "Blocked: git user.name '$NAME' is not a human (CLAUDE.md §2)." >&2; exit 2
fi

# no AI attribution in the message or staged diff
BLOB="$CMD"$'\n'"$(git diff --cached 2>/dev/null)"
if printf '%s' "$BLOB" | grep -qiE 'co-authored-by:.*(claude|ai)|generated with|claude code|chatgpt|copilot|AI[- ](assisted|generated)'; then
  echo "Blocked: AI attribution detected in commit (CLAUDE.md §2). Remove it." >&2; exit 2
fi

# no obvious secrets staged
if git diff --cached 2>/dev/null | grep -qiE '(api[_-]?key|secret[_-]?key|password|bearer )[^=]*[=:] *["'"'"']?[A-Za-z0-9/_+-]{16,}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY'; then
  echo "Blocked: a secret appears to be staged (CLAUDE.md §11). Unstage it." >&2; exit 2
fi
exit 0
