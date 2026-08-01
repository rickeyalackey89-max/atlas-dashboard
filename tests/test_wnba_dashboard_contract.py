import importlib.util
import json
import tempfile
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

    def test_performance_uses_verified_current_corpus_identity(self) -> None:
        snapshot = json.loads((ROOT / "config" / "wnba_corpus_performance.json").read_text(encoding="utf-8"))
        identity = snapshot["identity"]
        sources = snapshot["source_evidence"]
        with tempfile.TemporaryDirectory() as temp_dir:
            wnba_root = Path(temp_dir)
            builders = wnba_root / "data" / "wnba" / "model_champion" / "builders"
            builders.mkdir(parents=True)
            (builders / "active_builder_promotion.json").write_text(json.dumps({
                "status": "phase10_complete_promoted_live_verified",
                "phase10_complete": True,
                "probability_package_id": identity["probability_package_id"],
                "package_id": identity["builder_package_id"],
                "promotion_id": identity["builder_promotion_id"],
                "active_policy": {"policy_id": identity["builder_policy_id"]},
                "evidence": {
                    "protected_date_oos_manifest": {"sha256": sources["protected_builder_oos_sha256"]},
                    "final_policy_evaluation_manifest": {"sha256": sources["full_exact_policy_corpus_sha256"]},
                },
            }), encoding="utf-8")
            package_dir = (
                wnba_root / "data" / "wnba" / "model_champion" / "full_chain"
                / identity["probability_package_id"]
            )
            package_dir.mkdir(parents=True)
            (package_dir / "generation2_phase9_package_manifest.json").write_text(json.dumps({
                "evidence_inputs": {
                    "phase8_protected_gate": {"sha256": sources["phase8_protected_gate_sha256"]}
                }
            }), encoding="utf-8")
            waterfall_dir = wnba_root / "data" / "wnba" / "waterfall"
            waterfall_dir.mkdir(parents=True)
            (waterfall_dir / "latest_waterfall_manifest.json").write_text(json.dumps({
                "active_model": {
                    "probability_package_id": identity["probability_package_id"],
                    "builder_policy_id": identity["builder_policy_id"],
                },
                "target_date": "2026-07-30",
                "rolling_windows": {"last_1_game_dates": {"dates": ["2026-07-30"]}},
                "daily": {"slips": {
                    "metric_count": 3,
                    "win_rate": 1 / 3,
                    "by_size": {"2": {"metric_count": 1, "win_rate": 0.0}},
                }},
            }), encoding="utf-8")

            performance = BUILDER._performance(wnba_root)
            self.assertTrue(performance["identity_verified"])
            self.assertEqual(performance["protected_builder_oos"]["by_size"]["2"]["strict_wins"], 22)
            self.assertEqual(performance["full_exact_policy_corpus"]["member_count"], 84)
            self.assertEqual(performance["latest_live"]["scope"], "prospective_scored_live_run")

    def test_performance_rejects_stale_model_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            wnba_root = Path(temp_dir)
            builders = wnba_root / "data" / "wnba" / "model_champion" / "builders"
            builders.mkdir(parents=True)
            (builders / "active_builder_promotion.json").write_text(json.dumps({
                "status": "phase10_complete_promoted_live_verified",
                "phase10_complete": True,
                "probability_package_id": "stale_package",
            }), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "does not match the active package"):
                BUILDER._performance(wnba_root)


if __name__ == "__main__":
    unittest.main()
