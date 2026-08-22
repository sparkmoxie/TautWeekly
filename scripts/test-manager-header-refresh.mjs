#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionPath = path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js");
const previewPath = path.join(repositoryRoot, "docs", "gui-preview", "app.js");
const productionJS = fs.readFileSync(productionPath, "utf8");
const previewJS = fs.readFileSync(previewPath, "utf8");

function functionSource(source, name) {
  const marker = `function ${name}(`;
  let start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name}`);
  if (source.slice(Math.max(0, start - 6), start) === "async ") start -= 6;
  const bodyStart = source.indexOf(") {", start) + 2;
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
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
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(`unterminated ${name}`);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const functions = [
  "enterApplication",
  "refreshApplicationStatus",
  "runUpdateCheck",
  "checkForUpdates",
  "checkForUpdatesInBackground",
].map((name) => functionSource(productionJS, name)).join("\n\n");

const staleStatus = Object.freeze({
  state: "current",
  updateChannel: "stable",
  packageKind: "linux-native",
  backgroundCheckRecommended: true,
  checkInProgress: false,
  lastSuccessfulCheckUtc: "2031-04-17T16:30:00Z",
});
const freshStatus = Object.freeze({
  ...staleStatus,
  backgroundCheckRecommended: false,
  lastSuccessfulCheckUtc: "2031-04-18T16:30:00Z",
  nextCheckAllowedAtUtc: "2031-04-18T16:35:00Z",
});

function createHarness({ localStatuses = [staleStatus], localGate, localSuccess = true, checkResults = [freshStatus] } = {}) {
  const events = [];
  const requests = [];
  const globalStatuses = [];
  const updateMessage = { textContent: "cached status remains usable" };
  let localIndex = 0;
  let checkIndex = 0;
  const state = {
    updates: null,
    updateChecking: false,
    updateCheckBackground: false,
  };
  const context = {
    state,
    async loadAll() {
      events.push("local:start");
      if (localGate) await localGate.promise;
      state.updates = localStatuses[Math.min(localIndex, localStatuses.length - 1)];
      localIndex += 1;
      events.push("local:complete");
      context.setGlobalStatus("Local status refreshed.", true);
      return localSuccess;
    },
    async request(target, options = {}) {
      assert.equal(target, "/api/v1/updates/check", "background refresh used an unexpected endpoint");
      assert.equal(options.method, "POST", "update check method changed");
      assert.equal(options.body, "{}", "update check body changed");
      events.push(state.updateCheckBackground ? "check:background" : "check:manual");
      requests.push({ target, options, background: state.updateCheckBackground });
      const result = checkResults[Math.min(checkIndex, checkResults.length - 1)];
      checkIndex += 1;
      return await Promise.resolve(result);
    },
    renderUpdates() { events.push("updates:render"); },
    setGlobalStatus(message, persistent) { globalStatuses.push({ message, persistent }); },
    byId(id) {
      if (id === "update-settings-message") return updateMessage;
      if (id === "auth-shell" || id === "app-shell") return { hidden: false };
      throw new Error(`unexpected element ${id}`);
    },
    async waitForActiveUpdateCheck() {},
    window: {
      location: { hash: "", href: "http://127.0.0.1:8788/" },
      TautWeeklyUpdateUI: { routeFromHash() { return { view: "dashboard", section: "" }; } },
    },
    selectView(view) { events.push(`view:${view}`); },
    console,
  };
  vm.createContext(context);
  vm.runInContext(`
    let lastRoutedURL = "";
    ${functions}
    globalThis.testAPI = { enterApplication, refreshApplicationStatus, checkForUpdates, checkForUpdatesInBackground };
  `, context);
  return { context, events, requests, globalStatuses, state, updateMessage };
}

async function flushAsyncWork() {
  await new Promise((resolve) => setImmediate(resolve));
}

{
  const gate = deferred();
  const check = deferred();
  const harness = createHarness({ localGate: gate, checkResults: [check.promise] });
  const refresh = harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 0, "header Refresh checked before local status completed");
  gate.resolve();
  await refresh;
  assert.equal(harness.requests.length, 1, "stale applicable header Refresh did not start exactly one check");
  assert.deepEqual(harness.events.slice(0, 3), ["local:start", "local:complete", "updates:render"]);
  assert.ok(harness.events.indexOf("check:background") > harness.events.indexOf("local:complete"), "background check preceded local completion");
  assert.equal(harness.requests[0].background, true);
  assert.equal(harness.state.updateChecking, true, "header Refresh waited for the release request");
  check.resolve(freshStatus);
  await flushAsyncWork();
  assert.equal(harness.state.updateChecking, false);
}

for (const [name, status] of Object.entries({
  fresh: freshStatus,
  backoff: { ...staleStatus, backgroundCheckRecommended: false, nextCheckAllowedAtUtc: "2031-04-18T16:40:00Z" },
  "in progress": { ...staleStatus, backgroundCheckRecommended: false, checkInProgress: true },
  unsupported: { ...staleStatus, updateChannel: "unsupported", backgroundCheckRecommended: false },
})) {
  const harness = createHarness({ localStatuses: [status] });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 0, `${name} status initiated a header update check`);
}

{
  const harness = createHarness({ localSuccess: false });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 0, "failed local refresh initiated an update check from cached state");
}

{
  const firstCheck = deferred();
  const harness = createHarness({
    localStatuses: [staleStatus, staleStatus, staleStatus],
    checkResults: [firstCheck.promise, freshStatus],
  });
  await harness.context.testAPI.refreshApplicationStatus();
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 1, "repeated header clicks created concurrent checks");
  firstCheck.resolve(freshStatus);
  await flushAsyncWork();
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 2, "a later newly applicable header refresh was permanently suppressed");
  await flushAsyncWork();
}

{
  const failure = new Error("The stable release service could not be reached.");
  failure.code = "offline";
  const harness = createHarness({ checkResults: [Promise.reject(failure)] });
  await harness.context.testAPI.refreshApplicationStatus();
  await flushAsyncWork();
  assert.equal(harness.globalStatuses.at(-1).message, "Local status refreshed.", "background failure replaced local refresh success");
  assert.equal(harness.state.updates, staleStatus, "background failure discarded cached local update status");
  assert.equal(harness.updateMessage.textContent, failure.message, "background failure was not retained in update presentation");
}

{
  const harness = createHarness();
  await harness.context.testAPI.enterApplication();
  assert.equal(harness.requests.length, 1, "authenticated entry no longer performs the applicable background check");
  assert.ok(harness.events.indexOf("check:background") > harness.events.indexOf("local:complete"));
  await flushAsyncWork();
}

{
  const harness = createHarness({ checkResults: [{ ...freshStatus, state: "update-available" }] });
  harness.state.updates = freshStatus;
  await harness.context.testAPI.checkForUpdates();
  assert.equal(harness.requests.length, 1, "explicit Check now no longer starts a check");
  assert.equal(harness.requests[0].background, false, "explicit Check now became a background action");
  assert.equal(harness.globalStatuses.at(-1).message, "Stable update found.");
}

for (const [name, source] of [["production", productionJS], ["preview", previewJS]]) {
  assert.doesNotMatch(source, /backgroundUpdateCheckAttempted/, `${name} retains a session-wide suppression flag`);
  assert.match(source, /byId\("refresh-button"\)\.addEventListener\("click", refreshApplicationStatus\)/, `${name} header Refresh is not scoped to the new handler`);
  assert.equal((source.match(/refreshApplicationStatus/g) || []).length, 2, `${name} invokes the header-only handler from another path`);
  assert.equal((source.match(/addEventListener\("click", refreshApplicationStatus\)/g) || []).length, 1, `${name} attached the behavior to another control`);
  assert.match(source, /byId\("update-check-button"\)\.addEventListener\("click", checkForUpdates\)/, `${name} explicit Check now semantics changed`);
  assert.doesNotMatch(source, /byId\("tailscale-refresh-button"\)\.addEventListener\("click", refreshApplicationStatus\)/, `${name} Tailscale verification gained an update check`);
}

console.log("[PASS] Header Refresh local-first, applicability, concurrency, retry, failure, entry, manual, and isolation contracts.");
