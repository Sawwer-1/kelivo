#!/usr/bin/env python3
"""Kelivo learning gateway - the Learning Runtime as an external MCP service.

A durable, local "operational memory" for the agent: lessons about how the
user likes things done (preferences, corrections, workflow knowledge),
separate from facts about the user (those live in Kelivo's memory system).

Design (AAA Learning Runtime lineage, desktop re-cast):
- Shadow mode: every recorded lesson starts unverified; only promoted lessons
  surface in recall and world-book export.
- The model drives everything through MCP tools; storage is local SQLite.
- Export bridge: promoted lessons become a Kelivo world book JSON the user
  imports once, giving always-on injection without touching Kelivo code.

stdout is reserved for the MCP protocol; diagnostics go to stderr.
"""

import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "learning-gateway",
    instructions=(
        "Long-term operational learning for this agent. Record a lesson when "
        "the user corrects how you work, reveals a preference, or a workflow "
        "succeeds/fails in a way worth remembering (learning_record). Before "
        "non-trivial tasks, recall relevant lessons (learning_recall). "
        "Promoted lessons feed the world-book export; shadow ones wait for "
        "human review."
    ),
)

TYPES = ("preference", "correction", "workflow", "fact", "lesson")
STATUSES = ("shadow", "promoted", "archived")


def _db_path() -> Path:
    override = os.environ.get("LEARNING_DB", "").strip()
    if override:
        return Path(override)
    base = os.environ.get("APPDATA") or str(Path.home())
    return Path(base) / "kelivo_learning" / "lessons.db"


_conn: Optional[sqlite3.Connection] = None


def _db() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        path = _db_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(str(path))
        _conn.row_factory = sqlite3.Row
        _conn.execute(
            """CREATE TABLE IF NOT EXISTS lessons(
            id TEXT PRIMARY KEY, ts INTEGER, type TEXT, tags TEXT,
            content TEXT, content_normalized TEXT,
            status TEXT DEFAULT 'shadow',
            confidence REAL DEFAULT 0.6, source TEXT DEFAULT '',
            use_count INTEGER DEFAULT 0, last_used_at INTEGER)"""
        )
        _conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_lessons_status ON lessons(status)"
        )
        _conn.commit()
    return _conn


def _new_id() -> str:
    return "les_" + os.urandom(4).hex()


def _now() -> int:
    return int(time.time())


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip()).lower()


def _rows_to_json(rows) -> str:
    return json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# tools


@mcp.tool()
def learning_record(
    lesson: str,
    type: str = "lesson",
    tags: str = "",
    confidence: float = 0.6,
    source_conversation: str = "",
) -> str:
    """Record an operational lesson (starts in shadow status, pending human
    review). type: preference|correction|workflow|fact|lesson. tags: comma
    separated keywords used by recall and world-book export."""
    text = (lesson or "").strip()
    if not text:
        return json.dumps({"error": "lesson must not be empty"})
    if type not in TYPES:
        type = "lesson"
    confidence = min(1.0, max(0.0, float(confidence)))
    tag_list = [t.strip() for t in (tags or "").split(",") if t.strip()]
    db = _db()
    dup = db.execute(
        "SELECT id FROM lessons WHERE content_normalized = ? AND status != 'archived'",
        (_norm(text),),
    ).fetchone()
    now = _now()
    if dup:
        db.execute(
            "UPDATE lessons SET ts = ?, confidence = ? WHERE id = ?",
            (now, confidence, dup["id"]),
        )
        db.commit()
        return json.dumps(
            {"id": dup["id"], "status": "shadow", "deduplicated": True},
            ensure_ascii=False,
        )
    lid = _new_id()
    db.execute(
        "INSERT INTO lessons(id, ts, type, tags, content, "
        "content_normalized, status, confidence, source, use_count, "
        "last_used_at) VALUES (?,?,?,?,?,?,?, ?, ?,0,NULL)",
        (
            lid,
            now,
            type,
            json.dumps(tag_list, ensure_ascii=False),
            text,
            _norm(text),
            "shadow",
            confidence,
            (source_conversation or "").strip(),
        ),
    )
    db.commit()
    return json.dumps(
        {"id": lid, "status": "shadow", "note": "awaiting review"},
        ensure_ascii=False,
    )


