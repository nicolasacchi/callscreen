# Callscreen

AI phone call screener that answers forwarded calls via Telnyx TeXML, screens callers with an LLM, transcribes voicemails with Whisper, and pushes notifications via ntfy. Italian-first, but works with any locale.

Stack: Rails 8.1, Ruby 3.4, SQLite, Solid Queue (no Redis/Sidekiq), Devise admin, Thruster, Dockerized.

---

## How it works

```
Inbound call → Telnyx → POST /telnyx/voice
                          ↓
                  contact lookup + Rule check
                          ↓
        ┌─────────────────┼─────────────────┐
        ↓                 ↓                 ↓
   Reject          Forward (Dial)     Gather speech
   (blacklist)     (whitelist)              ↓
                                  POST /telnyx/screen
                                            ↓
                                  Rule keyword check
                                            ↓
                                  SpamClassifier (LLM)
                                            ↓
                          ┌─────────────────┼─────────────────┐
                          ↓                 ↓                 ↓
                       Hangup        Record voicemail   Record voicemail
                       (spam)        (legit)            (uncertain)
                                            ↓
                                  POST /telnyx/recording
                                            ↓
                            TranscribeRecordingJob (Solid Queue)
                                ↓                 ↓
                          Whisper API        ntfy push
```

---

## Required environment variables

| Variable | Purpose |
|---|---|
| `RAILS_MASTER_KEY` | Decrypts `config/credentials.yml.enc` |
| `APP_DOMAIN` | Public-facing host (e.g. `https://phone.example.com`); used to build TeXML callback URLs and for `config.hosts` |
| `WEBHOOK_TOKEN` | Legacy webhook auth token. **Optional once Telnyx Ed25519 signing is enabled.** |
| `TELNYX_PUBLIC_KEY` | Base64-encoded raw 32-byte Ed25519 public key from your Telnyx account. Required for signed-webhook verification. |
| `TELNYX_API_KEY` | Used to download recordings from `*.telnyx.com` |
| `MOONSHOT_API_KEY` | Authentication for the Moonshot/Kimi LLM classifier |
| `MOONSHOT_MODEL` | Model id, default `moonshot-v1-8k` (fast, non-reasoning; alternatives: `moonshot-v1-32k`, `kimi-k2.6` for reasoning) |
| `WHISPER_API_URL` | Faster-whisper service base URL, default `http://faster-whisper:8000` |
| `NTFY_URL` | Full ntfy topic URL for push notifications |
| `NTFY_PRIORITY` | Optional, default `default` |
| `FORWARD_NUMBER` | Optional E.164 number to dial for whitelisted callers |
| `ADMIN_EMAIL` | Seed admin email |
| `ADMIN_PASSWORD` | Seed admin password (REQUIRED in production) |
| `SOLID_QUEUE_IN_PUMA` | Set to `1` to run the Solid Queue supervisor inside Puma; default off in dev, on in our Docker image |
| `WEBHOOK_TOKEN_FALLBACK` | `1` (default when `WEBHOOK_TOKEN` is set) keeps the legacy `?token=` auth path active during cutover. Set to `0` once Telnyx-side signing is confirmed working. |
| `SENTRY_DSN` | Optional. When set, errors are reported to Sentry with PII filtered. |
| `SENTRY_TRACES_SAMPLE_RATE` | Optional, default `0.0` |
| `RAILS_LOG_LEVEL` | Optional, default `info` |
| `RAILS_MAX_THREADS` | Optional, default `3` |
| `TZ` | Set to `Europe/Rome` in the Dockerfile so cron schedules + log timestamps use Rome time |

---

## First-run setup

### Local dev

```bash
bundle config set --local path 'vendor/bundle'
bundle install
bin/rails db:prepare
bin/rails db:seed     # creates admin user; ADMIN_PASSWORD must be set
bin/rails server      # http://localhost:3000
```

Run the test suite:

```bash
bin/rails db:test:prepare
bin/rails test
```

Local checks before opening a PR:

```bash
bin/rubocop
bin/brakeman --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit
```

### Docker / production

The Dockerfile is multi-stage, runs as non-root, has a `HEALTHCHECK` against `/up`, and sets `TZ=Europe/Rome` plus `SOLID_QUEUE_IN_PUMA=1` so jobs run in the same container as the web server.

```bash
docker build -t callscreen .
docker run -d -p 80:80 \
  --env-file .env \
  -v $PWD/storage:/rails/storage \
  callscreen
```

