#!/usr/bin/env python3
"""Build the atlassports.ai WNBA dashboard payload from one audited Live run.

The public dashboard must mirror the actual WNBA Live surface.  This builder
therefore reads the published runtime pointer, fails closed on a failed audit,
exports only source-playable board sides, and never invents an alternate-tier
UNDER selection.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


TEAM_NAMES = {
    "ATL": "Atlanta Dream",
    "CHI": "Chicago Sky",
    "CON": "Connecticut Sun",
    "DAL": "Dallas Wings",
    "GS": "Golden State Valkyries",
    "IND": "Indiana Fever",
    "LA": "Los Angeles Sparks",
    "LV": "Las Vegas Aces",
    "MIN": "Minnesota Lynx",
    "NY": "New York Liberty",
    "PHX": "Phoenix Mercury",
    "POR": "Portland Fire",
    "SEA": "Seattle Storm",
    "TOR": "Toronto Tempo",
    "WSH": "Washington Mystics",
}

MARKET_LABELS = {
    "3_pt_attempted": "3-Point Attempts",
    "3_pt_made": "3-Pointers Made",
    "3_pt_made_combo": "3-Pointers Made",
    "assists": "Assists",
    "assists_combo": "Assists",
    "blocks": "Blocks",
    "blks_stls": "Blocks + Steals",
    "defensive_rebounds": "Defensive Rebounds",
    "fantasy_score": "Fantasy Score",
    "fg_attempted": "Field Goals Attempted",
    "fg_made": "Field Goals Made",
    "free_throws_attempted": "Free Throws Attempted",
    "free_throws_made": "Free Throws Made",
    "offensive_rebounds": "Offensive Rebounds",
    "points": "Points",
    "points_assists": "Points + Assists",
    "points_rebounds": "Points + Rebounds",
    "points_rebounds_assists": "Points + Rebounds + Assists",
    "rebounds": "Rebounds",
    "rebounds_assists": "Rebounds + Assists",
    "steals": "Steals",
    "turnovers": "Turnovers",
    "two_pointers_attempted": "2-Point Attempts",
    "two_pointers_made": "2-Pointers Made",
}


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    return value if isinstance(value, dict) else {}


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def _truthy(value: Any) -> bool:
    return value is True or str(value or "").strip().lower() in {"1", "true", "yes"}


def _float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _int(value: Any) -> int | None:
    number = _float(value)
    return int(number) if number is not None else None


def _split(value: Any) -> list[str]:
    return [item.strip() for item in str(value or "").split(";") if item.strip()]


def _norm_player(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    return re.sub(r"[^a-z0-9]", "", text.encode("ascii", "ignore").decode().lower())


def _market_label(value: Any) -> str:
    key = str(value or "").strip().lower()
    return MARKET_LABELS.get(key, key.replace("_", " ").title())


def _path(value: Any, root: Path) -> Path | None:
    if not value:
        return None
    candidate = Path(str(value))
    return candidate if candidate.is_absolute() else root / candidate


def _latest_live_run(wnba_root: Path) -> Path:
    latest_path = wnba_root / "data" / "wnba" / "runtime_state" / "live" / "latest_manifest.json"
    latest = _read_json(latest_path)
    run_dir = _path(latest.get("run_dir"), wnba_root)
    if run_dir is None:
        run_id = str(latest.get("run_id") or "")
        if not run_id:
            raise RuntimeError(f"Published WNBA Live pointer has no run_id: {latest_path}")
        run_dir = wnba_root / "data" / "wnba" / "live_runs" / run_id
    return run_dir.resolve()


def _validate_live_run(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest_path = run_dir / "run_manifest.json"
    audit_path = run_dir / "live_audit.json"
    manifest = _read_json(manifest_path)
    audit = _read_json(audit_path)
    blockers: list[str] = []
    if not manifest:
        blockers.append("missing_run_manifest")
    if manifest.get("run_mode") != "live":
        blockers.append("run_mode_not_live")
    if not _truthy((manifest.get("live_audit") or {}).get("ok")):
        blockers.append("manifest_live_audit_not_ok")
    if not _truthy((manifest.get("runtime_publication") or {}).get("published")):
        blockers.append("runtime_pointer_not_published")
    if not _truthy(audit.get("ok")) or int(audit.get("fail_count") or 0) != 0:
        blockers.append("live_audit_failed")
    if blockers:
        raise RuntimeError(f"WNBA dashboard refuses non-publishable Live run {run_dir.name}: {','.join(blockers)}")
    return manifest, audit


def _external_market_index(paths: Iterable[Path]) -> dict[tuple[str, str, float], dict[str, Any]]:
    index: dict[tuple[str, str, float], dict[str, Any]] = {}
    for path in paths:
        lower = str(path).lower()
        if "pick6" in lower or not path.exists():
            continue
        with path.open("r", encoding="utf-8-sig") as handle:
            for raw in handle:
                if not raw.strip():
                    continue
                row = json.loads(raw)
                line = _float(row.get("line"))
                if line is None:
                    continue
                key = (_norm_player(row.get("player_norm") or row.get("player_name")), str(row.get("market") or "").lower(), line)
                target = index.setdefault(key, {"sources": []})
                source = str(row.get("source") or "")
                if source and source not in target["sources"]:
                    target["sources"].append(source)
                for book in row.get("books") or []:
                    book_key = str(book.get("book_key") or "").lower()
                    prefix = "dk" if book_key == "draftkings" else "fd" if book_key == "fanduel" else ""
                    if not prefix:
                        continue
                    over_price = _float(book.get("over_price"))
                    under_price = _float(book.get("under_price"))
                    if over_price not in {None, 0.0}:
                        target[f"{prefix}_over"] = int(over_price)
                    if under_price not in {None, 0.0}:
                        target[f"{prefix}_under"] = int(under_price)
                    over_prob = _float(book.get("over_prob"))
                    under_prob = _float(book.get("under_prob"))
                    if over_prob is not None:
                        target[f"{prefix}_imp_over"] = over_prob
                    if under_prob is not None:
                        target[f"{prefix}_imp_under"] = under_prob
    return index


def _leg_from_card(row: dict[str, str], market_index: dict[tuple[str, str, float], dict[str, Any]]) -> dict[str, Any]:
    tier = str(row.get("tier") or "STANDARD").upper()
    side = str(row.get("side") or "").upper()
    if tier in {"DEMON", "GOBLIN"} and side != "OVER":
        raise RuntimeError(f"Illegal playable WNBA dashboard road: {tier}:{side}")
    line = _float(row.get("line"))
    probability = _float(row.get("final_probability"))
    projection = _float(row.get("expected_stat"))
    projection_delta = projection - line if projection is not None and line is not None else None
    side_delta = -projection_delta if side == "UNDER" and projection_delta is not None else projection_delta
    l10 = _float(row.get("recent_last_10_hit_rate"))
    l20 = _float(row.get("recent_last_20_hit_rate"))
    l10_decisions = _int(row.get("recent_last_10_decisions")) or 0
    l10_complete = str(row.get("recent_last_10_complete") or "").strip().lower()
    l10_n = 10 if l10_decisions == 10 and l10_complete in {"1", "true", "yes"} else 0
    if l10_n != 10:
        l10 = None
    l20_n = min(20, _int(row.get("recent_last_20_decisions")) or 0)
    current_minutes = _float(row.get("current_minutes"))
    prior_minutes = _float(row.get("recent_last_20_minutes_mean"))
    role_mult = current_minutes / prior_minutes if current_minutes is not None and prior_minutes and prior_minutes > 0 else None
    usage_pct = _float(row.get("usage"))
    if usage_pct is not None and usage_pct <= 1:
        usage_pct *= 100
    market_key = (_norm_player(row.get("player_name")), str(row.get("market") or "").lower(), line or 0.0)
    market = market_index.get(market_key, {})
    market_probs = [
        _float(market.get("dk_imp_under" if side == "UNDER" else "dk_imp_over")),
        _float(market.get("fd_imp_under" if side == "UNDER" else "fd_imp_over")),
    ]
    market_probs = [value for value in market_probs if value is not None]
    market_probability = sum(market_probs) / len(market_probs) if market_probs else None
    payout_modifier = 0.9 if tier == "GOBLIN" else 1.1 if tier == "DEMON" else 1.0
    raw_team = str(row.get("canonical_team_abbr") or "").upper()
    raw_opponent = str(row.get("opponent_abbr") or "").upper()
    team = raw_team if raw_team in TEAM_NAMES else ""
    opponent = raw_opponent if raw_opponent in TEAM_NAMES else ""
    leg: dict[str, Any] = {
        "id": row.get("source_scored_leg_id"),
        "builder_card_row_id": row.get("builder_card_row_id"),
        "sport": "WNBA",
        "player": row.get("player_name"),
        "team": team,
        "opp": opponent,
        "component_teams": raw_team if raw_team != team else "",
        "component_opponents": raw_opponent if raw_opponent != opponent else "",
        "game_id": row.get("game_id"),
        "game_date": row.get("game_date"),
        "start_time_utc": row.get("start_time_utc"),
        "market": row.get("market"),
        "stat": _market_label(row.get("market")),
        "line": line,
        "dir": side,
        "tier": tier,
        "p_cal": probability,
        "p_cal_marketed": probability,
        "model_probability": probability,
        "probability_edge": _float(row.get("probability_edge")),
        "payout_modifier": payout_modifier,
        "atlas_ev": probability * payout_modifier if probability is not None else None,
        "atlas_projection_mean": projection,
        "atlas_projection_median": projection,
        "atlas_projection_delta": projection_delta,
        "atlas_projection_side_delta": side_delta,
        "distribution_sd": _float(row.get("distribution_sd")),
        "distribution_family": row.get("distribution_family"),
        "l10_hr": l10,
        "l10_n": l10_n or None,
        "l20_hr": l20,
        "l20_n": l20_n or None,
        "fragility": _float(row.get("recent_stat_fragility")),
        "minute_volatility": _float(row.get("recent_minutes_fragility")),
        "usage_pct": usage_pct,
        "usage_score": usage_pct / 100 if usage_pct is not None else None,
        "role_mult": role_mult,
        "current_minutes": current_minutes,
        "minutes_mean": _float(row.get("minutes_mean")),
        "minutes_sd": _float(row.get("minutes_sd")),
        "starter_probability": _float(row.get("starter_probability")),
        "rotation_tier": row.get("rotation_tier"),
        "availability_state": row.get("availability_state"),
        "injury_status": row.get("injury_status"),
        "team_out_count": _int(row.get("team_out_count")),
        "pace": _float(row.get("environment_pace")),
        "opponent_def_rating": _float(row.get("opponent_def_rating")),
        "rest_days": _int(row.get("rest_days")),
        "side_playable": True,
        "board_side_contract": row.get("board_side_contract"),
        "source_decision_timestamp_utc": row.get("decision_timestamp_utc"),
        "source_board_snapshot_id": row.get("board_snapshot_id"),
        "external_market_context_available": bool(market_probability is not None),
        "external_prior_market_prob": market_probability,
        "market_context_source_type": "sportsbook" if market_probability is not None else "",
        "external_prior_sources": ",".join(market.get("sources") or []),
    }
    for key in ("dk_over", "dk_under", "dk_imp_over", "dk_imp_under", "fd_over", "fd_under", "fd_imp_over", "fd_imp_under"):
        if key in market:
            leg[key] = market[key]
    return leg


def _load_all_legs(run_dir: Path, market_index: dict[tuple[str, str, float], dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    builder_manifest = _read_json(run_dir / "builder_manifest.json")
    manifest_card_path = _path(builder_manifest.get("builder_card_path"), run_dir)
    card_paths = tuple(path for path in (
        manifest_card_path,
        run_dir / "builder_card" / "builder_card.csv",
        run_dir / "rc1_candidate_compiler" / "builder_card" / "builder_card.csv",
        run_dir / "atlas_candidate_compiler" / "builder_card" / "builder_card.csv",
    ) if path is not None)
    card_path = next((path for path in card_paths if path.is_file()), card_paths[0])
    rows = _read_csv(card_path)
    if not rows:
        raise RuntimeError(f"Missing Builder Card; checked: {', '.join(str(path) for path in card_paths)}")
    playable_rows = [
        row for row in rows
        if _truthy(row.get("side_playable")) and _truthy(row.get("probability_surface_eligible"))
    ]
    legs = [_leg_from_card(row, market_index) for row in playable_rows]
    if not legs:
        raise RuntimeError("WNBA Builder Card has no source-playable probability roads")
    legs.sort(key=lambda leg: (-(leg.get("p_cal") or 0), str(leg.get("player") or ""), str(leg.get("stat") or ""), leg.get("line") or 0))
    lookup: dict[str, dict[str, Any]] = {}
    for leg in legs:
        for key in (leg.get("id"), leg.get("builder_card_row_id")):
            if key:
                lookup[str(key)] = leg
    return legs, lookup


def _load_market_portfolio(run_dir: Path, lookup: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    builder_manifest = _read_json(run_dir / "builder_manifest.json")
    ledger_path = _path(builder_manifest.get("candidate_score_ledger_path"), run_dir)
    ledger = _read_json(ledger_path) if ledger_path is not None else {}
    scored_candidates: dict[str, dict[str, Any]] = {}
    for candidates in (ledger.get("families") or {}).values():
        for candidate in candidates or []:
            candidate_id = str(candidate.get("candidate_id") or "")
            if candidate_id:
                scored_candidates[candidate_id] = candidate
    output: list[dict[str, Any]] = []
    for size in (2, 3, 4):
        for row in _read_csv(run_dir / f"recommended_{size}leg.csv"):
            legs = [lookup[leg_id] for leg_id in _split(row.get("leg_ids")) if leg_id in lookup]
            if len(legs) != size:
                raise RuntimeError(f"WNBA {size}-leg dashboard slip cannot bind every legal Builder Card leg")
            scored = scored_candidates.get(str(row.get("candidate_id") or row.get("slip_id") or ""), {})
            raw_metrics = scored.get("raw_metrics") or {}
            hit_probability = _float(
                row.get("joint_strict_win_probability")
                or row.get("slip_probability")
                or raw_metrics.get("joint_qmc_probability")
            )
            expected_net = _float(
                row.get("expected_net_value_estimate")
                or raw_metrics.get("mean_EV")
            )
            expected_return = _float(row.get("expected_return_estimate"))
            if expected_return is None and expected_net is not None:
                expected_return = 1.0 + expected_net
            payout = _float(row.get("payout_multiplier_estimate"))
            if payout is None and hit_probability and expected_return is not None:
                payout = expected_return / hit_probability
            output.append({
                "slip_id": row.get("slip_id"),
                "family": "market_portfolio",
                "n_legs": size,
                "rank": _int(row.get("slip_rank")),
                "hit_prob": hit_probability,
                "payout_mult": payout,
                "ev": expected_return,
                "expected_net_value": expected_net,
                "atlas_slip_score": _float(row.get("atlas_slip_score") or scored.get("ATLAS_SLIP_SCORE")),
                "legs": legs,
                "legs_detail": legs,
            })
    return sorted(output, key=lambda slip: (slip.get("n_legs") or 0, slip.get("rank") or 0))


def _load_from_deep(run_dir: Path, lookup: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    picks: list[dict[str, Any]] = []
    for row in _read_csv(run_dir / "from_deep.csv"):
        key = str(row.get("builder_card_row_id") or row.get("source_scored_leg_id") or "")
        leg = lookup.get(key)
        if not leg:
            raise RuntimeError("From Deep pick cannot bind its legal Builder Card row")
        if leg.get("tier") != "DEMON" or leg.get("dir") != "OVER":
            raise RuntimeError("From Deep dashboard contract requires DEMON:OVER")
        picks.append({
            "slip_id": row.get("from_deep_id"),
            "family": "from_deep",
            "n_legs": 1,
            "rank": _int(row.get("rank")),
            "hit_prob": _float(row.get("final_probability")),
            "selection_reason": row.get("selection_reason"),
            "legs": [leg],
            "legs_detail": [leg],
        })
    return picks


def _top_hit_list(legs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    supported = [leg for leg in legs if leg.get("l10_n") == 10 and leg.get("l10_hr") is not None]
    supported.sort(key=lambda leg: (-(leg.get("l10_hr") or 0), -(leg.get("p_cal") or 0)))
    seen: set[tuple[Any, ...]] = set()
    output: list[dict[str, Any]] = []
    for leg in supported:
        key = (leg.get("player"), leg.get("stat"), leg.get("line"), leg.get("dir"))
        if key in seen:
            continue
        seen.add(key)
        output.append({name: leg.get(name) for name in ("sport", "player", "team", "opp", "stat", "line", "dir", "tier", "p_cal", "l10_hr", "l10_n")})
        if len(output) == 10:
            break
    return output


def _stat_hub(source_manifest: dict[str, Any], wnba_root: Path, legs: list[dict[str, Any]]) -> dict[str, Any]:
    resolved = source_manifest.get("resolved_sources") or {}
    rolling_path = _path(resolved.get("espn_rolling_path"), wnba_root)
    context_path = _path(resolved.get("game_context_path"), wnba_root)
    rolling = _read_csv(rolling_path) if rolling_path else []
    contexts = _read_csv(context_path) if context_path else []
    board_players = {_norm_player(leg.get("player")) for leg in legs}
    context_by_team = {str(row.get("team_abbr") or "").upper(): row for row in contexts}
    players_by_team: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for row in rolling:
        player_key = _norm_player(row.get("player_name"))
        team = str(row.get("team_abbr") or "").upper()
        if player_key not in board_players or not team:
            continue
        players_by_team[team][player_key] = {
            "player": row.get("player_name"),
            "team": team,
            "position": row.get("player_position"),
            "season": {
                "gp": _int(row.get("games_prior")),
                "min": _round(row.get("minutes_season_avg")),
                "pts": _round(row.get("points_season_avg")),
                "reb": _round(row.get("rebounds_season_avg")),
                "ast": _round(row.get("assists_season_avg")),
                "fg3m": _round(row.get("fg3m_season_avg")),
            },
        }
    teams: list[dict[str, Any]] = []
    for team in sorted({str(leg.get("team") or "").upper() for leg in legs if leg.get("team")}):
        context = context_by_team.get(team, {})
        opponent = str(context.get("opponent_abbr") or next((leg.get("opp") for leg in legs if leg.get("team") == team), "") or "")
        start = context.get("start_time_utc") or next((leg.get("start_time_utc") for leg in legs if leg.get("team") == team), "")
        teams.append({
            "team": team,
            "team_name": TEAM_NAMES.get(team, team),
            "opponents": [opponent] if opponent else [],
            "game_start_time": start,
            "game_time_label": _game_time_label(start),
            "players": sorted(players_by_team.get(team, {}).values(), key=lambda player: str(player.get("player") or "")),
        })
    return {"sport": "WNBA", "source": "espn_strict_prior_history", "playoff_active": False, "teams": teams}


def _round(value: Any, digits: int = 1) -> float | None:
    number = _float(value)
    return round(number, digits) if number is not None else None


def _game_time_label(value: Any) -> str:
    if not value:
        return ""
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed.astimezone().strftime("%I:%M %p").lstrip("0")
    except ValueError:
        return ""


def _injury_context(source_manifest: dict[str, Any], wnba_root: Path, selected_legs: list[dict[str, Any]], engagement: dict[str, Any]) -> dict[str, Any]:
    resolved = source_manifest.get("resolved_sources") or {}
    injury_path = _path(resolved.get("injury_matrix_path"), wnba_root)
    rows = _read_csv(injury_path) if injury_path else []
    invalidated: list[dict[str, Any]] = []
    questionable: list[dict[str, Any]] = []
    for row in rows:
        status = str(row.get("status") or "").upper()
        item = {"player": row.get("player"), "team": row.get("team"), "status": status, "reason": row.get("reason")}
        if status in {"OUT", "DOUBTFUL"}:
            invalidated.append(item)
        elif status in {"QUESTIONABLE", "PROBABLE"}:
            questionable.append(item)
    role_boosted: list[dict[str, Any]] = []
    seen: set[tuple[Any, Any]] = set()
    for leg in selected_legs:
        role = _float(leg.get("role_mult"))
        key = (leg.get("player"), leg.get("stat"))
        if role is None or abs(role - 1) < 0.005 or key in seen:
            continue
        seen.add(key)
        role_boosted.append({name: leg.get(name) for name in ("player", "team", "opp", "stat", "role_mult")})
    return {
        "invalidated_players": invalidated,
        "questionable_players": questionable,
        "role_boosted": role_boosted,
        "report_date": rows[0].get("report_date") if rows else None,
        "report_label": rows[0].get("report_label") if rows else None,
        **engagement,
    }


def _performance(wnba_root: Path) -> dict[str, Any]:
    summary = _read_json(wnba_root / "data" / "wnba" / "waterfall" / "latest_public_performance.json")
    if summary.get("version") != "wnba_public_performance_v1" or summary.get("status") != "complete":
        return {}
    source = summary.get("public") or {}

    def window(value: Any) -> dict[str, Any]:
        item = value if isinstance(value, dict) else {}
        count = int(item.get("n") or 0)
        rate = _float(item.get("hit_rate"))
        return {"hit_rate": rate if count else None, "n": count}

    overall_source = source.get("overall") or {}
    tier_source = source.get("by_tier") or {}
    slip_source = source.get("yesterday_slips") or {}
    slip_count = int(slip_source.get("total") or 0)
    slip_wins = int(slip_source.get("wins") or 0)
    slip_rate = _float(slip_source.get("pct")) if slip_count else None
    market_source = slip_source.get("market") or {}
    market_count = int(market_source.get("total") or 0)
    market_wins = int(market_source.get("wins") or 0)
    market_rate = _float(market_source.get("pct")) if market_count else None
    meta_source = source.get("meta") or {}
    return {
        "overall": {
            "last_7d": window(overall_source.get("last_7d")),
            "last_30d": window(overall_source.get("last_30d")),
        },
        "by_tier": {
            tier: {
                "last_7d": window((tier_source.get(tier) or {}).get("last_7d")),
                "last_30d": window((tier_source.get(tier) or {}).get("last_30d")),
            }
            for tier in ("GOBLIN", "STANDARD", "DEMON")
        },
        "yesterday_slips": {
            "date": str(slip_source.get("date") or "")[:10] or None,
            "wins": slip_wins,
            "total": slip_count,
            "pct": slip_rate,
            "market": {
                "wins": market_wins,
                "total": market_count,
                "pct": market_rate,
            },
        },
        "meta": {
            "sport": "WNBA",
            "eval_cadence": "3AM",
            "slip_sizes": [2, 3, 4],
            "latest_game_date": str(meta_source.get("latest_game_date") or "")[:10] or None,
        },
    }


def _engagement(manifest: dict[str, Any]) -> dict[str, Any]:
    engaged = manifest.get("created_at_ct") or manifest.get("created_at_utc") or manifest.get("decision_timestamp_utc")
    label = "WNBA model engaged"
    if engaged:
        try:
            dt = datetime.fromisoformat(str(engaged).replace("Z", "+00:00"))
            label = f"WNBA model engaged {dt.strftime('%b')} {dt.day} at {dt.strftime('%I:%M %p').lstrip('0')} CT"
        except ValueError:
            pass
    return {"model_engaged_at": engaged, "model_engaged_at_local": engaged, "model_engaged_label": label}


def build_payload(wnba_root: Path, out_dir: Path, run_dir: Path | None = None) -> Path:
    run_dir = (run_dir or _latest_live_run(wnba_root)).resolve()
    if not run_dir.exists():
        raise RuntimeError(f"WNBA Live run not found: {run_dir}")
    manifest, audit = _validate_live_run(run_dir)
    source_manifest_path = _path(manifest.get("source_selection_manifest_path"), wnba_root) or run_dir / "source_selection_manifest.json"
    source_manifest = _read_json(source_manifest_path)
    resolved = source_manifest.get("resolved_sources") or {}
    external_paths = [_path(value, wnba_root) for value in resolved.get("external_market_paths") or []]
    market_index = _external_market_index(path for path in external_paths if path is not None)
    all_legs, lookup = _load_all_legs(run_dir, market_index)
    marketed = _load_market_portfolio(run_dir, lookup)
    from_deep = _load_from_deep(run_dir, lookup)
    selected_legs = [leg for slip in marketed + from_deep for leg in slip.get("legs", [])]
    engagement = _engagement(manifest)
    generated = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    payload: dict[str, Any] = {
        "generated_at": generated,
        "run_id": run_dir.name,
        "sport": "WNBA",
        **engagement,
        "system": [],
        "system_winprob": [],
        "windfall": [],
        "windfall_winprob": [],
        "demonhunter": [],
        "big_swings": [],
        "from_deep": from_deep,
        "marketed_slips": marketed,
        "single_family": [],
        "single_family_slips": [],
        "single_family_3leg": [],
        "single_family_4leg": [],
        "single_family_5leg": [],
        "gamescript": [],
        "all_legs": all_legs,
        "top_hit_list": _top_hit_list(all_legs),
        "stat_hub": _stat_hub(source_manifest, wnba_root, all_legs),
        "injury_context": _injury_context(source_manifest, wnba_root, selected_legs, engagement),
        "performance": _performance(wnba_root),
        "source_context": {
            "run_mode": "live",
            "decision_timestamp_utc": manifest.get("decision_timestamp_utc"),
            "verified": bool(audit.get("ok")),
        },
    }
    illegal = [leg for leg in all_legs if leg.get("tier") in {"DEMON", "GOBLIN"} and leg.get("dir") != "OVER"]
    if illegal:
        raise RuntimeError(f"WNBA dashboard legality postflight failed: {len(illegal)} alternate-tier UNDER rows")
    out_dir.mkdir(parents=True, exist_ok=True)
    payload_path = out_dir / "cloudflare_payload.json"
    _write_json(payload_path, payload)
    _write_json(out_dir / "status_latest.json", {
        "ok": True,
        "sport": "WNBA",
        "run_id": run_dir.name,
        "generated_at": generated,
        "live_audit_check_count": audit.get("check_count"),
        "all_legs": len(all_legs),
        "market_portfolio_slips": len(marketed),
        "from_deep_picks": len(from_deep),
        **engagement,
    })
    return payload_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wnba-root", default=r"C:\Users\13142\Atlas\WNBA")
    parser.add_argument("--run-dir", default="")
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()
    wnba_root = Path(args.wnba_root).resolve()
    out_dir = Path(args.out_dir).resolve() if args.out_dir else wnba_root / "data" / "wnba" / "output" / "dashboard"
    payload = build_payload(wnba_root, out_dir, Path(args.run_dir) if args.run_dir else None)
    print(f"Wrote WNBA dashboard payload: {payload}")


if __name__ == "__main__":
    main()
