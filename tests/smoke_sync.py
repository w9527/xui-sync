#!/usr/bin/env python3
"""Minimal local smoke tests for xui-sync behavior."""

from __future__ import annotations

import sqlite3
import gc
import tempfile
from pathlib import Path


def qident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def qliteral(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def columns(conn: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in conn.execute(f"PRAGMA table_info({qident(table)})")]


def common_columns(target_conn: sqlite3.Connection, target_table: str, source_conn: sqlite3.Connection, source_table: str) -> list[str]:
    source_cols = set(columns(source_conn, source_table))
    return [col for col in columns(target_conn, target_table) if col in source_cols]


def ident_list(cols: list[str]) -> str:
    return ", ".join(qident(col) for col in cols)


def exec_sql(path: Path, sql: str) -> None:
    with sqlite3.connect(path) as conn:
        conn.executescript(sql)
        conn.commit()


def setup_live_db(path: Path) -> None:
    exec_sql(
        path,
        """
        CREATE TABLE users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT,
          live_only TEXT,
          password TEXT,
          login_secret TEXT,
          new_field TEXT
        );

        CREATE TABLE inbounds (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER,
          up INTEGER,
          down INTEGER,
          total INTEGER,
          remark TEXT,
          enable NUMERIC,
          expiry_time INTEGER,
          listen TEXT,
          port INTEGER,
          protocol TEXT,
          settings TEXT,
          stream_settings TEXT,
          tag TEXT,
          sniffing TEXT,
          allocate TEXT,
          all_time INTEGER DEFAULT 0,
          traffic_reset TEXT DEFAULT 'never',
          last_traffic_reset_time INTEGER DEFAULT 0,
          live_only TEXT,
          new_field TEXT
        );

        CREATE TABLE settings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          key TEXT,
          value TEXT,
          live_only TEXT,
          new_field TEXT
        );
        """,
    )

    with sqlite3.connect(path) as conn:
        conn.executemany(
            "INSERT INTO users(username, live_only, password, login_secret, new_field) VALUES (?, ?, ?, ?, ?)",
            [("alice", "live-u", "p1", "s1", "u-live"), ("bob", "live-u2", "p2", "s2", "u-live2")],
        )
        conn.executemany(
            """
            INSERT INTO inbounds(user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol,
                                 settings, stream_settings, tag, sniffing, allocate, all_time, traffic_reset,
                                 last_traffic_reset_time, live_only, new_field)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (1, 10, 11, 12, "live-remark-1", 1, 111, "127.0.0.1", 10001, "vless", "s", "ss", "tag-1", "sn", "al", 21, "never", 31, "keep-a", "in-live-a"),
                (2, 20, 21, 22, "live-remark-2", 0, 222, "127.0.0.2", 10002, "trojan", "s2", "ss2", "tag-2", "sn2", "al2", 42, "never", 62, "keep-b", "in-live-b"),
            ],
        )
        conn.executemany(
            "INSERT INTO settings(key, value, live_only, new_field) VALUES (?, ?, ?, ?)",
            [("k1", "v1", "live-s", "s-live"), ("k2", "v2", "live-s2", "s-live2")],
        )
        conn.commit()


def setup_config_db(path: Path) -> None:
    exec_sql(
        path,
        """
        CREATE TABLE users (
          username TEXT,
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          new_field TEXT,
          password TEXT,
          login_secret TEXT,
          cfg_only TEXT
        );

        CREATE TABLE inbounds (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          new_field TEXT,
          user_id INTEGER,
          up INTEGER,
          down INTEGER,
          total INTEGER,
          remark TEXT,
          enable NUMERIC,
          expiry_time INTEGER,
          listen TEXT,
          port INTEGER,
          protocol TEXT,
          settings TEXT,
          stream_settings TEXT,
          tag TEXT,
          sniffing TEXT,
          allocate TEXT,
          all_time INTEGER DEFAULT 0,
          traffic_reset TEXT DEFAULT 'never',
          last_traffic_reset_time INTEGER DEFAULT 0,
          cfg_only TEXT
        );

        CREATE TABLE settings (
          key TEXT,
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          value TEXT,
          new_field TEXT,
          cfg_only TEXT
        );
        """,
    )

    with sqlite3.connect(path) as conn:
        conn.executemany(
            "INSERT INTO users(username, new_field, password, login_secret, cfg_only) VALUES (?, ?, ?, ?, ?)",
            [("alice", "u-cfg", "cp1", "cs1", "x"), ("bob", "u-cfg2", "cp2", "cs2", "y")],
        )
        conn.executemany(
            """
            INSERT INTO inbounds(id, new_field, user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol,
                                 settings, stream_settings, tag, sniffing, allocate, all_time, traffic_reset,
                                 last_traffic_reset_time, cfg_only)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (1, "in-cfg-a", 1, 100, 101, 102, "cfg-remark-1", 9, 1111, "10.0.0.1", 20001, "vless", "cs", "css", "cfg-tag-1", "csn", "cal", 201, "never", 301, "x"),
                (2, "in-cfg-b", 2, 200, 201, 202, "cfg-remark-2", 8, 2222, "10.0.0.2", 20002, "trojan", "cs2", "css2", "cfg-tag-2", "csn2", "cal2", 402, "never", 602, "y"),
            ],
        )
        conn.executemany(
            "INSERT INTO settings(key, id, value, new_field, cfg_only) VALUES (?, ?, ?, ?, ?)",
            [("k1", 1, "cfg-v1", "s-cfg", "x"), ("k2", 2, "cfg-v2", "s-cfg2", "y")],
        )
        conn.commit()


