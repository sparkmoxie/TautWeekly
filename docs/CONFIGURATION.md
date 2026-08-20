# Configuration reference

TautWeekly for Plex writes live settings to `config.json`. Docker editions keep
it under `data/`; Windows keeps it beside the application; native Linux uses
`/var/lib/tautweekly`; and FreeBSD uses `/var/db/tautweekly`. Start from the
platform's `config.example.json` only for recovery or an expert manual setup.
Manager **Config** is the setup source on Windows, NAS/Docker, macOS Docker
Desktop, native Linux, and FreeBSD Podman. Terminal setup scripts remain
expert/recovery fallbacks on those packages.

Manager **Config > Configuration backups** lists private backup metadata, can
validate/restore one selected backup while first saving the current config, and
can permanently delete one selected backup only after **Confirm delete**.
Deletion leaves the live `config.json` unchanged and cannot be undone.

## Tautulli and Plex

| Key | Required | Purpose |
|---|---:|---|
| `TautulliUrl` | Yes | Base URL reachable from the TautWeekly for Plex runtime, such as `http://media.example.test:8181` |
| `ApiKey` | Yes | Tautulli API key; treat as a secret |
| `PlexWebUrl` | Yes | Destination for the newsletter button; defaults to the Plex web app and may point to a custom service such as Seer |
| `PlexButtonLabel` | No | Newsletter button text; missing or blank values safely default to `Open Plex` |
| `PlexServerUrl` | No; recommended | Direct Plex base URL reachable from the TautWeekly runtime for the complete alternate rating set, exact-episode metadata, backgrounds, and selected logos; a separate container must not use its own localhost |
| `PlexToken` | No; recommended | Administrator/server Plex token for direct Plex access and exact-GUID deleted-item recovery; treat as a secret |

TautWeekly for Plex's core activity flow uses Tautulli. Direct Plex access is
optional for that core flow but recommended for full newsletter fidelity.
Tautulli may expose only its currently selected/flattened rating, while direct
Plex lets TautWeekly inspect alternate movie RT critic/audience ratings, the
exact episode's IMDb rating, backgrounds, and selected logos. When Plex has
deleted an item but Tautulli still retains its history GUID, TautWeekly can use
`PlexToken` to ask `https://metadata.provider.plex.tv` for that exact
identifier. This v0.8.3 compatibility path is best-effort, not durable storage:
the provider may return no record or asset after Plex has discarded the library
item. If a response omits provider scores, TautWeekly can use its exact returned
slug to read provider-labelled ratings on `https://watch.plex.tv`; that public
request receives no Plex token. Neither path searches by title or sends
recipient identity or watch-history values. An absolute artwork URL on another
host is also fetched without the Plex token.

