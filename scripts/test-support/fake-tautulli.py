#!/usr/bin/env python3
"""Small deterministic Tautulli/Plex HTTP double for renderer integration tests."""

from __future__ import annotations

import argparse
import binascii
import json
import struct
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


DELETED_HISTORY_SCENARIOS = (
    "deleted-history-metadata",
    "deleted-history-legacy-guid",
    "cache-deleted",
)


def virtual_clear_logo_png() -> bytes:
    """Return a deterministic, decodable, bright PNG larger than 256 bytes."""
    width = 320
    height = 96
    scanlines = bytearray()
    for y in range(height):
        scanlines.append(0)
        for x in range(width):
            # A bright white/gold patterned wordmark surrogate gives the
            # renderer a realistic transparent-clearLogo decoding path.
            stripe = ((x // 8) + (y // 8)) % 3
            if x < 8 or x >= width - 8 or y < 8 or y >= height - 8:
                scanlines.extend((0, 0, 0, 0))
            elif stripe == 0:
                scanlines.extend((255, 255, 255, 255))
            elif stripe == 1:
                scanlines.extend((255, 196, 32, 255))
            else:
                scanlines.extend((244, 232, 200, 255))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(scanlines), 9))
        + chunk(b"IEND", b"")
    )


def media_rows(scenario: str) -> dict[str, list[dict[str, object]]]:
    now = int(time.time())
    old = now - (30 * 86400)
    movie_added = now if scenario in ("active", "personal-many", "platform-tie", "last-platform", "rating-export-fallback", "direct-rating-optional", "direct-rating-xml-fallback", "direct-episode-rt-fallback", "cache-prime") else old
    tv_added = now if scenario in ("active", "personal-many", "tv-only", "sparse-episode-metadata", "rating-export-fallback", "direct-rating-optional", "direct-rating-xml-fallback", "direct-episode-rt-fallback", "cache-prime") else old
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

    if scenario == "optional-hero-metadata":
        rows["10"][0].pop("summary", None)
        rows["10"][0].pop("genres", None)

    if scenario == "sparse-episode-metadata":
        rows["20"][0].update(
            {
                "grandparent_summary": "Sparse show-level summary survives enrichment.",
                "grandparent_year": "2026",
                "grandparent_rating": "8.4",
                "grandparent_rating_image": "imdb://image.rating",
                "grandparent_genres": ["Science Fiction", "Drama"],
            }
        )

    # These cases isolate Plex optional/XML rating fallback. The separate
    # sparse-episode fixture proves an authentic recent-row IMDb survives
    # sparse enrichment, so do not seed an exact rating in fallback cases.
    if scenario in {
        "direct-rating-optional", "direct-rating-xml-fallback", "direct-episode-rt-fallback"
    }:
        rows["20"][0].pop("rating", None)
        rows["20"][0].pop("rating_image", None)

    if scenario in ("quiet", "quiet-no-global-history"):
        rows["10"] = [
            {
                "section_id": "10",
                "media_type": "movie",
                "rating_key": key,
                "title": title,
                "year": "2026",
                "summary": summary,
                "added_at": now - (age_days * 86400),
                "rating": rating,
                "rating_image": "rottentomatoes://image.rating.ripe",
                "audience_rating": audience_rating,
                "audience_rating_image": "rottentomatoes://image.rating.upright",
                "genres": genres,
            }
            for key, title, age_days, summary, rating, audience_rating, genres in (
                (
                    "quiet-trending-movie",
                    "Quiet Trending Movie",
                    8,
                    "A complete quiet-week hero with real metadata.",
                    "8.8",
                    "9.4",
                    ["Adventure", "Comedy"],
                ),
                (
                    "quiet-recent-movie-01",
                    "Recent Movie One",
                    9,
                    "The newest non-trending quiet-week movie.",
                    "8.4",
                    "9.0",
                    ["Drama", "Mystery"],
                ),
                (
                    "selected-movie",
                    "Selected Movie",
                    12,
                    "A release from the selected movie library.",
                    "8.1",
                    "9.2",
                    ["Drama", "Mystery"],
                ),
                (
                    "quiet-recent-movie-03",
                    "Recent Movie Three",
                    15,
                    "A third genuine recent movie.",
                    "7.9",
                    "8.7",
                    ["Science Fiction", "Adventure"],
                ),
                (
                    "quiet-recent-movie-04",
                    "Recent Movie Four",
                    20,
                    "A fourth genuine recent movie.",
                    "7.7",
                    "8.5",
                    ["Comedy", "Family"],
                ),
                (
                    "quiet-recent-movie-overflow",
                    "Recent Movie Overflow",
                    25,
                    "A real movie beyond the four-card quiet-week cap.",
                    "7.5",
                    "8.2",
                    ["Documentary"],
                ),
            )
        ]
        rows["20"] = [
            {
                "section_id": "20",
                "media_type": "episode",
                "rating_key": episode_key,
                "grandparent_rating_key": show_key,
                "grandparent_title": show_title,
                "title": episode_title,
                "year": "2026",
                "summary": summary,
                "added_at": now - (age_days * 86400),
                "parent_media_index": 1,
                "media_index": 1,
                "rating": rating,
                "rating_image": "imdb://image.rating",
                "genres": ["Drama", "Mystery"],
            }
            for (
                episode_key,
                show_key,
                show_title,
                episode_title,
                age_days,
                summary,
                rating,
            ) in (
                (
                    "selected-episode",
                    "selected-show",
                    "Selected Show",
                    "Selected Premiere",
                    8,
                    "A release from the selected television library.",
                    "8.7",
                ),
                (
                    "quiet-recent-episode-02",
                    "selected-show-recent-02",
                    "Recent Show Two",
                    "Second Premiere",
                    14,
                    "A second recent television title.",
                    "8.5",
                ),
                (
                    "quiet-recent-episode-03",
                    "selected-show-recent-03",
                    "Recent Show Three",
                    "Third Premiere",
                    21,
                    "A third recent television title.",
                    "8.3",
                ),
                (
                    "quiet-recent-episode-04",
                    "selected-show-recent-04",
                    "Recent Show Four",
                    "Fourth Premiere",
                    27,
                    "A fourth recent television title.",
                    "8.1",
                ),
                (
                    "quiet-stale-episode",
                    "selected-show-stale",
                    "Stale Show Beyond One Month",
                    "Stale Premiere",
                    40,
                    "This title is older than one month and must be excluded.",
                    "7.0",
                ),
            )
        ]
        for episode in rows["20"]:
            episode["grandparent_rating"] = episode["rating"]
            episode["grandparent_rating_image"] = "imdb://image.rating"
        # Keep the selected episode's IMDb distinct from its show's IMDb so
        # integration tests prove show cards use show-level get_metadata.
        rows["20"][1]["rating"] = "6.1"
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


