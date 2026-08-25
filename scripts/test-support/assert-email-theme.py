#!/usr/bin/env python3
"""Assert that a captured SMTP message preserves the dark email contract."""

from __future__ import annotations

import argparse
import hashlib
import html as html_module
import re
import struct
from email import policy
from email.parser import BytesParser
from pathlib import Path


REQUIRED_HTML = (
    '<meta name="color-scheme" content="light dark">',
    '<meta name="supported-color-schemes" content="light dark">',
    ':root { color-scheme:light dark; supported-color-schemes:light dark; }',
    '@media (prefers-color-scheme: dark)',
    'class="email-background"',
    'bgcolor="#0f0f0f"',
    'background-color:#0f0f0f',
    'class="email-card"',
    'bgcolor="#181818"',
    'background-color:#181818',
)

def scoped_html_region(html: str, specification: str, label: str) -> tuple[str, str]:
    parts = specification.split("=", 2)
    if len(parts) != 3 or not all(parts):
        raise AssertionError(
            f"invalid bounded HTML {label}: {specification}; expected START=END=VALUE"
        )
    start_marker, end_marker, value = parts
    start_index = html.find(start_marker)
    if start_index < 0:
        raise AssertionError(f"delivered HTML lost bounded-region start marker: {start_marker}")
    end_index = html.find(end_marker, start_index + len(start_marker))
    if end_index < 0:
        raise AssertionError(f"delivered HTML lost bounded-region end marker: {end_marker}")
    if end_index <= start_index:
        raise AssertionError(
            f"delivered HTML bounded-region markers are out of order: {start_marker}, {end_marker}"
        )
    return html[start_index:end_index], value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("message", type=Path)
    parser.add_argument("--require-html", action="append", default=[])
    parser.add_argument("--require-preheader")
    parser.add_argument("--forbid-html", action="append", default=[])
    parser.add_argument("--forbid-html-after", action="append", default=[])
    parser.add_argument("--require-plain", action="append", default=[])
    parser.add_argument("--forbid-plain", action="append", default=[])
    parser.add_argument("--require-html-after", action="append", default=[])
    parser.add_argument("--require-cid-sha256", action="append", default=[])
    parser.add_argument("--require-cid-png-dimensions", action="append", default=[])
    parser.add_argument("--require-html-between", action="append", default=[])
    parser.add_argument("--forbid-html-between", action="append", default=[])
    args = parser.parse_args()

    message = BytesParser(policy=policy.default).parsebytes(args.message.read_bytes())
    html_parts = [part for part in message.walk() if part.get_content_type() == "text/html"]
    plain_parts = [part for part in message.walk() if part.get_content_type() == "text/plain"]
    if len(html_parts) != 1:
        raise AssertionError(f"expected one HTML MIME part, found {len(html_parts)}")
    if len(plain_parts) != 1:
        raise AssertionError(f"expected one plain-text MIME part, found {len(plain_parts)}")

    plain_text = plain_parts[0].get_content().replace("\r\n", "\n")
    html = html_parts[0].get_content()
    referenced_cids = set(re.findall(r"""cid:([^"'\s<>]+)""", html))
    cid_parts: dict[str, list] = {}
    for part in message.walk():
        cid = (part.get("Content-ID") or "").strip("<>")
        if cid:
            cid_parts.setdefault(cid, []).append(part)
    for cid in referenced_cids:
        if len(cid_parts.get(cid, [])) != 1:
            raise AssertionError(f"broken or duplicated HTML CID reference: {cid}")

    # Watched resources are linked only when used. Verify exact approved bytes
    # whenever rendered, and require no unused watched MIME parts otherwise.
    watched_assets = {
        "recipient_watched": (
            "26744BE4A08445006673CEE9757E88937FF6A98406ECA4ACF6C4DA4FC2B20498", "20x20"
        ),
        "recipient_watched_desktop": (
            "714BBB0D84C41A22AD38717A52BF177029F8854EC3ACE48E753C162D7E97A52E", "26x26"
        ),
    }
    for cid, (expected_hash, dimensions) in watched_assets.items():
        if cid in referenced_cids:
            args.require_cid_sha256.append(f"{cid}={expected_hash}")
            args.require_cid_png_dimensions.append(f"{cid}={dimensions}")
            payload = cid_parts[cid][0].get_payload(decode=True) or b""
            if len(payload) < 26 or payload[24:26] != bytes((8, 6)):
                raise AssertionError(f"watched CID {cid} lost 8-bit RGBA transparency")
        elif cid in cid_parts:
            raise AssertionError(f"unused watched MIME resource was attached: {cid}")
    if args.require_preheader is not None:
        preheader_match = re.search(
            r'<div style="display:none!important;[^"<>]*mso-hide:all;">(?P<text>.*?)</div>',
            html,
            flags=re.DOTALL,
        )
        if preheader_match is None:
            raise AssertionError("delivered HTML is missing the hidden email preheader")
        preheader_text = re.sub(r"<[^>]+>", "", preheader_match.group("text"))
        preheader_text = html_module.unescape(preheader_text)
        preheader_text = preheader_text.replace("\u200c", "").replace("\u00a0", "").strip()
        if preheader_text != args.require_preheader:
            raise AssertionError(
                f"delivered HTML preheader mismatch: {preheader_text!r} != {args.require_preheader!r}"
            )
        plain_first_line = plain_text.lstrip("\ufeff").split("\n", 1)[0].strip()
        if plain_first_line != args.require_preheader:
            raise AssertionError(
                f"delivered plain-text preheader mismatch: {plain_first_line!r} != "+
                f"{args.require_preheader!r}"
            )
    for marker in (*REQUIRED_HTML, *args.require_html):
        if marker not in html:
            raise AssertionError(f"delivered HTML lost dark-theme marker: {marker}")
    for marker in args.forbid_html:
        if marker in html:
            raise AssertionError(f"delivered HTML retained forbidden marker: {marker}")
    for marker in args.require_plain:
        if marker not in plain_text:
            raise AssertionError(f"delivered plain text lost required marker: {marker}")
    for marker in args.forbid_plain:
        if marker in plain_text:
            raise AssertionError(f"delivered plain text retained forbidden marker: {marker}")
    for specification in args.require_html_after:
        if "=" not in specification:
            raise AssertionError(f"invalid scoped HTML requirement: {specification}")
        marker, required = specification.split("=", 1)
        marker_index = html.find(marker)
        if marker_index < 0:
            raise AssertionError(f"delivered HTML lost scoped-region marker: {marker}")
        if required not in html[marker_index:]:
            raise AssertionError(
                f"delivered HTML lost required marker after {marker}: {required}"
            )

    for specification in args.forbid_html_after:
        if "=" not in specification:
            raise AssertionError(f"invalid scoped HTML prohibition: {specification}")
        marker, forbidden = specification.split("=", 1)
        marker_index = html.find(marker)
        if marker_index < 0:
            raise AssertionError(f"delivered HTML lost scoped-region marker: {marker}")
        if forbidden in html[marker_index:]:
            raise AssertionError(
                f"delivered HTML retained forbidden marker after {marker}: {forbidden}"
            )

    for specification in args.require_html_between:
        region, required = scoped_html_region(html, specification, "requirement")
        if required not in region:
            raise AssertionError(
                f"delivered HTML lost required marker in bounded region: {required}"
            )

    for specification in args.forbid_html_between:
        region, forbidden = scoped_html_region(html, specification, "prohibition")
        if forbidden in region:
            raise AssertionError(
                f"delivered HTML retained forbidden marker in bounded region: {forbidden}"
            )

    for shorthand in ("background:#0f0f0f", "background:#181818"):
        if shorthand in html:
            raise AssertionError(f"delivered HTML retained unsupported color shorthand: {shorthand}")
    for stale_scheme in (
        '<meta name="color-scheme" content="dark">',
        '<meta name="supported-color-schemes" content="dark">',
        "color-scheme:dark only",
    ):
        if stale_scheme in html:
            raise AssertionError(
                f"delivered HTML retained the incompatible dark-only declaration: {stale_scheme}"
            )

    for specification in args.require_cid_sha256:
        if "=" not in specification:
            raise AssertionError(f"invalid CID hash requirement: {specification}")
        cid, expected_hash = specification.split("=", 1)
        matches = [
            part
            for part in message.walk()
            if (part.get("Content-ID") or "").strip("<>") == cid
        ]
        if len(matches) != 1:
            raise AssertionError(f"expected one MIME part for CID {cid}, found {len(matches)}")
        part = matches[0]
        if part.get_content_type() not in ("image/gif", "image/jpeg", "image/png"):
            raise AssertionError(f"CID {cid} has unsafe MIME type {part.get_content_type()}")
        if part.get_filename() is not None or part.get_param("name", header="content-type") is not None:
            raise AssertionError(f"CID {cid} unexpectedly exposes an attachment filename")
        actual_hash = hashlib.sha256(part.get_payload(decode=True) or b"").hexdigest().upper()
        if actual_hash != expected_hash.upper():
            raise AssertionError(f"CID {cid} SHA-256 mismatch: {actual_hash}")

    for specification in args.require_cid_png_dimensions:
        if "=" not in specification:
            raise AssertionError(f"invalid CID PNG dimension requirement: {specification}")
        cid, expected_dimensions = specification.split("=", 1)
        if "x" not in expected_dimensions.lower():
            raise AssertionError(
                f"invalid CID PNG dimensions: {expected_dimensions}; expected WIDTHxHEIGHT"
            )
        expected_width_text, expected_height_text = expected_dimensions.lower().split("x", 1)
        expected_width = int(expected_width_text)
        expected_height = int(expected_height_text)
        matches = [
            part
            for part in message.walk()
            if (part.get("Content-ID") or "").strip("<>") == cid
        ]
        if len(matches) != 1:
            raise AssertionError(f"expected one MIME part for CID {cid}, found {len(matches)}")
        part = matches[0]
        if part.get_content_type() != "image/png":
            raise AssertionError(f"CID {cid} has unsafe MIME type {part.get_content_type()}")
        if part.get_filename() is not None or part.get_param("name", header="content-type") is not None:
            raise AssertionError(f"CID {cid} unexpectedly exposes an attachment filename")
        payload = part.get_payload(decode=True) or b""
        if len(payload) < 24 or payload[:8] != b"\x89PNG\r\n\x1a\n" or payload[12:16] != b"IHDR":
            raise AssertionError(f"CID {cid} is not a valid PNG with an IHDR header")
        actual_width, actual_height = struct.unpack(">II", payload[16:24])
        if (actual_width, actual_height) != (expected_width, expected_height):
            raise AssertionError(
                f"CID {cid} PNG dimensions mismatch: {actual_width}x{actual_height}"
            )

    print("[PASS] Captured SMTP HTML advertises Apple-compatible schemes and preserves explicit dark fallbacks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
