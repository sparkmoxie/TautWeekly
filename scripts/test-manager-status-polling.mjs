#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(path.join(root, "manager/internal/manager/web/app.js"), "utf8");

function functionSource(name) {
  const marker = `function ${name}(`;
  let start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name}`);
  if (source.slice(start - 6, start) === "async ") start -= 6;
  const bodyStart = source.indexOf(") {", start) + 2;
  let depth = 0, quote = "", escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
      continue;
    }
    if (["\"", "'", "`"].includes(character)) { quote = character; continue; }
    if (character === "{") depth += 1;
    if (character === "}" && --depth === 0) return source.slice(start, index + 1);
  }
  assert.fail(`unterminated ${name}`);
}

function snapshot(running = false) {
  return {
    overall: "healthy", observedAtUtc: "2031-04-18T16:31:00Z", platform: "fixture",
    runtime: { manager: "healthy", preview: "ready", scheduler: "ready" },
    readiness: { configuration: "ready", privateData: "ready" },
    schedule: { supported: true, installed: true, enabled: true, owned: true, provider: "embedded-fixture", state: "running" },
    delivery: { running, result: "not-recorded", evidence: "none" }, previewSummary: "Fixture previews",
  };
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function harness({ running = false, statusRequest = () => snapshot(running), operationRequest, scheduleRequest } = {}) {
  let now = 0, nextTimer = 0;
  const timers = new Map(), elements = new Map(), listeners = new Map();
  const requests = [];
  const state = { status: snapshot(running), editor: null, previews: [], operation: running ? { id: "fixture-operation", type: "send-all", state: "running" } : null };
  const byId = (id) => {
    if (!elements.has(id)) elements.set(id, { hidden: false, textContent: "", classList: { toggle() {} }, replaceChildren() {}, focus() {} });
    return elements.get(id);
  };
  const context = {
    state, byId, console,
    document: { hidden: false, addEventListener(name, callback) { listeners.set(name, callback); } },
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, at: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    async request(target) {
      requests.push({ target, at: now });
      if (target === "/api/v1/status") return await statusRequest();
      if (target === "/api/v1/operations/current") return operationRequest ? await operationRequest() : { current: state.operation };
      if (target === "/api/v1/schedule/operation") return scheduleRequest ? await scheduleRequest() : { current: state.scheduleOperation };
      throw new Error(`unexpected fixture request ${target}`);
    },
    operationIsActive: (operation) => ["queued", "running", "cancelling"].includes(operation?.state),
    scheduleOperationIsActive: (operation) => ["queued", "running"].includes(operation?.state),
    titleCase: String, formatDate: String, yesNo: String, overallHeading: String, overallCopy: String,
    setText() {}, setChip() {}, setSwappingText() {}, setTimelineCardState() {},
    renderDashboardGreeting() {}, renderDashboardScheduleSummary() {}, renderIntegrationStatus() {}, renderDashboardConfigStatus() {},
    renderSchedule() {}, renderOperations() {}, scheduleHasUpcomingRun() { return false; },
    isNAS() { return false; }, isLinuxService() { return false; }, isMacDocker() { return false; },
    clearHouseholdPrimary() {}, stopUpdateInstallPolling() {}, clearUpdateCheckAvailabilityTimer() {},
    clearAllRevealedSecrets() {}, closeSecretRevealDialog() {}, concealMaskedInputs() {}, renderUserComboboxes() {},
    setGlobalStatus() {},
  };
  vm.createContext(context);
  const functions = ["renderStatus", "productionDeliveryOperationIsActive", "productionDeliveryIsRunning", "productionDeliveryStartedAt", "manageDeliveryStatusPolling", "pollDeliveryStatus", "manageOperationPolling", "operationPollIsCurrent", "successfulPreviewGeneration", "pollOperation", "manageSchedulePolling", "pollScheduleOperation", "showAuthentication"].map(functionSource).join("\n");
  const visibilityStart = source.indexOf('document.addEventListener("visibilitychange",');
  const visibilityEnd = source.indexOf("\nmaterializeMaterialIcons();", visibilityStart);
  assert.ok(visibilityStart >= 0 && visibilityEnd > visibilityStart, "missing visibility lifecycle");
  vm.runInContext(`let authenticationEpoch = 0, applicationRefreshPromise = null;
    let deliveryStatusPollTimer, deliveryStatusPollInFlight = false, operationPollTimer, schedulePollTimer;
    let operationPollSequence = 0, operationCompletionProcessedID = "", schedulePollSequence = 0;
    ${functions}
    ${source.slice(visibilityStart, visibilityEnd)}
    globalThis.fixture = {
      start: manageDeliveryStatusPolling, poll: pollDeliveryStatus, render: renderStatus,
      startOperation: manageOperationPolling, startSchedule: manageSchedulePolling,
      pollOperation, pollSchedule: pollScheduleOperation, expire: showAuthentication,
    };`, context);
  return {
    state, requests, timers, fixture: context.fixture,
    async advance(milliseconds) {
      for (let tick = 0; tick < 8; tick += 1) await Promise.resolve();
      const target = now + milliseconds;
      while (timers.size) {
        const [id, timer] = [...timers].sort((left, right) => left[1].at - right[1].at)[0];
        if (timer.at > target) break;
        timers.delete(id);
        now = timer.at;
        void timer.callback();
        for (let tick = 0; tick < 8; tick += 1) await Promise.resolve();
      }
      now = target;
    },
    visibility(hidden) { context.document.hidden = hidden; listeners.get("visibilitychange")(); },
    resumeSession(status) { byId("app-shell").hidden = false; state.status = status; },
    get authenticated() { return !byId("app-shell").hidden; },
    statusRequests() { return requests.filter(({ target }) => target === "/api/v1/status"); },
  };
}

assert.match(functionSource("loadAll"), /manageDeliveryStatusPolling\(\);/, "application load must start status polling");

// The fictional Windows profile exposes the same observed scheduler timestamp.
{
  const mock = fs.readFileSync(path.join(root, "docs/gui-preview/mock-api.js"), "utf8");
  const start = mock.indexOf("  function status() {");
  const end = mock.indexOf("\n  function configView()", start);
  assert.ok(start >= 0 && end > start, "missing fictional status provider");
  const stamp = "2031-04-18T16:31:00Z";
  for (const service of [false, true]) {
    const status = vm.runInNewContext(`${mock.slice(start, end)}\nstatus();`, {
      now: () => stamp, serviceProfile: () => service,
      profile: () => ({ label: "Fixture", runtimeMode: service ? "linux" : "windows" }),
      model: { schedule: { installed: true, state: "ready" } }, DEMO_VERSION: "fixture", previews: [],
    });
    if (service) assert.equal(Object.hasOwn(status.schedule, "probeObservedAtUtc"), false, "embedded scheduler was given a fictional Windows probe");
    else assert.equal(status.schedule.probeObservedAtUtc, status.observedAtUtc, "Windows preview omitted its observed probe timestamp");
  }
}

// Actual operation polling renders every second; status must still run at 1.5s.
{
  const test = harness({ running: true });
  test.fixture.start();
  test.fixture.startOperation();
  await test.advance(6000);
  assert.deepEqual(test.statusRequests().map(({ at }) => at), [1500, 3000, 4500, 6000], "operation renders starved the status timer");
  assert.equal(test.requests.filter(({ target }) => target === "/api/v1/operations/current").length, 6);
}

// A completed delivery returns to idle cadence on the next status response.
{
  const test = harness({ running: true, statusRequest: () => snapshot(false) });
  test.fixture.start();
  test.state.operation = null;
  await test.advance(6500);
  assert.deepEqual(test.statusRequests().map(({ at }) => at), [1500, 6500]);
}

// Unrelated rendering also must not postpone the existing idle deadline.
{
  const test = harness();
  test.fixture.start();
  for (let index = 0; index < 4; index += 1) { await test.advance(1000); test.fixture.render(); }
  await test.advance(1000);
  assert.deepEqual(test.statusRequests().map(({ at }) => at), [5000]);
  await test.advance(5000);
  assert.equal(test.statusRequests().length, 2, "successful status reads must rearm polling");
}

// Background tabs stop; foregrounding immediately refreshes and resumes cadence.
{
  const test = harness();
  test.fixture.start();
  test.visibility(true);
  await test.advance(10000);
  assert.equal(test.statusRequests().length, 0);
  test.visibility(false);
  await test.advance(0);
  assert.equal(test.statusRequests().length, 1);
  await test.advance(5000);
  assert.equal(test.statusRequests().length, 2);
}

// Hidden tabs stop all three loops; foregrounding resumes each active loop.
{
  const test = harness({ running: true });
  test.state.scheduleOperation = { id: "fixture-schedule", state: "running" };
  test.fixture.startOperation();
  test.fixture.startSchedule();
  await test.advance(1000);
  const before = test.requests.length;
  test.visibility(true);
  await test.advance(10000);
  assert.equal(test.requests.length, before, "hidden operation/schedule polling continued");
  test.visibility(false);
  await test.advance(1000);
  assert.equal(test.requests.filter(({ target }) => target === "/api/v1/operations/current").length, 2);
  assert.equal(test.requests.filter(({ target }) => target === "/api/v1/schedule/operation").length, 2);
}

// A response started before hiding cannot overwrite the resumed operation view.
{
  const pending = deferred();
  const test = harness({ running: true, operationRequest: () => pending.promise });
  const before = test.state.operation;
  const request = test.fixture.pollOperation();
  test.visibility(true);
  test.visibility(false);
  pending.resolve({ current: { ...before, state: "succeeded" } });
  await request;
  assert.equal(test.state.operation, before, "old operation response replaced the resumed view");
}
{
  const pending = deferred();
  const test = harness({ scheduleRequest: () => pending.promise });
  const before = { id: "fixture-schedule", state: "running" };
  test.state.scheduleOperation = before;
  const request = test.fixture.pollSchedule();
  test.visibility(true);
  test.visibility(false);
  pending.resolve({ current: { ...before, state: "succeeded" } });
  await request;
  assert.equal(test.state.scheduleOperation, before, "old schedule response replaced the resumed view");
}

// A status request is single-flight, and an old session cannot repaint a new one.
{
  const pending = deferred();
  const test = harness({ statusRequest: () => pending.promise });
  const request = test.fixture.poll();
  await test.fixture.poll();
  assert.equal(test.statusRequests().length, 1);
  test.fixture.expire();
  const current = snapshot(false);
  current.observedAtUtc = "2031-04-18T16:32:00Z";
  test.resumeSession(current);
  test.fixture.start();
  pending.resolve(snapshot(true));
  await request;
  assert.equal(test.state.status, current, "stale session response replaced current status");
  assert.equal(test.timers.size, 1, "new session must resume after old in-flight request completes");
}

{
  const pending = deferred();
  const test = harness({ statusRequest: () => pending.promise });
  const request = test.fixture.poll();
  test.visibility(true);
  pending.resolve(snapshot());
  await request;
  assert.equal(test.timers.size, 0, "in-flight completion rearmed a hidden tab");
}

{
  const pending = deferred();
  const test = harness({ statusRequest: () => pending.promise });
  const request = test.fixture.poll();
  test.fixture.expire();
  test.resumeSession(snapshot());
  pending.reject(Object.assign(new Error("old session expired"), { status: 401 }));
  await request;
  assert.equal(test.authenticated, true, "old authentication failure expired the new session");
}

// Authentication failures stop; transient failures use the existing 5s retry.
{
  const test = harness({ statusRequest: () => { throw Object.assign(new Error("expired"), { status: 401 }); } });
  await test.fixture.poll();
  assert.equal(test.authenticated, false);
  assert.equal(test.timers.size, 0);
}
{
  let attempts = 0;
  const test = harness({ running: true, statusRequest: () => { if (++attempts === 1) throw new Error("fixture network failure"); return snapshot(true); } });
  await test.fixture.poll();
  await test.advance(4999);
  assert.equal(test.statusRequests().length, 1);
  await test.advance(1);
  assert.equal(test.statusRequests().length, 2);
  await test.advance(1500);
  assert.equal(test.statusRequests().length, 3, "successful retry must return to active cadence");
}

// Repeated identical dashboard evidence must not rewrite DOM text/classes.
{
  let writes = 0;
  function textNode(initial) {
    let text = initial;
    return { get textContent() { return text; }, set textContent(value) { writes += 1; text = value; } };
  }
  const label = textNode("Healthy"), text = textNode("Current");
  const classes = new Set(["state-card-good"]);
  const card = { classList: {
    contains: (value) => classes.has(value),
    remove(...values) { writes += 1; values.forEach((value) => classes.delete(value)); },
    add(value) { writes += 1; classes.add(value); },
  } };
  let chipClass = "state-chip good";
  const chip = {
    dataset: new Proxy({ iconName: "" }, { set(target, name, value) { writes += 1; target[name] = value; return true; } }),
    querySelector: (selector) => selector === ".state-chip-label" ? label : null,
    closest: () => card,
    get className() { return chipClass; }, set className(value) { writes += 1; chipClass = value; },
  };
  const context = {
    byId: (id) => id === "chip" ? chip : text,
    setSwappingElementText(element, value) { if (element.textContent !== value) element.textContent = value; },
  };
  vm.createContext(context);
  vm.runInContext(`${functionSource("setText")}\n${functionSource("setChip")}\n globalThis.fixture = { setText, setChip };`, context);
  for (let index = 0; index < 100; index += 1) { context.fixture.setText("text", "Current"); context.fixture.setChip("chip", "Healthy", "good"); }
  assert.equal(writes, 0, "unchanged evidence rewrote DOM properties");
  context.fixture.setText("text", "Updated");
  context.fixture.setChip("chip", "Warning", "bad");
  assert.equal(text.textContent, "Updated");
  assert.equal(label.textContent, "Warning");
  assert.deepEqual([...classes], ["state-card-bad"]);
}

console.log("[PASS] Manager status polling: operation/render starvation, idle/active cadence, hidden status/operation/schedule, single-flight, session isolation, authentication, retry, and unchanged DOM.");
