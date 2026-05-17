#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from urllib import error, parse, request

API_ROOT = "https://api.github.com"
REPO = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GITHUB_TOKEN"]
DEFAULT_ASSIGNEE = os.environ.get("ROUTER_ASSIGNEE", "rickeyalackey89-max")
REPO_KIND = os.environ.get("REPO_KIND", "generic").lower()
EVENT_PATH = os.environ["GITHUB_EVENT_PATH"]

LABELS = {
    "codex": ("5319E7", "Work item intended for Codex handling"),
    "codex:primary": ("0E8A16", "Route to the primary Codex lane"),
    "codex:5.3-spark": ("1D76DB", "Route to the GPT-5.3 Codex Spark lane"),
    "assigned:codex-primary": ("0E8A16", "Explicitly assigned to the primary Codex lane"),
    "assigned:codex-spark": ("1D76DB", "Explicitly assigned to the GPT-5.3 Codex Spark lane"),
    "needs-triage": ("FBCA04", "Needs owner or priority triage"),
    "support": ("D4C5F9", "Support-reported issue"),
    "area:auth": ("C5DEF5", "Authentication or login area"),
    "priority:high": ("B60205", "High priority"),
}

LANE_LABELS = {
    "primary": ["codex", "codex:primary", "assigned:codex-primary", "needs-triage"],
    "spark": ["codex", "codex:5.3-spark", "assigned:codex-spark", "needs-triage"],
}

OPPOSITE_LABELS = {
    "primary": ["codex:5.3-spark", "assigned:codex-spark"],
    "spark": ["codex:primary", "assigned:codex-primary"],
}

AMBASSADOR_SUPPORT_WORDS = (
    "approval",
    "applicant",
    "application",
    "auth",
    "login",
    "onboarding",
    "password",
    "portal",
    "referral",
    "sponsor",
)


def gh(method: str, path: str, payload: dict | None = None, allowed: tuple[int, ...] = (200, 201, 204)):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    req = request.Request(
        f"{API_ROOT}{path}",
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw) if raw else None
            return resp.status, data
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        if exc.code in allowed:
            data = json.loads(raw) if raw else None
            return exc.code, data
        raise SystemExit(f"GitHub API {method} {path} failed with {exc.code}: {raw}") from exc


def load_event() -> dict:
    with open(EVENT_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def normalize_lane(value: str | None) -> str:
    text = (value or "").strip().lower()
    if text in {"primary", "primary codex", "codex:primary", "assigned:codex-primary"}:
        return "primary"
    if text in {"spark", "5.3 spark", "5.3spark", "codex spark", "codex:5.3-spark", "assigned:codex-spark"}:
        return "spark"
    return ""


def looks_like_ambassador_support(text: str) -> bool:
    lower = text.lower()
    return REPO_KIND == "ambassador" and any(word in lower for word in AMBASSADOR_SUPPORT_WORDS)


def infer_lane(text: str, explicit_lane: str | None = None) -> str:
    explicit = normalize_lane(explicit_lane)
    if explicit:
        return explicit

    lower = text.lower()
    primary_markers = (
        "codex:primary",
        "assigned:codex-primary",
        "[codex primary]",
        "codex primary",
        "codex lane: primary",
        "primary codex",
        "/codex-primary",
    )
    spark_markers = (
        "codex:5.3-spark",
        "assigned:codex-spark",
        "[codex spark]",
        "codex spark",
        "codex lane: 5.3 spark",
        "5.3 spark",
        "5.3spark",
        "/codex-spark",
    )

    if any(marker in lower for marker in primary_markers):
        return "primary"
    if any(marker in lower for marker in spark_markers):
        return "spark"
    if looks_like_ambassador_support(text):
        return "spark"
    return ""


def labels_for(lane: str, text: str, extra_labels: str = "") -> list[str]:
    labels = list(LANE_LABELS[lane])
    if looks_like_ambassador_support(text):
        labels.extend(["support", "area:auth", "priority:high"])
    for label in extra_labels.split(","):
        clean = label.strip()
        if clean:
            labels.append(clean)
    return sorted(set(labels))


def ensure_label(name: str) -> None:
    encoded = parse.quote(name, safe="")
    status, _ = gh("GET", f"/repos/{REPO}/labels/{encoded}", allowed=(200, 404))
    if status == 200:
        return
    color, description = LABELS.get(name, ("BFDADC", "Created by Codex issue router"))
    gh("POST", f"/repos/{REPO}/labels", {"name": name, "color": color, "description": description}, allowed=(201, 422))


def apply_route(issue_number: int, lane: str, labels: list[str], assignee: str) -> None:
    for label in labels:
        ensure_label(label)
    gh("POST", f"/repos/{REPO}/issues/{issue_number}/labels", {"labels": labels})
    for label in OPPOSITE_LABELS[lane]:
        encoded = parse.quote(label, safe="")
        gh("DELETE", f"/repos/{REPO}/issues/{issue_number}/labels/{encoded}", allowed=(200, 204, 404))
    if assignee:
        gh("POST", f"/repos/{REPO}/issues/{issue_number}/assignees", {"assignees": [assignee]}, allowed=(200, 201, 422))
    print(f"Routed issue #{issue_number} to {lane}: {', '.join(labels)}")


def create_routed_issue(event: dict) -> None:
    inputs = event.get("inputs", {})
    title = inputs.get("title") or "[Codex Spark]: "
    body = inputs.get("body") or "No body provided."
    lane = infer_lane(f"{title}\n{body}", inputs.get("lane")) or "spark"
    assignee = inputs.get("assignee") or DEFAULT_ASSIGNEE
    labels = labels_for(lane, f"{title}\n{body}", inputs.get("labels", ""))
    for label in labels:
        ensure_label(label)
    lane_name = "Primary Codex" if lane == "primary" else "5.3 Spark"
    full_body = f"{body.rstrip()}\n\n---\nCodex Lane: {lane_name}\nCreated by the Codex Issue Router workflow."
    _, issue = gh(
        "POST",
        f"/repos/{REPO}/issues",
        {"title": title, "body": full_body, "labels": labels, "assignees": [assignee] if assignee else []},
    )
    print(f"Created routed issue #{issue['number']}: {issue['html_url']}")


def route_existing_issue(event: dict) -> None:
    issue = event.get("issue") or {}
    issue_number = issue.get("number")
    if not issue_number:
        print("No issue payload found; nothing to route.")
        return
    if "pull_request" in issue:
        print(f"#{issue_number} is a pull request; leaving it unchanged.")
        return
    comment = event.get("comment") or {}
    text = "\n".join(
        [
            issue.get("title") or "",
            issue.get("body") or "",
            comment.get("body") or "",
        ]
    )
    lane = infer_lane(text)
    if not lane:
        print(f"No Codex lane detected for issue #{issue_number}; leaving it unchanged.")
        return
    labels = labels_for(lane, text)
    apply_route(int(issue_number), lane, labels, DEFAULT_ASSIGNEE)


def main() -> None:
    event = load_event()
    if "inputs" in event:
        create_routed_issue(event)
    else:
        route_existing_issue(event)


if __name__ == "__main__":
    main()
