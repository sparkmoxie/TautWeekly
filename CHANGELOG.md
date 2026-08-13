# Changelog

All notable public changes to TautWeekly for Plex will be documented here. The project
uses [Semantic Versioning](https://semver.org/) for GitHub releases and follows
the structure of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.10.4] - 2026-08-13

### Fixed

- Personal TV statistics continue to consolidate episode activity by show and
  total watch duration, but now prefer that show's IMDb score and fall back to
  its Rotten Tomatoes critic score, then its audience score. Episode-level
  ratings remain limited to TV release rows.
- Personal movie and TV rows now omit the rating line when no eligible score
  exists instead of rendering `Ratings unavailable` or `IMDb unavailable`.
- Added cross-platform renderer regressions for populated IMDb/RT priority,
  score-dependent RT icons, aggregate TV duration, and absent-rating layout
  across Windows, NAS/Docker/Linux/FreeBSD, and macOS sources.

### Security

- Reused the existing exact show rating key and bounded provider-labelled
  metadata sources. The refinement adds no title search and does not persist or
  expose configuration, credentials, viewing history, recipient data, upstream
  responses, logs, or generated newsletters.

## [0.10.3] - 2026-08-13

### Changed

- Added a consistent metadata-readiness sequence to every maintained setup
  wizard, verifier, Quickstart, platform guide, update/install completion path,
  and private container preview landing page. Before first acceptance, users
  confirm each included Plex Movie library's Ratings Source, run Plex **Refresh
  All Metadata** for every included movie/TV library, then use Tautulli's
  per-library **Library > Media Info > Refresh media info** control before
  Verify, PreviewAll, or TestEmail.
- The guided macOS and QNAP installers now pause before their automatic
  verifier so the administrator can finish those upstream refreshes. Other
  platforms print the same ordered checklist before their test commands.
- Clarified that Plex full-library refreshes can be slow and can update
  metadata or artwork, Tautulli's table refresh does not replace Plex's
  refresh, and routine TautWeekly updates do not require the full sequence
  when current output already renders correctly.
- Pinned the canonical branding build script to byte-preserving Git handling
  so its approved SHA-256 remains stable in Windows and Unix checkouts.

### Security

- Kept metadata refreshes manual and scoped to the administrator-selected
  Plex libraries. TautWeekly does not invoke either upstream refresh API and
  does not expose configuration, tokens, history, recipients, private
  infrastructure, responses, logs, or generated newsletters.

## [0.10.2] - 2026-08-13

### Fixed

- Added an exact-episode Rotten Tomatoes fallback for TV release rows. An
  available IMDb score for that exact episode still has priority; otherwise
  the renderer uses the exact episode's RT critic score, then its RT audience
  score. Show-level, movie, TMDB, TVDB, unknown, and unlabelled values remain
  ineligible.
- Extended sanitized PreviewAll, SendTest, and renderer regressions across the
  maintained Windows, NAS/Docker/Linux/FreeBSD, and macOS sources. The tests
  prove IMDb wins when both providers exist and that an RT-only exact episode
  receives the score-dependent tomato or popcorn presentation.

### Security

- Reused the authenticated, exact-rating-key Plex and bounded Tautulli
  metadata paths introduced for rating recovery. The fallback adds no external
  rating search and does not persist or expose configuration, tokens, history,
  recipients, responses, or generated newsletter output.

## [0.10.1] - 2026-08-13

### Fixed

- Added an authenticated native Plex XML fallback for provider `Rating`
  elements when PMS omits required provider entries from JSON or ignores the
  requested scalar-field exclusion. Movies still prefer available Rotten
  Tomatoes critic/audience values, while TV rows still accept only
  exact-episode IMDb.
- Extended the sanitized PreviewAll and SendTest regression to cover a Plex
  server that exposes selected IMDb in JSON but the retained RT pair only in
  XML. The original optional-JSON path remains covered across the shared
  Windows, NAS/Docker/Linux/FreeBSD, and macOS renderer sources.
- Reclassified an empty optional Plex hosted-metadata exact-match fallback as
  informational. It can be unrelated to ratings and no longer appears as a
  warning when rendering can continue with local Plex or Tautulli metadata.

