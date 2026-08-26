# Bundled email assets

## Update and customization behavior

Starting with v0.21.4, Docker/Podman startup (NAS, Unraid, macOS, and FreeBSD)
and native Linux installation/service startup fingerprint the complete bundled email asset
set. A missing marker, including migration from an older installation, or a
changed bundle replaces **every shipped filename** in persistent `assets/`,
even if the existing file was customized. This includes the shipped PNGs as
well as GIFs. No old-file hash match is required.

The private `.tautweekly-asset-bundle` marker is written only after all copies
and the `output/assets/` browser-preview mirror succeed. A failed refresh stops
startup without advancing the marker, so a later startup retries. Copies are
atomic per file, not a whole-directory transaction. No directory is wiped.
Custom-only filenames, retired filenames, configuration, credentials, output,
logs, state, and fetched Plex/Tautulli artwork remain untouched.

Ordinary restarts with the same bundle preserve edits made since migration and
restore missing stock files. The preview mirror is synchronized with regular
files in `assets/` on startup. A maintenance release with identical bundled
asset bytes does not reset those edits. A rollback to different bundled bytes
is another transition. Explicit `repair-assets` restores all shipped filenames,
even when the marker is current. Keep backups of same-name custom artwork if
you want to reapply it after a transition.

Linked source/destination paths are refused rather than followed. The one
supported legacy `output/assets` directory symlink is unlinked and replaced
with a real directory without touching its target. Custom-only links and
subdirectories are preserved but not mirrored.

Native Linux also applies the transition during installation/upgrade, including
when the service stays stopped; the next service start sees the same marker.

Windows Setup and the verified packaged updater already replace shipped
filenames on installation/update, including customized stock assets, while
preserving custom-only filenames and private data. Their existing rollback
backup retains the replaced files. Windows previews use the updated `assets/`
directory directly; no startup reset or extra runtime dependency is added.

## v0.21.4 optimization

The release uses an explicitly approved exception to the future lossless
default: resize each original animation to **2x its largest rendered email
dimension**, then optimize the resized animation losslessly. Resizing itself
is not mathematically lossless. Manager picker and public-demo sizes do not
drive the resolution. Identical aliases share the larger email target, so
`watched.gif` remains identical to `genre-mystery.gif`; `trending.gif` remains
identical to `popcorn.gif`. The unused legacy `watchlist.gif` conservatively
retains capacity for a 42px email display.

All 32 GIFs remain animated: **1,809 frames**, unchanged per-frame delays and
loop behavior. No frame removal, frame-rate reduction, `--lossy` compression,
or reduced-color-budget pass is used. Lossless compression may rewrite frame
rectangles/disposal instructions, but `gifdiff` verifies every composited
frame, including transparency and the first-frame fallback, against the
resized reference. All 29 email PNGs (41,706 bytes), including both original
watched icons, remain byte-identical.

The 32 GIFs total **21,435,442 -> 2,704,515 bytes**, saving **18,730,927 bytes
(87.38%)** per bundled set. One retained synthetic SMTP fixture falls from
**10,133,029 -> 1,401,881 bytes (86.17%)**, including base64 overhead. Only its
10 matching GIF payloads were substituted; HTML and other attachments were
unchanged. This is a fixture comparison, not a guarantee for every email.
Attachment selection already includes only referenced CIDs.

The intended tradeoff is reduced source resolution, not different layout or
animation. These assets are sized for email, not enlargement back to 512px.
First-frame contact sheets and representative synthetic email previews were
inspected at 1280px and 390px with no missing images or horizontal overflow.
Classic Outlook remains structurally tested, not natively certified.

