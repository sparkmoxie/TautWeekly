# Platform identity assets

These assets identify a referenced operating system, runtime, NAS vendor, or
package ecosystem. They are category 2 platform/package identity and do not
replace the category 1 TautWeekly product artwork in `assets/branding/`.

The documentation displays these marks only beside the platform name or on a
platform-specific surface. The adjacent text supplies the accessible name, so
the repeated image is decorative (`alt=""`). Aspect ratios are preserved and
CSS does not recolor, crop, stretch, rotate, or filter the vendor artwork.

## Provenance

Assets were retrieved and verified on 2026-08-12. `ASSET-SHA256SUMS.txt`
records the durable documentation-asset hashes. `NEWSLETTER-ASSET-SHA256SUMS.txt`
records both the 42x42 white newsletter glyph derivatives and the approved
512x512 animated Top Genre artwork. The genre GIFs are stored byte-for-byte as
validated release inputs, and every package verifies their hashes, dimensions,
and animation before publication. Unknown or unavailable genre artwork uses the
existing neutral `movies.gif` asset, so generated mail never references a broken
image.

| Asset | Canonical input | Treatment |
| --- | --- | --- |
| `windows.svg` | User-approved [Windows 11 logo SVG](https://upload.wikimedia.org/wikipedia/commons/e/e6/Windows_11_logo.svg), SHA-256 `e8a33c4612b2ade22550b61e4c426e9d10a5bdf325b7b17f220e7363bed89dd2` | Exact supplied blue Windows 11 logo; no modification. |
| `apple-black-source.svg` | User-approved [black Apple logo SVG](https://upload.wikimedia.org/wikipedia/commons/f/fa/Apple_logo_black.svg), SHA-256 `9d00ea77a3240f291356c36261c5f45d7fa456f29c97a2f060caf0ed4b9c3231` | Untouched provenance; not used directly by the site. |
| `apple.svg` | `apple-black-source.svg` | User-requested display derivative. Exact path geometry is retained and the sole change is TautWeekly gold `#e5a00d`. This is the explicit exception to native platform colors. |
| `docker.svg` | Docker's [official logo kit](https://www.docker.com/company/newsroom/media-resources/), `docker-logos/SVG/docker-mark-ocean-blue.svg`; kit SHA-256 `590790ecdaaa577e55ce3dcad3a6c67a04ca7f8cc53a4a2fa21ac69d6767d476` | Exact current Ocean Blue secondary symbol. |
| `qnap.png` | QNAP's [official standard-color PNG](https://marketing.qnap.com/wp-content/uploads/2021/06/QNAP_LOGO_%E6%A8%99%E6%BA%96%E8%89%B2.png) from its [logo resource page](https://marketing.qnap.com/resource/qnap-logo-standard/) | Exact blue/red transparent wordmark. |
| `unraid.svg` | Current `unraid-logo` symbol on the [official Unraid site](https://unraid.net/) | Exact current wordmark path and native `#E22828` to `#FF8C2F` gradient, wrapped only with SVG metadata and a title. |
| `linux-tux.png` | Kernel.org's [Tux PNG](https://www.kernel.org/theme/images/logos/tux.png) | Exact full-color transparent raster. Tux was created by Larry Ewing; use is acknowledged with the requested credit. |
| `freebsd.png` | FreeBSD Foundation's [official logo archive](https://freebsdfoundation.org/wp-content/uploads/2024/10/FreeBSDLogoArchive-2.zip), archive SHA-256 `4f9fd15889dc96dab37a5cbc4cc9a8d48236512f6a99dbebc9228be9dc69ba4c` | Exact full-color reverse horizontal RGB PNG for the dark documentation background. |

The copied marks remain the property and trademarks of their respective
owners. Their presence describes compatibility; it does not imply sponsorship
or endorsement.

## Usage boundary

- Keep the TautWeekly app icon in global site/package headers.
- Use these assets only where the named platform or package is the subject.
- Keep the product icon on QNAP/Unraid package listings because those listings
  identify the TautWeekly app, not the host platform.
- Use the locally bundled client-platform glyphs in generated newsletters only beside the weekly heading, when the selected recipient's report-window activity resolves to a recognized platform or that exact recipient's Tautulli Last Platform provides a recognized fallback.
- Preserve each source's aspect ratio and documented clear space. Docker's
  mark must render at least 24 CSS pixels; the Windows logo renders above the
  15.5-pixel minimum in the supplied Microsoft guidance.