def quiet_metadata_for_key(rating_key: str) -> dict[str, object] | None:
    """Resolve every rich quiet fixture key without collapsing item identity."""
    rows = media_rows("quiet")
    for movie in rows["10"]:
        if str(movie.get("rating_key", "")) == rating_key:
            metadata = dict(movie)
            metadata.update(
                {
                    "media_type": "movie",
                    "banner": "",
                    "art": "",
                    "thumb": "",
                }
            )
            return metadata

    for episode in rows["20"]:
        if str(episode.get("rating_key", "")) == rating_key:
            metadata = dict(episode)
            metadata.update(
                {
                    "media_type": "episode",
                    "grandparent_title": episode.get("grandparent_title", ""),
                    "banner": "",
                    "art": "",
                    "thumb": "",
                }
            )
            return metadata
        if str(episode.get("grandparent_rating_key", "")) == rating_key:
            return {
                "rating_key": rating_key,
                "media_type": "show",
                "title": episode.get("grandparent_title", ""),
                "year": episode.get("year", ""),
                "summary": episode.get("summary", ""),
                "added_at": episode.get("added_at", 0),
                "rating": episode.get("grandparent_rating", ""),
                "rating_image": episode.get("grandparent_rating_image", ""),
                "audience_rating": "",
                "audience_rating_image": "",
                "genres": episode.get("genres", []),
                "banner": "",
                "art": "",
                "thumb": "",
            }

    return None


USERS = {
    "1": {
        "user_id": "1",
        "username": "viewer",
        "friendly_name": "Virtual Viewer",
        "email": "viewer@example.com",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
        "is_owner": 1,
        "platform": "tvOS",
    },
    "2": {
        "user_id": "2",
        "username": "champion",
        "friendly_name": "Simulated Champion",
        "email": "champion@example.com",
        "is_active": 1,
        "deleted_user": 0,
        "do_notify": 1,
        "platform": "Roku",
    },
}


