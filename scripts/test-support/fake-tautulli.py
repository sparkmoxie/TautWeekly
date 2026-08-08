#!/usr/bin/env python3
"""Small deterministic Tautulli/Plex HTTP double for renderer integration tests."""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def media_rows(scenario: str) -> dict[str, list[dict[str, object]]]:
    now = int(time.time())
    old = now - (30 * 86400)
    movie_added = now if scenario == "active" else old
    tv_added = now if scenario in ("active", "tv-only") else old
    return {
        "10": [
            {
                "section_id": "10",
                "media_type": "movie",
                "rating_key": "selected-movie",
                "title": "Selected Movie",
                "year": "2026",
                "summary": "A release from the selected movie library.",
                "added_at": movie_added,
                "rating": "8.1",
                "rating_image": "rottentomatoes://image.rating.ripe",
                "audience_rating": "9.2",
                "audience_rating_image": "rottentomatoes://image.rating.upright",
                "genres": ["Drama", "Mystery"],
            }
        ],
        "20": [
            {
                "section_id": "20",
                "media_type": "episode",
                "rating_key": "selected-episode",
                "grandparent_rating_key": "selected-show",
                "grandparent_title": "Selected Show",
                "title": "Selected Premiere",
                "year": "2026",
                "summary": "A release from the selected television library.",
                "added_at": tv_added - 60,
                "parent_media_index": 1,
                "media_index": 1,
                "rating": "8.7",
                "rating_image": "imdb://image.rating",
            }
        ],
        "99": [
            {
                "section_id": "99",
                "media_type": "movie",
                "rating_key": "private-movie",
                "title": "Private Movie",
                "year": "2026",
                "summary": "This private-library title must never reach output.",
                "added_at": now + 120,
                "rating": "9.9",
                "audience_rating": "9.9",
            }
        ],
    }


USERS = {
    "1": {
        "user_id": "1",
        "username": "viewer",
        "friendly_name": "Virtual Viewer",
        "email": "viewer@example.test",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
    },
    "2": {
        "user_id": "2",
        "username": "champion",
        "friendly_name": "Simulated Champion",
        "email": "champion@example.test",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
    },
}


def history_rows(section_id: str) -> list[dict[str, object]]:
    if section_id == "10":
        return [
            {
                "section_id": "10",
                "media_type": "movie",
                "rating_key": "selected-movie",
                "title": "Selected Movie",
                "year": "2026",
                "summary": "Selected-library viewing history.",
                "rating": "8.1",
                "audience_rating": "9.2",
                "user_id": "1",
                "friendly_name": "Virtual Viewer",
                "play_duration": 7200,
                "watched_status": 1,
                "percent_complete": 100,
                "group_count": 1,
            }
        ]
    if section_id == "20":
        return [
            {
                "section_id": "20",
                "media_type": "episode",
                "rating_key": "champion-episode",
                "grandparent_rating_key": "selected-show",
                "grandparent_title": "Selected Show",
                "parent_title": "Season 1",
                "title": "Champion Episode",
                "year": "2026",
                "summary": "Selected-library television history.",
                "user_id": "2",
                "friendly_name": "Simulated Champion",
                "play_duration": 10800,
                "watched_status": 1,
                "percent_complete": 100,
                "group_count": 1,
                "parent_media_index": 1,
                "media_index": 2,
                "rating": "8.9",
                "rating_image": "imdb://image.rating",
            }
        ]
    return [
        {
            "section_id": "99",
            "media_type": "movie",
            "rating_key": "private-movie",
            "title": "Private Movie",
            "user_id": "2",
            "friendly_name": "Simulated Champion",
            "play_duration": 86400,
            "watched_status": 1,
            "percent_complete": 100,
            "group_count": 20,
        }
    ]


