# Project Bootstrap (§4C detail)

How to create a project `CLAUDE.md` when a repo has none. The spine (§4C) carries the rule; this is the detection and fill detail. The `hooks/bootstrap-claude-md.sh` SessionStart hook is only the trigger — it emits a one-line nudge and never writes a file. You do the offering and the writing, only after the user agrees.

## When the hook nudges

It stays silent unless all three hold: the session is inside a git work tree, the work-tree root is not your home directory (so it never bootstraps a dotfiles-in-`$HOME` repo), and there is no `CLAUDE.md` at the work-tree root. So it never fires in a git-tracked home, in throwaway non-git directories, or in a repo that already has guidance — including the global `~/.claude` config, which ships its own `CLAUDE.md` and so is caught by the third condition. Once the file exists, every later session is silent.

## The offer

Offer; don't auto-create. A repo you were told to open may be one you're only reading, a clone, or someone else's code. Ask something like: "This repo has no `CLAUDE.md` — want me to create one from your standard and fill §19 from what's here?" Create only on a yes. If the user declines, drop it for the session; the nudge is stateless and may return next session, which is fine.

## Bare vs populated

- **Bare** — a fresh `git init` with no package manifest and no source (nothing but `.git`, maybe a `README` or `LICENSE`). Use the `new-repo` skill: an empty repo benefits from the whole hygiene set (`.gitignore`, CI gate + release workflow, `docs/` stubs, and the `CLAUDE.md`).
- **Populated** — anything with real structure (a manifest, a source tree, existing CI). Create **only** `./CLAUDE.md` from `~/.claude/templates/CLAUDE.project.md` (or `CLAUDE.project.compute.md` for a C++/CUDA repo). Do **not** run the full `new-repo` scaffolding — a mature repo has its own `.gitignore`, CI, and docs layout, and dropping the standard ones on top is intrusive and out of scope. The one canonical template is shared with `new-repo`, so there is no second copy to drift.

## Filling §19 from what's detectable

Fill only what the repo actually shows; leave everything else as the template's `TODO`. Confident signals:

- **19.2 Stack** — `package.json` (Node/TS; read `engines`, `packageManager`), `pyproject.toml`/`requirements.txt` (Python), `go.mod` (Go, with its version line), `Cargo.toml` (Rust), `build.gradle*`/`*.kt` (Android/Kotlin), `*.xcodeproj`/`Package.swift` (Swift/iOS), `CMakeLists.txt`/`*.cu` (compute). Pin versions you can read; never guess a version — a wrong pin is worse than a `TODO`.
- **19.3 Quality gate** — the scripts a contributor already runs: `package.json` `scripts` (lint/test/build/typecheck), a `Makefile`'s targets, `.github/workflows/*` steps, `pyproject`/`tox`/`noxfile` sections. Copy the real commands, in fail-fast order.
- **19.1 Description** — the `README` opening, if it states the product plainly. If the README is thin or marketing, leave the `TODO`.

Leave `TODO` for anything not on disk: **19.4** release pointers, **19.5** compliance scope, and any stack/gate field you cannot read. These are the fields you complete over time — when a PRD, an ADR, a spec, or a fuller README later states one, fill that `TODO` then. Don't fabricate a version, a distribution channel, or a compliance scope to make the file look finished.

## Rules

- **Never overwrite** an existing `CLAUDE.md`; if one appears, stop.
- **Fill, don't fabricate** — a `TODO` is the correct value for an unknown fact.
- **Scope is the `CLAUDE.md`** — nothing else in the repo changes on this path (the bare-repo case delegates the rest to `new-repo`).
