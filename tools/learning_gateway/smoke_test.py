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

            # Bypass ingest: drop two inbox turns (one with a learnable
            # signal, one without); expect 1 shadow lesson and both files
            # moved out of the inbox root.
            inbox = Path(tmp) / "inbox"
            inbox.mkdir(parents=True, exist_ok=True)
            (inbox / "bypass-1.json").write_text(json.dumps({
                "ts": 0, "conversation_id": "conv_test",
                "user_text": "以后部署前记得先查 CI，不要直接动手",
                "assistant_text": "好的，明白了。",
            }, ensure_ascii=False), encoding="utf-8")
            (inbox / "bypass-2.json").write_text(json.dumps({
                "ts": 0, "conversation_id": "conv_test",
                "user_text": "今天天气怎么样",
            }, ensure_ascii=False), encoding="utf-8")
            ingest = await call(session, "learning_ingest_inbox", {})
            assert ingest["scanned"] == 2, ingest
            assert ingest["lessons_created"] == 1, ingest
            assert ingest["skipped_no_signal"] == 1, ingest
            assert not (inbox / "bypass-1.json").exists(), ingest
            queue = await call(session, "learning_review_queue", {})
            # "部署前先查 CI" was promoted earlier, so shadow queue is
            # the first preference lesson + the new bypass lesson.
            assert len(queue) == 2 and any(
                "对话旁路" in r["content"] for r in queue
            ), queue
            print("bypass ingest ok")

            # CJK full-text recall: promote a Chinese lesson, query a
            # substring without word boundaries (bigram FTS path).
            r = await call(session, "learning_record", {
                "lesson": "汇报时先给结论再摆依据",
                "type": "preference", "tags": "汇报",
            })
            await call(session, "learning_promote", {"lesson_id": r["id"]})
            recall = await call(session, "learning_recall",
                                {"query": "先给结论"})
            assert any("先给结论" in x["content"] for x in recall), recall
            print("fts cjk recall ok")

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
