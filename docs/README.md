# TautWeekly for Plex documentation

The [TautWeekly Quickstart](https://sparkmoxie.github.io/TautWeekly/)
preserves the supplied Plex-inspired dark Quickstart experience, including
search, sticky navigation, scroll progress, responsive layouts, copy controls,
and terminal demonstrations.

## GUI Preview

- [Open the interactive GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/)

The static demonstration mirrors the Manager interface with a synthetic
in-memory API and fictional private/account activity. Its production-faithful
newsletter frames bundle public media artwork and dated Rotten Tomatoes/IMDb
score snapshots locally. It makes no outbound application or host-service
requests, writes no files, stores no credentials or entered values, and resets
every temporary change when the page reloads.

## Email States Preview

- [Open the rendered Email States Preview](https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html)

The single-file gallery renders nine newsletter lifecycle and density states,
including high usage, both Binge Champion treatments, onboarding, warmup,
quiet weeks, and a TV-only release week with the production Trending fallback. Demo counts are
synthetic; real public Plex Discover artwork and dated Rotten Tomatoes movie
and IMDb episode scores are used only to make the visual regression fixture
representative. TV cards preserve the production episode-row and IMDb-badge
formatting. No Plex token or private server data is embedded.

## Interactive Quickstart Guides

- [TautWeekly Quickstart](https://sparkmoxie.github.io/TautWeekly/)
- [Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/)
- [NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
- [macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/)
- [Native Linux Quickstart](https://sparkmoxie.github.io/TautWeekly/linux/)
- [FreeBSD Podman Quickstart](https://sparkmoxie.github.io/TautWeekly/freebsd/)

Across these packages, Manager **Settings > Updates** is the primary source for
application, package/image, host-adapter, stable-release, and check status.
Only Windows can start its existing verified updater from the GUI; every other
guide names the exact host-owned command or platform-native flow and its
limitations.

## Documentation

- [Windows installation](windows/README.md)
- [NAS / Docker installation](nas-docker/README.md)
- [macOS installation](mac/README.md)
- [Native Linux installation](linux/README.md)
- [FreeBSD Podman installation](freebsd/README.md)
- [Configuration reference](CONFIGURATION.md)
- [Security and hardening](SECURITY.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Release process](RELEASING.md)

Before first-run acceptance—or after a metadata-recovery update when ratings or
artwork may still be stale—follow the repository's
[Plex/Tautulli metadata-readiness sequence](CONFIGURATION.md#metadata-readiness-before-acceptance)
before verification, PreviewAll, or TestEmail. It is scoped to the movie/TV
libraries included in TautWeekly, not unrelated Plex libraries.

The `.html` files in the platform directories are self-contained Pages
Quickstarts. The Pages workflow deploys from the repository's default `main`
branch. The Markdown files are the canonical source-oriented guides for reading
directly on GitHub.