### Security

- Kept both direct requests on the user-configured Plex server, with the
  administrator token in an HTTP header. Regression output contains only
  synthetic provider labels and scores; no private response, rating key,
  configuration, recipient, history, or generated newsletter is committed.

## [0.10.0] - 2026-08-13

### Added

- Added the exact approved detailed popcorn `TW` raster provenance, corrected
  transparent source, transparent normalized logo master, padded transparent
  app-icon master, reproducible Pillow build, fixed SHA-256 evidence,
  raster-preserving SVG wrappers, web/app sizes, and Windows ICO to the durable
  public brand source.
- Added a Pages favicon, touch icon, web manifest, and social preview image,
  plus packaged product icons for the private container preview landing page
  and the Windows portable distribution.

### Changed

- Replaced global placeholder `TW`, chevron/play, popcorn emoji, Community Apps,
  and preview-service marks with exact raster derivatives. Platform-specific
  README badges remain their own identities; generic documentation
  abbreviations were replaced by verified Windows, Apple, Docker, QNAP,
  Unraid, Linux, and FreeBSD marks with fixed provenance and hashes.
- Preserved each platform mark's native colors and proportions, except for the
  user-approved Apple geometry-only derivative in TautWeekly gold; its original
  black SVG is retained untouched as provenance.
- Classified and documented unsupported package surfaces rather than inventing
  them: current `main` has no QNAP QPKG/App Center package, Windows
  Setup/uninstaller/executable, macOS app bundle, Linux desktop entry, or
  FreeBSD GUI metadata. The approved Windows ICO is packaged for those future
  Setup/shortcut consumers without changing portable installation behavior.
- Kept product artwork out of generated newsletter HTML and left the existing
  mail-state and provider assets unchanged.

## [0.9.8] - 2026-08-13

### Fixed

- Explicitly requested Plex's optional `Rating` metadata element for direct
  item JSON and exact-episode XML fallback requests, while excluding the
  case-colliding scalar JSON `rating` field. This restores alternate Rotten
  Tomatoes critic/audience values and exact-episode IMDb values when Tautulli
  exposes only Plex's flattened selected IMDb or TMDB score.
- Added a sanitized cross-platform regression that models the reported split:
  the default metadata response contains only selected IMDb, while the
  opt-in response contains the provider-labelled RT pair.
- Setup, verification, quickstarts, and troubleshooting now identify Plex's
  library-wide **Ratings Source → Rotten Tomatoes** setting and metadata refresh
  as prerequisites for intentional RT movie output. A passing direct-Plex check
  proves reachability, not provider choice.

### Security

- Kept the existing private direct-Plex boundary. The administrator token
  remains in an HTTP header, the request targets only the configured server
  and exact rating key, and no metadata response, viewing history, recipient
  data, generated newsletter, or private configuration is committed.

## [0.9.7] - 2026-08-13

### Fixed

- Routed container shells, setup, verification, library/user management,
  roster, asset-repair, and schedule controls through the configured non-root
  PUID/PGID. This prevents Docker, Unraid, QNAP, macOS Docker, and
  FreeBSD/Podman Console or exec commands from creating root-owned
  configuration and logs that later newsletter operations cannot update.
- Added bounded migration recovery for root-owned entries left by prior
  container commands under the dedicated `/data` filesystem.

### Security

- Restricted ownership recovery to root-owned entries on the `/data`
  filesystem without following symlinks or crossing mount points. The
  launchers continue to reject UID/GID 0 and do not expose private data.

## [0.9.6] - 2026-08-11

### Fixed

- Made direct Plex a clearly recommended setup step for full rating and artwork
  fidelity across Windows, NAS/Docker, macOS, native Linux, and
  FreeBSD/Podman. The guides now distinguish Tautulli-only fallback operation
  from the direct Plex path used for alternate RT values, exact-episode IMDb,
  backgrounds, and selected logos.
- Extended setup verification beyond Tautulli: it now tests the same resolved
  direct Plex URL and token that the renderer will use, including both the
  public identity endpoint and an authenticated library request. Unreachable,
  unauthorized, or invalid configured connections fail before Preview or
  SendTest; an entirely absent optional connection produces a reduced-fidelity
  warning.

