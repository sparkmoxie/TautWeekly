# TautWeekly canonical raster brand assets

This durable repository bundle preserves the exact approved detailed popcorn
`TW` artwork. It supersedes every earlier simplified or vector redraw. Do not
redraw, trace, recolor, distort, or add a media/play glyph to the mark.

## Canonical sources

- `tautweekly-logo-source.png`: untouched opaque supplied source retained only as provenance; never use it as a runtime mark.
- `tautweekly-logo-transparent-source.png`: exact approved RGB artwork with only the surrounding/background pixels converted to alpha.
- `tautweekly-logo-master.png`: transparent, padding-normalized 1024-pixel production master.
- `tautweekly-app-icon-1024.png`: transparent application-icon master with additional small-size padding.

The untouched source SHA-256 is
`fa6c43f81768ea28ba3cae604a7e93d43cbdb783809e9c16fe68ef9016530ed4`.
The corrected transparent source SHA-256 is
`a224a283f643ceb72873aed286efed945758eb2a4288ef7c2c719cf4f51322ea`.
The transparent normalized logo master SHA-256 is
`aaba3471c907d776779038c1d9c4f5ab489aca53dc70aceba57de8f8d0dd2adc`.
The transparent padded app-icon master SHA-256 is
`35b77794f4648c2aa2fe0cd8637171ee3df4c96cd109e600fee832a7cfb649b9`.
`SHA256SUMS.txt` records the complete source and generated-asset evidence.

## Derivatives

- Logo PNGs: 128, 256, 512, and 1024 pixels.
- Padded transparent app-icon PNGs: 16, 32, 48, 64, 128, 180, 192, 256, 512, and 1024 pixels.
- `tautweekly.ico`: Windows application/shortcut icon with 16, 24, 32, 48, 64, 128, and 256 pixel entries.
- `favicon.ico`: compact browser favicon with 16, 24, and 32 pixel entries.
- SVG wrappers embed the corresponding 1024-pixel PNG exactly. They are intentionally not presented as vector tracings.

## Integration guidance

- Every production derivative has a transparent background; the consuming surface supplies its own background.
- Use `tautweekly-logo.svg` or the matching PNG for product branding and `tautweekly-app-icon.svg` or the matching padded PNG for application icons.
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
both source PNGs untouched. Alpha validation confirms zero-alpha corners,
transparent padding, antialiased partial-alpha edges, and visible opaque logo
pixels in the corrected source and production masters.

## Integration boundary

Use these assets only for global TautWeekly product/application identity.
Platform and package badges remain their own identities. The Windows ICO is
packaged for approved Setup, shortcut, executable, and uninstaller consumers,
but the current portable Windows distribution does not create those surfaces.
The separately maintained exact platform marks, provenance, native-color
rules, and single user-approved Apple color derivative are documented in
[`assets/platforms`](../platforms/README.md).
Generated newsletter content and its existing mail-state artwork remain out of
scope.
