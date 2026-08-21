#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionPath = path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js");
const productionJS = fs.readFileSync(productionPath, "utf8");

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

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

const functions = [
  "previewScenarioIndex",
  "preferredPreviewForInventory",
  "operationIsActive",
  "manageOperationPolling",
  "operationPollIsCurrent",
  "successfulPreviewGeneration",
  "pollOperation",
  "openPreview",
].map(functionSource).join("\n\n");

function createHarness({ terminalState = "succeeded", previewResponse, selectedPreviewID = "normal-old", previewDeferred } = {}) {
  const calls = [];
  const renders = [];
  const timers = [];
  const oldPreviews = [
    { id: "index-old", name: "preview-all-00-index", modifiedUtc: "2031-01-01T00:00:00Z", sizeBytes: 10 },
    { id: "normal-old", name: "preview-all-04-normal-newsletter", modifiedUtc: "2031-01-01T00:00:00Z", sizeBytes: 20 },
  ];
  const nextPreviews = previewResponse || [
    { id: "index-new", name: "preview-all-00-index", modifiedUtc: "2031-01-02T00:00:00Z", sizeBytes: 11 },
    { id: "normal-new", name: "preview-all-04-normal-newsletter", modifiedUtc: "2031-01-02T00:00:00Z", sizeBytes: 21 },
  ];
  const operation = { id: "operation-2", type: "preview-all", state: "running", generatedPreviewIds: [] };
  const terminal = {
    ...operation,
    state: terminalState,
    generatedPreviewIds: terminalState === "succeeded" ? nextPreviews.map((preview) => preview.id) : [],
  };
  const context = {
    state: {
      operation,
      previews: oldPreviews,
      selectedPreviewID,
      history: [],
      historyMaximum: 20,
      status: {},
      setupWorkflow: null,
    },
    async request(target) {
      calls.push(target);
      if (target === "/api/v1/operations/current") return { current: terminal };
      if (target === "/api/v1/history") return { maximumEntries: 20, operations: [terminal] };
      if (target === "/api/v1/status") return { overall: "healthy" };
      if (target === "/api/v1/config/status") return { available: true };
      if (target === "/api/v1/previews") {
        if (previewDeferred) return previewDeferred.promise;
        return { previews: nextPreviews };
      }
      throw new Error(`unexpected request ${target}`);
    },
    renderPreviews(options) { renders.push({ name: "previews", options }); },
    renderOperations() { renders.push({ name: "operations" }); },
    renderStatus() { renders.push({ name: "status" }); },
    renderSetupWorkflow() { renders.push({ name: "setup" }); },
    operationSummary() { return { heading: "Preview generation completed" }; },
    setGlobalStatus() {},
    showAuthentication() {},
    setTimeout(callback, delay) { timers.push({ callback, delay }); return timers.length; },
    clearTimeout() {},
    console,
  };
  vm.createContext(context);
  vm.runInContext(`
    let operationPollTimer;
    let operationPollSequence = 0;
    let operationCompletionProcessedID = "";
    ${functions}
    globalThis.testAPI = {
      pollOperation,
      manageOperationPolling,
      preferredPreviewForInventory,
      previewScenarioIndex,
      openPreview,
      sequence: () => operationPollSequence,
    };
  `, context);
  return { context, calls, renders, timers, oldPreviews, nextPreviews, operation, terminal };
}

{
  const harness = createHarness();
  await harness.context.testAPI.pollOperation("operation-2", 0);
  assert.equal(harness.calls.filter((target) => target === "/api/v1/previews").length, 1, "successful completion did not refresh inventory exactly once");
  assert.deepEqual(harness.context.state.previews, harness.nextPreviews, "fresh preview inventory was not applied");
  const previewRender = harness.renders.find((render) => render.name === "previews");
  assert.equal(previewRender.options.preferredScenario, 4, "selected scenario was not preserved across changed preview IDs");
  assert.equal(previewRender.options.reloadKey, "operation-2", "successful generation did not request a new-artifact reload");
  assert.deepEqual(Array.from(previewRender.options.generatedPreviewIDs), ["index-new", "normal-new"]);
  const requestCount = harness.calls.length;
  await harness.context.testAPI.pollOperation("operation-2", 0);
  assert.equal(harness.calls.length, requestCount, "processed completion issued redundant follow-up requests");
  assert.equal(harness.calls.filter((target) => target === "/api/v1/previews").length, 1, "processed completion issued a redundant inventory request");
}

