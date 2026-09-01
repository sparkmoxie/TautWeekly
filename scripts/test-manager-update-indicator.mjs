#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionHelper = path.join(repositoryRoot, "manager", "internal", "manager", "web", "update-ui.js");
const previewHelper = path.join(repositoryRoot, "docs", "gui-preview", "update-ui.js");
const require = createRequire(import.meta.url);
const updateUI = require(productionHelper);

assert.equal(fs.readFileSync(productionHelper, "utf8"), fs.readFileSync(previewHelper, "utf8"), "production and preview update UI helpers diverged");

const checked = {
  state: "update-available",
  managerVersion: "1.2.3",
  applicationVersion: "1.2.3",
  packageVersion: "1.2.3",
  hostAdapterState: "current",
  updateChannel: "stable",
  latestStableVersion: "1.3.0",
  updateAvailable: true,
  checkInProgress: false,
  lastSuccessfulCheckUtc: "2031-04-18T16:30:00Z",
};

const visible = updateUI.updateIndicator(checked);
assert.deepEqual(visible, { visible: true, version: "v1.3.0", label: "Update available — Version v1.3.0" });
assert.equal(updateUI.updateIndicator({ ...checked, checkInProgress: true }).visible, true, "validated cached state disappeared during refresh");
const cooldownStart = Date.parse("2031-04-18T16:31:00Z");
assert.deepEqual(updateUI.updateCheckCooldown({ nextCheckAllowedAtUtc: "2031-04-18T16:35:00Z" }, cooldownStart), {
  active: true,
  delayMilliseconds: 4 * 60 * 1000,
});
assert.deepEqual(updateUI.updateCheckCooldown(
  { nextCheckAllowedAtUtc: "2031-04-18T16:35:00.987Z" },
  Date.parse("2031-04-18T16:30:00.500Z"),
), { active: true, delayMilliseconds: 300487 }, "fixed-millisecond cooldown timestamp lost precision");
assert.deepEqual(updateUI.updateCheckCooldown({ nextCheckAllowedAtUtc: "2031-04-18T16:35:00Z" }, cooldownStart + 4 * 60 * 1000), { active: false, delayMilliseconds: 0 });
assert.deepEqual(updateUI.updateCheckCooldown({ nextCheckAllowedAtUtc: "invalid" }, cooldownStart), { active: false, delayMilliseconds: 0 });

const hiddenCases = {
  current: { ...checked, state: "current", latestStableVersion: "1.2.3", updateAvailable: false },
  "checking without result": { checkInProgress: true, state: "unknown", updateChannel: "stable" },
  unknown: { ...checked, state: "unknown", updateAvailable: false },
  "offline error only": { state: "unknown", updateChannel: "stable", lastFailure: { code: "offline" } },
  "invalid metadata": { ...checked, latestStableVersion: "not-a-version" },
  "rollback or downgrade": { ...checked, state: "newer", latestStableVersion: "1.0.0", updateAvailable: false },
  "mismatched state": { ...checked, state: "mismatched" },
  "mismatched package layer": { ...checked, packageVersion: "1.2.2" },
  "mismatched image layer": { ...checked, imageVersion: "1.2.2" },
  "legacy wrapper": { ...checked, state: "legacy", hostAdapterState: "legacy" },
  "unsupported channel": { ...checked, updateChannel: "unsupported" },
  "unvalidated flag": { ...checked, updateAvailable: false },
  "missing successful check": { ...checked, lastSuccessfulCheckUtc: "" },
  "prerelease metadata": { ...checked, latestStableVersion: "1.3.0-rc.1" },
  "post-update current build": { ...checked, applicationVersion: "1.3.0", managerVersion: "1.3.0", packageVersion: "1.3.0" },
};
for (const [name, value] of Object.entries(hiddenCases)) {
  assert.equal(updateUI.updateIndicator(value).visible, false, `${name} exposed the header indicator`);
}

assert.equal(updateUI.updateIndicator({ ...checked, managerVersion: "1.3.0-rc.1", applicationVersion: "1.3.0-rc.1", packageVersion: "1.3.0-rc.1", latestStableVersion: "1.3.0" }).visible, true, "prerelease running build did not advance to validated stable");
for (const packageKind of ["windows-installer", "linux-native", "mac-docker", "freebsd-podman", "nas-docker", "qnap-container-station", "unraid", "docker-compatible"]) {
  assert.equal(updateUI.updateIndicator({ ...checked, packageKind }).visible, true, `${packageKind} did not share the common Manager indicator`);
}

