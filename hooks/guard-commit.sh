#!/usr/bin/env bash
# PreToolUse(Bash) — block force-push, hook-skipping (--no-verify, core.hooksPath), shell wrappers
# around git, non-human committers, AI attribution, and staged secrets before they happen.
# Exit 2 + a stderr reason is the documented blocking contract; stdout is unused.
#
# Needs jq and git 2.28+ (for --no-relative and --output-indicator-new on the diff it reads).
#
# This is a backstop behind the settings.json deny rules and plan mode, not a sandbox. Known,
# accepted limits: variable indirection (`p=push; git $p -f`), git aliases defined in an earlier
# call, `git config core.hooksPath` set in an earlier call, flags fed through a pipe (`xargs`),
# unique-prefix long options (`--no-veri`), a word or flag spliced by any expansion or substitution
# (`git pu${x}sh`, `git pu$(echo s)h`, `--for$(echo c)e`), and the committer and secrets
# checks reading the current directory's repo (`git -C elsewhere commit`), a `filter.*.clean`
# set in an earlier call (it rewrites the working-tree diff the guard reads), a script body run
# by name (`bash run.sh`, `source ./run.sh`), and git run from another interpreter
# (`python3 -c "os.system('git push -f')"`, `perl -e`, `node -e`, awk's `system()`), whose
# program is data to this walk. Known false blocks (safe direction): a shell wrapper anywhere in
# the same call as a plain commit or push (`git commit -m x && bash -c "echo done"`,
# `bash -x build.sh && git commit -m x`, `which bash && git commit -m x`, `git add zsh bash fish`
# in a dotfiles repo), `source`/`.` of a process substitution, any mention of `alias.` outside quotes
# in the same call as a commit or push (`git config alias.st status; git commit`, `git commit -m x
# alias.md`), a substitution inside `${...}` (`${v:-$(git describe)}`), a one-word quoted argument
# that spells a flag or subcommand (`-m "--no-verify"`, `-m "eval"`, `tag -m "push" -f`), a quoted
# identity inside a message (`-m "set user.name='claude'"`), a `-n` or `-f` on another
# command inside the same `$(...)` as a commit or push (`-m "$(git log -1 | head -n 1)"`),
# `--force-if-includes` on its own, `-S<keyid>` with an
# `n` in the key id, an unquoted `*`, `?`, `[`, or `{a,b}` in a commit or push (bash expands it
# when the command runs; quote it, or list the files), an expansion between a shell and its
# option (`bash $a -c`: bash may see nothing there), git config passed through the environment in
# a commit or push call (`--config-env`, `GIT_CONFIG_*`, `include.path`, `HOME=`), a commit message
# mentioning `-c core.hooksPath` or an unquoted `include.path`/`HOME=`, a diff over 16 MB (commit
# large binaries separately, or via LFS), and an ANSI-C numeric escape (`$'\033[0m'`) in a call
# that also mentions git, commit, or push. A call whose every one of those words is itself
# numerically encoded (`$'\x67it' $'\x70ush'`) is the splice limit above.
#
# No `grep -q` ever reads from a pipe: it exits on the first match, and under pipefail the
# upstream writer's SIGPIPE would read as "no match". Checks read here-strings, and every grep
# treats an exit status over 1 as a tool failure that blocks.
export LC_ALL=C   # byte-oriented grep/awk/tr: an invalid UTF-8 byte must not make a tool drop the rest of the input
set -o pipefail   # a failing tool anywhere in a pipeline must surface, never read as "no match"
set -f            # no pathname expansion anywhere: the hook never globs, and an unquoted token must stay a token
INPUT=$(cat) || { echo "Blocked: guard-commit.sh could not read its stdin. Failing closed." >&2; exit 2; }

# has <ERE> <text> (case-insensitive) / hasc (case-sensitive): grep that treats any status over 1
# as a tool failure and fails closed, so a broken grep can never read as "no match".
has()  { grep -qiE -e "$1" <<<"$2"; local rc=$?; [ "$rc" -gt 1 ] && { echo "Blocked: guard-commit.sh grep failed. Failing closed." >&2; exit 2; }; return "$rc"; }
hasc() { grep -qE  -e "$1" <<<"$2"; local rc=$?; [ "$rc" -gt 1 ] && { echo "Blocked: guard-commit.sh grep failed. Failing closed." >&2; exit 2; }; return "$rc"; }