| Asset | Largest email px | Shipped px | Original bytes | Optimized bytes |
|---|---:|---:|---:|---:|
| `action.gif` | 18 | 36 | 354,520 | 33,868 |
| `alert.gif` | 18 | 36 | 806,747 | 23,213 |
| `celebrate.gif` | 18 | 36 | 395,755 | 18,333 |
| `clock.gif` | 42 | 84 | 216,499 | 39,978 |
| `construction.gif` | 18 | 36 | 187,082 | 5,552 |
| `genre-action.gif` | 42 | 84 | 413,941 | 56,118 |
| `genre-comedy.gif` | 42 | 84 | 609,521 | 86,885 |
| `genre-crime.gif` | 42 | 84 | 405,066 | 85,741 |
| `genre-drama.gif` | 42 | 84 | 533,686 | 105,624 |
| `genre-fantasy.gif` | 42 | 84 | 991,094 | 150,380 |
| `genre-horror.gif` | 42 | 84 | 1,996,707 | 170,127 |
| `genre-musical.gif` | 42 | 84 | 673,545 | 95,233 |
| `genre-mystery.gif` | 42 | 84 | 752,856 | 114,572 |
| `genre-romance.gif` | 42 | 84 | 149,343 | 46,117 |
| `genre-scifi.gif` | 42 | 84 | 1,040,478 | 162,752 |
| `genre-thriller.gif` | 42 | 84 | 1,521,173 | 139,189 |
| `genre-western.gif` | 42 | 84 | 650,226 | 91,546 |
| `hot.gif` | 42 | 84 | 475,239 | 64,517 |
| `lockinfo.gif` | 18 | 36 | 323,222 | 21,289 |
| `movies.gif` | 42 | 84 | 2,016,544 | 336,128 |
| `pending.gif` | 48 | 96 | 554,328 | 41,803 |
| `popcorn.gif` | 42 | 84 | 773,283 | 105,441 |
| `quiet.gif` | 48 | 96 | 465,013 | 107,471 |
| `rocket.gif` | 18 | 36 | 262,339 | 14,490 |
| `tickets.gif` | 18 | 36 | 403,389 | 18,420 |
| `trending.gif` | 42 | 84 | 773,283 | 105,441 |
| `trophy.gif` | 54 | 108 | 723,871 | 176,243 |
| `tv.gif` | 42 | 84 | 1,493,657 | 95,148 |
| `warning.gif` | 18 | 36 | 307,054 | 19,796 |
| `watched.gif` | 18 | 84 | 752,856 | 114,572 |
| `watchlist.gif` | 42 | 84 | 148,541 | 43,136 |
| `welcome.gif` | 18 | 36 | 264,584 | 15,392 |

## Development and verification

`AGENTS.md` requires automatic **lossless** optimization of new/changed local
assets before deployment, with decoded-pixel equivalence checks and measured
savings. Keep originals when a candidate is not smaller. Any resizing or other
lossy operation requires explicit authorization for that delivery.

The development-only generator uses [Gifsicle 1.95](https://www.lcdf.org/gifsicle/)
and its `gifdiff` verifier. The original inputs are pinned to commit
`9ff8f7253d2fba3b40abb76610adffd2386291ad`; no runtime installation downloads or
optimizes images. The Windows archive linked by the upstream site has SHA-256
`7e47dd0bfd5ee47f911464c57faeed89a8709a7625dd1c449b16579889539ee8`.
Flags, per-frame controls, source/output hashes, dimensions, and PNG hashes
are recorded in [the asset manifest](../assets/email-gifs.json).

```sh
# Reproduce the specifically authorized v0.21.4 resize.
python3 -B scripts/optimize-email-gifs.py --gifsicle /path/to/gifsicle \
  --gifdiff /path/to/gifdiff --output-dir /tmp/tautweekly-gifs \
  --resize-for-email --apply

# Without --resize-for-email, preserve original pixels and dimensions.
# Verify committed assets and Windows/NAS/macOS/Manager/Pages mirrors:
python3 -B scripts/optimize-email-gifs.py --check
python3 -B scripts/test-asset-refresh.py
```

Linux and FreeBSD packages derive their application assets and refresh helper
from the NAS source through the existing release builder. Release validation
checks all 32 GIF hashes in every archive. Existing Windows update and container
smoke tests also cover stock-file replacement and custom-only preservation.
The migration tests additionally cover the marker, restart/rollback transitions,
preview copies, path safety, hard links, and retry after a copy failure.