assert.deepEqual(updateUI.routeFromHash("#settings/application-and-package-status"), { view: "about", section: "updates" });
assert.deepEqual(updateUI.routeFromHash("#settings/tailscale-funnel"), { view: "about", section: "tailscale" });
assert.deepEqual(updateUI.routeFromHash("#settings"), { view: "about", section: "" });
assert.deepEqual(updateUI.routeFromHash("#configuration"), { view: "configuration", section: "" });
assert.deepEqual(updateUI.routeFromHash("#pair=synthetic-token"), { view: "dashboard", section: "" });
assert.equal(updateUI.hashForRoute("about", "updates"), "#settings/application-and-package-status");
assert.equal(updateUI.hashForRoute("about", "tailscale"), "#settings/tailscale-funnel");
assert.equal(updateUI.hashForRoute("about"), "#settings");

const productionHTML = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "index.html"), "utf8");
const previewHTML = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "index.html"), "utf8");
const productionCSS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.css"), "utf8");
const productionJS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js"), "utf8");
const previewCSS = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "app.css"), "utf8");
const previewJS = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "app.js"), "utf8");
const previewMock = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "mock-api.js"), "utf8");

const funnelDefinitionsStart = productionJS.indexOf("const funnelIntegrationStates");
const funnelDefinitionsEnd = productionJS.indexOf("\nfunction renderStatus()", funnelDefinitionsStart);
assert.ok(funnelDefinitionsStart >= 0 && funnelDefinitionsEnd > funnelDefinitionsStart, "Funnel Dashboard presentation functions are missing");
const tailscaleStateStart = productionJS.indexOf("function tailscaleStatePresentation(remote)");
const tailscaleStateEnd = productionJS.indexOf("\nfunction validTailscaleURL", tailscaleStateStart);
assert.ok(tailscaleStateStart >= 0 && tailscaleStateEnd > tailscaleStateStart, "Funnel Settings state presentation is missing");
const funnelDefinitions = productionJS.slice(funnelDefinitionsStart, funnelDefinitionsEnd) +
  "\n" + productionJS.slice(tailscaleStateStart, tailscaleStateEnd);
