# Premium Data Security

Atlas public pages can stay static, but premium model payloads should not be
served from public JSON paths. The current secure path is:

1. Model writes `cloudflare_payload.json` locally.
2. `publish-atlas.ps1` writes public preview data to `public/data/picks_today.json`.
3. When `ATLAS_PREMIUM_KV_NAMESPACE_ID` is configured, the full premium payload is
   uploaded to Cloudflare KV at `premium:nba:dashboard:latest`.
4. Dashboard, Members, and Parlay Builder call:
   `/api/premium-data?dataset=dashboard&sport=nba`
5. The Pages Function verifies the signed premium token, rate-limits/logs the
   request when `ATLAS_SECURITY_KV` is bound, watermarks the response, and returns
   the premium payload.

## Cloudflare Bindings

Create two KV namespaces and bind them to the Pages project:

- `ATLAS_PREMIUM_KV` - private premium payload storage.
- `ATLAS_SECURITY_KV` - rate-limit counters, canary hits, and suspicious request logs.

Set these Pages environment variables:

- `SECRET_TOKEN`
- `STRIPE_SECRET_KEY`
- `ATLAS_PREMIUM_RATE_LIMIT_PER_MINUTE` is configured in `wrangler.toml` and defaults to `120`.

The publisher reads the `ATLAS_PREMIUM_KV` namespace id from `wrangler.toml`.
You can override it with `ATLAS_PREMIUM_KV_NAMESPACE_ID` if needed.

Then publish with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-atlas.ps1 -AtlasRoot C:\Users\13142\Atlas\NBA
```

If the KV namespace id is missing, the publisher keeps the old public premium JSON
as a compatibility fallback and prints a warning. That fallback should be removed
after the Cloudflare binding is live.

## Protections In Repo

- `/api/premium-data` requires a valid Atlas premium token.
- Premium responses use `Cache-Control: private, no-store`.
- Premium responses include `X-Robots-Tag: noindex, nofollow, noai, noimageai`.
- Each response has a top-level `_atlas_security.watermark_id`.
- Slips and all-legs rows receive `atlas_watermark`.
- `_atlas_security.canary_url` points to `/api/canary`.
- `/api/canary` records the fingerprint/watermark and blocks future premium access
  from that fingerprint when `ATLAS_SECURITY_KV` is bound.
- `robots.txt` blocks `/api/`, `/data/`, `/dashboard/`, `/members/`, and common AI
  crawlers. This is advisory only; the API gate is the real protection.

## Cloudflare Dashboard Settings

Recommended rollout order:

1. Enable WAF managed rules and basic bot protection.
2. Enable Cloudflare AI bot blocking for public content protection.
3. Add Turnstile to login/checkout forms if bot pressure appears.
4. Add Cloudflare rate-limit rules for `/api/*`, especially `/api/premium-data`.
5. Upgrade to Super Bot Fight Mode if false positives or scrape pressure increase.
