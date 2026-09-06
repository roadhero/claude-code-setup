#!/usr/bin/env bash
# PreToolUse(Bash) — block AI attribution, secrets, force-push, and hook-skipping (--no-verify)
# before they happen. Exit 2 + a stderr reason is the documented blocking contract; stdout is unused.
INPUT=$(cat)

# Fast path: this guard only concerns `git commit` / `git push`. If the payload mentions
# neither, allow immediately — so a missing jq (below) never blocks unrelated Bash (ls/cat/grep).
# Match loosely (no quote-class): a quoted arg before the subcommand (`git -C "x" commit`)
# must NOT slip past into a silent allow.
printf '%s' "$INPUT" | grep -qiE 'git.*(commit|push)' || exit 0

# The command plausibly commits/pushes — jq is needed to inspect it. Fail loud and closed.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: guard-commit.sh needs 'jq' to inspect a git commit/push but it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Classify per command segment, not per Bash call: `git commit -m ok && git push -f` is a commit
# AND a force-push, and each segment is judged on its own. Quoted text is stripped first so a
# commit MESSAGE that merely mentions `push --force` or `--no-verify` (or contains `;`) can't
# trip a flag check or split a segment. The subcommand may follow global options
# (`git -C <path>`, `git -c k=v`), so `commit`/`push` is matched as a whitespace-delimited word.
STRIPPED=$(printf '%s' "$CMD" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
IS_COMMIT=""
while IFS= read -r SEG; do
  [ -z "$SEG" ] && continue
  SEG_COMMIT=""; SEG_PUSH=""
  printf '%s' "$SEG" | grep -qiE 'git.*[[:space:]]commit([^[:alnum:]]|$)' && SEG_COMMIT=1
  printf '%s' "$SEG" | grep -qiE 'git.*[[:space:]]push([^[:alnum:]]|$)' && SEG_PUSH=1
  [ -n "$SEG_COMMIT" ] && IS_COMMIT=1
  [ -z "$SEG_COMMIT$SEG_PUSH" ] && continue

  # force-push: --force / -f / --force-with-lease, or a `+refspec` (the refspec form of --force)
  if [ -n "$SEG_PUSH" ] && printf '%s' "$SEG" | grep -qiE '[[:space:]]push.*[[:space:]](--force-with-lease|--force|-f)([^[:alnum:]]|$)|[[:space:]]push.*[[:space:]]\+[^[:space:]]'; then
    echo "Blocked: force-push. Protected-branch discipline (CLAUDE.md §9)." >&2; exit 2
  fi

  # --no-verify skips the pre-commit / pre-push hooks the repo installed on purpose (CLAUDE.md §14),
  # as does `git commit -n` (the short form) and re-pointing core.hooksPath. Fix the hook failure instead.
  if printf '%s' "$SEG" | grep -qiE '[[:space:]]--no-verify([^[:alnum:]-]|$)|core\.hooksPath'; then
    echo "Blocked: --no-verify / core.hooksPath bypasses the repo's git hooks (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
  if [ -n "$SEG_COMMIT" ] && printf '%s' "$SEG" | grep -qiE '[[:space:]]commit.*[[:space:]]-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)'; then
    echo "Blocked: git commit -n is --no-verify (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
done <<<"$(printf '%s' "$STRIPPED" | tr ';&|' '\n')"

# only inspect commit operations further
[ -z "$IS_COMMIT" ] && exit 0

# committer must be a human — match whole tokens / known bot identities, not substrings
NAME=$(git config user.name 2>/dev/null || echo "")
if printf '%s' "$NAME" | grep -qiE '(^|[^[:alnum:]])(claude|chatgpt|copilot|cursor|cursoragent|github-actions|assistant|bot|ai[-_ ]?(agent|assistant|bot))([^[:alnum:]]|$)'; then
  echo "Blocked: git user.name '$NAME' is not a human (CLAUDE.md §2)." >&2; exit 2
fi

# no AI attribution in the commit message — scan the command only, not the staged diff.
# (This is a repo *about* Claude Code; legit messages will say "Claude Code". Only
#  attribution-SHAPED phrases are blocked, not bare mentions of a tool.)
if printf '%s' "$CMD" | grep -qiE 'co-authored-by:.*(claude|gpt|copilot|cursor)|generated with (claude|chatgpt|copilot|ai)|🤖|AI[- ](assisted|generated)'; then
  echo "Blocked: AI attribution detected in commit message (CLAUDE.md §2). Remove it." >&2; exit 2
fi

# no obvious secrets. Scan the staged diff; for `git commit -a/--all` (which auto-stages tracked
# edits AFTER this hook runs) also scan the working-tree diff, else `-am` bypasses the check.
SECRETS='(api[_-]?key|secret[_-]?key|access[_-]?key|private[_-]?key|password|token|bearer )[^=]*[=:] *["'"'"']?[A-Za-z0-9/_+-]{16,}|BEGIN [A-Z0-9 ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[0-9A-Za-z-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
# Exempt example/sample files — they're meant to hold placeholder values and are
# explicitly whitelisted for commit (e.g. `!.env.example` in the scaffolder .gitignore).
EXCL=(':(exclude)*.example' ':(exclude)*.sample' ':(exclude)*.dist' ':(exclude)*.tmpl')
DIFF=$(git diff --cached 2>/dev/null -- "${EXCL[@]}")
if printf '%s' "$STRIPPED" | grep -qiE '[[:space:]](--all|-[A-Za-z]*a[A-Za-z]*)([[:space:]]|$)'; then
  DIFF="$DIFF"$'\n'"$(git diff 2>/dev/null -- "${EXCL[@]}")"
fi
if printf '%s' "$DIFF" | grep -qiE "$SECRETS"; then
  echo "Blocked: a secret appears to be staged (CLAUDE.md §11). Unstage it." >&2; exit 2
fi
exit 0
