#!/usr/bin/env bash
# Behavioral tests for hooks/guard-commit.sh: a PreToolUse(Bash) payload on stdin, an exit code out.
# 0 = allow, 2 = block. One case per rule the hook enforces and per regression it has had.
# Runs on macOS system bash 3.2 with jq + git only.  Usage: bash tests/hooks/test-guard-commit.sh
# shellcheck disable=SC2016  # several cases deliberately pass literal "$(cat <<'EOF' ...)" commit messages
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
HOOK="$HERE/../../hooks/guard-commit.sh"
BASH=/bin/bash; [ -x "$BASH" ] || BASH=bash   # the macOS system bash 3.2 when present, whatever is on PATH otherwise
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
  printf '%s' "$3" | jq -Rs '{tool_input:{command:.}}' | "$BASH" "$HOOK" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}

# run_raw <name> <expected-exit> <raw stdin for the hook>
run_raw() {
  printf '%s' "$3" | "$BASH" "$HOOK" >/dev/null 2>"$TMP/err"
  record "$1" "$2" $? "$3"
}

# run_err <name> <expected-exit> <stderr must contain> <command>: also asserts exactly one "cannot classify" line
run_err() {
  printf '%s' "$4" | jq -Rs '{tool_input:{command:.}}' | "$BASH" "$HOOK" >"$TMP/out" 2>"$TMP/err"
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
BS="\\"   # a literal backslash, so the JSON below really contains backslash-u escapes
run_raw "JSON unicode escape in the subcommand" 2 '{"tool_input":{"command":"git pu'"$BS"'u0073h --force origin main"}}'
run_raw "JSON unicode escape in git"         2 '{"tool_input":{"command":"g'"$BS"'u0069t push --force origin main"}}'
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
run "ash -c wrapper"                         2 'ash -c "git push --force origin main"'
run "bash -cx cluster"                       2 'bash -cx "git push --force origin main"'
run "bash -ceu cluster"                      2 'bash -ceu "git commit --no-verify -m x"'
run "bash fed by a heredoc"                  2 'bash <<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "bash -s fed by a heredoc"               2 'bash -s <<'"'"'EOF'"'"'
git commit --no-verify -m x
EOF'
run "bash fed by a here-string"              2 'bash <<<"git push --force origin main"'
run "bash fed by a pipe"                     2 'echo "git push --force origin main" | bash'
run "sh -s fed by a heredoc pipe"            2 'cat <<'"'"'EOF'"'"' | sh -s
git push --force origin main
EOF'
run "bash fed by a file"                     2 'bash < run.sh; git push origin main'
run "trap runs text at exit"                 2 'trap "git push --force origin main" EXIT; true'
run "wrapper elsewhere in the call (documented false block)" 2 'git commit -m "x" && bash -c "echo done"'
run "shell with leading option before a script (documented false block)" 2 'bash -x build.sh && git commit -m x'
run "script with its own -c argument is allowed" 0 'bash build.sh -c release && git commit -m x'
run "script with its own --check is allowed"  0 'bash scripts/publish.sh --check && git commit -m x'
run "sourcing a venv is allowed"             0 '. ./venv/bin/activate && git commit -m x'
run "ssh -c cipher is not a wrapper"         0 'ssh -c aes256-ctr host git commit -m x'
run "bash --norc fed by a heredoc"           2 'bash --norc <<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "bash -o pipefail fed by a heredoc"      2 'bash -o pipefail <<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "bash /dev/stdin fed by a heredoc"       2 'bash /dev/stdin <<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "bash 0<< fed by a heredoc"              2 'bash 0<<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "pipe into bash then ;"                  2 'echo "git push --force origin main" | bash; true'
run "pipe into sh inside a subshell"         2 '(echo "git push --force origin main" | sh)'
run "pipe into bash on the next line"        2 'printf "git push --force origin main" |
bash'
run "exec-redirected stdin then bare bash"   2 'exec <<'"'"'EOF'"'"'
git push --force origin main
EOF
bash'
run "bash fed by a process substitution"     2 'bash <(echo "git push --force origin main")'
run "source of a process substitution"       2 'source <(echo "git push --force origin main")'
run "env -S splits a string into a command"  2 'env -S "bash -c '"'"'git push --force origin main'"'"'"'
run "alias defined with -c, same call"       2 'git -c alias.fp=push fp --force origin main'
run "alias with the flag inside, same call"  2 'git -c alias.fp="push --force" fp origin main'
run "alias via git config, same call"        2 'git config alias.fp "push --force"; git fp origin main'
run "alias for a no-verify commit"           2 'git -c alias.nv="commit --no-verify" nv -m x'
run "alias lookup next to a commit (documented false block)" 2 'git config --get alias.st; git commit -m x'

# --- only a real command boundary splits a segment ---------------------------------------------
run "escaped ; in a -c value"                2 'git -c a.b=x\;y push -f origin main'
run "escaped ; in an unquoted message"       2 'git commit -m msg\;more --no-verify'
run "escaped & in a -c value"                2 'git -c a.b=x\&y push -f origin main'
run "escaped | in a -c value"                2 'git -c a.b=x\|y push -f origin main'
run "2>&1 before --force"                    2 'git push origin main 2>&1 --force'
run "2>&1 before --force-with-lease"         2 'git push origin main 2>&1 --force-with-lease'
run "2>&1 before +refspec"                   2 'git push origin 2>&1 +main'
run ">& before --force"                      2 'git push origin main >&/dev/null --force'
run "<&- before --force"                     2 'git push origin main <&- --force'
run "3>&2 before --force"                    2 'git push origin main 3>&2 --force'
run "&> before --force"                      2 'git push origin main &>/dev/null --force'
run ">| before --force"                      2 'git push origin main >|/tmp/log --force'
run "2>&1 before --no-verify"                2 'git commit -m x 2>&1 --no-verify'
run "2>&1 before -n"                         2 'git commit -m x 2>&1 -n'
run ">| before --no-verify"                  2 'git commit -m x >|/tmp/log --no-verify'
run "2>&1 then a real ; then plain push"     0 'git commit -m x 2>&1; git push origin feat/x'
run "wrapper directly inside a subshell"     2 '(eval "git push -f origin main")'
run "bash -c directly inside a subshell"     2 '(bash -c "git push -f origin main")'
run "trap directly inside a subshell"        2 '(trap "git push -f origin main" EXIT; true)'
run "eval directly inside \$( )"             2 'x=$(eval "git push -f origin main")'
run "bash -c directly inside \$( )"          2 'x=$(bash -c "git push -f origin main")'
run "bash heredoc directly inside \$( )"     2 'x=$(bash <<'"'"'EOF'"'"'
git push -f origin main
EOF
)'
run "bash 2>&1 -c wrapper"                   2 'bash 2>&1 -c "git push -f origin main"'
run "bash 3>&2 -c wrapper"                   2 'bash 3>&2 -c "git commit --no-verify -m x"'
run "sh -c right after ("                    2 '(sh -c "git push --force origin main")'
run "bash heredoc right after ("             2 '(bash <<'"'"'EOF'"'"'
git push --force origin main
EOF
)'
run "pipe into (bash)"                       2 'echo "git push --force origin main" | (bash)'
run "sh -c right after \$("                  2 'x=$(sh -c "git push --force origin main")'
run "here-string bash inside a message substitution" 2 'git commit -m "$(bash <<<"git push --force origin main")"'
run "eval inside a message substitution"     2 'git commit -m "$(eval "git push --force origin main")"'
run "bash -c right after a case pattern"     2 'case x in x)bash -c "git push --force origin main";; esac'
run "bare bash then 2>/dev/null"             2 'echo "git push --force origin main" | bash 2>/dev/null'
run "bare bash then >/dev/null 2>&1"         2 'echo "git push --force origin main" | bash >/dev/null 2>&1'
run "bare bash then > log"                   2 'echo "git push --force origin main" | bash > log'
run "bare bash then 2>&1 | tee"              2 'echo "git push --force origin main" | bash 2>&1 | tee log'
run "heredoc glued to bash"                  2 'bash<<'"'"'EOF'"'"'
git push --force origin main
EOF'
run "here-string glued to bash"              2 'bash<<<"git push --force origin main"'
run "file glued to sh then commit"           2 'sh<run.sh; git commit -m x'
run "env -i -S"                              2 'env -i -S "bash -c '"'"'git push --force origin main'"'"'"'
run "env -u X -S"                            2 'env -u X -S "bash -c '"'"'git push --force origin main'"'"'"'
run "env FOO=1 -S"                           2 'env FOO=1 -S "bash -c '"'"'git push --force origin main'"'"'"'
run "env --split-string"                     2 'env --split-string="bash -c '"'"'git push --force origin main'"'"'"'
run "env -C dir -S"                          2 'env -C /tmp -S "bash -c '"'"'git push --force origin main'"'"'"'
run "ksh93 -c wrapper"                       2 'ksh93 -c "git push --force origin main"'
run "bash5 -c wrapper"                       2 'bash5 -c "git push --force origin main"'
run "bash \$a -c wrapper"                    2 'bash $a -c "git push --force origin main"'
run "bash \${a} -c wrapper"                  2 'bash ${a} -c "git push --force origin main"'
run "bash \"\$a\" -c wrapper"                2 'bash "$a" -c "git push --force origin main"'
run "sh \$(:) -c wrapper"                    2 'sh $(:) -c "git push --force origin main"'
run "sh backtick -c wrapper"                 2 'sh `:` -c "git push --force origin main"'
run "env \${a} -S wrapper"                   2 'env ${a} -S "bash -c '"'"'git push --force origin main'"'"'"'
run "pipe into bash \$a"                     2 'echo "git push --force origin main" | bash $a'
run "push with an array subscript pipe"      2 'git push origin main ${a[1|2]} --force'
run "push with an array subscript ampersand" 2 'git push origin main ${a[1&2]} --force'
run "push with a quoted array subscript"     2 'git push origin main "${a[1|2]}" --force'
run "push with an arithmetic subscript"      2 'git push origin main $((a[1|2])) --force'
run "push with a nested subscript"           2 'git push origin main ${a[${b[1|2]}]} --force'
run "commit with a subscript then --no-verify" 2 'git commit ${a[1|2]} --no-verify -m x'
run "subscript between git and commit, bad committer" 2 'git -c user.name=Claude ${a[1|2]} commit -m x'
run "-c user.name override to a bot"          2 'git -c user.name=Claude commit -m x'
run "-c user.name override, quoted two words" 2 'git -c user.name="Claude Bot" commit -m x'
run "-c whole-arg quoted user.name to a bot" 2 'git -c "user.name=Claude Bot" commit -m x'
run "-c whole-arg single-quoted user.name to a bot" 2 'git -c '"'"'user.name=Claude Bot'"'"' commit -m x'
run "whole-arg quoted --author to a bot"     2 'git commit "--author=Claude Bot <c@e.com>" -m x'
run "-c whole-arg quoted user.name to a human" 0 'git -c "user.name=Dennis Vorobyov" commit -m x'
run "bot name with a trailing digit"         2 'git -c user.name=Claude2 commit -m x'
run "GIT_COMMITTER_NAME override to a bot"    2 'GIT_COMMITTER_NAME=Claude git commit -m x'
run "GIT_AUTHOR_NAME override to a bot"       2 'GIT_AUTHOR_NAME=Cursor git commit -m x'
run "--author override to a bot"              2 'git commit --author="Claude <c@example.com>" -m x'
run "--author space form to a bot"            2 'git commit --author "github-actions <a@b>" -m x'
run "-c user.name override to a human"        0 'git -c user.name="Dennis Vorobyov" commit -m "docs: Claude Code hooks"'
run "GIT_COMMITTER_NAME human then a quoted message naming a tool" 0 'GIT_COMMITTER_NAME=Dennis git commit -m "docs: Claude Code hooks"'
run "--author human with a tool in the message" 0 'git commit --author="Dennis V <d@example.com>" -m "explain Claude Code"'
run "test bracket then push -f still blocks" 2 '[ -f x ] && git push -f origin main'
run "double bracket then push -f still blocks" 2 '[[ -n x && -n y ]] && git push -f origin main'
run "commit with an unquoted glob flag"      2 'git commit -m x -*'
run "commit with an unquoted ? word"         2 'git commit -m x ?'
run "push with a brace-expanded flag"        2 'git push origin main --{force,}'
run "push with a brace range"                2 'git push origin main --{f..f}'
run "quoted * message is allowed"            0 'git commit -m "*"'
run "quoted brace message is allowed"        0 'git commit -m "fix {a,b}"'
run "escaped * message is allowed"           0 'git commit -m \*'
run "brace group around a plain push"        0 '{ git push origin feat/x; }'
run "git add * in its own segment then commit" 0 'git add * && git commit -m x'
run "commit with a bracket pattern flag"     2 'git commit -m x -[n]'
run "push with a bracket pattern flag"       2 'git push origin main -[f]'
run "commit with a word-glued bracket pattern" 2 'git commit -m x f[ab]'
run "array assignment then a plain commit"   0 'a[1]=x; git commit -m y'
run "[ in a brace default then push -f"      2 'echo ${x:-[} ; git push -f origin main ; : ]}'
run "[ in a brace default then push --force" 2 'echo ${x:-[} && git push --force origin main && : ]}'
run "[ in a brace replacement then --no-verify" 2 'echo ${x/a/[} ; git commit --no-verify -m x ; : ]}'
run "[ in a brace default then a bot committer" 2 'git status ${x:-[} ; git -c user.name=Claude commit -m x ; : ]}'
run "[ in a subscripted brace default then push -f" 2 'echo ${a[0]:-[} ; git push -f origin main ; : ]}'
run "[] in a brace default then a plain commit" 0 'echo ${x:-[]}; git commit -m x'
run "( left open inside a brace is refused"  2 'echo ${x:-(} ; git commit -m x'
run "bash with a three-line \${ } then -c"    2 'a=; bash ${a-
foo
bar} -c "git push -f origin main"'
run "bash with a continued \${ } then -c"     2 'bash ${x:-a\
b} -c "git push -f origin main"'
run "case pattern then a plain commit"       0 'case "$1" in build) make;; *) git commit -m y;; esac'
run "case pattern with ? then a plain push"  0 'case x in a?) git push origin main;; esac'
run "case pattern inside a message substitution" 0 'git commit -m "$(case x in a) echo y;; esac)"'
run "GIT_CONFIG_VALUE user.name is refused"  2 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=bot@example.com git commit -m x'
run "GIT_CONFIG_COUNT on a push is refused"  2 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp git push origin main'
run "GIT_CONFIG_GLOBAL inline on a commit is refused" 2 'GIT_CONFIG_GLOBAL=/tmp/cfg git commit -m x'
run "include.path on a commit is refused"    2 'git -c include.path=/tmp/cfg commit -m x'
run "includeIf on a commit is refused"       2 'git -c includeIf.gitdir:/x.path=/tmp/cfg commit -m x'
run "a file named includeIf.md is allowed"   0 'git commit -m x includeIf.md'
run "XDG_CONFIG_HOME on a commit is refused"  2 'XDG_CONFIG_HOME=/tmp/evil git commit -m x'
run "XDG_CONFIG_HOME on a push is refused"    2 'XDG_CONFIG_HOME=/tmp/evil git push origin main'
run "a message mentioning XDG_CONFIG_HOME with spaces is allowed" 0 'git commit -m "set XDG_CONFIG_HOME first"'
run "HOME= on a commit is refused"           2 'HOME=/tmp git commit -m x'
run "GIT_CONFIG_GLOBAL exported by the harness is invisible" 0 'git commit -m x'
run "substitution inside a quoted \${ } is refused" 2 'git commit -m "${v:-"$(git describe)"}"'
run "heredoc marker on a line ending inside \${ }" 2 'cat <<EOF ${x:-
}
EOF
git push -f origin main
: }'
run "heredoc marker inside an open \${ } then --no-verify" 2 'cat <<EOF ${x:-
}
EOF
git commit --no-verify -m x
: }'
run ") inside a quoted default then push -f" 2 ': "${x:-)}" ; git push -f origin main #"'
run ") inside a quoted replacement then --no-verify" 2 ': "${x/)/y}" ; git commit --no-verify -m x #"'
run ") inside a default, echo form"          2 'echo "${x:-)}"; git push origin main --force; echo "x <<EOF
more text"'
run ") inside an unquoted default in a push" 2 'git push origin main ${a:-)} --force'
run "bash \${a[@]} -c wrapper"               2 'bash ${a[@]} -c "git push --force origin main"'
run "bash \${a[0]} -c wrapper"               2 'bash ${a[0]} -c "git push --force origin main"'
run "bash \"\${a[@]}\" -c wrapper"           2 'bash "${a[@]}" -c "git push --force origin main"'
run "bash \"\${@}\" -c wrapper"              2 'bash "${@}" -c "git push --force origin main"'
run "bash \"backtick\" -c wrapper"           2 'bash "`:`" -c "git push --force origin main"'
run "bash backtick echo -c wrapper"          2 'bash `echo` -c "git push --force origin main"'
run "bash \${a[1 | 2]} -c wrapper"           2 'bash ${a[1 | 2]} -c "git push --force origin main"'
run "env \${a[@]} -S wrapper"                2 'env ${a[@]} -S "bash -c '"'"'git push --force origin main'"'"'"'
run "bash 5.3 funsub is refused"             2 '${ git push -f origin main; }'
run "substitution inside \${ } is refused"   2 'git commit -m "${v:-$(git describe)}"'
run "push with a quoted \${BRANCH##*/}"      0 'git commit -m "fix" && git push origin "HEAD:refs/heads/${BRANCH##*/}"'
run "push with an unquoted \${REF##*/}"      0 'git push origin HEAD:${REF##*/}'
run "push with \${BRANCH:?}"                 0 'git push origin ${BRANCH:?}'
run "commit then echo \${a[0]}"              0 'git commit -m x && echo "${a[0]}"'
run "message with parens naming a shell"     0 'git commit -m "fix(bash): x"'
run "message that is (sh)"                   0 'git commit -m "(sh)"'
run "quoted message mentioning user.name=claude" 0 'git commit -m "docs: never set user.name=claude"'
run "quoted message mentioning --author claude" 0 'git commit -m "fix: the --author claude check"'
run "-c user.name with an ANSI-C spliced bot" 2 'git -c user.name=$'"'"'Claude'"'"' commit -m x'
run "-c user.name with a quote-spliced bot"  2 'git -c user.name=Cla'"'"'ude'"'"' commit -m x'
run "--config-env user.name is refused"      2 'UN=ClaudeBot git --config-env=user.name=UN commit -m x'
run "GIT_CONFIG_KEY user.name is refused"    2 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Claude git commit -m x'
run "message mentioning --config-env is allowed" 0 'git commit -m "docs: explain --config-env"'
run_raw "control byte in the command is refused" 2 '{"tool_input":{"command":"git commit -m x'"$BS"'u0001 --no-verify"}}'
run "env with an assignment then a signed commit" 0 'env GIT_EDITOR=true git commit -S -m x'
run "shebang write then commit is allowed"   0 'echo '"'"'#!/bin/bash'"'"' > run.sh && git add run.sh && git commit -m x'
run "SHELL assignment then commit is allowed" 0 'export SHELL=/bin/zsh && git commit -m x'
run "bash >out script.sh is allowed"         0 'bash >out script.sh && git commit -m x'
run "which bash then commit (documented false block)" 2 'which bash && git commit -m x'
run "git add zsh bash fish (documented false block)" 2 'git add fish bash zsh && git commit -m "add shell configs"'
run "message mentioning alias.md is allowed" 0 'git commit -m "add alias.md"'
run "heredoc body mentioning an alias then commit" 0 'cat > notes.md <<'"'"'EOF'"'"'
use git config alias.co checkout once
EOF
git commit -m x'