class Handler(BaseHTTPRequestHandler):
    server_version = "TautWeeklyVirtual/1.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def write_json(self, data: object, status: int = 200) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def api_success(self, data: object) -> None:
        self.write_json({"response": {"result": "success", "message": "", "data": data}})

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        query = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
        with self.server.call_log.open("a", encoding="utf-8") as handle:  # type: ignore[attr-defined]
            handle.write(json.dumps({"path": parsed.path, "query": query}) + "\n")

        if parsed.path.startswith("/library/metadata/"):
            self.write_json({"MediaContainer": {"size": 0, "Metadata": []}})
            return

        if parsed.path != "/api/v2":
            self.write_json({"ok": True})
            return

        command = query.get("cmd", "")
        if command == "pms_image_proxy":
            payload = b"\xff\xd8" + (b"VIRTUAL-POSTER" * 48) + b"\xff\xd9"
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if command == "get_user_names":
            self.api_success([{"user_id": value["user_id"]} for value in USERS.values()])
            return
        if command == "get_users":
            self.api_success(list(USERS.values()))
            return
        if command == "get_user":
            self.api_success(USERS.get(query.get("user_id", ""), USERS["1"]))
            return
        if command == "refresh_users_list":
            self.api_success({})
            return
        if command == "get_tautulli_info":
            self.api_success({"tautulli_version": "2.16.0-virtual"})
            return
        if command == "get_server_info":
            self.api_success({"pms_url": self.server.base_url})  # type: ignore[attr-defined]
            return
        if command == "get_libraries":
            self.api_success(
                [
                    {"section_id": "10", "section_name": "Selected Movies", "section_type": "movie", "count": 1, "is_active": 1},
                    {"section_id": "20", "section_name": "Selected TV", "section_type": "show", "count": 1, "is_active": 1},
                    {"section_id": "99", "section_name": "Private", "section_type": "movie", "count": 1, "is_active": 1},
                ]
            )
            return
        if command == "get_history":
            rows = history_rows(query.get("section_id", ""))
            user_id = query.get("user_id", "")
            if user_id:
                rows = [row for row in rows if str(row.get("user_id", "")) == user_id]
            start = int(query.get("start", "0"))
            length = int(query.get("length", "1000"))
            self.api_success({"data": rows[start : start + length], "recordsFiltered": len(rows)})
            return
        if command == "get_recently_added":
            rows = self.server.rows.get(query.get("section_id", ""), self.server.rows["99"])  # type: ignore[attr-defined]
            start = int(query.get("start", "0"))
            count = int(query.get("count", "100"))
            self.api_success({"recently_added": rows[start : start + count]})
            return
        if command == "get_children_metadata":
            episode = dict(self.server.rows["20"][0])  # type: ignore[attr-defined]
            self.api_success({"children_type": "episode", "children_list": [episode]})
            return
        if command == "get_metadata":
            key = query.get("rating_key", "")
            is_episode = "episode" in key
            is_show = key.startswith("selected-show") and not is_episode
            title = "Selected Show" if is_show else ("Selected Episode" if is_episode else "Selected Movie")
            media_type = "show" if is_show else ("episode" if is_episode else "movie")
            self.api_success(
                {
                    "rating_key": key,
                    "media_type": media_type,
                    "title": title,
                    "year": "2026",
                    "summary": "Virtual metadata for functional rendering.",
                    "added_at": int(time.time()) - 120,
                    "rating": "8.7" if is_episode else "8.1",
                    "rating_image": "imdb://image.rating" if is_episode else "rottentomatoes://image.rating.ripe",
                    "audience_rating": "9.2",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "genres": ["Drama", "Mystery"],
                    "parent_media_index": 1,
                    "media_index": 1,
                    "banner": "",
                    "art": "",
                    "thumb": "",
                }
            )
            return
        if command == "export_metadata":
            self.api_success({"export_id": 0})
            return
        if command == "delete_export":
            self.api_success({})
            return

        self.write_json({"response": {"result": "error", "message": f"Unsupported virtual command: {command}", "data": {}}})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--scenario", choices=("active", "quiet", "tv-only"), required=True)
    parser.add_argument("--call-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.rows = media_rows(args.scenario)  # type: ignore[attr-defined]
    server.call_log = args.call_log  # type: ignore[attr-defined]
    server.base_url = f"http://127.0.0.1:{args.port}"  # type: ignore[attr-defined]
    args.call_log.write_text("", encoding="utf-8")
    args.ready_file.write_text(server.base_url, encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
