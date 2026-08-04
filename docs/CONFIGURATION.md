# Configuration reference

PlexWeekly writes live settings to `config.json`. Docker editions keep it under
`data/`; Windows keeps it beside the application. Start from the platform's
`config.example.json` only when manual setup is required—the guided setup is
preferred.

## Tautulli and Plex

| Key | Required | Purpose |
|---|---:|---|
| `TautulliUrl` | Yes | Base URL reachable from the PlexWeekly runtime, such as `http://media.example.test:8181` |
| `ApiKey` | Yes | Tautulli API key; treat as a secret |
| `PlexWebUrl` | Yes | Destination for “Open Plex” links; defaults to the Plex web app |
| `PlexServerUrl` | No | Direct Plex base URL for richer metadata and artwork |
| `PlexToken` | No | Direct Plex token; treat as a secret |

PlexWeekly's core activity flow uses Tautulli. Direct Plex access is optional
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
| `TestEmail` | Controlled recipient for all test modes |

Implicit SMTPS on port 465 is not the supported transport. Use a provider's
STARTTLS settings.

## Content and eligibility

| Key | Default | Purpose |
|---|---:|---|
| `DaysBack` | 7 | Activity and recently-added window |
| `WatchedPercent` | 85 | Completion threshold |
| `MinimumEpisodeSeconds` | 120 | Filters very short playback |
| `MaxMovies`, `MaxTv` | 8 | Content-card limits |
| `ExcludedUserIds` | `[]` | Users omitted by stable Tautulli ID |
| `ExcludedEmails` | `[]` | Email addresses omitted from delivery |
| `RecentAccessDays` | 7 | New/recent access classification |
| `SendDelaySeconds` | 10 | Pause between real production recipients |
| `TestSendDelaySeconds` | 2 | Pause between controlled test messages |

## Scheduling

| Key | Purpose |
|---|---|
| `ScheduleDay`, `ScheduleTime` | Local delivery day and 24-hour time |
| `ScheduleEnabled` | Docker scheduler opt-in; defaults to false in examples |
| `ScheduleGraceMinutes` | How long a delayed scheduler poll may still attempt the send |
| `SchedulerPollSeconds` | Container scheduler poll interval |
| `ScheduledTaskName` | Windows Task Scheduler identity |

Set the Docker `TZ` environment value to the intended IANA timezone so schedule
evaluation matches the operator's expectation.

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
