#!/usr/bin/env python3
"""Compile emitted history date filters with conservative real SQLite limits."""

from __future__ import annotations

from datetime import datetime, timedelta
import json
import sqlite3
import sys


def history_query(dates: list[str]) -> tuple[str, list[object]]:
    # Tautulli v2.18/v2.19 datatables.build_custom_where expands list equality
    # as a flat OR expression. Keep that owning-source SQL shape: using IN
    # here would hide SQLite's expression-depth failure for a 3650-date list.
    date_filter = " OR ".join(
        "strftime('%Y-%m-%d', datetime(started, 'unixepoch', 'localtime')) = ?"
        for _ in dates
    )
    sql = (
        "SELECT reference_id, COUNT(*), SUM(stopped-started) FROM history "
        "WHERE (" + date_filter + ") AND started >= ? AND started <= ? "
        "AND section_id = ? AND user_id = ? GROUP BY reference_id"
    )
    bounds = [0, 4102444800, "18446744073709551614", "18446744073709551615"]
    return sql, dates + bounds


def main() -> None:
    requests = json.load(sys.stdin)
    assert isinstance(requests, list) and requests, "No emitted history requests"
    database = sqlite3.connect(":memory:")
    # Older maintained SQLite builds allow only 999 bind variables; the
    # default expression limit is 1000 even on current SQLite releases.
    database.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 999)
    database.setlimit(sqlite3.SQLITE_LIMIT_EXPR_DEPTH, 1000)
    database.execute(
        "CREATE TABLE history(reference_id TEXT, started INTEGER, stopped INTEGER, "
        "section_id TEXT, user_id TEXT)"
    )
    oversized = [
        (datetime(2016, 1, 1) + timedelta(days=offset)).strftime("%Y-%m-%d")
        for offset in range(3650)
    ]
    try:
        database.execute(*history_query(oversized)).fetchall()
    except sqlite3.OperationalError as error:
        assert "Expression tree is too large" in str(error) or "too many SQL variables" in str(error)
    else:
        raise AssertionError("Fixture did not detect the rejected unbounded date expression")

    for request in requests:
        dates = request["start_date"].split(",")
        assert 1 <= len(dates) <= 365, "Emitted request exceeds the safe date chunk"
        assert len(dates) == len(set(dates)), "Repeated date in one request"
        for value in dates:
            assert datetime.strptime(value, "%Y-%m-%d").strftime("%Y-%m-%d") == value
        sql, arguments = history_query(dates)
        # Compile and execute the actual flat OR + grouping shape, rather than
        # just checking request length against an invented server contract.
        assert database.execute(sql, arguments).fetchall() == []
        # Use the host's local noon, matching SQLite's localtime conversion on
        # every runner, including UTC+13/14 where noon UTC is the next day.
        stamp = int(datetime.strptime(dates[0], "%Y-%m-%d").replace(hour=12).timestamp())
        database.execute(
            "INSERT INTO history VALUES(?, ?, ?, ?, ?)",
            ("7", stamp, stamp + 60, "18446744073709551614", "18446744073709551615"),
        )
        assert database.execute(sql, arguments).fetchall() == [("7", 1, 60)]
        database.execute("DELETE FROM history")
    print(f"[PASS] {len(requests)} emitted history date filters execute under SQLite depth1000/variables999; unbounded3650 fails.")


if __name__ == "__main__":
    main()
