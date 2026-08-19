#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
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
assert.deepEqual(updateUI.routeFromHash("#settings"), { view: "about", section: "" });
assert.deepEqual(updateUI.routeFromHash("#configuration"), { view: "configuration", section: "" });
assert.deepEqual(updateUI.routeFromHash("#pair=synthetic-token"), { view: "dashboard", section: "" });
assert.equal(updateUI.hashForRoute("about", "updates"), "#settings/application-and-package-status");
assert.equal(updateUI.hashForRoute("about"), "#settings");

const productionHTML = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "index.html"), "utf8");
const productionCSS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.css"), "utf8");
const productionJS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js"), "utf8");
const previewMock = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "mock-api.js"), "utf8");
assert.match(productionHTML, /id="icon-deployed-code-update"/);
assert.match(productionHTML, /id="update-status-button"[^>]+aria-controls="update-settings-panel"[^>]+hidden/);
assert.match(productionHTML, /id="update-settings-heading" tabindex="-1"/);
assert.match(productionCSS, /color:var\(--violet\)/);
assert.match(productionCSS, /animation:hero-pulse 2\.9s ease-out infinite/);
assert.match(productionCSS, /prefers-reduced-motion:reduce[^}]+update-status-halo/s);
assert.match(productionCSS, /forced-colors:active/);
assert.match(productionCSS, /max-width:420px[^}]+topbar \.brand-lockup>div/s);
assert.match(productionCSS, /max-width:420px[^\n]+access-status-button:before[^\n]+display:none/);
assert.match(productionJS, /checkForUpdatesInBackground\(\)/);
assert.match(productionJS, /backgroundUpdateCheckAttempted/);
assert.match(productionJS, /request\("\/api\/v1\/updates\/check", \{ method: "POST", body: "\{\}" \}\)/);
const initializeSource = productionJS.slice(productionJS.indexOf("async function initialize()"), productionJS.indexOf("async function loadAll()"));
const authenticatedEntrySource = productionJS.slice(productionJS.indexOf("async function enterApplication"), productionJS.indexOf("async function loadAll()"));
assert.doesNotMatch(initializeSource.slice(0, initializeSource.indexOf("await enterApplication()")), /checkForUpdatesInBackground/, "unauthenticated bootstrap can trigger an update check");
assert.match(authenticatedEntrySource, /await loadAll\(\);[\s\S]+checkForUpdatesInBackground\(\);/, "cached status must render before the authenticated background check");
assert.equal((productionJS.match(/checkForUpdatesInBackground\(\)/g) || []).length, 2, "background checks must be limited to the authenticated entry call and function declaration");
assert.match(productionJS, /addEventListener\("click", openUpdateSettings\)/);
assert.match(productionJS, /addEventListener\("popstate", applyLocationRoute\)/);
assert.match(productionJS, /update-settings-heading"\)\.focus/);
assert.match(previewMock, /backgroundCheckRecommended: true/);
assert.match(previewMock, /setTimeout\(\(\) => \{/);

console.log("[PASS] Manager update indicator visibility, package matrix, routing, motion, mobile, and preview contracts.");