Manager Config (or the platform's documented terminal fallback) stores the
private URL/token in `config.json`; container networking is a separate runtime
boundary. The URL must work from the TautWeekly process, not merely from a
desktop browser or the Tautulli container. **Validate, save, and verify** uses
the same discovery path as newsletter generation, sends the token only in the
`X-Plex-Token` header, and tests `/identity` plus authenticated
`/library/sections`. A resolved but unreachable or unauthorized connection is
a verification failure. If no URL/token pair can be resolved, verification
warns and preserves the supported Tautulli-only fallback.

An older configuration may legitimately contain neither direct-Plex key. A
guided migration preserves that file, identifies the omission, and adds the
current fields only after an explicit validated save. It never invents or
returns a Plex token. The Windows runtime may use `PlexOnlineToken` from the
current account's local Plex Media Server installation without copying it into
`config.json`; container/native runtimes may use an explicitly supplied
`PLEX_TOKEN` environment secret. The Manager reports only that a runtime token
is available. It never returns that value to the browser or writes it into a
configuration during normalization. A separately hosted Plex server still
requires a runtime-reachable `PlexServerUrl` and an explicitly supplied token.

### Metadata readiness before acceptance

Connection verification cannot prove that Plex or Tautulli holds current item
metadata. After first setup, after changing a Plex metadata agent or movie
Ratings Source, and after a ratings/artwork recovery update when upstream data
may be stale, complete these steps before PreviewAll or TestEmail:

1. Confirm **Edit → Advanced → Ratings Source** for every included Plex Movie
   library.
2. Run Plex **Manage Library → Refresh All Metadata** for every included movie
   and TV library, and wait for all refreshes to finish.
3. In Tautulli, open each same **Library → Media Info** tab, choose
   **Refresh media info**, and wait. The control is per library; repeat it for
   every included section.
4. In Manager, open **Verify**, generate PreviewAll, and send a controlled
   TestEmail. Use the documented terminal verifier only as a recovery fallback.

Plex documents that a full refresh can take significant time and can update
existing metadata and artwork. Scope it to TautWeekly's included movie/TV
libraries. Tautulli's media-info refresh updates its library table after Plex;
it neither changes the Plex Ratings Source nor replaces Plex's metadata
refresh. Routine TautWeekly updates do not require this full sequence when
current output is already correct.

Posters and hero art can still succeed through Tautulli's image proxy when the
direct Plex URL is unreachable. That does not prove that direct rating,
background, or selected-logo metadata is available. v0.9.5 uses Tautulli's
normal metadata and single-item JSON exporter for provider-labelled ratings;
it requests only metadata level 1, disables media information, and does not
request library/user individual files. Movie Rotten Tomatoes remains preferred
even when flattened metadata selects IMDb; a labelled movie IMDb score is the
final fallback only when no RT value exists. TV release rows prefer IMDb for
the exact episode, then use that exact episode's RT critic or audience value
when IMDb is absent. They do not substitute a selected show, movie, TMDB, or
TVDB score. Both rating field pairs are still parsed because Tautulli can place its
selected provider in either pair. Provider-free numbers, unknown provider
identifiers, out-of-range scores, and unavailable logo resources remain
omitted rather than guessed.

The [Tautulli `get_history` API](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_history)
retains descriptive fields such as GUID/rating keys, titles, years, episode
indexes, and play fields. Artwork fields are references, not durable image
bytes. Tautulli's [Exporter Guide](https://docs.tautulli.com/using-tautulli/exporter-guide)
likewise treats exported image resources as a separate explicit export. Once
Plex and Tautulli no longer have the asset, TautWeekly cannot reliably recover
it retroactively.

## Persistent deleted-item cache

| Key | Default | Accepted range | Purpose |
|---|---:|---:|---|
| `DeletedItemCacheEnabled` | `true` | Boolean | Enables capture and exact-ID fallback reads |
| `DeletedItemCacheRetentionDays` | `365` | 1-3650 | Expires entries by their last live observation |
| `DeletedItemCacheMaxItems` | `1000` | 1-10000 | Maximum retained entries before oldest-first eviction |
| `DeletedItemCacheMaxBytesMB` | `256` | 16-2048 | Total ceiling for artwork plus primary/backup manifests, with bounded overhead for atomic operations |

The schema-versioned cache records only the exact stable GUID and media type,
title, year, bounded summary, up to eight genres, newsletter rating values,
one poster with byte count and SHA-256 hash, and creation/last-seen timestamps.
It does not record playback metrics, recipient identity, generated newsletter
content, API keys, SMTP settings, or the Plex token. The token is never passed
to the cache and is never forwarded to an external poster host.

Entries are created only when live local metadata and a non-generic poster are
available. Later lookups require the same normalized stable GUID and media
type. Rating keys and titles are not fallback identities, so already-deleted
history with a missing or ambiguous identifier fails closed.

Cleanup runs at initialization and after writes. Expired entries are removed,
then the newest entries are retained deterministically until the item and total
byte limits are satisfied. `index.json` is replaced atomically on the same
volume and `index.backup.json` holds the previous valid generation. A corrupt
primary recovers from that backup; if neither generation is valid, one corrupt
copy is retained when practical and the cache starts empty. Poster hash failures
remove the damaged entry and rendering continues without it.

Existing configurations migrate safely because missing keys use the defaults
without rewriting `config.json`; setup preserves explicit values on
replacement. Windows stores the cache beside the application at
`cache/deleted-items`. Docker/macOS uses `/data/cache/deleted-items`, native
Linux uses `/var/lib/tautweekly/cache/deleted-items`, and FreeBSD uses
`/var/db/tautweekly/cache/deleted-items`.

Set `DeletedItemCacheEnabled` to `false` to stop reads and writes without
deleting data. To purge, stop TautWeekly and remove only the
`cache/deleted-items` directory under the applicable private data root. Backups
that include the cache must remain private. A full uninstall can remove the
entire private data root only after configuration, state, output, cache entries,
and backups are no longer needed.

## Optional custom text card

| Key | Default | Accepted range | Purpose |
|---|---:|---:|---|
| `CustomTextCardEnabled` | `false` | Boolean | Places the custom card before the newsletter title/date block |
| `CustomTextCardBorderColor` | `#72aef7` | Six-digit hex color | Selects the optional card-border color |
| `CustomTextCardBorderOpacity` | `34` | 0-100 | Sets border opacity; 0 removes the visible border |
| `CustomTextCardTitle` | empty | 0-120 characters | Optional gold uppercase label at the Welcome Aboard title size |
| `CustomTextCardSubheading` | empty | 0-200 characters | Optional large white heading |
| `CustomTextCardBody` | empty | 1-2000 characters when enabled | Required plain-text body when the card is enabled |

The Manager balances the card layout when either optional heading is omitted.
Line breaks are preserved, and every configured value is HTML-escaped before
rendering. Enabling the card with an empty or whitespace-only body blocks
validation, save, and verification. Existing configurations remain disabled
by default and do not need to add these keys.

## Branding and mail

| Key | Purpose |
|---|---|
| `ServerLabel` | Compact label used in newsletter identity |
| `FooterServerName` | Human-readable server name in the footer |
| `FromName` | Display name for outgoing mail |
| `FromEmail` | SMTP envelope/message sender allowed by the provider |
| `ReplyToEmail` | Reply destination |
| `SmtpHost`, `SmtpPort` | STARTTLS SMTP endpoint; port 587 is the usual default |
| `SmtpEnableSsl` | Enables TLS negotiation |
| `SmtpUseAuthentication` | Whether SMTP credentials are sent |
| `SmtpUsername`, `SmtpPassword` | Provider credential; the password is stored as plain text |
| `SmtpStripPasswordSpaces` | Optional normalization for providers that display grouped app passwords |
| `SmtpAuthenticationMethod` | `Auto` prefers challenge-style `LOGIN`, then `PLAIN`; set an explicit supported method only when required by the provider |
| `SmtpTimeoutSeconds` | Connection and protocol timeout; defaults to 30 seconds |
| `TestEmail` | Controlled recipient for all test modes |

Implicit SMTPS on port 465 is not the supported transport. Use a provider's
STARTTLS settings. The SMTP transport completes authentication and requires a
successful `235` response before it sends `MAIL FROM`. The platform verifier
checks TCP reachability and configuration shape only; run a controlled
`SendTest` with a numeric `USER_ID` to validate credentials and sender
authorization.

## Content and eligibility

| Key | Default | Purpose |
|---|---:|---|
| `DaysBack` | 7 | Activity and recently-added window |
| `WatchedPercent` | 85 | Completion threshold |
| `MinimumEpisodeSeconds` | 120 | Filters very short playback |
| `MaxMovies`, `MaxTv` | 8 | Content-card limits |
| `IncludedLibraryIds` | `[]` | Stable Tautulli section IDs defining the global newsletter scope; empty means all active movie/TV libraries for backward compatibility |
| `ExcludedUserIds` | `[]` | Users omitted by stable Tautulli ID |
| `ExcludedEmails` | `[]` | Email addresses omitted from delivery |
| `RecentAccessDays` | 7 | New/recent access classification |
| `SendDelaySeconds` | 10 | Pause between real production recipients |
| `TestSendDelaySeconds` | 2 | Pause between controlled test messages |

### Global library selection

Manager Config calls `get_libraries` after the Tautulli URL and API key are
entered and presents active movie and TV libraries for selection. The terminal
fallback accepts rows or ranges such as `1,3-4`, `all`, or Enter to keep the
displayed scope. At least one active movie or TV library is required for a
newly saved selection.

`IncludedLibraryIds` is applied to raw Tautulli history and recently-added
rows before any newsletter calculations. New/latest releases, quiet detection,
Trending, the hero, Binge Champion, and each user's personal totals therefore
share the selected scope. Per-user Plex sharing rules are not queried or
intersected; this is a single administrator-controlled scope.

Normally revise this scope in Manager Config. Recovery/expert fallbacks are
`15-MANAGE-LIBRARIES.bat` on Windows,
`./tautweekly.sh manage-libraries` on Docker editions, and
`sudo tautweekly manage-libraries` on Linux or FreeBSD. The write path backs up
`config.json` first. The corresponding `list-libraries` command (or
`16-LIST-LIBRARIES.bat`) is read-only. Verification warns about stale IDs and
fails when no configured ID matches an active video library.

### Interactive user exclusions

Manager Config queries Tautulli after `TautulliUrl` and `ApiKey` are entered,
then presents the delivery roster. The terminal fallback accepts rows or ranges
such as `2,4-6`, Enter to keep the current list, or `none` to clear every
exclusion. Unknown IDs already in the configuration are preserved when a new
known-user selection is saved, which avoids dropping an exclusion merely
because a user is temporarily absent from the current Tautulli response.

Roster loading makes two bulk requests: `get_user_names` supplies stable IDs
and display names, while `get_users` supplies delivery details. The results are
merged by ID. TautWeekly for Plex does not call `get_user` once per roster row;
if the detailed bulk request fails, name-only rows remain selectable but are
not marked delivery-eligible in the selector.

Normally revise exclusions in Manager Config. Recovery/expert fallbacks are
`14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on either Docker edition, and
`sudo tautweekly exclude-users` on Linux or FreeBSD. The standalone command
does not change `ExcludedEmails`, SMTP values, or scheduling. Both lists affect
scheduled and confirmed SendAll delivery. Preview and TestEmail modes remain
available for rendering checks, while a one-off welcome is a separate,
explicitly confirmed administrator action.

## Scheduling

| Key | Purpose |
|---|---|
| `ScheduleDay`, `ScheduleTime` | Local delivery day and 24-hour time |
| `ScheduleEnabled` | Container and native-service scheduler opt-in; defaults to false in examples |
| `ScheduleGraceMinutes` | How long a delayed scheduler poll may still attempt the send |
| `SchedulerPollSeconds` | Container scheduler poll interval |
| `ScheduledTaskName` | Windows Task Scheduler identity |

Windows uses Task Scheduler and the host's local Windows time. Every other
package resolves the platform timezone as an IANA zone and converts UTC through
that zone for each schedule decision. An invalid zone blocks automatic delivery
instead of falling back to UTC.

`schedule-status` reports both the zone/time resolved by its short-lived control
process and the zone/time recorded by the active scheduler heartbeat. After
changing a timezone environment file, restart the native service. After changing
Docker or Podman environment configuration, recreate or restart the container as
the platform requires, then confirm that `Scheduler TZ` matches `Configured TZ`
before enabling delivery.

## Docker environment

| Variable | Purpose |
|---|---|
| `TZ` | IANA timezone, such as `Etc/UTC` |
| `PUID`, `PGID` | Non-root runtime identity with write access to `data/` |
| `UMASK` | File-creation mask; `077` is the secure default |
| `PREVIEW_BIND` | Compatibility name for the host interface that publishes the authenticated Manager; Mac defaults to `127.0.0.1` |
| `PREVIEW_PORT` | Compatibility name for the host Manager port, normally `8787` |
| `PREVIEW_BASE_URL` | Public/local Manager base URL used for authenticated preview links |
| `MANAGER_ALLOWED_HOSTS` | Comma-separated exact DNS names accepted in addition to IP literals/localhost; no wildcards or ports |
| `MANAGER_SECURE_COOKIES` | Set `true` only when the Manager is reached through a trusted HTTPS reverse proxy |

Never paste live values into an issue, pull request, repository file, or public
release archive.

## Native service environment

Native Linux reads root-owned non-secret service values from
`/etc/tautweekly/tautweekly.env`. FreeBSD reads them from
`/usr/local/etc/tautweekly/tautweekly.env`. These files define the timezone,
data path, Manager bind/port, and-on FreeBSD-the OCI image reference. Keep SMTP,
Tautulli, and Plex secrets in the private `config.json`, not in service
environment files.
