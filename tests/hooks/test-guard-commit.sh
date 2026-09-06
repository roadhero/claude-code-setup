#!/usr/bin/env bash
# Behavioral tests for hooks/guard-commit.sh: a PreToolUse(Bash) payload on stdin, an exit code out.
# 0 = allow, 2 = block. One case per rule the hook enforces and per regression it has had.
# Runs on macOS system bash 3.2 with jq + git only.  Usage: bash tests/hooks/test-guard-commit.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../../hooks/guard-commit.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate git from the machine's real identity/config so the committer checks are deterministic.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test Human" GIT_COMMITTER_NAME="Test Human"
export GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_EMAIL=test@example.com

# run <name> <expected-exit> <bash command the agent is about to run>
run() {
  name=$1; want=$2; cmd=$3
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$HOOK" >/dev/null 2>"$TMP/err"
  got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name (want exit $want, got $got): $cmd"
    sed 's/^/      stderr: /' "$TMP/err"
  fi
}

# A throwaway repo with a human committer, one tracked file, and a clean tree.
mkrepo() {
  d=$(mktemp -d "$TMP/repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.name "$1"
  git -C "$d" config user.email test@example.com
  echo "hello" >"$d/tracked.txt"
  git -C "$d" add tracked.txt
  git -C "$d" commit -qm "init"
  echo "$d"
}

# Fake credentials are assembled at runtime so this file never contains a secret-shaped literal
# (the hook would otherwise refuse to commit its own test suite).
AWS_KEY=$(printf 'AKIA%s' "$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)")

REPO=$(mkrepo "Test Human")
cd "$REPO" || exit 1

# --- fast path: commands that are not git commit/push are never inspected ---------------------
run "unrelated command"                      0 'ls -la'
run "git without commit/push"                0 'git status && git log --oneline -3'
run "empty payload"                          0 ''

# --- force-push (7663993) -----------------------------------------------------------------------
run "push --force"                           2 'git push --force origin feat/x'
run "push -f"                                2 'git push -f origin feat/x'
run "push --force-with-lease"                2 'git push --force-with-lease origin feat/x'
run "push -f after git -C"                   2 'git -C /tmp/x push -f'
run "push +refspec (force by refspec)"       2 'git push origin +main'
run "push +HEAD:branch refspec"              2 'git push origin +HEAD:feat/x'
run "push with env assignment prefix"        2 'FOO=1 git push -f origin x'
run "plain push"                             0 'git push origin feat/x'
run "push of a branch named -f-ish"          0 'git push origin feature-flags'

# --- commit message that merely mentions a forbidden flag (07dd319) ----------------------------
run "message mentions push --force"          0 'git commit -m "docs: explain why push --force is blocked"'
run "message mentions --no-verify"           0 'git commit -m "docs: never use --no-verify"'
run "message with a separator inside"        0 'git commit -m "fix: a; b && git push -f"'

# --- chained commands: every segment is classified on its own ---------------------------------
run "commit then force-push"                 2 'git commit -m "ok" && git push -f origin feat/x'
run "commit; force-push"                     2 'git commit -m "ok"; git push --force origin feat/x'
run "commit || force-push"                   2 'git commit -m "ok" || git push -f'
run "commit then plain push"                 0 'git commit -m "ok" && git push -u origin feat/x'

# --- --no-verify skips the repo's own git hooks (CLAUDE.md §14) --------------------------------
run "commit --no-verify"                     2 'git commit --no-verify -m "x"'
run "commit -n short flag"                   2 'git commit -n -m "x"'
run "commit -anm combined short flags"       2 'git commit -anm "x"'
run "push --no-verify"                       2 'git push --no-verify origin feat/x'
run "commit then push --no-verify"           2 'git commit -m "x" && git push --no-verify'
run "hooksPath override on commit"           2 'git -c core.hooksPath=/dev/null commit -m "x"'
run "git log --no-verify is not a commit"    0 'git log --no-verify'
run "push -n is dry-run, not no-verify"      0 'git push -n origin feat/x'

# --- AI attribution in the commit message (CLAUDE.md §2) ---------------------------------------
run "co-authored-by trailer"                 2 'git commit -m "feat: x" -m "Co-authored-by: Claude <noreply@anthropic.com>"'
run "generated-with line"                    2 'git commit -m "feat: x" -m "Generated with Claude Code"'
run "robot emoji"                            2 'git commit -m "🤖 feat: x"'
run "bare tool mention is fine"              0 'git commit -m "docs: describe the Claude Code hook"'

# --- committer must be a human (CLAUDE.md §2) --------------------------------------------------
BOT=$(mkrepo "Claude")
( cd "$BOT" && run "non-human committer"     2 'git commit -m "x"' )
BOT2=$(mkrepo "github-actions[bot]")
( cd "$BOT2" && run "github-actions committer" 2 'git commit -m "x"' )

# --- secrets in the staged diff (CLAUDE.md §11), incl. the -a auto-stage path (229e95d) --------
printf 'aws_key=%s\n' "$AWS_KEY" >>tracked.txt
run "dirty tracked secret, plain commit"     0 'git commit -m "x"'
run "dirty tracked secret, commit -am"       2 'git commit -am "x"'
run "dirty tracked secret, commit --all"     2 'git commit --all -m "x"'
git checkout -q -- tracked.txt

printf 'aws_key=%s\n' "$AWS_KEY" >config.txt
git add config.txt
run "staged secret"                          2 'git commit -m "x"'
git rm -q --cached config.txt && rm config.txt

printf 'aws_key=%s\n' "$AWS_KEY" >.env.example
git add .env.example
run "staged secret in .env.example (72d9ea4)" 0 'git commit -m "x"'
git rm -q --cached .env.example && rm .env.example

printf -- '-----BEGIN RSA PRIVATE KEY-----\n' >key.txt
git add key.txt
run "staged private key header"              2 'git commit -m "x"'
git rm -q --cached key.txt && rm key.txt

# --- missing jq: fail closed for git commit/push, stay out of the way otherwise ----------------
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for t in bash sh grep git sed tr printf cat; do
  p=$(command -v "$t") && ln -s "$p" "$NOJQ/$t"
done
run_nojq() {
  name=$1; want=$2; cmd=$3
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' >"$TMP/payload"
  PATH="$NOJQ" bash "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
  got=$?
  if [ "$got" -eq "$want" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: $name (want exit $want, got $got): $cmd"; sed 's/^/      stderr: /' "$TMP/err"
  fi
}
run_nojq "no jq: commit fails closed"        2 'git commit -m "x"'
run_nojq "no jq: unrelated command allowed"  0 'ls'

echo "guard-commit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
