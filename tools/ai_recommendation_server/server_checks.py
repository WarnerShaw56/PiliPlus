import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

import server


class ServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.config = root / "config.json"
        self.feed = root / "feed.json"
        self.history = root / "history.json"
        self.lock = root / "generation.lock"
        self.generator = root / "generate.py"
        self.config.write_text(
            json.dumps(
                {
                    "groups": [
                        {
                            "id": "games",
                            "name": "游戏",
                            "intent": "优质游戏视频",
                            "prompt": "只选择优质游戏视频",
                            "source": "recommendation",
                        }
                    ]
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        self.generator.write_text("", encoding="utf-8")
        server.CONFIG_PATH = self.config
        server.FEED_PATH = self.feed
        server.HISTORY_PATH = self.history
        server.LOCK_PATH = self.lock
        server.GENERATOR_PATH = self.generator
        server._generation_process = None
        server._generation_started_at = None
        server._generation_finished_at = None
        server._generation_exit_code = None
        self.client = TestClient(server.app)

    def tearDown(self) -> None:
        self.client.close()
        self.directory.cleanup()

    def test_group_crud_allows_deleting_the_last_group(self) -> None:
        response = self.client.get("/groups")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["groups"][0]["id"], "games")

        response = self.client.post(
            "/groups",
            json={
                "id": "game-search",
                "name": "游戏搜索",
                "intent": "游戏深度内容",
                "prompt": "优先高质量游戏深度内容",
                "source": "search",
                "search_queries": ["游戏设计", "游戏史"],
            },
        )
        self.assertEqual(response.status_code, 201)

        response = self.client.put(
            "/groups/game-search",
            json={
                **response.json(),
                "prompt": "更新后的完整评分标准",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["prompt"], "更新后的完整评分标准")

        self.assertEqual(
            self.client.delete("/groups/game-search").status_code,
            204,
        )
        self.assertEqual(
            self.client.delete("/groups/games").status_code,
            204,
        )
        self.assertEqual(self.client.get("/groups").json()["groups"], [])

    def test_expand_uses_ai_result(self) -> None:
        proposal = {
            "id": "games-12345678",
            "name": "游戏深扒",
            "intent": "优质游戏",
            "prompt": "完整标准",
            "source": "hybrid",
            "search_queries": ["游戏设计"],
        }
        with patch(
            "server.expand_preference",
            new=AsyncMock(return_value=proposal),
        ):
            response = self.client.post(
                "/groups/expand",
                json={"intent": "优质游戏", "source": "hybrid"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), proposal)

    def test_invalid_group_returns_bad_request(self) -> None:
        response = self.client.post(
            "/groups",
            json={
                "name": "无效搜索组",
                "intent": "想看游戏",
                "prompt": "筛选游戏",
                "source": "search",
                "search_queries": [],
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("search_queries", response.json()["detail"])

    def test_status_reports_existing_feed(self) -> None:
        self.feed.write_text(
            json.dumps(
                {
                    "generated_at": "2026-07-17T00:00:00Z",
                    "groups": [{"id": "games"}],
                }
            ),
            encoding="utf-8",
        )
        response = self.client.get("/status")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["running"])
        self.assertEqual(response.json()["feed_group_count"], 1)

    def test_generate_passes_shared_lock_path(self) -> None:
        process = AsyncMock()
        process.pid = 123
        process.returncode = None
        process.wait.return_value = 0
        spawn = AsyncMock(return_value=process)
        with patch("server.asyncio.create_subprocess_exec", new=spawn):
            response = self.client.post("/generate")
        self.assertEqual(response.status_code, 202)
        arguments = spawn.await_args.args
        lock_index = arguments.index("--lock")
        self.assertEqual(arguments[lock_index + 1], str(self.lock))


if __name__ == "__main__":
    unittest.main()