def apply_config_like_shell(live_path: Path, cfg_path: Path) -> None:
    live = sqlite3.connect(live_path)
    cfg = sqlite3.connect(cfg_path)
    try:
        live.execute(f"ATTACH DATABASE {qliteral(str(cfg_path))} AS cfg")

        if live.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='users'").fetchone():
            user_cols = common_columns(live, "users", cfg, "users")
            live.execute("DELETE FROM users")
            live.execute(
                f"INSERT INTO users({ident_list(user_cols)}) SELECT {ident_list(user_cols)} FROM cfg.users"
            )

        if live.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbounds'").fetchone():
            inbound_cols = common_columns(live, "inbounds", cfg, "inbounds")
            preserve_cols = [c for c in ("id", "listen", "enable", "remark") if c in inbound_cols]
            if "id" in preserve_cols:
                live.execute(
                    f"CREATE TEMP TABLE local_inbound_state AS SELECT {ident_list(preserve_cols)} FROM inbounds"
                )
            live.execute("DELETE FROM inbounds")
            live.execute(
                f"INSERT INTO inbounds({ident_list(inbound_cols)}) SELECT {ident_list(inbound_cols)} FROM cfg.inbounds"
            )
            update_cols = [c for c in ("listen", "enable", "remark") if c in preserve_cols]
            if update_cols:
                assignments = ", ".join(
                    f"{qident(col)} = (SELECT {qident(col)} FROM local_inbound_state WHERE local_inbound_state.id = inbounds.id)"
                    for col in update_cols
                )
                live.execute(
                    f"UPDATE inbounds SET {assignments} WHERE id IN (SELECT id FROM local_inbound_state)"
                )

        if live.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'").fetchone():
            settings_cols = common_columns(live, "settings", cfg, "settings")
            live.execute("DELETE FROM settings")
            live.execute(
                f"INSERT INTO settings({ident_list(settings_cols)}) SELECT {ident_list(settings_cols)} FROM cfg.settings"
            )

        live.commit()
    finally:
        try:
            live.execute("DETACH DATABASE cfg")
        except sqlite3.Error:
            pass
        cfg.close()
        live.close()
        gc.collect()