### Security

- Kept the Plex token in the request header only. Verification does not place
  it in a URL, child-process command line, or status output, and does not write
  Plex responses or private server details to disk.

## [0.9.5] - 2026-08-11

### Fixed

- Continued through the bounded Plex and Tautulli rating fallbacks when a
  movie's flattened selected provider is IMDb, so available Rotten Tomatoes
  critic/audience values take precedence. A clearly labelled IMDb score is
  rendered only when no RT value is available.
- Restored exact-episode semantics for TV release rows: a selected TMDB or TVDB
  score no longer blocks the native Plex `Rating[]` / legacy XML IMDb lookup,
  and generic or show-level scores are not substituted beside episode titles.
- Added a sanitized regression where direct Plex returns 404, normal Tautulli
  movie metadata selects IMDb, and the rating-only item export supplies RT.
  Preview and decoded SendTest output must prefer RT and retain the individual
  episode IMDb score across every maintained renderer.

### Security

- Preserved the existing four-field, metadata-level-1 Tautulli export boundary.
  No external ratings search, media information, file paths, viewing history,
  recipient data, credentials, or generated output is added or persisted.

## [0.9.4] - 2026-08-11

### Fixed

- Accepted recognized provider-labelled IMDb, TMDB, and TVDB values from both
  Tautulli rating field pairs while preserving the dedicated Rotten Tomatoes
  movie and IMDb TV presentation. Current Tautulli TV metadata can place its
  selected TMDB score in `audience_rating` / `audience_rating_image` while
  leaving `rating_image` empty; v0.9.2 ignored that valid shape.
- Rendered the selected-provider fallback on movie, TV, episode, and personal
  statistics rows across Windows, NAS/Docker, and macOS, and retained the two
  bounded presentation fields in the exact-GUID deleted-item cache.
- Replaced the prior synthetic show-export fixture with Tautulli's maintained
  TV field contract, then exercised PreviewAll and decoded SendTest delivery
  with direct Plex deliberately unavailable. Follow-up evidence was provided
  by [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).

### Security

- Kept rating export requests at metadata level 1 with media information and
  file locations disabled. Only known provider identifiers with a numeric
  score from 0 through 10 are accepted; unknown or unlabeled values remain
  omitted.

## [0.9.3] - 2026-08-11

### Fixed

- Replaced the standards-valid but insufficiently supported `dark only` email
  declaration with Apple Mail's documented `light dark` opt-in. The base styles,
  dark-mode override, inline colors, and table fallbacks still render the same
  single dark-first design without adding a recipient-facing theme selector.
- Extended PreviewAll and decoded SendTest MIME assertions across every
  maintained renderer so delivered HTML must contain the compatible scheme
  metadata and must not retain the prior dark-only declaration.

## [0.9.2] - 2026-08-11

### Fixed

- Made Tautulli exporter-field discovery compatible with implementations that
  require a non-null `sub_media_type` even though the API documents it as
  optional.
- Explicitly requested the provider-labelled `rating`, `ratingImage`,
  `audienceRating`, and `audienceRatingImage` fields instead of relying on a
  Tautulli version's metadata-level mapping when field discovery is unavailable.
- Added the same item-export fallback for show IMDb ratings when Tautulli's
  normal metadata response and direct/hosted Plex lookups do not provide one,
  and display the recovered rating on the TV release card.
- Stopped rejecting valid rating-only JSON exports merely because their
  serialized response is shorter than 64 bytes.
- Extended the sanitized direct-Plex-failure regression through SendTest and
  now decode the captured MIME message to require movie RT, show IMDb, and
  their icons in the delivered HTML. This follow-up correction was reported by
  [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).

### Security

- Kept the exporter fallback limited to rating presentation fields at metadata
  level 1 with media information and file locations disabled. Unlabelled
  numeric values still fail closed.

## [0.9.1] - 2026-08-10

### Fixed

