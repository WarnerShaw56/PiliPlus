#!/usr/bin/env python3
"""Generate a static PiliPlus AI recommendation feed on a trusted server."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import html
import json
import math
import os
import re
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
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
HTML_TAGS = re.compile(r"<[^>]+>")
GROUP_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
GROUP_SOURCES = {"recommendation", "search", "hybrid"}


@dataclass(frozen=True)
class PreferenceGroup:
    id: str
    name: str
    intent: str
    prompt: str
    source: str = "recommendation"
    search_queries: tuple[str, ...] = ()
    result_count: int = 8
    minimum_duration_seconds: int = 900
    enabled: bool = True

    @classmethod
    def from_json(
        cls,
        data: dict[str, Any],
        *,
        default_minimum_duration_seconds: int,
        default_result_count: int,
    ) -> "PreferenceGroup":
        intent = str(data.get("intent") or data.get("prompt") or "").strip()
        prompt = str(data.get("prompt") or intent).strip()
        name = str(data.get("name") or intent[:24] or "未命名偏好").strip()
        group_id = str(data.get("id") or _group_id(name)).strip().lower()
        source = str(data.get("source") or "recommendation").strip().lower()
        queries = tuple(
            dict.fromkeys(
                str(query).strip()
                for query in data.get("search_queries") or []
                if str(query).strip()
            )
        )
        group = cls(
            id=group_id,
            name=name,
            intent=intent,
            prompt=prompt,
            source=source,
            search_queries=queries[:12],
            result_count=_int(data.get("result_count")) or default_result_count,
            minimum_duration_seconds=(
                _int(data.get("minimum_duration_seconds"))
                or default_minimum_duration_seconds
            ),
            enabled=data.get("enabled", True) is not False,
        )
        group.validate()
        return group

    def validate(self) -> None:
        if not GROUP_ID.fullmatch(self.id):
            raise ValueError(
                "group id must contain only lowercase letters, numbers, _ or -"
            )
        if not self.name or len(self.name) > 60:
            raise ValueError("group name must be between 1 and 60 characters")
        if not self.intent or len(self.intent) > 2000:
            raise ValueError("group intent must be between 1 and 2000 characters")
        if not self.prompt or len(self.prompt) > 12000:
            raise ValueError("group prompt must be between 1 and 12000 characters")
        if self.source not in GROUP_SOURCES:
            raise ValueError(f"unsupported group source: {self.source}")
        if self.source in {"search", "hybrid"} and not self.search_queries:
            raise ValueError("search and hybrid groups require search_queries")
        if not 1 <= self.result_count <= 30:
            raise ValueError("group result_count must be between 1 and 30")
        if not 60 <= self.minimum_duration_seconds <= 14400:
            raise ValueError(
                "group minimum_duration_seconds must be between 60 and 14400"
            )

    def to_json(self, *, redact_prompt: bool = False) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "intent": self.intent,
            "prompt": "" if redact_prompt else self.prompt,
            "source": self.source,
            "search_queries": list(self.search_queries),
            "result_count": self.result_count,
            "minimum_duration_seconds": self.minimum_duration_seconds,
            "enabled": self.enabled,
        }


@dataclass(frozen=True)
class Config:
    preference: str = ""
    groups: tuple[PreferenceGroup, ...] = ()
    candidate_count: int = 2000
    minimum_duration_seconds: int = 900
    shortlist_count: int = 400
    fetch_page_size: int = 30
    batch_size: int = 40
    batch_result_count: int = 16
    finalist_count: int = 60
    result_count: int = 8
    transcript_chars: int = 3500
    fill_results: bool = True
    redact_preference: bool = True
    search_pages_per_query: int = 2
    search_query_limit: int = 8
    search_history_days: int = 30

    @classmethod
    def load(cls, path: Path) -> "Config":
        return cls.from_json(json.loads(path.read_text(encoding="utf-8")))

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Config":
        raw = dict(data)
        raw_groups = raw.pop("groups", None)
        config = cls(**raw)
        if not 5 <= config.candidate_count <= 2500:
            raise ValueError("candidate_count must be between 5 and 2500")
        if not 60 <= config.minimum_duration_seconds <= 14400:
            raise ValueError("minimum_duration_seconds must be between 60 and 14400")
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
        if not 1 <= config.search_pages_per_query <= 5:
            raise ValueError("search_pages_per_query must be between 1 and 5")
        if not 1 <= config.search_query_limit <= 12:
            raise ValueError("search_query_limit must be between 1 and 12")
        if not 1 <= config.search_history_days <= 365:
            raise ValueError("search_history_days must be between 1 and 365")

        if raw_groups is None:
            if not config.preference.strip():
                raise ValueError("preference or groups is required")
            groups = (
                PreferenceGroup(
                    id="default",
                    name="每日精选",
                    intent=config.preference.strip(),
                    prompt=config.preference.strip(),
                    result_count=config.result_count,
                    minimum_duration_seconds=config.minimum_duration_seconds,
                ),
            )
        else:
            if not isinstance(raw_groups, list):
                raise ValueError("groups must be a list")
            groups = tuple(
                PreferenceGroup.from_json(
                    dict(item),
                    default_minimum_duration_seconds=(config.minimum_duration_seconds),
                    default_result_count=config.result_count,
                )
                for item in raw_groups
                if isinstance(item, dict)
            )
        if len(groups) > 12:
            raise ValueError("at most 12 preference groups are supported")
        ids = [group.id for group in groups]
        if len(ids) != len(set(ids)):
            raise ValueError("preference group ids must be unique")
        return cls(**{**config.__dict__, "groups": groups})

    def to_json(self) -> dict[str, Any]:
        return {
            "preference": self.preference,
            "groups": [group.to_json() for group in self.groups],
            "candidate_count": self.candidate_count,
            "minimum_duration_seconds": self.minimum_duration_seconds,
            "shortlist_count": self.shortlist_count,
            "fetch_page_size": self.fetch_page_size,
            "batch_size": self.batch_size,
            "batch_result_count": self.batch_result_count,
            "finalist_count": self.finalist_count,
            "result_count": self.result_count,
            "transcript_chars": self.transcript_chars,
            "fill_results": self.fill_results,
            "redact_preference": self.redact_preference,
            "search_pages_per_query": self.search_pages_per_query,
            "search_query_limit": self.search_query_limit,
            "search_history_days": self.search_history_days,
        }


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

    @classmethod
    def from_search_item(
        cls,
        item: dict[str, Any],
        *,
        query: str,
        order: str,
    ) -> "Candidate":
        cover = str(item.get("pic") or "") or None
        if cover and cover.startswith("//"):
            cover = "https:" + cover
        return cls(
            bvid=str(item["bvid"]),
            aid=_int(item.get("aid")),
            cid=None,
            title=html.unescape(
                HTML_TAGS.sub("", str(item.get("title") or "")).strip()
            ),
            cover=cover,
            duration=_duration_seconds(item.get("duration")),
            pubdate=_int(item.get("pubdate")),
            owner_mid=_int(item.get("mid")),
            owner_name=str(item.get("author") or ""),
            view=_int(item.get("play")),
            like=_int(item.get("like")),
            danmu=_int(item.get("danmaku")),
            is_followed=False,
            source_reason=f"搜索：{query} · {order}",
        )

    @property
    def heuristic_score(self) -> float:
        view = max(self.view or 0, 0)
        like_ratio = (self.like or 0) / max(view, 1)
        duration_bonus = min(max(self.duration - 900, 0) / 2700, 1) * 10
        return (
            math.log10(view + 1) * 5
            + min(like_ratio, 0.2) * 180
            + (12 if self.is_followed else 0)
            + duration_bonus
        )

    def with_transcript(self, transcript: str | None) -> "Candidate":
        return Candidate(**{**self.__dict__, "transcript": transcript})

    def to_prompt(
        self,
        transcript_chars: int,
        *,
        seen_recently: bool = False,
    ) -> dict[str, Any]:
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
            "seen_recently": seen_recently,
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
        pages_to_try = min(160, max(4, math.ceil(count / page_size) * 2))

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

    async def search(
        self,
        query: str,
        *,
        page: int,
        order: str,
    ) -> list[Candidate]:
        data = await self._json(
            "/x/web-interface/wbi/search/type",
            await self._sign(
                {
                    "search_type": "video",
                    "keyword": query,
                    "page": page,
                    "page_size": 20,
                    "order": order,
                    "platform": "pc",
                    "web_location": 1430654,
                }
            ),
        )
        candidates = []
        for item in data.get("result") or []:
            bvid = str(item.get("bvid") or "")
            if bvid:
                candidates.append(
                    Candidate.from_search_item(item, query=query, order=order)
                )
        return candidates

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
    group: PreferenceGroup,
    candidates: list[Candidate],
    desired_count: int,
    stage: str,
    recently_recommended: set[str] | None = None,
) -> list[dict[str, Any]]:
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
        "preference_group": {
            "name": group.name,
            "intent": group.intent,
            "scoring_prompt": group.prompt,
            "source": group.source,
        },
        "repeat_policy": (
            "seen_recently=true 表示最近已推荐；除非新候选明显更差，否则应优先未推荐内容。"
        ),
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
        "candidates": [
            item.to_prompt(
                config.transcript_chars,
                seen_recently=(item.bvid in (recently_recommended or set())),
            )
            for item in candidates
        ],
    }
    payload = await _ai_json(
        prompt,
        system_prompt="你是严谨的视频内容编辑。只输出一个 JSON 对象。",
    )
    decisions = payload.get("recommendations")
    if not isinstance(decisions, list):
        raise RuntimeError("AI response did not contain recommendations")
    return decisions


async def expand_preference(
    intent: str,
    source: str,
) -> dict[str, Any]:
    intent = intent.strip()
    source = source.strip().lower()
    if not intent:
        raise ValueError("intent is required")
    if source not in GROUP_SOURCES:
        raise ValueError(f"unsupported group source: {source}")
    task = {
        "task": (
            "把用户的一句视频偏好扩写成可直接用于候选视频评分的中文标准。"
            "保留用户原意，不擅自增加价值观限制。评分标准必须包含：硬性排除项、"
            "内容相关性、信息或娱乐价值、制作质量、标题党/低质信号、时长价值，"
            "以及 0-100 分档说明。"
        ),
        "intent": intent,
        "source": source,
        "search_query_rules": (
            "若来源包含搜索，生成 4-8 个语义明确且彼此有差异的 B 站搜索短语；"
            "覆盖主题、内容形式和细分方向。不要添加随机字母、乱码或规避平台机制的词。"
        ),
        "output_schema": {
            "name": "不超过 12 个汉字的组名",
            "prompt": "完整中文评分标准",
            "search_queries": ["搜索短语"],
        },
    }
    payload = await _ai_json(
        task,
        system_prompt=(
            "你是推荐系统的偏好建模编辑。忠实扩写用户意图，只输出 JSON 对象。"
        ),
    )
    name = str(payload.get("name") or intent[:12]).strip()
    prompt = str(payload.get("prompt") or "").strip()
    queries = list(
        dict.fromkeys(
            str(query).strip()
            for query in payload.get("search_queries") or []
            if str(query).strip()
        )
    )
    if not prompt:
        raise RuntimeError("AI preference expansion did not contain prompt")
    if source in {"search", "hybrid"} and not queries:
        queries = [intent]
    return {
        "id": _group_id(name),
        "name": name[:60],
        "intent": intent,
        "prompt": prompt,
        "source": source,
        "search_queries": queries[:12],
    }


async def _ai_json(
    prompt: dict[str, Any],
    *,
    system_prompt: str,
) -> dict[str, Any]:
    api_key = required_env("AI_API_KEY")
    endpoint = os.getenv("AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    if not endpoint.endswith("/chat/completions"):
        endpoint += "/chat/completions"
    model = required_env("AI_MODEL")
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
                        "content": system_prompt,
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
    payload = json.loads(content[start : end + 1])
    if not isinstance(payload, dict):
        raise RuntimeError("AI response JSON was not an object")
    return payload


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
    preliminary: dict[str, Any],
) -> dict[str, Any]:
    reason = str(preliminary.get("reason") or "按初筛结果补足")
    return {
        **preliminary,
        "bvid": candidate.bvid,
        "score": min(69, round(_decision_score(preliminary))),
        "reason": f"备选：{reason}",
        "tags": ["备选", *[str(tag) for tag in preliminary.get("tags") or []]][:4],
    }


def search_plan(
    group: PreferenceGroup,
    config: Config,
    run_date: date,
) -> list[tuple[str, int, str]]:
    orders = ("totalrank", "pubdate", "click", "stow")
    plan: list[tuple[str, int, str]] = []
    for query in group.search_queries[: config.search_query_limit]:
        seed = _stable_int(f"{group.id}:{run_date.isoformat()}:{query}")
        order = orders[seed % len(orders)]
        pages = [1]
        for offset in range(1, config.search_pages_per_query):
            page = 2 + ((seed // (offset * 17)) + offset - 1) % 5
            if page not in pages:
                pages.append(page)
        while len(pages) < config.search_pages_per_query:
            page = 2 + len(pages)
            if page not in pages:
                pages.append(page)
        plan.extend((query, page, order) for page in pages)
    return plan


async def fetch_search_candidates(
    bili: BilibiliClient,
    config: Config,
    group: PreferenceGroup,
    run_date: date,
) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen: set[str] = set()
    plan = search_plan(group, config, run_date)
    for index, (query, page, order) in enumerate(plan, start=1):
        try:
            results = await bili.search(query, page=page, order=order)
        except Exception as error:
            print(
                f"group {group.id} search {index}/{len(plan)} failed: {error}",
                flush=True,
            )
            continue
        added = 0
        for candidate in results:
            if candidate.bvid not in seen:
                seen.add(candidate.bvid)
                candidates.append(candidate)
                added += 1
        print(
            f"group {group.id} search {index}/{len(plan)} "
            f"query={query!r} page={page} order={order}: "
            f"+{added}, total={len(candidates)}",
            flush=True,
        )
        await asyncio.sleep(0.35)
    return candidates


async def generate_group(
    config: Config,
    group: PreferenceGroup,
    bili: BilibiliClient,
    recommendation_candidates: list[Candidate],
    recently_recommended: set[str],
    run_date: date,
) -> dict[str, Any]:
    search_candidates = (
        await fetch_search_candidates(bili, config, group, run_date)
        if group.source in {"search", "hybrid"}
        else []
    )
    by_bvid = {candidate.bvid: candidate for candidate in search_candidates}
    if group.source in {"recommendation", "hybrid"}:
        for candidate in recommendation_candidates:
            by_bvid.setdefault(candidate.bvid, candidate)
    candidates = list(by_bvid.values())
    if not candidates:
        raise RuntimeError(f"group {group.id} returned no source candidates")

    duration_eligible = [
        candidate
        for candidate in candidates
        if candidate.duration >= group.minimum_duration_seconds
    ]
    if not duration_eligible:
        raise RuntimeError(
            f"group {group.id} returned no videos at or above "
            f"{group.minimum_duration_seconds} seconds"
        )
    shortlist = sorted(
        duration_eligible,
        key=lambda item: (
            item.bvid not in recently_recommended,
            item.heuristic_score,
        ),
        reverse=True,
    )[: config.shortlist_count]
    preliminary_decisions: list[dict[str, Any]] = []
    shortlist_batches = batches(shortlist, config.batch_size)
    for index, batch in enumerate(shortlist_batches, start=1):
        print(
            f"group {group.id} AI metadata batch "
            f"{index}/{len(shortlist_batches)}: {len(batch)}",
            flush=True,
        )
        decisions = await ai_rank(
            config,
            group,
            batch,
            config.batch_result_count,
            "preliminary",
            recently_recommended,
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
    if not ranked_candidates:
        raise RuntimeError(
            f"group {group.id} AI preliminary ranking returned no candidates"
        )
    finalists = ranked_candidates[: config.finalist_count]
    enriched = await enrich_subtitles(bili, finalists)

    decisions = await ai_rank(
        config,
        group,
        enriched,
        group.result_count,
        "final",
        recently_recommended,
    )
    decisions = valid_decisions(decisions, enriched)[: group.result_count]
    if config.fill_results and len(decisions) < group.result_count:
        selected_bvids = {str(decision.get("bvid")) for decision in decisions}
        for candidate in enriched:
            if candidate.bvid in selected_bvids:
                continue
            preliminary = preliminary_by_bvid.get(candidate.bvid)
            if preliminary is None:
                continue
            decisions.append(fallback_decision(candidate, preliminary))
            selected_bvids.add(candidate.bvid)
            if len(decisions) >= group.result_count:
                break

    enriched_by_bvid = {item.bvid: item for item in enriched}
    items = [
        enriched_by_bvid[str(decision.get("bvid"))].to_feed_item(decision)
        for decision in decisions
        if str(decision.get("bvid")) in enriched_by_bvid
    ][: group.result_count]
    if not items:
        raise RuntimeError(f"group {group.id} AI returned no valid candidate bvid")
    return {
        **group.to_json(redact_prompt=config.redact_preference),
        "pipeline": {
            "source_candidates": len(candidates),
            "recommendation_candidates": (
                len(recommendation_candidates)
                if group.source in {"recommendation", "hybrid"}
                else 0
            ),
            "search_candidates": len(search_candidates),
            "minimum_duration_seconds": group.minimum_duration_seconds,
            "duration_eligible": len(duration_eligible),
            "recently_recommended": sum(
                candidate.bvid in recently_recommended
                for candidate in duration_eligible
            ),
            "heuristic_shortlist": len(shortlist),
            "ai_batches": len(shortlist_batches),
            "preliminary_ranked": len(preliminary_decisions),
            "finalists": len(enriched),
            "subtitle_hits": sum(1 for candidate in enriched if candidate.transcript),
            "result_count": len(items),
        },
        "items": items,
    }


async def generate(
    config: Config,
    output: Path,
    history_path: Path | None = None,
) -> dict[str, Any]:
    history_path = history_path or output.with_name("history.json")
    run_date = datetime.now().date()
    history = load_history(history_path)
    enabled_groups = [group for group in config.groups if group.enabled]
    if not enabled_groups:
        feed = {
            "schema_version": 1,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "source": "vps",
            "preference_snapshot": "",
            "pipeline": {
                "candidate_target": 0,
                "candidates_fetched": 0,
                "group_count": 0,
                "successful_groups": 0,
                "failed_groups": 0,
                "result_count": 0,
            },
            "groups": [],
            "items": [],
        }
        write_feed(output, feed)
        return feed
    needs_recommendations = any(
        group.source in {"recommendation", "hybrid"} for group in enabled_groups
    )

    async with BilibiliClient(required_env("BILI_COOKIE")) as bili:
        recommendation_candidates = (
            await bili.recommendations(
                config.candidate_count,
                config.fetch_page_size,
            )
            if needs_recommendations
            else []
        )
        if needs_recommendations and not recommendation_candidates:
            raise RuntimeError("Bilibili recommendation feed returned no videos")

        group_feeds: list[dict[str, Any]] = []
        errors: list[str] = []
        for group in enabled_groups:
            recent = recent_bvids(
                history,
                group.id,
                run_date,
                config.search_history_days,
            )
            try:
                group_feed = await generate_group(
                    config,
                    group,
                    bili,
                    recommendation_candidates,
                    recent,
                    run_date,
                )
                group_feeds.append(group_feed)
            except Exception as error:
                message = f"{group.id}: {error}"
                print(f"group failed: {message}", flush=True)
                errors.append(message)
                group_feeds.append(
                    {
                        **group.to_json(redact_prompt=config.redact_preference),
                        "error": str(error),
                        "items": [],
                    }
                )

    successful_groups = [
        group_feed for group_feed in group_feeds if group_feed.get("items")
    ]
    if not successful_groups:
        raise RuntimeError("all preference groups failed: " + "; ".join(errors))

    merged: dict[str, dict[str, Any]] = {}
    for group_feed in successful_groups:
        for item in group_feed["items"]:
            current = merged.get(str(item.get("bvid")))
            if current is None or _decision_score(item) > _decision_score(current):
                merged[str(item.get("bvid"))] = item
    items = sorted(merged.values(), key=_decision_score, reverse=True)[:30]

    feed = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "vps",
        "preference_snapshot": (
            ""
            if config.redact_preference
            else "\n\n".join(group.prompt for group in enabled_groups)
        ),
        "pipeline": {
            "candidate_target": (
                config.candidate_count if needs_recommendations else 0
            ),
            "candidates_fetched": len(recommendation_candidates),
            "group_count": len(enabled_groups),
            "successful_groups": len(successful_groups),
            "failed_groups": len(errors),
            "result_count": len(items),
        },
        "groups": group_feeds,
        "items": items,
    }
    write_feed(output, feed)

    for group_feed in successful_groups:
        remember_results(
            history,
            str(group_feed["id"]),
            run_date,
            [str(item["bvid"]) for item in group_feed["items"]],
            config.search_history_days,
        )
    write_history(history_path, history)
    return feed


def write_feed(path: Path, feed: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(feed, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    temporary.replace(path)


def load_history(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {"groups": {}}
    except (OSError, json.JSONDecodeError):
        return {"groups": {}}


def recent_bvids(
    history: dict[str, Any],
    group_id: str,
    run_date: date,
    history_days: int,
) -> set[str]:
    cutoff = run_date - timedelta(days=history_days - 1)
    recent: set[str] = set()
    entries = (history.get("groups") or {}).get(group_id) or []
    for entry in entries:
        try:
            entry_date = date.fromisoformat(str(entry.get("date")))
        except (TypeError, ValueError):
            continue
        if cutoff <= entry_date <= run_date:
            recent.update(str(bvid) for bvid in entry.get("bvids") or [])
    return recent


def remember_results(
    history: dict[str, Any],
    group_id: str,
    run_date: date,
    bvids: list[str],
    history_days: int,
) -> None:
    cutoff = run_date - timedelta(days=history_days - 1)
    groups = history.setdefault("groups", {})
    entries = []
    for entry in groups.get(group_id) or []:
        try:
            entry_date = date.fromisoformat(str(entry.get("date")))
        except (TypeError, ValueError):
            continue
        if entry_date >= cutoff and entry_date != run_date:
            entries.append(entry)
    entries.append({"date": run_date.isoformat(), "bvids": list(dict.fromkeys(bvids))})
    groups[group_id] = entries


def write_history(path: Path, history: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(history, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    temporary.replace(path)


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


def _duration_seconds(value: Any) -> int:
    if isinstance(value, (int, float)):
        return max(0, int(value))
    parts = str(value or "").strip().split(":")
    try:
        numbers = [int(part) for part in parts]
    except ValueError:
        return 0
    if not 1 <= len(numbers) <= 3:
        return 0
    total = 0
    for number in numbers:
        total = total * 60 + number
    return total


def _stable_int(value: str) -> int:
    return int.from_bytes(hashlib.sha256(value.encode()).digest()[:8], "big")


def _group_id(value: str) -> str:
    ascii_parts = re.findall(r"[a-z0-9]+", value.lower())
    base = "-".join(ascii_parts)[:48].strip("-")
    if not base:
        base = "group"
    suffix = uuid.uuid5(uuid.NAMESPACE_URL, value).hex[:8]
    return f"{base}-{suffix}"[:64]


@contextmanager
def generation_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as lock_file:
        if os.name != "nt":
            import fcntl

            print(f"waiting for generation lock: {path}", flush=True)
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name != "nt":
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("config.json"))
    parser.add_argument("--output", type=Path, default=Path("public/feed.json"))
    parser.add_argument("--history", type=Path, default=Path("history.json"))
    parser.add_argument(
        "--lock",
        type=Path,
        default=Path("/tmp/piliplus-ai-generation.lock"),
    )
    args = parser.parse_args()
    with generation_lock(args.lock):
        feed = asyncio.run(
            generate(
                Config.load(args.config),
                args.output,
                args.history,
            )
        )
    print(f"wrote {len(feed['items'])} recommendations to {args.output}")


if __name__ == "__main__":
    main()
