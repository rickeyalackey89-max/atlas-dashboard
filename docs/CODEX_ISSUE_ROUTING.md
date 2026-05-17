# Codex Issue Routing

Use GitHub issues to route dashboard work to either the primary Codex lane or the 5.3 Spark lane.

## Lanes

- `codex:primary`: production-sensitive dashboard publishing, payload contracts, Cloudflare behavior, or cross-repo work.
- `codex:5.3-spark`: isolated UI bugs, docs, tests, small graphics/tooling fixes, and work that should not interrupt the primary Codex session.

## Chat Invocation Examples

```text
Create a GitHub issue in rickeyalackey89-max/atlas-dashboard titled "[Codex Spark]: Fix X".
Use labels codex, codex:5.3-spark, assigned:codex-spark, needs-triage.
Assign it to rickeyalackey89-max.
Body: problem, reproduction steps, expected behavior, acceptance criteria.
```

```text
Create a GitHub issue in rickeyalackey89-max/atlas-dashboard titled "[Codex Primary]: Investigate X".
Use labels codex, codex:primary, assigned:codex-primary, needs-triage.
Assign it to rickeyalackey89-max.
```

Every routed issue should include problem, reproduction/evidence, expected behavior, acceptance criteria, target lane, and a GitHub assignee when a human owner should be notified.
