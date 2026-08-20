#!/usr/bin/env python3
"""Dependency-free structural accessibility checks for the embedded Manager UI."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


class Node:
    def __init__(self, tag: str, attrs: list[tuple[str, str | None]], parent: Node | None):
        self.tag = tag
        self.attrs = {name: value or "" for name, value in attrs}
        self.parent = parent
        self.children: list[Node] = []
        self.text: list[str] = []

    def ancestors(self):
        current = self.parent
        while current is not None:
            yield current
            current = current.parent

    def accessible_text(self) -> str:
        if self.attrs.get("aria-hidden", "").lower() == "true":
            return ""
        values = list(self.text)
        values.extend(child.accessible_text() for child in self.children)
        return " ".join(" ".join(values).split())


class DocumentParser(HTMLParser):
    void_elements = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document", [], None)
        self.stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        node = Node(tag, attrs, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in self.void_elements:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in self.void_elements:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.stack[-1].text.append(data)


def descendants(node: Node):
    for child in node.children:
        yield child
        yield from descendants(child)


def local_asset(value: str) -> bool:
    if not value or value.startswith(("#", "data:")):
        return True
    parsed = urlparse(value)
    return not parsed.scheme and not parsed.netloc and not value.startswith("//")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--html", type=Path, default=Path("manager/internal/manager/web/index.html"))
    parser.add_argument("--css", type=Path, default=Path("manager/internal/manager/web/app.css"))
    parser.add_argument("--js", type=Path, default=Path("manager/internal/manager/web/app.js"))
    args = parser.parse_args()

    html = args.html.read_text(encoding="utf-8")
    document = DocumentParser()
    document.feed(html)
    nodes = list(descendants(document.root))
    failures: list[str] = []

    ids: dict[str, Node] = {}
    for node in nodes:
        identifier = node.attrs.get("id", "")
        if not identifier:
            continue
        if identifier in ids:
            failures.append(f"duplicate id: {identifier}")
        ids[identifier] = node

    if not any(node.tag == "main" for node in nodes):
        failures.append("no main landmark")
    if not any(node.tag == "nav" for node in nodes):
        failures.append("no navigation landmark")
    if "main-content" not in ids:
        failures.append("skip-link main-content target is missing")
    skip_links = [node for node in nodes if "skip-link" in node.attrs.get("class", "").split()]
    if len(skip_links) != 1 or skip_links[0].attrs.get("href") != "#main-content":
        failures.append("exactly one skip link must target #main-content")

    labels_by_target = {
        node.attrs["for"]
        for node in nodes
        if node.tag == "label" and node.attrs.get("for")
    }
    controls = [node for node in nodes if node.tag in {"input", "select", "textarea"} and node.attrs.get("type", "").lower() != "hidden"]
    for control in controls:
        identifier = control.attrs.get("id", "")
        nested_label = any(ancestor.tag == "label" for ancestor in control.ancestors())
        named = bool(control.attrs.get("aria-label") or control.attrs.get("aria-labelledby"))
        if not nested_label and identifier not in labels_by_target and not named:
            failures.append(f"unlabelled {control.tag}: {identifier or '<no id>'}")

    for button in (node for node in nodes if node.tag == "button"):
        if not button.attrs.get("aria-label") and not button.attrs.get("aria-labelledby") and not button.accessible_text():
            failures.append(f"button has no accessible name: {button.attrs.get('id', '<no id>')}")

    reference_attributes = ("for", "aria-labelledby", "aria-describedby")
    for node in nodes:
        for attribute in reference_attributes:
            for target in node.attrs.get(attribute, "").split():
                if target and target not in ids:
                    failures.append(f"{attribute} references missing id: {target}")

    for frame in (node for node in nodes if node.tag == "iframe"):
        if not frame.attrs.get("title"):
            failures.append("iframe has no title")
        sandbox = frame.attrs.get("sandbox")
        if sandbox is None:
            failures.append("iframe has no sandbox")
        elif "allow-scripts" in sandbox.split():
            failures.append("preview iframe unexpectedly allows scripts")

    for node in nodes:
        asset = ""
        if node.tag in {"script", "img"}:
            asset = node.attrs.get("src", "")
        elif node.tag == "link":
            asset = node.attrs.get("href", "")
        if asset and not local_asset(asset):
            failures.append(f"external runtime asset: {asset}")

    css = args.css.read_text(encoding="utf-8")
    if ":focus-visible" not in css:
        failures.append("CSS has no focus-visible treatment")
    if "prefers-reduced-motion:reduce" not in css.replace(" ", ""):
        failures.append("CSS has no reduced-motion override")
    if ".skip-link:focus" not in css:
        failures.append("skip link has no visible focus state")
    if "@keyframes schedule-state-swap" not in css:
        failures.append("schedule action state change has no CSS transition")
    if "white-space:nowrap" not in css or "grid-template-rows:auto 44px minmax(1.1rem,auto)" not in css:
        failures.append("Manager lock chip or password fields can distort their layout")
    if ".access-status-button:after" not in css or "content:attr(data-tooltip)" not in css:
        failures.append("access lock control has no downward status tooltip")

    javascript = args.js.read_text(encoding="utf-8")
    required_dynamic_contracts = {
        'document.createElement("label")': "dynamic controls are not created with label elements",
        'setAttribute("aria-invalid", "true")': "dynamic validation does not expose aria-invalid",
        'role="status"': "status live regions are missing from the HTML source",
    }
    combined = javascript + "\n" + html
    for evidence, message in required_dynamic_contracts.items():
        if evidence not in combined:
            failures.append(message)

    if "function renderIntegrationStatus()" not in javascript:
        failures.append("dashboard integration details have no shared verification renderer")
    if "function configFieldIsHidden(field)" not in javascript or 'isServiceRuntime() && field.name === "ScheduledTaskName"' not in javascript:
        failures.append("service Manager modes do not suppress the Windows Scheduled Task configuration field")
    for marker in (
        'function isMacDocker()',
        'runtimeMode() === "mac"',
        'macOS Docker Desktop',
        './tautweekly.sh manager-bootstrap',
        './tautweekly.sh manager-reset-access',
    ):
        if marker not in javascript:
            failures.append(f"macOS Manager capability copy is missing: {marker}")
    if "function retainedSetupCheckState(" not in javascript or 'last?.overall || retainedLANState' not in javascript:
        failures.append("dashboard integrations do not fall back to retained save-verification state")
    if javascript.count("renderIntegrationStatus();") < 2:
        failures.append("status and verification refreshes do not share integration evidence")
    if "snapshot.integrations.tautulli" in javascript:
        failures.append("runtime status can overwrite live integration evidence with stale defaults")
    if 'setSwappingText("schedule-install-heading", installLabel);' not in javascript:
        failures.append("schedule action heading does not switch between Install and Refresh")
    if 'setSwappingText("schedule-install-button-label", installLabel);' not in javascript:
        failures.append("schedule action button does not switch between Install and Refresh")
    if "function setSwappingText(" not in javascript or "schedule-state-swap" not in javascript:
        failures.append("schedule action state change has no animated text transition")
    if "function setSwappingButtonText(" not in javascript or javascript.count("setSwappingButtonText(") < 8:
        failures.append("dynamic Manager buttons do not share the state-swap animation")
    if 'area === "lan-verification" ? "Connection Verification"' not in javascript:
        failures.append("retained verification diagnostics expose an internal LAN label")
    if 'id="metadata-readiness-confirm"' in combined or "metadataReady" in javascript:
        failures.append("automatic preview generation is still blocked by a separate readiness gate")
    if 'runPostSaveSetup(result.editor.revision);' not in javascript or 'type: "preview-all"' not in javascript:
        failures.append("validated configuration saves do not automatically start local previews")
    if "window.TautWeeklyUpdateUI.routeFromHash(window.location.hash)" not in javascript or "updateHistory: false" not in javascript:
        failures.append("Manager does not restore a local route safely after authentication")
    if 'id="first-time-setup"' not in combined or 'data-open-view="configuration"' not in combined:
        failures.append("Dashboard has no direct first-time setup route to Config")
    if 'state.editor?.state === "unconfigured"' not in javascript or 'prompt.hidden = !firstRun;' not in javascript:
        failures.append("first-time setup prompt is not limited to unconfigured installations")
    if 'id="dashboard-greeting"' not in combined or "function renderDashboardGreeting(" not in javascript:
        failures.append("Dashboard has no last-observed time greeting")
    if "minuteOfDay >= 360 && minuteOfDay <= 720" not in javascript or "minuteOfDay >= 721 && minuteOfDay <= 1080" not in javascript:
        failures.append("Dashboard greeting does not implement the requested morning and afternoon boundaries")
    if 'suggestedPreviewUserId' not in javascript or 'name ? `${greeting}, ${name}.` : `${greeting}.`' not in javascript:
        failures.append("Dashboard greeting lacks the unambiguous administrator-name fallback")
    if 'id="access-status-button"' not in combined or 'addEventListener("click", openAccessSettings)' not in javascript:
        failures.append("access lock status does not route to password settings")
    if 'return "Container access"' not in javascript or 'return "Browser access"' not in javascript:
        failures.append("access lock tooltip is not platform-aware")
    for control in ("startup-manager", "startup-dashboard", "startup-settings-controls", "startup-settings-message"):
        if f'id="{control}"' not in combined:
            failures.append(f"Manager startup settings omit accessible control: {control}")
    if 'id="startup-settings-save"' in combined or 'submitStartupSettings' in javascript:
        failures.append("Manager startup settings still require a redundant save button")
    if 'request("/api/v1/startup")' not in javascript or 'method: "PUT"' not in javascript:
        failures.append("Manager startup settings do not read and write the typed API")
    if 'dashboardToggle.disabled = state.startupSaving || unavailable || !managerToggle.checked;' not in javascript:
        failures.append("Open Dashboard after sign-in is not visibly dependent on Manager startup")
    if 'const savedManagerEnabled = Boolean(startup.startManager);' not in javascript:
        failures.append("Manager startup badge follows unsaved form state instead of the saved setting")
    if 'label.className = "state-chip-label";' not in javascript:
        failures.append("state badges do not inherit the smooth shared text transition")
    if 'chip.replaceChildren(...(iconName ?' in javascript or 'chip.insertBefore(nextIcon, label);' not in javascript:
        failures.append("unchanged state badges are detached and replay their animation during form edits")
    if '#startup-settings-chip{animation:none}' not in css:
        failures.append("Manager startup saved-state badge inherits a looping status animation")
    if 'state.startupDraft = requested;' not in javascript or 'body: JSON.stringify(requested)' not in javascript:
        failures.append("Manager startup toggles do not retain an atomic optimistic selection while saving")
    if 'state.startupError = error.message;' not in javascript or 'state.startupDraft = null;' not in javascript:
        failures.append("Manager startup toggle failures do not restore saved state with a truthful error")
    if 'panel.setAttribute("aria-busy", String(state.startupSaving));' not in javascript:
        failures.append("Manager startup controls do not expose their brief busy state accessibly")
    if '.startup-setting{display:flex' not in css or 'cursor:pointer;transition:opacity .18s ease}' not in css:
        failures.append("Manager startup toggle availability does not transition smoothly")
    for control in (
        "tailscale-settings-panel",
        "tailscale-settings-chip",
        "tailscale-enabled",
        "tailscale-host-authorization",
        "tailscale-copy-authorization",
        "tailscale-external-setup",
        "tailscale-external-url",
        "tailscale-private-confirm",
        "tailscale-external-guide",
        "tailscale-serve-status",
        "tailscale-url",
        "tailscale-password-status",
        "tailscale-refresh-button",
        "tailscale-setup-link",
        "tailscale-provider-warning",
        "tailscale-copy-button",
        "tailscale-settings-message",
    ):
        if f'id="{control}"' not in combined:
            failures.append(f"Tailscale remote access card omits accessible control: {control}")
    for marker in (
        'request("/api/v1/remote-access/tailscale")',
        'method: "PUT"',
        'confirmedPrivate: external ? byId("tailscale-private-confirm").checked : false',
        'navigator.clipboard.writeText(state.tailscale.url)',
        'panel.setAttribute("aria-busy", String(state.tailscaleSaving));',
    ):
        if marker not in javascript:
            failures.append(f"Tailscale remote access interaction contract is missing: {marker}")
    if "Enable HTTPS certificates only." not in combined or "Turn Funnel off before continuing" not in combined:
        failures.append("Tailscale provider approval does not explicitly require HTTPS-only consent with Funnel off")
    if "No credentials belong here." not in combined or "remote.hostAuthorizationCommand === \"sudo tautweekly remote-access-authorize\"" not in javascript:
        failures.append("Tailscale adapters do not keep credentials out of Manager or pin Linux host authorization to the packaged command")
    if 'remote.management === "external"' not in javascript or 'remote.management' not in javascript:
        failures.append("Tailscale card does not distinguish integrated and host-managed package adapters")
    if 'panel.classList.toggle("enabled-glow", Boolean(remote.enabled && remote.active));' not in javascript:
        failures.append("Active Tailscale state does not drive the full-card glow")
    if ".tailscale-settings-panel.enabled-glow" not in css or "prefers-reduced-motion:reduce" not in css:
        failures.append("Active Tailscale card glow lacks its motion-safe styling contract")
    if '.tailscale-settings-panel' not in css or '.tailscale-status-grid' not in css or '.tailscale-security-boundary' not in css:
        failures.append("Tailscale remote access card lacks its responsive security treatment")
    if "function materializeMaterialIcons(" not in javascript or "materializeMaterialIcons();" not in javascript:
        failures.append("local Material Symbols are not materialized for embedded-webview compatibility")
    if 'accessButton.replaceChildren(createMaterialIcon(locked ? "lock" : "lock-open"));' not in javascript:
        failures.append("access lock icon state can target a removed SVG use element")
    if 'request("/api/v1/config/status")' not in javascript:
        failures.append("configuration status is not loaded from durable Manager state")
    if 'request("/api/v1/config/status/previews/skipped"' not in javascript:
        failures.append("automatic preview skips are not retained by the Manager")
    if 'id="configuration-status-card"' not in combined or "function renderDashboardConfigStatus()" not in javascript:
        failures.append("Dashboard has no durable Config status health card")
    for step in ("choices", "lan", "smtp", "previews"):
        if f'id="configuration-status-{step}"' not in combined:
            failures.append(f"Dashboard Config status omits step: {step}")
        if f'id="setup-{step}-step"' not in combined:
            failures.append(f"Config setup workflow omits permanent step card: {step}")
    for symbol in ("dashboard", "tune", "calendar-clock", "verified", "preview", "settings", "lock", "lock-open", "deployed-code-update", "visibility"):
        if f'id="icon-{symbol}"' not in combined:
            failures.append(f"local Material Symbol missing: {symbol}")
    if "function initializeMaskedInputToggles(" not in javascript or "initializeMaskedInputToggles();" not in javascript:
        failures.append("static masked typing fields do not receive show/hide controls")
    if "function concealMaskedInputs(" not in javascript or ".masked-input-shell" not in css:
        failures.append("masked typing fields do not share concealment and layout behavior")
    if "function renewTrustedLocalSession(" not in javascript or "return await request(path, options, false);" not in javascript:
        failures.append("trusted-local sessions do not recover once after a Manager restart")
    if "function reloadAfterTrustedLocalRestart(" not in javascript or "window.location.reload();" not in javascript:
        failures.append("trusted-local restart races do not recover without a manual refresh")
    if "const authBootstrapEndpoint =" not in javascript or 'path.startsWith("/api/v1/auth/")' in javascript:
        failures.append("protected access-policy requests are incorrectly excluded from session recovery")
    if 'id="manual-send-runner-heading"' not in combined or 'id="manual-send-status"' not in combined:
        failures.append("Preview center has no guarded production delivery and retained status cards")
    for control in (
        "update-settings-panel",
        "update-status-button",
        "update-settings-chip",
        "update-manager-version",
        "update-latest-version",
        "update-platform",
        "update-edition",
        "update-release-alignment",
        "update-host-adapter-row",
        "update-host-adapter",
        "update-channel",
        "update-last-success",
        "update-check-button",
        "update-guidance-summary",
        "update-copy-command",
        "update-install-confirm",
        "update-install-button",
        "update-settings-message",
    ):
        if f'id="{control}"' not in combined:
            failures.append(f"Settings update card omits accessible control: {control}")
    if 'class="build-details"' in combined or 'id="update-application-version"' in combined or 'id="update-package-version"' in combined:
        failures.append("Manager and package identity is still duplicated outside the consolidated update status surface")
    if "function releaseAlignmentSummary(" not in javascript or 'matching.length === 1 ? "matches" : "match"' not in javascript:
        failures.append("application and package release alignment is not summarized without duplicate version values")
    update_surfaces = (
        ("Manager", html, javascript, css),
        (
            "GUI preview",
            Path("docs/gui-preview/index.html").read_text(encoding="utf-8"),
            Path("docs/gui-preview/app.js").read_text(encoding="utf-8"),
            Path("docs/gui-preview/app.css").read_text(encoding="utf-8"),
        ),
    )
    expected_update_labels = (
        "Manager build",
        "Latest stable",
        "Platform",
        "Edition",
        "Release alignment",
        "Host adapter",
        "Update channel",
        "Last successful check",
    )
    for surface, surface_html, surface_javascript, surface_css in update_surfaces:
        grid_start = surface_html.find('<dl class="update-version-grid host-adapter-hidden">')
        grid_end = surface_html.find("</dl>", grid_start)
        grid_html = surface_html[grid_start:grid_end] if grid_start >= 0 and grid_end >= 0 else ""
        label_positions = [grid_html.find(f"<dt>{label}</dt>") for label in expected_update_labels]
        if not grid_html or any(position < 0 for position in label_positions) or label_positions != sorted(label_positions):
            failures.append(f"{surface} update fields do not use the approved visible order")
        if "Package baseline" in surface_html or "update-package-baseline" in surface_html + surface_javascript:
            failures.append(f"{surface} still exposes the deprecated Package baseline field")
        if "Release layers" in surface_html or "update-release-layers" in surface_html + surface_javascript:
            failures.append(f"{surface} still exposes the replaced Release layers label or ID")
        if 'id="update-host-adapter-row" hidden' not in grid_html:
            failures.append(f"{surface} host adapter is visible before applicability is known")
        for marker in (
            'Boolean(update.hostAdapterState) && update.hostAdapterState !== "not-applicable"',
            "hostAdapterRow.hidden = !hostAdapterApplicable;",
            'classList.toggle("host-adapter-hidden", !hostAdapterApplicable)',
            'if (hostAdapterApplicable) {',
        ):
            if marker not in surface_javascript:
                failures.append(f"{surface} host-adapter visibility contract is missing: {marker}")
        for marker in (
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:span 2}",
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:1/-1}",
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:auto}",
        ):
            if marker not in surface_css:
                failures.append(f"{surface} conditional update grid reflow is missing: {marker}")
    for marker in (
        'request("/api/v1/updates")',
        'request("/api/v1/updates/check", { method: "POST", body: "{}" })',
        'request("/api/v1/updates/install", { method: "POST", body: "{}" })',
        'navigator.clipboard.writeText(command)',
        '!byId("update-install-confirm").checked',
    ):
        if marker not in javascript:
            failures.append(f"Settings update interaction contract is missing: {marker}")
    if "function pollUpdateInstall()" not in javascript or "updateInstallPollTimer = setTimeout(pollUpdateInstall" not in javascript:
        failures.append("verified update installation has no automatic status transition")
    if 'id="update-status-button"' not in combined or 'aria-controls="update-settings-panel"' not in combined:
        failures.append("header update notification does not expose its Settings target")
    if 'id="update-settings-heading" tabindex="-1"' not in combined or 'byId("update-settings-heading").focus' not in javascript:
        failures.append("header update notification does not move focus to the status heading")
    if 'addEventListener("click", openUpdateSettings)' not in javascript or 'selectView("about", { section: "updates" });' not in javascript:
        failures.append("header update notification does not route to the consolidated status section")
    if 'addEventListener("popstate", applyLocationRoute)' not in javascript or 'addEventListener("hashchange", applyLocationRoute)' not in javascript:
        failures.append("Manager update route does not preserve browser back and forward navigation")
    if "function checkForUpdatesInBackground()" not in javascript or "backgroundUpdateCheckAttempted" not in javascript:
        failures.append("authenticated Manager entry does not bound background checks to one attempt")
    if 'state.updates?.backgroundCheckRecommended' not in javascript or 'void runUpdateCheck(true);' not in javascript:
        failures.append("background update refresh is not gated by server cache freshness and backoff")
    if 'Update available — Version' in args.html.read_text(encoding="utf-8"):
        failures.append("static header markup exposes a stale update version before validated state is rendered")
    if ".update-status-button" not in css or "color:var(--violet)" not in css or "animation:hero-pulse" not in css:
        failures.append("header update notification does not reuse the violet badge and established halo pulse")
    if 'case "update-available": return { label: "Update available", tone: "update-available"' not in javascript or ".state-chip.update-available" not in css or "animation:state-pulse-update" not in css:
        failures.append("update-available status chip does not use the dedicated violet pulse")
    if "forced-colors:active" not in css or ".update-status-halo{animation:none!important" not in css:
        failures.append("header update notification does not preserve forced-colors and reduced-motion behavior")
    if ".topbar .brand-lockup>div{display:none}" not in css:
        failures.append("narrow mobile header does not preserve space for lock and update controls")
    if '.update-settings-panel' not in css or '.update-command' not in css or '.update-install-confirm' not in css:
        failures.append("Settings update card lacks its responsive and accessible visual treatment")
    if 'const toggle = document.createElement("label");' not in javascript or "toggle.htmlFor = id;" not in javascript:
        failures.append("generated boolean switches do not associate their full visible surface with the checkbox")
    if ".config-control-boolean .config-toggle{width:max-content;cursor:pointer" not in css:
        failures.append("generated boolean switches do not expose a full clickable pointer surface")
    if 'value="send-all"' not in combined or 'value="send-welcome"' not in combined:
        failures.append("manual production delivery does not expose both all-recipient and Manual Welcome scopes")
    if 'type === "send-welcome"' not in javascript or "confirmProductionSend: true" not in javascript:
        failures.append("manual production delivery does not use the fixed confirmed operation contracts")
    if 'id="manual-send-user-id"' not in combined or 'state.history.find((candidate) => manualTypes.has(candidate.type))' not in javascript:
        failures.append("Manual Welcome lacks selected-user input or shared sanitized status")
    if 'id="direct-plex-notice"' not in combined or "legacyFieldsMissing" not in javascript:
        failures.append("legacy direct Plex omissions have no guided completion message")
    for marker in (
        'method: "DELETE"',
        'setSwappingButtonElementText(deleteButton, "Confirm delete")',
        'Permanently delete configuration backup from',
        'Deletion is manual, confirmed, and permanent.',
    ):
        if marker not in combined:
            failures.append(f"configuration backup deletion contract is missing: {marker}")
    if "legacyRuleExcluded" not in javascript or "Excluded by existing config" not in javascript:
        failures.append("legacy email exclusions are not represented in guided delivery choices")
    if 'status.className = changed ? "discovery-selected-count" : "discovery-excluded-count"' not in javascript or "rgba(255,122,114,.48)" not in css:
        failures.append("guided delivery choices do not show the requested effective exclusion count")
    if 'status.textContent = `${effective} ${changed ? "selected" : "excluded"}`' not in javascript or ".discovery-selected-count{color:var(--gold-bright)" not in css:
        failures.append("guided delivery choices do not distinguish unsaved selections from saved exclusions")
    if "const orderedUsers = [...users].sort" not in javascript or "leftExcluded ? -1 : 1" not in javascript:
        failures.append("configured delivery exclusions are not grouped visibly at the top of discovered users")
    if ".user-combobox>input" not in css or ".manual-send-mode-field select{border-color:var(--line-strong)" not in css:
        failures.append("guided user and delivery-mode selectors do not share consistent control styling")
    if 'input.addEventListener("click"' not in javascript or 'if (open) input.focus();' not in javascript:
        failures.append("guided user selectors do not open from the full input field for typing or mouse selection")
    if 'card.hidden = !manualSend;' not in javascript:
        failures.append("manual production status is visible before a manual send exists")
    if 'card.hidden = manualSend;' not in javascript:
        failures.append("manual production delivery is duplicated in the generic current-run card")
    for label in ("Index", "Manual Welcome", "New User - No History", "New User - With History", "Normal Newsletter", "Established Quiet", "Established Warnings"):
        if label not in javascript:
            failures.append(f"preview scenario label is missing: {label}")
    if "function orderedPreviews(" not in javascript or "previewScenarioIndex(left) - previewScenarioIndex(right)" not in javascript:
        failures.append("available previews are not rendered in deterministic scenario order")
    if "function initializePreviewIndexNavigation()" not in javascript or 'link.addEventListener("click"' not in javascript:
        failures.append("preview index links do not select their scenario in the existing authenticated viewer")

    if failures:
        for failure in sorted(set(failures)):
            print(f"[FAIL] {failure}")
        return 1
    print(f"[PASS] Manager accessibility structure: {len(ids)} unique IDs, {len(controls)} static controls, local assets only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
