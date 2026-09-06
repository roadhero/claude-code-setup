#!/usr/bin/env bash
# Behavioral tests for hooks/guard-commit.sh: a PreToolUse(Bash) payload on stdin, an exit code out.
# 0 = allow, 2 = block. One case per rule the hook enforces and per regression it has had.
# Runs on macOS system bash 3.2 with jq + git only.  Usage: bash tests/hooks/test-guard-commit.sh
# shellcheck disable=SC2016  # several cases deliberately pass literal "$(cat <<'EOF' ...)" commit messages
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
HOOK="$HERE/../../hooks/guard-commit.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate git from the machine's real identity/config so the committer checks are deterministic.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test Human" GIT_COMMITTER_NAME="Test Human"
export GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_EMAIL=test@example.com

# record <name> <expected-exit> <got-exit> <command>
record() {
  if [ "$3" -eq "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 (want exit $2, got $3): $4"
    sed 's/^/      stderr: /' "$TMP/err"
  fi
}

# run <name> <expected-exit> <bash command the agent is about to run>
# Never call this inside a subshell: PASS/FAIL must be counted in this shell.
run() {
  printf '%s' "$3" | jq -Rs '{tool_input:{command:.}}' | bash "$HOOK" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}

# run_raw <name> <expected-exit> <raw stdin for the hook>
run_raw() {
  printf '%s' "$3" | bash "$HOOK" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}

# A throwaway repo with the given committer, one tracked file, and a clean tree.
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
PEM_HEADER=$(printf -- '-----BEGIN RSA %s KEY-----' "PRIVATE")

REPO=$(mkrepo "Test Human")
cd "$REPO" || exit 1

# --- fast path: commands that are not git commit/push are never inspected ---------------------
run "unrelated command"                      0 'ls -la'
run "git without commit/push"                0 'git status && git log --oneline -3'
run "empty command"                          0 ''
run_raw "empty stdin"                        0 ''
run_raw "non-JSON payload mentioning commit is fail-closed"  2 'git commit -m x'
run_raw "payload with renamed key is fail-closed"            2 '{"tool_input":{"cmd":"git push --force"}}'

# --- force-push (7663993) -----------------------------------------------------------------------
run "push --force"                           2 'git push --force origin feat/x'
run "push -f"                                2 'git push -f origin feat/x'
run "push --force-with-lease"                2 'git push --force-with-lease origin feat/x'
run "push --mirror"                          2 'git push --mirror origin'
run "push -f after git -C"                   2 'git -C /tmp/x push -f'
run "push -uf flag cluster"                  2 'git push -uf origin feat/x'
run "push -fu flag cluster"                  2 'git push -fu origin feat/x'
run "push +refspec (force by refspec)"       2 'git push origin +main'
run "push +HEAD:branch refspec"              2 'git push origin +HEAD:feat/x'
run "push with env assignment prefix"        2 'FOO=1 git push -f origin x'
run "push --force on a continuation line"    2 'git push \
  --force-with-lease \
  origin feat/x'
run "plain push"                             0 'git push origin feat/x'
run "push -u"                                0 'git push -u origin feat/x'
run "push --set-upstream"                    0 'git push --set-upstream origin feat/x'
run "push of a branch named -f-ish"          0 'git push origin feature-flags'
run "push -n is dry-run, not no-verify"      0 'git push -n origin feat/x'

# --- commit message that merely mentions a forbidden flag (07dd319) ----------------------------
run "message mentions push --force"          0 'git commit -m "docs: explain why push --force is blocked"'
run "message mentions --no-verify"           0 'git commit -m "docs: never use --no-verify"'
run "message mentions -n"                    0 'git commit -m "fix: handle -n flag"'
run "message with a separator inside"        0 'git commit -m "fix: a; b && git push -f"'
run "message with an escaped quote"          0 'git commit -m "fix: 5\" screen && git push -f"'
run "heredoc message mentioning push -f"     0 'git commit -m "$(cat <<'"'"'EOF'"'"'
feat: x

A chained git commit && git push -f was allowed before.
EOF
)"'
run "heredoc message mentioning --no-verify" 0 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: guard

The guard blocks git commit --no-verify and git push --force.
Also git commit -n is blocked.
EOF
)"'
run "multi-line -m message"                  0 'git commit -m "docs: x

