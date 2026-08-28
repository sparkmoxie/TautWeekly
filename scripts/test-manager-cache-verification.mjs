#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionJS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js"), "utf8");
const productionCSS = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.css"), "utf8");
const productionHTML = fs.readFileSync(path.join(repositoryRoot, "manager", "internal", "manager", "web", "index.html"), "utf8");
const previewJS = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "app.js"), "utf8");
const previewCSS = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "app.css"), "utf8");
const previewMock = fs.readFileSync(path.join(repositoryRoot, "docs", "gui-preview", "mock-api.js"), "utf8");

function functionSource(name) {
  const marker = `function ${name}(`;
  let start = productionJS.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name} in production Manager JavaScript`);
  if (productionJS.slice(Math.max(0, start - 6), start) === "async ") start -= 6;
  const bodyStart = productionJS.indexOf(") {", start) + 2;
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = bodyStart; index < productionJS.length; index += 1) {
    const character = productionJS[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === '"' || character === "'" || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) return productionJS.slice(start, index + 1);
    }
  }
  assert.fail(`unterminated ${name} in production Manager JavaScript`);
}

const setupContext = {
  state: { editor: { state: "ready" }, cache: { enabled: true }, setupWorkflowRunning: false },
};
vm.createContext(setupContext);
vm.runInContext(`
  const setupWorkflowSteps = ["choices", "lan", "smtp", "previews", "cache"];
  ${functionSource("setupWorkflowPresentation")}
  globalThis.present = setupWorkflowPresentation;
`, setupContext);
const baseSteps = Object.fromEntries(["choices", "lan", "smtp", "previews", "cache"].map((name) => [name, { state: "passed" }]));
const workflow = (cacheState) => ({ available: true, steps: { ...baseSteps, cache: { state: cacheState } } });
assert.deepEqual(
  structuredClone(setupContext.present(workflow("waiting"))),
  { label: "Waiting", tone: "waiting", summary: "One or more setup checks are waiting for a prerequisite." },
  "a prerequisite was not presented as Waiting",
);
assert.deepEqual(
  structuredClone(setupContext.present(workflow("warning"))),
  { label: "Completed with notes", tone: "warning", summary: "The saved configuration was checked; review the noted result before live delivery." },
  "a completed actionable finding was not presented as Warning",
);
assert.equal(setupContext.present(workflow("running")).label, "Running");

const navigationEvents = [];
let manualRuns = 0;
const cacheToggle = {
  scrollIntoView(options) { navigationEvents.push(["scroll", options]); },
  focus(options) { navigationEvents.push(["focus", options]); },
};
const mainContent = { focus() { navigationEvents.push(["main-focus"]); } };
const panel = { dataset: { panel: "configuration" }, hidden: true };
const nav = {
  dataset: { view: "configuration" },
  classList: { toggle() {} },
  setAttribute() {},
  removeAttribute() {},
};
const navigationContext = {
  state: { cache: { enabled: false } },
  window: {
    location: { hash: "", href: "http://example.test/", pathname: "/", search: "" },
    scrollTo() {},
    TautWeeklyUpdateUI: { hashForRoute: (view, section) => `#${view}/${section}` },
  },
  history: { pushState() {} },
  document: {
    querySelectorAll(selector) {
      if (selector === "[data-panel]") return [panel];
      if (selector === "[data-view]") return [nav];
      return [];
    },
  },
  clearAllRevealedSecrets() {},
  requestAnimationFrame(callback) { callback(); },
  byId(id) {
    if (id === "config-DeletedItemCacheEnabled") return cacheToggle;
    if (id === "main-content") return mainContent;
    throw new Error(`unexpected element ${id}`);
  },
  runCacheVerification() { manualRuns += 1; },
};
vm.createContext(navigationContext);
vm.runInContext(`
  let lastRoutedURL = "";
  ${functionSource("selectView")}
  ${functionSource("handleCacheVerificationAction")}
  globalThis.activateCacheAction = handleCacheVerificationAction;
`, navigationContext);
navigationContext.activateCacheAction();
assert.equal(navigationContext.state.cache.enabled, false, "Enable Cache Storage silently toggled the saved setting");
assert.equal(panel.hidden, false, "Enable Cache Storage did not open Config");
assert.deepEqual(structuredClone(navigationEvents), [
  ["scroll", { block: "center", behavior: "smooth" }],
  ["focus", { preventScroll: true }],
], "Enable Cache Storage did not smoothly scroll and focus the cache setting");
assert.equal(manualRuns, 0, "disabled-cache navigation started a verification request");
navigationContext.state.cache.enabled = true;
navigationContext.activateCacheAction();
assert.equal(manualRuns, 1, "enabled-cache action did not remain an optional manual recheck");

