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

## Risk-based validation

- Choose the smallest sufficient checks for the actual change. Use targeted tests while editing; do not automatically run the full baseline suite or repeat a full suite after each small edit.
- Reuse passing CI evidence for the exact commit or identical tree. Do not duplicate comprehensive suites locally and in CI without a concrete risk or failure; rerun only checks invalidated by later changes.
- Diagnose failures before retrying. For demonstrated infrastructure failures, prefer failed-job-only retries. Monitor required existing CI/release runs instead of adding duplicate manual runs.
- Docs-only changes need relevant documentation/link checks. Presentation changes need focused renderer, parity, and static checks plus representative desktop/mobile visual QA. Recipient, data, or security changes justify broader integration and privacy coverage.
- Keep required CI/release gates, privacy/isolation checks, package/checksum integrity, and publication verification. Never disable tests to get green, conceal omitted coverage, or claim unsupported email-client testing. Briefly explain any necessary expansion of validation.

## Optimized CI trigger matrix

This section describes the implemented risk-based policy in `.github/workflows`.
Reinspect the current workflows, required checks or rulesets, and recent Actions
history before changing it. Keep `scripts/ci_classifier.py` and its positive and
negative fixtures synchronized with workflow, build, packaging, and test inputs.

### Evidence and current behavior

- The baseline audit was performed against v0.23.1 / 06fba2372e45ab88fe63a58736b98b82a42f1b55 on 2026-08-27. At that point ci.yml used unfiltered push and pull_request triggers, so the same feature-branch commit ran the complete CI workflow twice once a pull request existed. The workflow also ran the complete matrix again on main and on release tags.
- PRs #161 and #162 each produced both a six-job branch-push CI run and a six-job pull-request CI run for the identical head SHA. Their full active-week and quiet-week rendering steps took 12.4 and 13.4 minutes in the PR runs; the complete duplicate runs took 16-24 minutes. Each merge then produced another approximately 20-minute full main CI run.
- The v0.23.1 tag produced an 18.2-minute generic CI run in parallel with the 18.3-minute Release workflow. The tag CI repeated PowerShell, rendering, archive, and installer checks even though Release built and validated the artifacts, tested the installer, built and boot-tested both container architectures, and published only after those jobs passed.
- The final v0.24.0 maintenance PR repeated its exact head SHA in a 19.2-minute
  branch-push CI run and a 21.4-minute pull-request CI run. The latter spent
  14 minutes 27 seconds in the full active-week and quiet-week render step.
  Merging then launched another 20.7-minute generic main CI run, and tagging the
  same merge commit launched a 21-minute generic CI run beside the 19.3-minute
  Release workflow. The optimized triggers eliminate the feature-branch and tag
  copies and make a verified merge run provenance-only.
- At the audit point GitHub reported no classic branch protection on main and no repository rulesets. Do not infer that this remains true. Before changing check names or triggers, query both protection mechanisms and inventory any required status contexts.
- test-newsletter-integration.ps1 copies and exercises the Windows, NAS/Linux/FreeBSD, and Mac renderer payloads across active, quiet, and additional edge scenarios. build-releases.ps1 packages the complete platform trees and platform guides, builds Manager and installer binaries, normalizes archives, and emits checksums. These direct dependencies are the basis for the path classes below; keep the classifier synchronized when either script changes.

### Implemented event policy

