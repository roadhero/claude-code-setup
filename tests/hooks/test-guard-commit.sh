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

# run_err <name> <expected-exit> <stderr must contain> <command>: also asserts exactly one "cannot classify" line
run_err() {
  printf '%s' "$4" | jq -Rs '{tool_input:{command:.}}' | bash "$HOOK" >"$TMP/out" 2>"$TMP/err"
  rc=$?
  if grep -qF -- "$3" "$TMP/err" && [ "$(grep -c 'cannot classify' "$TMP/err")" -eq 1 ] && [ ! -s "$TMP/out" ]; then
    record "$1" "$2" "$rc" "$4"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (stderr lacks '$3', or not exactly one reason line, or stdout not empty): $4"; sed 's/^/      stderr: /' "$TMP/err"
  fi
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
run "case inside a substitution in a body"   2 'cat <<EOF
$(case x in x) git push -f origin main;; esac)
EOF'
run "multi-line here-string then push"       2 'read -r a <<<"hello
world"
git push -f origin main'
run "EOF)\" terminator then a chained push"  2 'git commit -m "$(cat <<EOF
body
EOF)" && git push -f origin main'
run "EOF) && terminator"                     2 'x=$(cat <<EOF
body
EOF) && git push -f origin main'
run "EOF)\" terminator then push on next line" 2 'git commit -m "$(cat <<EOF
body
EOF)"
git push -f origin main'
run "heredoc nested inside a body substitution" 2 'cat <<EOF
$(cat <<INNER
hello
INNER
)
EOF
git push -f origin main'
run "marker line continued then push"        2 'cat <<EOF \
; git push -f origin main
EOF'
run "marker line with an open quote"         2 'cat <<EOF "x
" ; git push -f origin main
EOF'
run "unclosed \$( inside a body, then case"  2 'cat <<EOF
$(echo hi
EOF
case x in x) git push -f origin main;; esac'
run "substitution with marker closed on its line" 2 'x=$(cat <<EOF)
git push -f origin main
EOF'
run "backslash-escaped -f"                   2 'git push \-f origin main'
BIGSEG=$(head -c 1200 /dev/zero | tr '\0' ';')
run "too many segments fails closed"         2 "git commit -m x $BIGSEG"

