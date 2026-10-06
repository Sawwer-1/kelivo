#!/usr/bin/env python3
"""Kelivo learning gateway - the Learning Runtime as an external MCP service.

A durable, local "operational memory" for the agent: lessons about how the
user likes things done (preferences, corrections, workflow knowledge),
separate from facts about the user (those live in Kelivo's memory system).

Design (AAA Learning Runtime lineage, desktop re-cast):
- Shadow mode: every recorded lesson starts unverified; only promoted lessons
  surface in recall and world-book export.
- The model drives everything through MCP tools; storage is local SQLite.
- Recall is full-text (SQLite FTS5 over CJK bigrams + latin words) with an
  automatic LIKE fallback when FTS5 is unavailable.
- Bypass hook: the host (Kelivo) drops one JSON file per finished generation
  turn into ``<db dir>/inbox/``; ``learning_ingest_inbox`` distills those
  turns into shadow lessons without relying on the model's cooperation.
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
        "Run learning_ingest_inbox at session start to pick up lessons the "
        "host captured bypass-style from finished conversation turns. "
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
_fts_enabled: bool = False


def _bigram_tokens(text: str) -> list:
    """Tokenize text for FTS indexing: CJK runs become 2-grams (single CJK
    chars pass through), latin/digit runs become lowercase words. Query and
    index share this tokenizer so recall matches what was stored."""
    out = []
    for run in re.findall(r"[\u4e00-\u9fff]+|[a-z0-9]+", (text or "").lower()):
        if not run.isascii():
            if len(run) <= 2:
                out.append(run)
            else:
                out.extend(run[i : i + 2] for i in range(len(run) - 1))
        else:
            out.append(run)
    return out


def _fts_text(content: str, tags_json: str) -> str:
    try:
        tags = " ".join(json.loads(tags_json or "[]"))
    except (json.JSONDecodeError, TypeError):
        tags = ""
    return f"{content} {tags}"


def _fts_upsert(db: sqlite3.Connection, lesson_id: str, text: str) -> None:
    if not _fts_enabled:
        return
    db.execute("DELETE FROM lessons_fts WHERE lesson_id = ?", (lesson_id,))
    db.execute(
        "INSERT INTO lessons_fts(lesson_id, text) VALUES (?, ?)",
        (lesson_id, " ".join(_bigram_tokens(text))),
    )


def _fts_rebuild_missing(db: sqlite3.Connection) -> None:
    """One-shot sync at startup: drop FTS rows without a backing lesson and
    index lessons that appeared before FTS was enabled (idempotent)."""
    if not _fts_enabled:
        return
    db.execute(
        "DELETE FROM lessons_fts WHERE lesson_id NOT IN "
        "(SELECT id FROM lessons)"
    )
    indexed = {r[0] for r in db.execute("SELECT lesson_id FROM lessons_fts")}
    for row in db.execute("SELECT id, content, tags FROM lessons"):
        if row["id"] not in indexed:
            _fts_upsert(db, row["id"], _fts_text(row["content"], row["tags"]))


def _db() -> sqlite3.Connection:
    global _conn, _fts_enabled
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
        try:
            _conn.execute(
                "CREATE VIRTUAL TABLE IF NOT EXISTS lessons_fts USING fts5("
                "text, lesson_id UNINDEXED)"
            )
            _fts_enabled = True
        except sqlite3.OperationalError:
            # SQLite build without FTS5: recall falls back to LIKE.
            _fts_enabled = False
        if _fts_enabled:
            _fts_rebuild_missing(_conn)
        _conn.commit()
    return _conn


def _new_id() -> str:
    return "les_" + os.urandom(4).hex()


def _now() -> int:
    return int(time.time())


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip()).lower()


def _insert_lesson(
    db: sqlite3.Connection,
    text: str,
    type: str,
    tag_list: list,
    confidence: float,
    source: str,
) -> tuple:
    """Insert (or deduplicate) one lesson. Returns (id, deduplicated)."""
    dup = db.execute(
        "SELECT id FROM lessons WHERE content_normalized = ? "
        "AND status != 'archived'",
        (_norm(text),),
    ).fetchone()
    now = _now()
    if dup:
        db.execute(
            "UPDATE lessons SET ts = ?, confidence = ? WHERE id = ?",
            (now, confidence, dup["id"]),
        )
        db.commit()
        return dup["id"], True
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
            source,
        ),
    )
    _fts_upsert(db, lid, _fts_text(text, json.dumps(tag_list, ensure_ascii=False)))
    db.commit()
    return lid, False


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
    lid, deduplicated = _insert_lesson(
        _db(), text, type, tag_list, confidence, (source_conversation or "").strip()
    )
    if deduplicated:
        return json.dumps(
            {"id": lid, "status": "shadow", "deduplicated": True},
            ensure_ascii=False,
        )
    return json.dumps(
        {"id": lid, "status": "shadow", "note": "awaiting review"},
        ensure_ascii=False,
    )


def _recall_like(db, statuses, tokens, limit):
    """Legacy LIKE recall (also the FTS5 fallback for builds without it)."""
    marks = ",".join("?" for _ in statuses)
    if tokens:
        like = " OR ".join(
            "(content LIKE ? OR tags LIKE ?)" for _ in tokens
        )
        params: list = []
        for token in tokens:
            params += [f"%{token}%", f"%{token}%"]
        return db.execute(
            f"SELECT * FROM lessons WHERE status IN ({marks}) AND ({like}) "
            "ORDER BY use_count DESC, ts DESC LIMIT ?",
            [*statuses, *params, limit],
        ).fetchall()
    return db.execute(
        f"SELECT * FROM lessons WHERE status IN ({marks}) "
        "ORDER BY use_count DESC, ts DESC LIMIT ?",
        [*statuses, limit],
    ).fetchall()


def _recall_fts(db, statuses, bigrams, limit):
    """FTS5 recall over CJK bigrams + latin words, ranked by bm25 then usage."""
    marks = ",".join("?" for _ in statuses)
    match = " OR ".join(f'"{t}"' for t in bigrams if '"' not in t)
    if not match:
        return []
    return db.execute(
        f"SELECT l.* FROM lessons_fts f JOIN lessons l ON l.id = f.lesson_id "
        f"WHERE f MATCH ? AND l.status IN ({marks}) "
        "ORDER BY rank, l.use_count DESC, l.ts DESC LIMIT ?",
        [match, *statuses, limit],
    ).fetchall()


@mcp.tool()
def learning_recall(query: str, limit: int = 8, include_shadow: bool = False) -> str:
    """Recall promoted lessons relevant to [query] (full-text match over
    content and tags — CJK bigram FTS5 with LIKE fallback — ranked by
    relevance then usage then recency). Pass include_shadow=true only when
    the user asks to see unverified lessons."""
    db = _db()
    statuses = ("shadow", "promoted") if include_shadow else ("promoted",)
    limit = max(1, min(int(limit), 50))
    tokens = [t for t in _norm(query).split(" ") if len(t) >= 2]
    rows = []
    if _fts_enabled:
        bigrams = _bigram_tokens(query)
        if bigrams:
            try:
                rows = _recall_fts(db, statuses, bigrams, limit)
            except sqlite3.OperationalError:
                rows = []
        if not rows:
            # FTS found nothing (or failed): keep recall useful via LIKE.
            rows = _recall_like(db, statuses, tokens, limit)
    else:
        rows = _recall_like(db, statuses, tokens, limit)
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


def _inbox_dir() -> Path:
    return _db_path().parent / "inbox"


_NEGATIVE_SIGNALS = (
    "不要", "别再", "别用", "不要再", "改为", "禁止", "不许",
    "never", "don't", "do not", "stop", "instead", "avoid",
)
_POSITIVE_SIGNALS = (
    "记住", "以后", "下次", "偏好", "喜欢", "不喜欢", "习惯", "规矩",
    "从今", "以后就", "以后请", "记得",
    "prefer", "remember", "always", "favorite", "habit", "from now on",
    "next time", "please use", "make sure",
)


def _classify_bypass(user_text: str) -> Optional[str]:
    """Return a lesson type when the user turn carries a learnable signal,
    else None. Corrections (negative phrasing) outrank preferences."""
    lowered = (user_text or "").lower()
    if any(s in lowered for s in _NEGATIVE_SIGNALS):
        return "correction"
    if any(s in lowered for s in _POSITIVE_SIGNALS):
        return "preference"
    return None


@mcp.tool()
def learning_ingest_inbox(limit: int = 20) -> str:
    """Consume bypass files the host dropped into <db dir>/inbox after each
    finished conversation turn. Turns with a learnable signal (user
    correction or stated preference) become shadow lessons sourced
    'inbox:<conversation>'; every handled file is moved to inbox/processed
    (inbox/failed when unparseable). Run this at session start; it does not
    require the user's cooperation."""
    inbox = _inbox_dir()
    if not inbox.is_dir():
        return json.dumps({"scanned": 0, "lessons_created": 0, "note": "no inbox"})
    processed = inbox / "processed"
    failed = inbox / "failed"
    processed.mkdir(parents=True, exist_ok=True)
    failed.mkdir(parents=True, exist_ok=True)
    files = sorted(inbox.glob("*.json"))[: max(1, min(int(limit), 100))]
    db = _db()
    created, skipped, errors = 0, 0, []
    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            user_text = str(data.get("user_text") or "").strip()
            assistant_text = str(data.get("assistant_text") or "").strip()
            conversation_id = str(data.get("conversation_id") or "")
            ts = int(data.get("ts") or 0)
            if not user_text:
                raise ValueError("empty user_text")
            lesson_type = _classify_bypass(user_text)
            if lesson_type:
                date = time.strftime(
                    "%Y-%m-%d", time.localtime(ts or _now())
                )
                content = f"【对话旁路 {date}】用户：{user_text[:500]}"
                if assistant_text:
                    content += f"\n（当时助手回复：{assistant_text[:200]}）"
                _insert_lesson(
                    db, content, lesson_type, [], 0.45,
                    f"inbox:{conversation_id}"[:120],
                )
                created += 1
            else:
                skipped += 1
            target = processed / path.name
            if target.exists():
                target = processed / f"{path.stem}-{_now()}{path.suffix}"
            path.rename(target)
        except Exception as error:  # noqa: BLE001 - never stop the batch
            errors.append({"file": path.name, "error": str(error)[:120]})
            try:
                target = failed / path.name
                if target.exists():
                    target = failed / f"{path.stem}-{_now()}{path.suffix}"
                path.rename(target)
            except OSError:
                pass
    db.commit()
    return json.dumps(
        {
            "scanned": len(files),
            "lessons_created": created,
            "skipped_no_signal": skipped,
            "failed": errors,
            "inbox": str(inbox),
        },
        ensure_ascii=False,
    )


def main() -> None:
    sys.stderr.write(
        f"[learning-gateway] starting on stdio; db={_db_path()} "
        f"fts={_fts_enabled}\n"
    )
    mcp.run()


if __name__ == "__main__":
    main()