- Corrected the Tautulli fallback for movie Rotten Tomatoes ratings: item
  exports no longer request the library-only `individual_files` option, and
  rating-only downloads are parsed as JSON instead of being rejected for not
  being ZIP archives. Reported by
  [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).
- Accepted Tautulli's flattened rating fields and Plex's nested rating entries,
  including the Rotten/spilled low-score icon states. A sanitized integration
  scenario now keeps direct Plex unavailable and requires the item-export
  fallback to restore both critic and audience scores on every renderer.
- Documented why posters can remain available through Tautulli's image proxy
  while direct Plex ratings, backgrounds, or selected logos are unavailable,
  and how Docker operators must provide a Plex URL reachable from inside the
  TautWeekly container.

### Security

- Reduced the fallback from metadata level 9 to level 1 with media information
  disabled. The temporary export requests only presentation rating fields and
  cannot include library file locations or media-stream details.
- Kept provider-free numeric values fail-closed: TautWeekly does not label an
  unidentifiable rating as Rotten Tomatoes or IMDb.

## [0.9.0] - 2026-08-10

### Added

- Added a schema-versioned, persistent pre-deletion cache that records only an
  exact stable media GUID, bounded newsletter presentation metadata, and one
  SHA-256-verified poster while the Plex item is still available. PreviewAll,
  SendTest, and normal delivery can reuse the entry after later deletion on
  Windows, NAS/Docker, macOS, native Linux, and FreeBSD/Podman.
- Added default 365-day, 1,000-item, and 256 MiB retention controls, deterministic
  newest-first cleanup, atomic primary/backup manifests, corruption recovery,
  and cross-platform creation, deletion, eviction, privacy, and package tests.

### Changed

- Advanced the repository release to the next SemVer minor because this feature
  creates persistent state. Existing configurations migrate without a rewrite:
  omitted cache settings receive bounded defaults, while setup preserves later
  operator changes.
- Documented that the v0.8.3 Plex hosted-provider path is best-effort. Tautulli
  history can retain descriptive fields and identifiers, but neither Tautulli
  history nor a deleted Plex library item guarantees durable artwork bytes.
  The new cache protects future items observed after upgrade and cannot
  retroactively repair assets already discarded.

### Security

- The cache accepts a fixed presentation-field allowlist and excludes API keys,
  Plex and SMTP credentials, recipients, viewing metrics, and generated output.
  It never persists the Plex administrator token or sends it to third parties.
- Cache lookup requires the exact stable GUID and media type; malformed paths,
  missing identifiers, hash failures, and ambiguous title-only history fail
  closed. The total byte ceiling accounts for artwork and both manifests.

## [0.8.4] - 2026-08-10

### Fixed

- Preserved the newsletter's single dark-first palette in Apple Mail by
  declaring dark-only color-scheme support, and reinforced every maintained
  renderer with explicit longhand backgrounds and table `bgcolor` fallbacks
  for clients such as Gmail and Outlook that ignore or override scheme hints.
  Reported by [@Demonmeister](https://github.com/Demonmeister) in
  [#44](https://github.com/sparkmoxie/TautWeekly/issues/44).
- Captured and decoded the integration test's delivered MIME message so the
  preview variants and SMTP HTML must both retain the dark-mode metadata,
  outer canvas, card colors, and compatibility fallbacks.

## [0.8.3] - 2026-08-10

### Fixed

- Supplied Plex's required retained movie/show title and episode index context
  when its hosted provider retries deleted-history GUIDs, and preserved the
  representative episode indexes alongside aggregated TV history. This fixes
  the production `400 Bad Request` and empty-match behavior left in v0.8.2.
- Kept missing deleted-history artwork nonfatal under PowerShell strict mode when
  no hosted match is available.

### Security

- Validated title-hinted hosted responses against the retained canonical Plex
  GUID or returned external TMDB/TVDB/IMDb identifier. When Plex omits its
  external-ID array, the response must still agree with the retained title and
  media type from that exact external-ID request. Recipient identity and viewing
  metrics remain outside the Plex request.

## [0.8.2] - 2026-08-10

### Fixed

- Retried empty modern Plex and legacy TMDB/TVDB hosted lookups through Plex's
  current JSON `POST /library/metadata/matches` provider contract while
  preserving the compatible direct/query-form attempts. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) in
  [#51](https://github.com/sparkmoxie/TautWeekly/issues/51).

### Security

- Limited the provider-contract retry body to the validated exact
  GUID and numeric media type. It sends no title, year, recipient identity, or
  watch-history fields, and keeps the Plex token confined to the hosted Plex
  request.

## [0.8.1] - 2026-08-10

### Fixed

- Extended exact-GUID recovery for deleted Plex history to legacy TMDB agent
  aliases and legacy TVDB episode/show identifiers, and made unsupported or
  empty exact matches visible through privacy-safe warnings. Follow-up reported
  by [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) in
  [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).

### Security

- Kept legacy deleted-history recovery limited to validated numeric provider
  identifiers. It performs no title search and never writes the retained
  identifier or Plex token to diagnostics.

## [0.8.0] - 2026-08-10

### Fixed

- Made the generic-poster fingerprint probe portable to Unix so deleted Plex
  history artwork can proceed to the exact-GUID hosted recovery added in
  v0.7.0. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo)
  in [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).
- Routed watched TV-show statistics through the same exact-GUID enrichment as
  movies and rendered the recovered IMDb score in each personal TV row. The
  prior regression could match an unrelated global rating and now scopes its
  assertion to the TV statistics card. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) and corroborated
  by [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).