# Fast path: this guard only concerns `git commit` / `git push`. If the payload mentions
# neither, allow immediately — so a missing jq (below) never blocks unrelated Bash (ls/cat/grep).
# Match loosely (no quote-class): a quoted arg before the subcommand (`git -C "x" commit`)
# must NOT slip past into a silent allow. grep exit 1 = no match; anything else = error.
FLAT=$(tr '\n' ' ' <<<"$INPUT") || FLAT=$INPUT   # a pretty-printed payload must not split the match across lines
grep -qiE 'git.*(commit|push)' <<<"$FLAT"
RC=$?
if [ "$RC" -eq 1 ]; then
  # No plain mention. A split word (`g"it" push`, `git pu"sh"`, `git pus\h`, `git $'push'`,
  # `git pu\` + `sh`) could still be one: retry with quotes, backslashes, `$`, and JSON-escaped
  # continuations removed (sed: linear, ~25 ms on 400 KB; a bash substitution is quadratic on 3.2).
  # That only joins text, it can never destroy a real mention. An ANSI-C numeric escape
  # (`$'\x70ush'`) decodes to text no dequoting can reveal, so it goes to the walker, which refuses it.
  if ! J=$(sed -e 's/\\\\\\n//g' -e 's/\\"//g' -e "s/['\$\\\\]//g" <<<"$FLAT"); then
    echo "Blocked: guard-commit.sh could not run its fast-path check (sed failed). Failing closed." >&2; exit 2
  fi
  grep -qiE 'git.*(commit|push)' <<<"$J"
  RC=$?
  # Text no dequoting can reveal goes to the walker: an ANSI-C numeric escape (`$'\x70ush'`, the
  # walker refuses it) or a JSON \u escape for an ASCII letter (jq decodes it; the walker sees it).
  if [ "$RC" -eq 1 ] && has 'git|commit|push' "$J" && { hasc "\\\$'" "$FLAT" && hasc '\\\\[xuU0-7]' "$FLAT" || hasc '\\u00[0-9a-fA-F]{2}' "$FLAT"; }; then RC=0; fi
fi
case $RC in
  0) ;;
  1) exit 0 ;;
  *) echo "Blocked: guard-commit.sh could not run its fast-path check (grep failed). Failing closed." >&2; exit 2 ;;
esac

# The command plausibly commits/pushes — jq is needed to inspect it. Fail loud and closed.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: guard-commit.sh needs 'jq' to inspect a git commit/push but it is not installed (brew install jq). Failing closed." >&2
  exit 2
fi

