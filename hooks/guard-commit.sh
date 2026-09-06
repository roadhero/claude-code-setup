#!/usr/bin/env bash
# PreToolUse(Bash) — block AI attribution, secrets, force-push, and hook-skipping (--no-verify)
# before they happen. Exit 2 + a stderr reason is the documented blocking contract; stdout is unused.
#
# This is a backstop behind the settings.json deny rules and plan mode, not a sandbox. Known,
# accepted limits: variable indirection (`p=push; git $p -f`), git aliases defined in an earlier
# call, `git config core.hooksPath` set in an earlier call, flags fed through a pipe (`xargs`),
# and flags spelled with quoting tricks (`--no-veri"fy"`, `$'--no-verify'`, unique-prefix `--no-veri`).
export LC_ALL=C   # byte-oriented grep/awk/tr: an invalid UTF-8 byte must not make a tool drop the rest of the input
set -o pipefail   # a failing tool anywhere in a pipeline must surface, never read as "no match"
INPUT=$(cat)

# Fast path: this guard only concerns `git commit` / `git push`. If the payload mentions
# neither, allow immediately — so a missing jq (below) never blocks unrelated Bash (ls/cat/grep).
# Match loosely (no quote-class): a quoted arg before the subcommand (`git -C "x" commit`)
# must NOT slip past into a silent allow. JSON-escaped backslash-newlines (`git pu\` + `sh`) are
# joined first so a split word cannot dodge the match. grep exit 1 = no match; anything else = error.
printf '%s' "$INPUT" | sed 's/\\\\\\n//g' | grep -qiE 'git.*(commit|push)'
case $? in
  0) ;;
  1) exit 0 ;;
  *) echo "Blocked: guard-commit.sh could not run its fast-path check (sed/grep failed). Failing closed." >&2; exit 2 ;;
esac

# The command plausibly commits/pushes — jq is needed to inspect it. Fail loud and closed.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: guard-commit.sh needs 'jq' to inspect a git commit/push but it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

# The payload mentions git commit/push, so an empty command here means the payload did not parse
# (or its shape changed). Fail closed rather than silently turning into a no-op.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$CMD" ]; then
  echo "Blocked: guard-commit.sh could not read .tool_input.command from the PreToolUse payload. Failing closed." >&2
  exit 2
fi