const postSaveSource = functionSource("runPostSaveSetup");
assert.ok(postSaveSource.indexOf('request("/api/v1/operations"') < postSaveSource.indexOf("if (plan.verifyCache && !previewStarted)"), "cache verification was ordered before PreviewAll initialization");
assert.match(postSaveSource, /if \(plan\.verifyCache && !previewStarted\)[\s\S]+automatic: true, expectedRevision: revision/, "skipped PreviewAll does not fall back to automatic full verification");
assert.match(postSaveSource, /cachePending: Boolean\(plan\.verifyCache && previewStarted\)/, "started PreviewAll is not delegated to terminal backend verification");
assert.doesNotMatch(functionSource("runCacheVerification"), /operationIsActive|scheduleOperationIsActive/, "an unrelated active operation suppresses the automatic fallback cache check");
assert.match(functionSource("submitConfig"), /if \(!result\.saved\)[\s\S]+postSave\?\.verifyCache[\s\S]+runCacheVerification\(\{ automatic: true/, "an unchanged enabled configuration does not receive full cache verification");
assert.match(functionSource("renderVerification"), /cacheWorkflowState === "waiting"[\s\S]+Waiting for the no-email PreviewAll prerequisite/, "Verify does not inherit the Waiting prerequisite");
assert.match(functionSource("renderVerification"), /cacheDisabled[\s\S]+"Enable Cache Storage"/, "disabled cache does not expose the Config navigation action");
assert.match(functionSource("renderVerification"), /prepareVerificationResults[\s\S]+finishVerificationResults/, "verification cards are replaced instead of transitioning in place");

assert.match(productionCSS, /\.state-chip\.waiting,\.state-chip\.warning\{[^}]*animation:state-pulse-amber/, "Waiting and Warning lack the shared amber transition treatment");
assert.match(productionCSS, /\.health-card,\.setup-workflow-steps article,\.verification-result\{[^}]*color[^}]*border-color[^}]*background-color[^}]*box-shadow/, "state cards do not transition text, border, background, and glow together");
assert.match(productionCSS, /\.health-card,\.verification-result\{background-image:none;background-color:var\(--surface\)\}/, "opaque card gradients mask the state background transition");
assert.match(productionCSS, /\.verification-result\.state-card-good[^\n]+\{animation:none\}/, "legacy card pulse animations override the state glow transition");
assert.match(productionCSS, /prefers-reduced-motion:reduce[^\n]+state-chip\.waiting/, "new state motion lacks a reduced-motion fallback");
assert.match(productionHTML, /Optional local recheck[\s\S]+Validate, save, and verify already runs this full check/, "Verify copy still presents the manual check as a required second step");
assert.match(productionHTML, /never receives cache paths, titles, GUIDs, rating keys, hashes, artwork, viewing metrics, recipient data, credentials, or manifest contents/, "aggregate cache privacy boundary disappeared from Verify");
assert.match(productionHTML, /id="icon-home-storage-gear"[^>]+data-symbol="home_storage_gear"[^>]+data-weight="400"[^>]+data-optical-size="24"/, "the requested local cache boundary symbol is missing");
assert.match(productionHTML, /cache-boundary[^\n]+href="#icon-home-storage-gear"/, "the local cache boundary does not use the home storage settings symbol");

for (const [name, source] of [["production", productionJS], ["preview", previewJS]]) {
  assert.match(source, /cacheWorkflowState === "waiting"[\s\S]+Waiting for the no-email PreviewAll prerequisite/, `${name} Verify view lost Waiting inheritance`);
  assert.match(source, /selectView\("configuration", \{ section: "cache" \}\)/, `${name} disabled-cache action lost Config navigation`);
  assert.match(source, /scrollIntoView\(\{ block: "center", behavior: "smooth" \}\)/, `${name} disabled-cache action lost smooth focus navigation`);
}
assert.match(previewCSS, /\.state-chip\.waiting,\.state-chip\.warning\{[^}]*animation:state-pulse-amber/, "GUI preview lost Waiting/Warning transition parity");
assert.match(previewCSS, /\.health-card,\.setup-workflow-steps article,\.verification-result\{[^}]*background-color[^}]*box-shadow/, "GUI preview lost state-card transition parity");
assert.match(previewMock, /verifyCache: cacheEnabled, cacheEnabled/);
assert.match(previewMock, /steps\.cache = \{ state: "waiting"/);
assert.match(previewMock, /completeCacheVerification\(\);[\s\S]+setupStatus\.running = false/);

console.log("[PASS] Manager cache Waiting, automatic full verification, optional recheck, navigation, transition, preview, and privacy contracts.");