# The payload mentions git commit/push, so an empty command here means the payload did not parse
# (or its shape changed). Fail closed rather than silently turning into a no-op.
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
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
#  - single-, double-, and ANSI-C ($'...') quoted spans, with \ escapes. A quoted span with no
#    whitespace, separator, newline, or substitution inside is glued back into its word, as bash
#    does (`pu"sh"` is `push`, `"-f"` is `-f`, `--no-veri"fy"` is `--no-verify`); anything else is
#    data. A numeric escape in $'...' decodes to text the walk cannot see, so it fails closed. A
#    backslash-newline in code joins the next line with nothing in between, so a word or flag
#    split across lines stays whole;
#  - `$(...)` and backticks reopen code inside double quotes and inside unquoted heredoc bodies
#    (bash expands them there: `cat <<EOF` + `$(git push -f)` runs the push); `<(...)` and `>(...)`
#    are words of the enclosing command, so separators inside them never split it;
#  - `$((...))`, `((...))`, `$[...]`, `${...}`, and `[...]` frames, where `<<` is a shift or
#    text and `#` is not a comment; an unbalanced `[` dies at the next command boundary;
#  - `#` comments to end of line, only where bash starts one: at the start of a word, which a
#    `)` closing `$(...)` or a closing backtick is not;
#  - `case ... esac`, counted only in command position: a pattern's `)` is a command boundary and
#    does not close an enclosing `$(...)`; a `)` that the top frame cannot close unwinds to the `(`
#    it does close;
#    a frame or quote still open at the end of the input fails closed;
#  - heredoc bodies, dropped line by line up to the terminator (`EOF)` also closes a `$(`,
#    `<<-` allows leading tabs, an unterminated body runs to end of input as in bash). A `<<WORD`
#    marker counts only in code, never inside a string, a comment, or arithmetic: honoring one
#    there would let a real command hide behind a fake terminator line. A body starts at the
#    newline that ends the command, and anything left open inside it dies with it.
# Every divergence from bash is meant to err toward stripping LESS (a false block at worst),
# never more. Where the walk would have to guess (a heredoc nested in a body, a marker inside a
# substitution that closes on its own line, a delimiter continued on the next line) it exits 3
# and the hook fails closed.
strip_data() {
  awk '
  # q: 0 code, 1 single quotes, 2 double quotes, 3 $'"'"'...'"'"', 4 unquoted heredoc body, 5 quoted heredoc body
  # kind[]: "(" subshell, "$(" substitution, "`", "<(" process substitution, "((" arithmetic command,
  #         "$((" arithmetic expansion, "(a" paren inside arithmetic, "[" test bracket, "[s" array
  #         subscript, "${" parameter expansion. save[]: the q to restore on pop.
  # A `${...}` is one word whose text bash may replace with nothing at all, so its interior is
  # dropped and a lone `$` stands for it (`${a[@]}` is `$`); a substitution inside it is refused.
  function push(k, sq) { kind[++depth] = k; save[depth] = sq; casec[depth] = 0; pendat[depth] = npend; pushnr[depth] = NR; pushpos[depth] = i; cmdpos = 1 }
  function pop() {
    if (npend > pendat[depth]) refuse("a heredoc marker inside a substitution that closes on the same line")
    # `name()` is a function definition: what follows is a command (`f() case ...`)
    cmdpos = (kind[depth] == "(" && pushnr[depth] == NR && substr(line, pushpos[depth], i - pushpos[depth] + 1) ~ /^\([ \t]*\)$/)
    q = save[depth]; poppedkind = kind[depth]; depth--; poppos = i
    if (q == 2) qbad = 1                         # the enclosing string held a substitution: never glue it
  }
  function refuse(why) { refused = 1; print "guard-commit.sh cannot classify this command: " why ". Rewrite it without that construct." > "/dev/stderr"; exit 3 }
  # a short quoted fragment is part of its word; a dropped span leaves an empty "" so the
  # argument still counts as one (`-m "two words" file` keeps `file` as the pathspec it is),
  # unless it held a substitution, whose own mark already stands there; an empty pair
  # (`commi""t`) is nothing, as in bash
  function closeq() { if (!qbad && qb != "" && qb !~ /[ \t;&|*?\[{()<>`]/) o = o qb; else if (!qbad && (qb != "" || qfresh)) o = o "\"\"" }
  function droptests() { while (depth > 0 && kind[depth] == "[") depth-- }   # a test bracket cannot span a command
  function insubst(   k) { for (k = depth; k > 0; k--) if (kind[k] == "$(" || kind[k] == "`" || kind[k] == "<(") return 1; return 0 }
  function inframe(   k) { for (k = depth; k > 0; k--) if (kind[k] != "(") return 1; return 0 }   # anything but a bare subshell
  function inbrace(   k) { for (k = depth; k > 0; k--) if (kind[k] == "${") return 1; return 0 }   # inside a `${...}` word
  function fresh() { return (o == "" || o ~ /[ \t]$/ || substr(o, length(o), 1) == "\001") }   # a quote at the start of a word
  function heredocbeforesubst(   k) { for (k = depth; k > 0; k--) if ((kind[k] == "$(" || kind[k] == "`" || kind[k] == "<(") && pendat[k] > 0) return 1; return 0 }
  BEGIN { q = 0; depth = 0; npend = 0; body = 0; cont = 0; casec[0] = 0; poppos = -1; poppedkind = ""; cmdpos = 1; kwlead = 0 }
  {
    line = $0
    if (index(line, "\001")) refuse("a control byte in the command")   # \001 is the walk'"'"'s own boundary mark
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
        if (npend == 0) { body = 0; q = 0 } else q = (pq[1] ? 5 : 4)
        line = rest
      } else if (q == 5) next                    # quoted-delimiter body: inert, drop the line
    }
    n = split(line, c, "")
    o = ""
    bmark = 0                                  # where the current `${...}` word began on this line
    i = 1
    poppos = -1
    joined = cont; cont = 0                    # this line continues the previous one: no word starts at column 1
    if (q == 0 && !joined) cmdpos = 1
    while (i <= n) {
      ch = c[i]
      if (q == 1) { if (ch == "\047") { q = 0; closeq() } else qb = qb ch; i++; continue }
      if (q == 3) {
        if (ch == "\\" && c[i + 1] ~ /[xuU0-7]/) refuse("a numeric escape (\\x, \\u, octal) inside $'"'"'...'"'"'")
        if (ch == "\\") { qb = qb c[i + 1]; i += 2; continue }
        if (ch == "\047") { q = 0; closeq() } else qb = qb ch
        i++; continue
      }
      if (q == 2 || q == 4) {                    # data that still expands substitutions
        if (ch == "\\") { if (q == 2) qb = qb c[i + 1]; i += 2; continue }
        if (q == 2 && ch == "\"") { q = 0; closeq(); i++; continue }
        if (inbrace() && ((ch == "$" && c[i + 1] == "(") || ch == "`")) refuse("a substitution inside ${...}")
        if (ch == "$" && c[i + 1] == "(" && c[i + 2] == "(") { qbad = 1; push("$((", q); q = 0; o = o " "; i += 3; continue }
        if (ch == "$" && c[i + 1] == "(") { qbad = 1; push("$(", q); q = 0; o = o "$( "; i += 2; continue }
        if (ch == "$" && c[i + 1] == "{") {
          if (c[i + 2] ~ /[ \t|]/) refuse("a ${ command; } substitution")
          outer = !inbrace(); qbad = 1; push("${", q); q = 0; o = o " $"; if (outer) bmark = length(o); i += 2; continue
        }
        if (ch == "`") { qbad = 1; push("`", q); q = 0; o = o " `"; i++; continue }
        if (q == 2) qb = qb ch
        i++; continue
      }
      top = (depth > 0) ? kind[depth] : ""
      noheredoc = (top == "((" || top == "$((" || top == "[" || top == "[s" || top == "$[" || top == "(a" || top == "${")
      if (ch == "\\") {                       # `\-f` is `-f`; an escaped separator is text, never a boundary
        if (i == n) { cont = 1; i++; continue }
        o = o ((c[i + 1] ~ /[;&|]/) ? " " : (c[i + 1] ~ /[*?\[{]/) ? "\"\"" : c[i + 1]); i += 2; continue
      }
      if (ch == "$" && c[i + 1] == "\047") { q = 3; qb = ""; qbad = 0; qfresh = fresh(); i += 2; continue }
      if (ch == "\047") { q = 1; qb = ""; qbad = 0; qfresh = fresh(); i++; continue }
      if (ch == "\"") { q = 2; qb = ""; qbad = 0; qfresh = fresh(); i++; continue }
      # a comment starts only where a word starts: after whitespace, a control operator, or the `)`
      # that ends a subshell or an `((...))` command. The `)` of `$(...)` / `$((...))` or a closing
      # backtick ends a word, and `#` after it is part of that word.
      if (ch == "#" && !noheredoc && ((i == 1 && !joined) || (i > 1 && c[i - 1] ~ /[ \t;&|(]/) || (c[i - 1] == ")" && poppos == i - 1 && (poppedkind == "(" || poppedkind == "((")))) break
      # `;` `&` `|` separate commands only in code; inside an expansion or arithmetic they are text
      # `&` in `2>&1` `>&` `&>` `<&-` and `|` in `>|` belong to a redirection operator, not a boundary
      if ((ch == "&" && (c[i - 1] == "<" || c[i - 1] == ">" || c[i + 1] == ">")) || (ch == "|" && c[i - 1] == ">")) { o = o " "; i++; continue }
      if (ch == ";" || ch == "&" || ch == "|") {
        if (top == "${" || top == "((" || top == "$((" || top == "(a" || top == "$[" || top == "[s") { o = o " "; i++; continue }
        # inside `$(...)` a separator ends a command OF THE SUBSTITUTION, never the enclosing one
        # (`git push origin "$(a | b)" --force` is one push): a space keeps the flag with its git
        if (insubst()) { droptests(); cmdpos = 1; o = o " "; i++; continue }
        droptests(); cmdpos = 1; o = o "\001"; i++; continue   # a REAL boundary: a byte no command contains
      }
      if (ch == "{" || ch == "!") { cmdpos = 1; o = o ch; i++; continue }
      if (inbrace() && ((ch == "$" && c[i + 1] == "(") || ch == "`")) refuse("a substitution inside ${...}")
      if (ch == "$" && c[i + 1] == "(" && c[i + 2] == "(") { push("$((", 0); o = o " "; i += 3; continue }
      if (ch == "$" && c[i + 1] == "[") { push("$[", 0); o = o " "; i += 2; continue }
      if (ch == "$" && c[i + 1] == "{") {                  # the `$` stands for the whole word, which may expand to nothing
        if (c[i + 2] ~ /[ \t|]/) refuse("a ${ command; } substitution")
        outer = !inbrace(); push("${", 0); o = o " $"; if (outer) bmark = length(o); i += 2; continue
      }
      if (ch == "$" && c[i + 1] == "(") { push("$(", 0); o = o "$( "; i += 2; continue }
      # `[` in code opens a test bracket; inside an expansion or arithmetic it is an array subscript
      # (`${a[1|2]}`), whose `|` and `&` are text, never a command boundary
      if (ch == "[" && top == "${") { o = o ch; i++; continue }   # text inside `${...}`, like `)`: `${x:-[}` is a value, not a subscript
      if (ch == "[") {
        if (noheredoc && top != "[") { push("[s", 0); o = o " " }
        else if (cmdpos) { push("[", 0); o = o " " }
        else if (c[i - 1] ~ /[A-Za-z0-9_]/) { push("[s", 0); o = o ch }   # `a[1<<2]=1`: a subscript, its `<<` a shift; kept visible as a pattern too
        else o = o ch                         # `-[n]` is a pattern bash expands when it runs
        i++; continue
      }
      if ((ch == "<" || ch == ">") && c[i + 1] == "(") { push("<(", 0); o = o ch " "; i += 2; continue }   # process substitution: a word
      if (ch == "(" && noheredoc && top != "${") { push("(a", 0); o = o " "; i++; continue }
      if (ch == "(" && c[i + 1] == "(") { push("((", 0); o = o " "; i += 2; continue }
      if (ch == "(") { push("(", 0); o = o "( "; i++; continue }
      if (ch == ")" && c[i + 1] == ")" && (top == "((" || top == "$((")) { pop(); poppos = i + 1; o = o " "; i += 2; continue }
      if (ch == ")" && top == "(a") { pop(); o = o " "; i++; continue }
      if (ch == "]" && (top == "[" || top == "[s" || top == "$[")) { pop(); o = o " "; i++; continue }
      if (ch == "}" && top == "${") { pop(); if (!inbrace()) o = substr(o, 1, bmark) " "; i++; continue }   # the word is its `$`
      if (ch == "}" && inbrace()) refuse("a `}` with a paren or bracket still open inside ${...}")   # the word must never outlive its `}`
      if (ch == ")" && inbrace()) { o = o ch; i++; continue }   # text inside `${...}`, like `;` `&` `|`
      if (ch == ")") {
        if (top == "[" || top == "[s") {         # a frame `)` cannot close: unwind to the `(` it does close
          while (depth > 0 && kind[depth] != "(" && kind[depth] != "$(" && kind[depth] != "<(" && kind[depth] != "`" && kind[depth] != "((" && kind[depth] != "$((") {
            if (save[depth]) refuse("a `)` that unwinds a frame opened inside a quoted string")
            depth--                            # drops [ [s $[ (a
          }
          top = (depth > 0) ? kind[depth] : ""
        }
        if (casec[depth] > 0) { droptests(); o = o ch (insubst() ? " " : "\001"); i++; cmdpos = 1; continue }   # a case pattern terminator ends the pattern, as `;;` ends the command
        if (top == "(" || top == "$(" || top == "<(") { pop(); o = o ch " "; i++; continue }
        o = o ch " "; i++; continue
      }
      if (ch == "`") {
        if (top == "`") { pop(); o = o "` " } else { push("`", 0); o = o " `" }   # the backticks mark a word that may expand to nothing
        i++; continue
      }
      if (ch == "<" && c[i + 1] == "<" && c[i + 2] != "<" && (i == 1 || c[i - 1] != "<") && !noheredoc) {
        j = i + 2; dash = 0
        if (c[j] == "-") { dash = 1; j++ }
        while (c[j] == " " || c[j] == "\t") j++
        w = ""; quoted = 0
        while (j <= n && c[j] !~ /[ \t;&|<>()]/) {
          if (c[j] == "$" && (c[j + 1] == "\047" || c[j + 1] == "\"")) j++   # a $-prefixed quoted delimiter is quoted too
          if (c[j] == "\047" || c[j] == "\"") {  # a quoted delimiter may contain anything up to its closing quote
            qc = c[j]; quoted = 1; j++
            while (j <= n && c[j] != qc) { w = w c[j]; j++ }
            j++; continue
          }
          if (c[j] == "\\") {
            if (j == n) refuse("a heredoc delimiter continued on the next line")
            quoted = 1; j++; w = w c[j]; j++; continue
          }
          w = w c[j]; j++
        }
        if (w != "") {
          if (body) refuse("a heredoc nested inside another heredoc body")
          if (npend >= 16) refuse("more than 16 heredocs pending at once")
          pword[++npend] = w; pdash[npend] = dash; pq[npend] = quoted
        }
        o = o "<<"; i = j; cmdpos = 0; continue
      }
      if (ch ~ /[A-Za-z_]/ && ((i == 1 && !joined) || (i > 1 && c[i - 1] !~ /[A-Za-z0-9_]/))) {   # a word: track case ... esac in command position
        j = i; w = ""
        while (j <= n && c[j] ~ /[A-Za-z0-9_]/) { w = w c[j]; j++ }
        if (cmdpos && w == "case") casec[depth]++
        else if (cmdpos && w == "esac" && casec[depth] > 0) casec[depth]--
        if (w == "if" || w == "then" || w == "else" || w == "elif" || w == "while" || w == "until" || w == "do") { cmdpos = 1; kwlead = 0 }
        else if (w == "time" || w == "coproc") { cmdpos = 1; kwlead = 2 }   # `time -p cmd`, `coproc NAME cmd`: the command may be two words on
        else if (kwlead > 0) kwlead--
        else cmdpos = 0
        o = o w; i = j; continue
      }
      if (ch != " " && ch != "\t" && kwlead == 0) cmdpos = 0
      o = o ch; i++
    }
    if (q == 1 || q == 2 || q == 3) qbad = 1    # a quoted span crossing a line is never glued
    if (q == 0 && !cont) droptests()
    # a body starts at the newline that ends the COMMAND (code state, no continuation), as in bash;
    # a `${...}` still open, or a `<<WORD` registered before a substitution opened on the line, means
    # the command has not ended where the walk would start the body: it will not guess, it refuses
    if (!body && npend > 0 && inbrace()) refuse("a heredoc marker on a line that ends inside ${...}")
    if (!body && npend > 0 && heredocbeforesubst()) refuse("a heredoc marker before a substitution that opens on the same line")
    enter = (!body && npend > 0 && q == 0 && !cont)
    # A newline separates commands in code at the top level or inside a bare subshell. Inside any
    # other frame it does not end the ENCLOSING command: in `$(...)` it separates commands of the
    # substitution (`-m "$(cat <<EOF ... )" --no-verify` is ONE command), in `${...}` / `$((...))`
    # / `$[...]` it is just whitespace; so there it becomes a space. Inside a quoted span or a body
    # line it is part of a word.
    if (inbrace()) o = substr(o, 1, bmark)      # a `${...}` word spanning lines: none of it reaches the output
    if (cont) printf "%s", o
    else if (q == 0 && !inframe()) print o
    else if (q == 0 || q == 4) printf "%s ", o
    else printf "%s", o
    if (enter) { body = 1; bodydepth = depth; q = (pq[1] ? 5 : 4) }
  }
  # A frame or quote still open at the end means bash would reject the whole input (or the walk
  # lost track of it, e.g. a `case` with no `esac`). Either way: refuse to guess.
  END { if (refused) exit 3; if (depth > 0 || q == 1 || q == 2 || q == 3) refuse("a quote, $(...), ((...)), ${...} or [ left open at the end (or a case with no esac)") }'
}
if ! STRIPPED=$(strip_data <<<"$CMD"); then
  echo "Blocked: guard-commit.sh could not parse the command (awk failed). Failing closed." >&2
  exit 2
fi


# Each segment costs a few greps; thousands of `;`-separated segments could outlast the hook
# timeout, and a timed-out PreToolUse hook does not block. No real command has hundreds.
# The walker marks every real command boundary with \001 (a `;` `&` `|` it emits as text is not one).
if ! SEGMENTS=$(tr '\001' '\n' <<<"$STRIPPED") || ! NSEP=$(tr -cd '\001\n' <<<"$STRIPPED" | wc -c) || ! [ "$NSEP" -eq "$NSEP" ] 2>/dev/null; then
  echo "Blocked: guard-commit.sh could not split the command into segments (tr/wc failed). Failing closed." >&2
  exit 2
fi
if [ "$NSEP" -gt 500 ]; then
  echo "Blocked: guard-commit.sh will not inspect a git commit/push command with over 500 segments. Split it up." >&2
  exit 2
fi

# A shell wrapper runs text as a command, and the strip above just hid that text. The rule, per
# segment of a call that commits or pushes: a shell (`sh`, `bash`, `zsh`, ... by name or path) is a
# wrapper when it is given leading options (`bash -c`, `bash -x script`, `bash -s`), when anything
# is redirected into it (`bash <<'EOF'`, `bash <<<"..."`, `bash < f`, `bash <(...)`), or when it has
# no arguments at all (`... | bash`, `bash` after `exec <`). A shell given a script path and the
# script's own arguments is not (`bash build.sh -c release`); the script body is a listed limit.
# `eval` and `trap` run text by definition; `source`/`.` of a process substitution reads text;
# `env -S` splits a string into a command. Refuse rather than guess: the unwrapped form, in its
# own call, is always available to the agent.
SHW='(^|[[:space:]()])([^[:space:]#!=]*/)?(ba|z|da|k|c|tc|fi|a|mk|ya)?sh[0-9]*'   # a shell, by name or path (`ksh93`, `bash5` too); `#!/bin/bash` and `x=/bin/sh` are not commands
RD='([[:space:]]*[0-9]*[<>]+[[:space:]]*[^[:space:]<>]*)*'                          # redirection words are not arguments
# shellcheck disable=SC2016  # the backtick is a literal in the pattern
XW='([[:space:]]+([^[:space:]]*[$`][^[:space:]]*|\$\(.*\)|`.*`))*'                   # words holding an expansion may be nothing at all (`bash $a -c`, `sh $(:) -c`)
ENVOPT='([[:space:]]+(-[uCPa][[:space:]]+[^[:space:]]+|--(unset|chdir|argv0)[[:space:]]+[^[:space:]]+|-[A-Za-z]*|--[A-Za-z-]+(=[^[:space:]]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[^[:space:]]*[$`][^[:space:]]*))*'
# every alternative supplies its own right boundary, so `shasum`, `shellcheck`, `bashful` never match
WRAPPER="${SHW}${RD}${XW}${RD}[[:space:]]*[)}]*[[:space:]]*\$|${SHW}${RD}${XW}${RD}[[:space:]]+-|${SHW}[[:space:]]*[0-9]*<|${SHW}[[:space:]].*<|(^|[[:space:]()])(eval|trap)([[:space:]]|\$)|(^|[[:space:]()])(source|\.)[[:space:]].*<|(^|[[:space:]()])env${ENVOPT}[[:space:]]+(-[A-Za-z]*S|--split-string)"

# An alias defined in the same call renames a subcommand out of reach of every check below
# (`git -c alias.fp=push fp --force`; the `-c` value is quoted data, so the raw command is read too).
if has '(^|[^[:alnum:]_])alias\.' "$STRIPPED" || has '-c[[:space:]]*["'"'"']?alias\.' "$CMD"; then
  echo "Blocked: a git alias defined in the same call as a commit/push cannot be inspected. Define it separately, or use the full subcommand." >&2; exit 2
fi

IS_COMMIT=""; HAS_PUSH=""; HAS_ADD=""; HAS_WORKTREE=""
while IFS= read -r SEG; do
  [ -z "$SEG" ] && continue
  if hasc "$WRAPPER" "$SEG"; then
    echo "Blocked: a shell wrapper (sh -c, bash <<EOF, ... | sh, eval, trap) in the same call as a git commit/push cannot be inspected. Run the git command directly, in its own call." >&2; exit 2
  fi
  SEG_COMMIT=""; SEG_PUSH=""
  has 'git.*[[:space:]]commit([^[:alnum:]]|$)' "$SEG" && SEG_COMMIT=1
  has 'git.*[[:space:]]push([^[:alnum:]]|$)' "$SEG" && SEG_PUSH=1
  has 'git.*[[:space:]]add([^[:alnum:]]|$)' "$SEG" && HAS_ADD=1
  # an unquoted `*`, `?`, `[`, or `{a,b}` is expanded by bash when the command runs, into words this
  # walk never sees (`-*` with a file named `--no-verify` in the directory; `--{force,}`)
  if [ -n "$SEG_COMMIT$SEG_PUSH" ] && hasc '[*?[]|\{[^[:space:]{}]*(,|\.\.)[^[:space:]{}]*\}' "$SEG"; then
    echo "Blocked: an unquoted *, ?, [, or {a,b} pattern in a git commit/push is expanded when it runs, so it cannot be inspected. Quote it, or list the files." >&2; exit 2
  fi
  # a commit with -a/-i/-o, or any bare token after the subcommand that is not the value of a
  # message-like option, commits working-tree content, not just the index: scan it
  if [ -n "$SEG_COMMIT" ]; then
    if hasc '[[:space:]]commit.*[[:space:]](-[A-Za-z]*[aiop][A-Za-z]*|--all|--include|--only|--patch|--interactive|--pathspec-from-file)([^[:alnum:]]|$)' "$SEG"; then HAS_WORKTREE=1; fi
    SEEN=""; WANT=""; SUB=0; BT=0
    for T in $SEG; do   # (unquoted on purpose: the walker removed every quote and set -f is on)
      if [ -n "$SEEN" ]; then
        # the words of a `$(...)` or `...` are the substitution's, never pathspecs (`-m "$(cat <<EOF ...)"`):
        # the words of the substitution are never pathspecs. A backtick opens/closes a span and glues
        # to its word, so count it by parity; a quoted backtick is already dropped by closeq, so the
        # only backticks here are real marks. `$(` is emitted standalone, so match it exactly (a
        # literal `x$(y` must NOT count); its `)` glues to a word, so match that by containment.
        case "$T" in *'`'*) B=${T//[!\`]/}; [ $((${#B} % 2)) -eq 1 ] && BT=$((1 - BT)); WANT=""; continue ;; esac
        [ "$BT" -eq 1 ] && continue
        # shellcheck disable=SC2016  # `$(` is a literal mark
        case "$T" in '$(') SUB=$((SUB + 1)); WANT=""; continue ;; esac
        if [ "$SUB" -gt 0 ]; then case "$T" in *')'*) SUB=$((SUB - 1)) ;; esac; continue; fi   # `)` glues to its word (`date)`)
        if [ -n "$WANT" ]; then WANT=""; continue; fi   # the value of the previous option, whatever its shape
        case "$T" in
          *[\<\>]*)                                  # a redirection glued to a word (`tracked.txt>log`, `2>`): the word stays an argument
            case "$T" in *[\<\>]) WANT=1 ;; esac    # the operator's target is the next token, not a pathspec
            P=${T%%[<>]*}
            case "$P" in ''|[0-9]*) continue ;; esac   # nothing, or a descriptor number, before the operator
            T=$P ;;
        esac
        case "$T" in
          -m|-F|-C|-c|-t|--message|--file|--author|--date|--trailer|--template|--fixup|--squash|--reedit-message|--reuse-message|--cleanup) WANT=1 ;;
          -S*) ;;                                      # `-S<keyid>`: the key is attached, nothing follows
          -[aiosvqnepz]*[mFCct]) WANT=1 ;;             # `-qm fix`: no-value flags then an option that takes the next word
          -*) ;;
          *) HAS_WORKTREE=1 ;;
        esac
      fi
      [ "$T" = commit ] && SEEN=1
    done
  fi
  [ -n "$SEG_COMMIT" ] && IS_COMMIT=1
  [ -n "$SEG_PUSH" ] && HAS_PUSH=1
  [ -z "$SEG_COMMIT$SEG_PUSH" ] && continue

  # force-push: --force / --force-with-lease / --mirror, -f alone or inside a flag cluster (-uf),
  # or a `+refspec` (the refspec form of --force). `--force-if-includes` alone is also caught;
  # it is a no-op without --force-with-lease, so nothing legitimate is lost.
  if [ -n "$SEG_PUSH" ] && { has '[[:space:]]push.*[[:space:]](--force-with-lease|--force|--mirror)([^[:alnum:]]|$)|[[:space:]]push.*[[:space:]]\+[^[:space:]]' "$SEG" || hasc '[[:space:]]push.*[[:space:]]-[A-Za-z]*f[A-Za-z]*([^[:alnum:]]|$)' "$SEG"; }; then
    echo "Blocked: force-push. Protected-branch discipline (CLAUDE.md §9)." >&2; exit 2
  fi

  # --no-verify skips the pre-commit / pre-push hooks the repo installed on purpose (CLAUDE.md §14),
  # as does `git commit -n` (the short form, alone or in a cluster like -anm). Fix the hook failure instead.
  if has '[[:space:]]--no-verify([^[:alnum:]-]|$)' "$SEG"; then
    echo "Blocked: --no-verify bypasses the repo's git hooks (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
  if [ -n "$SEG_COMMIT" ] && has '[[:space:]]commit.*[[:space:]]-[A-Za-z]*n[A-Za-z]*([^[:alnum:]]|$)' "$SEG"; then
    echo "Blocked: git commit -n is --no-verify (CLAUDE.md §14). Fix the hook failure instead." >&2; exit 2
  fi
