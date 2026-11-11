#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(path.join(root, "manager/internal/manager/web/app.js"), "utf8");
const functionSource = (name) => {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const next = source.indexOf("\nfunction ", start + 1);
  return source.slice(start, next < 0 ? undefined : next);
};

class Element {
  children = [];
  dataset = {};
  listeners = {};
  checked = false;
  disabled = false;
  value = "";
  validity = { valid: true };
  classList = { toggle() {} };
  constructor(tag) { this.tag = tag; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute() {}
  addEventListener(event, callback) { this.listeners[event] = callback; }
  querySelectorAll(selector) {
    const all = this.children.flatMap((child) => [child, ...(child.querySelectorAll?.("*") || [])]);
    return all.filter((child) => selector === "*" || selector === "input:checked" && child.tag === "input" && child.checked);
  }
}

const fields = { IncludedLibraryIds: ["20", "99"], ExcludedUserIds: ["5"], ExcludedEmails: [] };
const assignments = { 1: "retained@example.org", 999: "unavailable@example.org" };
const elements = new Map();
const state = {
  editor: { fields: [{ name: "UserEmailOverrides", value: assignments }] },
  discovery: {
    users: [
      { id: "1", name: "Archived Owner", eligibility: "eligible", archived: true, role: "owner" },
      { id: "2", name: "Deleted", eligibility: "eligible", deleted: true },
      { id: "3", name: "Archived Cache", eligibility: "archived" },
      { id: "4", name: "Active", eligibility: "eligible", role: "administrator" },
      { id: "5", name: "Saved Excluded", eligibility: "eligible" },
      { id: "41", name: "Local", eligibility: "address-needed", needsDeliveryAddress: true },
      { id: "0", name: "Local", eligibility: "eligible" },
    ],
    libraries: [
      { id: "10", name: "Movies", mediaType: "movie", availability: "active" },
      { id: "20", name: "Archived Movies", mediaType: "movie", availability: "archived" },
      { id: "30", name: "Deleted Shows", mediaType: "show", availability: "deleted" },
    ],
  },
};
const controls = {
  "preview-user-id": { value: "1" }, "preview-confirm": { checked: true },
  "test-send-user-id": { value: "2" }, "test-send-confirm": { checked: true },
  "manual-send-user-id": { value: "3" }, "manual-send-confirm": { checked: true },
};
const context = {
  state, document: { createElement: (tag) => new Element(tag) },
  byId(id) { if (controls[id]) return controls[id]; if (!elements.has(id)) elements.set(id, new Element("div")); return elements.get(id); },
  savedListField: (name) => fields[name] || [], currentListField: (name) => fields[name] || [],
  setListField: (name, value) => { fields[name] = value; },
  currentUserEmailOverrides: () => assignments, renderHouseholdCopies() {},
  titleCase: (value) => String(value).replace(/^./, (letter) => letter.toUpperCase()),
  setText(id, value) { context.byId(id).textContent = value; },
};
vm.createContext(context);
for (const name of ["validPreviewUserID", "discoveredNewsletterUsers", "savedUserEmailOverrides", "userExcludedBySavedPolicy", "selectableNewsletterUsers", "validOperationUserID", "suggestedSelectablePreviewUserID", "reconcileOperationUserSelections", "renderDiscoveredLibraries", "managedUserAddressState", "renderManagedUserDeliveryAddresses"]) {
  vm.runInContext(functionSource(name), context);
}
assert.deepEqual(Array.from(context.selectableNewsletterUsers(), (item) => item.id), ["4", "41"], "archived/deleted users remained available for an operation");
assert.equal(context.suggestedSelectablePreviewUserID(), "4", "archived owner displaced the active administrator");
context.reconcileOperationUserSelections();
for (const id of ["preview", "test-send", "manual-send"]) {
  assert.equal(controls[`${id}-user-id`].value, "", `${id} kept a stale archived/deleted selection`);
  assert.equal(controls[`${id}-confirm`].checked, false);
}

context.renderDiscoveredLibraries();
const rows = context.byId("discovery-libraries").children;
assert.equal(rows.length, 4, "saved unavailable library disappeared");
const checkbox = (id) => rows.map((row) => row.children[0]).find((input) => input.dataset.choiceId === id);
assert.equal(checkbox("20").checked, true, "archived saved selection was silently removed");
assert.equal(checkbox("99").checked, true, "missing saved selection was silently removed");
assert.equal(checkbox("30").disabled, true, "a deleted library could be newly selected");
checkbox("10").checked = true;
checkbox("10").listeners.change();
assert.deepEqual(Array.from(fields.IncludedLibraryIds).sort(), ["10", "20", "99"], "editing active choices dropped retained saved scope");
assert.match(context.byId("discovery-library-count").textContent, /1 active.*3 unavailable/);
assert.match(rows[1].children[1].children[1].textContent, /Archived.*saved selection retained/);

for (const selectedID of ["20", "99", "10"]) {
  fields.IncludedLibraryIds = [selectedID];
  context.renderDiscoveredLibraries();
  const last = context.byId("discovery-libraries").children.map((row) => row.children[0]).find((input) => input.dataset.choiceId === selectedID);
  last.checked = false;
  last.listeners.change();
  assert.deepEqual(Array.from(fields.IncludedLibraryIds), [selectedID], "last deselection expanded the saved library scope to all active libraries");
  assert.equal(last.checked, true, "last selection was not visibly restored");
  assert.match(context.byId("discovery-message").textContent, /Select an active replacement/);
}

context.renderManagedUserDeliveryAddresses();
const addressRows = context.byId("managed-user-delivery-list").children;
assert.equal(addressRows.length, 3, "saved archived or missing fallback assignment was hidden");
assert.equal(addressRows.find((row) => row.children[1].id === "managed-user-address-1").children[1].value, "retained@example.org");
assert.equal(addressRows.find((row) => row.children[1].id === "managed-user-address-999").children[1].value, "unavailable@example.org");

const setupSteps = [];
for (const name of ["renderDiscovery", "renderVerification", "refreshConfigurationStatus", "renderSetupWorkflow", "renderStatus", "renderDashboardConfigStatus", "renderIntegrationStatus", "renderAbout"]) context[name] = () => {};
context.updateSetupWorkflowStep = (name, status, text) => setupSteps.push({ name, status, text });
context.request = async (url) => url === "/api/v1/discovery/tautulli" ? state.discovery : {};
const setupStart = source.indexOf("async function runPostSaveSetup(");
const setupEnd = source.indexOf("\nasync function recoverPendingPreviewsFromChoices(", setupStart);
assert.ok(setupStart >= 0 && setupEnd > setupStart);
vm.runInContext(source.slice(setupStart, setupEnd), context);
await context.runPostSaveSetup("synthetic-revision", { runDiscovery: true });
assert.match(setupSteps.find((step) => step.name === "choices" && step.status === "passed").text, /^1 active libraries and 7 users/, "setup summary counted retained unavailable libraries as active");
console.log("[PASS] Manager archive selectors, stale confirmations, and saved library/address editing remain consistent.");