# --- a leaked frame must never turn the closing quote into an opening one ---------------------
run "word case inside \$( ) then push"       2 'x="$(echo case)" ; git push --force origin main'
run "use-case.md inside \$( ) then push"     2 'git commit -m "$(cat docs/use-case.md)" && git push --force origin main'
run "edge-case inside \$( ) then --no-verify" 2 'git commit -m "$(basename feat/edge-case)" ; git commit --no-verify -m x'
run "unbalanced [ inside \$( ) then push"    2 'x="$(echo [)" ; git push --force origin main'
run "unclosed \${ inside \$( ) then push"    2 'x="$(echo ${a)" ; git push --force origin main'
run "# inside \${ } is not a comment"        2 'echo ${x:-a #b} ; git push --force origin main'
run "# inside quoted \${ } is not a comment" 2 'echo "${BRANCH:-main #default}" ; git push --force origin main'
run "case without esac inside \$( )"         2 'x="$(case a in a) echo hi )"
git push -f origin main'
run "case without esac, echo form"           2 'echo "$(case a in a) x )"
git push -f origin main'
run "unbalanced quote inside \${ }"          2 'echo ${x//"/} ; git push --force origin main'
run "unclosed \$( at end of input"           2 'x=$(echo hi
git push -f origin main'
run "; inside \${ } does not split a push"   2 'git push ${x:-;} --force origin main'
run "| inside \${ } does not split a commit" 2 'git commit ${x:-a|} --no-verify -m x'
run "; inside \${ } in a -c value"           2 'git -c ${x:-x.y=z;} push --force origin main'
run "; inside a real \$( ) still splits"     2 'x=$(echo hi; git push -f origin main)'
run "# after (( )) is a comment"             2 '((1))#c <<EOF
git push --force origin main'
run "# after \$(( )) is part of the word"    0 'echo $((1))#c <<EOF
git push --force origin main is body here'
run "function definition then case"          2 'x="$(f() case a in a) git push --force origin main;; esac
f)"'
run "function def then case, --no-verify"    2 'git commit -m "$(f() case a in a) git commit --no-verify -m x;; esac
f)"'
run "coproc then case"                       2 'x="$(coproc case a in a) git push --force origin main;; esac)"'
run "subcommand split by quotes"             2 'git pu"sh" --force origin main'
run "subcommand split by quotes, other cut"  2 'git p"ush" --force origin main'
run "subcommand as an ANSI-C string"         2 'git $'"'"'push'"'"' --force origin main'
run "subcommand split by a backslash"        2 'git pus\h --force origin main'
run "commit split by empty quotes"           2 'git commi""t --no-verify -m x'
run "commit split by a backslash"            2 'git com\mit --no-verify -m x'
run "flag in quotes"                         2 'git push "-f" origin main'
run "flag split by quotes"                   2 'git commit --no-veri"fy" -m x'
run "flag as an ANSI-C string"               2 'git commit $'"'"'--no-verify'"'"' -m x'
run "one-word quoted message is harmless"    0 'git commit -m "tidy"'
run "quoted ; is data, flag stays with git"  2 'git commit -m "x;" --no-verify'
run "quoted ; in a -c value"                 2 'git -c "a.b=y;" push --force origin main'
run "quoted | in a -c value"                 2 'git -c '"'"'a.b=y|'"'"' push -f origin main'
run "ANSI-C & in a -c value"                 2 'git -c $'"'"'a.b=y&'"'"' push -f origin main'
run "message with ; then a plain push"       0 'git commit -m "a;b" && git push origin feat/x'
run "ANSI-C hex escape in the subcommand"    2 'git $'"'"'\x70ush'"'"' --force origin main'
run "ANSI-C octal escape in the subcommand"  2 'git $'"'"'\160ush'"'"' --force origin main'
run "ANSI-C hex escape in the flag"          2 'git push $'"'"'\x2d\x66'"'"' origin main'
run "ANSI-C unicode escape"                  2 'git $'"'"'\u0070ush'"'"' --force origin main'
run "commit -F is not a force flag"          0 'git commit -m "push" -F /dev/null'
run "git split by quotes"                    2 'g"it" push --force origin main'
run "git split by single quotes"             2 'gi'"'"'t'"'"' push -f origin main'
run "git split by empty quotes"              2 'gi'"'"''"'"'t push -f origin main'
run "git split by a backslash"               2 'gi\t push -f origin main'
run "git split, --no-verify"                 2 'g"it" commit --no-verify -m x'
run "git as an ANSI-C hex string"            2 '$'"'"'\x67it'"'"' push -f origin main'
run_err "refusal names the construct" 2 "numeric escape" 'git commit -m x; echo $'"'"'\033[0m'"'"''
run_err "refusal names an open quote"  2 "left open" 'x=$(echo hi
git push -f origin main'

# --- a newline is a command boundary only at the top level in code ------------------------------
run "newline inside a quoted push argument"  2 'git push "multi
line" --force origin main'
run "newline inside a quoted commit message" 2 'git commit -m "line one
line two" --no-verify'
run "heredoc message then --no-verify"       2 'git commit -m "$(cat <<EOF
feat: x

body
EOF
)" --no-verify'
run "newline inside a -c value"              2 'git -c "a
b" commit --no-verify -m x'
run "backslash-newline inside double quotes" 2 'git push "x\
y" --force origin main'
run "heredoc message then a plain push"      0 'git commit -m "$(cat <<'"'"'EOF'"'"'
feat: x

body
EOF
)"
git push origin feat/x'
run "# on a continuation line is not a comment" 2 'git commit -m x\
#; git push -f origin main'
run "# on a continuation after echo"         2 'echo a\
#; git push --force origin main'
run_raw "JSON unicode escape in the subcommand" 2 '{"tool_input":{"command":"git push --force origin main"}}'
run_raw "JSON unicode escape in git"         2 '{"tool_input":{"command":"git push --force origin main"}}'
run_raw "pretty-printed payload"             2 '{
  "tool_input": {
    "command": "git push --force origin main"
  }
}'
# shellcheck disable=SC1003  # the \' is part of the command under test
run "ANSI-C with an escaped quote before a hex escape" 2 'git $'"'"'a\'"'"'\x70ush'"'"' --force origin main'
run "coproc NAME case"                       2 'x="$(coproc nm case a in a) git push --force origin main;; esac)"'
run "time -p case"                           2 'x="$( { time -p case a in a) git push --force origin main;; esac; } )"'
run "hooksPath value with a space"           2 'git -c "core.hooksPath=/no such" commit -m x'

