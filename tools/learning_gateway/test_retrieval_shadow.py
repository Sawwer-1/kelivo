#!/usr/bin/env python3
"""Function-level test for the retrieval-shadow additions: bypasses the
stdio MCP layer (which cannot spawn under this sandbox) and calls the
gateway functions directly. Mirrors the smoke test's B-batch assertions.
Usage: python tools/learning_gateway/test_retrieval_shadow.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
os.environ["LEARNING_DB"] = str(
    Path(tempfile.mkdtemp(prefix="lg_shadow_t_")) / "lessons.db"
)

import learning_gateway as g  # noqa: E402


def main() -> None:
    db = g._db()
    cols = {r[1] for r in db.execute("PRAGMA table_info(lessons)")}
    assert "retrieval_confirmed" in cols and "evidence" in cols, cols
    print("schema migration ok:", sorted(cols))

    # record + dedup
    lid, dup = g._insert_lesson(db, "部署前先查 CI", "workflow", ["部署", "ci"], 0.9, "t")
    assert not dup
    lid2, dup2 = g._insert_lesson(db, "部署前先查 CI", "workflow", [], 0.6, "t")
    assert dup2 and lid2 == lid
    print("record+dedup ok")

    # shadow isolation in recall
    rows = db.execute("SELECT * FROM lessons WHERE status='promoted'").fetchall()
    assert rows == []
    print("shadow isolation ok")

    # promote (with note) -> evidence 1, snapshot refreshed
    r = json.loads(g.learning_promote(lid, "reviewed by smoke"))
    assert r["status"] == "promoted" and r["evidence_count"] == 1, r
    snap_path = g._snapshot_path()
    snap = json.loads(snap_path.read_text(encoding="utf-8"))
    assert snap["count"] == 1 and snap["entries"][0]["id"] == lid, snap
    assert snap["entries"][0]["retrieval_confirmed"] is False, snap
    print("promote + snapshot ok")

    # confirm retrieval -> evidence 2, verified in snapshot
    r2 = json.loads(g.learning_confirm_retrieval(lid, "shaped the deploy plan"))
    assert r2["retrieval_confirmed"] == 1 and r2["evidence_count"] == 2, r2
    snap = json.loads(snap_path.read_text(encoding="utf-8"))
    assert snap["entries"][0]["retrieval_confirmed"] is True, snap
    ev = g._load_evidence(db, lid)
    assert [e["kind"] for e in ev] == ["promoted", "retrieval_confirm"], ev
    print("retrieval shadow confirm ok")

    # recall row carries the new column
    hit = json.loads(g.learning_recall("ci"))
    assert len(hit) == 1 and hit[0]["retrieval_confirmed"] == 1, hit
    print("recall carries retrieval_confirmed ok")

    # unknown id errors
    r3 = json.loads(g.learning_confirm_retrieval("les_nope"))
    assert "error" in r3, r3
    print("unknown id error ok")

    # archive refreshes snapshot (count 1 -> 0)
    r4 = json.loads(g.learning_archive(lid, "obsolete"))
    assert r4["status"] == "archived" and r4["evidence_count"] == 3, r4
    snap = json.loads(snap_path.read_text(encoding="utf-8"))
    assert snap["count"] == 0, snap
    print("archive snapshot refresh ok")

    # legacy db migration: create a pre-B schema and reopen
    old_db = Path(tempfile.mkdtemp(prefix="lg_shadow_old_")) / "old.db"
    import sqlite3
    c = sqlite3.connect(str(old_db))
    c.execute(
        "CREATE TABLE lessons(id TEXT PRIMARY KEY, ts INTEGER, type TEXT, "
        "tags TEXT, content TEXT, content_normalized TEXT, "
        "status TEXT DEFAULT 'shadow', confidence REAL DEFAULT 0.6, "
        "source TEXT DEFAULT '', use_count INTEGER DEFAULT 0, "
        "last_used_at INTEGER)"
    )
    c.commit()
    c.close()
    os.environ["LEARNING_DB"] = str(old_db)
    g._conn = None  # force reopen
    g._fts_enabled = False
    db2 = g._db()
    cols2 = {r[1] for r in db2.execute("PRAGMA table_info(lessons)")}
    assert "retrieval_confirmed" in cols2 and "evidence" in cols2, cols2
    print("legacy migration ok")

    print("SHADOW_TESTS_OK")


if __name__ == "__main__":
    main()
