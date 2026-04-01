# Atlas → AtlasDashboard → Cloudflare Wiring

## What exists where

### Atlas (engine workspace, NOT a git repo)
Runs the model, writes CSV outputs and dashboard JSON exports.

Key outputs:
- Latest CSVs (placeable):
  - C:\Users\rick\projects\Atlas\data\output\latest\all\System\recommended_{3,4,5}leg.csv
  - C:\Users\rick\projects\Atlas\data\output\latest\all\Windfall\recommended_{3,4,5}leg.csv

- Dashboard export JSONs (written by run_today_and_export.ps1):
  - C:\Users\rick\projects\Atlas\data\output\dashboard\status_latest.json
  - C:\Users\rick\projects\Atlas\data\output\dashboard\invalidations_latest.json
  - (optional) C:\Users\rick\projects\Atlas\data\output\dashboard\recommended_gamescript_latest.json

- Last-5 audit file (written by refresh_nba_gamelogs.py):
  - C:\Users\rick\projects\Atlas\data\gamelogs\audit_last5_board.csv

### AtlasDashboard (git repo, Cloudflare serves this)
Publishes JSON to:
- C:\Users\rick\projects\AtlasDashboard\public\data\

Cloudflare serves:
- /data/status_latest.json
- /data/invalidations_latest.json
- /data/recommended_latest.json                (System feed; built from CSV)
- /data/recommended_windfall_latest.json       (Windfall feed; built from CSV)
- /data/recommended_gamescript_latest.json     (GameScript feed; empty if not exported)
- /data/recommended_risky*_latest.json         (placeholders; empty arrays)

## The two commands (canonical)

### 1) Run Atlas + export dashboard artifacts
Run from Atlas:
powershell -NoProfile -ExecutionPolicy Bypass -File .\run_today_and_export.ps1

This refreshes:
- gamelogs + audit_last5_board.csv
- injury report + status_latest.json
- external_priors_today.csv
- model run + latest/ folders
- dashboard JSON exports

### 2) Publish to Cloudflare (commit + push)
Run from AtlasDashboard:
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-atlas.ps1

This does:
- Stage build into public/data_stage/
- Copy stage → public/data/
- Validate JSON
- git add + commit + push public/data

## What publish-atlas.ps1 builds

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