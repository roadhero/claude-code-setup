#!/usr/bin/env bash
# Behavioral tests for hooks/bootstrap-claude-md.sh: a SessionStart payload on stdin,
# always exit 0, a nudge emitted ONLY when the repo is a git work tree (root != $HOME)
# with no root CLAUDE.md.  Usage: bash tests/hooks/test-bootstrap-claude-md.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../../hooks/bootstrap-claude-md.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check <name> <ok-flag: 0 = passed>
check() {
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

# feed <cwd> : run the hook with a SessionStart payload naming that cwd
feed() {
  jq -n --arg c "$1" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}' | bash "$HOOK" 2>/dev/null
}

# emitted <stdout> <rc> : 0 when it is a valid SessionStart nudge with non-empty context
emitted() {
  [ "$2" -eq 0 ] || return 1
  printf '%s' "$1" | jq -e '.hookSpecificOutput | .hookEventName == "SessionStart" and (.additionalContext | length > 0)' >/dev/null 2>&1
}

# silent <stdout> <rc> : 0 when nothing was emitted and exit was clean
silent() {
  [ "$2" -eq 0 ] && [ -z "$1" ]
}

# Fixtures: a git repo without CLAUDE.md, one with it, and a plain (non-git) dir.
REPO="$TMP/repo"; mkdir -p "$REPO"; git init -q "$REPO"
ROOT=$(git -C "$REPO" rev-parse --show-toplevel)   # canonical path (matches what the hook computes)
mkdir -p "$ROOT/sub"
REPO_OK="$TMP/repo_ok"; mkdir -p "$REPO_OK"; git init -q "$REPO_OK"
ROOT_OK=$(git -C "$REPO_OK" rev-parse --show-toplevel)
printf '# CLAUDE.md\n' >"$ROOT_OK/CLAUDE.md"
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"

# 1. git repo, no CLAUDE.md -> emits the nudge.
out=$(feed "$ROOT"); rc=$?
emitted "$out" "$rc"; check "missing CLAUDE.md in a git repo emits a nudge" $?

# 2. CLAUDE.md present at root -> silent.
out=$(feed "$ROOT_OK"); rc=$?
silent "$out" "$rc"; check "existing CLAUDE.md is silent" $?

# 3. non-git directory -> silent.
out=$(feed "$PLAIN"); rc=$?
silent "$out" "$rc"; check "non-git directory is silent" $?

# 4. work-tree root is $HOME -> silent even with no CLAUDE.md (never bootstrap the home dir).
out=$(jq -n --arg c "$ROOT" '{cwd:$c}' | HOME="$ROOT" bash "$HOOK" 2>/dev/null); rc=$?
silent "$out" "$rc"; check "repo root == \$HOME is silent" $?

# 5. cwd is a subdirectory -> resolves to the work-tree root and emits.
out=$(feed "$ROOT/sub"); rc=$?
emitted "$out" "$rc"; check "subdirectory resolves to root and emits" $?

# 6. empty payload -> falls back to \$PWD; a git repo without CLAUDE.md still emits.
out=$( cd "$ROOT" && printf '' | bash "$HOOK" 2>/dev/null ); rc=$?
emitted "$out" "$rc"; check "empty payload falls back to \$PWD and emits" $?

# 7. empty payload in a non-git dir -> silent (no crash on the fallback path).
out=$( cd "$PLAIN" && printf '' | bash "$HOOK" 2>/dev/null ); rc=$?
silent "$out" "$rc"; check "empty payload in a non-git dir is silent" $?

# 8. malformed JSON payload -> falls back to \$PWD, never crashes; non-git dir stays silent.
out=$( cd "$PLAIN" && printf 'not json at all' | bash "$HOOK" 2>/dev/null ); rc=$?
silent "$out" "$rc"; check "malformed payload does not crash and stays silent" $?

# 9. HOME unset -> fail-open (exit 0, still emits), never a set -u crash on the \$HOME guard.
out=$(jq -n --arg c "$ROOT" '{cwd:$c}' | env -u HOME bash "$HOOK" 2>/dev/null); rc=$?
emitted "$out" "$rc"; check "unset HOME fails open (no set -u crash)" $?

echo "bootstrap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