def test_config_apply_compat() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        live_path = tmpdir / "live.db"
        cfg_path = tmpdir / "cfg.db"
        setup_live_db(live_path)
        setup_config_db(cfg_path)
        apply_config_like_shell(live_path, cfg_path)

        conn = sqlite3.connect(live_path)
        try:
            conn.row_factory = sqlite3.Row
            users = [dict(row) for row in conn.execute("SELECT * FROM users ORDER BY id")]
            assert users == [
                {"id": 1, "username": "alice", "live_only": None, "password": "cp1", "login_secret": "cs1", "new_field": "u-cfg"},
                {"id": 2, "username": "bob", "live_only": None, "password": "cp2", "login_secret": "cs2", "new_field": "u-cfg2"},
            ]

            inbounds = [dict(row) for row in conn.execute("SELECT * FROM inbounds ORDER BY id")]
            assert inbounds[0]["up"] == 100
            assert inbounds[0]["down"] == 101
            assert inbounds[0]["total"] == 102
            assert inbounds[0]["remark"] == "live-remark-1"
            assert inbounds[0]["enable"] == 1
            assert inbounds[0]["expiry_time"] == 1111
            assert inbounds[0]["listen"] == "127.0.0.1"
            assert inbounds[0]["port"] == 20001
            assert inbounds[0]["protocol"] == "vless"
            assert inbounds[0]["settings"] == "cs"
            assert inbounds[0]["stream_settings"] == "css"
            assert inbounds[0]["tag"] == "cfg-tag-1"
            assert inbounds[0]["all_time"] == 201
            assert inbounds[0]["live_only"] is None
            assert inbounds[0]["new_field"] == "in-cfg-a"

            assert inbounds[1]["up"] == 200
            assert inbounds[1]["down"] == 201
            assert inbounds[1]["total"] == 202
            assert inbounds[1]["remark"] == "live-remark-2"
            assert inbounds[1]["enable"] == 0
            assert inbounds[1]["expiry_time"] == 2222
            assert inbounds[1]["listen"] == "127.0.0.2"
            assert inbounds[1]["port"] == 20002
            assert inbounds[1]["protocol"] == "trojan"
            assert inbounds[1]["settings"] == "cs2"
            assert inbounds[1]["stream_settings"] == "css2"
            assert inbounds[1]["tag"] == "cfg-tag-2"
            assert inbounds[1]["all_time"] == 402
            assert inbounds[1]["live_only"] is None
            assert inbounds[1]["new_field"] == "in-cfg-b"

            settings = [dict(row) for row in conn.execute("SELECT * FROM settings ORDER BY id")]
            assert settings == [
                {"id": 1, "key": "k1", "value": "cfg-v1", "live_only": None, "new_field": "s-cfg"},
                {"id": 2, "key": "k2", "value": "cfg-v2", "live_only": None, "new_field": "s-cfg2"},
            ]
        finally:
            conn.close()
            gc.collect()
        gc.collect()


def master_reset_should_keep_state_on_failure(node_results: list[bool]) -> bool:
    """Return True when the master state DB should be kept."""
    return not all(node_results)


def test_master_reset_policy() -> None:
    assert master_reset_should_keep_state_on_failure([True, True, True]) is False
    assert master_reset_should_keep_state_on_failure([True, False, True]) is True


def config_sync_should_attempt_all_nodes(nodes: list[str], config_master: str) -> list[str]:
    return [node for node in nodes if node != config_master]


def test_config_sync_attempts_all_non_master_nodes() -> None:
    nodes = ["sg-01", "jp-01", "us-01"]
    assert config_sync_should_attempt_all_nodes(nodes, "sg-01") == ["jp-01", "us-01"]


def upsert_user_like_shell(conn: sqlite3.Connection, username: str, password: str, login_secret: str) -> None:
    conn.execute(
        "UPDATE users SET password = ?, login_secret = ? WHERE username = ?",
        (password, login_secret, username),
    )
    conn.execute(
        """
        INSERT INTO users(username, password, login_secret)
        SELECT ?, ?, ?
        WHERE changes() = 0
        """,
        (username, password, login_secret),
    )
    conn.commit()


