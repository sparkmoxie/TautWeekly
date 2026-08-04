# PlexWeekly documentation

The [GitHub Pages source](index.html) preserves the supplied Plex-inspired
dark walkthrough experience, including
search, sticky navigation, scroll progress, responsive layouts, copy controls,
and terminal demonstrations.

## Install by platform

- [Windows portable](windows/README.md)
- [NAS / Docker Compose](nas-docker/README.md)
- [macOS / Docker Desktop](mac/README.md)

## Operate and maintain

- [Configuration reference](CONFIGURATION.md)
- [Security and hardening](SECURITY.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Release process](RELEASING.md)

The `.html` files in the platform directories are self-contained Pages
walkthroughs. The Pages workflow deploys from the repository's current default
branch: `public-launch` during launch review and `main` after the pull request
is merged and the default branch is changed. The Markdown files are the
canonical source-oriented guides for reading directly on GitHub.