- Recovered provider-labelled movie Rotten Tomatoes and TV IMDb scores from
  Plex's public watch page when exact-GUID hosted metadata returns artwork and
  genres without ratings. The fallback uses only Plex's exact returned slug,
  performs no title search, and leaves genuinely unavailable scores blank.

### Security

- Kept the public Plex rating fallback tokenless and limited its request to the
  exact validated movie/show slug returned by Plex's authenticated GUID lookup.
  Recipient identity and watch-history values are never sent.

## [0.7.0] - 2026-08-10

### Fixed

- Recovered posters, summaries, genres, years, movie Rotten Tomatoes ratings,
  and TV IMDb ratings for deleted Plex items by resolving the exact metadata
  GUID retained in Tautulli history, and rejected Tautulli's generic poster
  placeholder as usable artwork. Reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo)
  in [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).

### Security

- Limited deleted-item recovery to Plex's hosted metadata service using the
  existing administrator Plex token and exact retained GUID. No title search,
  recipient identity, or watch-history payload is sent, and the token is not
  forwarded to external artwork hosts returned by Plex.

## [0.6.3] - 2026-08-09

### Fixed

- Made root-started Docker and Podman console newsletter commands drop to the
  configured PUID/PGID before writing locks, logs, posters, or diagnostics.

## [0.6.2] - 2026-08-09

### Fixed

- Treated sparse Tautulli hero metadata fields as optional so recoverable direct
  Plex 404 fallbacks cannot be followed by a strict-mode crash in previews or
  test email delivery.

## [0.6.1] - 2026-08-09

### Changed

- Limited **HOT NEW RELEASE** hero selection to new movies. Movie-empty weeks
  now promote the normal **TRENDING THIS WEEK** result while retaining new TV
  titles in the release shelf.
- Revised personal stats to list up to four most-watched movie titles and four
  most-watched TV shows, grouping qualifying episodes by show and omitting an
  empty TV card.
- Replaced the movie and TV stat artwork in every packaged renderer with the
  supplied animated GIFs while retaining the established CID/repair pipeline.
- Split Binge Champion into a bold watch-duration line and a smaller unique
  movie/TV-show breakdown for winners and non-winners, omitting zero categories.
- Removed qualifying-play copy from Total Watched.

### Fixed

- Accepted section-scoped Tautulli recently-added rows when Plex omits the
  redundant library identifier, while continuing to reject explicit library
  mismatches and unscoped rows.
- Made inbox preview and body counts describe unique TV titles/shows rather
  than episode rows when multiple series are added or watched.

## [0.6.0] - 2026-08-07

### Added

- Added an explicit Windows `U` action that downloads the official latest
  stable ZIP and checksum, validates a per-file release manifest, and applies
  the update only after user confirmation and Windows elevation.
