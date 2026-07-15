# Secrets inventory

> Full detail for CLAUDE.md §11.1. The spine carries the secret-handling imperatives (§11); this is the per-project inventory template it points to. Copy into a real project's `docs/SECRETS.md` and fill in.

Document every secret the project needs. Suggested baseline (delete what doesn't apply, add domain-specific ones):

| Secret                                      | Used by                     | Purpose                                          | Rotation cadence                        |
| ------------------------------------------- | --------------------------- | ------------------------------------------------ | --------------------------------------- |
| `<artifact-registry>_TOKEN`                 | release workflow            | Publish package to npm/PyPI/crates.io/Maven/etc. | Every 90 days                           |
| `<container-registry>_TOKEN`                | release workflow            | Push container images                            | Every 90 days                           |
| `DATABASE_URL`                              | runtime + integration tests | Connect to primary database                      | Per-environment, rotated on team change |
| `OAUTH_CLIENT_SECRET` (per provider)        | runtime                     | OAuth flows                                      | Every 90 days                           |
| `WEBHOOK_SIGNING_SECRET`                    | runtime                     | Verify inbound webhooks                          | On team change                          |
| `SLACK_WEBHOOK_URL` / `DISCORD_WEBHOOK_URL` | release workflow            | Release notifications                            | On team change                          |
| `SENTRY_DSN` (or equivalent error tracker)  | runtime                     | Crash reporting                                  | Rarely (rotation breaks attribution)    |
| Signing keys (binary, package, container)   | release workflow            | Sign published artifacts                         | Never (rotation breaks trust chain)     |

Audit CI logs for any secret name that's been removed but is still referenced.