assert.doesNotMatch(funnelDefinitions, /request\(/, "ordinary Dashboard rendering can invoke a Funnel API or provider operation");
const funnelContext = vm.createContext({ console });
const funnelHarnessSource = [
  "let state = {};",
  "const elements = new Map();",
  "function element(id) {",
  "  if (!elements.has(id)) elements.set(id, {",
  "    className: \"\", textContent: \"\", attributes: {}, dataset: {},",
  "    classList: { values: {}, toggle(name, enabled) { this.values[name] = Boolean(enabled); } },",
  "    setAttribute(name, value) { this.attributes[name] = value; },",
  "  });",
  "  return elements.get(id);",
  "}",
  "function byId(id) { return element(id); }",
  "function setText(id, value) { element(id).textContent = value; }",
  "function setChip(id, label, tone) { Object.assign(element(id), { label, tone }); }",
  "function titleCase(value) { return String(value || \"\").split(/[- ]/).filter(Boolean).map((part) => part[0].toUpperCase() + part.slice(1)).join(\" \"); }",
].join("\n") + "\n" + funnelDefinitions + "\n" + [
  "globalThis.funnelDashboardTest = {",
  "  present(remote) { return JSON.parse(JSON.stringify(funnelIntegrationPresentation(remote))); },",
  "  render(remote) {",
  "    elements.clear();",
  "    state = {",
  "      tailscale: remote,",
  "      verification: {",
  "        last: { overall: \"passed\", steps: [{ service: \"tautulli\", state: \"passed\" }, { service: \"plex\", state: \"passed\" }] },",
  "        smtp: { overall: \"passed\", state: \"passed\" },",
  "      },",
  "      setupWorkflow: null,",
  "      verificationRunning: false,",
  "      smtpVerificationRunning: false,",
  "    };",
  "    const result = renderIntegrationStatus();",
  "    return JSON.parse(JSON.stringify({",
  "      result,",
  "      chip: element(\"integration-chip\"),",
  "      funnelState: element(\"funnel-state\").textContent,",
  "      funnelDetail: element(\"funnel-detail\").textContent,",
  "      funnelValue: element(\"funnel-integration-value\"),",
  "      funnelLink: element(\"funnel-settings-link\"),",
  "      tailscaleButton: element(\"tailscale-status-button\"),",
  "    }));",
  "  },",
  "};",
].join("\n");
vm.runInContext(funnelHarnessSource, funnelContext);

const funnelBase = { supported: true, installed: true, enabled: false, active: false, state: "inactive" };
const funnelMatrix = [
  ["safely off", funnelBase, "Passed", "Off", "good", "passed", "Passed", "good"],
  ["verified active", { ...funnelBase, enabled: true, active: true, state: "active", cleanupRequired: true }, "Passed", "Active", "good", "passed", "Passed", "good"],
  ["publication pending", { ...funnelBase, enabled: true, state: "starting", cleanupRequired: true }, "Attention", "Publication pending", "publication-pending", "warning", "Attention", "warning"],
  ["password lock missing while enabled", { ...funnelBase, enabled: true, state: "manager-password-required", passwordRequired: true, cleanupRequired: true }, "Failed", "password lock required", "bad", "failed", "Failed", "bad"],
  ["route mismatch", { ...funnelBase, enabled: true, state: "needs-attention", cleanupRequired: true }, "Failed", "verification failed", "bad", "failed", "Failed", "bad"],
  ["failed cleanup", { ...funnelBase, state: "needs-attention", cleanupRequired: true }, "Failed", "cleanup or verification required", "bad", "failed", "Failed", "bad"],
  ["unsupported surface", { supported: false, installed: false, enabled: false, active: false, state: "unsupported" }, "Not applicable", "Unsupported", "neutral", "", "Passed", "good"],
  ["not configured", { ...funnelBase, installed: false, state: "tailscale-required" }, "Not configured", "Not configured", "neutral", "", "Passed", "good"],
  ["malformed retained state", { ...funnelBase, state: "private-raw-state" }, "Failed", "retained status invalid", "bad", "failed", "Failed", "bad"],
];
for (const [name, remote, label, detail, tone, outcome, overallLabel, overallTone] of funnelMatrix) {
  const presentation = funnelContext.funnelDashboardTest.present(remote);
  assert.equal(presentation.label, label, name);
  assert.match(presentation.detail, new RegExp(detail, "i"), name);
  assert.equal(presentation.tone, tone, name);
  assert.equal(presentation.outcome, outcome, name);
  const rendered = funnelContext.funnelDashboardTest.render(remote);
  assert.equal(rendered.chip.label, overallLabel, name + " aggregate label");
  assert.equal(rendered.chip.tone, overallTone, name + " aggregate tone");
  assert.equal(rendered.funnelState, label, name + " visible row label");
  assert.match(rendered.funnelValue.attributes["aria-label"], new RegExp(label, "i"), name + " accessible row label");
  assert.match(rendered.funnelLink.dataset.tooltip, /Tailscale Funnel/, name + " animated navigation tooltip");
  const badgeActive = remote.state === "active" || remote.state === "starting";
  assert.equal(rendered.tailscaleButton.classList.values.active, badgeActive, name + " header badge active appearance");
  assert.equal(rendered.tailscaleButton.classList.values.off, !badgeActive, name + " header badge off appearance");
  const expectedBadgeState = remote.state === "inactive" ? "Off"
    : remote.state === "unsupported" ? "Unsupported"
      : remote.state === "starting" ? "Publication pending"
        : remote.state === "active" ? "Active"
          : remote.state === "manager-password-required" ? "Password required"
            : remote.state === "needs-attention" ? "Needs attention"
              : remote.state === "tailscale-required" ? "Tailscale required"
                : "Unavailable";
  assert.equal(rendered.tailscaleButton.dataset.tooltip, `Tailscale Funnel: ${expectedBadgeState}`, name + " exact-state header tooltip");
}
const loadingBadge = funnelContext.funnelDashboardTest.render(null).tailscaleButton;
assert.equal(loadingBadge.classList.values.active, false, "loading retained Funnel state used active badge appearance");
assert.equal(loadingBadge.classList.values.off, true, "loading retained Funnel state omitted off badge appearance");
assert.equal(loadingBadge.dataset.tooltip, "Tailscale Funnel: Checking retained status", "loading badge tooltip is not truthful");
const sanitizedPresentation = funnelContext.funnelDashboardTest.present({
  ...funnelBase,
  enabled: true,
  active: true,
  state: "active",
  url: "https://private-device.example.ts.net/?token=secret",
  errorCode: "private-tailnet-identity",
  rawOutput: "secret provider output",
});
assert.equal(JSON.stringify(sanitizedPresentation), JSON.stringify({ label: "Passed", detail: "Active", tone: "good", outcome: "passed" }));
assert.doesNotMatch(JSON.stringify(sanitizedPresentation), /secret|private-device|tailnet-identity|provider output/i, "Dashboard Funnel row disclosed provider or private state");
const loadTailscaleStart = productionJS.indexOf("async function loadTailscaleAccess()");
const loadTailscaleEnd = productionJS.indexOf("\nasync function copyTailscaleURL", loadTailscaleStart);
const loadTailscaleSource = productionJS.slice(loadTailscaleStart, loadTailscaleEnd);
assert.match(loadTailscaleSource, /request\("\/api\/v1\/remote-access\/tailscale"\)/, "Dashboard does not reuse the retained typed Funnel status endpoint");
assert.doesNotMatch(loadTailscaleSource, /\/verify|method:\s*"(?:POST|PUT)"/, "passive Funnel status loading can trigger verification or mutation");
assert.match(productionHTML, /id="icon-deployed-code-update"/);
const tailscaleButtonStart = productionHTML.indexOf('id="tailscale-status-button"');
const tailscaleButtonEnd = productionHTML.indexOf("</button>", tailscaleButtonStart);
const tailscaleButton = productionHTML.slice(tailscaleButtonStart, tailscaleButtonEnd);
assert.notEqual(tailscaleButtonStart, -1);
assert.notEqual(tailscaleButtonEnd, -1);
assert.match(tailscaleButton, /class="tailscale-logo" viewBox="0 0 512 512"/);
assert.equal((tailscaleButton.match(/<path/g) || []).length, 7);
assert.equal((tailscaleButton.match(/class="tailscale-fade"/g) || []).length, 4);
assert.doesNotMatch(tailscaleButton, /<use/);
assert.match(productionHTML, /id="tailscale-status-button"[^>]+class="access-status-button tailscale-status-button off"|class="access-status-button tailscale-status-button off"[^>]+id="tailscale-status-button"/);
assert.match(productionHTML, /id="funnel-settings-link"[^>]+data-tooltip=/);
assert.doesNotMatch(productionHTML, /id="funnel-settings-link"[^>]+title=/);
assert.match(productionHTML, /id="update-status-button"[^>]+aria-controls="update-settings-panel"[^>]+hidden/);
assert.match(productionHTML, /id="update-settings-heading" tabindex="-1"/);
assert.match(productionCSS, /[.]tailscale-settings-panel{scroll-margin-top:90px/);
assert.match(productionCSS, /[.]metric-link{[^}]*border:0[^}]*transition:[^}]*cubic-bezier/);
assert.match(productionCSS, /[.]metric-link:after{content:attr\(data-tooltip\)/);
assert.match(productionCSS, /[.]tailscale-status-button [.]tailscale-logo{[^}]*display:block/);
assert.match(productionCSS, /[.]tailscale-status-button [.]tailscale-logo path{fill:#f0f0f0;opacity:[.]2/);
assert.match(productionCSS, /[.]tailscale-status-button[.]active [.]tailscale-logo path:not\([.]tailscale-fade\){opacity:1}/);
assert.match(productionCSS, /[.]tailscale-status-button[.]active [.]tailscale-fade{opacity:[.]2}/);
assert.match(productionJS, /const active = settingsAvailable && remote\.enabled === true &&\s+\(\(remote\.state === "active" && remote\.active === true\) \|\| remote\.state === "starting"\)/);
assert.doesNotMatch(productionJS, /funnelValue\.title|funnelLink\.disabled/);
assert.match(productionCSS, /[.]update-status-button{[^}]*border-color:rgba\(114,174,247,[.]44\)[^}]*color:var\(--blue\)[^}]*background:rgba\(114,174,247,[.]1\)/);
assert.match(productionCSS, /animation:hero-pulse 2\.9s ease-out infinite/);
for (const [name, css, javascript] of [["production", productionCSS, productionJS], ["preview", previewCSS, previewJS]]) {
  assert.match(javascript, /case "update-available": return \{ label: "Update available", tone: "update-available"/, `${name} update state does not select the dedicated purple tone`);
  assert.match(javascript, /classList\.toggle\("update-attention-glow", update\.state !== "current"\)/, `${name} update card glow does not follow the non-current state`);
  assert.match(css, /\.state-chip\.update-available\{[^}]*color:var\(--violet\)[^}]*animation:state-pulse-update 2\.9s ease-in-out infinite/, `${name} update chip is not purple with a pulse`);
  assert.match(css, /@keyframes state-pulse-update\{[^}]+rgba\(173,140,255/, `${name} update chip pulse is not purple`);
  assert.match(css, /\.update-settings-panel\.update-attention-glow:before\{[^}]*animation:update-panel-pulse 2\.9s ease-out infinite/, `${name} non-current update card background does not pulse`);
  assert.match(css, /@keyframes update-panel-pulse\{0%,100%\{opacity:\.42\}50%\{opacity:1\}\}/, `${name} update card pulse is missing`);
  assert.match(css, /prefers-reduced-motion:reduce.*?update-settings-panel\.update-attention-glow:before/s, `${name} update card glow lacks reduced-motion support`);
  assert.match(css, /forced-colors:active[^}]+\.state-chip\.update-available/, `${name} update chip lacks forced-colors support`);
  assert.match(css, /forced-colors:active.*?\.update-settings-panel\.update-attention-glow/s, `${name} update card glow lacks forced-colors support`);
  assert.match(javascript, /scheduleUpdateCheckAvailabilityRefresh\(cooldown\)/, `${name} update cooldown has no automatic expiry render`);
  assert.match(javascript, /function showAuthentication\(\) \{[\s\S]+clearUpdateCheckAvailabilityTimer\(\)/, `${name} authentication boundary retains the update cooldown timer`);
  assert.match(javascript, /cooldown\.delayMilliseconds \+ 1000/, `${name} cooldown expiry omitted its one-second timing safety buffer`);
  assert.match(javascript, /updateAuthenticationEpoch !== authenticationEpoch \|\| byId\("app-shell"\)\.hidden/, `${name} in-flight update completion can cross the authentication boundary`);
  assert.match(javascript, /finally \{\s+if \(updateAuthenticationEpoch === authenticationEpoch && !byId\("app-shell"\)\.hidden\) \{\s+state\.updateChecking = false;/, `${name} stale update completion can clear a new session's in-flight state`);
  assert.match(javascript, /applicationRefreshPromise = null;[\s\S]+byId\("refresh-button"\)\.disabled = false;/, `${name} authentication transition retains stale Header Refresh state`);
}
assert.match(productionCSS, /prefers-reduced-motion:reduce[^}]+update-status-halo/s);
assert.match(productionCSS, /forced-colors:active/);
assert.match(productionCSS, /max-width:420px[^}]+topbar \.brand-lockup>div/s);
assert.match(productionCSS, /max-width:420px[^\n]+access-status-button:before[^\n]+display:none/);
assert.match(productionJS, /checkForUpdatesInBackground\(\)/);
assert.match(productionHTML, /id="refresh-button"[^>]+aria-label="Refresh Manager, Tautulli choices, and update status"/);
assert.match(previewHTML, /id="refresh-button"[^>]+aria-label="Refresh synthetic Manager, Tautulli choices, and update status"/);
assert.doesNotMatch(productionJS, /backgroundUpdateCheckAttempted/);
assert.match(productionJS, /request\("\/api\/v1\/updates\/check", \{ method: "POST", body: "\{\}" \}\)/);
const initializeSource = productionJS.slice(productionJS.indexOf("async function initialize()"), productionJS.indexOf("async function loadAll()"));
const authenticatedEntrySource = productionJS.slice(productionJS.indexOf("async function enterApplication"), productionJS.indexOf("async function loadAll()"));
assert.doesNotMatch(initializeSource.slice(0, initializeSource.indexOf("await enterApplication()")), /checkForUpdatesInBackground/, "unauthenticated bootstrap can trigger an update check");
assert.match(authenticatedEntrySource, /const localStatusLoaded = await loadAll\(\);[\s\S]+if \(localStatusLoaded\) checkForUpdatesInBackground\(\);/, "cached status must render before the authenticated background check");
assert.match(productionJS, /if \(applicationRefreshPromise\) return applicationRefreshPromise;[\s\S]+recoverPendingPreviews: false,[\s\S]+updateCheckIsAvailable\(\)[\s\S]+Promise\.allSettled\(refreshes\)/, "header Refresh does not serialize and isolate local, Tautulli, and eligible update work");
assert.match(productionJS, /byId\("refresh-button"\)\.addEventListener\("click", refreshApplicationStatus\)/, "header Refresh is not wired to the scoped update-aware handler");
assert.equal((productionJS.match(/checkForUpdatesInBackground\(\)/g) || []).length, 2, "background checks escaped authenticated entry");
assert.match(productionJS, /addEventListener\("click", openUpdateSettings\)/);
assert.match(productionJS, /addEventListener\("popstate", applyLocationRoute\)/);
assert.match(productionJS, /update-settings-heading"\)\.focus/);
assert.match(previewMock, /backgroundCheckRecommended: true/);
assert.match(previewMock, /setTimeout\(\(\) => \{/);

console.log("[PASS] Manager update indicator visibility, package matrix, routing, motion, mobile, and preview contracts.");
