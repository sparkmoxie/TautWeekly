#!/usr/bin/env python3
"""Assert that a captured SMTP message preserves the dark email contract."""

from __future__ import annotations

import argparse
from email import policy
from email.parser import BytesParser
from pathlib import Path


REQUIRED_HTML = (
    '<meta name="color-scheme" content="dark">',
    '<meta name="supported-color-schemes" content="dark">',
    ':root { color-scheme:dark only; supported-color-schemes:dark; }',
    '@media (prefers-color-scheme: dark)',
    'class="email-background"',
    'bgcolor="#0f0f0f"',
    'background-color:#0f0f0f',
    'class="email-card"',
    'bgcolor="#181818"',
    'background-color:#181818',
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("message", type=Path)
    parser.add_argument("--require-html", action="append", default=[])
    args = parser.parse_args()

    message = BytesParser(policy=policy.default).parsebytes(args.message.read_bytes())
    html_parts = [part for part in message.walk() if part.get_content_type() == "text/html"]
    plain_parts = [part for part in message.walk() if part.get_content_type() == "text/plain"]
    if len(html_parts) != 1:
        raise AssertionError(f"expected one HTML MIME part, found {len(html_parts)}")
    if len(plain_parts) != 1:
        raise AssertionError(f"expected one plain-text MIME part, found {len(plain_parts)}")

    html = html_parts[0].get_content()
    for marker in (*REQUIRED_HTML, *args.require_html):
        if marker not in html:
            raise AssertionError(f"delivered HTML lost dark-theme marker: {marker}")
    for shorthand in ("background:#0f0f0f", "background:#181818"):
        if shorthand in html:
            raise AssertionError(f"delivered HTML retained unsupported color shorthand: {shorthand}")

    print("[PASS] Captured SMTP HTML preserves dark-only metadata and explicit background fallbacks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
