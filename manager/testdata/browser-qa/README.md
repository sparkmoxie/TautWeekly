# Manager browser QA fixture

These files are synthetic test inputs, not a usable TautWeekly configuration
or renderer. The PowerShell fixture accepts only the fixed `PreviewAll`,
`SendTestAll`, and `SendWelcome` Manager contracts, requires the `FixtureOnly` marker, and waits
briefly so active-state UI can be tested. PreviewAll writes seven fictional
local HTML files (an index plus six states); SendTestAll reports six fictional
SMTP acceptances; and SendWelcome reports one fictional acceptance. None opens
a connection. Each writes one sanitized structured result. The fixture contains
no network, SMTP, browser-launch, or scheduler operation.

`mock-tautulli.mjs` is an optional loopback-only companion for interactive
browser QA. It requires `X-Api-Key` authentication and rejects query-string API
keys. It exposes exactly five read-only Tautulli discovery commands used by the
Manager and returns three fictional libraries and 78 fictional users. The live
`get_libraries` response deliberately omits archive flags; `get_library_names`
provides the DB archive roster for the stable-ID join. Its primary user response omits two addresses so the bounded
`get_users_table` compatibility fallback is exercised. Those two users match
the fixture's legacy email exclusions, allowing the retained, checked exclusion
presentation to be verified without exposing real addresses.

For desktop and mobile smoke checks, library `3` is archived and selected;
missing library `99` is also selected. Both remain visible, and removing the
last selection must keep it checked until an active replacement is selected.
User `4` is archived, `5` is deleted, and `6` is inactive. They remain visible
for editing but cannot be selected for Preview, TestEmail, or Manual Welcome.
The fixture retains an archived user's fallback address and household copy,
plus an unavailable user's fallback address, so all remain reviewable.

Browser QA copies these files to an ignored temporary directory and renames
`fixture-config.json` to `config.json`. The temporary root and Manager data are
removed before repository validation.
