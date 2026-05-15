# Atlas Dashboard Mobile Workflow

Status: active local workflow
Last updated: 2026-05-12

## Purpose

This repo can receive mobile/Codex work through the Atlas CLI listener in the
main `Atlas` repo.

Use this workflow for website tasks that should be queued from mobile ChatGPT
and handled later from desktop/Codex.

## Repository Roles

- `C:\Users\13142\Atlas\Atlas` owns model runs, listener execution, dashboard
  payload generation, and publish automation.
- `C:\Users\13142\Atlas\atlas-dashboard` owns the website, Cloudflare Pages
  functions, public assets, checkout flow, and hosted dashboard files.

## Listener Entry Point

Run from the main Atlas repo:

```powershell
cd C:\Users\13142\Atlas\Atlas
.\scripts\automation\atlas_cli_listener.ps1 listen
```

Process queued tasks once:

```powershell
.\scripts\automation\atlas_cli_listener.ps1 once
```

## Dashboard Task Examples

Create a website Codex handoff:

```powershell
.\scripts\automation\atlas_cli_listener.ps1 submit codex_handoff --target-repo atlas-dashboard --prompt "Review the checkout page mobile timeout issue."
```

Check dashboard status:

```powershell
.\scripts\automation\atlas_cli_listener.ps1 submit dashboard_status --reason "mobile dashboard check"
.\scripts\automation\atlas_cli_listener.ps1 once
```

Publish Atlas dashboard payload:

```powershell
.\scripts\automation\atlas_cli_listener.ps1 submit publish_dashboard --reason "manual dashboard publish"
```

## Handoff Location

Dashboard-specific handoffs are written locally to:

```text
C:\Users\13142\Atlas\atlas-dashboard\.codex_handoffs
```

These files are local operator tasks. They should not be treated as deployed
website assets.

## Mobile Safe Operations

Allowed from mobile:

- create website/Codex handoffs
- request status checks
- ask for architecture review
- ask for PR or file review
- queue publish after a validated model run

Avoid from mobile:

- large checkout rewrites without desktop review
- secrets or payment configuration changes
- Cloudflare binding changes
- destructive git operations
- production publish without checking generated payloads