Deployment in this repo is via the traefik compose at `compose.yml` (out of repo). Persistent storage is mounted at `/rails/storage` so SQLite databases and voicemail recordings survive container restarts.

---

## Telnyx setup

1. **Create a TeXML application** in the Telnyx portal with this voice URL:
   `https://<APP_DOMAIN>/telnyx/voice` (POST). Status callback URL: `https://<APP_DOMAIN>/telnyx/status`.
2. **Enable webhook signing** on the application. Copy the public key (Base64-encoded raw 32 bytes) and set it as `TELNYX_PUBLIC_KEY`.
3. **(Optional, during cutover)** Set `WEBHOOK_TOKEN` so the app accepts `?token=...` query-string authentication as a fallback if signing is misconfigured. Set `WEBHOOK_TOKEN_FALLBACK=0` to disable the fallback once signing is verified.
4. **Provision a phone number** and forward it to the TeXML application.
5. **Set `FORWARD_NUMBER`** to the number you want whitelisted callers to be Dial'd to (typically your real phone).

### Rotating `WEBHOOK_TOKEN`

```bash
bin/rails callscreen:rotate_webhook_token   # prints a fresh token
```

Update env, restart, then update the Telnyx-side webhook URL in the dashboard (or, if signing is on, just remove the token).

---

## Greeting catalog & voices

The greeting played at the start of every screened call is **selectable from the admin UI** (`/admin/settings`). Two settings drive it:

- `greeting_variant` — one of 10 slugs in `app/models/greeting_catalog.rb` (`informal_tu`, `formal_lei`, `business_meeting`, `brief_lei`, `brief_tu`, `apologetic`, `direct`, `warm`, `email_first`, `bilingual_short`). Default: `informal_tu`. All variants share the same core message ("sono impegnato, ditemi di cosa avete bisogno…") plus the email `operator@example.com` written phonetically for clean TTS.
- `greeting_voice` — one of `if_sara`, `im_nicola` (Kokoro Italian voices) or `alice`/`man`/`woman` (Telnyx built-in fallback).

### Two-tier playback

1. **Pre-rendered Kokoro audio** (preferred). When `storage/greetings/<slug>/<voice>.wav` exists, the app emits TeXML `<Play>` pointing at `https://APP_DOMAIN/greetings/<slug>/<voice>.wav` and Telnyx fetches the file. Studio-quality voices, no per-call cost.
2. **Telnyx `<Say voice="alice">` fallback**. When the audio file is missing, the app falls back to Telnyx's built-in TTS using the variant's text. The system never hangs even if the operator hasn't pre-rendered yet.

### One-time setup: install Kokoro and render audio

Kokoro is a free, local TTS engine (no API key, ~2 GB for model + torch). Install once on the host, then run the render script after every catalog edit:

```bash
# inside the callscreen project
python3 -m venv .venv
source .venv/bin/activate
pip install 'kokoro>=0.9.4' soundfile torch numpy

bin/render_greetings                               # all 10 variants × default voices
bin/render_greetings --voices if_sara              # only one voice
bin/render_greetings --variants informal_tu --force  # re-render one variant
```

Output goes into `storage/greetings/<slug>/<voice>.wav` (24 kHz mono WAV). The mounted `storage/` volume in the deployed container picks the files up immediately — no restart needed.

To add a new voice (e.g., `if_carlotta` if Kokoro adds it), append it to `Setting::ALLOWED_VOICES` in `app/models/setting.rb`, run `bin/render_greetings --voices if_carlotta`, restart.

## Data retention

Two retention windows, both configured via the admin Settings page:

| Setting | Default | What it deletes |
|---|---|---|
| `auto_delete_days` | 30 | The voicemail audio file (`storage/recordings/<sid>.wav`) and the row's `recording_local_path` |
| `auto_delete_transcripts_days` | 30 | `voicemail_transcript`, `screening_transcript`, and `ai_classification` columns on Call rows past this age |

Phone numbers (`Contact.phone`, `Call.from_number`) are retained indefinitely so blacklist/whitelist Rules continue to work across cleanup runs. To purge a specific contact's history, delete it via the admin UI; cascading nullification is handled by `Contact has_many :calls, dependent: :nullify`.

`CleanupRecordingsJob` runs daily at 03:00 Europe/Rome via Solid Queue's recurring scheduler (`config/recurring.yml`).

---

## Admin UI

