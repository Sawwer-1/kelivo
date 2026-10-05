#!/usr/bin/env python3
"""Smoke test for the learning gateway: full lesson lifecycle over stdio MCP.

Usage: python tools/learning_gateway/smoke_test.py
"""

import asyncio
import json
import sys
import tempfile
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

GATEWAY = "tools/learning_gateway/learning_gateway.py"


async def call(session, name, args):
    result = await session.call_tool(name, args)
    text = result.content[0].text if result.content else ""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


async def main() -> None:
    tmp = tempfile.mkdtemp(prefix="kelivo_learning_smoke_")
    params = StdioServerParameters(
        command=sys.executable,
        args=[GATEWAY],
        env={"LEARNING_DB": str(Path(tmp) / "lessons.db")},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"handshake ok: server={init.serverInfo.name}")
            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print(f"tools ({len(names)}): {', '.join(names)}")

            r1 = await call(session, "learning_record", {
                "lesson": "主公喜欢先给结论再摆依据的汇报顺序",
                "type": "preference",
                "tags": "汇报,沟通",
                "confidence": 0.9,
            })
            assert r1["status"] == "shadow", r1
            await call(session, "learning_record", {
                "lesson": "部署前先查 CI 再动手",
                "type": "workflow",
                "tags": "部署,ci",
            })
            dup = await call(session, "learning_record", {
                "lesson": "部署前先查 CI 再动手",
                "type": "workflow",
            })
            assert dup.get("deduplicated"), dup
            print("record+dedup ok")

            recall = await call(session, "learning_recall", {"query": "ci"})
            assert recall == [], "shadow lessons must not surface in recall"
            print("shadow isolation ok")

            queue = await call(session, "learning_review_queue", {})
            assert len(queue) == 2, queue
            lid = next(
                r["id"] for r in queue if "CI" in r["content"]
            )
            assert (await call(session, "learning_promote",
                               {"lesson_id": lid}))["status"] == "promoted"
            print("review+promote ok")

            recall = await call(session, "learning_recall", {"query": "ci"})
            assert len(recall) == 1 and recall[0]["id"] == lid, recall
            print("recall after promote ok")

            stats = await call(session, "learning_stats", {})
            assert stats["by_status"].get("promoted") == 1, stats
            print("stats ok")

            export = await call(session, "learning_export_worldbook", {
                "path": str(Path(tmp) / "wb.json"),
                "mode": "keywords",
            })
            book = json.loads(Path(export["path"]).read_text(encoding="utf-8"))
            assert book["name"] and book["entries"], export
            assert book["entries"][0]["constantActive"] is False
            print(f"worldbook export ok: {export['entries']} entries")

            print("SMOKE_OK (db in", tmp, ")")


if __name__ == "__main__":
    asyncio.run(main())
