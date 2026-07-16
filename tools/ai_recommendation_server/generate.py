#!/usr/bin/env python3
"""Generate a static PiliPlus AI recommendation feed on a trusted server."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

import httpx

MIXIN_KEY_ENC_TAB = (
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
)
INVALID_WBI_CHARS = re.compile(r"[!'()*]")


@dataclass(frozen=True)
class Config:
    preference: str
    candidate_count: int = 300
    shortlist_count: int = 120
    fetch_page_size: int = 30
    batch_size: int = 40
    batch_result_count: int = 12
    finalist_count: int = 24
    result_count: int = 8
    transcript_chars: int = 3500
    fill_results: bool = True
    redact_preference: bool = True

    @classmethod
    def load(cls, path: Path) -> "Config":
        data = json.loads(path.read_text(encoding="utf-8"))
        config = cls(**data)
        if not 5 <= config.candidate_count <= 500:
            raise ValueError("candidate_count must be between 5 and 500")
        if not 10 <= config.fetch_page_size <= 50:
            raise ValueError("fetch_page_size must be between 10 and 50")
        if not 5 <= config.batch_size <= 100:
            raise ValueError("batch_size must be between 5 and 100")
        if not 1 <= config.batch_result_count <= config.batch_size:
            raise ValueError("batch_result_count must be between 1 and batch_size")
        if (
            not 1
            <= config.result_count
            <= config.finalist_count
            <= config.shortlist_count
            <= config.candidate_count
        ):
            raise ValueError(
                "result_count <= finalist_count <= shortlist_count "
                "<= candidate_count is required"
            )
        return config


@dataclass(frozen=True)
class Candidate:
    bvid: str
    aid: int | None
    cid: int | None
    title: str
    cover: str | None
    duration: int
    pubdate: int | None
    owner_mid: int | None
    owner_name: str
    view: int | None
    like: int | None
    danmu: int | None
    is_followed: bool
    source_reason: str | None
    transcript: str | None = None

    @classmethod
    def from_feed_item(cls, item: dict[str, Any]) -> "Candidate":
        owner = item.get("owner") or {}
        stat = item.get("stat") or {}
        return cls(
            bvid=str(item["bvid"]),
            aid=_int(item.get("id")),
            cid=_int(item.get("cid")),
            title=str(item.get("title") or ""),
            cover=item.get("pic"),
            duration=_int(item.get("duration")) or 0,
            pubdate=_int(item.get("pubdate")),
            owner_mid=_int(owner.get("mid")),
            owner_name=str(owner.get("name") or ""),
            view=_int(stat.get("view")),
            like=_int(stat.get("like")),
            danmu=_int(stat.get("danmaku")),
            is_followed=item.get("is_followed") == 1,
            source_reason=(item.get("rcmd_reason") or {}).get("content"),
        )

    @property
    def heuristic_score(self) -> float:
        view = max(self.view or 0, 0)
        like_ratio = (self.like or 0) / max(view, 1)
        return (
            math.log10(view + 1) * 5
            + min(like_ratio, 0.2) * 180
            + (12 if self.is_followed else 0)
        )

    def with_transcript(self, transcript: str | None) -> "Candidate":
        return Candidate(**{**self.__dict__, "transcript": transcript})

    def to_prompt(self, transcript_chars: int) -> dict[str, Any]:
        return {
            "bvid": self.bvid,
            "title": self.title,
            "up": self.owner_name,
            "duration_seconds": self.duration,
            "published_at_unix": self.pubdate,
            "view": self.view,
            "like": self.like,
            "danmu": self.danmu,
            "followed_up": self.is_followed,
            "source_reason": self.source_reason,
            "subtitle_excerpt": (
                self.transcript[:transcript_chars] if self.transcript else None
            ),
        }

    def to_feed_item(self, decision: dict[str, Any]) -> dict[str, Any]:
        return {
            "bvid": self.bvid,
            "aid": self.aid,
            "cid": self.cid,
            "title": self.title,
            "cover": self.cover,
            "duration": self.duration,
            "pubdate": self.pubdate,
            "owner_mid": self.owner_mid,
            "owner_name": self.owner_name,
            "view": self.view,
            "like": self.like,
            "danmu": self.danmu,
            "is_followed": self.is_followed,
            "source_reason": self.source_reason,
            "score": max(0, min(100, round(float(decision.get("score", 0))))),
            "reason": str(decision.get("reason") or ""),
            "summary": str(decision.get("summary") or ""),
            "tags": [str(tag) for tag in decision.get("tags") or []][:4],
            "transcript_source": "subtitle" if self.transcript else "metadata",
        }


class BilibiliClient:
    def __init__(self, cookie: str) -> None:
        self.http = httpx.AsyncClient(
            base_url="https://api.bilibili.com",
            timeout=20,
            headers={
                "cookie": cookie,
                "referer": "https://www.bilibili.com/",
                "user-agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/131.0 Safari/537.36"
                ),
            },
        )
        self._mixin_key: str | None = None

    async def __aenter__(self) -> "BilibiliClient":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.http.aclose()

    async def _json(
        self, path: str, params: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        response = await self.http.get(path, params=params)
        response.raise_for_status()
        payload = response.json()
        if payload.get("code") != 0:
            raise RuntimeError(f"Bilibili API {path}: {payload.get('message')}")
        return payload.get("data") or {}

    async def _get_mixin_key(self) -> str:
        if self._mixin_key:
            return self._mixin_key
        data = await self._json("/x/web-interface/nav")
        wbi_img = data.get("wbi_img") or {}
        img_key = Path(wbi_img["img_url"]).stem
        sub_key = Path(wbi_img["sub_url"]).stem
        source = img_key + sub_key
        self._mixin_key = "".join(source[index] for index in MIXIN_KEY_ENC_TAB)[:32]
        return self._mixin_key

    async def _sign(self, params: dict[str, Any]) -> dict[str, Any]:
        signed = {
            key: INVALID_WBI_CHARS.sub("", str(value))
            for key, value in params.items()
            if value is not None
        }
        signed["wts"] = int(time.time())
        query = urlencode(sorted(signed.items()))
        signed["w_rid"] = hashlib.md5(
            (query + await self._get_mixin_key()).encode()
        ).hexdigest()
        return signed

    async def recommendations(
        self,
        count: int,
        page_size: int = 30,
    ) -> list[Candidate]:
        candidates: list[Candidate] = []
        seen: set[str] = set()
        empty_pages = 0
        pages_to_try = min(40, max(4, math.ceil(count / page_size) * 2))

        for fresh_idx in range(1, pages_to_try + 1):
            params = await self._sign(
                {
                    "version": 1,
                    "feed_version": "V8",
                    "homepage_ver": 1,
                    "ps": min(page_size, max(count - len(candidates), 1)),
                    "fresh_idx": fresh_idx,
                    "brush": fresh_idx,
                    "fresh_type": 4,
                }
            )
            data = await self._json(
                "/x/web-interface/wbi/index/top/feed/rcmd",
                params,
            )
            added = 0
            for item in data.get("item") or []:
                bvid = str(item.get("bvid") or "")
                if (
                    item.get("goto") == "av"
                    and bvid
                    and item.get("owner")
                    and bvid not in seen
                ):
                    seen.add(bvid)
                    candidates.append(Candidate.from_feed_item(item))
                    added += 1
                    if len(candidates) >= count:
                        break

            print(
                f"recommendation page {fresh_idx}: +{added}, "
                f"total {len(candidates)}/{count}"
            )
            if len(candidates) >= count:
                break
            empty_pages = empty_pages + 1 if added == 0 else 0
            if empty_pages >= 4:
                print("stopping after four pages without new videos")
                break
            await asyncio.sleep(0.35)

        return candidates[:count]

    async def subtitle(self, candidate: Candidate) -> tuple[Candidate, str | None]:
        cid = candidate.cid
        if cid is None:
            view = await self._json("/x/web-interface/view", {"bvid": candidate.bvid})
            pages = view.get("pages") or []
            cid = _int(pages[0].get("cid")) if pages else None
        if cid is None:
            return candidate, None
        player = await self._json(
            "/x/player/wbi/v2",
            await self._sign({"bvid": candidate.bvid, "cid": cid}),
        )
        subtitles = (player.get("subtitle") or {}).get("subtitles") or []
        if not subtitles:
            return candidate, None
        preferred = next(
            (item for item in subtitles if str(item.get("lan", "")).startswith("zh")),
            subtitles[0],
        )
        url = str(preferred.get("subtitle_url") or "")
        if url.startswith("//"):
            url = "https:" + url
        response = await self.http.get(url)
        response.raise_for_status()
        text = "\n".join(
            str(line.get("content") or "").strip()
            for line in response.json().get("body") or []
        ).strip()
        return candidate, text or None


async def enrich_subtitles(
    bili: BilibiliClient,
    candidates: list[Candidate],
) -> list[Candidate]:
    semaphore = asyncio.Semaphore(4)

    async def one(candidate: Candidate) -> Candidate:
        async with semaphore:
            try:
                original, transcript = await bili.subtitle(candidate)
                return original.with_transcript(transcript)
            except Exception as error:
                print(f"subtitle unavailable for {candidate.bvid}: {error}")
                return candidate

    return await asyncio.gather(*(one(candidate) for candidate in candidates))


async def ai_rank(
    config: Config,
    candidates: list[Candidate],
    desired_count: int,
    stage: str,
) -> list[dict[str, Any]]:
    api_key = required_env("AI_API_KEY")
    endpoint = os.getenv("AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    if not endpoint.endswith("/chat/completions"):
        endpoint += "/chat/completions"
    model = required_env("AI_MODEL")
    desired_count = min(desired_count, len(candidates))
    task = (
        f"这是元数据初筛，从候选中选出最合适的 {desired_count} 条进入最终复排。"
        f"候选足够时必须返回 {desired_count} 条；严格不符合硬性条件的不要选，"
        "较弱但仍可接受的项目可以标记为备选。"
        if stage == "preliminary"
        else (
            f"这是最终复排，从候选中选出 {desired_count} 条。"
            f"候选足够时尽量返回 {desired_count} 条；有字幕时以字幕为主要依据，"
            "无字幕时明确只按元数据判断。严格违反用户硬性排除条件的内容不得用于补足。"
        )
    )
    prompt = {
        "stage": stage,
        "task": task
        + "score 为 0-100 时间价值分，reason 和 summary 使用中文，不得虚构。",
        "user_preference": config.preference,
        "output_schema": {
            "recommendations": [
                {
                    "bvid": "候选 bvid",
                    "score": 0,
                    "reason": "string",
                    "summary": "string",
                    "tags": ["string"],
                }
            ]
        },
        "candidates": [item.to_prompt(config.transcript_chars) for item in candidates],
    }
    async with httpx.AsyncClient(timeout=120) as http:
        response = await http.post(
            endpoint,
            headers={"authorization": f"Bearer {api_key}"},
            json={
                "model": model,
                "temperature": 0.2,
                "messages": [
                    {
                        "role": "system",
                        "content": "你是严谨的视频内容编辑。只输出一个 JSON 对象。",
                    },
                    {"role": "user", "content": json.dumps(prompt, ensure_ascii=False)},
                ],
            },
        )
        response.raise_for_status()
        content = response.json()["choices"][0]["message"]["content"]
    start, end = content.find("{"), content.rfind("}")
    if start < 0 or end <= start:
        raise RuntimeError("AI response did not contain JSON")
    decisions = json.loads(content[start : end + 1]).get("recommendations")
    if not isinstance(decisions, list):
        raise RuntimeError("AI response did not contain recommendations")
    return decisions


def _decision_score(decision: dict[str, Any]) -> float:
    try:
        return float(decision.get("score", 0))
    except (TypeError, ValueError):
        return 0


def valid_decisions(
    decisions: list[dict[str, Any]],
    candidates: list[Candidate],
) -> list[dict[str, Any]]:
    valid_bvids = {candidate.bvid for candidate in candidates}
    seen: set[str] = set()
    valid = []
    for decision in decisions:
        if not isinstance(decision, dict):
            continue
        bvid = str(decision.get("bvid") or "")
        if bvid in valid_bvids and bvid not in seen:
            seen.add(bvid)
            valid.append(decision)
    return sorted(valid, key=_decision_score, reverse=True)


def batches(candidates: list[Candidate], size: int) -> list[list[Candidate]]:
    return [
        candidates[index : index + size] for index in range(0, len(candidates), size)
    ]


def fallback_decision(
    candidate: Candidate,
    preliminary: dict[str, Any] | None,
) -> dict[str, Any]:
    if preliminary:
        reason = str(preliminary.get("reason") or "按初筛结果补足")
        return {
            **preliminary,
            "bvid": candidate.bvid,
            "score": min(69, round(_decision_score(preliminary))),
            "reason": f"备选：{reason}",
            "tags": ["备选", *[str(tag) for tag in preliminary.get("tags") or []]][:4],
        }
    return {
        "bvid": candidate.bvid,
        "score": min(59, round(candidate.heuristic_score)),
        "reason": "备选：AI 返回数量不足，按互动质量补足",
        "summary": "仅根据标题、UP、时长和互动数据生成的备选。",
        "tags": ["备选", "元数据"],
    }


async def generate(config: Config, output: Path) -> dict[str, Any]:
    async with BilibiliClient(required_env("BILI_COOKIE")) as bili:
        candidates = await bili.recommendations(
            config.candidate_count,
            config.fetch_page_size,
        )
        if not candidates:
            raise RuntimeError("Bilibili recommendation feed returned no videos")
        shortlist = sorted(
            candidates, key=lambda item: item.heuristic_score, reverse=True
        )[: config.shortlist_count]
        preliminary_decisions: list[dict[str, Any]] = []
        shortlist_batches = batches(shortlist, config.batch_size)
        for index, batch in enumerate(shortlist_batches, start=1):
            print(f"AI metadata batch {index}/{len(shortlist_batches)}: {len(batch)}")
            decisions = await ai_rank(
                config,
                batch,
                config.batch_result_count,
                "preliminary",
            )
            preliminary_decisions.extend(valid_decisions(decisions, batch))

        preliminary_decisions = valid_decisions(preliminary_decisions, shortlist)
        preliminary_by_bvid = {
            str(decision.get("bvid")): decision for decision in preliminary_decisions
        }
        shortlist_by_bvid = {candidate.bvid: candidate for candidate in shortlist}
        ranked_candidates = [
            shortlist_by_bvid[str(decision.get("bvid"))]
            for decision in preliminary_decisions
        ]
        ranked_bvids = {candidate.bvid for candidate in ranked_candidates}
        ranked_candidates.extend(
            candidate for candidate in shortlist if candidate.bvid not in ranked_bvids
        )
        finalists = ranked_candidates[: config.finalist_count]
        enriched = await enrich_subtitles(bili, finalists)

    decisions = await ai_rank(
        config,
        enriched,
        config.result_count,
        "final",
    )
    decisions = valid_decisions(decisions, enriched)[: config.result_count]
    if config.fill_results and len(decisions) < config.result_count:
        selected_bvids = {str(decision.get("bvid")) for decision in decisions}
        for candidate in enriched:
            if candidate.bvid in selected_bvids:
                continue
            decisions.append(
                fallback_decision(
                    candidate,
                    preliminary_by_bvid.get(candidate.bvid),
                )
            )
            selected_bvids.add(candidate.bvid)
            if len(decisions) >= config.result_count:
                break

    by_bvid = {item.bvid: item for item in enriched}
    items = [
        by_bvid[str(decision.get("bvid"))].to_feed_item(decision)
        for decision in decisions
        if str(decision.get("bvid")) in by_bvid
    ][: config.result_count]
    if not items:
        raise RuntimeError("AI returned no valid candidate bvid")

    feed = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "vps",
        "preference_snapshot": "" if config.redact_preference else config.preference,
        "pipeline": {
            "candidate_target": config.candidate_count,
            "candidates_fetched": len(candidates),
            "heuristic_shortlist": len(shortlist),
            "ai_batches": len(shortlist_batches),
            "preliminary_ranked": len(preliminary_decisions),
            "finalists": len(enriched),
            "subtitle_hits": sum(1 for candidate in enriched if candidate.transcript),
            "result_count": len(items),
        },
        "items": items,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(feed, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temporary.replace(output)
    return feed


def required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"missing environment variable: {name}")
    return value


def _int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("config.json"))
    parser.add_argument("--output", type=Path, default=Path("public/feed.json"))
    args = parser.parse_args()
    feed = asyncio.run(generate(Config.load(args.config), args.output))
    print(f"wrote {len(feed['items'])} recommendations to {args.output}")


if __name__ == "__main__":
    main()