@mcp.tool()
def learning_recall(query: str, limit: int = 8, include_shadow: bool = False) -> str:
    """Recall promoted lessons relevant to [query] (keyword match over content
    and tags, ranked by usage then recency). Pass include_shadow=true only
    when the user asks to see unverified lessons."""
    db = _db()
    statuses = ("shadow", "promoted") if include_shadow else ("promoted",)
    marks = ",".join("?" for _ in statuses)
    tokens = [t for t in _norm(query).split(" ") if len(t) >= 2]
    if tokens:
        like = " OR ".join(
            "(content LIKE ? OR tags LIKE ?)" for _ in tokens
        )
        params: list = []
        for token in tokens:
            params += [f"%{token}%", f"%{token}%"]
        rows = db.execute(
            f"SELECT * FROM lessons WHERE status IN ({marks}) AND ({like}) "
            "ORDER BY use_count DESC, ts DESC LIMIT ?",
            [*statuses, *params, max(1, min(int(limit), 50))],
        ).fetchall()
    else:
        rows = db.execute(
            f"SELECT * FROM lessons WHERE status IN ({marks}) "
            "ORDER BY use_count DESC, ts DESC LIMIT ?",
            [*statuses, max(1, min(int(limit), 50))],
        ).fetchall()
    if rows:
        ids = [r["id"] for r in rows]
        db.executemany(
            "UPDATE lessons SET use_count = use_count + 1, last_used_at = ? "
            "WHERE id = ?",
            [(_now(), i) for i in ids],
        )
        db.commit()
    return _rows_to_json(rows)


@mcp.tool()
def learning_review_queue(limit: int = 20) -> str:
    """List shadow (unreviewed) lessons for human review."""
    rows = _db().execute(
        "SELECT * FROM lessons WHERE status = 'shadow' ORDER BY ts DESC "
        "LIMIT ?",
        (max(1, min(int(limit), 100)),),
    ).fetchall()
    return _rows_to_json(rows)


def _set_status(lesson_id: str, status: str) -> str:
    db = _db()
    cur = db.execute(
        "UPDATE lessons SET status = ? WHERE id = ?", (status, lesson_id)
    )
    db.commit()
    if cur.rowcount == 0:
        return json.dumps({"error": f"unknown lesson id: {lesson_id}"})
    return json.dumps({"id": lesson_id, "status": status})


@mcp.tool()
def learning_promote(lesson_id: str) -> str:
    """Promote a shadow lesson after human review: it now surfaces in recall
    and world-book export."""
    return _set_status(lesson_id, "promoted")


@mcp.tool()
def learning_archive(lesson_id: str) -> str:
    """Archive a lesson (wrong or obsolete): hidden from recall and export."""
    return _set_status(lesson_id, "archived")


@mcp.tool()
def learning_stats() -> str:
    """Lesson counts by status and type, plus the most used tags."""
    db = _db()
    by_status = {
        r["status"]: r["n"]
        for r in db.execute(
            "SELECT status, COUNT(*) AS n FROM lessons GROUP BY status"
        )
    }
    by_type = {
        r["type"]: r["n"]
        for r in db.execute(
            "SELECT type, COUNT(*) AS n FROM lessons GROUP BY type"
        )
    }
    tag_count: dict[str, int] = {}
    for r in db.execute("SELECT tags FROM lessons WHERE status = 'promoted'"):
        for tag in json.loads(r["tags"] or "[]"):
            tag_count[tag] = tag_count.get(tag, 0) + 1
    top_tags = sorted(tag_count.items(), key=lambda kv: -kv[1])[:10]
    return json.dumps(
        {
            "db": str(_db_path()),
            "by_status": by_status,
            "by_type": by_type,
            "top_tags": top_tags,
        },
        ensure_ascii=False,
    )


@mcp.tool()
def learning_export_worldbook(path: str = "", mode: str = "constant") -> str:
    """Export promoted lessons as a Kelivo world book JSON for one-time
    import (Settings > World Books > import). mode: 'constant' = always
    injected; 'keywords' = injected when a lesson tag matches the chat."""
    promoted = _db().execute(
        "SELECT * FROM lessons WHERE status = 'promoted' ORDER BY ts ASC"
    ).fetchall()
    if not promoted:
        return json.dumps({"error": "no promoted lessons to export"})
    entries = []
    for r in promoted:
        tags = json.loads(r["tags"] or "[]")
        entries.append(
            {
                "id": r["id"],
                "name": f"[学习] {r['type']} #{r['id'][-4:]}",
                "enabled": True,
                "priority": 100,
                "position": "AFTER_SYSTEM_PROMPT",
                "content": r["content"],
                "injectDepth": 4,
                "role": "USER",
                "keywords": tags,
                "useRegex": False,
                "caseSensitive": False,
                "scanDepth": 4,
                "constantActive": mode != "keywords",
                "sticky": 0,
                "cooldown": 0,
                "delay": 0,
            }
        )
    book = {
        "id": "kelivo_learning_export",
        "name": "Kelivo 学习成果",
        "description": "由 learning-gateway 导出的已晋升经验条目",
        "enabled": True,
        "entries": entries,
    }
    target = Path(path) if path.strip() else (
        _db_path().parent / "kelivo_learning_worldbook.json"
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(book, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return json.dumps(
        {
            "path": str(target),
            "entries": len(entries),
            "import": "Kelivo 设置 → 世界书 → 导入该 JSON 文件",
        },
        ensure_ascii=False,
    )


def main() -> None:
    sys.stderr.write(
        f"[learning-gateway] starting on stdio; db={_db_path()}\n"
    )
    mcp.run()


if __name__ == "__main__":
    main()
