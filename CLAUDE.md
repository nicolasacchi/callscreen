# Callscreen

AI-screened call routing for an Italian-primary multi-tenant operator.
Telnyx Voice API webhooks in → AI screening (Whisper transcription +
Moonshot Kimi LLM classification) → ntfy push out. One Telnyx number
serves multiple tenants, routed by `dedicated_number` or SIP
`History-Info` header at `phone.example.com`.

## Stack

- Rails 8.1.2 / Ruby 3.4.8
- SQLite + Solid Queue (no Postgres / Redis / Sidekiq)
- Devise multi-tenant on the `Tenant` model (renamed from `AdminUser`
  to free up the `Admin::` controller namespace)
- Telnyx Voice API (Call Control); Ed25519-signed webhooks
- Kokoro + Chatterbox (multilingual + clone) for TTS
- faster-whisper (whisper-medium) for transcription, sidecar service
- Deployed via traefik docker-compose at `compose.yml` (out of repo)

## Run / test commands

```
bundle exec bin/rails test                # unit suite (run from repo root)
bundle exec brakeman -q                   # security scan, must stay clean
bin/synthetic_call --watch                # one synthetic call against prod
bundle exec rake e2e:run                  # live e2e (needs E2E_AGAINST + SYNTHETIC_WEBHOOK_TOKEN)
docker compose -f compose.yml build callscreen
docker compose -f compose.yml up -d callscreen
```

Migrations run automatically on container start via `bin/docker-entrypoint`.

## Where things live

| Concern | Path |
|---|---|
| Telnyx webhook dispatcher | `app/controllers/telnyx_controller.rb` |
| Phrase / greeting selection | `app/services/phrase_pool_resolver.rb` |
| Time-of-day slot resolver | `app/services/time_of_day_slot.rb` |
| Day-of-week slot resolver | `app/services/day_of_week_slot.rb` |
| Caller language resolution | `app/services/language_resolver.rb` |
| Whisper client | `app/services/whisper_client.rb` |
| LLM classifier | `app/services/spam_classifier.rb` |
| ntfy notifier + action token | `app/services/ntfy_notifier.rb`, `app/services/ntfy_action_token.rb` |
| ntfy action endpoints | `app/controllers/ntfy_actions_controller.rb` |
| Voice clone | `app/jobs/voice_clone_render_job.rb`, `scripts/clone_render.py` |
| Phrase render | `app/jobs/phrase_render_job.rb`, `scripts/render_phrase.py` |
| Synthetic call (CLI + lib) | `bin/synthetic_call`, `scripts/synthetic_call.rb`, `lib/synthetic_call.rb` |
| Live e2e suite | `e2e/` (NOT under `test/`) |
| E2E inspector JSON endpoints | `app/controllers/e2e_inspector_controller.rb` |
| Recording playback | `app/controllers/recordings_controller.rb`, `app/services/recording_downloader.rb` |
| Greeting WAV serving | `app/controllers/greetings_controller.rb`, `app/lib/greetings_storage.rb` |
| Admin views | `app/views/admin/`, layout in `app/views/layouts/admin.html.erb` |

## Tenant resolution

`TelnyxController#resolve_tenant` matches in this order — **not** by
`mobile_number`:

1. `Tenant.find_by(dedicated_number: to)` — Telnyx-side number that
   identifies the tenant
2. `Tenant.find_by(mobile_number: SIP History-Info origin)` — for
   carrier-forwarded calls (Italian Telecom Italia uses RFC 7044
   History-Info, NOT RFC 5806 Diversion)
3. `Tenant.default`

Setting up a new tenant for a Telnyx number → set `dedicated_number`,
not just `mobile_number`. The e2e fixture rediscovered this the hard
way.

## Phrase / greeting selection

`PhrasePoolResolver#resolve!` runs a 7-tier fallback. Every tier
filters through `Phrase.rendered.with_text(lang).matching_day(day)`:

1. Direct contact pool, time-of-day matched
2. Tag-matched pool, time-of-day matched
3. Tenant default pool, time-of-day matched
4. Direct contact pool, time-of-day = `any`
5. Tag-matched pool, time-of-day = `any`
6. Tenant default pool, time-of-day = `any`
7. Static fallback: `Phrase.find_by(slug: tenant.greeting_variant)` →
   any rendered shared phrase

Cursor advance: only the *owning* tier increments its cursor. Empty
tiers don't bump anything. Per-contact cursor lives on
`Contact#phrase_rotation_index`; tenant cursor on
`Tenant#phrase_rotation_index`.

## Voice rotation

Picked once per call via `TelnyxController#pick_voice_for_call!`,
cached on `Call#selected_voice`. `play_greeting`, `play_goodbye`, and
`start_voicemail` all call this — first invocation advances the
rotation cursor, subsequent invocations return the cached voice.
Result: cursor advances exactly once per call regardless of how many
audio segments fire.

Order: `voice_rotation_voices` → `voice_clone_dir` (`_t<id>`) →
`tenant.greeting_voice`.

## Render pipeline

WAV layout:
- `storage/greetings/<slug>/<voice>/<tone>.wav` — Kokoro / Chatterbox
- `storage/greetings/<slug>/_t<tenant_id>/<tone>.wav` — Italian clone
- `storage/greetings/<slug>/_t<tenant_id>/<tone>_en.wav` — English
  clone (language encoded in tone-suffix; handled by
  `TelnyxController#audio_url_for_voice`)

