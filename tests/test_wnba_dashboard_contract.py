import csv
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
            "recent_last_10_complete": "true",
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

    def test_wnba_l10_is_exported_only_for_exact_complete_ten(self) -> None:
        complete = BUILDER._leg_from_card(self._card_row("STANDARD", "over"), {})
        self.assertEqual((complete["l10_hr"], complete["l10_n"]), (0.70, 10))
        partial_row = self._card_row("STANDARD", "over")
        partial_row["recent_last_10_decisions"] = "2"
        partial_row["recent_last_10_complete"] = "false"
        partial = BUILDER._leg_from_card(partial_row, {})
        self.assertIsNone(partial["l10_hr"])
        self.assertIsNone(partial["l10_n"])

    def test_builder_card_path_is_resolved_from_live_builder_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            run_dir = Path(raw_root)
            card_path = run_dir / "atlas_candidate_compiler" / "builder_card" / "builder_card.csv"
            card_path.parent.mkdir(parents=True)
            row = self._card_row("STANDARD", "over")
            row["side_playable"] = "true"
            row["probability_surface_eligible"] = "true"
            with card_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=list(row))
                writer.writeheader()
                writer.writerow(row)
            (run_dir / "builder_manifest.json").write_text(
                json.dumps({"builder_card_path": str(card_path)}), encoding="utf-8"
            )

            legs, lookup = BUILDER._load_all_legs(run_dir, {})

        self.assertEqual(len(legs), 1)
        self.assertEqual(lookup["leg_1"]["player"], "Atlas Player")

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

    def test_performance_exports_only_consumer_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            summary_path = root / "data" / "wnba" / "waterfall" / "latest_public_performance.json"
            summary_path.parent.mkdir(parents=True)
            summary_path.write_text(
                json.dumps(
                    {
                        "version": "wnba_public_performance_v1",
                        "status": "complete",
                        "public": {
                            "overall": {
                                "last_7d": {"hit_rate": 0.60, "n": 17304},
                                "last_30d": {"hit_rate": 0.59, "n": 43058},
                            },
                            "by_tier": {
                                "GOBLIN": {
                                    "last_7d": {"hit_rate": 0.70, "n": 8786},
                                    "last_30d": {"hit_rate": 0.68, "n": 21765},
                                },
                                "STANDARD": {
                                    "last_7d": {"hit_rate": 0.51, "n": 7086},
                                    "last_30d": {"hit_rate": 0.52, "n": 18139},
                                },
                                "DEMON": {
                                    "last_7d": {"hit_rate": 0.42, "n": 1432},
                                    "last_30d": {"hit_rate": 0.38, "n": 3154},
                                },
                            },
                            "yesterday_slips": {
                                "date": "2026-07-30",
                                "wins": 1,
                                "total": 3,
                                "pct": 1 / 3,
                                "market": {"wins": 1, "total": 3, "pct": 1 / 3},
                            },
                            "meta": {"latest_game_date": "2026-07-29"},
                        },
                        "provenance": {
                            "private_model_identifier": "must_not_be_exported",
                            "private_research_metric": 0.123,
                        },
                    }
                ),
                encoding="utf-8",
            )

            performance = BUILDER._performance(root)

        self.assertEqual(performance["yesterday_slips"]["wins"], 1)
        self.assertEqual(performance["overall"]["last_30d"]["n"], 43058)
        exported = json.dumps(performance).lower()
        for forbidden in (
            "corpus",
            "protected",
            "oos",
            "package",
            "policy",
            "brier",
            "ece",
            "logloss",
            "private_model_identifier",
            "private_research_metric",
        ):
            self.assertNotIn(forbidden, exported)

    def test_performance_ui_has_no_internal_model_section(self) -> None:
        html = (ROOT / "public" / "dashboard" / "index.html").read_text(encoding="utf-8")
        for expected in ("Yesterday\\'s Slip Results", "Overall Leg Hit Rate", "Hit Rate By Tier"):
            self.assertIn(expected, html)
        for forbidden in (
            "Current Corpus Identity",
            "Protected Historical OOS",
            "Probability-Chain Gate",
            "Full Exact-Policy Corpus",
            "buildWnbaCorpusPerformance",
        ):
            self.assertNotIn(forbidden, html)

    def test_wnba_payload_builder_does_not_export_internal_runtime_identity(self) -> None:
        source = BUILDER_PATH.read_text(encoding="utf-8")
        exported_block = source[source.index('"source_context": {') : source.index("illegal = [leg")]
        for forbidden in (
            "probability_package_id",
            "builder_policy_id",
            "builder_card_sha256",
            "source_selection_manifest_sha256",
            'manifest.get("runtime_publication")',
        ):
            self.assertNotIn(forbidden, exported_block)


if __name__ == "__main__":
    unittest.main()
