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

    document = DocumentParser()
    document.feed(args.html.read_text(encoding="utf-8"))
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
    combined = javascript + "\n" + args.html.read_text(encoding="utf-8")
    for evidence, message in required_dynamic_contracts.items():
        if evidence not in combined:
            failures.append(message)

    if "function renderIntegrationStatus()" not in javascript:
        failures.append("dashboard integration details have no shared verification renderer")
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
    if 'selectView(preferredView || "dashboard");' not in javascript:
        failures.append("Manager does not consistently land on Dashboard after authentication")
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
    for symbol in ("dashboard", "tune", "calendar-clock", "verified", "preview", "settings", "lock", "lock-open", "visibility"):
        if f'id="icon-{symbol}"' not in combined:
            failures.append(f"local Material Symbol missing: {symbol}")
    if "function initializeMaskedInputToggles(" not in javascript or "initializeMaskedInputToggles();" not in javascript:
        failures.append("static masked typing fields do not receive show/hide controls")
    if "function concealMaskedInputs(" not in javascript or ".masked-input-shell" not in css:
        failures.append("masked typing fields do not share concealment and layout behavior")

    if failures:
        for failure in sorted(set(failures)):
            print(f"[FAIL] {failure}")
        return 1
    print(f"[PASS] Manager accessibility structure: {len(ids)} unique IDs, {len(controls)} static controls, local assets only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
