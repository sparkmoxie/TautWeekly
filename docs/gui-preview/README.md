# TautWeekly GUI Preview boundary

The rendered [GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/)
is a static, package-neutral demonstration of the Manager interface. It uses a
synthetic in-memory API and only fictional users, libraries, endpoints, email
addresses, schedules, newsletters, diagnostics, and operation results.

The page never contacts Plex, Tautulli, SMTP, a scheduler, or another external
service; it writes no files and stores no credentials or entered values. Its
content security policy disables network connections, all simulated checks
pass, and every temporary edit or operation resets on reload.