| Event | Always present | Conditional work | Work intentionally omitted |
| --- | --- | --- | --- |
| Feature-branch push | No automatic CI workflow. Developers may use a manual `auto`, `fast`, or `full` diagnostic dispatch before opening a PR. | None by default. Once a PR exists, `pull_request` is the authoritative validation event. | Do not run a second full branch-push matrix for the same SHA. |
| Pull request | Run an unfiltered change-classifier job, the fast PR layer, and one stable aggregate check named CI / required. | Run the path-classified PowerShell/runtime, render, Manager, package, installer, Compose, and container-image gates below. | Do not publish Pages, containers, archives, or releases. |
| Push to main after a green PR | Verify the exact merge commit, PR head, tested first parent, short-lived exact base/head provenance artifact, and successful `CI / required` run, then run the stable aggregate. Require PRs to be current with main so the tested PR merge tree is the tree that lands. | Deploy Pages for documentation inputs and publish the edge container for container-image inputs, after the aggregate. Perform only deployment-specific work not already proven by the PR tree. | Do not blindly replay the full PR matrix, full render matrix, release archives, or installer lifecycle. |
| Direct or otherwise unverified push to main | Detect the lack of a green associated PR and fail closed. | Run the same path-classified gates that a PR would have required before any deployment or publication. | Do not treat an unprotected direct push as if it inherited PR evidence. |
| Release tag `v*.*.*` | Run a release preflight that proves the tag is on main history, every platform version and the release notes agree, and the exact tagged commit has green `CI / required` provenance. | Build the final archives once; validate checksums, payload contracts, launcher modes, native Linux startup, and reproducibility; test the generated Windows installer; build and boot-test both release container architectures; publish attestations, containers, artifacts, and the GitHub Release only after all gates pass. | Generic CI does not trigger for tags, and Release does not repeat the source-render or generic repository matrix. |
| Manual dispatch | Always identify the selected commit and report which classifier outputs and gates were requested. | Permit focused diagnostics or an explicit full audit. | A manual run does not replace a required PR result unless it tests the exact required commit/tree and repository policy explicitly accepts its stable aggregate context. |

Keep the required PR workflow itself free of workflow-level paths filters. The classifier, fast layer, and aggregate must start for every PR; apply path conditions to jobs or reusable calls. Otherwise an intentionally unmatched workflow may never create its required check and can leave branch protection pending.

### Pull-request path classes

The path notation below is descriptive shorthand; expand it explicitly in the classifier and test it with positive and negative fixtures. A change may select more than one class. Changes to the classifier, a workflow, a reusable action, or a validation script must select every gate whose behavior it can alter. Unknown executable, build, package, or test inputs fail closed to the broader applicable gate instead of being silently treated as documentation.

