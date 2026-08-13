# macOS Docker Desktop installation

[Open the macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/)

The macOS distribution runs the PowerShell newsletter engine in Docker Desktop
and provides Mac-native setup and preview helpers.

Current source baseline: **1.2.4**.

## Requirements

- An Intel or Apple silicon Mac.
- Docker Desktop with Docker Compose available in Terminal.
- Network access from Docker to Tautulli and an SMTP STARTTLS endpoint.
- Network access from Docker to Plex is recommended for complete movie RT
  critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and
  selected logos.
- A Tautulli API key.
- A permanent project directory writable by the current macOS user.

## Install

1. Download and extract
   [`TautWeekly-mac-docker.tar.gz`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.tar.gz)
   or the equivalent [ZIP archive](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.zip).
2. Open Terminal in the extracted directory.
3. Make the launchers executable and start the guided installer:

```bash
chmod +x INSTALL-MAC.command mac-install.sh tautweekly.sh mac-update.sh check-release.sh app/*.sh app/bin/*.sh
./mac-install.sh
```

Alternatively, double-click `INSTALL-MAC.command` after granting it execute
permission.

The installer detects the current UID/GID, creates a private `.env`, builds the
container, and runs interactive setup. It then pauses for the metadata-readiness
checklist below before verification. Existing `.env` and `data/config.json`
files are preserved unless you explicitly replace them.

## Service connectivity

For software running directly on the Mac, Docker Desktop exposes the host as
`host.docker.internal`:

```text
http://host.docker.internal:8181   # Tautulli
http://host.docker.internal:32400  # recommended direct Plex URL
```

For another server, use a resolvable hostname such as
`http://media.example.test:8181`. For a Tautulli container on the same
user-defined Docker network, use its service name.

Direct Plex is optional only for the core Tautulli activity flow. Enter its URL
and administrator token during setup for full newsletter fidelity. The URL must
work from Docker, not only from macOS. `verify` checks Plex `/identity` and
authenticated `/library/sections` with the token kept in a request header. A
resolved but unusable connection fails verification; if no URL/token pair can
be resolved, verification warns that selected/flattened Tautulli ratings and
other fallbacks will be used.
Verification proves reachability and authentication, not that every item has
every provider score. The renderer explicitly requests Plex's optional
`Rating` element so available movie RT pairs and exact-episode IMDb/RT values are not
hidden by a selected IMDb/TMDB fallback. If JSON lacks movie RT or
exact-episode provider entries, the renderer retries the same authenticated local
item as XML and reads only provider-labelled `Rating` elements.
For intended movie RT output, set every applicable Plex Movie library's
**Edit → Advanced → Ratings Source** to **Rotten Tomatoes**. This is a
library-wide Plex choice, not a TautWeekly setting; leave IMDb/TMDB selected if
that fallback is intentional.

## Metadata readiness before acceptance

After first setup, after changing a Plex metadata agent or Ratings Source, and
after a ratings/artwork recovery update when upstream data may be stale:

1. Confirm **Edit → Advanced → Ratings Source** in every included Plex Movie
   library.
2. Run Plex **Manage Library → Refresh All Metadata** for every included movie
   and TV library, then wait for all refreshes to finish.
3. In Tautulli, open each same **Library → Media Info** tab, select
   **Refresh media info**, and wait. The current control is per library, so
   repeat it for every included section.
4. Run `verify`, PreviewAll, and TestEmail only after both refresh stages
   complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

## Safe acceptance sequence

```bash
./tautweekly.sh verify
./tautweekly.sh list-libraries
./tautweekly.sh manage-libraries
./tautweekly.sh list-users
./tautweekly.sh exclude-users
./tautweekly.sh preview-all USER_ID
./tautweekly.sh open-preview
./tautweekly.sh send-test-all USER_ID
./tautweekly.sh schedule-status
```

Replace `USER_ID` with a numeric value printed by `list-users`. The roster is
informational and does not select or save a default user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Recreate or restart the container after changing `TZ`.

