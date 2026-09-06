#!/usr/bin/env bash
# PreToolUse(Bash) — block AI attribution, secrets, force-push, and hook-skipping (--no-verify)
# before they happen. Exit 2 + a stderr reason is the documented blocking contract; stdout is unused.
#
# This is a backstop behind the settings.json deny rules and plan mode, not a sandbox. Known,
# accepted limits: variable indirection (`p=push; git $p -f`), git aliases defined in an earlier
# call, `git config core.hooksPath` set in an earlier call, flags fed through a pipe (`xargs`),
# and flags spelled with quoting tricks (`--no-veri"fy"`, `$'--no-verify'`, unique-prefix `--no-veri`).
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

# The payload mentions git commit/push, so an empty command here means the payload did not parse
# (or its shape changed). Fail closed rather than silently turning into a no-op.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$CMD" ]; then
  echo "Blocked: guard-commit.sh could not read .tool_input.command from the PreToolUse payload. Failing closed." >&2
  exit 2
fi

# Join backslash-newline continuations so a flag on its own line stays with its subcommand.
CMD=${CMD//\\$'\n'/ }

# Classify per command segment, not per Bash call: `git commit -m ok && git push -f` is a commit
# AND a force-push, and each segment is judged on its own. Data is stripped first so a commit
# MESSAGE or a file body that merely mentions `push --force` or `--no-verify` (or contains `;`)
# can't trip a flag check or split a segment. One quote model does all of it, a character walk
# that keeps its state across lines: single- and double-quoted spans (with \ escapes), `$(...)`
# and backtick substitutions that reopen code inside double quotes, `#` comments, and heredoc
# bodies (`cat > f <<'EOF' ... EOF`, `git commit -F - <<EOF ...`), which are data bash never
# runs. A `<<WORD` marker counts only in code, never inside a string or a comment: honoring one
# inside a string would let a real command hide behind a fake terminator line. Every divergence
# from bash is meant to err toward stripping LESS (a false block at worst), never more.
strip_data() {
  awk '
  BEGIN { q = 0; depth = 0; npend = 0; body = 0 }
  {
    line = $0
    if (body) {                                  # inside a heredoc body: drop lines up to the terminator
      t = line
      if (pdash[1]) sub(/^\t+/, "", t)
      tail = ""
      while (t ~ /\)$/) { t = substr(t, 1, length(t) - 1); tail = tail ")" }   # `EOF)` closes a $( too
      if (t != pword[1]) next
      for (k = 1; k < npend; k++) { pword[k] = pword[k + 1]; pdash[k] = pdash[k + 1] }
      npend--
      if (npend == 0) body = 0
      line = tail
    }
    n = split(line, c, "")
    o = ""
    i = 1
    while (i <= n) {
      ch = c[i]
      if (q == 1) { if (ch == "\047") q = 0; i++; continue }              # inside single quotes
      if (q == 2) {                                                        # inside double quotes
        if (ch == "\\") { i += 2; continue }
        if (ch == "\"") { q = 0; i++; continue }
        if (ch == "$" && c[i + 1] == "(") { kind[++depth] = "("; save[depth] = 2; q = 0; o = o " "; i += 2; continue }
        if (ch == "`") { kind[++depth] = "`"; save[depth] = 2; q = 0; o = o " "; i++; continue }
        i++; continue
      }
      if (ch == "\\") { o = o ch c[i + 1]; i += 2; continue }              # code from here on
      if (ch == "\047") { q = 1; i++; continue }
      if (ch == "\"") { q = 2; i++; continue }
      if (ch == "#" && (i == 1 || c[i - 1] ~ /[ \t;&|(]/)) break         # comment to end of line
      if (ch == "$" && c[i + 1] == "(") { kind[++depth] = "("; save[depth] = 0; o = o "$("; i += 2; continue }
      if (ch == "(") { kind[++depth] = "("; save[depth] = 0; o = o ch; i++; continue }
      if (ch == ")" && depth > 0 && kind[depth] == "(") { q = save[depth--]; o = o ch; i++; continue }
      if (ch == "`") {
        if (depth > 0 && kind[depth] == "`") q = save[depth--]; else { kind[++depth] = "`"; save[depth] = 0 }
        o = o " "; i++; continue
      }
      if (ch == "<" && c[i + 1] == "<" && c[i + 2] != "<" && (i == 1 || c[i - 1] != "<")) {
        j = i + 2; dash = 0
        if (c[j] == "-") { dash = 1; j++ }
        while (c[j] == " " || c[j] == "\t") j++
        w = ""
        while (j <= n && c[j] !~ /[ \t;&|<>()]/) { w = w c[j]; j++ }
        gsub(/[\047"\\]/, "", w)
        if (w != "") { pword[++npend] = w; pdash[npend] = dash }
        o = o "<<"; i = j; continue
      }
      o = o ch; i++
    }
    print o
    if (npend > 0) body = 1
  }'
}
STRIPPED=$(printf '%s' "$CMD" | strip_data)

# A shell wrapper runs its quoted argument as a command, which the strip above just hid.
# Refuse rather than guess: the unwrapped form is always available to the agent.
if printf '%s' "$STRIPPED" | grep -qE '(^|[^[:alnum:]_./-])((ba|z|da)?sh[[:space:]]+-[a-z]*c|eval)([^[:alnum:]_./-]|$)'; then
  echo "Blocked: git commit/push inside a shell wrapper (sh -c / bash -c / eval) cannot be inspected. Run the git command directly." >&2; exit 2
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
done <<<"$(printf '%s' "$STRIPPED" | tr ';&|' '\n')"

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
