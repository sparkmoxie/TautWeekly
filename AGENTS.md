# TautWeekly repository instructions

These instructions apply to the entire repository.

## Delivery boundaries

- Treat each clearly defined patch, hotfix, feature batch, or release as one discrete delivery.
- Keep clarifications, validation, CI monitoring, packaging, publication, and immediate fixes for that delivery in the same Codex task until the requested outcome is complete.
- Before closing a delivery, verify the relevant tests and publication state, then report the commit, pull request, merge, tag, release, artifacts, and any remaining risks that apply.
- A milestone or major delivery boundary is reached once its commit or pull request has been merged or deployed. Pending validation and monitoring for that delivery stay in its existing task, but any new unrelated request starts in a fresh Codex task.
- Start that fresh task inside the existing TautWeekly local project, using a new Codex-managed Git worktree based on the latest remote `main`. Fork the repository state, not the completed conversation history, so each update or fix has an isolated task transcript.
- Do not create a projectless task, another saved local project, or a permanent-worktree project for the next TautWeekly delivery.
- Fetch the remote and confirm the worktree starts from current `origin/main` before making changes. Create a feature branch in the managed worktree only when implementation begins.
- Keep the primary TautWeekly checkout on `main` as the canonical source-of-truth and coordination context. Do not reuse its long-running task or working directory for unrelated implementation after a delivery boundary.
- Before fixing existing behavior, inspect the latest `main` implementation, tests, documentation, merged pull requests, and published release behavior. Treat older branches, prior worktrees, archives, and legacy source folders as historical inputs rather than the current implementation baseline.
- Do not carry unrelated implementation work into a completed delivery task.
- Seed the new task with the repository path, target branch, current commit or tag, relevant pull-request or release URLs, validation results, and unresolved risks so work can continue without losing context.
- Do not create a new task merely for a refinement or immediate fix belonging to the active delivery.
- If task creation is unavailable, ask the user to open a fresh task and stop before starting the next separate delivery.

## Repository safety

- Treat legacy source folders and any supplied production archives as input-only unless the user explicitly changes that scope.
- Create and modify public project files only in the local `TautWeekly` Git repository or one of its Git worktrees.
- Preserve unrelated user changes and use a clean branch or worktree when the primary checkout is dirty.
- Never commit runtime configuration, credentials, tokens, personal identifiers, generated newsletters, logs, state files, or private infrastructure details.

## Primary Quickstart feature spotlight

- Keep the featured release box in `docs/index.html` focused on the newest published release that adds substantial user-facing functionality.
- A release qualifies when its changelog has an `Added` section describing a new end-user capability. Maintenance-only fixes, hardening, documentation, internal tooling, minor visual polish, and other tweaks do not replace the featured release.
- When a qualifying feature release is published, update the spotlight's `data-feature-release` value, version label, explanation, capability summary, configuration link, and release-notes link together.
- Keep repository validation aligned with this policy so a later maintenance release cannot silently displace the latest feature release.