done <<<"$SEGMENTS"

[ -z "$IS_COMMIT$HAS_PUSH" ] && exit 0

# git can take config from the environment (`--config-env`, `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`,
# `GIT_CONFIG_PARAMETERS`), where the key or the value is out of every check's sight: refuse.
if has '--config-env|GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+|PARAMETERS|GLOBAL|SYSTEM)=|include\.path=|includeIf\.|(^|[[:space:]])HOME=' "$STRIPPED"; then
  echo "Blocked: git config from the environment or an unreadable file (--config-env, GIT_CONFIG_*, include.path, HOME) in the same call as a commit/push cannot be inspected. Set it with -c or in the repo config." >&2; exit 2
fi
# Re-pointing core.hooksPath anywhere in the same call (`git -c core.hooksPath=x commit`,
# `git config core.hooksPath x; git commit`) is the same bypass as --no-verify.
# (checked on the raw command as well: a quoted value with a space in it is stripped as data)
if has 'core\.hooksPath' "$STRIPPED" || has '(-c[[:space:]]*["'"'"']?core\.hooksPath|config[^;&|]*core\.hooksPath)' "$CMD"; then
  echo "Blocked: core.hooksPath override bypasses the repo's git hooks (CLAUDE.md §14)." >&2; exit 2
fi