- Added a shared Windows installation lock so newsletter runs and updates
  cannot overlap, plus functional regression coverage for checksum refusal,
  private-file preservation, deprecated-file cleanup, and rollback.
- Added `RELEASE-FILES.txt` with SHA-256 hashes to every packaged platform so
  release ownership is deterministic without claiming runtime data.

### Changed

- Advanced the Windows portable source baseline to 1.7.0 and documented the
  difference between manual update checking, explicit application, and the
  absence of unattended Windows update tasks.

### Security

- Windows updates now pause and restore Task Scheduler state, keep a private
  full-folder sibling backup, replace only verified release-owned files, verify
  the installed version and PowerShell syntax, and automatically restore the
  previous installation after a failed apply.

## [0.5.5] - 2026-08-07

### Added

- Added explicit stable-release checks for Windows, macOS, and native Linux,
  plus stage-only image checks for NAS/QNAP and FreeBSD.
- Added regression contracts for stable-channel defaults, check/apply
  separation, operation-lock refusal, health/version verification, and
  automatic container-image rollback.

### Changed

- Defined one package-by-package update policy across the README, Markdown
  guides, and rendered Quickstarts. Stable releases remain the default,
  unattended application is opt-in, and `edge` is documented as unreleased
  `main` rather than an update channel.
- Made NAS/QNAP Compose and FreeBSD updates preserve state, reject concurrent
  TautWeekly operations, verify the replacement container, and restore the
  prior image automatically after a failed health check.

### Fixed

- Corrected macOS `update`: it now builds the verified release package present
  on disk, records that repository version in the image, verifies health and
  version, and rolls back on failure instead of only refreshing the base image.
- Removed FreeBSD's ineffective Podman registry auto-update label; Podman auto
  update requires a systemd-managed container, while this package uses rc.d.

## [0.5.4] - 2026-08-07

### Added

- Added global movie/TV library discovery and selection to every primary setup
  flow, using stable Tautulli section IDs and preserving legacy all-library
  behavior for configurations without an explicit selection.
- Added standalone list and management commands for Windows, NAS/Unraid,
  macOS, native Linux, and FreeBSD, including configuration backup and stale-ID
  verification.
- Added deterministic virtual Tautulli/Plex integration scenarios for active
  and quiet release weeks, cross-platform command-routing tests, packaged
  runtime contract checks, and checksum verification for every distribution.

### Changed

- Consolidated the separate Docker Compose quick-start page into the canonical
  NAS / Docker guide. Compose, QNAP Container Station, Unraid Apps, and Docker
  Desktop are now presented as deployment paths for one package; the retired
  `quickstart.html` URL redirects to the consolidated guide.
- Routed top-level Unraid references through the consolidated NAS Quickstart or
  Markdown documentation; the detailed NAS guides retain the published
  Community Apps installation destination in context, including the platform
  comparison shortcut.
- Separated interactive Quickstarts from source-oriented documentation and
  standardized the platform labels across the README, Pages hub, rendered HTML,
  and standalone installation guides.
- Query each selected Tautulli section independently for history and
  recently-added media, then fail closed on mismatched rows before calculating
  releases, quiet mode, Trending, hero content, Binge Champion, and personal
  statistics. Busy private libraries can no longer crowd selected releases out
  of paged API results.
- Allow the FreeBSD Podman binary path to be set with
  `TAUTWEEKLY_PODMAN_BIN`, while retaining `/usr/local/bin/podman` as the
  package default.

### Fixed

- Clarified that `./tautweekly.sh` is a host-side Docker Compose wrapper, not a
  command inside the Unraid Apps container, and replaced container-generated
  follow-up guidance with commands that exist in the Unraid Console.
- Made every non-Windows scheduler resolve and convert UTC through the configured
  IANA `TZ` explicitly instead of trusting process-local `Get-Date`; invalid
  zones now fail closed instead of silently scheduling in UTC. Schedule status
  now distinguishes the control process from the active scheduler heartbeat,
  including the resolved zone, local time, and UTC offset.
