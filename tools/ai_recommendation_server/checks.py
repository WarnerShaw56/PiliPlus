import json
import os
import unittest
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
from generate import Candidate, Config, batches, fallback_decision, valid_decisions


class CandidateTests(unittest.TestCase):
    def candidate(self, bvid: str = "BV-test") -> Candidate:
        return Candidate(
            bvid=bvid,
            aid=1,
            cid=2,
            title="Test",
            cover=None,
            duration=600,
            pubdate=None,
            owner_mid=3,
            owner_name="UP",
            view=1000,
            like=100,
            danmu=10,
            is_followed=True,
            source_reason=None,
            transcript="subtitle",
        )

    def test_feed_item_matches_mobile_schema(self) -> None:
        candidate = self.candidate()

        item = candidate.to_feed_item(
            {
                "score": 105,
                "reason": "reason",
                "summary": "summary",
                "tags": ["a", "b", "c", "d", "e"],
            }
        )

        self.assertEqual(item["score"], 100)
        self.assertEqual(item["bvid"], "BV-test")
        self.assertEqual(item["tags"], ["a", "b", "c", "d"])
        self.assertEqual(item["transcript_source"], "subtitle")

    def test_valid_decisions_filters_deduplicates_and_sorts(self) -> None:
        candidates = [self.candidate("BV-1"), self.candidate("BV-2")]
        decisions = [
            {"bvid": "BV-1", "score": 50},
            {"bvid": "BV-missing", "score": 100},
            {"bvid": "BV-2", "score": 90},
            {"bvid": "BV-2", "score": 10},
        ]

        valid = valid_decisions(decisions, candidates)

        self.assertEqual([item["bvid"] for item in valid], ["BV-2", "BV-1"])

    def test_batch_and_fallback_helpers(self) -> None:
        candidates = [self.candidate(f"BV-{index}") for index in range(5)]
        self.assertEqual([len(batch) for batch in batches(candidates, 2)], [2, 2, 1])

        fallback = fallback_decision(
            candidates[0],
            {"bvid": candidates[0].bvid, "score": 88, "reason": "good"},
        )
        self.assertEqual(fallback["score"], 69)
        self.assertTrue(fallback["reason"].startswith("备选："))


class ConfigTests(unittest.TestCase):
    def load(self, data: dict) -> Config:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            return Config.load(path)

    def test_default_pipeline_uses_large_batched_pool(self) -> None:
        config = self.load({"preference": "games"})
        self.assertEqual(config.candidate_count, 300)
        self.assertEqual(config.shortlist_count, 120)
        self.assertEqual(config.batch_size, 40)
        self.assertEqual(config.finalist_count, 24)

    def test_candidate_limit_is_enforced(self) -> None:
        with self.assertRaisesRegex(ValueError, "between 5 and 500"):
            self.load({"preference": "games", "candidate_count": 501})


class PipelineTests(unittest.IsolatedAsyncioTestCase):
    async def test_pipeline_batches_reranks_and_fills(self) -> None:
        candidates = [CandidateTests().candidate(f"BV-{index}") for index in range(300)]

        class FakeBilibiliClient:
            def __init__(self, _cookie: str) -> None:
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args) -> None:
                pass

            async def recommendations(self, count: int, _page_size: int):
                return candidates[:count]

            async def subtitle(self, candidate: Candidate):
                return candidate, f"subtitle for {candidate.bvid}"

        async def fake_ai_rank(_config, batch, desired_count, stage):
            count = 2 if stage == "final" else desired_count
            return [
                {
                    "bvid": candidate.bvid,
                    "score": 90 - index,
                    "reason": "good",
                    "summary": "summary",
                    "tags": ["game"],
                }
                for index, candidate in enumerate(batch[:count])
            ]

        config = Config(preference="games")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "feed.json"
            with (
                patch.dict(os.environ, {"BILI_COOKIE": "secret"}),
                patch("generate.BilibiliClient", FakeBilibiliClient),
                patch("generate.ai_rank", fake_ai_rank),
            ):
                from generate import generate

                feed = await generate(config, output)

            self.assertEqual(feed["pipeline"]["candidates_fetched"], 300)
            self.assertEqual(feed["pipeline"]["ai_batches"], 3)
            self.assertEqual(feed["pipeline"]["subtitle_hits"], 24)
            self.assertEqual(len(feed["items"]), 8)
            self.assertTrue(feed["items"][2]["reason"].startswith("备选："))
            self.assertTrue(output.exists())


if __name__ == "__main__":
    unittest.main()