def test_config_add_user_upserts() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "users.db"
        exec_sql(
            db_path,
            """
            CREATE TABLE users (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              username TEXT,
              password TEXT,
              login_secret TEXT
            );
            INSERT INTO users(username, password, login_secret) VALUES ('alice', 'old', 'old-secret');
            """,
        )
        conn = sqlite3.connect(db_path)
        try:
            upsert_user_like_shell(conn, "alice", "new-pass", "new-secret")
            upsert_user_like_shell(conn, "bob", "bob-pass", "bob-secret")
            rows = conn.execute("SELECT username, password, login_secret FROM users ORDER BY id").fetchall()
            assert rows == [
                ("alice", "new-pass", "new-secret"),
                ("bob", "bob-pass", "bob-secret"),
            ]
        finally:
            conn.close()
            gc.collect()


def reset_client_traffic_like_shell(conn: sqlite3.Connection, user_keys: list[str]) -> None:
    where_clause = ""
    if user_keys:
        quoted = ", ".join(qliteral(key.split("@", 1)[0]) for key in user_keys)
        where_clause = (
            " WHERE CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END "
            f"IN ({quoted})"
        )
    conn.execute(
        f"UPDATE client_traffics SET up = 0, down = 0, all_time = 0, last_online = 0{where_clause}"
    )
    if user_keys:
        quoted = ", ".join(qliteral(key.split("@", 1)[0]) for key in user_keys)
        conn.execute(f"DELETE FROM xui_sync_client_state WHERE user_key IN ({quoted})")
    else:
        conn.execute("DELETE FROM xui_sync_client_state")
    conn.commit()


def test_reset_specific_user_traffic() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "traffic.db"
        exec_sql(
            db_path,
            """
            CREATE TABLE client_traffics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              email TEXT,
              up INTEGER,
              down INTEGER,
              all_time INTEGER,
              last_online INTEGER
            );
            CREATE TABLE xui_sync_client_state (
              user_key TEXT PRIMARY KEY,
              synced_up INTEGER,
              synced_down INTEGER,
              synced_all_time INTEGER,
              synced_last_online INTEGER,
              base_up INTEGER,
              base_down INTEGER,
              base_all_time INTEGER,
              entries INTEGER,
              updated_at INTEGER
            );
            INSERT INTO client_traffics(email, up, down, all_time, last_online) VALUES
              ('alice@a', 10, 11, 21, 1),
              ('alice@b', 12, 13, 25, 2),
              ('bob@a', 20, 21, 41, 3);
            INSERT INTO xui_sync_client_state(user_key, synced_up, synced_down, synced_all_time, synced_last_online, base_up, base_down, base_all_time, entries, updated_at) VALUES
              ('alice', 100, 110, 210, 4, 10, 11, 21, 2, 1),
              ('bob', 200, 210, 410, 5, 20, 21, 41, 1, 1);
            """,
        )
        conn = sqlite3.connect(db_path)
        try:
            reset_client_traffic_like_shell(conn, ["alice"])
            rows = conn.execute("SELECT email, up, down, all_time, last_online FROM client_traffics ORDER BY email").fetchall()
            assert rows == [
                ("alice@a", 0, 0, 0, 0),
                ("alice@b", 0, 0, 0, 0),
                ("bob@a", 20, 21, 41, 3),
            ]
            state_rows = conn.execute("SELECT user_key FROM xui_sync_client_state ORDER BY user_key").fetchall()
            assert state_rows == [("bob",)]
        finally:
            conn.close()
            gc.collect()


def delete_user_like_shell(conn: sqlite3.Connection, user_key: str) -> None:
    conn.execute(
        """
        DELETE FROM users
        WHERE CASE
          WHEN instr(username, '@') > 0 THEN substr(username, 1, instr(username, '@') - 1)
          ELSE username
        END = ?
        """,
        (user_key,),
    )
    conn.execute(
        """
        DELETE FROM client_traffics
        WHERE CASE
          WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
          ELSE email
        END = ?
        """,
        (user_key,),
    )
    conn.execute(
        """
        DELETE FROM inbound_client_ips
        WHERE CASE
          WHEN instr(client_email, '@') > 0 THEN substr(client_email, 1, instr(client_email, '@') - 1)
          ELSE client_email
        END = ?
        """,
        (user_key,),
    )
    conn.execute("DELETE FROM xui_sync_client_state WHERE user_key = ?", (user_key,))
    conn.commit()