- Replaced the legacy SMTP send path with an explicit STARTTLS and
  `AUTH LOGIN`/`AUTH PLAIN` transport that requires authentication success
  before `MAIL FROM`, including compatibility with Proton SMTP submission.
- Corrected Unraid Console examples to pass the required numeric `USER_ID`,
  clarified that `ListUsers` is display-only across every launcher and guide,
  and documented that `verify` checks SMTP reachability rather than login or
  sender authorization.
- Corrected the selected-library row predicate on all renderers. PowerShell
  previously accepted an unsupported parameter without binding the row,
  causing every history and release item to be rejected whenever an explicit
  library scope was enabled.

## [0.5.3] - 2026-08-05

### Fixed

- Replaced Docker health's scheduler-progress dependency with a five-second
  service-supervisor heartbeat, preventing long scheduled deliveries from
  making a working container appear unhealthy.
- Made missing decorative preview artwork a repair warning rather than a
  liveness failure, while retaining hard failures for an unavailable preview
  listener and a missing, unreadable, or stale supervisor heartbeat.
- Added actionable health-probe errors and an eight-scenario functional suite
  covering failure isolation and automatic recovery.

## [0.5.2] - 2026-08-05

### Fixed

- Replaced exclusion setup's per-user `get_user` requests with a two-call merge
  of Tautulli's `get_user_names` and `get_users` rosters. Stable IDs from the
  name roster remain selectable when detailed rows are unavailable.
- Added a bulk-roster fallback for newsletter user resolution when a Tautulli
  installation rejects an otherwise valid single-user lookup.

## [0.5.1] - 2026-08-05

### Added

- Added a standalone, responsive eight-state newsletter showcase with real
  public Plex Discover posters and title art, dated Rotten Tomatoes movie and
  IMDb episode score examples, production-formatted TV episode rows, dense
  movie/TV releases, both anonymous Binge Champion treatments, onboarding and
  warmup variants, and the production quiet-week latest-release fallback.

### Fixed

- Treat Tautulli episode `rating_image` and `rating` fields as optional when
  building personal statistics, preventing `preview-all` from failing under
  strict PowerShell property handling when either field is omitted.
- Added a permanent first-run page to the container preview endpoint, verified
  its listener before starting the scheduler, and made an unexpected preview
  or scheduler process exit fail the container visibly.
- Corrected NAS documentation that pointed to a nonexistent `preview-all/`
  subdirectory; the generated index is `/preview-all-00-INDEX.html`.

### Changed

- Docker and Unraid startup logs now identify the exact persistent
  `/data/config.json` path and provide the appropriate Compose or Console setup
  command. Documentation and Community Apps metadata now distinguish the
  read-only preview viewer from an administration Web UI.

## [0.5.0] - 2026-08-04

### Added

- Added a standalone native Linux distribution with PowerShell 7.2+, a
  hardened systemd service, protected `/var/lib/tautweekly` storage, safe
  in-place upgrades, and matching administrative commands.
- Added a FreeBSD 15.1+ amd64 beta distribution using FreeBSD Podman Linux
  containers, rc.d lifecycle integration, protected `/var/db/tautweekly`
  storage, image pinning, updates, and private backups.
- Added rich searchable Linux and FreeBSD Pages walkthroughs, standalone
  Markdown install guides, platform troubleshooting, security boundaries, and
  support-matrix entries.
- Added Linux and FreeBSD ZIP/TAR.GZ release artifacts, checksum coverage,
  launcher-permission checks, and platform-contract validation.

### Changed

- Made container runtime wrappers honor configurable application and data roots
  so the canonical renderer can be packaged for native Linux without source
  drift.

## [0.4.0] - 2026-08-04

### Added

- Added interactive Tautulli user exclusion selection to every platform's
  primary setup and a standalone exclusion manager for later recipient-policy
  updates.
- Added Windows and Docker launch commands, selection behavior tests, and
  matching Markdown and rendered walkthrough guidance.

### Changed

- Setup replacement now carries forward existing `ExcludedUserIds` and
  `ExcludedEmails`; a temporary Tautulli lookup failure no longer silently
  clears established exclusions.
- Binge Champion now ranks qualifying users by total watch time, with total
  plays as the exact-time tie-breaker.
