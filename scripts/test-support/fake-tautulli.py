#!/usr/bin/env python3
"""Small deterministic Tautulli/Plex HTTP double for renderer integration tests."""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


DELETED_HISTORY_SCENARIOS = (
    "deleted-history-metadata",
    "deleted-history-legacy-guid",
    "cache-deleted",
)


def media_rows(scenario: str) -> dict[str, list[dict[str, object]]]:
    now = int(time.time())
    old = now - (30 * 86400)
    movie_added = now if scenario in ("active", "optional-hero-metadata", "rating-export-fallback", "cache-prime") else old
    tv_added = now if scenario in ("active", "tv-only", "optional-hero-metadata", "rating-export-fallback", "cache-prime") else old
    rows = {
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
    if scenario in DELETED_HISTORY_SCENARIOS or scenario == "cache-prime":
        if scenario == "deleted-history-legacy-guid":
            rows["10"][0]["guid"] = "com.plexapp.agents.tmdb://12345?lang=en"
            rows["20"][0]["guid"] = "com.plexapp.agents.thetvdb://999/1/2?lang=en"
        else:
            rows["10"][0]["guid"] = "plex://movie/deletedmovieguid"
            rows["20"][0]["guid"] = "plex://episode/deletedepisodeguid"
    if scenario in DELETED_HISTORY_SCENARIOS:
        for field in (
            "year",
            "summary",
            "rating",
            "rating_image",
            "audience_rating",
            "audience_rating_image",
            "genres",
        ):
            rows["10"][0].pop(field, None)
        for field in ("year", "summary", "rating", "rating_image"):
            rows["20"][0].pop(field, None)
    return rows


USERS = {
    "1": {
        "user_id": "1",
        "username": "viewer",
        "friendly_name": "Virtual Viewer",
        "email": "viewer@example.com",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
    },
    "2": {
        "user_id": "2",
        "username": "champion",
        "friendly_name": "Simulated Champion",
        "email": "champion@example.com",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
    },
}


def history_rows(section_id: str, scenario: str) -> list[dict[str, object]]:
    if section_id == "10":
        rows = [
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
        if scenario in DELETED_HISTORY_SCENARIOS:
            rows[0]["guid"] = (
                "com.plexapp.agents.tmdb://12345?lang=en"
                if scenario == "deleted-history-legacy-guid"
                else "plex://movie/deletedmovieguid"
            )
            for field in ("year", "summary", "rating", "audience_rating"):
                rows[0].pop(field, None)
        return rows
    if section_id == "20":
        rows = [
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
                "media_index": 1,
                "rating": "8.9",
                "rating_image": "imdb://image.rating",
            }
        ]
        if scenario in DELETED_HISTORY_SCENARIOS:
            deleted_episode_guid = (
                "com.plexapp.agents.thetvdb://999/1/2?lang=en"
                if scenario == "deleted-history-legacy-guid"
                else "plex://episode/deletedepisodeguid"
            )
            rows[0]["guid"] = deleted_episode_guid
            for field in ("year", "summary", "rating", "rating_image"):
                rows[0].pop(field, None)
            rows.append(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": "viewer-deleted-episode",
                    "grandparent_rating_key": "selected-show",
                    "grandparent_title": "Selected Show",
                    "parent_title": "Season 1",
                    "title": "Viewer Deleted Episode",
                    "year": "2026",
                    "guid": deleted_episode_guid,
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 1800,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "parent_media_index": 1,
                    "media_index": 1,
                }
            )
        return rows
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

    def current_scenario(self) -> str:
        state_file: Path | None = self.server.state_file  # type: ignore[attr-defined]
        if state_file is not None and state_file.exists():
            value = state_file.read_text(encoding="utf-8").strip()
            if value:
                return value
        return self.server.scenario  # type: ignore[attr-defined]

    def record_call(
        self,
        method: str,
        path: str,
        query: dict[str, str],
        body: object | None = None,
    ) -> None:
        with self.server.call_log.open("a", encoding="utf-8") as handle:  # type: ignore[attr-defined]
            handle.write(
                json.dumps(
                    {
                        "method": method,
                        "path": path,
                        "query": query,
                        "body": body,
                        "has_plex_token": bool(self.headers.get("X-Plex-Token")),
                    }
                )
                + "\n"
            )

    def hosted_match_payload(self, external_guid: str, media_type: str) -> dict[str, object]:
        if self.current_scenario() == "cache-deleted":
            return {"MediaContainer": {"Metadata": []}}
        if external_guid == "plex://movie/deletedmovieguid" and media_type == "1":
            return {
                "MediaContainer": {
                    "Metadata": [
                        {
                            "type": "movie",
                            "guid": "plex://movie/deletedmovieguid",
                            "slug": "selected-movie",
                            "title": "Selected Movie",
                            "year": "2026",
                            "summary": "Hosted history movie summary.",
                            "thumb": f"http://localhost:{self.server.server_port}/hosted/deleted-movie.jpg",  # type: ignore[attr-defined]
                            "Genre": [
                                {"tag": "History Drama"},
                                {"tag": "Mystery"},
                                {"tag": "Archive"},
                            ],
                        }
                    ]
                }
            }

        if external_guid == "plex://episode/deletedepisodeguid" and media_type == "4":
            return {
                "MediaContainer": {
                    "Metadata": [
                        {
                            "type": "episode",
                            "guid": "plex://episode/deletedepisodeguid",
                            "grandparentGuid": "plex://show/deletedshowguid",
                            "grandparentThumb": f"{self.server.base_url}/hosted/deleted-show.jpg",  # type: ignore[attr-defined]
                        }
                    ]
                }
            }

        if external_guid == "plex://show/deletedshowguid" and media_type == "2":
            return {
                "MediaContainer": {
                    "Metadata": [
                        {
                            "type": "show",
                            "guid": "plex://show/deletedshowguid",
                            "slug": "selected-show",
                            "title": "Selected Show",
                            "year": "2024",
                            "summary": "Hosted history show summary.",
                            "thumb": f"{self.server.base_url}/hosted/deleted-show.jpg",  # type: ignore[attr-defined]
                            "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
                        }
                    ]
                }
            }

        if external_guid == "tmdb://12345" and media_type == "1":
            return {
                "MediaContainer": {
                    "Metadata": [
                        {
                            "type": "movie",
                            "guid": "plex://movie/deletedmovieguid",
                            "slug": "selected-movie",
                            "title": "Selected Movie",
                            "year": "2026",
                            "summary": "Hosted history movie summary.",
                            "thumb": f"http://localhost:{self.server.server_port}/hosted/deleted-movie.jpg",  # type: ignore[attr-defined]
                            "Genre": [
                                {"tag": "History Drama"},
                                {"tag": "Mystery"},
                                {"tag": "Archive"},
                            ],
                        }
                    ]
                }
            }

        if external_guid == "tvdb://999" and media_type == "2":
            return {
                "MediaContainer": {
                    "Metadata": [
                        {
                            "type": "show",
                            "guid": "plex://show/deletedshowguid",
                            "slug": "selected-show",
                            "title": "Selected Show",
                            "year": "2024",
                            "summary": "Hosted history show summary.",
                            "thumb": f"{self.server.base_url}/hosted/deleted-show.jpg",  # type: ignore[attr-defined]
                            "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
                        }
                    ]
                }
            }

        return {"MediaContainer": {"Metadata": []}}

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        query = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        try:
            body = json.loads(self.rfile.read(content_length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.write_json({"error": "invalid JSON body"}, status=400)
            return
        self.record_call("POST", parsed.path, query, body)

        if parsed.path != "/hosted/library/metadata/matches":
            self.write_json({"error": "unsupported virtual POST"}, status=404)
            return
        if not self.headers.get("X-Plex-Token"):
            self.write_json({"error": "missing virtual Plex token"}, status=401)
            return
        if not isinstance(body, dict):
            self.write_json({"error": "match body required"}, status=400)
            return

        external_guid = str(body.get("guid", ""))
        media_type = str(body.get("type", ""))
        if media_type in {"1", "2"}:
            expected_title = "Selected Movie" if media_type == "1" else "Selected Show"
            if body.get("title") != expected_title:
                self.write_json({"error": "title is required for movie/show matching"}, status=400)
                return
        elif media_type == "4":
            if (
                body.get("grandparentTitle") != "Selected Show"
                or body.get("parentIndex") != 1
                or body.get("index") != 1
            ):
                self.write_json({"error": "show title and episode indexes are required"}, status=400)
                return
        else:
            self.write_json({"error": "unsupported metadata type"}, status=400)
            return

        self.write_json(self.hosted_match_payload(external_guid, media_type))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        query = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
        self.record_call("GET", parsed.path, query)

        if parsed.path in {"/identity", "/library/sections"}:
            if self.headers.get("X-Plex-Token") != "virtual-plex-token":
                self.write_json({"error": "invalid virtual Plex token"}, status=401)
                return
            self.write_json({"MediaContainer": {"size": 1}})
            return

        if parsed.path == "/hosted/library/metadata/matches":
            if not self.headers.get("X-Plex-Token"):
                self.write_json({"error": "missing virtual Plex token"}, status=401)
                return

            external_guid = query.get("guid", "")
            media_type = query.get("type", "")
            if self.current_scenario() == "deleted-history-legacy-guid":
                # Reproduce the v0.8.1 report: the compatible query form
                # completes but returns no match, while the provider POST
                # contract resolves the same exact external identifier.
                self.write_json({"MediaContainer": {"Metadata": []}})
                return

            self.write_json(self.hosted_match_payload(external_guid, media_type))
            return

        if parsed.path.startswith("/hosted/library/metadata/"):
            metadata_id = parsed.path.rsplit("/", 1)[-1]
            if not self.headers.get("X-Plex-Token"):
                self.write_json({"error": "missing virtual Plex token"}, status=401)
                return

            if self.current_scenario() in {"deleted-history-metadata", "cache-deleted"} and metadata_id in {
                "deletedmovieguid",
                "deletedepisodeguid",
                "deletedshowguid",
            }:
                self.write_json({"MediaContainer": {"Metadata": []}})
                return

            if metadata_id == "deletedmovieguid":
                self.write_json(
                    {
                        "MediaContainer": {
                            "Metadata": [
                                {
                                    "type": "movie",
                                    "guid": "plex://movie/deletedmovieguid",
                                    "slug": "selected-movie",
                                    "title": "Selected Movie",
                                    "year": "2026",
                                    "summary": "Hosted history movie summary.",
                                    "thumb": f"http://localhost:{self.server.server_port}/hosted/deleted-movie.jpg",  # type: ignore[attr-defined]
                                    "Genre": [
                                        {"tag": "History Drama"},
                                        {"tag": "Mystery"},
                                        {"tag": "Archive"},
                                    ],
                                }
                            ]
                        }
                    }
                )
                return

            if metadata_id == "deletedepisodeguid":
                self.write_json(
                    {
                        "MediaContainer": {
                            "Metadata": [
                                {
                                    "type": "episode",
                                    "guid": "plex://episode/deletedepisodeguid",
                                    "grandparentGuid": "plex://show/deletedshowguid",
                                    "grandparentThumb": f"{self.server.base_url}/hosted/deleted-show.jpg",  # type: ignore[attr-defined]
                                }
                            ]
                        }
                    }
                )
                return

            if metadata_id == "deletedshowguid":
                self.write_json(
                    {
                        "MediaContainer": {
                            "Metadata": [
                                {
                                    "type": "show",
                                    "guid": "plex://show/deletedshowguid",
                                    "slug": "selected-show",
                                    "title": "Selected Show",
                                    "year": "2024",
                                    "summary": "Hosted history show summary.",
                                    "thumb": f"{self.server.base_url}/hosted/deleted-show.jpg",  # type: ignore[attr-defined]
                                    "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
                                }
                            ]
                        }
                    }
                )
                return

            self.write_json({"MediaContainer": {"Metadata": []}})
            return

        if parsed.path == "/watch/movie/selected-movie":
            payload = (
                '<div data-testid="metadata-ratings">'
                '<span title="87% critic rating on Rotten Tomatoes">87%</span>'
                '<span title="93% audience rating on Rotten Tomatoes">93%</span>'
                '<span title="8.1 audience rating on IMDb">8.1</span>'
                "</div>"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path == "/watch/show/selected-show":
            payload = (
                '<div data-testid="metadata-ratings">'
                '<span title="8.4 audience rating on IMDb">8.4</span>'
                '<span title="99% critic rating on Rotten Tomatoes">99%</span>'
                "</div>"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path in ("/hosted/deleted-movie.jpg", "/hosted/deleted-show.jpg"):
            marker = b"MOVIE" if parsed.path.endswith("deleted-movie.jpg") else b"SHOW"
            payload = b"\xff\xd8" + (marker * 160) + b"\xff\xd9"
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path.startswith("/library/metadata/"):
            scenario = self.current_scenario()
            if scenario in ("optional-hero-metadata", "rating-export-fallback") or scenario in DELETED_HISTORY_SCENARIOS:
                self.write_json({"error": "sanitized missing Plex metadata"}, status=404)
                return
            self.write_json({"MediaContainer": {"size": 0, "Metadata": []}})
            return

        if parsed.path != "/api/v2":
            self.write_json({"ok": True})
            return

        command = query.get("cmd", "")
        if command == "download_export" and self.current_scenario() == "rating-export-fallback":
            if query.get("export_id") == "59":
                # Current Tautulli show exports do not expose ratingImage, but
                # they do expose the selected audience provider fields.
                export_data = [
                    {
                        "rating": "",
                        "audienceRating": "7.4",
                        "audienceRatingImage": "themoviedb://image.rating",
                    }
                ]
            else:
                export_data = [
                    {
                        "rating": "5.3",
                        "ratingImage": "rottentomatoes://image.rating.rotten",
                        "audienceRating": "4.0",
                        "audienceRatingImage": "rottentomatoes://image.rating.spilled",
                    }
                ]
            payload = json.dumps(export_data).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if command == "pms_image_proxy":
            rating_key = query.get("rating_key", "")
            is_generic_probe = not rating_key or rating_key.startswith("tautulli-default-poster-")
            marker = (
                b"GENERIC-POSTER"
                if self.current_scenario() in DELETED_HISTORY_SCENARIOS or is_generic_probe
                else b"VIRTUAL-POSTER"
            )
            payload = b"\xff\xd8" + (marker * 48) + b"\xff\xd9"
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
            rows = history_rows(query.get("section_id", ""), self.current_scenario())
            user_id = query.get("user_id", "")
            if user_id:
                rows = [row for row in rows if str(row.get("user_id", "")) == user_id]
            start = int(query.get("start", "0"))
            length = int(query.get("length", "1000"))
            self.api_success({"data": rows[start : start + length], "recordsFiltered": len(rows)})
            return
        if command == "get_recently_added":
            current_rows = media_rows(self.current_scenario())
            rows = current_rows.get(query.get("section_id", ""), current_rows["99"])
            start = int(query.get("start", "0"))
            count = int(query.get("count", "100"))
            self.api_success({"recently_added": rows[start : start + count]})
            return
        if command == "get_children_metadata":
            episode = dict(media_rows(self.current_scenario())["20"][0])
            self.api_success({"children_type": "episode", "children_list": [episode]})
            return
        if command == "get_metadata":
            key = query.get("rating_key", "")
            scenario = self.current_scenario()
            if scenario in DELETED_HISTORY_SCENARIOS and key in (
                "selected-movie",
                "selected-show",
                "champion-episode",
                "viewer-deleted-episode",
            ):
                self.write_json(
                    {
                        "response": {
                            "result": "error",
                            "message": "sanitized deleted Plex metadata",
                            "data": {},
                        }
                    }
                )
                return
            is_episode = "episode" in key
            is_show = key.startswith("selected-show") and not is_episode
            if scenario == "optional-hero-metadata" and is_show:
                # Tautulli may return a successful but sparse metadata object. The
                # renderer must retain the global-history title and default every
                # absent optional hero field without violating strict mode.
                self.api_success({"media_type": "show"})
                return
            if scenario == "rating-export-fallback" and not is_episode and not is_show:
                self.api_success(
                    {
                        "rating_key": key,
                        "media_type": "movie",
                        "title": "Selected Movie",
                        "year": "2026",
                        "summary": "Virtual metadata with an IMDb fallback selected before RT enrichment.",
                        "rating": "6.6",
                        "rating_image": "imdb://image.rating",
                        "audience_rating": "",
                        "audience_rating_image": "",
                        "genres": ["Drama", "Mystery"],
                    }
                )
                return
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
        if command == "get_export_fields" and self.current_scenario() == "rating-export-fallback":
            media_type = query.get("media_type")
            if media_type not in ("movie", "show") or query.get("sub_media_type") != media_type:
                self.write_json(
                    {
                        "response": {
                            "result": "error",
                            "message": "sanitized exporter field discovery requires a compatible subtype",
                            "data": {},
                        }
                    }
                )
                return
            metadata_fields = [
                {"field": "rating", "level": 1},
                {"field": "audienceRating", "level": 1},
                {"field": "audienceRatingImage", "level": 1},
                {"field": "contentRating", "level": 1},
            ]
            if media_type == "movie":
                metadata_fields.insert(1, {"field": "ratingImage", "level": 1})
            self.api_success(
                {
                    "metadata_fields": metadata_fields,
                    "media_info_fields": [],
                }
            )
            return
        if command == "export_metadata":
            if self.current_scenario() == "rating-export-fallback":
                if query.get("individual_files", "").lower() != "false":
                    self.write_json(
                        {
                            "response": {
                                "result": "error",
                                "message": "Individual file export is only allowed for library or user export.",
                                "data": {},
                            }
                        },
                        status=400,
                    )
                    return
                requested_fields = {
                    field.strip()
                    for field in query.get("custom_fields", "").split(",")
                    if field.strip()
                }
                required_fields = {"rating", "audienceRating", "audienceRatingImage"}
                if query.get("rating_key") != "selected-show":
                    required_fields.add("ratingImage")
                if not required_fields.issubset(requested_fields):
                    self.write_json(
                        {
                            "response": {
                                "result": "error",
                                "message": "sanitized item export omitted provider-labelled rating fields",
                                "data": {},
                            }
                        },
                        status=400,
                    )
                    return
                export_id = 59 if query.get("rating_key") == "selected-show" else 58
                self.api_success({"export_id": export_id})
                return
            self.api_success({"export_id": 0})
            return
        if command == "get_exports_table" and self.current_scenario() == "rating-export-fallback":
            self.api_success(
                {
                    "data": [
                        {"export_id": 58, "complete": 1},
                        {"export_id": 59, "complete": 1},
                    ]
                }
            )
            return
        if command == "delete_export":
            self.api_success({})
            return

        self.write_json({"response": {"result": "error", "message": f"Unsupported virtual command: {command}", "data": {}}})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument(
        "--scenario",
        choices=(
            "active",
            "quiet",
            "tv-only",
            "optional-hero-metadata",
            "rating-export-fallback",
            "deleted-history-metadata",
            "deleted-history-legacy-guid",
            "cache-prime",
            "cache-deleted",
        ),
        required=True,
    )
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--call-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.rows = media_rows(args.scenario)  # type: ignore[attr-defined]
    server.scenario = args.scenario  # type: ignore[attr-defined]
    server.state_file = args.state_file  # type: ignore[attr-defined]
    server.call_log = args.call_log  # type: ignore[attr-defined]
    server.base_url = f"http://127.0.0.1:{args.port}"  # type: ignore[attr-defined]
    args.call_log.write_text("", encoding="utf-8")
    args.ready_file.write_text(server.base_url, encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