def test_delete_user_family() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "delete.db"
        exec_sql(
            db_path,
            """
            CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT, password TEXT, login_secret TEXT);
            CREATE TABLE client_traffics (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT, up INTEGER, down INTEGER, all_time INTEGER, last_online INTEGER);
            CREATE TABLE inbound_client_ips (id INTEGER PRIMARY KEY AUTOINCREMENT, client_email TEXT, ips TEXT);
            CREATE TABLE xui_sync_client_state (user_key TEXT PRIMARY KEY, synced_up INTEGER, synced_down INTEGER, synced_all_time INTEGER, synced_last_online INTEGER, base_up INTEGER, base_down INTEGER, base_all_time INTEGER, entries INTEGER, updated_at INTEGER);
            INSERT INTO users(username, password, login_secret) VALUES ('BENZY', 'p', 's'), ('OTHER', 'p2', 's2');
            INSERT INTO client_traffics(email, up, down, all_time, last_online) VALUES ('BENZY@1', 1, 2, 3, 4), ('BENZY@2', 5, 6, 11, 12), ('OTHER@1', 7, 8, 15, 16);
            INSERT INTO inbound_client_ips(client_email, ips) VALUES ('BENZY@1', '1.1.1.1'), ('OTHER@1', '2.2.2.2');
            INSERT INTO xui_sync_client_state(user_key, synced_up, synced_down, synced_all_time, synced_last_online, base_up, base_down, base_all_time, entries, updated_at) VALUES ('BENZY', 10, 20, 30, 40, 1, 2, 3, 2, 1), ('OTHER', 11, 22, 33, 44, 4, 5, 6, 1, 1);
            """,
        )
        conn = sqlite3.connect(db_path)
        try:
            delete_user_like_shell(conn, "BENZY")
            assert conn.execute("SELECT username FROM users ORDER BY username").fetchall() == [("OTHER",)]
            assert conn.execute("SELECT email FROM client_traffics ORDER BY email").fetchall() == [("OTHER@1",)]
            assert conn.execute("SELECT client_email FROM inbound_client_ips ORDER BY client_email").fetchall() == [("OTHER@1",)]
            assert conn.execute("SELECT user_key FROM xui_sync_client_state ORDER BY user_key").fetchall() == [("OTHER",)]
        finally:
            conn.close()
            gc.collect()


def user_status_like_shell(conn: sqlite3.Connection, user_key: str, now_ms: int = 1700000005000, grace_ms: int = 60000) -> tuple[str, str, str]:
    row = conn.execute(
        """
        WITH cur AS (
          SELECT
            CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END AS user_key,
            SUM(COALESCE(up, 0)) AS up,
            SUM(COALESCE(down, 0)) AS down,
            SUM(COALESCE(all_time, COALESCE(up, 0) + COALESCE(down, 0))) AS all_time,
            MAX(COALESCE(last_online, 0)) AS last_online
          FROM client_traffics
          WHERE email IS NOT NULL AND email <> ''
            AND (CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END) = ?
          GROUP BY user_key
        ),
        ips AS (
          SELECT group_concat(DISTINCT client_email || ':' || ips) AS ips_list
          FROM inbound_client_ips
          WHERE client_email IS NOT NULL AND client_email <> ''
            AND (CASE WHEN instr(client_email, '@') > 0 THEN substr(client_email, 1, instr(client_email, '@') - 1) ELSE client_email END) = ?
        )
        SELECT
          CASE
            WHEN cur.user_key IS NULL THEN 'not-found'
            WHEN COALESCE(ips.ips_list, '') <> '' THEN 'online'
            WHEN COALESCE(cur.last_online, 0) > 0 AND ? - COALESCE(cur.last_online, 0) <= ? THEN 'online'
            WHEN COALESCE(cur.last_online, 0) > 0 THEN 'seen'
            ELSE 'offline'
          END AS status,
          COALESCE(ips.ips_list, '') AS ips,
          CASE WHEN COALESCE(cur.last_online, 0) > 0 THEN datetime(CAST(cur.last_online / 1000 AS INTEGER), 'unixepoch', '+8 hours') ELSE '' END AS last_online_time
        FROM ips
        LEFT JOIN cur ON 1=1
        """,
        (user_key, user_key, now_ms, grace_ms),
    ).fetchone()
    return row[0], row[1], row[2]


