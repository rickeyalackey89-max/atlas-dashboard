import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "tools" / "build_wnba_dashboard_payload.py"
SPEC = importlib.util.spec_from_file_location("build_wnba_dashboard_payload", BUILDER_PATH)
assert SPEC and SPEC.loader
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class WnbaDashboardContractTests(unittest.TestCase):
    def _card_row(self, tier: str, side: str) -> dict[str, str]:
        return {
            "source_scored_leg_id": "leg_1",
            "builder_card_row_id": "card_1",
            "player_name": "Atlas Player",
            "canonical_team_abbr": "DAL",
            "opponent_abbr": "WSH",
            "market": "points",
            "line": "12.5",
            "tier": tier,
            "side": side,
            "final_probability": "0.61",
            "expected_stat": "14.0",
            "recent_last_10_decisions": "10",
            "recent_last_10_hit_rate": "0.70",
            "recent_last_20_decisions": "20",
            "recent_last_20_hit_rate": "0.65",
            "usage": "24.0",
        }

    def test_alternate_tier_under_fails_closed(self) -> None:
        for tier in ("DEMON", "GOBLIN"):
            with self.assertRaisesRegex(RuntimeError, "Illegal playable"):
                BUILDER._leg_from_card(self._card_row(tier, "under"), {})

    def test_standard_under_and_demon_over_are_exportable(self) -> None:
        standard = BUILDER._leg_from_card(self._card_row("STANDARD", "under"), {})
        demon = BUILDER._leg_from_card(self._card_row("DEMON", "over"), {})
        self.assertEqual((standard["tier"], standard["dir"]), ("STANDARD", "UNDER"))
        self.assertEqual((demon["tier"], demon["dir"]), ("DEMON", "OVER"))
        self.assertEqual(demon["sport"], "WNBA")

    def test_dashboard_exposes_wnba_and_all_eight_tabs(self) -> None:
        html = (ROOT / "public" / "dashboard" / "index.html").read_text(encoding="utf-8")
        self.assertIn('data-sport="wnba"', html)
        self.assertIn("/data/wnba/picks_today.json", html)
        self.assertIn("var parlayLegPools = { nba: [], mlb: [], wnba: [] };", html)
        for tab in ("probability", "ev", "stathub", "beyond", "slips", "market", "injury", "performance"):
            self.assertIn(f'data-sub="{tab}"', html)

    def test_secure_api_and_publisher_know_wnba(self) -> None:
        api = (ROOT / "functions" / "api" / "premium-data.js").read_text(encoding="utf-8")
        publisher = (ROOT / "publish-atlas.ps1").read_text(encoding="utf-8")
        self.assertIn("premium:wnba:dashboard:latest", api)
        self.assertIn("/data/wnba/cloudflare_payload.json", api)
        self.assertIn('[ValidateSet("nba","mlb","wnba")]', publisher)
        self.assertIn("refusing to publish the full premium payload publicly", publisher)


if __name__ == "__main__":
    unittest.main()
