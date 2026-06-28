---
name: new-repo-scaffold
description: Scaffold a new repository with the engineering-config hygiene the spine and rules assume. Use when starting a new project, initializing a repo, or "setting up" a web/backend or Android codebase. Lays down .gitignore (with secret patterns), CHANGELOG.md, docs/ stubs (PRD/ROADMAP/ADR), a CI quality-gate + release workflow, and the per-repo CLAUDE.md (§19); for Android, also copies the 7 Android subagents into .claude/agents/. Detects the stack or takes web|android explicitly. Never overwrites existing files.
---

# New-repo scaffolder

Lays down the repo hygiene that `~/.claude/CLAUDE.md` (§9 stacked-PR, §10 reconciliation, §11 secrets, §6/§7 release/gate in the platform rule) and the agents assume exists — so their references (`CHANGELOG.md`, `docs/REQUIREMENTS.md`, the version source, CI) resolve instead of dangling.

## When to use

Starting or initializing a new project, or a repo that's missing the standard scaffolding. Ask the user `web` (TS/JS/Python/Go/…) or `android` if it isn't obvious from existing files (`build.gradle*`/`*.kt` → android; `package.json`/`pyproject.toml` → web).

## Rules

- **Never overwrite.** Check each target with `test -e`; if it exists, skip it and report "kept existing". The user's files win.
- **One stack per run.** Don't lay down both web and Android scaffolding in the same repo unless asked.
- **Fill, don't fabricate.** The §19 `CLAUDE.md` ships with TODO placeholders the user completes — do not invent versions, SDK levels, or compliance scope.
- **Report exactly** what was created vs. skipped, as a list.

## Procedure

1. Determine stack (detect or ask). Set `STACK=web|android`.
2. From this skill's `templates/`, copy `common/` + `<STACK>/` files into the repo, **skipping any that already exist**. Template files use a `.tmpl` suffix to avoid clobbering — strip it on copy (e.g. `gitignore.tmpl` → `.gitignore`).
3. For **android**: also `mkdir -p .claude/agents` and copy the 7 files from `~/.claude/agents-android/` if present (or tell the user where to get them). For **web**: no local agents — it inherits the 15 global agents.
4. Drop the per-repo `CLAUDE.md` (§19 template) at the repo root.
5. `git init` only if `.git` is absent. Stage nothing automatically — let the user review.
6. Print the created/skipped report and the 3 manual follow-ups: fill §19, set the version source, wire branch protection (§7.3).

## What gets laid down

**common/** (both stacks): `.gitignore` (secret patterns from §11), `CHANGELOG.md` (Keep-a-Changelog header), `docs/REQUIREMENTS.md`, `docs/ROADMAP.md`, `docs/adr/0001-foundation.md`, `docs/decisions/.gitkeep`.

**android/**: `version.properties` (versionCode/versionName source of truth), `.github/workflows/gate.yml` (Spotless/detekt/lint/unit/Roborazzi/compileRelease), `.github/workflows/release.yml` (tag↔versionName parity → signed build → GitHub Release), `CLAUDE.md` (§19, Android-flavored).

**web/**: `.github/workflows/gate.yml` (format/lint/typecheck/test/build), `.github/workflows/release.yml` (tag↔version parity → publish), `CLAUDE.md` (§19, generic).

## Secret patterns the .gitignore enforces (§11)

`*.env`, `.env.*`, `*.pem`, `*.key`, `*.keystore`, `*.jks`, `**/secrets/`, `*.p12`, `google-services.json` (android), `service-account*.json`, `*.tfstate*`. The user adds project-specific paths.