Behind `/admin/login`. Devise with `:lockable` (5 failed attempts → 1-hour lock), `:timeoutable` (30-minute idle session), `:trackable` (records sign-in count, IP, last login). Rack::Attack rate-limits the login endpoint at 10 requests/5 minutes per IP and 5 requests/20 minutes per submitted email.

Pages:
- **Dashboard** — call counts (today + 30-day chart), contact stats, 15 most recent calls, 10 most recent admin audit-log entries
- **Calls** — paginated, filterable by status; search by phone number; per-call detail view with screening transcript, voicemail transcript, AI classification, recording playback. Per-call buttons: Mark Spam / Mark Legit / Block Number (each writes an `AuditLog` entry).
- **Contacts** — CRUD for caller records; `whitelisted` / `blacklisted` flags; auto-created on every inbound call.
- **Rules** — prefix / regex / keyword rules with allow / block actions, priority ordering, hit-count tracking. Regex rules are validated for ReDoS at save time and bounded to 1s match time globally.
- **Settings** — operator-tunable values (greeting voice/language/text, voicemail prompt, spam sensitivity, max recording length, retention windows). All writes go through per-key validators; bad values surface as flash alerts.

---

## Operations runbook

| Symptom | Where to look |
|---|---|
| Webhook returning 401 | `Telnyx-Signature-Ed25519` header missing or `TELNYX_PUBLIC_KEY` wrong; OR (fallback path) `?token=` mismatch with `WEBHOOK_TOKEN`. Check `bin/rails log:tail` for the request_id. |
| Voicemails not being transcribed | Check `SOLID_QUEUE_IN_PUMA=1` is set in the deployed container, then `bin/rails callscreen:purge_failed_jobs` after fixing whatever raised. |
| ntfy not firing | Check the consecutive-failure warning in logs; verify `NTFY_URL` is reachable from the container. |
| OpenRouter rate-limited | Falls back gracefully to "uncertain" classification → caller is sent to voicemail. No action needed unless this is sustained. |
| Stuck call stuck in `screening` status | Likely the `/telnyx/screen` callback never arrived. Check Telnyx dashboard logs for the call SID. |
| Disk filling up | `auto_delete_days` cleanup not running; check Solid Queue dashboard or run `CleanupRecordingsJob.new.perform` manually. |

---

## Useful rake tasks

```bash
bin/rails callscreen:rotate_webhook_token             # generate a fresh token
bin/rails callscreen:reclassify[CALL_ID]              # re-run SpamClassifier on stored transcript
bin/rails callscreen:purge_failed_jobs                # clear failed Solid Queue jobs
```

---

## Architecture notes

- **No Redis, no Sidekiq.** Solid Queue runs in the same Puma process via the `solid_queue` plugin (gated by `SOLID_QUEUE_IN_PUMA=1`). The queue lives in a separate SQLite database (`storage/production_queue.sqlite3`).
- **Rate limits.** Rack::Attack throttles `/telnyx/*` at 60 req/min/IP and `/admin/login` at 10 req/5min by IP and 5 req/20min by email.
- **Webhook auth.** Ed25519 signatures with 5-minute timestamp drift; legacy `?token=` query string is a cutover fallback gated by `WEBHOOK_TOKEN_FALLBACK`.
- **PII filter.** `config/initializers/filter_parameter_logging.rb` masks `From`, `To`, `CallSid`, `SpeechResult`, `RecordingUrl`, `phone`, `transcript`, `screening_transcript`, `voicemail_transcript`, `name` in Rails logs; the Sentry initializer applies the same set to event payloads.
- **TeXML rendering.** All TeXML responses are built with `Nokogiri::XML::Builder`; attribute values from Settings are properly XML-escaped.
- **Recordings on disk.** Stored at `Rails.root/storage/recordings/<call_sid>.wav`. The `call_sid` is regex-validated at webhook entry (`/\A[A-Za-z0-9_-]{1,64}\z/`); `RecordingsController` only serves files whose name matches the same pattern, regardless of what's in `recording_local_path`.

---

## Testing

```bash
bin/rails db:test:prepare
bin/rails test                                # full suite
bin/rails test test/services/                 # only service tests
bin/rails test test/controllers/telnyx_controller_test.rb -n test_rejects_voice_webhook_with_malformed_CallSid
```

WebMock disables real network calls. Fixtures live in `test/fixtures/`. Admin users are created in test setup blocks rather than fixtures because Devise password hashing is awkward in YAML.

---

## License

Private project, no license.
