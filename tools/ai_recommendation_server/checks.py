import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from generate import Candidate


class CandidateTests(unittest.TestCase):
    def test_feed_item_matches_mobile_schema(self) -> None:
        candidate = Candidate(
            bvid="BV-test",
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


if __name__ == "__main__":
    unittest.main()
