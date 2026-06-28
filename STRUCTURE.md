# Mac Claude Code config — full structure

```
~/.claude/
├── CLAUDE.md                 # universal spine (§1–18, stack-agnostic)
├── settings.json             # ACTIVE: web/android/ios perms + hooks
├── settings2.json            # compute (C++/CUDA/Python) perms + hooks + subagent model — swap-in
├── rules/
│   ├── web.md                # TS/JS/Python/Go/Rust
│   ├── android.md            # Kotlin/Compose/Hilt/Room
│   ├── ios.md                # Swift/SwiftUI/Swift6/App Store
│   └── compute.md            # C++/CUDA/parallel-Python
├── agents/                   # 15 GENERIC (global default)
├── hooks/
│   ├── guard-commit.sh       # PreToolUse(Bash): block AI attribution, secrets, force-push, non-human committer
│   └── format.sh             # PostToolUse(Edit|Write): auto-format by extension, all stacks
└── skills/new-repo/          # scaffolder

Per-repo overrides (drop into <repo>/.claude/agents/ — override the 15 globals by canonical name):
   Android repo → agents-android/   (7)
   iOS repo     → agents-ios/        (7)
   Compute repo → agents-compute/    (21; 8 duplicate globals harmlessly, 13 are compute-specific)

Per-repo CLAUDE.md (§19 only; inherits spine + auto-detected rule):
   generic template   → templates/CLAUDE.project.md
   compute template   → templates/CLAUDE.project.compute.md
   filled example     → examples/CLAUDE.example-web.md (fictional web SaaS, shows §19 filled in)
```

## Install (Mac)
```bash
mkdir -p ~/.claude/rules ~/.claude/agents ~/.claude/hooks ~/.claude/skills
cp CLAUDE.md            ~/.claude/CLAUDE.md
cp settings.json        ~/.claude/settings.json        # merge your model + enabledPlugins blocks in
cp settings2.json       ~/.claude/settings2.json        # kept for swapping; see note below
cp rules/*.md           ~/.claude/rules/
cp agents/*.md          ~/.claude/agents/
cp hooks/*.sh           ~/.claude/hooks/ && chmod +x ~/.claude/hooks/*.sh
cp -R skills/new-repo    ~/.claude/skills/

# per repo:
cp templates/CLAUDE.project.md /path/to/repo/CLAUDE.md   # then fill §19  (or templates/CLAUDE.project.compute.md for C++/CUDA)
mkdir -p /path/to/repo/.claude/agents
cp agents-android/*.md /path/to/android-repo/.claude/agents/     # or agents-ios / agents-compute
```

## The two settings files — how they work
Claude Code reads **`settings.json`** only. `settings2.json` is the compute profile, kept beside it to **swap in** when you do C++/CUDA/Python work on the Mac:
```bash
cd ~/.claude
cp settings.json settings.web.json     # stash the active one once
# switch to compute:
cp settings2.json settings.json
# switch back:
cp settings.web.json settings.json
```
Both reference the **same** `guard-commit.sh` + `format.sh`; they differ only in the permission allowlist (web/mobile tools vs compiler/CUDA/profiler tools) and the subagent-model env.

> **Alternative (simpler):** the two allowlists don't conflict — you can merge them into one `settings.json` and never swap. Permissions are just an allowlist; granting compiler tools alongside mobile tools is harmless.

> **⚠ Subagent model:** `settings2.json` pins `CLAUDE_CODE_SUBAGENT_MODEL=claude-opus-4-8`. If your main model is higher-tier than Opus, this line **downgrades** subagents to Opus. Delete the `env` block if you want subagents to inherit your main model. It's there only because compute work is rule-heavy and a deterministic pin can be worth it.

## Hook paths
Both settings files reference the hooks via `$HOME/.claude/hooks/...`, which the shell expands to your home directory, so they work for any user without editing. Verify with `/hooks` inside Claude Code. Install the prereqs the format hook needs per stack: `jq` (required), plus `prettier`/`ktlint`/`swift-format`/`ruff`/`clang-format` as applicable.

## Agent override model
A repo's `.claude/agents/<name>.md` overrides the user-scope `~/.claude/agents/<name>.md` with the same `name:` field. So dropping the 7 Android agents (canonical names architect/senior-swe/code-reviewer/qa/release-engineer/docs-reconciler/performance-engineer) into an Android repo swaps the generic four-hat chain for Android-brained ones; the other 8+ generics still apply. Same pattern for iOS and compute.
