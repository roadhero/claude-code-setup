# PR description template

> Full detail for CLAUDE.md §16. The spine carries the one-line pointer; the fill-in template lives here.
>
> **Per §2: no mention of AI tools, LLMs, or assistants** in PR descriptions, test plans, or anywhere else in the PR. The template below contains no such mentions and you shouldn't add any.

```markdown
## Summary

<1–3 sentences explaining what this PR does and why>

- **<key change 1>** — <one-line description>
- **<key change 2>** — <one-line description>

### Deferred / out of scope

- <thing you intentionally didn't do, with reason>

## Test plan

- [x] Local quality gate green: `<formatter>`, `<linter>`, `<type-checker>`, `<unit-tests>`, `<build>`, `<integration-tests>` (delete what doesn't apply)
- [x] Any domain-specific audits clean
- [ ] On-target verification:
  - <specific check 1>
  - <specific check 2>

<Closes #N OR Refs #N>
```