for (const terminalState of ["failed", "cancelled"]) {
  const harness = createHarness({ terminalState });
  await harness.context.testAPI.pollOperation("operation-2", 0);
  assert.equal(harness.calls.includes("/api/v1/previews"), false, `${terminalState} generation refreshed preview inventory`);
  assert.equal(harness.renders.some((render) => render.name === "previews"), false, `${terminalState} generation reloaded the visible preview`);
}

{
  const harness = createHarness({ selectedPreviewID: "missing" });
  const preferred = harness.context.testAPI.preferredPreviewForInventory(harness.nextPreviews, "missing", Number.MAX_SAFE_INTEGER, ["index-new", "normal-new"]);
  assert.equal(preferred.id, "index-new", "invalid selection did not fall back to the newly generated index");
  const previewsWithLegacyFile = [{ id: "legacy", name: "preview-legacy" }, ...harness.nextPreviews];
  const emptySelection = harness.context.testAPI.preferredPreviewForInventory(previewsWithLegacyFile, "", Number.MAX_SAFE_INTEGER, ["normal-new"]);
  assert.equal(emptySelection.id, "normal-new", "empty selection did not fall back to an available newly generated state");
}

{
  const gate = deferred();
  const harness = createHarness({ previewDeferred: gate });
  const stalePoll = harness.context.testAPI.pollOperation("operation-2", 0);
  await Promise.resolve();
  await Promise.resolve();
  harness.context.state.operation = { id: "operation-3", type: "preview-all", state: "running" };
  harness.context.testAPI.manageOperationPolling();
  gate.resolve({ previews: harness.nextPreviews });
  await stalePoll;
  assert.deepEqual(harness.context.state.previews, harness.oldPreviews, "stale completion overwrote the next operation's inventory");
  assert.equal(harness.renders.some((render) => render.name === "previews"), false, "stale completion reloaded the next operation's frame");
}

{
  let sourceAssignments = 0;
  let source = "/preview/normal-old";
  const attributes = {};
  const frame = {
    dataset: { previewId: "normal-old" },
    hidden: false,
    get src() { return source; },
    set src(value) { source = value; sourceAssignments += 1; },
    removeAttribute(name) { delete attributes[name]; if (name === "data-preview-reload-key") delete this.dataset.previewReloadKey; },
  };
  const button = { classList: { add() {} } };
  const context = {
    state: { selectedPreviewID: "normal-old" },
    document: { querySelectorAll() { return [{ classList: { remove() {} } }]; } },
    byId(id) {
      if (id === "preview-frame") return frame;
      if (id === "preview-placeholder") return { hidden: false };
      throw new Error(`unexpected element ${id}`);
    },
    encodeURIComponent,
  };
  vm.createContext(context);
  vm.runInContext(`${functionSource("openPreview")}; globalThis.openPreviewForTest = openPreview;`, context);
  context.openPreviewForTest("normal-old", button, { reloadKey: "operation-2" });
  assert.equal(source, "/preview/normal-old?refresh=operation-2", "selected preview did not navigate to its new artifact URL");
  assert.equal(sourceAssignments, 1);
  context.openPreviewForTest("normal-old", button, { reloadKey: "operation-2" });
  assert.equal(sourceAssignments, 1, "same completion redundantly reloaded the iframe");
}

console.log("[PASS] Manager preview completion refresh, selection, reload, terminal-state, request, and race contracts.");
