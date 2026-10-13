#!/usr/bin/env python3
"""fixture.py —— SQLite 浏览器示例的**夹具库生成器 + 进程外核对器**

为什么要单独一个对端脚本（而不是让应用自说自话）：

  1. **生成**：示例页面的自检断言全部对着一个形状已知的库写死。形状必须由一个**独立进程**造出来，
     否则「页面说读到了什么」和「库文件里真有什么」就是同一份代码的两面，对不了账。
  2. **核对**：页面的 `sqlite:exec` 往库里写一行之后，本脚本再以**另一个进程**只读打开同一个文件，
     确认那一行真的落盘了。这是本示例最硬的一条证据——仓颉侧 FFI 写进去、python3 读出来。

三个模式（都只依赖 python3 标准库，零第三方依赖）：
  * 无参数            —— 在 --out 指定的位置生成夹具库（已存在则覆盖）
  * --selftest        —— 先自证夹具生成器本身没问题（造到临时文件再逐条断言），退出码即结论
  * --verify <库文件> —— 进程外核对页面写进去的行在不在；不在就非零退出

夹具形状（页面自检的期望值就写在这上面，改这里必须同步页面）：
  artists(id, name, country)         3 行，rowid 序首位是「阿炳」，BINARY 升序首位是 'Bob Dylan'
  albums(id, artist_id, title, year, rating, cover)  5 行；第 1 行 cover 是 4 字节 BLOB；
                                                      第 3 行 rating 是 NULL（类型映射要能看见 null）
  notes(id, body)                    1 行，body 80000 字节 —— 超过单元格上限 65536，必定走截断分支
  v_album_titles                     一个视图（**不计入 tableCount**，行数如实报 -1）
"""

import argparse
import os
import sqlite3
import sys
import tempfile

PREFIX = "[sqlite-fixture]"

# 页面自检依赖的两个数字（与仓颉侧 SQLITE_TEXT_CELL_LIMIT / 夹具行数一一对应）
CELL_LIMIT = 65536
BIG_BODY_BYTES = 80000
EXPECTED_TABLES = 3
EXPECTED_ARTISTS = 3
EXPECTED_ALBUMS = 5


def log(line):
    print(PREFIX + " " + line, flush=True)


