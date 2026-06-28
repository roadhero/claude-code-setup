#!/usr/bin/env bash
# PostToolUse(Edit|Write) — auto-format the edited file by extension.
# Covers every stack (web/android/ios/compute). Each branch is command-v guarded,
# so a missing formatter is a silent no-op, never an error.
INPUT=$(cat)
F=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$F" ] || [ ! -f "$F" ] && exit 0
case "$F" in
  *.kt|*.kts)
     command -v ktlint >/dev/null && ktlint -F "$F" >/dev/null 2>&1 ;;
  *.swift)
     if command -v swift-format >/dev/null; then swift-format -i "$F" 2>/dev/null
     elif command -v swiftformat >/dev/null; then swiftformat "$F" >/dev/null 2>&1; fi ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.css|*.scss|*.html|*.md)
     command -v prettier >/dev/null && prettier --write "$F" >/dev/null 2>&1 ;;
  *.py)
     command -v ruff >/dev/null && { ruff format "$F" >/dev/null 2>&1; ruff check --fix "$F" >/dev/null 2>&1; } ;;
  *.c|*.cc|*.cpp|*.cxx|*.h|*.hpp|*.hxx|*.cu|*.cuh)
     command -v clang-format >/dev/null && clang-format -i "$F" ;;
  *.go)
     command -v gofmt >/dev/null && gofmt -w "$F" ;;
  *.rs)
     command -v rustfmt >/dev/null && rustfmt "$F" >/dev/null 2>&1 ;;
  CMakeLists.txt|*.cmake)
     command -v gersemi >/dev/null && gersemi -i "$F" >/dev/null 2>&1 ;;
esac
exit 0
