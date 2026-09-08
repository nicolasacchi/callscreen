# Security policy

Callscreen is a **self-hosted** Rails app. There is no hosted multi-tenant
service and no SaaS. This policy covers the code, not a hosted product.

## Supported versions

Security fixes target **`main`**. There is no long-term-support branch.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting
on this repository: **Security tab → Report a vulnerability**. That opens a
private advisory thread with the maintainers before anything is public. There
is no security email address — the GitHub flow is the only reporting channel.

Include: description, affected path (webhook, ntfy token, recordings,
inspector, admin), repro, and commit SHA. **Redact caller phone numbers,
recordings, and transcripts.**

There is no bug bounty and no SLA. Reports will be acknowledged and, with
your permission, credited in the fix commit.

## In scope

- Bypassing Telnyx Ed25519, synthetic-token, or ntfy action-token checks
- Cross-tenant read/write, including `/e2e/*` inspector endpoints when the
  synthetic token is set
- SSRF via recording URLs or tenant-controlled `ntfy_url`
- Path traversal on greeting or recording file serving

## Out of scope

- Issues that require `SYNTHETIC_WEBHOOK_TOKEN` set on a production deploy
  (that token is opt-in; production should leave it unset)
- Social engineering of the operator's ntfy topic or Telnyx account