# only inspect commit operations further
[ -z "$IS_COMMIT" ] && exit 0

# committer must be a human — match whole tokens / known bot identities, not substrings.
# The identity is the repo config, or an override on the command itself (`-c user.name=`,
# `GIT_COMMITTER_NAME=`, `GIT_AUTHOR_NAME=`, `--author`); the override's value runs to its closing
# quote, or to the end of the line when it is unquoted.
IDENT='(claude|chatgpt|copilot|cursor|cursoragent|github-actions|assistant|bot|ai[-_ ]?(agent|assistant|bot))'
NAME=$(git config user.name 2>/dev/null || echo "")
if has "(^|[^[:alnum:]])${IDENT}[0-9]*([^[:alnum:]]|\$)" "$NAME"; then
  SAFE_NAME=$(tr -d '\n\r' <<<"$NAME" | cut -c1-40)   # repo-controlled text: one line, short, before it reaches the model
  echo "Blocked: git user.name '$SAFE_NAME' is not a human (CLAUDE.md §2)." >&2; exit 2
fi
# The stripped text has the unquoted forms with every quote splice undone (`user.name=Cla'ude'`); the
# raw text has the quoted values (`--author="Claude Bot <...>"`), whose closing quote bounds them.
if has "(user\.name=|GIT_(AUTHOR|COMMITTER)_NAME=|--author[= ])([^[:space:]]*[^[:alnum:][:space:]])?${IDENT}[0-9]*([^[:alnum:]]|\$)" "$STRIPPED" ||
   has "(user\.name=|GIT_(AUTHOR|COMMITTER)_NAME=|--author[= ])[\"']([^\"']*[^[:alnum:]\"'])?${IDENT}[0-9]*([^[:alnum:]]|\$)" "$CMD" ||
   has "[\"'](user\.name=|GIT_(AUTHOR|COMMITTER)_NAME=|--author=)([^\"']*[^[:alnum:]\"'])?${IDENT}[0-9]*([^[:alnum:]]|\$)" "$CMD"; then
  echo "Blocked: the commit sets a committer or author that is not a human (CLAUDE.md §2)." >&2; exit 2