why git push -f is blocked"'

# --- heredoc bodies are data, not commands -----------------------------------------------------
run "heredoc file write mentioning the hook" 0 'cat > notes.md <<'"'"'EOF'"'"'
The hook refuses sh -c "git commit" wrappers and blocks git push -f and --no-verify.
EOF'
run "heredoc file write, unquoted marker"    0 'cat > notes.md <<EOF
never run git push --force or git commit --no-verify
EOF'
run "commit -F - with a heredoc body"        0 'git commit -F - <<EOF
feat: x

mentions git push -f and --no-verify in the body
EOF'
run "<<- heredoc with a tab-indented end"    0 'cat <<-EOF
	git push -f is documented here
	EOF'
run "real heredoc then force-push after it"  2 'cat <<EOF
harmless body
EOF
git push -f origin main'
run "real heredoc then --no-verify after it" 2 'cat > x.md <<EOF
harmless body
EOF
git commit --no-verify -m x'
run "fake marker inside quotes hides a push" 2 'git commit -m "a <<EOF
b" && git push -f origin main
EOF'
run "fake marker inside single quotes"       2 'git commit -m '"'"'a <<EOF
b'"'"' && git push --force origin main
EOF'
run "here-string is not a heredoc"           2 'read -r a b <<<"hello world"
git push -f origin main'
run "marker on line 2 of a quoted message"   2 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix(hooks): strip heredoc bodies

A <<WORD marker counts only when it sits outside quotes on its line.
EOF
)" && git push -f origin main'
run "fake terminator after a quoted marker"  2 'git commit -m "docs: x
see <<EOF
b" && git push -f origin main
EOF'
run "EOF) terminator inside \$( ) then push" 2 'x=$(cat <<EOF
body
EOF)
git push -f origin main'
run "delimiter with dashes then push"        2 'cat > x.md <<'"'"'END-OF-FILE'"'"'
body
END-OF-FILE
git push -f origin main'
run "marker inside a comment"                2 '# see <<EOF
git push -f origin main'
run "double quote inside a heredoc message"  2 'git commit -m "$(cat <<'"'"'EOF'"'"'
say "hi"
EOF
)" && git push -f origin main'
run "backslash-quoted delimiter"             0 'cat > x.md <<\EOF
never git push -f
EOF'
run "apostrophe in a quoted arg before a heredoc" 0 'echo "don'"'"'t" && cat > x.md <<EOF
never git push -f
EOF'
run "unterminated heredoc: tail is body"     0 'cat <<EOF
git push -f origin main'
run "heredoc body then a chained plain push" 0 'cat > x.md <<EOF
body mentions git push -f
EOF
git commit -m "x" && git push origin feat/x'

