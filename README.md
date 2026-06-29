# Claude Code setup

This is the actual Claude Code configuration I run day to day at [EltexSoft](https://eltexsoft.com): a stack-agnostic engineering "spine," platform-specific rule packs that auto-activate, a roster of **50 subagents across four stacks**, two safety hooks, and a repo scaffolder. It's the same setup I describe in **42: The AI Builder's Stack**. Take what's useful.

Most people publish a single `CLAUDE.md` and call it a setup. The thing that actually makes Claude Code reliable is structure: a global file that never changes, rules that load only when the matching tech is detected, agents scoped to one job each, and hooks that stop bad commits before they happen. That's what's here.

## What's inside

| Path | What it is |
| --- | --- |
| `CLAUDE.md` | The universal spine. Workflow, git rules, coding guidelines, secrets handling, anti-patterns. Stack-agnostic, applies everywhere. The big one. |
| `rules/{web,android,ios,compute}.md` | Platform rule packs. Claude Code auto-loads the right one based on the files in your repo. |
| `agents/` (15) | The default subagent roster: the four-hat chain (architect → senior-swe → code-reviewer → qa), plus specialists (security, performance, db-migration, debugger, devops, docs, design) and a delivery layer (TPM, scrum-master). |
| `agents-android/` (7), `agents-ios/` (7), `agents-compute/` (21) | Per-stack overrides. Drop them into a repo's `.claude/agents/` and they override the generic ones of the same name with platform-brained versions. |
| `hooks/guard-commit.sh` | A pre-commit guard that blocks force-pushes to protected branches, non-human committers, AI attribution lines, and obviously-staged secrets. |
| `hooks/format.sh` | Auto-formats edited files by extension across every stack. Missing formatter is a silent no-op, never an error. |
| `skills/new-repo/` | A scaffolder skill: spins up a new repo with the right `CLAUDE.md`, `.gitignore`, quality gate, and release workflow per stack. |
| `templates/` | Blank project `CLAUDE.md` templates (generic + compute) to copy into a new repo and fill in. |
| `examples/CLAUDE.example-web.md` | A filled-in example so you can see what "done" looks like before you write your own. |
| `STRUCTURE.md` | The full layout, install steps, and how the two-settings-file swap works. **Read this first.** |

## The idea in one paragraph

Two tiers. The **global** tier (`~/.claude/CLAUDE.md` + `rules/` + `agents/` + `hooks/`) is everything that's true regardless of what you're building. The **project** tier is a short `CLAUDE.md` at the repo root that holds only what's specific to that project (§19: stack, quality gate, release pointers, compliance scope). The spine gets prompt-cached and never changes; the project file is the only thing you edit per repo. Rules and agents specialize automatically based on the repo's actual files. You configure once, then mostly leave it alone.

## Install

Mac/Linux, with Claude Code already installed. Full steps and the per-repo install are in [`STRUCTURE.md`](./STRUCTURE.md). The short version:

```bash
mkdir -p ~/.claude/rules ~/.claude/agents ~/.claude/hooks ~/.claude/skills
cp CLAUDE.md      ~/.claude/CLAUDE.md
cp settings.json  ~/.claude/settings.json      # merge your own model / plugin blocks in
cp rules/*.md     ~/.claude/rules/
cp agents/*.md    ~/.claude/agents/
cp hooks/*.sh     ~/.claude/hooks/ && chmod +x ~/.claude/hooks/*.sh
cp -R skills/new-repo ~/.claude/skills/
```

Then per repo, copy a template in as the project `CLAUDE.md` and fill in §19. See `examples/` for a worked one.

## A few honest caveats

This is opinionated and built for how my team works. The git rules assume PR-based flow with protected branches. The hooks assume the formatters are installed (they no-op cleanly if not). The compute stack is C++/CUDA/Python systems work and is overkill if you only ship web apps. Strip what you don't need. The point isn't to adopt my exact setup. It's to see a real, working one and build yours.

## More

- The book: **42: The AI Builder's Stack** — sample chapters are at [eltexsoft.com](https://eltexsoft.com); the full book is on Amazon.
- The chapter on Claude Code goes deep on the why behind all of this.

MIT licensed. Use it, fork it, change it. No attribution required.
