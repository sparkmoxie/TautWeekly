#!/usr/bin/env python3
"""Strip non-rendering JPEG metadata without recompressing image data."""

from __future__ import annotations

import argparse
import io
import json
from pathlib import Path


SOI = b"\xff\xd8"
SOS = 0xDA
STANDALONE_MARKERS = {0x01, *range(0xD0, 0xDA)}
PRESERVED_APP_MARKERS = {0xE0, 0xE2, 0xEE}  # JFIF, ICC, and Adobe color transform.
FORBIDDEN_METADATA_SIGNATURES = (
    b"Exif\x00\x00",
    b"Photoshop 3.0\x00",
    b"http://ns.adobe.com/xap/1.0/\x00",
)


def stripped_jpeg(source: bytes) -> bytes:
    if not source.startswith(SOI):
        raise ValueError("input is not a JPEG")

    output = bytearray(SOI)
    offset = len(SOI)
    found_scan = False
    while offset < len(source):
        marker_start = offset
        if source[offset] != 0xFF:
            raise ValueError(f"invalid JPEG marker at byte {offset}")
        while offset < len(source) and source[offset] == 0xFF:
            offset += 1
        if offset >= len(source):
            raise ValueError("truncated JPEG marker")
        marker = source[offset]
        offset += 1

        if marker == 0xD9:
            output.extend(source[marker_start:offset])
            break
        if marker in STANDALONE_MARKERS:
            output.extend(source[marker_start:offset])
            continue
        if offset + 2 > len(source):
            raise ValueError("truncated JPEG segment length")
        segment_length = int.from_bytes(source[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(source):
            raise ValueError("invalid JPEG segment length")
        segment_end = offset + segment_length

        if marker == SOS:
            output.extend(source[marker_start:])
            found_scan = True
            break

        is_app_marker = 0xE0 <= marker <= 0xEF
        if not is_app_marker or marker in PRESERVED_APP_MARKERS:
            output.extend(source[marker_start:segment_end])
        offset = segment_end

    if not found_scan:
        raise ValueError("JPEG has no image scan")
    candidate = bytes(output)
    if not candidate.endswith(b"\xff\xd9"):
        raise ValueError("JPEG image scan is truncated")
    for signature in FORBIDDEN_METADATA_SIGNATURES:
        if signature in candidate:
            raise ValueError(f"metadata signature was not removed: {signature!r}")
    return candidate


def verify_decoded_pixels(source: bytes, candidate: bytes) -> tuple[str, tuple[int, int]]:
    try:
        from PIL import Image
    except ImportError as error:  # pragma: no cover - depends on the development runtime
        raise RuntimeError("Pillow is required for --verify-pixels") from error

    with Image.open(io.BytesIO(source)) as original_image:
        original_image.load()
        original_mode = original_image.mode
        original_size = original_image.size
        original_pixels = original_image.tobytes()
    with Image.open(io.BytesIO(candidate)) as candidate_image:
        candidate_image.load()
        if candidate_image.mode != original_mode or candidate_image.size != original_size:
            raise ValueError("decoded image mode or dimensions changed")
        if candidate_image.tobytes() != original_pixels:
            raise ValueError("decoded JPEG pixels changed")
    return original_mode, original_size


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--verify-pixels", action="store_true")
    args = parser.parse_args()

    source = args.source.read_bytes()
    candidate = stripped_jpeg(source)
    if len(candidate) >= len(source):
        raise ValueError("lossless metadata stripping did not make the JPEG smaller")

    mode = None
    dimensions = None
    if args.verify_pixels:
        mode, dimensions = verify_decoded_pixels(source, candidate)

    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_bytes(candidate)
    print(
        json.dumps(
            {
                "sourceBytes": len(source),
                "optimizedBytes": len(candidate),
                "savedBytes": len(source) - len(candidate),
                "mode": mode,
                "dimensions": dimensions,
                "pixelsIdentical": bool(args.verify_pixels),
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
