#!/usr/bin/env python3
"""Rebuild the committed GIFs from immutable originals; never used at runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "assets/email-gifs.json"
SOURCE_REF = "9ff8f7253d2fba3b40abb76610adffd2386291ad"
ASSETS = ROOT / "platforms/windows/assets"
MIRRORS = [
    "platforms/nas-docker/app/assets-default",
    "platforms/mac-docker/app/assets-default",
    "manager/internal/manager/web/media",
    "docs/gui-preview/media",
    "docs/assets",
]
RESIZE_FLAGS = ["--unoptimize", "--resize-method=lanczos3", "--resize-colors=256",
                "--careful", "--no-comments", "--no-names", "-O0"]
OPTIMIZE_FLAGS = ["-O3", "-Okeep-empty", "--careful", "--no-comments", "--no-names"]
# Largest rendered EMAIL size across all maintained renderer variants.
DISPLAY = {
    "action.gif": (18, "Welcome feature icon"),
    "alert.gif": (18, "Custom email title"),
    "celebrate.gif": (18, "Custom email title"),
    "clock.gif": (42, "Personal watch-time footer"),
    "construction.gif": (18, "Custom email title"),
    "hot.gif": (42, "Hero: 42px desktop, 34px mobile"),
    "lockinfo.gif": (18, "Welcome privacy icon"),
    "movies.gif": (42, "Movie footer and neutral genre fallback"),
    "pending.gif": (48, "Warm-up footer"),
    "popcorn.gif": (42, "Hero and trending footer"),
    "quiet.gif": (48, "Quiet-week footer"),
    "rocket.gif": (18, "Custom email title"),
    "tickets.gif": (18, "Custom email title"),
    "trending.gif": (42, "Trending footer; identical to popcorn"),
    "trophy.gif": (54, "Winner footer: 54px; ordinary award: 42px"),
    "tv.gif": (42, "TV footer"),
    "warning.gif": (18, "Custom email title"),
    "watched.gif": (18, "Welcome readout; identical to genre-mystery"),
    "watchlist.gif": (42, "Retained alias: no current emitted use; reserve 42px"),
    "welcome.gif": (18, "Welcome heading"),
}
for genre in ("action", "comedy", "crime", "drama", "fantasy", "horror",
              "musical", "mystery", "romance", "scifi", "thriller", "western"):
    DISPLAY[f"genre-{genre}.gif"] = (
        42, "Genre footer",
    )


def sha(data):
    return hashlib.sha256(data).hexdigest()


def gif_info(data):
    """Read GIF control data without decoding or changing image pixels."""
    if data[:6] not in (b"GIF87a", b"GIF89a"):
        raise ValueError("Not a GIF")
    width, height, flags = struct.unpack_from("<HHB", data, 6)
    pos = 13 + (3 * (2 ** ((flags & 7) + 1)) if flags & 128 else 0)
    frames, loop, control = [], None, (0, 0, False)

    def blocks(offset):
        payload = bytearray()
        while data[offset]:
            size = data[offset]
            payload.extend(data[offset + 1:offset + 1 + size])
            offset += size + 1
        return offset + 1, bytes(payload)

    while pos < len(data):
        kind = data[pos]
        pos += 1
        if kind == 0x3B:
            return {"width": width, "height": height, "loop": loop, "frames": frames}
        if kind == 0x21:
            label = data[pos]
            pos, payload = blocks(pos + 1)
            if label == 0xF9:
                control = (struct.unpack_from("<H", payload, 1)[0],
                           (payload[0] >> 2) & 7, bool(payload[0] & 1))
            elif label == 0xFF and payload[:11] in (b"NETSCAPE2.0", b"ANIMEXTS1.0"):
                loop = struct.unpack_from("<H", payload, 12)[0]
        elif kind == 0x2C:
            left, top, fw, fh, packed = struct.unpack_from("<HHHHB", data, pos)
            if left + fw > width or top + fh > height:
                raise ValueError("GIF frame exceeds logical screen")
            pos += 9 + (3 * (2 ** ((packed & 7) + 1)) if packed & 128 else 0)
            pos, _ = blocks(pos + 1)  # LZW minimum code size, then subblocks
            frames.append({"delayCs": control[0], "disposal": control[1],
                           "transparent": control[2]})
            control = (0, 0, False)
        else:
            raise ValueError(f"Unexpected GIF block {kind:#x}")
    raise ValueError("Missing GIF trailer")


def check():
    manifest = json.loads(MANIFEST.read_text())
    expected = {item["name"]: item for item in manifest["assets"]}
    assert set(expected) == {p.name for p in ASSETS.glob("*.gif")}
    for name, item in expected.items():
        data = (ASSETS / name).read_bytes()
        assert sha(data) == item["sha256"], name
        assert len(data) == item["bytes"], name
        assert gif_info(data) == item["gif"], name
        assert item["gif"]["width"] >= 2 * item["maxDisplayPx"], name
        for directory in MIRRORS:
            path = ROOT / directory / name
            if path.exists():
                assert path.read_bytes() == data, str(path)
    for directory in MIRRORS[:2]:
        assert {p.name for p in (ROOT / directory).glob("*.gif")} == set(expected)
    # PNG artwork is input-only for this update, including both watched icons.
    for item in manifest["unchangedPngs"]:
        for directory in ["platforms/windows/assets", *MIRRORS[:2]]:
            assert sha((ROOT / directory / item["name"]).read_bytes()) == item["sha256"]
    print(f"[PASS] {len(expected)} GIFs: controls, dimensions, hashes, mirrors; 29 PNGs unchanged.")


def rebuild(executable, diff_executable, output, apply, resize_for_email):
    version = subprocess.check_output([executable, "--version"], text=True).splitlines()[0]
    if version != "LCDF Gifsicle 1.95":
        raise ValueError(f"Reproducibility requires LCDF Gifsicle 1.95, got {version}")
    originals = {}
    for name in DISPLAY:
        originals[name] = subprocess.check_output(
            ["git", "show", f"{SOURCE_REF}:platforms/windows/assets/{name}"], cwd=ROOT)
    # Identical original aliases share the largest target, not merely their own use.
    targets = {}
    for name, data in originals.items():
        targets[sha(data)] = max(targets.get(sha(data), 0), DISPLAY[name][0] * 2)
    output.mkdir(parents=True, exist_ok=True)
    records, cache = [], {}
    with tempfile.TemporaryDirectory(prefix="tautweekly-gif-source-") as temp:
        for name in sorted(originals):
            original = originals[name]
            digest, display = sha(original), DISPLAY[name]
            target = targets[digest] if resize_for_email else gif_info(original)["width"]
            if digest not in cache:
                source = Path(temp) / name
                dest = output / name
                source.write_bytes(original)
                reference = source
                if resize_for_email:
                    reference = Path(temp) / ("resized-" + name)
                    subprocess.run([executable, *RESIZE_FLAGS, f"--resize-fit={target}x{target}",
                                    "--output", str(reference), str(source)], check=True)
                best = original if not resize_for_email else reference.read_bytes()
                # Compare lossless encodings; never grow an already efficient original.
                strategies = [OPTIMIZE_FLAGS] if resize_for_email else [
                    [f"-O{level}", "-Okeep-empty", "--no-comments", "--no-names", *careful]
                    for level in (1, 2, 3) for careful in ([], ["--careful"])
                ]
                for flags in strategies:
                    subprocess.run([executable, *flags, "--output", str(dest),
                                    str(reference)], check=True)
                    candidate = dest.read_bytes()
                    if len(candidate) >= len(best):
                        continue
                    subprocess.run([diff_executable, str(reference), str(dest)], check=True)
                    candidate_info = gif_info(candidate)
                    reference_info = gif_info(reference.read_bytes())
                    assert len(candidate_info["frames"]) == len(reference_info["frames"]), name
                    assert [f["delayCs"] for f in candidate_info["frames"]] == [
                        f["delayCs"] for f in reference_info["frames"]], name
                    assert candidate_info["loop"] == reference_info["loop"], name
                    best = candidate
                cache[digest] = best
            optimized = cache[digest]
            (output / name).write_bytes(optimized)
            before, after = gif_info(original), gif_info(optimized)
            assert len(after["frames"]) == len(before["frames"]), name
            assert [f["delayCs"] for f in after["frames"]] == [
                f["delayCs"] for f in before["frames"]], name
            assert after["loop"] == before["loop"], name
            assert len(optimized) <= len(original), name
            records.append({
                "name": name, "maxDisplayPx": display[0], "usage": display[1],
                "sourceBytes": len(original), "sourceSha256": digest,
                "bytes": len(optimized), "sha256": sha(optimized), "gif": after,
            })
    pngs = [{"name": p.name, "sha256": sha(subprocess.check_output(
        ["git", "show", f"{SOURCE_REF}:platforms/windows/assets/{p.name}"], cwd=ROOT))}
        for p in sorted(ASSETS.glob("*.png"))]
    manifest = {"sourceRef": SOURCE_REF, "pixelPolicy": "authorized-email-resize" if resize_for_email else "identical-original", "tool": version, "resizeFlags": RESIZE_FLAGS, "optimizeFlags": OPTIMIZE_FLAGS,
                "assets": records, "unchangedPngs": pngs}
    import re
    encoded = json.dumps(manifest, indent=2)
    encoded = re.sub(r'\{\n\s+"delayCs": (\d+),\n\s+"disposal": (\d+),\n\s+"transparent": (true|false)\n\s+\}',
                     r'{"delayCs": \1, "disposal": \2, "transparent": \3}', encoded)
    (output / "email-gifs.json").write_text(encoded + "\n")
    if apply:
        for item in records:
            name = item["name"]
            shutil.copyfile(output / name, ASSETS / name)
            for directory in MIRRORS:
                dest = ROOT / directory / name
                if dest.exists():
                    shutil.copyfile(output / name, dest)
        shutil.copyfile(output / "email-gifs.json", MANIFEST)
        genre_manifest = ROOT / "assets/platforms/NEWSLETTER-ASSET-SHA256SUMS.txt"
        by_name = {item["name"]: item["sha256"] for item in records}
        lines = []
        for line in genre_manifest.read_text().splitlines():
            name = line.split("  ")[-1]
            lines.append(by_name[name] + "  " + name if name in by_name else line)
        genre_manifest.write_text("\n".join(lines) + "\n")
        check()
    before = sum(x["sourceBytes"] for x in records)
    after = sum(x["bytes"] for x in records)
    print(f"GIF bytes: {before:,} -> {after:,}; saved {100 * (1 - after / before):.2f}%")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--gifsicle")
    parser.add_argument("--gifdiff", help="Pixel-equivalence verifier shipped with Gifsicle")
    parser.add_argument("--resize-for-email", action="store_true",
                        help="Requires explicit user authorization: resize is NOT strictly lossless.")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.check:
        check()
    elif args.gifsicle and args.gifdiff and args.output_dir:
        rebuild(args.gifsicle, args.gifdiff, args.output_dir.resolve(), args.apply, args.resize_for_email)
    else:
        parser.error("Use --check, or --gifsicle PATH --gifdiff PATH --output-dir DIR [--apply]")