- Binge Champion output now shares only anonymous movie-play, TV-play, and
  watch-time totals. Friendly names, user identifiers, and titles are hidden;
  only the winner receives the gold **YOU WON** treatment.

## [0.3.0] - 2026-08-04

### Added

- Added an official Unraid Community Applications v2 Docker template and root
  `ca_profile.xml` with safe appdata, port, identity, and timezone defaults.
- Added automated amd64/arm64 container publishing to
  `ghcr.io/sparkmoxie/tautweekly` with OCI source metadata, SBOM, provenance,
  version tags, and a stable `latest` tag.
- Added a pull-based QNAP Container Station Compose application while keeping
  the source Dockerfile and local-build workflow maintainable.
- Added repository validation for Community Applications metadata and Docker
  template configuration.

### Changed

- Updated the NAS/Docker baseline to 1.1.0 and made routine NAS installation
  and updates pull the published image without touching persistent data.
- Documented why QNAP App Center is not used for the Docker edition: App Center
  catalogs native QPKG packages, while Container Station is QNAP's Compose UI.

## [0.2.0] - 2026-08-04

### Changed

- Renamed the public product to **TautWeekly for Plex** and standardized the
  repository, Pages site, documentation, UI, email, source, and release
  branding around `TautWeekly`.
- Renamed the PowerShell entry points to `TautWeekly.ps1`, Docker launchers to
  `tautweekly.sh` and `tautweekly-docker.ps1`, and release archives to the
  `TautWeekly-<platform>` convention.
- Renamed Docker services, images, internal application paths, operation
  locks, backups, and environment variables to the lowercase `tautweekly` or
  uppercase `TAUTWEEKLY_` convention.
- Moved repository and rendered documentation links to
  `sparkmoxie/TautWeekly` and `sparkmoxie.github.io/TautWeekly`.

### Migration

- Preserve private configuration and the Docker `data` directory, but replace
  program files with the 0.2.0 package and use the newly named launchers.
- Recreate Docker services with `docker compose up -d --build` after replacing
  the application files. Windows users should verify the scheduled-task name
  in `config.json` before reinstalling the schedule.

## [0.1.1] - 2026-08-03

### Fixed

- Preserved Docker dotfiles in ZIP release archives, including
  `.dockerignore`, `.env.example`, and `data/.keep`.
- Added a build-time ZIP payload parity check so archive creation fails if any
  staged source file is omitted.

## [0.1.0] - 2026-08-03

### Fixed

- Pointed the README documentation entry at the live Pages site, removed
  premature download links to an empty Releases page, and made current source
  locations explicit until the first version tag is published.
- Replaced user-facing links to HTML source blobs with rendered GitHub Pages
  URLs for the documentation home, all three platform walkthroughs, and the
  NAS / Docker Compose quick start.
- Made the Pages deployment follow the repository's current default launch
  branch and replaced a stale `blob/main` footer link with a default-branch
  (`HEAD`) URL.
- Preserved array semantics for exactly one adaptive movie or episode under
  Windows PowerShell 5.1 strict mode.
- Derived archive source-baseline metadata from each platform's shipped
  `VERSION.txt` instead of stale hard-coded values.

### Added

- Initial public, maintainable source tree for Windows, NAS/Docker, and macOS
  Docker Desktop.
- Sanitized configuration examples and repository-wide runtime-file guards.
- Interactive GitHub Pages documentation based on the supplied rich
  walkthroughs.
- Cross-platform validation, release packaging, checksums, Pages deployment,
  and tagged-release automation.
- Adaptive personal activity cards with posters, movie genres and ratings,
  episode metadata, and equal content-driven heights.
- A server-wide Binge Champion user award and counted Trending title feature.

### Changed

- Scheduled weekly mail now discloses the Binge Champion friendly name and
  winning aggregate; one-off welcome mail remains award-free.

### Source baselines

- Windows portable implementation: 1.6.11.
- NAS/Docker implementation: 1.0.7.
- macOS Docker Desktop implementation: 1.0.3.

These baseline numbers describe the imported platform distributions. Future
public GitHub releases use one repository-level semantic version.