def user_last_online_like_shell(conn: sqlite3.Connection, user_key: str) -> tuple[str, int, str, str]:
    row = conn.execute(
        """
        WITH cur AS (
          SELECT
            CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END AS user_key,
            group_concat(DISTINCT email) AS matched_emails,
            MAX(COALESCE(last_online, 0)) AS last_online
          FROM client_traffics
          WHERE email IS NOT NULL AND email <> ''
            AND (CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END) = ?
          GROUP BY user_key
        )
        SELECT
          CASE
            WHEN cur.user_key IS NULL THEN 'not-found'
            ELSE 'seen'
          END AS status,
          COALESCE(cur.last_online, 0) AS last_online,
          COALESCE(cur.matched_emails, '') AS matched_emails,
          CASE WHEN COALESCE(cur.last_online, 0) > 0 THEN datetime(CAST(cur.last_online / 1000 AS INTEGER), 'unixepoch', '+8 hours') ELSE '' END AS last_online_time
        FROM (SELECT 1)
        LEFT JOIN cur ON 1=1
        """,
        (user_key,),
    ).fetchone()
    return row[0], row[1], row[2], row[3]


def test_user_status_detection() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "status.db"
        exec_sql(
            db_path,
            """
            CREATE TABLE client_traffics (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT, up INTEGER, down INTEGER, all_time INTEGER, last_online INTEGER);
            CREATE TABLE inbound_client_ips (id INTEGER PRIMARY KEY AUTOINCREMENT, client_email TEXT, ips TEXT);
            INSERT INTO client_traffics(email, up, down, all_time, last_online) VALUES ('BENZY@1', 1, 2, 3, 1700000000000), ('OTHER@1', 7, 8, 15, 16);
            INSERT INTO inbound_client_ips(client_email, ips) VALUES ('BENZY@1', '1.1.1.1,1.1.1.2');
            """,
        )
        conn = sqlite3.connect(db_path)
        try:
            assert user_status_like_shell(conn, "BENZY") == ("online", "BENZY@1:1.1.1.1,1.1.1.2", "2023-11-15 06:13:20")
            assert user_status_like_shell(conn, "MISSING")[0] == "not-found"
            conn.execute("DELETE FROM inbound_client_ips")
            conn.commit()
            assert user_status_like_shell(conn, "BENZY")[0] == "online"
            assert user_status_like_shell(conn, "BENZY", now_ms=1700001200000)[0] == "seen"
        finally:
            conn.close()
            gc.collect()


def test_user_last_online_detection() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "last-online.db"
        exec_sql(
            db_path,
            """
            CREATE TABLE client_traffics (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT, up INTEGER, down INTEGER, all_time INTEGER, last_online INTEGER);
            INSERT INTO client_traffics(email, up, down, all_time, last_online) VALUES
              ('BENZY@1', 1, 2, 3, 1700000000000),
              ('BENZY@2', 3, 4, 7, 1700000100000),
              ('OTHER@1', 7, 8, 15, 1700000200000);
            """,
        )
        conn = sqlite3.connect(db_path)
        try:
            assert user_last_online_like_shell(conn, "BENZY") == ("seen", 1700000100000, "BENZY@1,BENZY@2", "2023-11-15 06:15:00")
            assert user_last_online_like_shell(conn, "MISSING") == ("not-found", 0, "", "")
        finally:
            conn.close()
            gc.collect()


def main() -> None:
    test_config_apply_compat()
    test_master_reset_policy()
    test_config_sync_attempts_all_non_master_nodes()
    test_config_add_user_upserts()
    test_reset_specific_user_traffic()
    test_delete_user_family()
    test_user_status_detection()
    test_user_last_online_detection()
    print("smoke tests passed")


if __name__ == "__main__":
    main()
