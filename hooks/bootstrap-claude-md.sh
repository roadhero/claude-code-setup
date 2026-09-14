#!/usr/bin/env bash
# SessionStart hook -- offer to bootstrap a project CLAUDE.md when the repo has none.
#
# Emits a one-line nudge on stdout (the documented SessionStart context idiom) telling
# Claude to act on the project-bootstrap policy (CLAUDE.md section 4C). Silent unless
# ALL of these hold:
#   - the session's directory is inside a git work tree,
#   - the work-tree root is not the home directory (never bootstrap a dotfiles-in-$HOME
#     repo; the global ~/.claude config stays silent via the CLAUDE.md-exists check below),
#   - there is no CLAUDE.md at the work-tree root.
# It never writes a file and never blocks the session: any failure just means no
# nudge (fail-open). Claude, not this hook, creates the file -- only after the user
# agrees -- so a hook that inspects but never writes keeps the "a hook touches only
# the tool's own target" rule (STRUCTURE.md).
#
# Contract: reads the SessionStart JSON payload on stdin (uses .cwd), prints either
# nothing or one line of context to stdout, and exits 0. Requires jq (to read the
# payload) and git, already hard dependencies of this config's hooks.

set -u

# Read the payload; fall back to the current directory if it is missing or unusable.
payload=$(cat 2>/dev/null) || payload=""
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD

# Inside a git work tree? Silent no-op otherwise (throwaway dirs, non-repos).
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

# Never fire on a git-tracked home directory (project guidance does not belong at $HOME).
# $root is canonical (rev-parse resolved symlinks), so compare against both the raw and
# the canonicalized $HOME; a symlinked home path then still matches. ${HOME:-} and the cd
# fallback keep the fail-open contract: an unset or unreadable HOME just does not match.
home=${HOME:-}
canon=$(cd "$home" 2>/dev/null && pwd -P 2>/dev/null)
[ -n "$home" ] && [ "$root" = "$home" ] && exit 0
[ -n "$canon" ] && [ "$root" = "$canon" ] && exit 0

# Already has project guidance? Silent.
[ -e "$root/CLAUDE.md" ] && exit 0

msg="This repository has no CLAUDE.md at its root. Follow the project-bootstrap policy (CLAUDE.md section 4C): offer to create one before doing other work, and create it only if the user agrees. On yes, if the repo is essentially empty use the new-repo skill; otherwise create ./CLAUDE.md from the standard template at ~/.claude/templates/CLAUDE.project.md, fill the section 19 fields you can confidently detect now (stack, quality-gate commands), and leave the rest as TODO to complete as specs appear. Never overwrite an existing CLAUDE.md."

# Plain-text stdout is the documented way a SessionStart hook injects context Claude
# can see; print the nudge and exit clean.
printf '%s\n' "$msg"
exit 0