# --- process substitution is a word of the enclosing command ------------------------------------
run "pipe inside <( ) before --force-with-lease" 2 'git push origin main <(git log --oneline | head -5) --force-with-lease'
run "; inside <( ) before --force"           2 'git push origin main <(echo a;echo b) --force'
run "; inside <( ) before +refspec"          2 'git push origin <(echo a;echo b) +main'
run "; inside <( ) before --no-verify"       2 'git commit -m x <(echo a;echo b) --no-verify'
run "&& inside <( ) before -n"               2 'git commit -m x <(echo a&&echo b) -n'
run "newline inside >( ) before --force"     2 'git push origin main >(cat
) --force'
run "<( ) control without a separator"       2 'git push origin main <(echo a) --force'
run "<( ) in a plain diff then commit"       0 'diff <(sort a) <(sort b); git commit -m "x"'
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
run "dirty tracked secret, 2>&1 then -a"     2 'git commit -m x 2>&1 -a'
run "dirty tracked secret, 2>&1 then --all"  2 'git commit -m x 2>&1 --all'
run "dirty tracked secret, escaped ; then -a" 2 'git commit -m x\;y -a'
run "dirty tracked secret, extension-less pathspec" 2 'git commit -m "x" tracked'
run "dirty tracked secret, -m value is not a pathspec" 0 'git commit -m fix'
run "dirty tracked secret, two-word message then pathspec" 2 'git commit -m "fix: two words" tracked.txt'
run "dirty tracked secret, multi-line message then pathspec" 2 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: x

