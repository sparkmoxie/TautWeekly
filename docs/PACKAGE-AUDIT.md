# Package audit — v0.27.1

Audit date: 2026-10-09. Baseline: v0.27.0 / `c200af1`.

This audit covers the maintained Windows, NAS/Docker, macOS Docker, native Linux,
and FreeBSD/Podman package surfaces, shared Manager, Windows installer, release
assembly, container contexts, update adapters, source-copy contracts, local
assets, privacy boundaries, and CI selection. It combines source/duplicate
inspection with the repository's automated checks; it is not a claim of an
exhaustive formal code proof or physical testing on every host.

## Findings addressed

| Finding | Resolution | Evidence |
|---|---|---|
| Identical Linux Manager targets were compiled once for Mac and again for native Linux | Compile amd64 and arm64 once per candidate and copy those exact outputs | Release artifact checks require matching SHA-256 values in both ZIP packages; reproducibility checks compare complete repeated builds |
| The source image's broad Manager allow rule included ignored local build/state directories | Add explicit final exclusions for Manager build output, private state, configuration, logs, output, and caches | Platform contracts require privacy exclusions; multiarchitecture image builds and boot checks verify required runtime inputs remain present |
| Release-builder paths selected too few consumer checks | Select every applicable validation gate for builder changes and renderer/installer gates for artifact contracts | Positive and negative classifier fixtures, with one stable required aggregate |
| Dashboard schedule and version evidence were inconvenient to inspect | Add observed next run, explicitly timestamped primary-recipient counts, and the shared Manager badge tooltip | Go policy/cache tests, JavaScript state tests, accessibility/parity checks, and desktop/mobile browser inspection |

## Intentional duplication retained

- The canonical NAS app payload is assembled into NAS, Mac fallback, Linux, and
  FreeBSD packages. Maintained source mirrors and package manifests verify that
  parity; platform wrappers preserve different installation/service behavior.
- Windows and container renderers include platform-specific runtime setup. This
  release does not merge them or alter production newsletter delivery.
- GIF aliases and platform asset copies are consumed by established templates,
  manifests, offline packages, and preview mirrors. Byte-identical files are not
  automatically redundant. No artwork, dimensions, animation frames, timing,
  palettes, or integrity hashes were changed.
- Legacy Mac build adapters and the transitional Mac Compose asset remain
  compatibility inputs. Only the unified image receives new release tags.
- Runtime and Manager are packaged together; package version metadata is separate
  from the independently maintained platform source-baseline VERSION.txt files.

## Dependency, privacy, and performance review

Manager and installer declare no third-party Go module dependencies. Native
binaries use the existing trimmed, stripped, CGO-disabled build settings. The
multi-stage image keeps the Go compiler outside the production image, removes
apt indexes and downloaded PowerShell archives, and verifies PowerShell archive
checksums. No dependency upgrades or speculative runtime rewrites were needed.

Recipient aggregation reuses the explicit Tautulli lookup already performed by
Manager. It adds no page-load, hover, or polling network requests. Only an integer
aggregate is retained: native addresses, fallback maps, and BCC addresses are not
added to discovery evidence. Missing, bounded, fallback, or revision-invalidated
evidence remains unknown. A successful saved-configuration rebase clears the
count, and delivery still applies its own live policy checks.

## Validation and release gates

Local checks cover Manager Go tests/vet, recipient filtering/cache invalidation,
header and update-state regressions, GUI parity/accessibility, repository
privacy, all-platform contracts, classifier fixtures, and documentation links.
Browser QA uses fictional data at desktop and mobile widths across all five
package profiles, including badge hover, keyboard focus, and navigation.

The required PR matrix validates PowerShell runtime, active/quiet rendering,
recipient/privacy integration, Manager target builds, release archives and
reproducibility, Windows installer lifecycle, Compose, and amd64/arm64 container
behavior. Tagged publication repeats the required final-artifact and installer
checks, builds/boots/publishes the unified image, and publishes release assets.
Final release verification checks anonymous artifact hashes, manifest platforms,
release version, and deployed documentation. The corresponding Actions runs and
published release are the authority for their completion state.

No live Plex/Tautulli account, SMTP recipient, physical NAS/Mac/FreeBSD machine,
or email-client compatibility test is asserted. Native host differences remain
covered by package contracts, fixtures, cross-builds, Linux runners, and QEMU
where applicable.
