# Configuration reference

TautWeekly for Plex writes live settings to `config.json`. Docker editions keep
it under `data/`; Windows keeps it beside the application; native Linux uses
`/var/lib/tautweekly`; and FreeBSD uses `/var/db/tautweekly`. Start from the
platform's `config.example.json` only when manual setup is required—the guided
setup is preferred.

## Tautulli and Plex

| Key | Required | Purpose |
|---|---:|---|
| `TautulliUrl` | Yes | Base URL reachable from the TautWeekly for Plex runtime, such as `http://media.example.test:8181` |
| `ApiKey` | Yes | Tautulli API key; treat as a secret |
| `PlexWebUrl` | Yes | Destination for “Open Plex” links; defaults to the Plex web app |
| `PlexServerUrl` | No | Direct Plex base URL for richer metadata and artwork |
| `PlexToken` | No | Direct Plex token; treat as a secret |

TautWeekly for Plex's core activity flow uses Tautulli. Direct Plex access is optional
and improves selected metadata and artwork paths.

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

After setup receives the Tautulli URL and API key, it calls `get_libraries`
and lists active movie and TV libraries. Enter rows or ranges such as `1,3-4`,
type `all`, or press Enter to keep the displayed scope. At least one active
movie or TV library is required for a newly saved selection.

`IncludedLibraryIds` is applied to raw Tautulli history and recently-added
rows before any newsletter calculations. New/latest releases, quiet detection,
Trending, the hero, Binge Champion, and each user's personal totals therefore
share the selected scope. Per-user Plex sharing rules are not queried or
intersected; this is a single administrator-controlled scope.

Run `15-MANAGE-LIBRARIES.bat` on Windows,
`./tautweekly.sh manage-libraries` on Docker editions, or
`sudo tautweekly manage-libraries` on Linux and FreeBSD to change only this
scope. The manager backs up `config.json` first. The corresponding
`list-libraries` command (or `16-LIST-LIBRARIES.bat`) is read-only. Verification
warns about stale IDs and fails when no configured ID matches an active video
library.

### Interactive user exclusions

The guided setup queries Tautulli after `TautulliUrl` and `ApiKey` are entered,
then shows a numbered roster. Enter rows or ranges such as `2,4-6`, press Enter
to keep the current list, or type `none` to clear every exclusion. Unknown IDs
already in the configuration are preserved when a new known-user selection is
saved, which avoids dropping an exclusion merely because a user is temporarily
absent from the current Tautulli response.

Roster loading makes two bulk requests: `get_user_names` supplies stable IDs
and display names, while `get_users` supplies delivery details. The results are
merged by ID. TautWeekly for Plex does not call `get_user` once per roster row;
if the detailed bulk request fails, name-only rows remain selectable but are
not marked delivery-eligible in the selector.

Use `14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on either Docker edition, or
`sudo tautweekly exclude-users` on Linux and FreeBSD to revise
`ExcludedUserIds` independently. The standalone command does not change
`ExcludedEmails`, SMTP values, or scheduling. Both lists affect scheduled and
confirmed SendAll delivery. Preview and TestEmail modes remain available for
rendering checks, while a one-off welcome is a separate, explicitly confirmed
administrator action.

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
| `PREVIEW_BIND` | Host interface for preview publication |
| `PREVIEW_PORT` | Host preview port |
| `PREVIEW_BASE_URL` | URL printed in preview instructions |

Never paste live values into an issue, pull request, repository file, or public
release archive.

## Native service environment

Native Linux reads root-owned non-secret service values from
`/etc/tautweekly/tautweekly.env`. FreeBSD reads them from
`/usr/local/etc/tautweekly/tautweekly.env`. These files define the timezone,
data path, preview bind/port, and—on FreeBSD—the OCI image reference. Keep SMTP,
Tautulli, and Plex secrets in the private `config.json`, not in service
environment files.
