# TautWeekly canonical raster brand assets

This durable repository bundle preserves the exact approved detailed popcorn
`TW` artwork. It supersedes every earlier simplified or vector redraw. Do not
redraw, trace, recolor, distort, or add a media/play glyph to the mark.

## Canonical sources

- `tautweekly-logo-source.png`: untouched supplied source image.
- `tautweekly-logo-master.png`: padding-normalized 1024-pixel production master on the original near-black field.
- `tautweekly-app-icon-1024.png`: exact artwork placed on a rounded near-black application tile.

The untouched source SHA-256 is
`fa6c43f81768ea28ba3cae604a7e93d43cbdb783809e9c16fe68ef9016530ed4`.
The normalized logo master SHA-256 is
`fada7196c5f6fa9283bf3e5fe0a928a22360e152320e9139e1f3c6cd4b27688d`.
The app-tile master SHA-256 is
`ee29569539c627c5df78e55c70eaf3b11667f41f2981bc1ee5bb6eaa3c1c6ceb`.
`SHA256SUMS.txt` records the complete source and generated-asset evidence.

## Derivatives

- Logo PNGs: 128, 256, 512, and 1024 pixels.
- App-tile PNGs: 16, 32, 48, 64, 128, 180, 192, 256, 512, and 1024 pixels.
- `tautweekly.ico`: Windows application/shortcut icon with 16, 24, 32, 48, 64, 128, and 256 pixel entries.
- `favicon.ico`: compact browser favicon with 16, 24, and 32 pixel entries.
- SVG wrappers embed the corresponding 1024-pixel PNG exactly. They are intentionally not presented as vector tracings.

## Integration guidance

- Use `tautweekly-app-icon.svg` or the matching PNG for documentation/site surfaces with uncontrolled backgrounds.
- Use `tautweekly.ico` for Windows executables and shortcuts.
- Use `favicon.ico`, plus 180/192/512 PNGs where HTML manifests request them.
- Do not independently redraw, recolor, distort, or add a media/play glyph.
- Do not place the brand mark inside generated newsletters unless separately approved.
- Regenerate derivatives with `build-assets.py`; edit neither derived PNGs nor embedded SVG payloads manually.

## Reproduction

Use Python 3.12 with the pinned Pillow version, then confirm the hashes:

```console
python -m pip install -r requirements.txt
python build-assets.py
```

The approved handoff was regenerated with Python 3.12.13 and Pillow 12.3.0;
all 19 generated files were byte-identical. The script intentionally leaves
`tautweekly-logo-source.png` untouched.

## Integration boundary

Use these assets only for global TautWeekly product/application identity.
Platform and package badges remain their own identities. The Windows ICO is
packaged for approved Setup, shortcut, executable, and uninstaller consumers,
but the current portable Windows distribution does not create those surfaces.
Generated newsletter content and its existing mail-state artwork remain out of
scope.