During preview review, confirm the supplied animated movie/TV icons,
up-to-four most-watched movie and TV-show rows, duration-only Total Watched
card, anonymous Binge Champion duration plus nonzero movie/TV-show counts, gold winner
treatment, and Trending hero fallback. The TV stats card is absent when no
show was watched; TV-only release weeks retain their TV cards below the hero.

Enable automation only after reviewing browser previews and TestEmail messages:

```bash
./tautweekly.sh schedule-enable
```

The macOS Compose default binds previews to `127.0.0.1`. Keep that default
unless trusted-LAN access is intentional.

Opening `http://localhost:8787/` shows a read-only preview landing page with
first-run commands. It is not an administration Web UI and does not expose
configuration or send controls. After `preview-all` completes, the generated
index is available at `http://localhost:8787/preview-all-00-INDEX.html`.

## Manage user exclusions

During primary setup, the wizard queries Tautulli and lets you select numbered
users or ranges such as `2,4-6`. Press Enter to keep the current selection or
type `none` to clear it. Run `./tautweekly.sh exclude-users` later to update
only the stable IDs in `ExcludedUserIds`; existing `ExcludedEmails` values are
left unchanged.

The selector merges the bulk `get_user_names` and `get_users` responses by
stable ID. It does not call `get_user` once per row, and users present only in
the name roster remain available for selection.

Excluded users are skipped by automatic delivery and SendAll. Preview and
TestEmail modes can still use them for safe rendering checks, and the one-off
welcome remains a separately confirmed administrator action. Do not share the
selector's names or email addresses publicly.

## Manage newsletter libraries

Primary setup discovers active movie and TV libraries through Tautulli and
saves selected section IDs in `IncludedLibraryIds`. This single scope filters
releases, quiet detection, Trending, Binge Champion, and personal statistics
before the normal calculations. Empty or absent IDs preserve legacy
all-library behavior.

Run `./tautweekly.sh list-libraries` to inspect the scope or
`./tautweekly.sh manage-libraries` to replace it. The manager accepts rows,
ranges, `all`, or Enter to keep the current choice; it backs up the private
config before writing and does not change SMTP, recipients, or scheduling.

## Data and updates

Private runtime data lives in `data/`. Back it up with
`./tautweekly.sh backup` and keep the archive private.

The future-deletion cache lives at `data/cache/deleted-items`, defaults to 365
days/1,000 items/256 MiB, and is preserved with the rest of `data/` during
updates. It can reuse only items observed live after v0.9.0; it cannot restore
assets Plex/Tautulli had already discarded. To purge it, stop the container and
remove only that directory. Delete all of `data/` during uninstall only when
configuration, state, output, cache entries, and backups are no longer needed.

`./tautweekly.sh check-update` compares `RELEASE-METADATA.txt` with GitHub's
latest stable release. It never applies an update and never follows `main` or
the container `edge` tag. macOS does not schedule unattended updates.

To apply a newer release, download the Mac archive and `SHA256SUMS.txt`, verify
the checksum, and extract the archive over the existing project folder without
deleting `.env` or `data/`. Then run:

```bash
./tautweekly.sh update
./tautweekly.sh verify
./tautweekly.sh preview-all USER_ID
./tautweekly.sh send-test-all USER_ID
```

The update command builds the verified package currently on disk; it no longer
pretends that refreshing the Docker base image installs a newer TautWeekly
release. It refuses a busy application operation, preserves `.env` and `data/`,
checks the running image version and container health, and automatically retags
and restarts the previous image if validation fails. Keep the prior verified
archive and private backup for file-level recovery.

If the update addresses missing ratings/artwork or output remains stale,
complete metadata readiness before the listed verify/preview/TestEmail checks.

Docker health uses a service-supervisor heartbeat that continues throughout
long scheduled sends. A stopped preview listener or stalled supervisor remains
unhealthy; missing decorative artwork produces a repair warning and can be
restored with `./tautweekly.sh repair-assets`.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
