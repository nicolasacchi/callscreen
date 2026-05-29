# Ops runbook — P0 security & durability actions

These are the deploy-side P0 items from the May 2026 multi-view review
(`docs/research/callscreen-multiview-review-2026-05-29.html`). They touch
`compose-host` and secrets, so they are performed by the operator, not in the app
repo. Do them together — several are interdependent.

## 1. Rotate the synthetic webhook token; remove committed compose defaults (MT-1 / SEC-6 / OPS-4)

`compose.yml` currently ships **real** secret values as `:-`
defaults, so a missing env var silently goes live with a committed credential:

```yaml
# BEFORE (callscreen service env block) — committed defaults are live if unset:
- SYNTHETIC_WEBHOOK_TOKEN=${CALLSCREEN_SYNTHETIC_WEBHOOK_TOKEN:-<redacted 64-hex token>}
- ADMIN_PASSWORD=${CALLSCREEN_ADMIN_PASSWORD:-<redacted default password>}
```

The synthetic token bypasses Telnyx Ed25519 verification and (when set) unlocks
`/e2e/*` inspector reads + `X-E2E-Now` clock injection.

Steps:
1. Generate a fresh token: `openssl rand -hex 32`.
2. Store it (and a real admin password) in operator secret store, then set in `compose-host/.env`:
   ```
   CALLSCREEN_SYNTHETIC_WEBHOOK_TOKEN=<new token>   # OR leave unset in prod (see step 4)
   CALLSCREEN_ADMIN_PASSWORD=<strong password>
   ```
3. Change the compose lines to **fail-closed** (no `:-` default):
   ```yaml
   - SYNTHETIC_WEBHOOK_TOKEN=${CALLSCREEN_SYNTHETIC_WEBHOOK_TOKEN}
   - ADMIN_PASSWORD=${CALLSCREEN_ADMIN_PASSWORD}
   ```
4. **Preferred:** do not run e2e against prod at all — leave
   `CALLSCREEN_SYNTHETIC_WEBHOOK_TOKEN` unset in prod (the `/e2e/*` surface and
   synthetic webhook then return 401 and are invisible) and point the e2e suite
   at a staging target. If you must keep it enabled on prod, also set
   `CALLSCREEN_E2E_TENANT_SLUG=e2e` (see step 5).
5. Recreate the container: `docker compose -f compose.yml up -d callscreen`.
6. Verify: `curl -s -o /dev/null -w '%{http_code}' 'https://phone.example.com/e2e/tenant?slug=default'` returns **401** in prod.

## 2. Confine the e2e inspector to the fixture tenant (defense-in-depth, MT-1)

The app now scopes `/e2e/*` reads to a single tenant when `E2E_TENANT_SLUG` is
set. If you keep the synthetic token enabled anywhere, set in `compose-host/.env`:

```
CALLSCREEN_E2E_TENANT_SLUG=e2e
```

and add `- E2E_TENANT_SLUG=${CALLSCREEN_E2E_TENANT_SLUG}` to the callscreen env
block. A leaked token then cannot enumerate other tenants' calls/contacts.

## 3. Enable Sentry (OPS-2)

Without `SENTRY_DSN`, all `Sentry.capture_exception` calls are no-ops and the
operator is blind to screening failures. Set in `compose-host/.env`:

```
CALLSCREEN_SENTRY_DSN=<dsn from sentry.io>
```

and add `- SENTRY_DSN=${CALLSCREEN_SENTRY_DSN}` to the callscreen env block.
(Independently, `ScreeningJob`/`TranscribeRecordingJob` now push an ntfy alert
to the tenant on terminal failure, so failures surface even without Sentry.)

## 4. Nightly SQLite backups (OPS-1)

All business state lives in `storage/*.sqlite3` on one bind mount with no
backup. The app now ships a WAL-safe `db:backup` rake task (`lib/tasks/backup.rake`,
`VACUUM INTO` → `storage/backups/`, keeps 14 days). Add a host cron entry:

```cron
0 3 * * *  docker exec callscreen ./bin/rails db:backup >> /var/log/callscreen-backup.log 2>&1
# Optional: copy storage/backups off-box alongside the existing borg job.
```

Restore: stop the container, copy a snapshot over `storage/production.sqlite3`
(and `production_queue.sqlite3`), start the container.

Run a pre-deploy backup before any migration: `docker exec callscreen ./bin/rails db:backup`.

## 5. Rebuild after the .dockerignore change (OPS-3)

`.dockerignore` now excludes `/.venv` and `/.hf_cache` (the 8.5 GB host venv was
being baked into the image via `COPY . .`). Rebuild and confirm the image shrank:

```
docker compose -f compose.yml build callscreen
docker run --rm --entrypoint sh <image> -c 'ls /rails/.venv 2>/dev/null && echo PRESENT || echo absent'  # → absent
```