fi

# no AI attribution in the commit message — scan the command only, not the staged diff.
# (This is a repo *about* Claude Code; legit messages will say "Claude Code". Only
#  attribution-SHAPED phrases are blocked, not bare mentions of a tool.)
if has 'co-authored-by:.*(claude|gpt|copilot|cursor)|generated with (claude|chatgpt|copilot|ai)|🤖|AI[- ](assisted|generated)' "$CMD"; then
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
# Repo config must not reshape what the guard reads: no external diff, no textconv, no color,
# no relative paths, and binary-looking content (a `-diff` attribute, a NUL byte) still as text.
# Added lines are marked `>` by git itself (--output-indicator-new), so a content line that merely
# looks like a `+++ b/file` header cannot be mistaken for one.
GIT_DIFF=(git -c core.fsmonitor=false diff --no-ext-diff --no-textconv --no-color --no-relative --text --output-indicator-new='>')
gitfail() { echo "Blocked: guard-commit.sh could not read the diff ($1 failed). Failing closed." >&2; exit 2; }
DIFF=$("${GIT_DIFF[@]}" --cached 2>/dev/null -- "${EXCL[@]}") || gitfail "git diff --cached"
if [ -n "$HAS_ADD$HAS_WORKTREE" ]; then
  WT=$("${GIT_DIFF[@]}" 2>/dev/null -- "${EXCL[@]}") || gitfail "git diff"
  DIFF="$DIFF"$'\n'"$WT"