def build(db_path):
    """造夹具库：先删旧的再建，保证每次跑的形状完全一致（可复现是对账的前提）"""
    parent = os.path.dirname(os.path.abspath(db_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(db_path):
        os.remove(db_path)
    con = sqlite3.connect(db_path)
    try:
        cur = con.cursor()
        cur.execute("CREATE TABLE artists (id INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT)")
        cur.executemany("INSERT INTO artists (id, name, country) VALUES (?, ?, ?)",
                        [(1, "阿炳", "中国"), (2, "Bob Dylan", "US"), (3, "中岛美雪", "JP")])
        cur.execute("""CREATE TABLE albums (
                         id INTEGER PRIMARY KEY,
                         artist_id INTEGER,
                         title TEXT,
                         year INTEGER,
                         rating REAL,
                         cover BLOB)""")
        cur.executemany("""INSERT INTO albums (id, artist_id, title, year, rating, cover)
                           VALUES (?, ?, ?, ?, ?, ?)""", [
            (1, 1, "二泉映月", 1950, 9.6, b"\x89PNG"),   # 4 字节 BLOB（PNG 魔数）
            (2, 2, "Highway 61 Revisited", 1965, 9.1, None),
            (3, 3, "A Sense of Purpose", 2000, None, None),  # rating 为 NULL
            (4, 1, "Erquan Yingyue (Remaster)", 1998, 8.7, None),
            (5, 2, "Blonde on Blonde", 1966, 9.0, None),
        ])
        cur.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        cur.execute("INSERT INTO notes (id, body) VALUES (1, ?)", ("x" * BIG_BODY_BYTES,))
        cur.execute("CREATE VIEW v_album_titles AS SELECT title, year FROM albums")
        con.commit()
    finally:
        con.close()
    return db_path


def table_count(con):
    return con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' "
                       "AND name NOT LIKE 'sqlite_%'").fetchone()[0]


def check(cond, name, detail=""):
    if cond:
        log("SELFTEST PASS " + name + (" " + detail if detail else ""))
        return 1
    log("SELFTEST FAIL " + name + " " + (detail if detail else ""))
    return 0


def selftest():
    tmp = tempfile.mkdtemp(prefix="cj-tauri-sqlite-fixture-")
    db = os.path.join(tmp, "fixture.db")
    passed = 0
    failed = 0
    build(db)
    con = sqlite3.connect(db)
    try:
        n = check(os.path.exists(db), "file.created", db)
        passed += n
        failed += 0 if n else 1

        got = table_count(con)
        n = check(got == EXPECTED_TABLES, "tables.count", "got=%d" % got)
        passed += n
        failed += 0 if n else 1

        views = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='view'").fetchone()[0]
        n = check(views == 1, "views.count", "got=%d" % views)
        passed += n
        failed += 0 if n else 1

        got = con.execute("SELECT COUNT(*) FROM artists").fetchone()[0]
        n = check(got == EXPECTED_ARTISTS, "artists.rows", "got=%d" % got)
        passed += n
        failed += 0 if n else 1

        got = con.execute("SELECT COUNT(*) FROM albums").fetchone()[0]
        n = check(got == EXPECTED_ALBUMS, "albums.rows", "got=%d" % got)
        passed += n
        failed += 0 if n else 1

        body = con.execute("SELECT body FROM notes WHERE id=1").fetchone()[0]
        n = check(len(body) == BIG_BODY_BYTES, "notes.body.bytes", "got=%d" % len(body))
        passed += n
        failed += 0 if n else 1

        n = check(len(body) > CELL_LIMIT, "notes.body.over.cell.limit",
                  "bytes=%d limit=%d" % (len(body), CELL_LIMIT))
        passed += n
        failed += 0 if n else 1

        nulls = con.execute("SELECT COUNT(*) FROM albums WHERE rating IS NULL").fetchone()[0]
        n = check(nulls == 1, "albums.rating.null", "got=%d" % nulls)
        passed += n
        failed += 0 if n else 1

        blob = con.execute("SELECT cover FROM albums WHERE id=1").fetchone()[0]
        n = check(blob is not None and len(blob) == 4, "albums.cover.bytes",
                  "got=%s" % (len(blob) if blob is not None else "None"))
        passed += n
        failed += 0 if n else 1

        # 页面按 BINARY 升序断言首位；这里先把「谁最小」算出来，页面断言不成立时能一眼看出是谁变了
        first = con.execute("SELECT name FROM artists ORDER BY name ASC LIMIT 1").fetchone()[0]
        n = check(first == "Bob Dylan", "artists.order.asc.first", "got=%s" % first)
        passed += n
        failed += 0 if n else 1

        first_rowid = con.execute("SELECT name FROM artists ORDER BY rowid ASC LIMIT 1").fetchone()[0]
        n = check(first_rowid == "阿炳", "artists.order.rowid.first", "got=%s" % first_rowid)
        passed += n
        failed += 0 if n else 1

        # 升序首位与 rowid 首位必须是**不同的值**，否则页面那条排序断言证明不了「排序生效」
        n = check(first != first_rowid, "artists.order.distinguishable",
                  "asc=%s rowid=%s" % (first, first_rowid))
        passed += n
        failed += 0 if n else 1
    finally:
        con.close()
    log("SELFTEST summary pass=%d fail=%d" % (passed, failed))
    return 0 if failed == 0 else 1


def verify(db_path, expect_artists):
    """进程外核对：页面经 sqlite:exec 写的那一行，必须在**这个进程**里也看得见"""
    if not os.path.exists(db_path):
        log("VERIFY FAIL db.missing path=%s" % db_path)
        return 1
    # mode=ro：核对器自己绝不改库，用的还是 URI 只读连接——写没写进去只看文件
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        total = con.execute("SELECT COUNT(*) FROM artists").fetchone()[0]
        row = con.execute("SELECT id, name, country FROM artists WHERE name='自检写入'").fetchone()
        body = con.execute("SELECT length(body) FROM notes WHERE id=1").fetchone()[0]
        ok = True
        if total == expect_artists:
            log("VERIFY ok artists.count=%d" % total)
        else:
            log("VERIFY FAIL artists.count=%d want=%d" % (total, expect_artists))
            ok = False
        if row is not None:
            log("VERIFY ok inserted.row id=%s name=%s country=%s" % (row[0], row[1], row[2]))
        else:
            log("VERIFY FAIL inserted.row missing name=自检写入")
            ok = False
        if row is not None and row[2] == "ZZ":
            log("VERIFY ok inserted.country=ZZ")
        else:
            log("VERIFY FAIL inserted.country=%s" % (row[2] if row else "None"))
            ok = False
        log("VERIFY info notes.body=%s bytes=%s sqlite=%s"
            % (body, os.path.getsize(db_path), sqlite3.sqlite_version))
        log("VERIFY summary %s" % ("pass" if ok else "fail"))
        return 0 if ok else 1
    finally:
        con.close()


def main(argv):
    ap = argparse.ArgumentParser(description="SQLite 浏览器示例的夹具库生成器 / 进程外核对器")
    ap.add_argument("--out", default="data/fixture.db", help="生成到哪（相对当前工作目录）")
    ap.add_argument("--verify", metavar="DB", help="核对这个库里页面写的那一行在不在")
    ap.add_argument("--expect-artists", type=int, default=EXPECTED_ARTISTS + 1,
                    help="核对时的 artists 期望行数（默认 3 + 页面写进去的 1）")
    ap.add_argument("--selftest", action="store_true", help="自证夹具生成器")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.verify:
        return verify(args.verify, args.expect_artists)

    path = build(args.out)
    log("built path=%s tables=%d sqlite=%s" % (path, table_count(sqlite3.connect(path)),
                                               sqlite3.sqlite_version))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