body
EOF
)" tracked.txt'
run "dirty tracked secret, -S then pathspec" 2 'git commit -S tracked.txt -m x'
run "dirty tracked secret, --gpg-sign then pathspec" 2 'git commit --gpg-sign tracked.txt -m x'
run "dirty tracked secret, -m -F then pathspec" 2 'git commit -m -F tracked.txt'
run "dirty tracked secret, plain commit with 2>&1" 0 'git commit -m x 2>&1'
run "dirty tracked secret, plain commit to /dev/null" 0 'git commit -m x >/dev/null 2>&1'
run "dirty tracked secret, -qm cluster takes a value" 0 'git commit -qm fix'
run "dirty tracked secret, -sm cluster takes a value" 0 'git commit -sm fix'
run "dirty tracked secret, quoted a>b is a pathspec" 2 'git commit -m x "a>b"'
run "dirty tracked secret, heredoc message, no pathspec" 0 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: x

body
EOF
)"'
run "dirty tracked secret, \${msg} message, no pathspec" 0 'git commit -m "${msg}"'
run "dirty tracked secret, prefixed \${x} message, no pathspec" 0 'git commit -m "fix: ${x}"'
run "dirty tracked secret, backtick message, no pathspec" 0 'git commit -m "`date`"'
run "dirty tracked secret, backtick message then pathspec" 2 'git commit -m "`date`" tracked.txt'
run "dirty tracked secret, substitution message then pathspec" 2 'git commit -m "$(date)" tracked.txt'
run "dirty tracked secret, -SDEADBEEF is not -a" 0 'git commit -SDEADBEEF -m x'
run "dirty tracked secret, backtick with parens then pathspec" 2 'git commit -m "`(echo x)`" tracked.txt'
run "dirty tracked secret, backtick with <( ) then pathspec" 2 'git commit -m "`cat <(date)`" tracked.txt'
run "dirty tracked secret, pathspec glued to a redirect" 2 'git commit -m x tracked.txt>log'
run "dirty tracked secret, pathspec glued to 2>&1" 2 'git commit -m x tracked.txt2>&1'
run "dirty tracked secret, --pathspec-from-file" 2 'git commit -m x --pathspec-from-file=list'
run "dirty tracked secret, --patch"          2 'git commit -p -m x'
run "dirty tracked secret, redirect to a file, no pathspec" 0 'git commit -m x >log 2>&1'
run "dirty tracked secret, -m \$(date) then -- pathspec" 2 'git commit -m "$(date)" -- tracked.txt'
run "dirty tracked secret, quoted backtick word then pathspec" 2 'git commit -m '"'"'a`b'"'"' tracked.txt'
run "dirty tracked secret, literal \$( in a word then pathspec" 2 'git commit -m x$\(y tracked.txt'
run "dirty tracked secret, empty message then pathspec" 2 'git commit -m "" tracked.txt'
run "empty quote glued before push"          2 'git ""push --force origin main'
run "empty quote glued before the force flag" 2 'git push ""--force origin main'
run "empty quote glued before commit"        2 'git ""commit --no-verify -m x'
run "empty quote glued before commit, dirty secret" 2 'git ""commit -am x'
run "single empty quote glued before commit" 2 "git ''commit --no-verify -m x"
run "empty quote glued before a bash wrapper" 2 '""bash -c "git push --force origin main"'
run "empty quote before commit, then chained force-push" 2 'git commit -m x && git ""push --force origin main'
run "empty quote glued before a word is not a phantom" 0 'git ""status'
run "standalone empty arg then a plain commit" 0 'echo "" && git commit -m x'
run "bare \$x glued before the force flag"    2 'git push origin $x--force'
run "bare \$x glued before -f"               2 'git push origin $x-f'
run "bare \$x glued before --mirror"         2 'git push $x--mirror'
run "bare \$x glued before --no-verify"      2 'git commit $x--no-verify -m x'
run "bare \$x glued before -n"               2 'git commit -a $x-n -m x'
run "bare \$x then empty quote before --force" 2 'git push origin $x""--force'
run "bare \$x before a bash wrapper flag"    2 'bash $x-c "git push --force origin main"'
run "bare \$x in a normal push is allowed"   0 'git push origin $branch'
run "bare \$1 glued before --force"          2 'git push origin $1--force'
run "quoted \$x glued before --force"        2 'git push origin "$x--force"'
run "quoted \${x} glued before --force"      2 'git push origin "${x}--force"'
run "quoted \$x, two spans, before --force"  2 'git push origin "$x""--force"'
run "quoted \$x span then unquoted --force"  2 'git push origin "$x"--force'
run "quoted \$@ glued before --force"        2 'git push origin "$@--force"'
run "quoted \$x glued before -f"             2 'git push "$x-f" origin'
run "quoted \$x glued before --no-verify"    2 'git push "$x--no-verify"'
run "quoted \$x after -m ok before --no-verify" 2 'git commit -m ok "$x--no-verify"'
run "quoted \$x glued before -n"             2 'git commit "$x-n" -m ok'
run "quoted \${x} split-span bot author is refused (value from an expansion)" 2 'git commit --author="$x""Claude Bot <a@b.c>" -m x'
run "single-span quoted bot author is still caught" 2 'git commit --author="Claude Bot <a@b.c>" -m x'
run "quoted \$x normal refspec is allowed"   0 'git push origin "$branch"'
run "quoted \${x} prefix message is allowed" 0 'git commit -m "${x} done"'
run "quoted substitution message, no pathspec, dirty secret" 0 'git commit -m "$(date)"'
run "quoted \${x} message then pathspec, dirty secret" 2 'git commit -m "${x}" tracked.txt'
run "quoted \$x message then pathspec, dirty secret" 2 'git commit -m "$x" tracked.txt'
run "quoted \${x:-} default is a flag"       2 'git push origin "${x:---force}"'
run "unquoted \${x:-} default is a flag"     2 'git push origin ${x:---force}'
run "\${x:=} default is --no-verify"         2 'git commit "${x:=--no-verify}" -m x'
run "\${x=} default is a flag"               2 'git push origin ${x=--force}'
run "\${VERSION:-0.0.0} default is allowed"  0 'git commit -m "${VERSION:-0.0.0}"'
run "\${BRANCH:-main} default is allowed"    0 'git push origin "${BRANCH:-main}"'
run "\${x:-HEAD} default is allowed"         0 'git push origin ${x:-HEAD}'
run "\${#files} length is allowed"           0 'git commit -m "count ${#files}"'
run "\${x//a/b} replacement is allowed"      0 'git commit -m "${x//a/b}"'
run "\${HOME:+--force} alternate is a flag"   2 'git push origin "${HOME:+--force}"'
run "\${x:+-n} alternate is a flag"          2 'git commit -m ok "${x:+-n}"'
run "\${x+--force} bare alternate is a flag" 2 'git push origin ${x+--force}'
run "\${x:- space then flag} default is a flag" 2 'git push origin ${x:- --force}'
run "\${a[0]:---force} subscript default is a flag" 2 'git push origin "${a[0]:---force}"'
run "\${x:+value} alternate value is allowed" 0 'git commit -m "${x:+ready}"'
run "\${x/a/b} replacement is allowed (indirection limit)" 0 'git commit -m "${x/a/b}"'
run "\${x//-/_} dash-strip replacement is allowed" 0 'git commit -m "${x//-/_}"'
run "\${x:-a-b} hyphenated default value is allowed" 0 'git commit -m "${x:-a-b}"'
run "\${x:-\"--force\"} quoted default is a flag" 2 'git push origin ${x:-"--force"}'
run "\${x:-'"'"'--force'"'"'} single-quoted default is a flag" 2 'git push origin ${x:-'"'"'--force'"'"'}'
run "\${x:-\\-\\-force} backslashed default is a flag" 2 'git push origin ${x:-\-\-force}'
run "\${x:-\"0.0.0\"} quoted non-flag default is allowed" 0 'git commit -m "${x:-"0.0.0"}"'
run "\${x:-v1.0} versiony default is allowed"  0 'git commit -m "${x:-v1.0}"'
run "\${x:-+main} refspec default is force"   2 'git push origin ${x:-+main}'
run "\${x:-\"+main\"} quoted refspec default is force" 2 'git push origin ${x:-"+main"}'
run "\${x:-+HEAD:main} refspec default is force" 2 'git push origin ${x:-+HEAD:main}'
run "-c value from an expansion is refused"   2 'git -c ${x:-core.hooksPath=/tmp} commit -m x'
run "-c user.name from an expansion is refused" 2 'git -c ${x:-user.name=Claude} commit -m x'
run "user.name= value from an expansion is refused" 2 'git -c user.name=${x:-Claude} commit -m x'
run "GIT_AUTHOR_NAME from an expansion is refused" 2 'GIT_AUTHOR_NAME=${x:-Claude} git commit -m x'
run "GIT_COMMITTER_EMAIL from an expansion is refused" 2 'GIT_COMMITTER_EMAIL=${x} git commit -m x'
run "--author from an expansion is refused"   2 'git commit --author=${x:-Claude} -m x'
run "core.hooksPath from an expansion is refused" 2 'git -c core.hooksPath=$HOME commit -m x'
run "-c with a literal human name is allowed" 0 'git -c user.name="Dennis Vorobyov" commit -m x'
run "commit -c reuse-message sha is allowed"  0 'git commit -c abc1234 -m x'
run "message mentioning user.name in prose is allowed" 0 'git commit -m "note about user.name settings"'
run "hooksPath key split across a substitution" 2 'git -c c"$(printf ore.hooksPath=/tmp/h)" commit -m x'
run "user.name key split across a substitution" 2 'git -c u"$(printf ser.name=Claude)" commit -m x'
run "hooksPath key split across a brace default" 2 'git -c c"${x:-ore.hooksPath=/tmp/h}" commit -m x'
run "GIT_AUTHOR_NAME value split across a substitution" 2 'GIT_AUTHOR_NAME=C"$(printf laude)" git commit -m x'
run "GIT_COMMITTER_NAME value split across a substitution" 2 'GIT_COMMITTER_NAME=C"$(printf laude)" git commit -m x'
run "--author value split across a substitution" 2 'git commit --author=A"$(printf laude)" -m x'
run "--config value from a substitution"      2 'git --config c"$(printf ore.hooksPath=/tmp)" commit -m x'
run "user.email value from an expansion is refused" 2 'git -c user.email=${x:-bot@example.com} commit -m x'
run "prose message mentioning core.hooksPath= is allowed" 0 'git commit -m "docs: core.hooksPath=$HOME is risky"'
run "reuse-message commit -c with a variable sha is allowed" 0 'git commit -c ${sha} -m x'
run "reuse-message commit -C with a substitution sha is allowed" 0 'git commit -C "$(git rev-parse HEAD)" -m x'
run "git -C chdir from a variable is allowed"  0 'git -C "$repo" push origin main'
run "commit then chained push, reuse sha, allowed" 0 'git commit -c ${sha} -m x && git push origin main'
run "git config user.name to a bot then commit" 2 'git config user.name Claude && git commit -am x'
run "git config user.name quoted bot then commit" 2 'git config user.name "Claude" && git commit -m x'
run "git config user.name two-word bot then commit" 2 'git config user.name "Claude Bot" && git commit -m x'
run "git config --local user.name bot then commit" 2 'git config --local user.name Cursor && git commit -am x'
run "git config set user.name bot then commit" 2 'git config set user.name Claude && git commit -m x'
run "git config user.email bot then commit"   2 'git config user.email bot@anthropic.com && git commit -m x'
run "git config user.name github-actions then commit" 2 'git config user.name "github-actions" && git commit -m x'
run "case-mismatched -c User.Name from expansion" 2 'git -c User.Name=${x:-Claude} commit -m x'
run "git config user.name human then commit"  0 'git config user.name "Dennis Vorobyov" && git commit -m x'
run "git config core.editor then commit"      0 'git config core.editor vim && git commit -m x'
run "git config user.email human then commit" 0 'git config user.email denny@example.com && git commit -m x'
run "git config commit.gpgsign then commit"   0 'git config commit.gpgsign true && git commit -m x'
run "brace default carrying = is a config token" 2 'git commit --trailer ${x:-Acked-by=me} -m x'
run "git config user.name value from a substitution" 2 'git config user.name C"$(printf laude)" && git commit -m x'
run "git config user.name value from a bare var" 2 'git config user.name $BOT && git commit -m x'
run "git config user.name value from a brace default" 2 'git config user.name ${x:-Claude} && git commit -m x'
run "git config user.name split key then bot value" 2 'git config user.na"me" Claude && git commit -m x'
run "git config user.name value from a var, human intent, still refused" 2 'git config user.name "$USER" && git commit -m x'
run "git config core.editor from a var is allowed" 0 'git config core.editor $EDITOR && git commit -m x'
run "git config -f file user.name bot then commit" 2 'git config -f cfg user.name Claude && git commit -m x'
run "git config --file user.name bot then commit" 2 'git config --file cfg user.name Claude && git commit -m x'
run "git config -f file core.editor is allowed" 0 'git config -f cfg core.editor vim && git commit -m x'
run "git config --type=path user.name bot then commit" 2 'git config --type=path user.name Claude && git commit -m x'
run "git config --type=path user.email bot then commit" 2 'git config --type=path user.email bot@evil.com && git commit -m x'
run "git config --file= user.name value from a substitution" 2 'git config --file=cfg user.name C"$(printf laude)" && git commit -m x'
run "git config --file=.git/config core.editor is allowed" 0 'git config --file=.git/config core.editor vim && git commit -m x'
run "git config --replace-all user.name human is allowed" 0 'git config --replace-all user.name Dennis && git commit -m x'
run "heredoc marker before a substitution on the same line" 2 'cat <<EOF $(:
git push -f origin main
EOF
)'
run "heredoc marker before a backtick substitution" 2 'cat <<EOF `:
git push --force origin main
EOF
`'
run "legit heredoc message substitution still allowed" 0 'git commit -m "$(cat <<'"'"'EOF'"'"'
feat: x
EOF
)"'
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

printf '++ b/x aws_key=%s\n' "$AWS_KEY" >header.txt
git add header.txt
run "secret on a line shaped like a diff header" 2 'git commit -m "x"'
git rm -q --cached header.txt && rm header.txt

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
  PATH="$NOJQ" "$BASH" "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
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
  PATH="$NOAWK" "$BASH" "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
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
  PATH="$1" "$BASH" "$HOOK" <"$TMP/payload" >/dev/null 2>"$TMP/err"
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
