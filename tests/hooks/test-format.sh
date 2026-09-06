#!/usr/bin/env bash
# Smoke tests for hooks/format.sh: a PostToolUse(Edit|Write) payload on stdin, always exit 0,
# only the tool's own target file is ever touched.  Usage: bash tests/hooks/test-format.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../../hooks/format.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check <name> <ok-flag: 0 = passed>
check() {
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

# run_hook <file_path> : feed a PostToolUse payload naming that path
run_hook() {
  printf '%s' "{\"tool_input\":{\"file_path\":\"$1\"}}" | bash "$HOOK" >/dev/null 2>&1
}

# 1. Empty payload: exit 0, nothing happens.
printf '' | bash "$HOOK" >/dev/null 2>&1
check "empty payload exits 0" $?

# 2. Nonexistent path: exit 0, file is not created.
run_hook "$TMP/missing.md"; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ ! -e "$TMP/missing.md" ] && ok=0
check "nonexistent path exits 0 and creates nothing" $ok

# 3. Unknown extension: exit 0, file untouched.
printf 'keep me\n' >"$TMP/note.xyz"
before=$(cat "$TMP/note.xyz")
run_hook "$TMP/note.xyz"; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ "$(cat "$TMP/note.xyz")" = "$before" ] && ok=0
check "unknown extension is a no-op" $ok

# 4. Idempotent: a second run on an already-formatted file changes nothing, and no other file appears.
printf '# Title\n\nSome text.\n' >"$TMP/doc.md"
run_hook "$TMP/doc.md"
first=$(cat "$TMP/doc.md")
run_hook "$TMP/doc.md"; rc=$?
count=0; for f in "$TMP"/*; do [ -e "$f" ] && count=$((count + 1)); done
ok=1; [ "$rc" -eq 0 ] && [ "$(cat "$TMP/doc.md")" = "$first" ] && [ "$count" -eq 2 ] && ok=0
check "second run is a no-op and touches nothing else" $ok

echo "format: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
