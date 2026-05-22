from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


FAMILY_FILES = {
    "system": ("system_3leg.json", "system_4leg.json", "system_5leg.json"),
    "windfall": ("windfall_3leg.json", "windfall_4leg.json", "windfall_5leg.json"),
    "demonhunter": ("demonhunter.json",),
}


def _read_json(path: Path) -> Any:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _num(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _int(value: Any) -> int | None:
    number = _num(value)
    return None if number is None else int(number)


TEAM_ALIASES = {
    "ARI": "AZ",
    "ATH": "ATH",
    "CHW": "CWS",
    "OAK": "ATH",
    "WAS": "WSH",
    "WSN": "WSH",
}


def _team_key(value: Any) -> str:
    raw = str(value or "").strip().upper()
    return TEAM_ALIASES.get(raw, raw)


def _name_key(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def _name_variants(value: Any) -> list[str]:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    tokens = re.findall(r"[a-z0-9]+", text)
    if not tokens:
        return []
    suffixes = {"jr", "sr", "ii", "iii", "iv", "v"}
    stripped = list(tokens)
    while stripped and stripped[-1] in suffixes:
        stripped.pop()
    variants = ["".join(tokens)]
    if stripped:
        variants.append("".join(stripped))
        if len(stripped) >= 2:
            variants.append(stripped[0][:1] + stripped[-1])
    deduped: list[str] = []
    for key in variants:
        if key and key not in deduped:
            deduped.append(key)
    return deduped


def _read_jsonl(path: Path | None) -> list[dict[str, Any]]:
    if not path or not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                rows.append(item)
    return rows


def _find_path_ending(obj: Any, suffix: str) -> Path | None:
    if isinstance(obj, dict):
        for value in obj.values():
            found = _find_path_ending(value, suffix)
            if found:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = _find_path_ending(value, suffix)
            if found:
                return found
    elif isinstance(obj, str) and obj.lower().endswith(suffix.lower()):
        path = Path(obj)
        if path.exists():
            return path
    return None


def _fmt_number(value: float | int | None, digits: int = 0) -> str:
    if value is None:
        return "-"
    number = float(value)
    if digits <= 0:
        return str(int(round(number)))
    return f"{number:.{digits}f}"


def _fmt_rate(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}".lstrip("0")


def _innings_to_outs(value: Any) -> int:
    if value in (None, ""):
        return 0
    text = str(value)
    if "." in text:
        whole, frac = text.split(".", 1)
        try:
            whole_i = int(whole or 0)
            frac_i = int(frac[:1] or 0)
        except ValueError:
            return 0
        return whole_i * 3 + min(max(frac_i, 0), 2)
    try:
        return int(float(text) * 3)
    except (TypeError, ValueError):
        return 0


def _outs_to_ip(outs: int) -> str:
    if outs <= 0:
        return "0.0"
    return f"{outs // 3}.{outs % 3}"


def _player_image(person_id: Any) -> str:
    pid = _int(person_id)
    if not pid:
        return ""
    return (
        "https://img.mlbstatic.com/mlb-photos/image/upload/"
        f"w_213,d_people:generic:headshot:silo:current.png,q_auto:best,f_auto/v1/people/{pid}/headshot/67/current"
    )


def _team_logo(team_id: Any) -> str:
    tid = _int(team_id)
    return f"https://www.mlbstatic.com/team-logos/{tid}.svg" if tid else ""


def _find_prizepicks_payload(mlb_root: Path, run_dir: Path) -> Path | None:
    manifest = _read_json(run_dir / "run_manifest.json") or _read_json(run_dir / "source_selection_manifest.json") or {}
    normalized_dir = _find_nested_value(manifest, "normalized_dir")
    snapshot_id = ""
    if normalized_dir:
        snapshot_id = Path(str(normalized_dir)).name
    if not snapshot_id:
        found_snapshot = _find_nested_value(manifest, "snapshot_id")
        if str(found_snapshot or "").startswith("prizepicks_"):
            snapshot_id = str(found_snapshot)
    match = re.search(r"prizepicks_(\d{4})(\d{2})(\d{2})T(\d{6})Z", snapshot_id)
    if match:
        date = f"{match.group(1)}-{match.group(2)}-{match.group(3)}"
        stamp = f"{match.group(1)}{match.group(2)}{match.group(3)}T{match.group(4)}Z"
        path = mlb_root / "data" / "mlb" / "raw" / "prizepicks" / date / stamp / "payload.json"
        if path.exists():
            return path
    raw_root = mlb_root / "data" / "mlb" / "raw" / "prizepicks"
    if not raw_root.exists():
        return None
    candidates = sorted(raw_root.glob("**/payload.json"), key=lambda p: p.stat().st_mtime)
    return candidates[-1] if candidates else None


def _load_prizepicks_visual_assets(mlb_root: Path, run_dir: Path) -> dict[str, Any]:
    assets: dict[str, Any] = {"players": {}, "teams": {}, "payload_path": ""}
    payload_path = _find_prizepicks_payload(mlb_root, run_dir)
    if not payload_path:
        return assets
    assets["payload_path"] = str(payload_path)
    try:
        data = json.loads(payload_path.read_text(encoding="utf-8"))
    except Exception:
        return assets
    for item in data.get("included", []):
        item_type = item.get("type")
        attrs = item.get("attributes") or {}
        if item_type == "team":
            abbr = _team_key(attrs.get("abbreviation"))
            if not abbr or "/" in abbr:
                continue
            assets["teams"][abbr] = {
                "logo_url": attrs.get("logo") or "",
                "team_name": attrs.get("name") or "",
                "market": attrs.get("market") or "",
                "primary_color": attrs.get("primary_color") or "",
                "secondary_color": attrs.get("secondary_color") or "",
            }
        elif item_type == "new_player":
            if attrs.get("combo"):
                continue
            name = str(attrs.get("display_name") or attrs.get("name") or "").strip()
            team = _team_key(attrs.get("team"))
            if not name:
                continue
            payload = {
                "image_url": attrs.get("image_url") or "",
                "jersey_number": attrs.get("jersey_number") or "",
                "position": attrs.get("position") or "",
                "pp_player_id": item.get("id") or "",
            }
            for key in _name_variants(name):
                assets["players"][(team, key)] = payload
                assets["players"].setdefault(("", key), payload)
    return assets


def _infer_recent_games(rate: float | None, max_games: int = 10, min_games: int = 5) -> int | None:
    if rate is None or rate <= 0:
        return None
    if rate >= 1:
        return max_games
    best_n: int | None = None
    best_err = 1.0
    for n in range(min_games, max_games + 1):
        hits = round(rate * n)
        if hits < 0 or hits > n:
            continue
        err = abs(rate - (hits / n))
        if err < best_err or (err == best_err and (best_n is None or n > best_n)):
            best_err = err
            best_n = n
    return best_n if best_n is not None and best_err <= 0.0005 else max_games


def _latest_live_run(mlb_root: Path) -> Path:
    live_root = mlb_root / "data" / "mlb" / "live_runs"
    runs = sorted((p for p in live_root.glob("live_*") if p.is_dir()), key=lambda p: p.name)
    if not runs:
        raise SystemExit(f"No MLB live runs found under {live_root}")
    return runs[-1]


def _display_stat(row: dict[str, Any]) -> str:
    return str(row.get("stat_raw") or row.get("source_market") or row.get("market") or row.get("stat") or "").upper()


def _side_probability(row: dict[str, Any]) -> float | None:
    direct = _num(row.get("p_cal") or row.get("model_probability") or row.get("p_adj"))
    if direct is not None:
        return direct
    side = str(row.get("side") or row.get("dir") or row.get("direction") or "").lower()
    if side == "under":
        return _num(row.get("under_probability"))
    return _num(row.get("over_probability"))


def _projection_fields(row: dict[str, Any], direction: str) -> dict[str, Any]:
    mean = _num(row.get("atlas_projection_mean") or row.get("mean_projection"))
    median = _num(row.get("atlas_projection_median") or row.get("median_projection"))
    line = _num(row.get("line"))
    raw_delta = None if mean is None or line is None else mean - line
    side_delta = None
    if raw_delta is not None:
        side_delta = -raw_delta if str(direction or "").upper() == "UNDER" else raw_delta
    return {
        "atlas_projection_mean": mean,
        "atlas_projection_median": median,
        "atlas_projection_delta": raw_delta,
        "atlas_projection_side_delta": side_delta,
        "atlas_projection_source": row.get("atlas_projection_source")
        or row.get("simulation_kernel_version")
        or row.get("parameter_model_version")
        or "atlas_simulation",
        "atlas_projection_opportunity": _num(row.get("projected_opportunity")),
        "atlas_projection_p10": _num(row.get("p10")),
        "atlas_projection_p25": _num(row.get("p25")),
        "atlas_projection_p75": _num(row.get("p75")),
        "atlas_projection_p90": _num(row.get("p90")),
    }


def _is_contest_market_source(row: dict[str, Any]) -> bool:
    raw = " ".join(
        str(row.get(key) or "")
        for key in (
            "market_source",
            "market_context_source_type",
            "external_market_context_source",
            "external_prior_sources",
            "source",
        )
    ).lower()
    return "pick6" in raw or "pick_6" in raw or "pick 6" in raw


def _l10(row: dict[str, Any]) -> tuple[float | None, int | None]:
    side = str(row.get("side") or row.get("dir") or row.get("direction") or "").lower()
    key = "bettingpros_last_10_under_rate" if side == "under" else "bettingpros_last_10_over_rate"
    rate = _num(row.get(key))
    if rate is None or rate <= 0:
        return (None, None)
    return (rate, _infer_recent_games(rate))


def _normalize_leg(row: dict[str, Any]) -> dict[str, Any]:
    l10_rate, l10_n = _l10(row)
    p_cal = _side_probability(row)
    contest_market = _is_contest_market_source(row)
    tier = str(row.get("tier") or row.get("odds_type") or "").upper()
    side = str(row.get("dir") or row.get("direction") or row.get("side") or "").upper()
    if side == "OVER" or side == "UNDER":
        direction = side
    else:
        direction = "OVER"
    leg = {
        "sport": "MLB",
        "id": _int(row.get("id") or row.get("projection_id") or row.get("source_projection_id")),
        "player": row.get("player") or row.get("player_name") or "",
        "team": row.get("team") or row.get("player_team") or "",
        "opp": row.get("opp") or row.get("opponent") or "",
        "stat": _display_stat(row),
        "stat_raw": row.get("stat_raw") or row.get("source_market") or row.get("market") or "",
        "line": _num(row.get("line")),
        "dir": direction,
        "tier": tier,
        "p_cal": p_cal,
        "atlas_ev": _num(row.get("atlas_ev") or row.get("ev_mult") or row.get("edge")),
        "edge": _num(row.get("edge")),
        "l10_hr": l10_rate,
        "l10_n": l10_n,
        "recent_streak": _num(row.get("bettingpros_streak") or row.get("recent_streak")),
        "recent_streak_type": row.get("bettingpros_streak_type") or row.get("recent_streak_type"),
        "recent_last_5_over_rate": _num(row.get("bettingpros_last_5_over_rate") or row.get("recent_last_5_over_rate")),
        "recent_last_5_under_rate": _num(row.get("bettingpros_last_5_under_rate") or row.get("recent_last_5_under_rate")),
        "recent_last_10_over_rate": _num(row.get("bettingpros_last_10_over_rate") or row.get("recent_last_10_over_rate")),
        "recent_last_10_under_rate": _num(row.get("bettingpros_last_10_under_rate") or row.get("recent_last_10_under_rate")),
        "recent_last_20_over_rate": _num(row.get("bettingpros_last_20_over_rate") or row.get("recent_last_20_over_rate")),
        "recent_last_20_under_rate": _num(row.get("bettingpros_last_20_under_rate") or row.get("recent_last_20_under_rate")),
        "recent_season_over_rate": _num(row.get("bettingpros_season_over_rate") or row.get("recent_season_over_rate")),
        "recent_season_under_rate": _num(row.get("bettingpros_season_under_rate") or row.get("recent_season_under_rate")),
        "stability_score": _num(row.get("stability_score")),
        "fragility_score": _num(row.get("fragility_score") or row.get("fragility")),
        "lineup_score": _num(row.get("lineup_score")),
        "starter_matchup_score": _num(row.get("starter_matchup_score")),
        "bullpen_matchup_score": _num(row.get("bullpen_matchup_score")),
        "environment_score": _num(row.get("environment_score")),
        "matchup_composite_score": _num(row.get("matchup_composite_score")),
        "matchup_confidence": _num(row.get("matchup_confidence")),
        "matchup_target_shift": _num(row.get("matchup_target_shift")),
        "game_date": row.get("game_date"),
        "start_time": row.get("start_time") or row.get("start_time_utc"),
        "market": row.get("market"),
        "external_market_context_available": row.get("external_market_context_available"),
        "market_price": _num(row.get("market_price")),
        "fair_price": _num(row.get("fair_price")),
        "fair_decimal": _num(row.get("fair_decimal")),
        "market_implied_prob": _num(row.get("market_implied_prob") or row.get("external_prior_market_prob")),
        "market_over_probability": _num(row.get("market_over_probability")),
        "market_under_probability": _num(row.get("market_under_probability")),
        "market_n_books": _num(row.get("market_n_books")),
        "market_source_line": _num(row.get("market_source_line")),
        "market_line_match_type": row.get("market_line_match_type"),
        "market_line_delta": _num(row.get("market_line_delta")),
    }
    if contest_market:
        for key in (
            "external_market_context_available",
            "market_price",
            "market_implied_prob",
            "market_over_probability",
            "market_under_probability",
            "market_n_books",
            "market_source_line",
            "market_line_match_type",
            "market_line_delta",
        ):
            leg.pop(key, None)
    leg.update(_projection_fields(row, direction))
    return {k: v for k, v in leg.items() if v not in (None, "")}


def _market_context_path(run_dir: Path) -> Path | None:
    run_manifest = _read_json(run_dir / "run_manifest.json") or {}
    source_manifest = _read_json(run_dir / "source_selection_manifest.json") or {}
    candidates = [
        _find_nested_value(run_manifest, "market_context.json_path"),
        _find_nested_value(run_manifest, "market_context_path"),
        _find_nested_value(run_manifest, "json_path"),
        _find_nested_value(source_manifest, "market"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(str(candidate))
        if path.name == "market_context_manifest.json":
            sibling = path.with_name("market_context.csv")
            if sibling.exists():
                return sibling
            sibling = path.with_name("market_context.json")
            if sibling.exists():
                return sibling
        if path.exists() and path.name in {"market_context.csv", "market_context.json"}:
            return path
    fallback = run_dir.parents[1] / "features" / "market_context" / run_dir.name / "market_context.csv"
    if fallback.exists():
        return fallback
    fallback_json = fallback.with_suffix(".json")
    return fallback_json if fallback_json.exists() else None


def _load_market_context_rows(run_dir: Path) -> dict[str, dict[str, Any]]:
    path = _market_context_path(run_dir)
    rows: list[dict[str, Any]] = []
    if not path:
        return {}
    if path.suffix.lower() == ".csv":
        with path.open("r", encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.DictReader(fh))
    else:
        data = _read_json(path) or {}
        rows = data if isinstance(data, list) else data.get("rows", [])
    price_index = _load_market_price_index(run_dir)
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        prices = price_index.get(_market_key(row))
        if prices:
            row = {**row, **prices}
        key = str(row.get("source_projection_id") or row.get("id") or "").strip()
        if key:
            out[key] = row
    return out


def _merge_market_context(leg: dict[str, Any], ctx: dict[str, Any]) -> None:
    if not ctx:
        return
    if _is_contest_market_source(ctx):
        return
    side = str(leg.get("dir") or "").upper()
    market_prob = _num(ctx.get("market_under_probability") if side == "UNDER" else ctx.get("market_over_probability"))
    updates = {
        "market_implied_prob": market_prob,
        "external_prior_market_prob": market_prob,
        "market_over_probability": _num(ctx.get("market_over_probability")),
        "market_under_probability": _num(ctx.get("market_under_probability")),
        "market_n_books": _num(ctx.get("market_n_books")),
        "market_source_line": _num(ctx.get("market_source_line")),
        "market_over_price": _num(ctx.get("market_over_price")),
        "market_under_price": _num(ctx.get("market_under_price")),
        "dk_over": _num(ctx.get("dk_over")),
        "dk_under": _num(ctx.get("dk_under")),
        "fd_over": _num(ctx.get("fd_over")),
        "fd_under": _num(ctx.get("fd_under")),
        "market_line_match_type": ctx.get("market_line_match_type"),
        "market_line_delta": _num(ctx.get("market_line_delta")),
        "market_context_flags": ctx.get("market_context_flags"),
    }
    if ctx.get("market_context_available") not in (None, ""):
        updates["external_market_context_available"] = ctx.get("market_context_available")
    for key, value in updates.items():
        if value not in (None, ""):
            leg[key] = value


def _line_key(value: Any) -> str:
    number = _num(value)
    return f"{number:g}" if number is not None else str(value or "").strip()


def _market_key(row: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        _team_key(row.get("player_team")),
        _name_key(row.get("player_name")),
        str(row.get("market") or "").strip().lower(),
        _line_key(row.get("line")),
    )


def _valid_american(value: Any) -> float | None:
    number = _num(value)
    if number is None or number == 0:
        return None
    return number


def _load_market_price_index(run_dir: Path) -> dict[tuple[str, str, str, str], dict[str, Any]]:
    source_manifest = _read_json(run_dir / "source_selection_manifest.json") or {}
    details = _find_nested_value(source_manifest, "selected_details")
    if not isinstance(details, list):
        details = []
    out: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    for detail in details:
        source_dir = Path(str((detail or {}).get("path") or ""))
        props_path = source_dir / "oddsapi_props.jsonl"
        if not props_path.exists():
            continue
        for row in _read_jsonl(props_path):
            key = _market_key(row)
            if not all(key):
                continue
            item = out.setdefault(key, {})
            books = row.get("books") if isinstance(row.get("books"), list) else []
            source_over: float | None = None
            source_under: float | None = None
            for book in books:
                if not isinstance(book, dict):
                    continue
                book_key = str(book.get("book_key") or book.get("book_title") or "").lower()
                over_price = _valid_american(book.get("over_price"))
                under_price = _valid_american(book.get("under_price"))
                if source_over is None and over_price is not None:
                    source_over = over_price
                if source_under is None and under_price is not None:
                    source_under = under_price
                if "draftkings" in book_key and "pick6" not in book_key:
                    if over_price is not None:
                        item["dk_over"] = over_price
                    if under_price is not None:
                        item["dk_under"] = under_price
                if "fanduel" in book_key or book_key in {"fd"}:
                    if over_price is not None:
                        item["fd_over"] = over_price
                    if under_price is not None:
                        item["fd_under"] = under_price
            if source_over is not None:
                item.setdefault("market_over_price", source_over)
            if source_under is not None:
                item.setdefault("market_under_price", source_under)
    return out


def _load_all_legs(run_dir: Path) -> list[dict[str, Any]]:
    csv_path = run_dir / "scored_legs_deduped.csv"
    if not csv_path.exists():
        return []
    market_context = _load_market_context_rows(run_dir)
    legs: list[dict[str, Any]] = []
    with csv_path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            leg = _normalize_leg(row)
            ctx = market_context.get(str(row.get("source_projection_id") or leg.get("id") or "").strip())
            _merge_market_context(leg, ctx or {})
            legs.append(leg)
    legs.sort(key=lambda leg: (-(leg.get("p_cal") or 0), str(leg.get("player") or ""), str(leg.get("stat") or "")))
    return legs


def _top_hit_list(legs: list[dict[str, Any]], limit: int = 10) -> list[dict[str, Any]]:
    ranked: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    for leg in legs:
        rate = _num(leg.get("l10_hr"))
        n = _int(leg.get("l10_n"))
        if rate is None:
            side = str(leg.get("dir") or "").lower()
            key = "bettingpros_last_10_under_rate" if side == "under" else "bettingpros_last_10_over_rate"
            rate = _num(leg.get(key))
            n = _infer_recent_games(rate)
        if rate is None or n is None or n < 5:
            continue
        key_tuple = (
            str(leg.get("player") or "").lower(),
            str(leg.get("team") or "").upper(),
            str(leg.get("stat") or "").upper(),
            leg.get("line"),
            str(leg.get("dir") or "").upper(),
        )
        if key_tuple in seen:
            continue
        seen.add(key_tuple)
        hits = round(rate * n)
        ranked.append(
            {
                "sport": "MLB",
                "player": leg.get("player"),
                "team": leg.get("team"),
                "opp": leg.get("opp"),
                "stat": leg.get("stat"),
                "line": leg.get("line"),
                "dir": leg.get("dir"),
                "tier": leg.get("tier"),
                "p_cal": leg.get("p_cal"),
                "l10_hr": rate,
                "l10_n": n,
                "l10_hits": hits,
                "streak": leg.get("bettingpros_streak"),
                "streak_type": leg.get("bettingpros_streak_type"),
            }
        )
    ranked.sort(
        key=lambda item: (
            -(item.get("l10_hr") or 0),
            -(item.get("l10_n") or 0),
            -(item.get("p_cal") or 0),
            str(item.get("player") or ""),
            str(item.get("stat") or ""),
        )
    )
    return ranked[:limit]


def _normalize_slip(raw: dict[str, Any], family: str) -> dict[str, Any] | None:
    legs_raw = raw.get("legs") or raw.get("legs_detail") or []
    if not legs_raw:
        return None
    legs = [_normalize_leg(dict(leg)) for leg in legs_raw]
    n_legs = int(raw.get("n_legs") or raw.get("leg_count") or len(legs))
    payout = _num(raw.get("payout_mult_eff") or raw.get("payout_mult") or raw.get("pp_power_payout_mult"))
    hit_prob = _num(raw.get("hit_prob"))
    out = {
        "sport": "MLB",
        "product": family.title() if family != "demonhunter" else "DemonHunter",
        "family": family,
        "n_legs": n_legs,
        "label": raw.get("label") or f"{n_legs}-leg",
        "legs": legs,
        "legs_detail": legs,
        "hit_prob": hit_prob,
        "payout_mult": payout,
        "pp_power_payout_mult": payout,
        "ev": _num(raw.get("ev") or raw.get("ev_mult")),
        "high_confidence": bool(raw.get("high_confidence", False)),
    }
    return {k: v for k, v in out.items() if v not in (None, "")}


def _load_marketed(run_dir: Path) -> list[dict[str, Any]]:
    raw = _read_json(run_dir / "slips" / "marketed_slips.json") or _read_json(run_dir / "marketed_slips.json") or {}
    slips = raw.get("slips") if isinstance(raw, dict) else raw
    return [s for s in (_normalize_slip(dict(item), "marketed") for item in (slips or [])) if s]


def _load_family(run_dir: Path, family: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for name in FAMILY_FILES.get(family, ()):
        raw = _read_json(run_dir / "slips" / name)
        if isinstance(raw, dict):
            slip = _normalize_slip(raw, family)
            if slip:
                out.append(slip)
    return out


def _load_source_context(run_dir: Path) -> dict[str, Any]:
    operator = _read_json(run_dir / "operator" / "operator_input.json") or {}
    manifest = _read_json(run_dir / "run_manifest.json") or {}
    feature_summary = operator.get("feature_summary") or {}
    source = feature_summary.get("source_completeness") or {}
    counts = operator.get("counts") or {}
    return {
        "feature_summary": feature_summary,
        "source_completeness": source,
        "counts": counts,
        "run_manifest_version": manifest.get("schema_version") or manifest.get("run_mode"),
    }


def _find_nested_value(obj: Any, key: str) -> Any:
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for value in obj.values():
            found = _find_nested_value(value, key)
            if found not in (None, ""):
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = _find_nested_value(value, key)
            if found not in (None, ""):
                return found
    return None


def _load_injury_context(run_dir: Path, all_legs: list[dict[str, Any]]) -> dict[str, Any]:
    manifest = _read_json(run_dir / "run_manifest.json") or {}
    injuries_path_raw = _find_nested_value(manifest, "injuries_path")
    if not injuries_path_raw:
        return {"invalidated_players": [], "questionable_players": [], "role_boosted": []}
    injuries_path = Path(str(injuries_path_raw))
    if not injuries_path.exists():
        return {"invalidated_players": [], "questionable_players": [], "role_boosted": []}

    slate_teams = {str(leg.get("team") or "").upper() for leg in all_legs}
    slate_teams |= {str(leg.get("opp") or "").upper() for leg in all_legs}
    invalidated: list[dict[str, Any]] = []
    questionable: list[dict[str, Any]] = []
    report_date = ""
    pulled_at = ""
    with injuries_path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            team = str(row.get("team") or "").upper()
            if slate_teams and team not in slate_teams:
                continue
            status = str(row.get("status") or "").strip()
            status_u = status.upper()
            item = {
                "player": row.get("player_name") or row.get("player") or "",
                "team": team,
                "status": status,
                "reason": row.get("comment") or row.get("reason") or "",
            }
            if "DAY-TO-DAY" in status_u or "QUESTION" in status_u:
                questionable.append(item)
            elif "IL" in status_u or "OUT" in status_u or "INACTIVE" in status_u:
                invalidated.append(item)
            report_date = report_date or str(row.get("report_date") or "")[:10]
            pulled_at = pulled_at or str(row.get("pulled_at_utc") or "")
    return {
        "invalidated_players": invalidated[:80],
        "questionable_players": questionable[:80],
        "role_boosted": [],
        "report_date": report_date,
        "report_label": "ESPN MLB injuries" if pulled_at else "",
    }


def _latest_eval_file(mlb_root: Path, name: str) -> Path | None:
    eval_root = mlb_root / "data" / "mlb" / "eval"
    if not eval_root.exists():
        return None
    matches = [p for p in eval_root.glob(f"**/{name}") if p.is_file()]
    if not matches:
        return None
    return max(matches, key=lambda p: p.stat().st_mtime)


def _load_performance(mlb_root: Path) -> dict[str, Any]:
    public_eval_start = date(2026, 5, 28)
    if datetime.now().date() < public_eval_start:
        return {
            "placeholder_message": "Evaluation coming 5/28",
            "placeholder_detail": "MLB public performance metrics will begin after one full week of live production runs.",
        }

    eval_summary_path = _latest_eval_file(mlb_root, "eval_summary.json")
    slip_eval_path = _latest_eval_file(mlb_root, "slip_eval.json")
    eval_summary = _read_json(eval_summary_path) if eval_summary_path else {}
    slip_eval = _read_json(slip_eval_path) if slip_eval_path else {}
    if not eval_summary and not slip_eval:
        return {}

    slip_summary = (slip_eval or {}).get("summary") or {}
    family_summary = slip_summary.get("family_summary") or {}
    yesterday = {
        "wins": slip_summary.get("result_counts", {}).get("win", 0),
        "total": slip_summary.get("settled_count") or slip_summary.get("slip_count") or 0,
        "pct": slip_summary.get("win_rate"),
        "date": "latest MLB eval",
    }
    for key, label in (("market", "Marketed"), ("system", "System"), ("windfall", "Windfall")):
        item = family_summary.get(label) or {}
        yesterday[key] = {
            "wins": item.get("result_counts", {}).get("win", 0),
            "total": item.get("metric_count") or item.get("slip_count") or 0,
            "pct": item.get("win_rate"),
        }

    return {
        "overall": {
            "last_7d": {
                "hit_rate": eval_summary.get("win_rate"),
                "n": eval_summary.get("metric_count"),
            },
            "last_30d": {
                "hit_rate": eval_summary.get("win_rate"),
                "n": eval_summary.get("metric_count"),
            },
        },
        "by_tier": {},
        "yesterday_slips": yesterday,
        "meta": {
            "source": "latest_mlb_eval",
            "eval_summary_path": str(eval_summary_path) if eval_summary_path else "",
            "slip_eval_path": str(slip_eval_path) if slip_eval_path else "",
        },
    }


def _roster_indexes(rows: list[dict[str, Any]]) -> tuple[dict[int, dict[str, Any]], dict[tuple[str, str], dict[str, Any]]]:
    by_id: dict[int, dict[str, Any]] = {}
    by_team_name: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        pid = _int(row.get("person_id") or row.get("statsapi_person_id"))
        team = _team_key(row.get("team_abbreviation") or row.get("statsapi_roster_team_abbreviation"))
        name = str(row.get("player_name") or "").strip()
        if pid:
            by_id[pid] = row
        if team and name:
            by_team_name[(team, _name_key(name))] = row
    return by_id, by_team_name


def _team_index(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        team = _team_key(row.get("team_abbreviation"))
        if team:
            out[team] = row
    return out


def _resolve_person(row: dict[str, Any], roster_by_name: dict[tuple[str, str], dict[str, Any]]) -> tuple[int | None, dict[str, Any]]:
    team = _team_key(row.get("team_abbr") or row.get("team") or row.get("player_team"))
    name = row.get("player_name") or row.get("pitcher_name") or row.get("player") or ""
    roster = roster_by_name.get((team, _name_key(name)), {})
    return _int(roster.get("person_id") or roster.get("statsapi_person_id")), roster


def _aggregate_season_gamelogs(path: Path | None) -> dict[int, dict[str, Any]]:
    if not path or not path.exists():
        return {}
    totals: dict[int, dict[str, Any]] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            pid = _int(row.get("person_id"))
            if not pid:
                continue
            try:
                stat = json.loads(row.get("stat") or "{}")
            except json.JSONDecodeError:
                continue
            group = str(row.get("group") or "").lower()
            player = totals.setdefault(
                pid,
                {
                    "player": row.get("player_name") or "",
                    "team": _team_key(row.get("team_abbreviation") or row.get("player_team")),
                    "hitting": {},
                    "pitching": {},
                },
            )
            if group == "hitting":
                agg = player["hitting"]
                for key in (
                    "gamesPlayed",
                    "atBats",
                    "runs",
                    "hits",
                    "doubles",
                    "triples",
                    "homeRuns",
                    "rbi",
                    "totalBases",
                    "baseOnBalls",
                    "strikeOuts",
                    "stolenBases",
                ):
                    agg[key] = agg.get(key, 0) + (_num(stat.get(key)) or 0)
            elif group == "pitching":
                agg = player["pitching"]
                for key in (
                    "gamesPitched",
                    "gamesStarted",
                    "wins",
                    "losses",
                    "saves",
                    "hits",
                    "earnedRuns",
                    "homeRuns",
                    "baseOnBalls",
                    "strikeOuts",
                    "pitchesThrown",
                    "strikes",
                ):
                    agg[key] = agg.get(key, 0) + (_num(stat.get(key)) or 0)
                agg["outs"] = agg.get("outs", 0) + (_num(stat.get("outs")) or _innings_to_outs(stat.get("inningsPitched")))
                if str(row.get("is_pitching_starter") or "").lower() == "true":
                    agg["gamesStarted"] = max(agg.get("gamesStarted", 0), agg.get("gamesStarted", 0))
    return totals


def _mlb_recent_stat_value(stat: dict[str, Any], market: str, group: str) -> float | None:
    key = str(market or "").upper().strip()

    def val(name: str) -> float:
        return _num(stat.get(name)) or 0.0

    if group == "hitting":
        mapping = {
            "HITS": val("hits"),
            "SINGLES": max(0.0, val("hits") - val("doubles") - val("triples") - val("homeRuns")),
            "DOUBLES": val("doubles"),
            "TRIPLES": val("triples"),
            "HOME RUNS": val("homeRuns"),
            "RUNS": val("runs"),
            "RBIS": val("rbi"),
            "HITS+RUNS+RBIS": val("hits") + val("runs") + val("rbi"),
            "TOTAL BASES": val("totalBases"),
            "STOLEN BASES": val("stolenBases"),
            "WALKS": val("baseOnBalls"),
            "HITTER STRIKEOUTS": val("strikeOuts"),
            "HITTER FANTASY SCORE": val("hits") * 3 + val("doubles") * 3 + val("triples") * 6 + val("homeRuns") * 10 + val("runs") + val("rbi") + val("baseOnBalls") + val("stolenBases") * 5,
        }
        return mapping.get(key)
    mapping = {
        "PITCHER STRIKEOUTS": val("strikeOuts"),
        "PITCHING OUTS": val("outs"),
        "HITS ALLOWED": val("hits"),
        "EARNED RUNS ALLOWED": val("earnedRuns"),
        "PITCHER WALKS": val("baseOnBalls"),
        "PITCHES THROWN": val("pitchesThrown") or val("numberOfPitches"),
    }
    return mapping.get(key)


def _mlb_recent_game_index(path: Path | None) -> dict[tuple[str, str], list[dict[str, Any]]]:
    if not path or not path.exists():
        return {}
    out: dict[tuple[str, str], list[dict[str, Any]]] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            name = row.get("player_name") or ""
            team = _team_key(row.get("team_abbreviation") or row.get("player_team"))
            group = str(row.get("group") or "").lower()
            if not name or not team or group not in {"hitting", "pitching"}:
                continue
            try:
                stat = json.loads(row.get("stat") or "{}")
            except json.JSONDecodeError:
                continue
            out.setdefault((team, _name_key(name)), []).append(
                {
                    "date": str(row.get("game_date") or ""),
                    "opp": _team_key(row.get("opponent_abbreviation")),
                    "group": group,
                    "stat": stat,
                }
            )
    for rows in out.values():
        rows.sort(key=lambda item: item.get("date") or "")
    return out


def _attach_recent_games_to_legs(legs: list[dict[str, Any]], season_path: Path | None, limit: int = 5) -> None:
    index = _mlb_recent_game_index(season_path)
    if not index:
        return
    for leg in legs:
        team = _team_key(leg.get("team"))
        player_key = _name_key(leg.get("player"))
        rows = index.get((team, player_key)) or index.get(("", player_key)) or []
        if not rows:
            # Last fallback: player name is usually unique enough for the current slate.
            rows = [row for (row_team, name), player_rows in index.items() if name == player_key for row in player_rows]
            rows.sort(key=lambda item: item.get("date") or "")
        stat_name = str(leg.get("stat") or "")
        direction = str(leg.get("dir") or "").upper()
        line = _num(leg.get("line"))
        recent: list[dict[str, Any]] = []
        for row in rows[-limit:]:
            value = _mlb_recent_stat_value(row.get("stat") or {}, stat_name, str(row.get("group") or ""))
            if value is None:
                continue
            hit = None
            if line is not None:
                hit = value < line if direction == "UNDER" else value > line
            recent.append({"date": row.get("date"), "opp": row.get("opp"), "value": value, "hit": hit})
        if recent:
            leg["recent_games"] = recent


def _hitting_fields(agg: dict[str, Any]) -> list[list[str]]:
    gp = _num(agg.get("gamesPlayed")) or 0
    ab = _num(agg.get("atBats")) or 0
    hits = _num(agg.get("hits")) or 0
    tb = _num(agg.get("totalBases")) or 0
    avg = hits / ab if ab else None
    slg = tb / ab if ab else None
    return [
        ["GP", _fmt_number(gp)],
        ["AB", _fmt_number(ab)],
        ["R", _fmt_number(agg.get("runs"))],
        ["H", _fmt_number(hits)],
        ["2B", _fmt_number(agg.get("doubles"))],
        ["3B", _fmt_number(agg.get("triples"))],
        ["HR", _fmt_number(agg.get("homeRuns"))],
        ["RBIS", _fmt_number(agg.get("rbi"))],
        ["TB", _fmt_number(tb)],
        ["BB", _fmt_number(agg.get("baseOnBalls"))],
        ["SO", _fmt_number(agg.get("strikeOuts"))],
        ["SB", _fmt_number(agg.get("stolenBases"))],
        ["AVG", _fmt_rate(avg)],
        ["SLG", _fmt_rate(slg)],
    ]


def _pitching_fields(agg: dict[str, Any]) -> list[list[str]]:
    outs = int(_num(agg.get("outs")) or 0)
    ip = outs / 3 if outs else 0
    h = _num(agg.get("hits")) or 0
    er = _num(agg.get("earnedRuns")) or 0
    bb = _num(agg.get("baseOnBalls")) or 0
    k = _num(agg.get("strikeOuts")) or 0
    pitches = _num(agg.get("pitchesThrown")) or 0
    strikes = _num(agg.get("strikes")) or 0
    return [
        ["G", _fmt_number(agg.get("gamesPitched"))],
        ["GS", _fmt_number(agg.get("gamesStarted"))],
        ["W", _fmt_number(agg.get("wins"))],
        ["L", _fmt_number(agg.get("losses"))],
        ["SV", _fmt_number(agg.get("saves"))],
        ["IP", _outs_to_ip(outs)],
        ["H", _fmt_number(h)],
        ["ER", _fmt_number(er)],
        ["HR", _fmt_number(agg.get("homeRuns"))],
        ["BB", _fmt_number(bb)],
        ["K", _fmt_number(k)],
        ["K/9", _fmt_number((k * 9 / ip) if ip else None, 1)],
        ["P/S", f"{_fmt_number(pitches)}/{_fmt_number(strikes)}"],
        ["WHIP", _fmt_number(((bb + h) / ip) if ip else None, 2)],
        ["ERA", _fmt_number((er * 9 / ip) if ip else None, 2)],
    ]


def _stat_player(
    *,
    name: str,
    team: str,
    position: str,
    jersey: Any,
    image_url: str,
    fields: list[list[str]],
    order: int | None = None,
) -> dict[str, Any]:
    meta = {"fields": fields}
    if order:
        meta["order"] = order
    return {
        "player": name,
        "team": team,
        "position": position,
        "jersey_number": jersey,
        "image_url": image_url,
        "season": meta,
    }


def _load_mlb_stat_hub(mlb_root: Path, run_dir: Path, all_legs: list[dict[str, Any]]) -> dict[str, Any]:
    manifest = _read_json(run_dir / "source_selection_manifest.json") or _read_json(run_dir / "run_manifest.json") or {}
    lineups_path = _find_path_ending(manifest, "daily_lineups.jsonl") or _find_path_ending(manifest, "batting_orders.jsonl")
    pitchers_path = _find_path_ending(manifest, "pitchers.jsonl")
    relievers_path = _find_path_ending(manifest, "hitter_context.jsonl")
    roster_path = _find_path_ending(manifest, "statsapi_rosters_bulk.jsonl")
    teams_path = _find_path_ending(manifest, "statsapi_teams.jsonl")
    season_path = mlb_root / "data" / "mlb" / "season_gamelogs" / "latest.csv"

    slate_teams: set[str] = set()
    for leg in all_legs:
        for raw in (leg.get("team"), leg.get("opp")):
            for part in str(raw or "").replace("@", "/").split("/"):
                team = _team_key(part)
                if team and len(team) <= 3:
                    slate_teams.add(team)

    lineups = [row for row in _read_jsonl(lineups_path) if _team_key(row.get("team_abbr")) in slate_teams]
    pitchers = [row for row in _read_jsonl(pitchers_path) if _team_key(row.get("team_abbr")) in slate_teams]
    relievers = [row for row in _read_jsonl(relievers_path) if _team_key(row.get("team_abbr") or row.get("team")) in slate_teams]
    roster_by_id, roster_by_name = _roster_indexes(_read_jsonl(roster_path))
    teams_by_abbr = _team_index(_read_jsonl(teams_path))
    season_stats = _aggregate_season_gamelogs(season_path)
    pp_assets = _load_prizepicks_visual_assets(mlb_root, run_dir)

    def pp_player(team: str, name: Any) -> dict[str, Any]:
        players = pp_assets.get("players", {})
        for key in _name_variants(name):
            found = players.get((team, key)) or players.get(("", key))
            if found:
                return found
        return {}

    teams: list[dict[str, Any]] = []
    for team in sorted(slate_teams):
        team_info = teams_by_abbr.get(team, {})
        opponents = sorted(
            {
                _team_key(row.get("opponent_abbr"))
                for row in lineups + pitchers
                if _team_key(row.get("team_abbr")) == team and row.get("opponent_abbr")
            }
        )
        team_visual = pp_assets.get("teams", {}).get(team, {})

        hitting_players: list[dict[str, Any]] = []
        team_lineup = sorted(
            [row for row in lineups if _team_key(row.get("team_abbr")) == team],
            key=lambda row: (_int(row.get("batting_order")) or 99, str(row.get("player_name") or "")),
        )
        seen_hitters: set[str] = set()
        for row in team_lineup[:9]:
            person_id, roster = _resolve_person(row, roster_by_name)
            stat = season_stats.get(person_id or 0, {}).get("hitting", {})
            name = row.get("player_name") or roster.get("player_name") or ""
            if not name or _name_key(name) in seen_hitters:
                continue
            seen_hitters.add(_name_key(name))
            visual = pp_player(team, name)
            hitting_players.append(
                _stat_player(
                    name=name,
                    team=team,
                    position=str(row.get("position") or visual.get("position") or roster.get("primary_position") or ""),
                    jersey=visual.get("jersey_number") or roster.get("jersey_number"),
                    image_url=str(visual.get("image_url") or ""),
                    order=_int(row.get("batting_order")),
                    fields=_hitting_fields(stat),
                )
            )

        pitching_players: list[dict[str, Any]] = []
        for row in [row for row in pitchers if _team_key(row.get("team_abbr")) == team][:1]:
            person_id, roster = _resolve_person(row, roster_by_name)
            stat = season_stats.get(person_id or 0, {}).get("pitching", {})
            name = row.get("pitcher_name") or roster.get("player_name") or ""
            visual = pp_player(team, name)
            pitching_players.append(
                _stat_player(
                    name=name,
                    team=team,
                    position=f"SP {row.get('throws') or roster.get('throws') or visual.get('position') or ''}".strip(),
                    jersey=visual.get("jersey_number") or roster.get("jersey_number"),
                    image_url=str(visual.get("image_url") or ""),
                    fields=_pitching_fields(stat),
                )
            )

        team_relievers = sorted(
            [row for row in relievers if _team_key(row.get("team_abbr") or row.get("team")) == team],
            key=lambda row: (
                0 if str(row.get("position") or "").lower() == "closer" else 1,
                -(_num(row.get("innings_pitched")) or 0),
                str(row.get("player_name") or ""),
            ),
        )
        seen_pitchers = {_name_key(player.get("player")) for player in pitching_players}
        for row in team_relievers:
            if len(pitching_players) >= 4:
                break
            person_id, roster = _resolve_person(row, roster_by_name)
            name = row.get("player_name") or roster.get("player_name") or ""
            if not name or _name_key(name) in seen_pitchers:
                continue
            seen_pitchers.add(_name_key(name))
            stat = season_stats.get(person_id or 0, {}).get("pitching", {})
            visual = pp_player(team, name)
            pitching_players.append(
                _stat_player(
                    name=name,
                    team=team,
                    position=str(row.get("position") or visual.get("position") or "Bullpen"),
                    jersey=visual.get("jersey_number") or roster.get("jersey_number"),
                    image_url=str(visual.get("image_url") or ""),
                    fields=_pitching_fields(stat),
                )
            )

        if hitting_players or pitching_players:
            teams.append(
                {
                    "team": team,
                    "team_name": (
                        f"{team_visual.get('market') or ''} {team_visual.get('team_name') or ''}".strip()
                        or team_info.get("team_name")
                        or team
                    ),
                    "logo_url": team_visual.get("logo_url") or "",
                    "market": team_visual.get("market") or team_info.get("team_short_name") or "",
                    "opponents": opponents,
                    "sections": [
                        {
                            "label": "Hitting",
                            "meta": "Daily lineup",
                            "players": hitting_players,
                        },
                        {
                            "label": "Pitching",
                            "meta": "Probable SP and main bullpen arms",
                            "players": pitching_players,
                        },
                    ],
                }
            )

    return {
        "sport": "MLB",
        "source": "rotowire_lineups_statsapi_gamelogs",
        "teams": teams,
        "meta": {
            "lineups_path": str(lineups_path or ""),
            "pitchers_path": str(pitchers_path or ""),
            "relievers_path": str(relievers_path or ""),
            "season_gamelogs_path": str(season_path),
            "prizepicks_visual_payload": pp_assets.get("payload_path") or "",
            "team_count": len(teams),
        },
    }


def _public_picks(legs: list[dict[str, Any]], limit: int = 50) -> list[dict[str, Any]]:
    fields = ("sport", "id", "player", "team", "opp", "stat", "line", "dir", "tier", "p_cal")
    rows = []
    seen_players: set[str] = set()
    for leg in legs:
        player = str(leg.get("player") or "").lower()
        if player in seen_players:
            continue
        seen_players.add(player)
        rows.append({k: leg.get(k) for k in fields if k in leg})
        if len(rows) >= limit:
            break
    return rows


def build_payload(mlb_root: Path, run_id: str, out_dir: Path) -> Path:
    run_dir = _latest_live_run(mlb_root) if run_id == "latest" else mlb_root / "data" / "mlb" / "live_runs" / run_id
    if not run_dir.exists():
        raise SystemExit(f"MLB run not found: {run_dir}")

    all_legs = _load_all_legs(run_dir)
    _attach_recent_games_to_legs(all_legs, mlb_root / "data" / "mlb" / "season_gamelogs" / "latest.csv")
    marketed = _load_marketed(run_dir)
    system = _load_family(run_dir, "system")
    windfall = _load_family(run_dir, "windfall")
    demonhunter = _load_family(run_dir, "demonhunter")
    source_context = _load_source_context(run_dir)
    injury_context = _load_injury_context(run_dir, all_legs)
    performance = _load_performance(mlb_root)
    stat_hub = _load_mlb_stat_hub(mlb_root, run_dir, all_legs)
    generated = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    payload = {
        "generated_at": generated,
        "run_id": run_dir.name,
        "sport": "MLB",
        "system": system,
        "system_winprob": [],
        "windfall": windfall,
        "windfall_winprob": [],
        "demonhunter": demonhunter,
        "marketed_slips": marketed,
        "gamescript": [],
        "all_legs": all_legs,
        "top_hit_list": _top_hit_list(all_legs),
        "stat_hub": stat_hub,
        "injury_context": injury_context,
        "performance": performance,
        "source_context": source_context,
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    payload_path = out_dir / "cloudflare_payload.json"
    payload_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    picks_payload = {
        "generated_at": generated,
        "run_id": run_dir.name,
        "sport": "MLB",
        "picks": _public_picks(all_legs),
        "total_legs": len(all_legs),
        "total_slips": len(system) + len(windfall) + len(demonhunter) + len(marketed),
    }
    (out_dir / "picks_today.json").write_text(json.dumps(picks_payload, indent=2), encoding="utf-8")
    (out_dir / "status_latest.json").write_text(
        json.dumps({"ok": True, "sport": "MLB", "run_id": run_dir.name, "generated_at": generated}, indent=2),
        encoding="utf-8",
    )
    return payload_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mlb-root", default=r"C:\Users\13142\Atlas\MLB")
    parser.add_argument("--run-id", default="latest")
    parser.add_argument("--out-dir", default="")
    args = parser.parse_args()

    mlb_root = Path(args.mlb_root).resolve()
    out_dir = Path(args.out_dir).resolve() if args.out_dir else mlb_root / "data" / "mlb" / "output" / "dashboard"
    payload = build_payload(mlb_root=mlb_root, run_id=args.run_id, out_dir=out_dir)
    print(f"Wrote MLB dashboard payload: {payload}")


if __name__ == "__main__":
    main()