fi
if [ -n "$HAS_ADD" ]; then
  # (a plain function, not `case` inside $(...): bash 3.2 cannot parse the `)` of a case pattern there)
  # NUL-separated paths so a newline in a filename cannot hide a file; a grep failure marks the scan.
  scan_untracked() {
    git ls-files -z --others --exclude-standard 2>/dev/null | while IFS= read -r -d '' f; do
      case "$f" in *.example|*.sample|*.dist|*.tmpl) continue ;; esac   # (a whole-name match: a newline in the name cannot fool it)
      [ -L "$f" ] && continue                # git stores a symlink's target text, never the target
      [ -f "$f" ] || continue
      grep -saE -i -e "$SECRETS" -- "$f" | sed 's/^/>/'   # -a: a NUL byte must not make grep skip the file
      [ "${PIPESTATUS[0]}" -gt 1 ] && printf '>GUARD_SCAN_FAILED %s\n' "$f"
    done
    [ "${PIPESTATUS[0]}" -eq 0 ] || printf '>GUARD_SCAN_FAILED ls-files\n'
  }
  UT=$(scan_untracked)
  if hasc '^>GUARD_SCAN_FAILED' "$UT"; then gitfail "scanning an untracked file"; fi
  DIFF="$DIFF"$'\n'"$UT"
fi
if [ ${#DIFF} -gt 16777216 ]; then
  echo "Blocked: guard-commit.sh will not scan a diff over 16 MB for secrets. Commit large binaries separately (or via LFS)." >&2; exit 2
fi
# Only ADDED lines (`>`) count: removing a leaked secret from a file must stay committable
# (§11: rotate, then scrub). One grep, no `-q`, so it reads everything; 1 = clean.
grep -iE -e "^>.*($SECRETS)" <<<"$DIFF" >/dev/null
case $? in
  0) echo "Blocked: a secret appears to be staged (CLAUDE.md §11). Unstage it." >&2; exit 2 ;;
  1) ;;
  *) echo "Blocked: guard-commit.sh could not scan the staged diff for secrets (grep failed). Failing closed." >&2; exit 2 ;;
esac
exit 0
