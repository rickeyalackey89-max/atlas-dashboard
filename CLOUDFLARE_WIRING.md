# Atlas → AtlasDashboard → Cloudflare Wiring

## What exists where

### Atlas NBA (engine workspace)
Runs the model, writes CSV outputs and dashboard JSON exports.

Key outputs:
- Latest CSVs (placeable):
  - C:\Users\13142\Atlas\NBA\data\output\latest\all\System\recommended_{3,4,5}leg.csv
  - C:\Users\13142\Atlas\NBA\data\output\latest\all\Windfall\recommended_{3,4,5}leg.csv

- Dashboard export JSONs (written by run_today_and_export.ps1):
  - C:\Users\13142\Atlas\NBA\data\output\dashboard\cloudflare_payload.json
  - C:\Users\13142\Atlas\NBA\data\output\dashboard\status_latest.json
  - C:\Users\13142\Atlas\NBA\data\output\dashboard\invalidations_latest.json
  - (optional) C:\Users\13142\Atlas\NBA\data\output\dashboard\recommended_gamescript_latest.json

- Last-5 audit file (written by refresh_nba_gamelogs.py):
  - C:\Users\13142\Atlas\NBA\data\gamelogs\audit_last5_board.csv

### AtlasDashboard (git repo, Cloudflare serves this)
Publishes JSON to:
- C:\Users\13142\Atlas\atlas-dashboard\public\data\
- C:\Users\13142\Atlas\atlas-dashboard\public\data\mlb\

Cloudflare serves:
- /data/status_latest.json
- /data/invalidations_latest.json
- /data/picks_today.json                       (public homepage preview)
- /data/mlb/picks_today.json                  (public MLB homepage preview)
- /api/premium-data?dataset=dashboard&sport=nba (authenticated premium dashboard payload)
- /api/premium-data?dataset=dashboard&sport=mlb (authenticated MLB dashboard payload)
- /data/cloudflare_payload.json                (compatibility fallback only until KV is configured)

Premium dashboard JSON should live in Cloudflare KV, not as a public file. The
Pages Function `/api/premium-data` checks the signed Atlas premium token, applies
rate limiting/logging when `ATLAS_SECURITY_KV` is bound, watermarks the payload,
and then reads `premium:<sport>:dashboard:latest` from `ATLAS_PREMIUM_KV`.

## The two commands (canonical)

### 1) Run Atlas + export dashboard artifacts
Run from Atlas:
cd C:\Users\13142\Atlas\NBA
py -m Atlas.cli live

This refreshes:
- gamelogs + audit_last5_board.csv
- injury report + status_latest.json
- external_priors_today.csv
- model run + latest/ folders
- dashboard JSON exports

### 2) Publish to Cloudflare (commit + push)
Run from AtlasDashboard:
cd C:\Users\13142\Atlas\atlas-dashboard
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-atlas.ps1 -AtlasRoot C:\Users\13142\Atlas\NBA

This does:
- Stage build into `.publish_stage/` outside the public Cloudflare directory
- Copy public preview/status files → public/data/
- If `ATLAS_PREMIUM_KV_NAMESPACE_ID` is set, upload the full premium payload to KV
  and publish only a public stub at `/data/cloudflare_payload.json`
- Validate JSON
- git add + commit + push public/data only when staged `public/data` changed

### Required Cloudflare bindings/secrets

Pages environment variables:
- `SECRET_TOKEN` - required for premium token signing/verification.
- `STRIPE_SECRET_KEY` - required for login/subscription verification.
- `TURNSTILE_LOGIN_SECRET` - required when login Turnstile verification is enabled.
- `TURNSTILE_CHECKOUT_SECRET` - required when checkout Turnstile verification is enabled.
- `ATLAS_PREMIUM_RATE_LIMIT_PER_MINUTE` - optional, defaults to 120.

Pages KV bindings:
- `ATLAS_PREMIUM_KV` - stores private premium payloads.
- `ATLAS_SECURITY_KV` - stores rate-limit counters, canary hits, and security events.

The publisher reads the `ATLAS_PREMIUM_KV` namespace id from `wrangler.toml`.
You can override it with `ATLAS_PREMIUM_KV_NAMESPACE_ID` if needed.

Example:
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-atlas.ps1 -AtlasRoot C:\Users\13142\Atlas\NBA
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-atlas.ps1 -Sport mlb -AtlasRoot C:\Users\13142\Atlas\MLB
```

The 6am evaluation automation is registered from the umbrella Atlas root:
```
C:\Users\13142\Atlas\run-6am-eval-and-publish.cmd -ContinueOnError
```

That wrapper runs prior-day evals for both NBA and MLB, rebuilds the sport
dashboard payloads, then calls `publish-atlas.ps1` for `nba` and `mlb`.

Live automation also publishes current live payloads. MLB live refreshes are
scheduled at 11:00 AM with NBA, then MLB-only at 1:30 PM, 4:30 PM, and 7:30 PM
Central. NBA also has a first-tip runner registered from the umbrella root that
fetches a fresh board and runs NBA live about 20 minutes before the first game.
Eval automation is for prior-day performance results; it should not overwrite a
current live slate with historical board data.

Use `-ForcePublicPremiumPayload` only as a temporary fallback if the KV binding is
not ready and the dashboard must keep loading the old public payload.

Security files:
- `public\.well-known\security.txt` is published as
  `https://atlassports.ai/.well-known/security.txt`.

## What publish-atlas.ps1 builds

### Public homepage preview (`picks_today.json`)

`publish-atlas.ps1` writes one small public preview file per sport:

- NBA: `public/data/picks_today.json`
- MLB: `public/data/mlb/picks_today.json`

Each sport preview is intentionally limited. It starts with one candidate from
each tier (`GOBLIN`, `STANDARD`, `DEMON`) when available and avoids repeating a
player in that sport's top preview rows.

The landing page then combines NBA and MLB preview files and selects the final
three public cards:

- one Goblin / below-alt;
- one Standard;
- one Demon / above-alt.

The landing page ranks within each required tier by calibrated probability and
skips any candidate whose player already appeared in the other selected cards.
That means Today's Picks is a balanced cross-sport preview, not a raw top-three
probability list.

### System feed (recommended_latest.json)
Built from:
Atlas\data\output\latest\all\System\recommended_{3,4,5}leg.csv

Output schema (array):
[
  {
    "product":"System",
    "n_legs":3,
    "legs":"... | ... | ...",
    "legs_detail":[{ "raw":"...", "last5_val":12.4, "last5_minutes":29.2 }, ...],
    "ev_mult":"...",
    "hit_prob":"..."
  },
  ...
]

### Windfall feed (recommended_windfall_latest.json)
Built from:
Atlas\data\output\latest\all\Windfall\recommended_{3,4,5}leg.csv

### Last-5 enrichment
publish-atlas.ps1 enriches legs_detail using:
Atlas\data\gamelogs\audit_last5_board.csv

Audit columns:
board_player,resolved_player,resolution_method,team,latest_game_date,last5_minutes,last5_pts,last5_reb,last5_ast,last5_fg3m,note

Mapping rules:
- PTS -> last5_pts
- REB -> last5_reb
- AST -> last5_ast
- FG3M -> last5_fg3m
- PR  -> last5_pts + last5_reb
- PA  -> last5_pts + last5_ast
- RA  -> last5_reb + last5_ast
- PRA -> last5_pts + last5_reb + last5_ast

The UI displays last5_val.
