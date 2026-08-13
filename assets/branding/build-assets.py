from __future__ import annotations

import base64
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "tautweekly-logo-source.png"
MASTER = ROOT / "tautweekly-logo-master.png"
APP_MASTER = ROOT / "tautweekly-app-icon-1024.png"
MARK_SIZES = (128, 256, 512, 1024)
APP_SIZES = (16, 32, 48, 64, 128, 180, 192, 256, 512, 1024)


def subject_bbox(image: Image.Image, threshold: int = 10) -> tuple[int, int, int, int]:
    rgb = image.convert("RGB")
    background = Image.new("RGB", rgb.size, (1, 1, 1))
    difference = ImageChops.difference(rgb, background).convert("L")
    mask = difference.point(lambda value: 255 if value > threshold else 0)
    bbox = mask.getbbox()
    if bbox is None:
        raise ValueError("Source contains no visible logo subject")
    return bbox


def contain(image: Image.Image, size: int, fill: tuple[int, int, int, int], margin: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), fill)
    maximum = size - (margin * 2)
    copy = image.copy()
    copy.thumbnail((maximum, maximum), Image.Resampling.LANCZOS)
    offset = ((size - copy.width) // 2, (size - copy.height) // 2)
    canvas.alpha_composite(copy, offset)
    return canvas


def save_png(image: Image.Image, destination: Path) -> None:
    image.save(destination, format="PNG", optimize=True, compress_level=9)


def write_embedded_svg(png_path: Path, svg_path: Path, title: str, description: str) -> None:
    payload = base64.b64encode(png_path.read_bytes()).decode("ascii")
    svg_path.write_text(
        f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">{title}</title>
  <desc id="desc">{description}</desc>
  <image width="1024" height="1024" href="data:image/png;base64,{payload}"/>
</svg>
''',
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    with Image.open(SOURCE) as opened:
        source = opened.convert("RGBA")

    bbox = subject_bbox(source)
    cropped = source.crop(bbox)

    # Preserve every interior pixel and only normalize the surrounding near-black field.
    master = contain(cropped, 1024, (1, 1, 1, 255), margin=58)
    save_png(master, MASTER)

    # The app tile uses the exact detailed mark on a rounded, near-black container.
    tile = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    tile_mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle((12, 12, 1011, 1011), radius=208, fill=255)
    # Match the supplied image's sampled edge color so no inner square is visible.
    tile_fill = Image.new("RGBA", tile.size, (1, 1, 1, 255))
    tile.alpha_composite(Image.composite(tile_fill, Image.new("RGBA", tile.size), tile_mask))
    tile_mark = contain(cropped, 1024, (0, 0, 0, 0), margin=74)
    tile.alpha_composite(tile_mark)
    save_png(tile, APP_MASTER)

    for size in MARK_SIZES:
        save_png(master.resize((size, size), Image.Resampling.LANCZOS), ROOT / f"tautweekly-logo-{size}.png")

    for size in APP_SIZES:
        save_png(tile.resize((size, size), Image.Resampling.LANCZOS), ROOT / f"tautweekly-app-icon-{size}.png")

    tile.save(
        ROOT / "tautweekly.ico",
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    tile.resize((32, 32), Image.Resampling.LANCZOS).save(
        ROOT / "favicon.ico",
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32)],
    )

    write_embedded_svg(
        MASTER,
        ROOT / "tautweekly-logo.svg",
        "TautWeekly popcorn TW logo",
        "The exact approved detailed raster logo embedded in an SVG container.",
    )
    write_embedded_svg(
        APP_MASTER,
        ROOT / "tautweekly-app-icon.svg",
        "TautWeekly app icon",
        "The exact approved detailed raster logo on a rounded near-black app tile.",
    )


if __name__ == "__main__":
    main()