# --- the walker must never think it is in data where bash is in code ---------------------------
run "arithmetic shift is not a heredoc"      2 'echo $((1<<2))
git push --force origin main'
run "arithmetic command shift"               2 '((x<<2))
git push --force origin main'
run "arithmetic shift inside double quotes"  2 'echo "$((1<<2))"
git push --force origin main'
run "legacy \$[ ] arithmetic shift"          2 'echo $[1<<2]
git push --force origin main'
run "comment right after a paren"            2 '( : )#c <<EOF
git push --force origin main'
# shellcheck disable=SC1003  # the \' is part of the command under test, not an escape in this file
run "ANSI-C quote with an escaped quote"     2 'git commit -m $'"'"'a\'"'"'b'"'"'
git push --force origin main'
run "ANSI-C message mentioning a flag"       0 'git commit -m $'"'"'docs: x\nnever git push -f'"'"''
run "invalid UTF-8 byte before a push"       2 "$(printf 'cat \377\377 x\ngit push --force origin main')"
run "substitution in an unquoted heredoc"    2 'cat <<EOF
$(git push -f origin main)
EOF'
run "backticks in an unquoted heredoc"       2 'cat > notes.md <<EOF
`git push --force origin main`
EOF'
run "substitution in an unquoted -m heredoc" 2 'git commit -m "$(cat <<EOF
feat: x $(git push -f origin main)
EOF
)"'
run "substitution in a quoted heredoc is text" 0 'cat > notes.md <<'"'"'EOF'"'"'
$(git push -f origin main) is not run here
EOF'
run "body line ending in backslash"          2 'cat <<'"'"'EOF'"'"'
foo\
EOF
git push -f origin main'
run "paren nested inside arithmetic"         2 'echo $(( (1<<2) ))
git push -f origin main'
run "paren nested inside (( )) command"      2 '(( x = (1<<2) ))
git push -f origin main'
run "two heredocs on one line, push after"   2 'cat <<A <<B
git push -f in body A
A
git push -f in body B
B
git push -f origin main'
run "two heredocs on one line, nothing after" 0 'cat <<A <<B
git push -f in body A
A
git push -f in body B
B'
run "quoted delimiter with a space"          2 'cat <<"E OF"
body
E OF
git push -f origin main'
run "# right after \$( ) is not a comment"   2 'echo $(date)#x; git push --force origin main'
run "# right after a backtick is not a comment" 2 'echo `date`#x; git push --force origin main'
run "# after \$( ) in a chained commit"      2 'git commit -m x && echo $(date)#c && git push --force origin main'
run "# after a subshell is a comment"        0 '( : )#c git push --force origin main'
run "delimiter split by a continuation"      2 'cat <<E\
OF
body
EOF
git push --force origin main'
run "<< inside \${ } is not a heredoc"       2 'echo ${x:-<<EOF}
git push --force origin main'
run "<< inside an array subscript"           2 'a[1<<2]=1
git push --force origin main'
run "test brackets then a force-push"        2 '[ -f x ] && git push -f origin main'
run "word split across a continuation"       2 'git pu\
sh --force origin main'
run "flag split across a continuation"       2 'git push --for\
ce origin main'
run "case pattern inside a quoted \$( )"     2 'x="$(case a in a) git push --force origin main;; esac)"'
run "case pattern then a chained push"       2 'git commit -m "$(case a in a) echo x;; esac)" && git push -f origin main'
run "case statement in plain code"           2 'case x in x) echo hi;; esac
git push -f origin main'
run "case statement then plain push"         0 'case x in x) echo hi;; esac
git push origin feat/x'
BIG=$(head -c 300000 /dev/zero | tr '\0' 'a')
run "oversized command fails closed"         2 "git commit -m $BIG"

# --- chained commands: every segment is classified on its own ---------------------------------
run "commit then force-push"                 2 'git commit -m "ok" && git push -f origin feat/x'
run "commit; force-push"                     2 'git commit -m "ok"; git push --force origin feat/x'
run "commit || force-push"                   2 'git commit -m "ok" || git push -f'
run "commit newline force-push"              2 'git commit -m "ok"
git push -f origin feat/x'
run "commit then plain push"                 0 'git commit -m "ok" && git push -u origin feat/x'

# --- --no-verify skips the repo's own git hooks (CLAUDE.md §14) --------------------------------
run "commit --no-verify"                     2 'git commit --no-verify -m "x"'
run "commit --no-verify on continuation"     2 'git commit \
  --no-verify \
  -m "x"'
run "commit -n short flag"                   2 'git commit -n -m "x"'
run "commit -anm combined short flags"       2 'git commit -anm "x"'
run "commit -n glued to a redirect"          2 'git commit -m x -n>/dev/null'
run "push --no-verify"                       2 'git push --no-verify origin feat/x'
run "commit then push --no-verify"           2 'git commit -m "x" && git push --no-verify'
run "hooksPath -c override on commit"        2 'git -c core.hooksPath=/dev/null commit -m "x"'
run "hooksPath config then commit"           2 'git config core.hooksPath /dev/null; git commit -m "x"'
run "hooksPath via GIT_CONFIG_PARAMETERS"    2 'GIT_CONFIG_PARAMETERS="core.hooksPath=/dev/null" git commit -m "x"'
run "git log --no-verify is not a commit"    0 'git log --no-verify'
run "commit --amend --no-edit"               0 'git commit --amend --no-edit'
run "commit --signoff"                       0 'git commit --signoff -m "x"'

# --- shell wrappers hide the real command: refuse rather than guess ----------------------------
run "bash -c wrapper"                        2 'bash -c "git push -f origin main"'
run "sh -c wrapper"                          2 'sh -c '"'"'git commit --no-verify -m x'"'"''
run "eval wrapper"                           2 'eval "git push --force origin main"'
run "script named *.sh before a commit"      0 'bash tests/hooks/test-format.sh && git commit -m "x"'