`PhraseRenderJob` (queue: `:rendering`) shells out to
`scripts/render_phrase.py`. The `:rendering` queue is intentionally
separate from `:default` (see `config/queue.yml`) so a render storm
on user-authored phrases never blocks `ScreeningJob` or `NotifyJob`.

`Phrase` has `after_commit :enqueue_render_if_text_changed` — in
tests use `update_columns` to bypass.

## Webhook auth

Three paths in `TelnyxController#verify_telnyx_request`:

1. **Telnyx Ed25519 signature** (production) — verified via
   `TelnyxSignatureVerifier` against `ENV["TELNYX_PUBLIC_KEY"]`
2. **Fallback token** (`?token=…` matching `ENV["WEBHOOK_TOKEN"]`) —
   currently disabled in production via `WEBHOOK_TOKEN_FALLBACK=0`
3. **Synthetic token** (`?synthetic_token=…` matching
   `ENV["SYNTHETIC_WEBHOOK_TOKEN"]`) — opt-in per-deployment, used by
   `bin/synthetic_call` and `e2e/`. Also gates `X-E2E-Now` time
   injection and `/e2e/*` JSON inspector endpoints.

## ntfy notifications

`NotifyJob` → `NtfyNotifier.notify` posts to `tenant.ntfy_url` with
fallback to `ENV["NTFY_URL"]`. Three action buttons (Whitelist /
Mark spam / Call back) are signed by `NtfyActionToken` (Rails
`MessageVerifier`), 14-day expiry. Action endpoints at
`/ntfy/calls/:id/{whitelist,spam,legit}?t=…`.

Per-tenant suppression: `tenant.ntfy_url == "disabled"` short-circuits
BEFORE the ENV fallback. The e2e tenant uses this so test runs don't
push real notifications to the operator's phone.

`NotifyJob` has `discard_on ActiveRecord::RecordNotFound` so a Call
destroyed mid-flight (e.g., during e2e teardown) doesn't pollute the
SolidQueue dead set.

## E2E test suite

Lives in `e2e/`, NOT `test/e2e/`. `bin/rails test` autoloads every
`*_test.rb` under `test/`, which would crash if it tried to load
files that hit `ENV.fetch("E2E_AGAINST")` at class-load time.

```
e2e/
  e2e_helper.rb                 # base + fire_call + read_call helpers
  01_greeting_language_swap_test.rb
  02_per_contact_pool_test.rb
  03_voice_rotation_test.rb
  04_ntfy_action_test.rb
  05_time_of_day_test.rb
  06_day_of_week_test.rb
  07_rate_limit_test.rb
```

The suite drives `bin/synthetic_call` against a deployed target,
then reads state via the `/e2e/call`, `/e2e/tenant`, `/e2e/contact`
JSON endpoints (token-gated). State mutation (tenant fixture setup,
Phrase creation with render-bypass + fake WAV write) goes via
`docker exec callscreen bin/rails runner`.

## Storage volumes

`storage/recordings/`, `storage/greetings/`, `storage/voice_samples/`
are Docker volumes mounted from the host. `storage/development.sqlite3`,
`storage/test.sqlite3`, `storage/production.sqlite3` are the per-env
DBs. Don't `rm -rf storage` during dev work without checking.

## Secrets

Secrets live in the operator secret store. **Never** read
`.env` files directly. Production env vars are loaded from
the compose-host `.env` into the docker-compose `callscreen` service block.

## Common gotchas

- `auto_blacklist_threshold` must be `nil` to disable, NOT `0` —
  validator rejects `0`.
- System phrases use `tenant_id: nil`; reserved slugs in
  `Phrase::RESERVED_SYSTEM_SLUGS` block user collisions.
- Routes don't pass colons cleanly in path segments — call_control_id
  values like `v3:synthetic-…` go in query params, not path segments
  (see `/e2e/call?call_control_id=…`).
- `Phrase.rendered` only matches `render_status: "rendered"`. New
  user phrases stay `pending` until `PhraseRenderJob` finishes; the
  resolver skips them, so seed/setup paths must `update_columns` to
  bypass the after_commit render-enqueue when faking rendered state.
- `tenant.default_tenant: true` is partial-unique; only one tenant
  can hold it. Use a different mobile_number/dedicated_number for
  test tenants.
- `ScreeningJob` runs in `:default` queue alongside `NotifyJob`;
  `PhraseRenderJob` runs in `:rendering`. Don't merge the queues.
- `Time.zone.parse(raw) rescue nil` silently swallows errors.
  `Time.zone.iso8601(raw)` raises on malformed input — use the
  strict form when you want a parse failure to surface.

## Sentry / observability

`config/initializers/sentry.rb` propagates request_id to outbound
HTTP. Audit trail in `AuditLog` (system actions use `actor: nil`,
`metadata.source: "ntfy"` etc.).

## When in doubt

The plan files at `~/.claude/plans/*.md` keep historical context for
each major refactor (per-contact phrases, e2e suite, voice rotation
fix). They reference exact file paths and line numbers as of the
ship date.
