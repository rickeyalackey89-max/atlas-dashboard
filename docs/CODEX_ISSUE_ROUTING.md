# Codex Issue Routing

Use GitHub issues to route dashboard work to either the primary Codex lane or the 5.3 Spark lane.

## Lanes

- `codex:primary`: production-sensitive dashboard publishing, payload contracts, Cloudflare behavior, or cross-repo work.
- `codex:5.3-spark`: isolated UI bugs, docs, tests, small graphics/tooling fixes, and work that should not interrupt the primary Codex session.

## Chat Invocation Examples

```text
Create a GitHub issue in rickeyalackey89-max/atlas-dashboard titled "[Codex Spark]: Fix X".
Set Codex Lane to 5.3 Spark.
Use labels codex, codex:5.3-spark, assigned:codex-spark, needs-triage.
Assign it to rickeyalackey89-max.
Body: problem, reproduction steps, expected behavior, acceptance criteria.
```

```text
Create a GitHub issue in rickeyalackey89-max/atlas-dashboard titled "[Codex Primary]: Investigate X".
Set Codex Lane to Primary Codex.
Use labels codex, codex:primary, assigned:codex-primary, needs-triage.
Assign it to rickeyalackey89-max.
```

## Write Bridge Fallback

If Chat can create a plain issue but labels or assignees do not persist, include one of these in the issue title, body, or a comment:

```text
Codex Lane: 5.3 Spark
```

```text
@codex please implement this using 5.3 Spark.
```

The `Codex Issue Router` GitHub Action will add the lane labels and assign `rickeyalackey89-max`.

If Chat cannot create an issue at all, open GitHub Actions, run `Codex Issue Router`, and fill in the title, body, lane, labels, and assignee inputs. The workflow will create the routed issue directly from GitHub.

Every routed issue should include problem, reproduction/evidence, expected behavior, acceptance criteria, Codex Lane, target label lane, and a GitHub assignee when a human owner should be notified.