# --- a separator inside $( ) ends a command of the substitution, never the enclosing one --------
run "pipe inside a refspec substitution"     2 'git push origin "$(git branch --show-current | tr -d '"'"' '"'"')" --force'
run "pipe inside a message substitution"     2 'git commit -m "$(git log -1 --pretty=%s | cut -c1-50)" --no-verify'
run "; inside a message substitution"        2 'git commit -m "$(echo a; echo b)" --no-verify'
run "&& inside a message substitution"       2 'git commit -m "$(date && echo)" -n'
run "backtick substitution with a pipe"      2 'git commit -m "`echo a | cat`" --no-verify'
run "; inside \$( ) still separates there"   2 'x=$(echo hi; git push -f origin main)'
run "multi-line subshell with a plain push"  0 '(
cd sub
git push origin main
rm -f tmp
)'
run "multi-line subshell with ls -n"         0 '(
git commit -m x
ls -n
)'
run "absolute-path sh -c wrapper"            2 '/bin/sh -c "git push --force origin main"'
run "absolute-path bash -c wrapper"          2 '/bin/bash -c "git commit --no-verify -m x"'
run "\$'EOF' quoted delimiter then push"     2 'cat <<$'"'"'EOF'"'"'
body
EOF
git push -f origin main'
run "numeric escape with no git is allowed"  0 'find . -print0 | while IFS= read -r -d $'"'"'\0'"'"' f; do echo "$f"; done'
run "numeric escape with a commit still refused" 2 'git commit -m x; echo $'"'"'\033[0m'"'"''

# --- a newline inside ${ }, $(( )) or $[ ] does not end the enclosing command --------------------
run "newline inside \${ } before --force"    2 'git push origin main ${x:-
} --force'
run "newline inside quoted \${ } before --no-verify" 2 'git commit -m "${x:-
}" --no-verify'
run "newline inside \$(( )) before --force"  2 'git push origin main $((1+
1)) --force'
run "newline inside \$[ ] before --force"    2 'git push origin main $[1+
1] --force'
run "bash -x -c wrapper"                     2 'bash -x -c "git push --force origin main"'
run "bash --norc -c wrapper"                 2 'bash --norc -c "git commit --no-verify -m x"'
run "bash -o pipefail -c wrapper"            2 'bash -o pipefail -c "git commit --no-verify -m x"'
run "ksh -c wrapper"                         2 'ksh -c "git push --force origin main"'
DENSE=$(for _ in $(seq 1 600); do printf '  "key": "value",\n'; done)
run "quote-dense non-git heredoc is allowed" 0 "cat > package.json <<'EOF'
{
$DENSE
}
EOF"
run "quoted message with spaces stays data"  0 'git commit -m "never git push -f"'
MANY=$(for _ in $(seq 1 20); do printf ' <<A'; done)
run "twenty heredocs on one line fail closed" 2 ": $MANY
git push -f origin main"
run "unbalanced [ then a benign heredoc"     0 'echo [
cat > n.md <<EOF
never git push -f
EOF'
PAD=$(for _ in $(seq 1 400); do printf 'echo %s\n' "$(head -c 190 /dev/zero | tr '\0' 'a')"; done)
run "wrapper after 80 KB of padding"         2 "$PAD
bash -c \"git push --force origin main\""
run "hooksPath after 80 KB of padding"       2 "$PAD
git -c core.hooksPath=/dev/null commit -m x"
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
run "dirty tracked secret, -a then ;"        2 'git commit -m x -a;git push origin x'
run "dirty tracked secret, pathspec commit"  2 'git commit -m "x" tracked.txt'
run "dirty tracked secret, --include"        2 'git commit --include tracked.txt -m "x"'
run "dirty tracked secret, add && commit"    2 'git add tracked.txt && git commit -m "x"'
git checkout -q -- tracked.txt

printf 'PASSWORD=%s\n' "$(printf 'B%.0s' $(seq 1 26))" >shout.txt
run "untracked uppercase secret, add && commit" 2 'git add shout.txt && git commit -m "x"'
rm shout.txt

git config diff.algorithm bogus
run "git diff failure fails closed"          2 'git commit -m "x"'
git config --unset diff.algorithm

