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
quiet weeks, a TV-only Trending week, complementary Trending/Top Genre footers,
and the dynamic inbox-preview/count lines. Demo counts are
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

Every Quickstart follows the same GUI-first path: install the package, open and
pair the Manager where required, complete **Config**, run the non-sending
verification, review all six **Previews**, send only to **TestEmail**, and then
opt into **Schedule**. Config can add an optional custom text card before the
release-count/date block; its body is required whenever the card is enabled,
and its uppercase title can append one of six packaged local GIFs.
The [configuration reference](CONFIGURATION.md#optional-custom-text-card) and
each platform README document the complete options. Commands in the guides are
reserved for installation, bootstrap, expert operation, or recovery.

Across these packages, Manager **Settings > Updates** is the primary source for
application, package/image, host-adapter, stable-release, and check status.
Successful results are reused for five minutes, and the normal background
freshness window remains 24 hours. **Current** keeps its green status glow;
every non-current status gives the capability-aware update card an attention
glow. The purple header SVG appears only after a successful check validates a
newer running-application release.
Only Windows can start its existing verified updater from the GUI; every other
guide names the exact host-owned command or platform-native flow and its
limitations.

Every maintained package also exposes an optional **Settings > Tailscale**
private-access card. Windows and native Linux have narrow, package-owned
adapters; macOS, FreeBSD, QNAP, Unraid, and other Docker/NAS packages accept
only a separately created exact private Serve hostname. TautWeekly never
enables Funnel or treats tailnet membership as a replacement for the Manager
login. Optional mobile access requires the Tailscale app signed in on the phone
or tablet before opening the private address. An active card uses a motion-safe
full-card glow so the additional remote administration boundary remains visible.

## Documentation

- [Windows installation](windows/README.md)
- [NAS / Docker installation](nas-docker/README.md)
- [macOS registry-first installation and archive fallback](mac/README.md)
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