# --- AI attribution in the commit message (CLAUDE.md §2) ---------------------------------------
run "co-authored-by trailer"                 2 'git commit -m "feat: x" -m "Co-authored-by: Claude <noreply@anthropic.com>"'
run "generated-with line"                    2 'git commit -m "feat: x" -m "Generated with Claude Code"'
run "robot emoji"                            2 'git commit -m "🤖 feat: x"'
run "bare tool mention is fine"              0 'git commit -m "docs: describe the Claude Code hook"'

# --- committer must be a human (CLAUDE.md §2) --------------------------------------------------
BOT=$(mkrepo "Claude")
cd "$BOT" || exit 1
run "non-human committer"                    2 'git commit -m "x"'
BOT2=$(mkrepo "github-actions[bot]")
cd "$BOT2" || exit 1
run "github-actions committer"               2 'git commit -m "x"'
cd "$REPO" || exit 1

# --- secrets in the staged diff (CLAUDE.md §11), incl. the -a auto-stage path (229e95d) --------
printf 'aws_key=%s\n' "$AWS_KEY" >>tracked.txt
run "dirty tracked secret, plain commit"     0 'git commit -m "x"'
run "dirty tracked secret, commit -am"       2 'git commit -am "x"'
run "dirty tracked secret, commit --all"     2 'git commit --all -m "x"'
run "dirty tracked secret, add && commit"    2 'git add tracked.txt && git commit -m "x"'
git checkout -q -- tracked.txt

printf 'aws_key=%s\n' "$AWS_KEY" >config.txt
git add config.txt
run "staged secret"                          2 'git commit -m "x"'
git rm -q --cached config.txt && rm config.txt

printf 'aws_key=%s\n' "$AWS_KEY" >config.txt
run "untracked secret, add && commit"        2 'git add config.txt && git commit -m "x"'
run "untracked secret, add -A && commit"     2 'git add -A && git commit -m "x"'
run "untracked secret, plain commit"         0 'git commit -m "x"'
rm config.txt

printf 'aws_key=%s\n' "$AWS_KEY" >.env.example
git add .env.example
run "staged secret in .env.example (72d9ea4)" 0 'git commit -m "x"'
git rm -q --cached .env.example
run "untracked .env.example, add && commit"  0 'git add .env.example && git commit -m "x"'
rm .env.example

printf '%s\n' "$PEM_HEADER" >key.txt
git add key.txt
run "staged private key header"              2 'git commit -m "x"'
git rm -q --cached key.txt && rm key.txt

# Scrubbing a leaked secret (a removed line) must stay committable; git is called directly here,
# the hook is not involved in seeding the leak.
printf 'aws_key=%s\n' "$AWS_KEY" >leaked.txt
git add leaked.txt && git commit -qm "seed leak"
printf 'aws_key=REDACTED\n' >leaked.txt
git add leaked.txt
run "removing a leaked secret is allowed"    0 'git commit -m "chore: scrub leaked key"'
run "removing a leaked secret via add && commit" 0 'git add leaked.txt && git commit -m "chore: scrub"'
git reset -q --hard HEAD~1

# --- missing jq: fail closed for git commit/push, stay out of the way otherwise ----------------
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for t in bash sh grep git sed tr printf cat; do
  p=$(command -v "$t") && ln -s "$p" "$NOJQ/$t"
done
run_nojq() {
  printf '%s' "$3" | jq -Rs '{tool_input:{command:.}}' >"$TMP/payload"
  PATH="$NOJQ" bash "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}
run_nojq "no jq: commit fails closed"        2 'git commit -m "x"'
run_nojq "no jq: unrelated command allowed"  0 'ls'

# Every case in this file must have been counted: a case that ran in a subshell would be lost.
EXPECTED=$(grep -cE '^(run|run_raw|run_nojq) ' "$SELF")
if [ "$((PASS + FAIL))" -ne "$EXPECTED" ]; then
  echo "FAIL: $EXPECTED cases defined, $((PASS + FAIL)) counted"
  FAIL=$((FAIL + 1))
fi

echo "guard-commit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