printf 'aws_key=%s\n' "$AWS_KEY" >color.txt
git add color.txt
git config color.ui always
run "color.ui=always does not hide a staged secret" 2 'git commit -m "x"'
git config --unset color.ui
git rm -q --cached color.txt && rm color.txt

ln -s /nonexistent-target dangling
run "dangling symlink does not break add && commit" 0 'git add dangling && git commit -m "x"'
rm dangling

printf '*.txt -diff\n' >.gitattributes
printf 'aws_key=%s\n' "$AWS_KEY" >nodiff.txt
git add .gitattributes nodiff.txt
run "-diff attribute does not hide a staged secret" 2 'git commit -m "x"'
git rm -q --cached .gitattributes nodiff.txt && rm .gitattributes nodiff.txt

printf 'aws_key=%s\n\0\n' "$AWS_KEY" >nul.txt
git add nul.txt
run "NUL byte does not hide a staged secret" 2 'git commit -m "x"'
git rm -q --cached nul.txt
run "NUL byte does not hide an untracked secret" 2 'git add nul.txt && git commit -m "x"'
rm nul.txt

printf '*.txt diff=hide\n' >.gitattributes
git config diff.hide.textconv 'sed s/AKIA/XXXX/'
printf 'aws_key=%s\n' "$AWS_KEY" >conv.txt
git add .gitattributes conv.txt
run "textconv does not rewrite the staged secret" 2 'git commit -m "x"'
git config --unset diff.hide.textconv
git rm -q --cached .gitattributes conv.txt && rm .gitattributes conv.txt

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

# A secret on line 1 of a staged diff far larger than a pipe buffer must still be seen.
{ printf 'aws_key=%s\n' "$AWS_KEY"; head -c 200000 /dev/zero | tr '\0' 'b' | fold -w 80; } >big.txt
git add big.txt
run "secret at the top of a 200 KB staged diff" 2 'git commit -m "x"'
git rm -q --cached big.txt && rm big.txt

printf '++aws_key=%s\n' "$AWS_KEY" >plus.txt
git add plus.txt
run "secret on an added line starting with ++" 2 'git commit -m "x"'
git rm -q --cached plus.txt && rm plus.txt

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

# --- missing awk: the strip cannot run, so a git commit/push fails closed ---------------------
NOAWK="$TMP/noawk"
mkdir -p "$NOAWK"
for t in bash sh grep git sed tr printf cat jq wc; do
  p=$(command -v "$t") && ln -s "$p" "$NOAWK/$t"
done
run_noawk() {
  printf '%s' "$3" | jq -Rs '{tool_input:{command:.}}' >"$TMP/payload"
  PATH="$NOAWK" bash "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}
run_noawk "no awk: commit fails closed"      2 'git commit -m "x"'
run_noawk "no awk: unrelated command allowed" 0 'ls'

# --- missing tr or wc: the segment split cannot run, so a git commit/push fails closed ----------
mktoolbox() { # mktoolbox <dir> <tools...>
  mkdir -p "$1"; d=$1; shift
  for t in "$@"; do p=$(command -v "$t") && ln -s "$p" "$d/$t"; done
}
mktoolbox "$TMP/notr" bash sh grep git sed awk printf cat jq wc
mktoolbox "$TMP/nowc" bash sh grep git sed awk printf cat jq tr
run_without() { # run_without <toolbox> <name> <expected-exit> <command>
  printf '%s' "$4" | jq -Rs '{tool_input:{command:.}}' >"$TMP/payload"
  PATH="$1" bash "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
  record "$2" "$3" $? "$4"
}
run_without "$TMP/notr" "no tr: push fails closed"      2 'git push --force origin main'
run_without "$TMP/nowc" "no wc: commit fails closed"    2 'git commit --no-verify -m x'
run_without "$TMP/notr" "no tr: unrelated command allowed" 0 'ls'

# Every case in this file must have been counted: a case that ran in a subshell would be lost.
EXPECTED=$(grep -cE '^(run|run_raw|run_err|run_nojq|run_noawk|run_without) ' "$SELF")
if [ "$((PASS + FAIL))" -ne "$EXPECTED" ]; then
  echo "FAIL: $EXPECTED cases defined, $((PASS + FAIL)) counted"
  FAIL=$((FAIL + 1))
fi

echo "guard-commit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