# No agent-realistic command is this long; past this size the character walk below gets slow, so
# stop here (the per-segment loop further down has its own cap for the same reason).
if [ ${#CMD} -gt 262144 ]; then
  echo "Blocked: guard-commit.sh will not inspect a git commit/push command over 256 KB. Split it up." >&2
  exit 2
fi

# Classify per command segment, not per Bash call: `git commit -m ok && git push -f` is a commit
# AND a force-push, and each segment is judged on its own. Data is stripped first so a commit
# MESSAGE or a file body that merely mentions `push --force` or `--no-verify` (or contains `;`)
# can't trip a flag check or split a segment. One quote model does all of it, a character walk
# that keeps its state across lines:
#  - single-, double-, and ANSI-C ($'...') quoted spans, with \ escapes; a backslash-newline in
#    code joins the next line with nothing in between, as bash does, so a flag on its own line
#    (or a word split across lines) stays with its subcommand;
#  - `$(...)` and backticks reopen code inside double quotes and inside unquoted heredoc bodies
#    (bash expands them there: `cat <<EOF` + `$(git push -f)` runs the push);
#  - `$((...))`, `((...))`, `$[...]`, `${...}`, and `[...]` frames, where `<<` is a shift or
#    text, not a heredoc;
#  - `#` comments to end of line, only where bash starts one: at the start of a word, which a
#    `)` closing `$(...)` or a closing backtick is not;
#  - `case ... esac`: a pattern's `)` does not close an enclosing `$(...)`;
#  - heredoc bodies, dropped line by line up to the terminator (`EOF)` also closes a `$(`,
#    `<<-` allows leading tabs, an unterminated body runs to end of input as in bash). A `<<WORD`
#    marker counts only in code, never inside a string, a comment, or arithmetic: honoring one
#    there would let a real command hide behind a fake terminator line.
# Every divergence from bash is meant to err toward stripping LESS (a false block at worst),
# never more. If the walk itself fails, the hook fails closed (pipefail below).
strip_data() {
  awk '
  # q: 0 code, 1 single quotes, 2 double quotes, 3 $'"'"'...'"'"', 4 unquoted heredoc body, 5 quoted heredoc body
  # kind[]: "(" subshell, "$(" substitution, "`", "((" arithmetic, "(a" paren inside arithmetic,
  #         "[" subscript/test, "${" parameter expansion. save[]: the q to restore on pop.
  function push(k, sq) { kind[++depth] = k; save[depth] = sq; casec[depth] = 0; pendat[depth] = npend }
  function pop() {
    if (npend > pendat[depth]) exit 3            # a marker inside a substitution closed on its own line: refuse to guess
    q = save[depth]; poppedkind = kind[depth]; depth--; poppos = i
  }
  BEGIN { q = 0; depth = 0; npend = 0; body = 0; cont = 0; casec[0] = 0; poppos = -1; poppedkind = "" }
  {
    line = $0
    if (body) {
      t = line
      if (pdash[1]) sub(/^\t+/, "", t)
      w1 = pword[1]; rest = ""; term = 0
      if (t == w1) term = 1
      else if (depth > 0 && substr(t, 1, length(w1) + 1) == w1 ")") { term = 1; rest = substr(t, length(w1) + 1) }   # `EOF)...` closes a $( too
      if (term) {                                # terminator: leave this body, walk the rest of the line as code
        for (k = 1; k < npend; k++) { pword[k] = pword[k + 1]; pdash[k] = pdash[k + 1]; pq[k] = pq[k + 1] }
        npend--
        depth = bodydepth                        # anything left open inside the body dies with it, as in bash
        if (npend == 0) { body = 0; q = bodyq } else q = (pq[1] ? 5 : 4)
        line = rest
      } else if (q == 5) next                    # quoted-delimiter body: inert, drop the line
    }
    n = split(line, c, "")
    o = ""
    i = 1
    poppos = -1
    while (i <= n) {
      ch = c[i]
      if (q == 1) { if (ch == "\047") q = 0; i++; continue }
      if (q == 3) { if (ch == "\\") { i += 2; continue } if (ch == "\047") q = 0; i++; continue }
      if (q == 2 || q == 4) {                    # data that still expands substitutions
        if (ch == "\\") { i += 2; continue }
        if (q == 2 && ch == "\"") { q = 0; i++; continue }
        if (ch == "$" && c[i + 1] == "(" && c[i + 2] == "(") { push("((", q); q = 0; o = o " "; i += 3; continue }
        if (ch == "$" && c[i + 1] == "(") { push("$(", q); q = 0; o = o "$("; i += 2; continue }
        if (ch == "$" && c[i + 1] == "{") { push("${", q); q = 0; o = o " "; i += 2; continue }
        if (ch == "`") { push("`", q); q = 0; o = o " "; i++; continue }
        i++; continue
      }
      top = (depth > 0) ? kind[depth] : ""
      noheredoc = (top == "((" || top == "[" || top == "(a" || top == "${")
      if (ch == "\\") { if (i == n) { cont = 1; i++; continue } o = o c[i + 1]; i += 2; continue }   # `\-f` is `-f`
      if (ch == "$" && c[i + 1] == "\047") { q = 3; i += 2; continue }
      if (ch == "\047") { q = 1; i++; continue }
      if (ch == "\"") { q = 2; i++; continue }
      # a comment starts only where a word starts: after whitespace, a control operator, or the `)`
      # of a subshell. The `)` of `$(...)`, a closing backtick, or `))` end a word, not a command.
      if (ch == "#" && (i == 1 || c[i - 1] ~ /[ \t;&|(]/ || (c[i - 1] == ")" && poppos == i - 1 && poppedkind == "("))) break
      if (ch == "$" && c[i + 1] == "(" && c[i + 2] == "(") { push("((", 0); o = o " "; i += 3; continue }
      if (ch == "$" && c[i + 1] == "[") { push("[", 0); o = o " "; i += 2; continue }
      if (ch == "$" && c[i + 1] == "{") { push("${", 0); o = o " "; i += 2; continue }
      if (ch == "$" && c[i + 1] == "(") { push("$(", 0); o = o "$("; i += 2; continue }
      if (ch == "[") { push("[", 0); o = o " "; i++; continue }
      if (ch == "(" && noheredoc && top != "${") { push("(a", 0); o = o " "; i++; continue }
      if (ch == "(" && c[i + 1] == "(") { push("((", 0); o = o " "; i += 2; continue }
      if (ch == "(") { push("(", 0); o = o ch; i++; continue }
      if (ch == ")" && c[i + 1] == ")" && top == "((") { pop(); o = o " "; i += 2; continue }
      if (ch == ")" && top == "(a") { pop(); o = o " "; i++; continue }
      if (ch == "]" && top == "[") { pop(); o = o " "; i++; continue }
      if (ch == "}" && top == "${") { pop(); o = o " "; i++; continue }
      if (ch == ")" && casec[depth] > 0) { o = o ch; i++; continue }         # a case pattern terminator
      if (ch == ")" && (top == "(" || top == "$(")) { pop(); o = o ch; i++; continue }
      if (ch == "`") {
        if (top == "`") pop(); else push("`", 0)
        o = o " "; i++; continue
      }
      if (ch == "<" && c[i + 1] == "<" && c[i + 2] != "<" && (i == 1 || c[i - 1] != "<") && !noheredoc) {
        j = i + 2; dash = 0
        if (c[j] == "-") { dash = 1; j++ }
        while (c[j] == " " || c[j] == "\t") j++
        w = ""; quoted = 0
        while (j <= n && c[j] !~ /[ \t;&|<>()]/) {
          if (c[j] == "\047" || c[j] == "\"") {  # a quoted delimiter may contain anything up to its closing quote
            qc = c[j]; quoted = 1; j++
            while (j <= n && c[j] != qc) { w = w c[j]; j++ }
            j++; continue
          }
          if (c[j] == "\\") {
            if (j == n) exit 3                   # a delimiter continued on the next line: refuse to guess
            quoted = 1; j++; w = w c[j]; j++; continue
          }
          w = w c[j]; j++
        }
        if (w != "") {
          if (body) exit 3                       # a heredoc nested inside another body: refuse to guess
          pword[++npend] = w; pdash[npend] = dash; pq[npend] = quoted
        }
        o = o "<<"; i = j; continue
      }
      if (ch ~ /[A-Za-z_]/ && (i == 1 || c[i - 1] !~ /[A-Za-z0-9_]/)) {   # a word: track case ... esac
        j = i; w = ""
        while (j <= n && c[j] ~ /[A-Za-z0-9_]/) { w = w c[j]; j++ }
        if (w == "case") casec[depth]++
        else if (w == "esac" && casec[depth] > 0) casec[depth]--
        o = o w; i = j; continue
      }
      o = o ch; i++
    }
    # a body starts at the newline that ends the COMMAND (code state, no continuation), as in bash
    enter = (!body && npend > 0 && q == 0 && !cont)
    if (cont) { printf "%s", o; cont = 0 } else print o
    if (enter) { body = 1; bodyq = q; bodydepth = depth; q = (pq[1] ? 5 : 4) }
  }'
}
if ! STRIPPED=$(printf '%s' "$CMD" | strip_data); then
  echo "Blocked: guard-commit.sh could not parse the command (awk failed). Failing closed." >&2
  exit 2
fi

# A shell wrapper runs its quoted argument as a command, which the strip above just hid.
# Refuse rather than guess: the unwrapped form is always available to the agent.
if printf '%s' "$STRIPPED" | grep -qE '(^|[^[:alnum:]_./-])((ba|z|da)?sh[[:space:]]+-[a-z]*c|eval)([^[:alnum:]_./-]|$)'; then
  echo "Blocked: git commit/push inside a shell wrapper (sh -c / bash -c / eval) cannot be inspected. Run the git command directly." >&2; exit 2
fi

# Each segment costs a few greps; thousands of `;`-separated segments could outlast the hook
# timeout, and a timed-out PreToolUse hook does not block. No real command has hundreds.
SEGMENTS=$(printf '%s' "$STRIPPED" | tr ';&|' '\n')
if [ "$(printf '%s' "$STRIPPED" | tr -cd ';&|\n' | wc -c)" -gt 500 ]; then
  echo "Blocked: guard-commit.sh will not inspect a git commit/push command with over 500 segments. Split it up." >&2
  exit 2
fi

IS_COMMIT=""; HAS_PUSH=""; HAS_ADD=""
while IFS= read -r SEG; do
  [ -z "$SEG" ] && continue
  SEG_COMMIT=""; SEG_PUSH=""
  printf '%s' "$SEG" | grep -qiE 'git.*[[:space:]]commit([^[:alnum:]]|$)' && SEG_COMMIT=1
  printf '%s' "$SEG" | grep -qiE 'git.*[[:space:]]push([^[:alnum:]]|$)' && SEG_PUSH=1
  printf '%s' "$SEG" | grep -qiE 'git.*[[:space:]]add([^[:alnum:]]|$)' && HAS_ADD=1
  [ -n "$SEG_COMMIT" ] && IS_COMMIT=1
  [ -n "$SEG_PUSH" ] && HAS_PUSH=1
  [ -z "$SEG_COMMIT$SEG_PUSH" ] && continue

  # force-push: --force / --force-with-lease / --mirror, -f alone or inside a flag cluster (-uf),
  # or a `+refspec` (the refspec form of --force). `--force-if-includes` alone is also caught;
  # it is a no-op without --force-with-lease, so nothing legitimate is lost.
  if [ -n "$SEG_PUSH" ] && printf '%s' "$SEG" | grep -qiE '[[:space:]]push.*[[:space:]](--force-with-lease|--force|--mirror)([^[:alnum:]]|$)|[[:space:]]push.*[[:space:]]-[A-Za-z]*f[A-Za-z]*([^[:alnum:]]|$)|[[:space:]]push.*[[:space:]]\+[^[:space:]]'; then
    echo "Blocked: force-push. Protected-branch discipline (CLAUDE.md §9)." >&2; exit 2
  fi

  # --no-verify skips the pre-commit / pre-push hooks the repo installed on purpose (CLAUDE.md §14),
  # as does `git commit -n` (the short form, alone or in a cluster like -anm). Fix the hook failure instead.
  if printf '%s' "$SEG" | grep -qiE '[[:space:]]--no-verify([^[:alnum:]-]|$)'; then
    echo "Blocked: --no-verify bypasses the repo's git hooks (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
  if [ -n "$SEG_COMMIT" ] && printf '%s' "$SEG" | grep -qiE '[[:space:]]commit.*[[:space:]]-[A-Za-z]*n[A-Za-z]*([^[:alnum:]]|$)'; then
    echo "Blocked: git commit -n is --no-verify (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
done <<<"$SEGMENTS"

[ -z "$IS_COMMIT$HAS_PUSH" ] && exit 0

# Re-pointing core.hooksPath anywhere in the same call (`git -c core.hooksPath=x commit`,
# `git config core.hooksPath x; git commit`, GIT_CONFIG_PARAMETERS=...) is the same bypass.
if printf '%s' "$STRIPPED" | grep -qiE 'core\.hooksPath|GIT_CONFIG_(PARAMETERS|COUNT|KEY_)'; then
  echo "Blocked: core.hooksPath override bypasses the repo's git hooks (CLAUDE.md §14)." >&2; exit 2
fi

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

# no obvious secrets. Scan the staged diff. For `git commit -a/--all` (which auto-stages tracked
# edits AFTER this hook runs) also scan the working-tree diff, and for `git add ... && git commit`
# in one call (the add has not happened yet either) also scan the working tree and untracked files.
SECRETS='(api[_-]?key|secret[_-]?key|access[_-]?key|private[_-]?key|password|token|bearer )[^=]*[=:] *["'"'"']?[A-Za-z0-9/_+-]{16,}|BEGIN [A-Z0-9 ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[0-9A-Za-z-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
# Exempt example/sample files — they're meant to hold placeholder values and are
# explicitly whitelisted for commit (e.g. `!.env.example` in the scaffolder .gitignore).
EXCL=(':(exclude)*.example' ':(exclude)*.sample' ':(exclude)*.dist' ':(exclude)*.tmpl')
# `--no-ext-diff` and `core.fsmonitor=false` so a repo-local config cannot make the guard run a program.
GIT_DIFF=(git -c core.fsmonitor=false diff --no-ext-diff)
DIFF=$("${GIT_DIFF[@]}" --cached 2>/dev/null -- "${EXCL[@]}")
if [ -n "$HAS_ADD" ] || printf '%s' "$STRIPPED" | grep -qiE '[[:space:]](--all|-[A-Za-z]*a[A-Za-z]*)([[:space:]]|$)'; then
  DIFF="$DIFF"$'\n'"$("${GIT_DIFF[@]}" 2>/dev/null -- "${EXCL[@]}")"
fi
if [ -n "$HAS_ADD" ]; then
  # (a plain function, not `case` inside $(...): bash 3.2 cannot parse the `)` of a case pattern there)
  scan_untracked() {
    git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
      printf '%s' "$f" | grep -qE '\.(example|sample|dist|tmpl)$' && continue
      grep -sIE "$SECRETS" -- "$f" | sed 's/^/+/'
    done
  }
  DIFF="$DIFF"$'\n'"$(scan_untracked)"
fi
# Only ADDED lines count: removing a leaked secret from a file must stay committable (§11: rotate, then scrub).
if printf '%s' "$DIFF" | grep '^+' | grep -v '^+++' | grep -qiE "$SECRETS"; then
  echo "Blocked: a secret appears to be staged (CLAUDE.md §11). Unstage it." >&2; exit 2
fi
exit 0