| Class | Inputs that select it | Required gate |
| --- | --- | --- |
| Fast PR layer | Every PR, including Markdown- and AGENTS.md-only changes. | Repository privacy/hygiene and JSON checks; branding, platform-copy, Unraid, and GUI synchronization contracts; docs validation and relative links; shell, JavaScript, Python, JSON/YAML, and PowerShell syntax; Manager accessibility; plus cheap unit checks applicable to the changed files. This layer must remain fast and must not build release archives, installers, or container images. |
| PowerShell/runtime | Maintained platforms/**/*.ps1 runtime or setup code; PowerShell validators/tests and their fixtures; templates or configuration contracts consumed by that code. | Parse under the maintained Windows PowerShell and PowerShell 7 engines and run the relevant cross-platform runtime/unit suites. Exclude the full newsletter render gate unless the render class also matches. |
| Full renderer | Any maintained `TautWeekly.ps1`; renderer-loaded SMTP, operation-lock, deleted-item-cache, or cache-diagnostic runtime; newsletter templates or local email assets; renderer fixture/assertion helpers; render, recipient-isolation, library/user-selection, cache, MIME/SMTP, or presentation tests; or packaging logic that can change which renderer/runtime/template/asset bytes enter an artifact. | Run the complete active-week and quiet-week matrix once under Windows PowerShell across the maintained Windows and container payloads, plus the PowerShell 7 portability, cache, SMTP, and recipient-isolation assertions. A guide, license, or other package-only text input does not select this gate merely because it is included in an archive. |
| Manager | manager/**, mirrored Manager or GUI-preview web assets, Manager Go tests, GUI synchronization, accessibility, update-indicator/header/preview tests, or Manager cross-build logic. | Run Go test/vet, embedded JavaScript checks, GUI parity/accessibility tests, and maintained-target cross-builds. Avoid repeating the same cross-build on both runner operating systems unless the OS itself is under test. |
| Release package | platforms/** files copied into a release; manager/**; installer/**; the five packaged platform README files; LICENSE; THIRD_PARTY_NOTICES.md; release builder, artifact-contract, reproducibility, native-Linux-package, archive-mode, or checksum logic. | Build candidates once, then test exact manifests/payload contracts, archive integrity and executable modes, checksums, native Linux startup, and reproducibility. Upload a short-lived candidate only when a downstream selected gate needs it. |
| Windows installer | installer/**; any Windows release-payload input; Manager Windows binary/resource inputs; installer build/test logic. | Consume the selected package candidate and test isolated install, upgrade, icon/identity, rollback where applicable, and uninstall. Do not run for packages that cannot change the Windows payload or installer. |
| Compose/config | Maintained Compose files, container configuration examples, Unraid template, runtime-profile selection, or their validators/tests. | Parse every affected Compose/profile variant and run configuration/refusal tests. Compose-only changes do not require a multi-architecture image build unless they also alter image inputs or boot behavior. |
| Container image | Dockerfiles or .dockerignore; files copied into the unified image, including the canonical NAS app payload, Manager, templates, and ca_profile.xml; entrypoint/health/runtime-profile behavior; container image/profile tests; container build or publication workflow logic. | On PRs, build and boot-test affected amd64 profiles and exercise arm64/QEMU when architecture, Dockerfile, base/runtime, native Manager, or cross-platform boot inputs changed. On main, publish edge only for this class. On a release tag, build, boot-test, attest, and publish the final multi-architecture image once. |
| Pages | docs/** or Pages workflow/configuration. | The PR fast layer proves docs/link integrity. After merge, deploy Pages once for matching paths; do not use the deployment as a second general docs test run. |

Keep path classification conservative around shared inputs. In particular, the canonical NAS app payload is copied into NAS, Mac, Linux, and FreeBSD packages, so a change there selects every affected package/container gate. Renderer source, templates/assets, cache runtime, packaging selection logic, or tests/fixtures that can change or judge rendered output select the full active/quiet render gate; unrelated docs, Manager-only, scheduler-only, wrapper-only, or Compose-only changes do not.

### Aggregate required check

- Configure branch protection or the applicable ruleset to require only the stable CI / required context for PR validation. Do not separately require path-optional job names or the path-filtered Container workflow.
- Run the aggregate with if: always() and make it depend on the classifier, fast layer, and every conditional gate. It must succeed only when the classifier and fast layer succeeded and every selected gate succeeded. A conditional gate may be skipped only when the classifier explicitly marked it unnecessary; cancellation, failure, or a missing selected result fails the aggregate.
- Keep job/check names stable or migrate repository protection atomically with a workflow rename. Validate the skipped-job cases on a docs-only PR and the selected-job cases on representative PowerShell, renderer, package, installer, and container changes before making the aggregate required.
- Use concurrency cancellation keyed to the PR number for superseded PR runs, but never let a cancelled latest run satisfy the aggregate. Reuse successful outputs and artifacts within the same SHA/tree instead of rebuilding them in downstream jobs.

### Workflow implementation map

| Responsibility | Implementation |
| --- | --- |
| Event authority and merge provenance | `.github/workflows/ci.yml` jobs `provenance` and `classify` |
| Conservative path classification | `scripts/ci_classifier.py`; unknown executable, build, workflow, or test inputs fail closed |
| Classifier regression coverage | `scripts/test_ci_classifier.py` positive and negative fixtures |
| Stable protection context | `CI / required`, produced by the `required` job with `if: always()` |
| PR container validation and main edge publication | Reusable `.github/workflows/container.yml`, called in validation-only or publication-only mode |
| Pages publication | Reusable `.github/workflows/pages.yml`, called only after `CI / required` succeeds on main |
| Tagged publication | `.github/workflows/release.yml` preflight, single candidate build, installer lifecycle, multiarch container publication, and final release job |

## Local asset optimization before deployment

- Automatically optimize new or changed bundled/local static assets before deployment, using deterministic, format-appropriate lossless tooling.
- Lossless means preserving decoded pixels at the original dimensions, including every composited animation frame, frame timing, loop behavior, transparency, and first-frame fallback. Do not resize, reduce palettes, remove frames, or use lossy compression unless the user explicitly authorizes that exception for the active delivery.
- Verify equivalence and measure before/after byte counts. Keep the original when a verified lossless candidate is not smaller; never inflate an asset merely to claim it was optimized.
- Keep maintained platform copies, aliases, preview mirrors, package manifests, and integrity checks aligned. Perform optimization at development/build time; do not add runtime optimization dependencies or modify fetched Plex/Tautulli artwork.
