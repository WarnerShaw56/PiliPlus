#!/usr/bin/env python3
"""Private management API for PiliPlus VPS preference groups."""

from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Response, status

from generate import Config, PreferenceGroup, expand_preference

CONFIG_PATH = Path(os.getenv("PILIPLUS_AI_CONFIG", "/var/lib/piliplus-ai/config.json"))
FEED_PATH = Path(os.getenv("PILIPLUS_AI_FEED", "/var/www/piliplus-ai/feed.json"))
HISTORY_PATH = Path(
    os.getenv("PILIPLUS_AI_HISTORY", "/var/lib/piliplus-ai/history.json")
)
LOCK_PATH = Path(os.getenv("PILIPLUS_AI_LOCK", "/var/lib/piliplus-ai/generation.lock"))
GENERATOR_PATH = Path(
    os.getenv("PILIPLUS_AI_GENERATOR", "/opt/piliplus-ai/generate.py")
)

app = FastAPI(
    title="PiliPlus AI preference groups",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
_generation_process: asyncio.subprocess.Process | None = None
_generation_started_at: datetime | None = None
_generation_finished_at: datetime | None = None
_generation_exit_code: int | None = None
_generation_lock = asyncio.Lock()


def read_config() -> Config:
    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return Config.from_json(raw)
    except Exception as error:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"invalid VPS config: {error}",
        ) from error


def write_config(config: Config) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = CONFIG_PATH.with_suffix(CONFIG_PATH.suffix + ".tmp")
    temporary.write_text(
        json.dumps(config.to_json(), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(CONFIG_PATH)


def editable_groups(config: Config) -> list[dict[str, Any]]:
    return [group.to_json() for group in config.groups]


def config_with_groups(
    config: Config,
    groups: list[dict[str, Any]],
) -> Config:
    raw = config.to_json()
    raw["preference"] = ""
    raw["groups"] = groups
    try:
        return Config.from_json(raw)
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(error),
        ) from error


def parse_group(
    payload: dict[str, Any],
    config: Config,
    *,
    group_id: str | None = None,
) -> PreferenceGroup:
    try:
        return PreferenceGroup.from_json(
            {**payload, **({"id": group_id} if group_id is not None else {})},
            default_minimum_duration_seconds=config.minimum_duration_seconds,
            default_result_count=config.result_count,
        )
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(error),
        ) from error


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "time": datetime.now(timezone.utc).isoformat()}


@app.get("/groups")
async def list_groups() -> dict[str, Any]:
    config = read_config()
    return {
        "groups": editable_groups(config),
        "limits": {
            "max_groups": 12,
            "sources": ["recommendation", "search", "hybrid"],
            "result_count": [1, 30],
            "minimum_duration_seconds": [60, 14400],
        },
    }


@app.post("/groups/expand")
async def expand_group(payload: dict[str, Any]) -> dict[str, Any]:
    intent = str(payload.get("intent") or "").strip()
    source = str(payload.get("source") or "recommendation").strip().lower()
    if not intent:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="intent is required",
        )
    try:
        return await expand_preference(intent, source)
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(error),
        ) from error
    except Exception as error:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"AI preference expansion failed: {error}",
        ) from error


@app.post("/groups", status_code=status.HTTP_201_CREATED)
async def create_group(payload: dict[str, Any]) -> dict[str, Any]:
    config = read_config()
    groups = editable_groups(config)
    if len(groups) >= 12:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="at most 12 preference groups are supported",
        )
    candidate = parse_group(payload, config)
    if any(group["id"] == candidate.id for group in groups):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="group id already exists",
        )
    groups.append(candidate.to_json())
    updated = config_with_groups(config, groups)
    write_config(updated)
    return candidate.to_json()


@app.put("/groups/{group_id}")
async def update_group(
    group_id: str,
    payload: dict[str, Any],
) -> dict[str, Any]:
    config = read_config()
    groups = editable_groups(config)
    index = next(
        (index for index, group in enumerate(groups) if group["id"] == group_id),
        None,
    )
    if index is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="group not found",
        )
    candidate = parse_group(payload, config, group_id=group_id)
    groups[index] = candidate.to_json()
    updated = config_with_groups(config, groups)
    write_config(updated)
    return candidate.to_json()


@app.delete("/groups/{group_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_group(group_id: str) -> Response:
    config = read_config()
    groups = [
        group for group in editable_groups(config) if str(group["id"]) != group_id
    ]
    if len(groups) == len(config.groups):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="group not found",
        )
    updated = config_with_groups(config, groups)
    write_config(updated)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


async def wait_for_generation(process: asyncio.subprocess.Process) -> None:
    global _generation_exit_code, _generation_finished_at
    _generation_exit_code = await process.wait()
    _generation_finished_at = datetime.now(timezone.utc)


@app.post("/generate", status_code=status.HTTP_202_ACCEPTED)
async def start_generation() -> dict[str, Any]:
    global _generation_process, _generation_started_at
    global _generation_finished_at, _generation_exit_code
    async with _generation_lock:
        if _generation_process is not None and _generation_process.returncode is None:
            return generation_status()
        read_config()
        _generation_started_at = datetime.now(timezone.utc)
        _generation_finished_at = None
        _generation_exit_code = None
        _generation_process = await asyncio.create_subprocess_exec(
            sys.executable,
            str(GENERATOR_PATH),
            "--config",
            str(CONFIG_PATH),
            "--output",
            str(FEED_PATH),
            "--history",
            str(HISTORY_PATH),
            "--lock",
            str(LOCK_PATH),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.STDOUT,
        )
        asyncio.create_task(wait_for_generation(_generation_process))
        return generation_status()


def generation_status() -> dict[str, Any]:
    process = _generation_process
    running = process is not None and process.returncode is None
    feed: dict[str, Any] = {}
    try:
        value = json.loads(FEED_PATH.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            feed = value
    except (OSError, json.JSONDecodeError):
        pass
    return {
        "running": running,
        "pid": process.pid if running and process else None,
        "started_at": (
            _generation_started_at.isoformat() if _generation_started_at else None
        ),
        "finished_at": (
            _generation_finished_at.isoformat() if _generation_finished_at else None
        ),
        "exit_code": _generation_exit_code,
        "feed_generated_at": feed.get("generated_at"),
        "feed_group_count": len(feed.get("groups") or []),
    }


@app.get("/status")
async def get_generation_status() -> dict[str, Any]:
    return generation_status()
