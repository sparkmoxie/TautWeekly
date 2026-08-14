# Manager browser QA fixture

These files are synthetic test inputs, not a usable TautWeekly configuration
or renderer. The PowerShell fixture accepts only the fixed `PreviewAll`,
`SendTestAll`, and `SendWelcome` Manager contracts, requires the `FixtureOnly` marker, and waits
briefly so active-state UI can be tested. PreviewAll writes seven fictional
local HTML files (an index plus six states); SendTestAll reports six fictional
SMTP acceptances; and SendWelcome reports one fictional acceptance. None opens
a connection. Each writes one sanitized structured result. The fixture contains
no network, SMTP, browser-launch, or scheduler operation.

Browser QA copies these files to an ignored temporary directory and renames
`fixture-config.json` to `config.json`. The temporary root and Manager data are
removed before repository validation.