def configured_users(server: ThreadingHTTPServer) -> dict[str, dict[str, object]]:
    users_file: Path | None = server.users_file  # type: ignore[attr-defined]
    if users_file is None:
        return USERS
    values = json.loads(users_file.read_text(encoding="utf-8-sig"))
    if not isinstance(values, list):
        raise ValueError("virtual users file must contain a JSON array")
    users: dict[str, dict[str, object]] = {}
    for value in values:
        if not isinstance(value, dict) or not str(value.get("user_id", "")):
            raise ValueError("virtual user requires a user_id")
        users[str(value["user_id"])] = value
    return users


def history_rows(section_id: str, scenario: str) -> list[dict[str, object]]:
    if scenario == "quiet-no-global-history":
        return []
    if section_id == "10":
        if scenario == "platform-tie":
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
                    "group_count": 2,
                    "platform_name": "chrome",
                    "platform": "Ignored fallback",
                    "started": 100,
                },
                {
                    "section_id": "10",
                    "media_type": "clip",
                    "rating_key": "platform-tie-newer",
                    "title": "Platform tie probe",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 0,
                    "watched_status": 0,
                    "percent_complete": 0,
                    "group_count": 2,
                    "platform": "Android-TV",
                    "started": 200,
                },
                {
                    "section_id": "10",
                    "media_type": "clip",
                    "rating_key": "platform-unknown",
                    "title": "Unknown platform probe",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 0,
                    "watched_status": 0,
                    "percent_complete": 0,
                    "group_count": 500,
                    "platform": "<script>unsafe-platform</script>",
                    "started": 400,
                },
                {
                    "section_id": "10",
                    "media_type": "clip",
                    "rating_key": "other-user-platform",
                    "title": "Other user platform probe",
                    "user_id": "2",
                    "friendly_name": "Simulated Champion",
                    "play_duration": 0,
                    "watched_status": 0,
                    "percent_complete": 0,
                    "group_count": 999,
                    "platform": "Roku",
                    "started": 999,
                },
            ]
        if scenario == "personal-many":
            return [
                {
                    "section_id": "10",
                    "media_type": "movie",
                    "rating_key": f"personal-movie-{index:02d}",
                    "title": f"Personal Movie {index:02d}",
                    "year": "2026",
                    "summary": "Synthetic uncapped personal movie history.",
                    "rating": "8.7" if index != 10 else "",
                    "rating_image": "rottentomatoes://image.rating.ripe" if index != 10 else "",
                    "audience_rating": "9.1" if index != 10 else "",
                    "audience_rating_image": "rottentomatoes://image.rating.upright" if index != 10 else "",
                    "genres": ["Drama", "Mystery"],
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 30 * (13 - index),
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                }
                for index in range(1, 13)
            ]
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
                "platform": "Chrome",
                "started": 100,
            }
        ]
        if scenario == "active":
            rows[0]["group_count"] = 4
            # A real, non-release movie leads the movie-only Trending totals.
            # It is deliberately not a completed watch so Binge Champion
            # expectations remain independent from the compact Trending card.
            rows.append(
                {
                    "section_id": "10",
                    "media_type": "movie",
                    "rating_key": "active-trending-movie",
                    "title": "Active Trending Movie",
                    "year": "2025",
                    "summary": "Authentic server history outside the active release shelf.",
                    "rating": "8.6",
                    "rating_image": "rottentomatoes://image.rating.ripe",
                    "audience_rating": "9.0",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "genres": ["Adventure", "Science Fiction"],
                    "user_id": "2",
                    "friendly_name": "Simulated Champion",
                    "play_duration": 9000,
                    "watched_status": 0,
                    "percent_complete": 50,
                    "group_count": 4,
                    "platform": "Roku",
                    "started": 190,
                }
            )
        if scenario == "sparse-episode-metadata":
            # The first selected-viewer row contains incomplete rating halves
            # and no descriptive metadata. A later row for the same title is
            # complete, proving Get-UserStats backfills whole value/provider
            # pairs plus summary, year, and genres across authentic rows.
            rows[0].update(
                {
                    "year": "",
                    "summary": "",
                    "rating": "",
                    "rating_image": "rottentomatoes://image.rating.ripe",
                    "audience_rating": "7.7",
                    "audience_rating_image": "",
                    "genres": [],
                }
            )
            # An intervening global row supplies the opposite incomplete
            # halves. Get-GlobalTitleTotals must not manufacture a 7.6/RT or
            # 7.7/audience-RT pairing from different history rows.
            rows.append(
                {
                    "section_id": "10",
                    "media_type": "movie",
                    "rating_key": "selected-movie",
                    "title": "Selected Movie",
                    "year": "",
                    "summary": "",
                    "rating": "7.6",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "user_id": "2",
                    "friendly_name": "Simulated Champion",
                    "play_duration": 300,
                    "watched_status": 0,
                    "percent_complete": 10,
                    "group_count": 1,
                    "platform": "Roku",
                    "started": 90,
                }
            )
            rows.append(
                {
                    "section_id": "10",
                    "media_type": "movie",
                    "rating_key": "selected-movie",
                    "title": "Selected Movie",
                    "year": "2026",
                    "summary": "Selected-library viewing history.",
                    "rating": "8.1",
                    "rating_image": "rottentomatoes://image.rating.ripe",
                    "audience_rating": "9.2",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "genres": ["Drama", "Mystery"],
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 600,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "platform": "Chrome",
                    "started": 110,
                }
            )
        if scenario == "quiet-no-history":
            rows[0]["user_id"] = "2"
            rows[0]["friendly_name"] = "Simulated Champion"
            rows[0]["platform"] = "Roku"
            rows[0]["started"] = 200
        if scenario in DELETED_HISTORY_SCENARIOS:
            rows[0]["guid"] = (
                "com.plexapp.agents.tmdb://12345?lang=en"
                if scenario == "deleted-history-legacy-guid"
                else "plex://movie/deletedmovieguid"
            )
            for field in ("year", "summary", "rating", "audience_rating"):
                rows[0].pop(field, None)
        if scenario == "last-platform":
            rows[0]["platform"] = "Unrecognized Platform"
        if scenario == "optional-hero-metadata":
            rows[0]["play_duration"] = 14400
            rows[0]["rating_image"] = "rottentomatoes://image.rating.ripe"
            rows[0]["audience_rating_image"] = "rottentomatoes://image.rating.upright"
            rows[0]["genres"] = ["Drama", "Mystery"]

        if scenario == "quiet":
            rows[0].update(
                {
                    "rating_key": "quiet-trending-movie",
                    "title": "Quiet Trending Movie",
                    "summary": "A complete quiet-week hero with real metadata.",
                    "rating": "8.8",
                    "rating_image": "rottentomatoes://image.rating.ripe",
                    "audience_rating": "9.4",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "genres": ["Adventure", "Comedy"],
                    "play_duration": 14400,
                    "group_count": 4,
                }
            )
            rows[0]["user_id"] = "2"
            rows[0]["friendly_name"] = "Simulated Champion"
            rows[0]["platform"] = "Roku"
            rows[0]["started"] = 200
            rows.append(
                {
                    "section_id": "10",
                    "media_type": "movie",
                    "rating_key": "quiet-recent-movie-01",
                    "title": "Recent Movie One",
                    "year": "2026",
                    "summary": "The newest non-trending quiet-week movie.",
                    "rating": "8.4",
                    "rating_image": "rottentomatoes://image.rating.ripe",
                    "audience_rating": "9.0",
                    "audience_rating_image": "rottentomatoes://image.rating.upright",
                    "genres": ["Drama", "Mystery"],
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 7200,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 2,
                    "platform": "Chrome",
                    "started": 175,
                }
            )
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
                "platform": "Roku",
                "started": 200,
                "parent_media_index": 1,
                "media_index": 1,
                "rating": "8.9",
                "rating_image": "imdb://image.rating",
            }
        ]
        if scenario == "sparse-episode-metadata":
            rows.append(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": "selected-episode",
                    "grandparent_rating_key": "selected-show",
                    "grandparent_title": "Selected Show",
                    "parent_title": "Season 1",
                    "title": "Selected Premiere",
                    "year": "2026",
                    "summary": "Authentic selected-viewer episode history.",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 3600,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "platform": "Chrome",
                    "started": 175,
                    "parent_media_index": 1,
                    "media_index": 1,
                    "rating": "8.7",
                    "rating_image": "imdb://image.rating",
                    "grandparent_summary": "",
                    "grandparent_year": "",
                    "grandparent_rating": "",
                    "grandparent_rating_image": "imdb://image.rating",
                    "grandparent_audience_rating": "7.3",
                    "grandparent_audience_rating_image": "",
                    "grandparent_genres": [],
                }
            )
            rows.append(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": "selected-episode-rich",
                    "grandparent_rating_key": "selected-show",
                    "grandparent_title": "Selected Show",
                    "parent_title": "Season 1",
                    "title": "Selected Followup",
                    "year": "2026",
                    "summary": "Authentic second selected-viewer episode history.",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 1800,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "platform": "Chrome",
                    "started": 170,
                    "parent_media_index": 1,
                    "media_index": 2,
                    "rating": "8.7",
                    "rating_image": "imdb://image.rating",
                    "grandparent_summary": "Sparse show-level summary survives enrichment.",
                    "grandparent_year": "2026",
                    "grandparent_rating": "8.4",
                    "grandparent_rating_image": "imdb://image.rating",
                    "grandparent_genres": ["Science Fiction", "Drama"],
                }
            )
        if scenario == "platform-tie":
            rows.append(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": "viewer-platform-episode",
                    "grandparent_rating_key": "selected-show",
                    "grandparent_title": "Selected Show",
                    "parent_title": "Season 1",
                    "title": "Viewer Platform Episode",
                    "year": "2026",
                    "summary": "Synthetic recipient television history.",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 1800,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "platform": "",
                    "started": 150,
                    "parent_media_index": 1,
                    "media_index": 2,
                    "rating": "8.4",
                    "rating_image": "imdb://image.rating",
                }
            )
        if scenario == "personal-many":
            rows.extend(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": f"personal-episode-{index:02d}",
                    "grandparent_rating_key": f"selected-show-personal-{index:02d}",
                    "grandparent_title": f"Personal Show {index:02d}",
                    "parent_title": "Season 1",
                    "title": f"Personal Episode {index:02d}",
                    "year": "2026",
                    "summary": "Synthetic uncapped personal TV history.",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 120 * (12 - index),
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "parent_media_index": 1,
                    "media_index": index,
                    "rating": "8.4" if index != 9 else "",
                    "rating_image": "imdb://image.rating" if index != 9 else "",
                }
                for index in range(1, 12)
            )
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
                    "platform": "Chrome",
                    "started": 150,
                    "parent_media_index": 1,
                    "media_index": 1,
                }
            )
        if scenario == "quiet":
            rows[0]["play_duration"] = 21600
            rows[0]["group_count"] = 7
            rows.append(
                {
                    "section_id": "20",
                    "media_type": "episode",
                    "rating_key": "quiet-recent-episode-02",
                    "grandparent_rating_key": "selected-show-recent-02",
                    "grandparent_title": "Recent Show Two",
                    "parent_title": "Season 1",
                    "title": "Second Premiere",
                    "year": "2026",
                    "summary": "A real selected-viewer television watch.",
                    "user_id": "1",
                    "friendly_name": "Virtual Viewer",
                    "play_duration": 3600,
                    "watched_status": 1,
                    "percent_complete": 100,
                    "group_count": 1,
                    "platform": "Chrome",
                    "started": 175,
                    "parent_media_index": 1,
                    "media_index": 1,
                    "rating": "6.1",
                    "rating_image": "imdb://image.rating",
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

    def write_xml(self, payload: str, status: int = 200) -> None:
        encoded = payload.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

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
                        "accept": self.headers.get("Accept", ""),
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

        if parsed.path == "/virtual/clear-logo.png":
            payload = virtual_clear_logo_png()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path.endswith("/clearLogos"):
            scenario = self.current_scenario()
            parts = parsed.path.strip("/").split("/")
            rating_key = parts[2] if len(parts) == 4 else ""
            if self.headers.get("X-Plex-Token") != "virtual-plex-token":
                self.write_json({"error": "invalid virtual Plex token"}, status=401)
                return
            eligible_keys = {
                "active": {"selected-movie"},
                "quiet": {"quiet-trending-movie"},
                "sparse-episode-metadata": {"selected-movie"},
            }
            if rating_key in eligible_keys.get(scenario, set()):
                self.write_xml(
                    '<MediaContainer size="1">'
                    f'<Photo selected="1" ratingKey="{rating_key}" '
                    'key="/virtual/clear-logo.png" thumb="/virtual/clear-logo.png" />'
                    "</MediaContainer>"
                )
                return
            self.write_xml('<MediaContainer size="0"></MediaContainer>')
            return

        if parsed.path.startswith("/library/metadata/"):
            scenario = self.current_scenario()
            if scenario in {"direct-rating-optional", "direct-rating-xml-fallback", "direct-episode-rt-fallback"}:
                if self.headers.get("X-Plex-Token") != "virtual-plex-token":
                    self.write_json({"error": "invalid virtual Plex token"}, status=401)
                    return

                metadata_id = parsed.path.rsplit("/", 1)[-1]
                is_episode = "episode" in metadata_id
                is_show = metadata_id.startswith("selected-show") and not is_episode
                metadata: dict[str, object] = {
                    "ratingKey": metadata_id,
                    "type": "episode" if is_episode else ("show" if is_show else "movie"),
                    "ratingImage": "themoviedb://image.rating" if (is_episode or is_show) else "imdb://image.rating",
                    "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
                }
                if (
                    scenario in {"direct-rating-xml-fallback", "direct-episode-rt-fallback"}
                    and "application/xml" in self.headers.get("Accept", "")
                ):
                    rating_xml = (
                        '<Rating image="rottentomatoes://image.rating.ripe" type="critic" value="6.2" />'
                        if (scenario == "direct-episode-rt-fallback" and is_episode)
                        else '<Rating image="imdb://image.rating" type="audience" value="8.6" />'
                        if (is_episode or is_show)
                        else (
                            '<Rating image="rottentomatoes://image.rating.ripe" type="critic" value="8.7" />'
                            '<Rating image="rottentomatoes://image.rating.upright" type="audience" value="8.3" />'
                        )
                    )
                    item_type = "episode" if is_episode else ("show" if is_show else "movie")
                    self.write_xml(
                        f'<MediaContainer size="1"><Video ratingKey="{metadata_id}" type="{item_type}">'
                        f"{rating_xml}</Video></MediaContainer>"
                    )
                    return
                if query.get("excludeFields") != "rating":
                    metadata["rating"] = "7.4" if (is_episode or is_show) else "6.6"
                if query.get("includeOptionalElements") == "Rating":
                    if scenario == "direct-episode-rt-fallback" and is_episode:
                        metadata["Rating"] = [
                            {
                                "image": "rottentomatoes://image.rating.ripe",
                                "type": "critic",
                                "value": "6.2",
                            }
                        ]
                    elif scenario == "direct-rating-xml-fallback":
                        metadata["Rating"] = [
                            {
                                "image": "themoviedb://image.rating" if (is_episode or is_show) else "imdb://image.rating",
                                "type": "audience",
                                "value": "7.4" if (is_episode or is_show) else "7.0",
                            }
                        ]
                    elif is_episode:
                        metadata["Rating"] = [
                            {"image": "imdb://image.rating", "type": "audience", "value": "8.6"}
                        ]
                    elif is_show:
                        metadata["Rating"] = [
                            {"image": "imdb://image.rating", "type": "audience", "value": "8.4"}
                        ]
                    else:
                        metadata["Rating"] = [
                            {"image": "rottentomatoes://image.rating.ripe", "type": "critic", "value": "8.7"},
                            {"image": "rottentomatoes://image.rating.upright", "type": "audience", "value": "8.3"},
                        ]

                self.write_json({"MediaContainer": {"size": 1, "Metadata": [metadata]}})
                return
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
            users = configured_users(self.server)  # type: ignore[arg-type]
            self.api_success([{"user_id": value["user_id"]} for value in users.values()])
            return
        if command == "get_users":
            self.api_success(list(configured_users(self.server).values()))  # type: ignore[arg-type]
            return
        if command == "get_users_table":
            users = list(configured_users(self.server).values())  # type: ignore[arg-type]
            user_id = query.get("user_id", "")
            if user_id:
                users = [user for user in users if str(user.get("user_id", "")) == user_id]
            rows = [
                {"user_id": user.get("user_id", ""), "platform": user.get("platform", "")}
                for user in users
            ]
            start = int(query.get("start", "0"))
            length = int(query.get("length", "25"))
            self.api_success({"data": rows[start : start + length], "recordsFiltered": len(rows)})
            return
        if command == "get_user":
            users = configured_users(self.server)  # type: ignore[arg-type]
            user = users.get(query.get("user_id", ""))
            if user is None:
                self.write_json({"response": {"result": "error", "message": "virtual user not found", "data": {}}})
                return
            self.api_success(user)
            return
        if command == "refresh_users_list":
            fail_refresh_file: Path | None = self.server.fail_refresh_file  # type: ignore[attr-defined]
            if fail_refresh_file is not None and fail_refresh_file.exists():
                self.write_json(
                    {
                        "response": {
                            "result": "error",
                            "message": "virtual roster refresh rejected",
                            "data": {},
                        }
                    }
                )
                return
            refresh_users_file: Path | None = self.server.refresh_users_file  # type: ignore[attr-defined]
            users_file: Path | None = self.server.users_file  # type: ignore[attr-defined]
            if (
                refresh_users_file is not None
                and refresh_users_file.exists()
                and refresh_users_file.stat().st_size > 0
                and users_file is not None
            ):
                refreshed = json.loads(refresh_users_file.read_text(encoding="utf-8-sig"))
                if not isinstance(refreshed, list):
                    raise ValueError("virtual refreshed users file must contain a JSON array")
                users_file.write_text(json.dumps(refreshed), encoding="utf-8")
            self.api_success({})
            return
        if command == "get_tautulli_info":
            self.api_success({"tautulli_version": "2.16.0-virtual"})
            return
        if command == "get_server_info":
            self.api_success({"pms_url": self.server.base_url})  # type: ignore[attr-defined]
            return
        if command == "get_libraries":
            libraries = [
                {"section_id": "10", "section_name": "Selected Movies", "section_type": "movie", "count": 1, "is_active": 1},
                {"section_id": "20", "section_name": "Selected TV", "section_type": "show", "count": 1, "is_active": 1},
                {"section_id": "99", "section_name": "Private", "section_type": "movie", "count": 1, "is_active": 1},
            ]
            if self.current_scenario() == "quiet-no-history":
                libraries = libraries[:2]
            self.api_success(libraries)
            return
        if command == "get_history":
            section_id = query.get("section_id", "")
            if self.current_scenario() == "quiet-no-history" and not section_id:
                rows = history_rows("10", self.current_scenario()) + history_rows("20", self.current_scenario())
            else:
                rows = history_rows(section_id, self.current_scenario())
            user_id = query.get("user_id", "")
            if user_id and self.current_scenario() != "platform-tie":
                rows = [row for row in rows if str(row.get("user_id", "")) == user_id]
            start = int(query.get("start", "0"))
            length = int(query.get("length", "1000"))
            self.api_success({"data": rows[start : start + length], "recordsFiltered": len(rows)})
            return
        if command == "get_recently_added":
            current_rows = media_rows(self.current_scenario())
            section_id = query.get("section_id", "")
            if self.current_scenario() == "quiet-no-history" and not section_id:
                rows = []
            else:
                rows = current_rows.get(section_id, current_rows["99"])
            start = int(query.get("start", "0"))
            count = int(query.get("count", "100"))
            self.api_success({"recently_added": rows[start : start + count]})
            return
        if command == "get_children_metadata":
            current_rows = media_rows(self.current_scenario())["20"]
            parent_key = query.get("rating_key", "")
            episodes = [
                dict(episode)
                for episode in current_rows
                if str(episode.get("grandparent_rating_key", "")) == parent_key
            ]
            if not episodes:
                episodes = [dict(current_rows[0])]
            self.api_success({"children_type": "episode", "children_list": episodes})
            return
        if command == "get_metadata":
            key = query.get("rating_key", "")
            scenario = self.current_scenario()
            if scenario in ("quiet", "quiet-no-global-history"):
                metadata = quiet_metadata_for_key(key)
                if metadata is not None:
                    self.api_success(metadata)
                    return
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
            if scenario == "personal-many" and (key.startswith("personal-movie-") or key.startswith("selected-show-personal-")):
                intentionally_unrated = key.endswith("-10") if key.startswith("personal-movie-") else key.endswith("-09")
                self.api_success(
                    {
                        "rating_key": key,
                        "media_type": "show" if is_show else "movie",
                        "year": "2026",
                        "summary": "Synthetic uncapped personal-stat metadata.",
                        "rating": "" if intentionally_unrated else ("8.4" if is_show else "8.7"),
                        "rating_image": "" if intentionally_unrated else ("imdb://image.rating" if is_show else "rottentomatoes://image.rating.ripe"),
                        "audience_rating": "" if intentionally_unrated or is_show else "9.1",
                        "audience_rating_image": "" if intentionally_unrated or is_show else "rottentomatoes://image.rating.upright",
                        "genres": ["Drama", "Mystery"],
                        "banner": "",
                        "art": "",
                        "thumb": "",
                    }
                )
                return
            if scenario == "sparse-episode-metadata" and key in {
                "selected-movie",
                "selected-show",
                "selected-episode",
            }:
                is_sparse_movie = key == "selected-movie"
                is_sparse_show = key == "selected-show"
                self.api_success(
                    {
                        "rating_key": key,
                        "media_type": "movie" if is_sparse_movie else ("show" if is_sparse_show else "episode"),
                        "title": "Selected Movie" if is_sparse_movie else ("Selected Show" if is_sparse_show else "Selected Premiere"),
                        "year": "",
                        "summary": "",
                        "rating": "",
                        "rating_image": "rottentomatoes://image.rating.ripe" if is_sparse_movie else "imdb://image.rating",
                        "audience_rating": "7.7" if is_sparse_movie else "",
                        "audience_rating_image": "",
                        "genres": [],
                        "parent_media_index": 1,
                        "media_index": 1,
                    }
                )
                return

            if scenario == "active" and key == "active-trending-movie":
                self.api_success(
                    {
                        "rating_key": key,
                        "media_type": "movie",
                        "title": "Active Trending Movie",
                        "year": "2025",
                        "summary": "Authentic server history outside the active release shelf.",
                        "rating": "8.6",
                        "rating_image": "rottentomatoes://image.rating.ripe",
                        "audience_rating": "9.0",
                        "audience_rating_image": "rottentomatoes://image.rating.upright",
                        "genres": ["Adventure", "Science Fiction"],
                        "banner": "",
                        "art": "",
                        "thumb": "",
                    }
                )
                return

            if scenario == "optional-hero-metadata" and not is_episode:
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
            if scenario in {"direct-rating-optional", "direct-rating-xml-fallback", "direct-episode-rt-fallback"}:
                title = "Selected Show" if is_show else ("Selected Episode" if is_episode else "Selected Movie")
                media_type = "show" if is_show else ("episode" if is_episode else "movie")
                self.api_success(
                    {
                        "rating_key": key,
                        "media_type": media_type,
                        "title": title,
                        "year": "2026",
                        "summary": "Virtual metadata with only the selected provider flattened.",
                        "rating": "",
                        "rating_image": "",
                        "audience_rating": "7.4" if (is_episode or is_show) else "6.6",
                        "audience_rating_image": "themoviedb://image.rating" if (is_episode or is_show) else "imdb://image.rating",
                        "genres": ["Drama", "Mystery"],
                        "parent_media_index": 1,
                        "media_index": 1,
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
            "personal-many",
            "platform-tie",
            "last-platform",
            "quiet",
            "tv-only",
            "quiet-no-history",
            "quiet-no-global-history",
            "optional-hero-metadata",
            "rating-export-fallback",
            "direct-rating-optional",
            "direct-rating-xml-fallback",
            "direct-episode-rt-fallback",
            "sparse-episode-metadata",
            "deleted-history-metadata",
            "deleted-history-legacy-guid",
            "cache-prime",
            "cache-deleted",
        ),
        required=True,
    )
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--users-file", type=Path)
    parser.add_argument("--refresh-users-file", type=Path)
    parser.add_argument("--fail-refresh-file", type=Path)
    parser.add_argument("--call-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.rows = media_rows(args.scenario)  # type: ignore[attr-defined]
    server.scenario = args.scenario  # type: ignore[attr-defined]
    server.state_file = args.state_file  # type: ignore[attr-defined]
    server.users_file = args.users_file  # type: ignore[attr-defined]
    server.refresh_users_file = args.refresh_users_file  # type: ignore[attr-defined]
    server.fail_refresh_file = args.fail_refresh_file  # type: ignore[attr-defined]
    server.call_log = args.call_log  # type: ignore[attr-defined]
    server.base_url = f"http://127.0.0.1:{args.port}"  # type: ignore[attr-defined]
    args.call_log.write_text("", encoding="utf-8")
    args.ready_file.write_text(server.base_url, encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
