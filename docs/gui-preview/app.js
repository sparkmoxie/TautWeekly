"use strict";

const state = {
  csrfToken: "",
  status: null,
  config: null,
  editor: null,
  backups: [],
  verification: { last: null, smtp: null },
  verificationRunning: false,
  smtpVerificationRunning: false,
  discovery: null,
  discoveryRunning: false,
  setupWorkflow: null,
  setupWorkflowRunning: false,
  previews: [],
  selectedPreviewID: "",
  operation: null,
  history: [],
  operationStarting: false,
  operationStartingType: "",
  operationCancelling: false,
  scheduleOperation: null,
  schedulePendingAction: "",
  scheduleStarting: false,
  authAccess: null,
  about: null,
  diagnostics: { events: [], maximumEntries: 200, retentionDays: 30 },
};
const byId = (id) => document.getElementById(id);
const titleCase = (value) => String(value || "unknown").replaceAll("-", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
const guidedConfigFields = new Set(["IncludedLibraryIds", "ExcludedUserIds"]);
const activeSecretReveals = new Map();
let pendingSecretReveal = null;
let sessionRecoveryPromise = null;

function materializeMaterialIcon(svg) {
  const use = svg?.querySelector("use");
  const href = use?.getAttribute("href") || "";
  const symbol = href.startsWith("#") ? byId(href.slice(1)) : null;
  if (!symbol) return svg;
  const viewBox = symbol.getAttribute("viewBox");
  if (viewBox) svg.setAttribute("viewBox", viewBox);
  svg.replaceChildren(...Array.from(symbol.children, (child) => child.cloneNode(true)));
  return svg;
}

function materializeMaterialIcons(root = document) {
  root.querySelectorAll("svg.ui-icon").forEach(materializeMaterialIcon);
}

function maskedInputLabel(input) {
  const label = input.labels?.[0];
  const strongLabel = label?.querySelector(":scope > strong")?.textContent?.trim();
  if (strongLabel) return strongLabel;
  const directLabel = Array.from(label?.childNodes || []).find((node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
  if (directLabel) return directLabel.textContent.trim();
  return input.getAttribute("aria-label") || input.name || "value";
}

function updateMaskedInputToggle(input, button) {
  const visible = input.type === "text";
  const label = maskedInputLabel(input);
  button.classList.toggle("visible", visible);
  button.setAttribute("aria-pressed", String(visible));
  button.setAttribute("aria-label", `${visible ? "Hide" : "Show"} ${label}`);
  button.title = `${visible ? "Hide" : "Show"} ${label}`;
}

function initializeMaskedInputToggles(root = document) {
  root.querySelectorAll('input[type="password"]').forEach((input) => {
    if (input.closest(".secret-input-shell") || input.closest(".masked-input-shell")) return;
    const shell = document.createElement("span");
    shell.className = "masked-input-shell";
    input.before(shell);
    shell.append(input);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "secret-toggle-button";
    button.setAttribute("aria-controls", input.id);
    button.append(createMaterialIcon("visibility"));
    button.addEventListener("click", () => {
      input.type = input.type === "password" ? "text" : "password";
      updateMaskedInputToggle(input, button);
      input.focus({ preventScroll: true });
    });
    shell.append(button);
    updateMaskedInputToggle(input, button);
  });
}

function concealMaskedInputs(root = document) {
  root.querySelectorAll(".masked-input-shell>input").forEach((input) => {
    input.type = "password";
    const button = input.nextElementSibling;
    if (button?.classList.contains("secret-toggle-button")) updateMaskedInputToggle(input, button);
  });
}

async function performRequest(path, options = {}) {
  const method = options.method || "GET";
  const headers = new Headers(options.headers || {});
  if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  if (method !== "GET" && method !== "HEAD" && state.csrfToken) headers.set("X-CSRF-Token", state.csrfToken);
  const response = await fetch(path, { ...options, method, headers, credentials: "same-origin" });
  const contentType = response.headers.get("Content-Type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const error = new Error(payload?.error?.message || `Request failed (${response.status}).`);
    error.status = response.status;
    error.code = payload?.error?.code || "request-failed";
    error.fields = payload?.error?.fields || {};
    throw error;
  }
  return payload;
}

async function renewTrustedLocalSession() {
  const session = await performRequest("/api/v1/auth/session");
  state.csrfToken = session.csrfToken || "";
  return session;
}

async function reloadAfterTrustedLocalRestart() {
  try {
    const setup = await performRequest("/api/v1/setup");
    if (!setup?.authenticationRequired) {
      window.location.reload();
      return true;
    }
  } catch (_) {
    // Preserve the original authentication error when setup cannot be read.
  }
  return false;
}

async function request(path, options = {}, allowSessionRecovery = true) {
  try {
    return await performRequest(path, options);
  } catch (error) {
    const authBootstrapEndpoint = ["/api/v1/auth/session", "/api/v1/auth/login", "/api/v1/auth/pair", "/api/v1/auth/logout"].includes(path);
    if (error.status !== 401 || !allowSessionRecovery || authBootstrapEndpoint) throw error;
    if (!sessionRecoveryPromise) {
      sessionRecoveryPromise = renewTrustedLocalSession().finally(() => {
        sessionRecoveryPromise = null;
      });
    }
    try {
      await sessionRecoveryPromise;
      return await request(path, options, false);
    } catch (recoveryError) {
      if (recoveryError.status === 401 && await reloadAfterTrustedLocalRestart()) {
        const restoring = new Error("Manager restarted; restoring the trusted-local session.");
        restoring.code = "session-restoring";
        restoring.status = 0;
        throw restoring;
      }
      state.csrfToken = "";
      showAuthentication();
      throw recoveryError;
    }
  }
}

function pairingTokenFromFragment() {
  const params = new URLSearchParams(window.location.hash.slice(1));
  const token = params.get("pair") || "";
  if (token) history.replaceState(null, "", window.location.pathname + window.location.search);
  return token;
}

async function initialize() {
  const setup = await request("/api/v1/setup");
  try {
    const session = await request("/api/v1/auth/session");
    state.csrfToken = session.csrfToken;
    await enterApplication();
    return;
  } catch (error) {
    if (error.status !== 401) setAuthMessage(error.message);
  }
  byId("auth-shell").hidden = false;
  if (setup.pairingRequired) {
    byId("pair-form").hidden = false;
    const token = pairingTokenFromFragment();
    byId("pair-token").value = token;
    (token ? byId("pair-password") : byId("pair-token")).focus();
  } else {
    byId("login-form").hidden = false;
    byId("login-password").focus();
  }
}

async function enterApplication(preferredView = "") {
  byId("auth-shell").hidden = true;
  byId("app-shell").hidden = false;
  await loadAll();
  selectView(preferredView || "dashboard");
  byId("main-content").focus({ preventScroll: true });
}

async function loadAll() {
  setGlobalStatus("Refreshing synthetic status…");
  try {
    const [status, config, editor, configurationStatus, backups, verification, discovery, previews, operation, history, scheduleOperation, authAccess, about, diagnostics] = await Promise.all([
      request("/api/v1/status"),
      request("/api/v1/config"),
      request("/api/v1/config/editor"),
      request("/api/v1/config/status"),
      request("/api/v1/config/backups"),
      request("/api/v1/checks/integrations"),
      request("/api/v1/discovery/tautulli"),
      request("/api/v1/previews"),
      request("/api/v1/operations/current"),
      request("/api/v1/history"),
      request("/api/v1/schedule/operation"),
      request("/api/v1/auth/access"),
      request("/api/v1/about"),
      request("/api/v1/diagnostics"),
    ]);
    state.status = status;
    state.config = config;
    state.editor = editor;
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
    state.backups = backups.backups || [];
    state.verification = verification || { last: null, smtp: null };
    state.discovery = discovery.last || null;
    state.previews = previews.previews || [];
    state.operation = operation.current || null;
    state.history = history.operations || [];
    state.scheduleOperation = scheduleOperation.current || null;
    state.authAccess = authAccess;
    state.about = about;
    state.diagnostics = diagnostics;
    renderStatus();
    renderFirstTimeSetup();
    renderConfigEditor();
    renderSetupWorkflow();
    renderBackups();
    renderVerification();
    renderPreviews();
    renderOperations();
    renderSchedule();
    renderAccessSettings();
    renderAbout();
    manageOperationPolling();
    manageSchedulePolling();
    setGlobalStatus("Synthetic status refreshed.", true);
  } catch (error) {
    if (error.status === 401) {
      showAuthentication();
      return;
    }
    setGlobalStatus(error.message, true);
  }
}

function renderFirstTimeSetup() {
  const prompt = byId("first-time-setup");
  const firstRun = state.editor?.state === "unconfigured";
  prompt.hidden = !firstRun;
  if (firstRun) setChip("first-time-setup-chip", "Not run", "pending");
}

function setupWorkflowPresentation(workflow = state.setupWorkflow) {
  if (!workflow?.available) {
    return {
      label: state.editor?.state === "unconfigured" ? "Not configured" : "Not run",
      tone: "neutral",
      summary: state.editor?.state === "unconfigured"
        ? "Complete the guided configuration before setup checks can run."
        : "Safe setup checks have not been recorded for this configuration.",
    };
  }
  const steps = setupWorkflowSteps.map((name) => workflow.steps?.[name]).filter(Boolean);
  const states = steps.map((step) => step.state);
  const active = state.setupWorkflowRunning || states.includes("running");
  if (active) return { label: "Running", tone: "pending", summary: "Synthetic setup checks are running in memory." };
  if (states.includes("failed")) return { label: "Needs review", tone: "bad", summary: "One or more synthetic setup checks need review." };
  if (states.every((stepState) => stepState === "not-run")) return { label: "Not run", tone: "neutral", summary: "Validate and save to run the four safe setup checks." };
  if (states.includes("waiting")) return { label: "Pending", tone: "pending", summary: "One or more setup checks are waiting to run for this configuration." };
  if (states.some((stepState) => ["warning", "skipped"].includes(stepState))) return { label: "Completed with notes", tone: "neutral", summary: "The fictional configuration was checked; review the synthetic note." };
  if (states.length === setupWorkflowSteps.length && states.every((stepState) => stepState === "passed")) return { label: "Passed", tone: "good", summary: "All four synthetic setup checks passed in memory." };
  return { label: "Incomplete", tone: "neutral", summary: "Some synthetic setup checks have not completed." };
}

function renderDashboardConfigStatus() {
  const presentation = setupWorkflowPresentation();
  setChip("configuration-status-chip", presentation.label, presentation.tone);
  setText("configuration-status-copy", presentation.summary);
  for (const name of setupWorkflowSteps) {
    setText(`configuration-status-${name}`, titleCase(state.setupWorkflow?.steps?.[name]?.state || "not-run"));
  }
}

function renderIntegrationStatus() {
  const last = state.verification?.last || null;
  const smtp = state.verification?.smtp || null;
  const steps = new Map((last?.steps || []).map((step) => [step.service, step]));
  const retainedLANState = retainedSetupCheckState("lan");
  const retainedSMTPState = retainedSetupCheckState("smtp");
  const tautulliState = steps.get("tautulli")?.state || retainedLANState || "not checked";
  const plexState = steps.get("plex")?.state || retainedLANState || "not checked";
  const smtpState = smtp?.state || retainedSMTPState || "not checked";
  setText("tautulli-state", titleCase(tautulliState));
  setText("plex-state", titleCase(plexState));
  setText("smtp-state", titleCase(smtpState));

  const outcomes = [last?.overall || retainedLANState, smtp?.overall || retainedSMTPState].filter(Boolean);
  let overall = "not-run";
  if (outcomes.includes("failed")) overall = "failed";
  else if (outcomes.includes("warning")) overall = "warning";
  else if (outcomes.length === 2 && outcomes.every((outcome) => outcome === "passed")) overall = "passed";
  else if (outcomes.length) overall = "partial";
  const verificationActive = state.verificationRunning || state.smtpVerificationRunning;
  const overallTone = verificationActive ? "pending" : overall === "passed" ? "good" : overall === "failed" ? "bad" : "neutral";
  const overallLabel = verificationActive ? "Running" : overall === "not-run" ? "Not run" : titleCase(overall);
  setChip("integration-chip", overallLabel, overallTone);
  setText("integration-copy", outcomes.length
    ? "Latest passing synthetic checks are retained in memory for this tab."
    : "Passing synthetic checks run after a demo save or manual simulation.");
  return { overallLabel, overallTone };
}

function retainedSetupCheckState(name) {
  const checkState = state.setupWorkflow?.steps?.[name]?.state || "";
  return ["passed", "warning", "failed"].includes(checkState) ? checkState : "";
}

function renderStatus() {
  const snapshot = state.status;
  const overall = snapshot.overall;
  const healthy = overall === "healthy";
  const blocked = overall === "blocked";
  renderDashboardGreeting(snapshot.observedAtUtc);
  setText("observed-time", formatDate(snapshot.observedAtUtc));
  setText("overall-label", titleCase(overall));
  setText("overall-heading", overallHeading(overall));
  setText("overall-copy", overallCopy(overall));
  byId("overall-orb").className = `status-orb ${healthy ? "good" : blocked ? "bad" : ""}`;
  setText("manager-state", titleCase(snapshot.runtime.manager));
  setText("preview-state", titleCase(snapshot.runtime.preview));
  setText("scheduler-state", titleCase(snapshot.runtime.scheduler));
  setChip("runtime-chip", snapshot.runtime.manager === "healthy" ? "Healthy" : "Degraded", snapshot.runtime.manager === "healthy" ? "good" : "bad");
  setText("runtime-copy", `${titleCase(snapshot.readiness.configuration)} fictional configuration · ${titleCase(snapshot.readiness.privateData)} temporary state.`);
  setText("schedule-installed", yesNo(snapshot.schedule.installed));
  setText("schedule-enabled", yesNo(snapshot.schedule.enabled));
  setText("schedule-ownership", titleCase(snapshot.schedule.ownership));
  setText("schedule-state", titleCase(snapshot.schedule.state));
  const scheduleOwned = !snapshot.schedule.installed || snapshot.schedule.owned;
  const scheduleProbeFailed = snapshot.schedule.state === "probe-failed";
  const scheduleHealthy = snapshot.schedule.installed && snapshot.schedule.enabled && scheduleOwned;
  setChip("schedule-chip", scheduleProbeFailed ? "Status unavailable" : !scheduleOwned ? "Ownership warning" : scheduleHealthy ? "Active" : snapshot.schedule.installed ? "Disabled" : "Not installed", scheduleProbeFailed || !scheduleOwned ? "bad" : scheduleHealthy ? "good" : "neutral");
  setText("schedule-copy", scheduleProbeFailed ? "Host scheduler status could not be verified." : !scheduleOwned ? "A same-named task exists but does not match this installation." : snapshot.schedule.supported ? "Simulated host scheduler state is ready." : "Schedule management is unavailable on this platform.");
  setText("last-attempt", formatDate(snapshot.delivery.lastAttemptUtc));
  setText("last-result", titleCase(snapshot.delivery.result));
  setText("last-success", formatDate(snapshot.delivery.lastSuccessUtc));
  setText("timeline-last-attempt", formatDate(snapshot.delivery.lastAttemptUtc));
  const rendererEvidence = snapshot.delivery.evidence === "renderer-result";
  setText("last-accepted-count", rendererEvidence ? String(snapshot.delivery.smtpAcceptedCount || 0) : "Not recorded");
  setText("delivery-copy", rendererEvidence
    ? "Fictional evidence models SMTP acceptance; no message or inbox exists."
    : "Simulated task state is not presented as real SMTP acceptance or inbox delivery.");
  setText("timeline-last-copy", rendererEvidence
    ? `${snapshot.delivery.smtpAcceptedCount || 0} fictional SMTP accepts · ${snapshot.delivery.skippedCount || 0} skipped · ${snapshot.delivery.failedCount || 0} failed.`
    : "No fictional renderer result has been recorded.");
  const deliveryTone = ["smtp-accepted", "simulated-accepted"].includes(snapshot.delivery.result) ? "good" : snapshot.delivery.result === "failed" ? "bad" : "neutral";
  setChip("delivery-chip", snapshot.delivery.result === "not-recorded" ? "No history" : snapshot.delivery.result === "simulated-accepted" ? "Simulated" : titleCase(snapshot.delivery.result), deliveryTone);
  renderIntegrationStatus();
  renderDashboardConfigStatus();
  setText("next-run", formatDate(snapshot.schedule.nextRunLocal));
  setText("next-run-utc", snapshot.schedule.nextRunUtc ? `Fictional UTC: ${formatDate(snapshot.schedule.nextRunUtc)}` : "The synthetic scheduler has no upcoming run.");
  setText("preview-count", snapshot.previewSummary);
  setText("sidebar-platform", `${titleCase(snapshot.platform)} · static preview`);
  setText("about-platform", titleCase(snapshot.platform));
}

function renderDashboardGreeting(observedAtUtc) {
  const observed = new Date(observedAtUtc || Date.now());
  const validObserved = !Number.isNaN(observed.getTime());
  const hour = validObserved ? observed.getHours() : new Date().getHours();
  const minute = validObserved ? observed.getMinutes() : new Date().getMinutes();
  const minuteOfDay = hour * 60 + minute;
  let greeting = "Good evening";
  if (minuteOfDay >= 360 && minuteOfDay <= 720) greeting = "Good morning";
  else if (minuteOfDay >= 721 && minuteOfDay <= 1080) greeting = "Good afternoon";
  const name = discoveredAdministratorName();
  setText("dashboard-greeting", name ? `${greeting}, ${name}.` : `${greeting}.`);
}

function discoveredAdministratorName() {
  const suggestedID = String(state.discovery?.suggestedPreviewUserId || "");
  if (!suggestedID) return "";
  const user = (state.discovery?.users || []).find((candidate) => String(candidate.id) === suggestedID);
  const name = String(user?.name || "").trim();
  return name && !/^User \d+$/i.test(name) ? name : "";
}

function renderSchedule() {
  const snapshot = state.status;
  const editor = state.editor;
  const operation = state.scheduleOperation;
  if (!snapshot || !editor) return;
  const schedule = snapshot.schedule;
  const ready = editor.state === "ready";
  const owned = !schedule.installed || schedule.owned;
  const probeFailed = schedule.state === "probe-failed";
  const scheduleActive = scheduleOperationIsActive(operation);
  const managerActive = operationIsActive(state.operation);
  const blocked = state.scheduleStarting || scheduleActive || managerActive || !ready || !schedule.supported || !owned || probeFailed;

  let chipText = "Not installed";
  let chipTone = "neutral";
  if (!schedule.supported) chipText = "Unsupported";
  else if (probeFailed) { chipText = "Status unavailable"; chipTone = "bad"; }
  else if (!owned) { chipText = "Ownership warning"; chipTone = "bad"; }
  else if (state.scheduleStarting) { chipText = "Starting"; chipTone = "pending"; }
  else if (scheduleActive) { chipText = "Changing"; chipTone = "pending"; }
  else if (schedule.installed && schedule.enabled) { chipText = "Active"; chipTone = "good"; }
  else if (schedule.installed) chipText = "Disabled";
  setChip("schedule-view-chip", chipText, chipTone);

  const day = configEditorValue("ScheduleDay") || "Friday";
  const time = configEditorValue("ScheduleTime") || "09:30";
  setText("schedule-configured-window", ready ? `${day} at ${time} local host time` : "Complete configuration first");
  setText("schedule-view-installed", yesNo(schedule.installed));
  setText("schedule-view-enabled", yesNo(schedule.enabled));
  setText("schedule-view-ownership", titleCase(schedule.ownership));
  setText("schedule-view-state", titleCase(schedule.state));
  setText("schedule-view-next-run", formatDate(schedule.nextRunLocal));
  setText("schedule-observed", `Observed ${formatDate(snapshot.observedAtUtc)}`);

  const warning = byId("schedule-warning");
  warning.className = "schedule-warning";
  if (!schedule.supported) warning.textContent = "Schedule changes are unavailable on this platform.";
  else if (probeFailed) {
    warning.textContent = "Host scheduler status could not be verified. The Manager will not request a schedule mutation until the local probe succeeds.";
    warning.classList.add("bad");
  }
  else if (!ready) warning.textContent = "Complete and save configuration before requesting a schedule change.";
  else if (!owned) {
    warning.textContent = "Safety stop simulation: a fictional same-named schedule does not match this installation, so the mock Manager leaves it untouched.";
    warning.classList.add("bad");
  } else if (managerActive) warning.textContent = "Wait for the active preview or test-delivery operation before changing the schedule.";
  else if (scheduleActive) warning.textContent = "A synthetic schedule operation is completing in memory. No second change can start.";
  else warning.textContent = "This synthetic scheduler is interactive. No host task, email, or service is changed.";

  const installLabel = schedule.installed ? "Refresh" : "Install";
  setSwappingText("schedule-install-heading", installLabel);
  setSwappingText("schedule-install-button-label", installLabel);
  setText("schedule-install-copy", schedule.installed
    ? "Simulate refreshing the verified host schedule after configuration changes."
    : "Simulate creating the verified host schedule from the configured day and local time.");

  for (const button of document.querySelectorAll("[data-schedule-action]")) {
    const action = button.dataset.scheduleAction;
    let available = action === "install";
    if (action === "enable") available = schedule.installed && !schedule.enabled;
    if (action === "disable") available = schedule.installed && schedule.enabled;
    if (action === "remove") available = schedule.installed;
    button.disabled = blocked || !available;
  }

  const confirmation = byId("schedule-confirmation");
  const pending = state.schedulePendingAction;
  confirmation.hidden = !pending;
  if (pending) {
    const copy = scheduleActionCopy(pending, day, time, schedule.installed);
    setText("schedule-confirmation-heading", copy.heading);
    setText("schedule-confirmation-copy", copy.copy);
    setText("schedule-confirm-label", copy.label);
    setText("schedule-confirm-help", copy.help);
    const confirmed = byId("schedule-confirm").checked;
    byId("schedule-confirm-run").disabled = blocked || !confirmed;
    setSwappingButtonText("schedule-confirm-run", state.scheduleStarting ? "Running simulation..." : "Run simulation");
  }
  renderScheduleOperation(operation);
}

function renderScheduleOperation(operation) {
  if (!operation) {
    setText("schedule-current-heading", "No schedule change recorded");
    setText("schedule-current-copy", "No synthetic schedule operation has started.");
    setText("schedule-current-time", "Not recorded");
    setChip("schedule-current-chip", "Idle", "neutral");
    return;
  }
  const action = titleCase(operation.action);
  let heading = `${action} schedule ${titleCase(operation.state)}`;
  let copy = "The in-memory mock is waiting to report a synthetic result.";
  if (operation.state === "queued") {
    heading = `${action} schedule queued`;
    copy = "The simulated host approval step is queued; no system prompt appears.";
  } else if (operation.state === "running") {
    heading = `${action} schedule in progress`;
    copy = "The fictional host approval step is running in memory; no system prompt or mutation occurs.";
  } else if (operation.state === "succeeded") {
    heading = `${action} schedule completed`;
    copy = "The simulation completed and the Manager observed the expected fictional scheduler state.";
  } else if (operation.state === "failed") {
    heading = `${action} schedule was not completed`;
    copy = scheduleFailureCopy(operation.errorCategory, operation.supportCode);
  }
  setText("schedule-current-heading", heading);
  setText("schedule-current-copy", copy);
  const time = operation.finishedAtUtc ? `Finished ${formatDate(operation.finishedAtUtc)}` : `Started ${formatDate(operation.startedAtUtc)}`;
  setText("schedule-current-time", time);
  setChip("schedule-current-chip", titleCase(operation.state), operation.state === "succeeded" ? "good" : operation.state === "failed" ? "bad" : scheduleOperationIsActive(operation) ? "pending" : "neutral");
}

function configEditorValue(name) {
  return state.editor?.fields?.find((field) => field.name === name)?.value;
}

function scheduleOperationIsActive(operation) {
  return Boolean(operation && ["queued", "running"].includes(operation.state));
}

function scheduleActionCopy(action, day, time, scheduleInstalled = false) {
  switch (action) {
  case "install": return scheduleInstalled
    ? { heading: "Refresh the fictional weekly schedule", copy: `Model an update for ${day} at ${time} local time.`, label: "Simulate refreshing this owned schedule", help: "The GUI preview changes only temporary in-memory state." }
    : { heading: "Install the fictional weekly schedule", copy: `Model a schedule for ${day} at ${time} local time.`, label: "Simulate installing this schedule", help: "The GUI preview changes only temporary in-memory state." };
  case "enable": return { heading: "Enable fictional scheduled delivery", copy: "Model allowing the ownership-verified schedule to start on its weekly window.", label: "Simulate enabling this schedule", help: "No task is enabled and no newsletter is sent." };
  case "disable": return { heading: "Disable fictional scheduled starts", copy: "Model preserving the schedule definition while preventing future starts.", label: "Simulate disabling this schedule", help: "No host task or process is changed." };
  case "remove": return { heading: "Remove the fictional schedule", copy: "Model deleting only the ownership-verified schedule while preserving in-memory demo state.", label: "Simulate removing this schedule", help: "Reloading the page restores the initial fictional state." };
  default: return { heading: "Confirm simulated schedule change", copy: "Review this typed fictional operation.", label: "Confirm this simulated change", help: "No administrator approval or host mutation occurs." };
  }
}

function scheduleFailureCopy(category, supportCode) {
  const suffix = supportCode ? ` Support code: ${supportCode}.` : "";
  switch (category) {
  case "elevation-declined": return "The fictional host approval was declined or closed." + suffix;
  case "configuration-changed": return "The synthetic configuration changed while approval was pending. Refresh and retry." + suffix;
  case "task-not-found": return "The expected fictional schedule was not found." + suffix;
  case "task-ownership-mismatch": return "The fictional same-named schedule did not match this installation and was left untouched." + suffix;
  case "schedule-invalid": return "The fictional day or time could not be interpreted safely." + suffix;
  case "renderer-missing": return "The mock renderer is unavailable, so the fictional schedule was not enabled." + suffix;
  case "postcondition-failed": return "The simulation returned, but the expected scheduler state could not be verified." + suffix;
  case "schedule-configuration-read-failed": return "The simulation could not validate the fictional schedule configuration." + suffix;
  case "task-definition-failed": return "The synthetic scheduler rejected the fictional definition." + suffix;
  case "task-mutation-failed": return "The synthetic scheduler could not apply the fictional change." + suffix;
  case "task-verification-failed": return "The simulation could not verify the resulting fictional owned state." + suffix;
  case "task-read-access-failed": return "The simulation could not read the fictional schedule state." + suffix;
  case "manager-restarted": return "The demo state changed while the simulation was pending; reload to reset it." + suffix;
  default: return "The schedule simulation did not complete successfully." + suffix;
  }
}

function renderConfig() {
  const config = state.config;
  const grid = byId("config-grid");
  grid.replaceChildren();
  setChip("config-chip", titleCase(config.state), config.valid ? "good" : config.exists ? "bad" : "neutral");
  if (!config.fields.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = config.exists ? "The fictional configuration could not be displayed safely." : "No demo configuration is loaded. Reload the page to restore it.";
    grid.append(empty);
    return;
  }
  for (const field of config.fields) {
    const card = document.createElement("article");
    card.className = `config-field${field.secret ? " secret" : ""}`;
    const label = document.createElement("small");
    label.textContent = `${field.name} · ${field.type}`;
    const value = document.createElement("strong");
    value.textContent = field.secret ? (field.secret.configured ? "Configured · value withheld" : "Not configured") : displayValue(field.value);
    card.append(label, value);
    grid.append(card);
  }
}

function renderConfigEditor() {
  const editor = state.editor;
  const form = byId("config-form");
  const blocked = byId("config-blocked");
  const sections = byId("config-sections");
  clearConfigErrors();
  clearAllRevealedSecrets();
  sections.replaceChildren();
  setChip("config-chip", titleCase(editor.state), editor.state === "ready" ? "good" : editor.valid ? "neutral" : "bad");
  form.hidden = !editor.valid;
  blocked.hidden = editor.valid;
  if (!editor.valid) {
    renderDirectPlexNotice();
    renderDiscovery();
    return;
  }

  const fieldsByGroup = new Map(editor.groups.map((group) => [group, []]));
  for (const field of editor.fields) {
    if (guidedConfigFields.has(field.name)) continue;
    if (!fieldsByGroup.has(field.group)) fieldsByGroup.set(field.group, []);
    fieldsByGroup.get(field.group).push(field);
  }
  for (const [group, fields] of fieldsByGroup) {
    if (!fields.length) continue;
    const section = document.createElement("section");
    section.className = "config-section";
    const heading = document.createElement("div");
    heading.className = "config-section-heading";
    const title = document.createElement("h2");
    title.textContent = group;
    const count = document.createElement("small");
    count.textContent = `${fields.length} ${fields.length === 1 ? "setting" : "settings"}`;
    heading.append(title, count);
    const grid = document.createElement("div");
    grid.className = "config-editor-grid";
    for (const field of fields) grid.append(createConfigControl(field));
    section.append(heading, grid);
    sections.append(section);
  }
  for (const field of editor.fields.filter((candidate) => guidedConfigFields.has(candidate.name))) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.id = `config-${field.name}`;
    input.name = field.name;
    input.value = Array.isArray(field.value) ? field.value.join(", ") : "";
    sections.append(input);
  }
  byId("config-save-copy").textContent = "The mock API validates values in this tab, records a fictional backup, runs passing synthetic checks, and refreshes six bundled previews. Nothing is persisted.";
  if (Object.keys(editor.issues || {}).length) {
    showConfigErrors("Complete the required setup fields before saving.", editor.issues, false);
  }
  renderDirectPlexNotice();
  renderDiscovery();
}

function renderDirectPlexNotice() {
  const notice = byId("direct-plex-notice");
  const status = state.editor?.directPlex;
  const visible = Boolean(state.editor?.exists && status && (!status.urlConfigured || (!status.tokenConfigured && !status.runtimeTokenAvailable)));
  notice.hidden = !visible;
  if (!visible) return;
  const legacy = Boolean(status.legacyFieldsMissing);
  setText("direct-plex-notice-heading", legacy ? "Legacy config needs one direct Plex review" : "Complete optional direct Plex access");
  let copy = legacy
    ? "This fictional legacy scenario omits one or both direct Plex fields so the review workflow can be explored. "
    : "Optional direct Plex access is incomplete in this fictional scenario. ";
  if (!status.urlConfigured) copy += "Use an invented .invalid URL; this preview never connects to it. ";
  if (!status.tokenConfigured) copy += "The demo secret control exposes only a fixed placeholder and never retains an entered value. ";
  copy += "Validate, save, and verify to model the passing in-memory checks.";
  setText("direct-plex-notice-copy", copy);
}

function reviewDirectPlexFields() {
  const input = byId("config-PlexServerUrl") || byId("config-PlexToken");
  input?.scrollIntoView({ behavior: "smooth", block: "center" });
  setTimeout(() => input?.focus({ preventScroll: true }), 250);
}

function renderDiscovery() {
  if (state.discovery && state.discovery.configRevision !== state.editor?.revision) state.discovery = null;
  const confirm = byId("discovery-confirm");
  const button = byId("discovery-run-button");
  const ready = state.editor?.state === "ready";
  const networkBusy = state.discoveryRunning || state.verificationRunning || state.smtpVerificationRunning;
  button.disabled = networkBusy || !ready || !confirm.checked;
  setSwappingButtonText("discovery-run-button", state.discoveryRunning ? "Loading fictional choices..." : "Refresh fictional choices");
  if (!state.discovery) {
    byId("discovery-results").hidden = true;
    byId("discovery-message").textContent = ready
      ? "A simulated save loads these choices automatically. Confirm above to replay bundled discovery now."
      : "Save the synthetic configuration before loading fictional choices.";
    renderUserComboboxes();
    return;
  }
  byId("discovery-results").hidden = false;
  byId("discovery-message").textContent = `Fictional choices loaded ${formatDate(state.discovery.completedAtUtc)} and retained only in memory for this tab.`;
  renderDiscoveredLibraries();
  renderDiscoveredUsers();
  renderUserComboboxes();
}

function currentListField(name) {
  const input = byId(`config-${name}`);
  if (!input) return [];
  return input.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean);
}

function setListField(name, values) {
  const input = byId(`config-${name}`);
  if (input) input.value = [...new Set(values)].join(", ");
}

function renderDiscoveredLibraries() {
  const container = byId("discovery-libraries");
  container.replaceChildren();
  const libraries = state.discovery?.libraries || [];
  setText("discovery-library-count", `${libraries.length} fictional`);
  const configured = new Set(currentListField("IncludedLibraryIds"));
  const selected = configured.size ? configured : new Set(libraries.map((item) => item.id));
  for (const item of libraries) {
    const label = document.createElement("label");
    label.className = "choice-row";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = selected.has(item.id);
    input.dataset.choiceId = item.id;
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `${titleCase(item.mediaType)} · section ${item.id}${item.itemCount ? ` · ${item.itemCount} items` : ""}`;
    copy.append(name, detail);
    input.addEventListener("change", () => {
      const unknown = currentListField("IncludedLibraryIds").filter((id) => !libraries.some((library) => library.id === id));
      const known = [...container.querySelectorAll("input:checked")].map((choice) => choice.dataset.choiceId);
      setListField("IncludedLibraryIds", [...unknown, ...known]);
    });
    label.append(input, copy);
    container.append(label);
  }
}

function renderDiscoveredUsers() {
  const container = byId("discovery-users");
  container.replaceChildren();
  const users = state.discovery?.users || [];
  const legacyRuleCount = Number(state.discovery?.legacyRuleCount || 0);
  const matchedLegacyRuleCount = Number(state.discovery?.matchedLegacyRuleCount || 0);
  const legacySummary = legacyRuleCount ? ` · ${matchedLegacyRuleCount}/${legacyRuleCount} legacy matched` : "";
  setText("discovery-user-count", `${users.length} fictional${legacySummary}`);
  const configured = new Set(currentListField("ExcludedUserIds"));
  const orderedUsers = [...users].sort((left, right) => {
    const leftExcluded = configured.has(left.id) || left.legacyRuleExcluded === true;
    const rightExcluded = configured.has(right.id) || right.legacyRuleExcluded === true;
    if (leftExcluded !== rightExcluded) return leftExcluded ? -1 : 1;
    return left.name.localeCompare(right.name, undefined, { sensitivity: "base" });
  });
  for (const item of orderedUsers) {
    const label = document.createElement("label");
    label.className = "choice-row";
    const input = document.createElement("input");
    input.type = "checkbox";
    const configuredByID = configured.has(item.id);
    const legacyRuleExcluded = item.legacyRuleExcluded === true;
    input.checked = configuredByID || legacyRuleExcluded;
    input.disabled = legacyRuleExcluded;
    input.dataset.choiceId = item.id;
    input.dataset.configuredId = String(configuredByID);
    label.classList.toggle("legacy-exclusion", legacyRuleExcluded);
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `User ${item.id} · ${titleCase(item.eligibility)}${item.role ? ` · ${titleCase(item.role)}` : ""}${legacyRuleExcluded ? " · Excluded by existing config" : ""}`;
    copy.append(name, detail);
    input.addEventListener("change", () => {
      const unknown = currentListField("ExcludedUserIds").filter((id) => !users.some((user) => user.id === id));
      const known = [...container.querySelectorAll("input:checked")]
        .filter((choice) => !choice.disabled || choice.dataset.configuredId === "true")
        .map((choice) => choice.dataset.choiceId);
      setListField("ExcludedUserIds", [...unknown, ...known]);
    });
    label.append(input, copy);
    container.append(label);
  }
}

function renderUserDatalist() {
  const list = byId("tautulli-user-choices");
  list.replaceChildren();
  for (const item of state.discovery?.users || []) {
    const option = document.createElement("option");
    option.value = item.id;
    option.label = `${item.name} · ${titleCase(item.eligibility)}${item.role ? ` · ${titleCase(item.role)}` : ""}`;
    list.append(option);
  }
}

function renderUserComboboxes() {
  document.querySelectorAll("[data-user-combobox]").forEach((container) => renderUserComboboxOptions(container));
}

function renderUserComboboxOptions(container) {
  const input = container.querySelector("input");
  const list = container.querySelector(".user-combobox-options");
  const query = container.dataset.filter === "true" ? input.value.trim().toLowerCase() : "";
  const users = (state.discovery?.users || []).filter((item) => !query || item.id.includes(query) || item.name.toLowerCase().includes(query));
  list.replaceChildren();
  if (!users.length) {
    const empty = document.createElement("p");
    empty.className = "user-combobox-empty";
    empty.textContent = state.discovery ? "No matching fictional Tautulli user." : "Load fictional Tautulli choices from Config to browse users.";
    list.append(empty);
    return;
  }
  for (const item of users) {
    const option = document.createElement("button");
    option.type = "button";
    option.className = "user-combobox-option";
    option.setAttribute("role", "option");
    option.setAttribute("aria-selected", String(input.value === item.id));
    option.tabIndex = -1;
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `User ${item.id} - ${titleCase(item.eligibility)}${item.role ? ` - ${titleCase(item.role)}` : ""}`;
    option.append(name, detail);
    option.addEventListener("click", () => selectUserComboboxOption(container, item.id));
    option.addEventListener("keydown", (event) => navigateUserComboboxOptions(event, container, option));
    list.append(option);
  }
}

function setUserComboboxOpen(container, open) {
  const input = container.querySelector("input");
  const toggle = container.querySelector(".user-combobox-toggle");
  const list = container.querySelector(".user-combobox-options");
  if (open) renderUserComboboxOptions(container);
  list.hidden = !open;
  container.classList.toggle("open", open);
  input.setAttribute("aria-expanded", String(open));
  toggle.setAttribute("aria-expanded", String(open));
}

function selectUserComboboxOption(container, id) {
  const input = container.querySelector("input");
  input.value = id;
  container.dataset.filter = "false";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  setUserComboboxOpen(container, false);
  input.focus();
}

function navigateUserComboboxOptions(event, container, option) {
  const options = [...container.querySelectorAll(".user-combobox-option")];
  const index = options.indexOf(option);
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    option.click();
  } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const offset = event.key === "ArrowDown" ? 1 : -1;
    options[(index + offset + options.length) % options.length]?.focus();
  } else if (event.key === "Escape") {
    event.preventDefault();
    setUserComboboxOpen(container, false);
    container.querySelector("input").focus();
  }
}

function initializeUserCombobox(container) {
  const input = container.querySelector("input");
  const toggle = container.querySelector(".user-combobox-toggle");
  input.addEventListener("click", () => {
    if (!container.classList.contains("open")) {
      container.dataset.filter = "false";
      setUserComboboxOpen(container, true);
    }
  });
  input.addEventListener("input", () => {
    container.dataset.filter = "true";
    setUserComboboxOpen(container, true);
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setUserComboboxOpen(container, true);
      container.querySelector(".user-combobox-option")?.focus();
    } else if (event.key === "Escape") {
      setUserComboboxOpen(container, false);
    }
  });
  toggle.addEventListener("click", () => {
    const open = !container.classList.contains("open");
    container.dataset.filter = "false";
    setUserComboboxOpen(container, open);
    if (open) input.focus();
  });
}

async function runTautulliDiscovery() {
  if (state.discoveryRunning || state.verificationRunning || state.smtpVerificationRunning || state.editor?.state !== "ready" || !byId("discovery-confirm").checked) return;
  state.discoveryRunning = true;
  renderDiscovery();
  renderVerification();
  setGlobalStatus("Loading fictional Tautulli choices...");
  try {
    state.discovery = await request("/api/v1/discovery/tautulli", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
    byId("discovery-confirm").checked = false;
    setGlobalStatus("Fictional choices loaded in memory.", true);
  } catch (error) {
    byId("discovery-message").textContent = error.message;
    setGlobalStatus(error.message, true);
  } finally {
    state.discoveryRunning = false;
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // The manual result remains visible even if the durable summary cannot be refreshed.
    }
    renderDiscovery();
    renderVerification();
  }
}

function createConfigControl(field) {
  const control = document.createElement("div");
  control.className = `config-control config-control-${field.type}`;
  control.dataset.configField = field.name;
  const heading = document.createElement("span");
  heading.className = "config-control-heading";
  const label = document.createElement("strong");
  label.textContent = field.label;
  label.id = `config-label-${field.name}`;
  const key = document.createElement("small");
  key.textContent = field.required ? `${field.name} · required` : field.name;
  heading.append(label, key);
  control.append(heading);

  const id = `config-${field.name}`;
  let input;
  if (field.type === "boolean") {
    input = document.createElement("input");
    input.type = "checkbox";
    input.checked = Boolean(field.value);
    const toggle = document.createElement("span");
    toggle.className = "config-toggle";
    toggle.append(input, document.createElement("span"));
    const stateLabel = document.createElement("em");
    stateLabel.textContent = input.checked ? "Enabled" : "Disabled";
    input.addEventListener("change", () => { stateLabel.textContent = input.checked ? "Enabled" : "Disabled"; });
    toggle.append(stateLabel);
    control.append(toggle);
  } else if (field.type === "select") {
    input = document.createElement("select");
    for (const optionValue of field.options || []) {
      const option = document.createElement("option");
      option.value = optionValue;
      option.textContent = optionValue;
      option.selected = String(field.value) === optionValue;
      input.append(option);
    }
    control.append(input);
  } else {
    input = document.createElement("input");
    input.type = configInputType(field.type);
    input.placeholder = field.type === "secret" && field.secret?.configured
      ? "Fictional placeholder is configured"
      : field.type === "secret" && field.secret?.availableFromRuntime
        ? "Fictional runtime placeholder available"
        : field.placeholder || "";
    if (field.type === "integer") {
      if (field.min !== undefined) input.min = String(field.min);
      if (field.max !== undefined) input.max = String(field.max);
      input.step = "1";
      input.value = field.value ?? "";
    } else if (field.type === "string-list" || field.type === "email-list") {
      input.value = Array.isArray(field.value) ? field.value.join(", ") : "";
    } else if (field.type !== "secret") {
      input.value = field.value ?? "";
    }
    if (field.type === "secret") {
      input.autocomplete = "new-password";
      const shell = document.createElement("span");
      shell.className = "secret-input-shell";
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "secret-toggle-button";
      toggle.disabled = !field.secret?.configured;
      toggle.append(createMaterialIcon("visibility"));
      shell.append(input, toggle);
      control.append(shell);
      input.addEventListener("input", () => {
        const active = activeSecretReveals.get(field.name);
        if (active && input.value !== active.value) forgetSecretReveal(field.name, false);
        if (!input.value && !field.secret?.configured) input.type = "password";
        toggle.disabled = !input.value && !field.secret?.configured;
        updateSecretToggle(field, input, toggle);
      });
      toggle.addEventListener("click", () => toggleSecretVisibility(field, input, toggle));
      updateSecretToggle(field, input, toggle);
    } else {
      control.append(input);
    }
  }
  input.id = id;
  input.name = field.name;
  input.setAttribute("aria-labelledby", label.id);

  if (field.type === "secret") {
    const secretLine = document.createElement("span");
    secretLine.className = "secret-state";
    const stateText = document.createElement("span");
    stateText.textContent = field.secret?.configured
      ? "Fictional placeholder - hidden"
      : field.secret?.availableFromRuntime
        ? "Fictional runtime placeholder"
        : "No fictional placeholder";
    stateText.id = `config-secret-state-${field.name}`;
    secretLine.append(stateText);
    if (field.secret?.configured) {
      const clearLabel = document.createElement("label");
      clearLabel.className = "secret-clear";
      const clear = document.createElement("input");
      clear.type = "checkbox";
      clear.id = `config-clear-${field.name}`;
      clearLabel.append(clear, " Clear fictional placeholder");
      secretLine.append(clearLabel);
      input.addEventListener("input", () => { if (input.value) clear.checked = false; });
      clear.addEventListener("change", () => {
        if (clear.checked) {
          forgetSecretReveal(field.name, true);
          input.value = "";
          input.type = "password";
          const toggle = control.querySelector(".secret-toggle-button");
          if (toggle) updateSecretToggle(field, input, toggle);
        }
      });
    }
    control.append(secretLine);
  }
  if (field.help) {
    const help = document.createElement("span");
    help.className = "config-help";
    help.textContent = field.help;
    control.append(help);
  }
  const error = document.createElement("span");
  error.className = "config-field-error";
  error.id = `config-error-${field.name}`;
  control.append(error);
  return control;
}

function updateSecretToggle(field, input, button) {
  const hasValue = input.value !== "";
  const visible = hasValue && input.type === "text";
  button.classList.toggle("visible", visible);
  button.setAttribute("aria-pressed", String(visible));
  if (visible) button.setAttribute("aria-label", `Hide ${field.label}`);
  else if (hasValue) button.setAttribute("aria-label", `Show ${field.label}`);
  else button.setAttribute("aria-label", `Reveal fictional ${field.label} placeholder`);
}

function toggleSecretVisibility(field, input, button) {
  if (input.value) {
    input.type = input.type === "password" ? "text" : "password";
    updateSecretToggle(field, input, button);
    return;
  }
  if (field.secret?.configured) openSecretReveal(field, input, button);
}

function openSecretReveal(field, input, button) {
  pendingSecretReveal = { field, input, button };
  const passwordRequired = Boolean(state.authAccess?.authenticationRequired);
  byId("secret-reveal-title").textContent = `Reveal fictional ${field.label}`;
  byId("secret-reveal-eyebrow").textContent = passwordRequired ? "Demo password confirmation" : "Demo placeholder reveal";
  byId("secret-reveal-copy").textContent = passwordRequired
    ? "Enter the temporary demo password. A fixed non-secret placeholder will appear for 30 seconds."
    : "Confirm this demonstration. A fixed non-secret placeholder will appear for 30 seconds.";
  byId("secret-reveal-message").textContent = "";
  const passwordInput = byId("secret-reveal-password");
  passwordInput.value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  passwordInput.hidden = !passwordRequired;
  passwordInput.closest(".masked-input-shell").hidden = !passwordRequired;
  passwordInput.required = passwordRequired;
  byId("secret-reveal-password-label").hidden = !passwordRequired;
  byId("secret-reveal-dialog").showModal();
  (passwordRequired ? passwordInput : byId("secret-reveal-submit")).focus();
}

async function submitSecretReveal(event) {
  event.preventDefault();
  const target = pendingSecretReveal;
  if (!target) return;
  const submit = byId("secret-reveal-submit");
  const passwordInput = byId("secret-reveal-password");
  submit.disabled = true;
  const passwordRequired = Boolean(state.authAccess?.authenticationRequired);
  setSwappingButtonText("secret-reveal-submit", passwordRequired ? "Verifying..." : "Revealing...");
  byId("secret-reveal-message").textContent = "";
  try {
    const result = await request(`/api/v1/config/secrets/${encodeURIComponent(target.field.name)}/reveal`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, password: passwordInput.value }),
    });
    passwordInput.value = "";
    clearAllRevealedSecrets();
    target.input.value = result.value;
    target.input.type = "text";
    const timer = setTimeout(() => forgetSecretReveal(target.field.name, true), 30000);
    activeSecretReveals.set(target.field.name, { value: result.value, input: target.input, button: target.button, timer });
    const stateText = byId(`config-secret-state-${target.field.name}`);
    if (stateText) stateText.textContent = "Revealed temporarily - clears in 30 seconds";
    updateSecretToggle(target.field, target.input, target.button);
    byId("secret-reveal-dialog").close();
    target.input.focus();
    setGlobalStatus(`Fictional ${target.field.label} placeholder revealed temporarily.`, true);
  } catch (error) {
    passwordInput.value = "";
    byId("secret-reveal-message").textContent = error.message;
    (passwordRequired ? passwordInput : submit).focus();
  } finally {
    submit.disabled = false;
    setSwappingButtonText("secret-reveal-submit", "Reveal for 30 seconds");
  }
}

function forgetSecretReveal(name, clearValue) {
  const active = activeSecretReveals.get(name);
  if (!active) return;
  clearTimeout(active.timer);
  activeSecretReveals.delete(name);
  if (clearValue && active.input.value === active.value) active.input.value = "";
  active.input.type = "password";
  const field = state.editor?.fields.find((candidate) => candidate.name === name);
  const stateText = byId(`config-secret-state-${name}`);
  if (stateText) stateText.textContent = "Fictional placeholder - hidden";
  if (field) updateSecretToggle(field, active.input, active.button);
}

function clearAllRevealedSecrets() {
  for (const name of [...activeSecretReveals.keys()]) forgetSecretReveal(name, true);
}

function closeSecretRevealDialog() {
  byId("secret-reveal-password").value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  byId("secret-reveal-message").textContent = "";
  pendingSecretReveal = null;
  if (byId("secret-reveal-dialog").open) byId("secret-reveal-dialog").close();
}

function configInputType(type) {
  if (["url", "email", "time", "password"].includes(type)) return type;
  if (type === "integer") return "number";
  if (type === "secret") return "password";
  return "text";
}

function collectConfigSaveRequest() {
  const values = {};
  const secrets = {};
  for (const field of state.editor.fields) {
    const input = byId(`config-${field.name}`);
    if (field.type === "secret") {
      const clear = byId(`config-clear-${field.name}`);
      if (clear?.checked) secrets[field.name] = { action: "clear" };
      else if (activeSecretReveals.get(field.name)?.value === input.value) secrets[field.name] = { action: "preserve" };
      else if (input.value !== "") secrets[field.name] = { action: "replace", value: input.value };
      else secrets[field.name] = { action: "preserve" };
    } else if (field.type === "boolean") {
      values[field.name] = input.checked;
    } else if (field.type === "integer") {
      values[field.name] = input.value === "" ? null : Number(input.value);
    } else if (field.type === "string-list" || field.type === "email-list") {
      values[field.name] = input.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean);
    } else {
      values[field.name] = input.value;
    }
  }
  return { expectedRevision: state.editor.revision, values, secrets };
}

const setupWorkflowSteps = ["choices", "lan", "smtp", "previews"];

function beginSetupWorkflow() {
  state.setupWorkflow = {
    available: true,
    running: true,
    steps: Object.fromEntries(setupWorkflowSteps.map((name) => [name, { state: "waiting", summary: "Waiting for the synthetic configuration." }])),
  };
  state.setupWorkflowRunning = true;
  renderSetupWorkflow();
}

function updateSetupWorkflowStep(name, stepState, summary) {
  if (!state.setupWorkflow?.steps?.[name]) return;
  state.setupWorkflow.steps[name] = { state: stepState, summary };
  renderSetupWorkflow();
}

function renderSetupWorkflow() {
  const panel = byId("setup-workflow");
  if (!panel) return;
  if (!state.setupWorkflow) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  const presentation = setupWorkflowPresentation();
  setChip("setup-workflow-chip", presentation.label, presentation.tone);
  setText("setup-workflow-summary", presentation.summary);
  for (const name of setupWorkflowSteps) {
    const step = state.setupWorkflow.steps[name];
    setText(`setup-${name}-summary`, step.summary);
    const tone = step.state === "passed" ? "good" : step.state === "failed" ? "bad" : ["running", "waiting"].includes(step.state) ? "pending" : "neutral";
    setChip(`setup-${name}-chip`, titleCase(step.state), tone);
    const row = byId(`setup-${name}-step`);
    row.classList.toggle("active", step.state === "running");
  }
  renderDashboardConfigStatus();
}

async function refreshConfigurationStatus() {
  const configurationStatus = await request("/api/v1/config/status");
  state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
  renderSetupWorkflow();
}

async function retainSkippedPreviewStatus(revision, reason) {
  try {
    const configurationStatus = await request("/api/v1/config/status/previews/skipped", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, reason }),
    });
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : state.setupWorkflow;
  } catch (_) {
    // The local result remains visible; a later refresh will load the durable server record.
  }
  renderSetupWorkflow();
}

async function runPostSaveSetup(revision) {
  let discovered = null;
  state.discoveryRunning = true;
  updateSetupWorkflowStep("choices", "running", "Loading bundled fictional libraries, users, and roles...");
  renderDiscovery();
  renderVerification();
  try {
    discovered = await request("/api/v1/discovery/tautulli", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
    });
    state.discovery = discovered;
    if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
    updateSetupWorkflowStep("choices", "passed", `${discovered.libraries?.length || 0} fictional libraries and ${discovered.users?.length || 0} fictional users loaded in memory.`);
  } catch (error) {
    updateSetupWorkflowStep("choices", "failed", error.message);
  } finally {
    state.discoveryRunning = false;
    renderDiscovery();
    renderVerification();
  }

  state.verificationRunning = true;
  updateSetupWorkflowStep("lan", "running", "Simulating Tautulli and direct Plex checks with fictional endpoints...");
  renderDiscovery();
  renderVerification();
  try {
    const result = await request("/api/v1/checks/integrations", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, last: result };
    updateSetupWorkflowStep("lan", result.overall, result.overall === "passed"
      ? "Synthetic Tautulli and direct Plex verification passed. Detailed fictional evidence is available under Verify."
      : "The synthetic connection checks completed with a result that needs review under Verify.");
  } catch (error) {
    updateSetupWorkflowStep("lan", "failed", error.message);
  } finally {
    state.verificationRunning = false;
    renderDiscovery();
    renderVerification();
  }

  state.smtpVerificationRunning = true;
  updateSetupWorkflowStep("smtp", "running", "Simulating SMTP reachability and STARTTLS without opening a socket...");
  renderDiscovery();
  renderVerification();
  try {
    const result = await request("/api/v1/checks/smtp-network", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, smtp: result };
    updateSetupWorkflowStep("smtp", result.overall, result.summary);
  } catch (error) {
    updateSetupWorkflowStep("smtp", "failed", error.message);
  } finally {
    state.smtpVerificationRunning = false;
    renderDiscovery();
    renderVerification();
  }

  const suggestedUserID = discovered?.suggestedPreviewUserId || "";
  if (!validPreviewUserID(suggestedUserID)) {
    updateSetupWorkflowStep("previews", "skipped", "The fictional roster has no unambiguous administrator ID. Choose a demo user under Previews to model the six states manually.");
    await retainSkippedPreviewStatus(revision, "owner-not-found");
  } else if (operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation)) {
    updateSetupWorkflowStep("previews", "skipped", "Another Manager or schedule operation is active. Generate previews manually after it finishes.");
    await retainSkippedPreviewStatus(revision, "operation-active");
  } else {
    state.operationStarting = true;
    state.operationStartingType = "preview-all";
    updateSetupWorkflowStep("previews", "running", "Refreshing six bundled newsletter previews for the fictional administrator...");
    renderOperations();
    try {
      state.operation = await request("/api/v1/operations", {
        method: "POST",
        body: JSON.stringify({ type: "preview-all", expectedRevision: revision, userId: suggestedUserID, confirmNoSend: true }),
      });
      updateSetupWorkflowStep("previews", "running", "Six-state in-memory preview simulation started. No service or file is contacted.");
      manageOperationPolling();
    } catch (error) {
      updateSetupWorkflowStep("previews", error.code === "operation-busy" || error.code === "schedule-busy" ? "skipped" : "failed", error.message);
    } finally {
      state.operationStarting = false;
      state.operationStartingType = "";
      renderOperations();
    }
  }

  state.setupWorkflow.running = false;
  state.setupWorkflowRunning = false;
  try {
    await refreshConfigurationStatus();
  } catch (_) {
    renderSetupWorkflow();
  }
  try {
    const [status, verification] = await Promise.all([
      request("/api/v1/status"),
      request("/api/v1/checks/integrations"),
    ]);
    state.status = status;
    state.verification = verification || { last: null, smtp: null };
    renderStatus();
    renderVerification();
  } catch (_) {
    renderDashboardConfigStatus();
    renderIntegrationStatus();
  }
  try {
    state.diagnostics = await request("/api/v1/diagnostics");
    renderAbout();
  } catch (_) {
    // Diagnostics are supplementary; the individual setup results remain visible.
  }
}

async function submitConfig(event) {
  event.preventDefault();
  clearConfigErrors();
  const saveButton = byId("config-save-button");
  saveButton.disabled = true;
  byId("config-reset-button").disabled = true;
  setSwappingButtonText("config-save-button", "Saving...");
  setGlobalStatus("Validating fictional configuration in memory...");
  try {
    const result = await request("/api/v1/config", { method: "PUT", body: JSON.stringify(collectConfigSaveRequest()) });
    state.editor = result.editor;
    beginSetupWorkflow();
    await loadAll();
    selectView("configuration");
    setGlobalStatus(result.backup ? "Demo configuration saved in memory with a fictional backup. Running synthetic checks..." : "Demo configuration saved in memory. Running synthetic checks...");
    await runPostSaveSetup(result.editor.revision);
    setGlobalStatus("Synthetic save verification finished. Review the results above.", true);
  } catch (error) {
    showConfigErrors(error.message, error.fields);
    setGlobalStatus(error.message, true);
  } finally {
    saveButton.disabled = false;
    byId("config-reset-button").disabled = false;
    setSwappingButtonText("config-save-button", "Validate, save, and verify");
  }
}

function showConfigErrors(message, fields = {}, scroll = true) {
  const alert = byId("config-errors");
  const list = byId("config-error-list");
  list.replaceChildren();
  const names = Object.keys(fields).sort();
  if (!names.length) {
    const item = document.createElement("li");
    item.textContent = message;
    list.append(item);
  }
  for (const name of names) {
    const item = document.createElement("li");
    const field = state.editor.fields.find((candidate) => candidate.name === name);
    item.textContent = `${field?.label || name}: ${fields[name]}`;
    list.append(item);
    const control = document.querySelector(`[data-config-field="${CSS.escape(name)}"]`);
    control?.classList.add("invalid");
    const input = byId(`config-${name}`);
    input?.setAttribute("aria-invalid", "true");
    const error = byId(`config-error-${name}`);
    if (error) error.textContent = fields[name];
  }
  alert.hidden = false;
  if (scroll) alert.scrollIntoView({ block: "start" });
}

function clearConfigErrors() {
  byId("config-errors").hidden = true;
  byId("config-error-list").replaceChildren();
  document.querySelectorAll("[data-config-field]").forEach((control) => control.classList.remove("invalid"));
  document.querySelectorAll("[data-config-field] input, [data-config-field] select").forEach((input) => input.removeAttribute("aria-invalid"));
  document.querySelectorAll(".config-field-error").forEach((error) => { error.textContent = ""; });
}

function renderBackups() {
  const list = byId("backup-list");
  list.replaceChildren();
  setText("backup-count", state.backups.length ? `${state.backups.length} fictional` : "None created");
  if (!state.backups.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No fictional backup exists yet. Reloading restores the initial demo configuration.";
    list.append(empty);
    return;
  }
  for (const backup of state.backups) {
    const row = document.createElement("article");
    row.className = "backup-row";
    const copy = document.createElement("div");
    const title = document.createElement("strong");
    title.textContent = formatDate(backup.createdAtUtc);
    const detail = document.createElement("small");
    detail.textContent = `${formatBytes(backup.sizeBytes)} · revision ${String(backup.revision || "").slice(0, 10)}`;
    copy.append(title, detail);
    const restoreButton = document.createElement("button");
    restoreButton.type = "button";
    restoreButton.className = "button button-secondary";
    restoreButton.textContent = "Restore";
    restoreButton.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
    const deleteButton = document.createElement("button");
    deleteButton.type = "button";
    deleteButton.className = "button button-danger";
    deleteButton.textContent = "Delete";
    deleteButton.setAttribute("aria-label", `Delete fictional configuration backup from ${formatDate(backup.createdAtUtc)}`);
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button button-secondary";
    cancel.textContent = "Cancel";
    cancel.hidden = true;
    const actions = document.createElement("div");
    actions.className = "backup-actions";
    const resetConfirmation = () => {
      delete row.dataset.backupAction;
      row.classList.remove("armed");
      restoreButton.hidden = false;
      restoreButton.className = "button button-secondary";
      setSwappingButtonElementText(restoreButton, "Restore");
      restoreButton.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
      deleteButton.hidden = false;
      setSwappingButtonElementText(deleteButton, "Delete");
      deleteButton.setAttribute("aria-label", `Delete fictional configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = true;
    };
    restoreButton.addEventListener("click", () => {
      if (row.dataset.backupAction === "restore") {
        restoreBackup(backup, restoreButton, cancel);
        return;
      }
      row.dataset.backupAction = "restore";
      row.classList.add("armed");
      deleteButton.hidden = true;
      restoreButton.className = "button button-danger";
      setSwappingButtonElementText(restoreButton, "Confirm restore");
      restoreButton.setAttribute("aria-label", `Confirm restore of configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = false;
    });
    deleteButton.addEventListener("click", () => {
      if (row.dataset.backupAction === "delete") {
        deleteBackup(backup, deleteButton, cancel);
        return;
      }
      row.dataset.backupAction = "delete";
      row.classList.add("armed");
      restoreButton.hidden = true;
      setSwappingButtonElementText(deleteButton, "Confirm delete");
      deleteButton.setAttribute("aria-label", `Permanently delete fictional configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = false;
    });
    cancel.addEventListener("click", resetConfirmation);
    actions.append(cancel, restoreButton, deleteButton);
    row.append(copy, actions);
    list.append(row);
  }
}

async function deleteBackup(backup, button, cancel) {
  button.disabled = true;
  cancel.disabled = true;
  setSwappingButtonElementText(button, "Deleting...");
  setGlobalStatus("Deleting the fictional backup from this in-memory preview...");
  try {
    await request(`/api/v1/config/backups/${encodeURIComponent(backup.id)}`, { method: "DELETE" });
    const result = await request("/api/v1/config/backups");
    state.backups = result.backups || [];
    renderBackups();
    setGlobalStatus("Fictional configuration backup deleted from this preview.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
    button.disabled = false;
    cancel.disabled = false;
    setSwappingButtonElementText(button, "Confirm delete");
  }
}

async function restoreBackup(backup, button, cancel) {
  button.disabled = true;
  cancel.disabled = true;
  setSwappingButtonElementText(button, "Restoring...");
  setGlobalStatus("Restoring the fictional backup in memory...");
  try {
    const result = await request(`/api/v1/config/backups/${encodeURIComponent(backup.id)}/restore`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision }),
    });
    await loadAll();
    selectView("configuration");
    setGlobalStatus(result.safetyBackup ? "Fictional backup restored in memory; a synthetic safety backup was recorded." : "Fictional backup restored in memory.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    button.disabled = false;
    cancel.disabled = false;
    setSwappingButtonElementText(button, "Restore");
  }
}

function appendVerificationResult(container, heading, checkState, summaryText) {
  const card = document.createElement("article");
  const tone = checkState === "passed" ? "good" : checkState === "failed" ? "bad" : "neutral";
  card.className = `verification-result ${checkState} state-card-${tone}`;
  const top = document.createElement("div");
  top.className = "card-topline";
  const title = document.createElement("h2");
  title.textContent = heading;
  const chip = document.createElement("span");
  chip.className = `state-chip ${tone}`;
  chip.textContent = titleCase(checkState);
  top.append(title, chip);
  const summary = document.createElement("p");
  summary.textContent = summaryText;
  card.append(top, summary);
  container.append(card);
}

function renderVerification() {
  const last = state.verification?.last || null;
  const smtp = state.verification?.smtp || null;
  const ready = state.editor?.state === "ready";
  const networkBusy = state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning;
  const results = byId("verification-results");
  const smtpResults = byId("smtp-verification-results");
  const confirm = byId("verification-confirm");
  const smtpConfirm = byId("smtp-verification-confirm");
  const runButton = byId("verification-run-button");
  const smtpRunButton = byId("smtp-verification-run-button");
  results.replaceChildren();
  smtpResults.replaceChildren();
  runButton.disabled = networkBusy || !confirm.checked || !ready;
  smtpRunButton.disabled = networkBusy || !smtpConfirm.checked || !ready;
  setSwappingButtonText("verification-run-button", state.verificationRunning ? "Running synthetic checks..." : "Run synthetic connection test");
  setSwappingButtonText("smtp-verification-run-button", state.smtpVerificationRunning ? "Simulating SMTP..." : "Run synthetic SMTP preflight");

  if (!ready) {
    byId("verification-message").textContent = "Save the fictional configuration before running the simulation.";
    byId("smtp-verification-message").textContent = "Save the fictional configuration before running the SMTP simulation.";
  } else {
    byId("verification-message").textContent = state.verificationRunning
      ? "Returning passing synthetic Tautulli and direct Plex results from memory."
      : "The button runs an in-memory simulation; no service request can occur.";
    byId("smtp-verification-message").textContent = state.smtpVerificationRunning
      ? "Returning a passing synthetic SMTP and STARTTLS result from memory."
      : "The button runs an in-memory simulation; no SMTP request can occur.";
  }

  const retainedLANState = retainedSetupCheckState("lan");
  const retainedSMTPState = retainedSetupCheckState("smtp");
  if (last) {
    setText("verification-observed", `Completed ${formatDate(last.completedAtUtc)} · ${titleCase(last.networkBoundary)}.`);
    for (const step of last.steps || []) {
      appendVerificationResult(results, step.service === "plex" ? "Direct Plex" : titleCase(step.service), step.state, step.summary);
    }
  } else if (retainedLANState) {
    setText("verification-observed", "Retained in memory from the latest synthetic setup validation.");
    appendVerificationResult(results, "Tautulli and direct Plex", retainedLANState, state.setupWorkflow.steps.lan.summary);
  } else {
    setText("verification-observed", "No synthetic integration result is available yet.");
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "Validate and save to run every synthetic setup check, or repeat this simulated connection test.";
    results.append(empty);
  }

  if (smtp) {
    setText("smtp-verification-observed", `Completed ${formatDate(smtp.completedAtUtc)} · ${titleCase(smtp.security)}.`);
    appendVerificationResult(smtpResults, "SMTP preflight", smtp.state, smtp.summary);
  } else if (retainedSMTPState) {
    setText("smtp-verification-observed", "Retained in memory from the latest synthetic setup validation.");
    appendVerificationResult(smtpResults, "SMTP preflight", retainedSMTPState, state.setupWorkflow.steps.smtp.summary);
  } else {
    setText("smtp-verification-observed", "No synthetic SMTP preflight is available yet.");
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "Validate and save to run every synthetic setup check, or repeat this simulated SMTP preflight.";
    smtpResults.append(empty);
  }

  const { overallLabel, overallTone } = renderIntegrationStatus();
  setChip("verification-chip", overallLabel, overallTone);
}

async function runVerification() {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || !byId("verification-confirm").checked || state.editor?.state !== "ready") return;
  state.verificationRunning = true;
  const button = byId("verification-run-button");
  setSwappingButtonText("verification-run-button", "Running synthetic checks...");
  renderVerification();
  renderDiscovery();
  setGlobalStatus("Running synthetic Tautulli and direct Plex checks in memory...");
  try {
    const result = await request("/api/v1/checks/integrations", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, last: result };
    byId("verification-confirm").checked = false;
    setGlobalStatus(result.overall === "failed" ? "Synthetic connection test completed with failures." : "Synthetic connection test passed. No network request occurred.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.verificationRunning = false;
    setSwappingButtonText("verification-run-button", "Run synthetic connection test");
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // The detailed result is already visible; a later refresh will load its durable server record.
    }
    renderVerification();
    renderDiscovery();
  }
}

async function runSMTPVerification() {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || !byId("smtp-verification-confirm").checked || state.editor?.state !== "ready") return;
  state.smtpVerificationRunning = true;
  renderVerification();
  renderDiscovery();
  setGlobalStatus("Running the synthetic SMTP and STARTTLS preflight in memory...");
  try {
    const result = await request("/api/v1/checks/smtp-network", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, smtp: result };
    byId("smtp-verification-confirm").checked = false;
    const message = result.overall === "failed"
      ? "Synthetic SMTP preflight completed with a failure. No network request occurred."
      : result.overall === "warning"
        ? "The fictional SMTP result warns that STARTTLS is disabled."
        : "Synthetic SMTP reachability and certificate-validated STARTTLS passed. No host was contacted.";
    setGlobalStatus(message, true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.smtpVerificationRunning = false;
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // The detailed result is already visible; a later refresh will load its durable server record.
    }
    renderVerification();
    renderDiscovery();
  }
}

function previewScenarioIndex(preview) {
  const match = String(preview?.name || "").match(/^preview-all-(\d{2})-/i);
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

function previewDisplayName(preview) {
  const name = String(preview?.name || "");
  const scenarios = [
    [/-00-index(?:\.html)?$/i, "Index"],
    [/-01-manual-welcome(?:\.html)?$/i, "Manual Welcome"],
    [/-02-new-user-no-history(?:\.html)?$/i, "New User - No History"],
    [/-03-new-user-with-history(?:\.html)?$/i, "New User - With History"],
    [/-04-normal-newsletter(?:\.html)?$/i, "Normal Newsletter"],
    [/-05-established-quiet(?:\.html)?$/i, "Established Quiet"],
    [/-06-established-warmup(?:\.html)?$/i, "Established Warnings"],
  ];
  return scenarios.find(([pattern]) => pattern.test(name))?.[1] || name;
}

function orderedPreviews() {
  return [...state.previews].sort((left, right) => {
    const scenarioDifference = previewScenarioIndex(left) - previewScenarioIndex(right);
    if (scenarioDifference) return scenarioDifference;
    return String(right.modifiedUtc || "").localeCompare(String(left.modifiedUtc || ""));
  });
}

function renderPreviews() {
  const list = byId("preview-list");
  list.replaceChildren();
  const previews = orderedPreviews();
  const previewStateCount = previews.filter((preview) => previewScenarioIndex(preview) > 0).length;
  setChip("preview-chip", state.previews.length ? `${previewStateCount} states + index` : "None generated", state.previews.length ? "good" : "neutral");
  if (!state.previews.length) {
    state.selectedPreviewID = "";
    byId("preview-placeholder").hidden = false;
    const frame = byId("preview-frame");
    frame.hidden = true;
    frame.removeAttribute("data-preview-id");
    frame.src = "about:blank";
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No bundled fictional previews are available in this demo.";
    list.append(empty);
    return;
  }
  for (const preview of previews) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "preview-button";
    button.dataset.previewId = preview.id;
    const name = document.createElement("strong");
    name.textContent = previewDisplayName(preview);
    const meta = document.createElement("small");
    meta.textContent = `${formatDate(preview.modifiedUtc)} · ${formatBytes(preview.sizeBytes)}`;
    button.append(name, meta);
    button.addEventListener("click", () => openPreview(preview.id, button));
    list.append(button);
  }
  const selected = previews.find((preview) => preview.id === state.selectedPreviewID);
  const latestRun = state.history.find((operation) => operation.type === "preview-all" && operation.state === "succeeded" && operation.generatedPreviewIds?.length);
  const generated = new Set(latestRun?.generatedPreviewIds || []);
  const preferred = selected
    || previews.find((preview) => preview.id === "demo-normal" && generated.has(preview.id))
    || previews.find((preview) => generated.has(preview.id))
    || previews.find((preview) => preview.id === "demo-normal")
    || previews[0];
  const button = list.querySelector(`[data-preview-id="${CSS.escape(preferred.id)}"]`);
  if (button) openPreview(preferred.id, button);
}

function renderOperations() {
  const operation = state.operation;
  const active = operationIsActive(operation);
  const scheduleActive = scheduleOperationIsActive(state.scheduleOperation);
  const manualSendType = byId("manual-send-mode").value === "send-welcome" ? "send-welcome" : "send-all";
  const manualWelcome = manualSendType === "send-welcome";
  const manualSendUserID = byId("manual-send-user-id").value.trim();
  const manualSendUserValid = !manualWelcome || validPreviewUserID(manualSendUserID);
  renderManualSendChoice(manualSendType);
  const userID = byId("preview-user-id").value.trim();
  const userIDValid = validPreviewUserID(userID);
  const confirmed = byId("preview-confirm").checked;
  const testUserID = byId("test-send-user-id").value.trim();
  const testUserIDValid = validPreviewUserID(testUserID);
  const testConfirmed = byId("test-send-confirm").checked;
  const manualSendConfirmed = byId("manual-send-confirm").checked;
  const ready = state.editor?.state === "ready";
  const startButton = byId("preview-run-button");
  startButton.disabled = state.operationStarting || state.operationCancelling || active || scheduleActive || !ready || !userIDValid || !confirmed;
  setSwappingButtonText("preview-run-button", state.operationStarting && state.operationStartingType === "preview-all" ? "Starting preview generation..." : active || scheduleActive ? "Another operation is active" : "Generate all previews");

  let message = "Choose a fictional numeric Tautulli user ID, then confirm the preview simulation.";
  if (!ready) message = "Save the fictional configuration before generating previews.";
  else if (active) message = operation.type === "preview-all" ? (operation.state === "cancelling" ? "Stopping the in-memory preview simulation..." : "Refreshing bundled previews in memory.") : "A fictional delivery simulation is active. Wait for its aggregate result.";
  else if (scheduleActive) message = "Wait for the in-memory schedule simulation before generating previews.";
  else if (state.operationStarting) message = "Starting a synthetic Manager operation...";
  else if (!userIDValid && userID) message = "Enter a fictional numeric Tautulli user ID using no more than 20 digits.";
  else if (userIDValid && confirmed) message = "Ready to refresh six bundled previews without contacting a service or file system.";
  setText("preview-operation-message", message);

  const testButton = byId("test-send-run-button");
  testButton.disabled = state.operationStarting || active || scheduleActive || !ready || !testUserIDValid || !testConfirmed;
  setSwappingButtonText("test-send-run-button", state.operationStarting && state.operationStartingType === "send-test-all" ? "Starting simulation..." : active || scheduleActive ? "Another operation is active" : "Simulate six test messages");
  let testMessage = "Choose a fictional Tautulli user ID, then confirm the six-message simulation.";
  if (!ready) testMessage = "Save the fictional configuration before starting a test-delivery simulation.";
  else if (active) testMessage = operation.type === "send-test-all" ? "Modeling six SMTP accepts in memory; no message or mailbox exists." : "Another synthetic Manager operation is active.";
  else if (scheduleActive) testMessage = "Wait for the in-memory schedule simulation before starting a test-delivery simulation.";
  else if (state.operationStarting) testMessage = "Starting a synthetic Manager operation...";
  else if (!testUserIDValid && testUserID) testMessage = "Enter a fictional numeric Tautulli user ID using no more than 20 digits.";
  else if (testUserIDValid && testConfirmed) testMessage = "Ready to model six fictional TestEmail messages without contacting SMTP.";
  setText("test-send-operation-message", testMessage);

  const manualSendButton = byId("manual-send-run-button");
  manualSendButton.disabled = state.operationStarting || active || scheduleActive || !ready || !manualSendConfirmed || !manualSendUserValid;
  const manualSendButtonLabel = manualWelcome ? "Simulate Manual Welcome" : "Simulate all-recipient delivery";
  setSwappingButtonText("manual-send-run-button", state.operationStarting && state.operationStartingType === manualSendType ? "Starting simulation..." : active || scheduleActive ? "Another operation is active" : manualSendButtonLabel);
  let manualSendMessage = manualWelcome ? "Choose a fictional user, then confirm the one-message Manual Welcome simulation." : "Confirm the fictional all-recipient delivery simulation.";
  if (!ready) manualSendMessage = "Save the fictional configuration before starting a delivery simulation.";
  else if (active) manualSendMessage = ["send-welcome", "send-all"].includes(operation.type) ? "A fictional delivery simulation is running in memory." : "Another synthetic Manager operation is active.";
  else if (scheduleActive) manualSendMessage = "Wait for the in-memory schedule simulation before starting a delivery simulation.";
  else if (state.operationStarting) manualSendMessage = "Starting a synthetic Manager operation...";
  else if (manualWelcome && manualSendUserID && !manualSendUserValid) manualSendMessage = "Enter a fictional numeric Tautulli user ID using no more than 20 digits.";
  else if (manualSendConfirmed && manualSendUserValid) manualSendMessage = manualWelcome ? "Ready to model one fictional Manual Welcome message." : "Ready to model delivery to all fictional eligible recipients.";
  setText("manual-send-operation-message", manualSendMessage);

  renderCurrentOperation(operation);
  renderManualSendStatus(operation);
  renderOperationHistory();
  renderDashboardOperation(operation);
  if (state.status && state.editor) renderSchedule();
}

function renderManualSendChoice(type) {
  const manualWelcome = type === "send-welcome";
  byId("manual-send-user-field").hidden = !manualWelcome;
  setSwappingText("manual-send-runner-heading", manualWelcome ? "Model one Manual Welcome" : "Model this week's newsletter now");
  setText("manual-send-runner-copy", manualWelcome
    ? "Models the Manual Welcome flow for one fictional user without creating a message or changing recipient state."
    : "Models the scheduled all-recipient flow with temporary library and user exclusions. No recipient state changes.");
  setText("manual-send-confirm-heading", manualWelcome ? "Simulate one Manual Welcome" : "Simulate the all-recipient newsletter");
  setText("manual-send-confirm-copy", manualWelcome
    ? "I understand this models one fictional message and changes no mailbox, service, or recipient state."
    : "I understand this models aggregate results for fictional recipients and changes no mailbox, service, or recipient state.");
}

function renderManualSendStatus(operation) {
  const manualTypes = new Set(["send-welcome", "send-all"]);
  const manualSend = manualTypes.has(operation?.type)
    ? operation
    : state.history.find((candidate) => manualTypes.has(candidate.type));
  const card = byId("manual-send-status");
  card.hidden = !manualSend;
  if (!manualSend) return;
  const summary = operationSummary(manualSend);
  setText("manual-send-status-heading", summary.heading);
  setText("manual-send-status-copy", summary.copy);
  const duration = manualSend.durationMs ? ` · ${formatDuration(manualSend.durationMs)}` : "";
  setText("manual-send-status-time", manualSend.finishedAtUtc ? `Finished ${formatDate(manualSend.finishedAtUtc)}${duration}` : `Started ${formatDate(manualSend.startedAtUtc)}`);
  setChip("manual-send-status-chip", titleCase(manualSend.outcome || manualSend.state), operationTone(manualSend));
}

function renderCurrentOperation(operation) {
  const cancel = byId("preview-cancel-button");
  cancel.hidden = !operation?.cancellable || !operationIsActive(operation);
  cancel.disabled = state.operationCancelling;
  setSwappingButtonText("preview-cancel-button", state.operationCancelling ? "Cancelling..." : "Cancel preview generation");
  if (!operation) {
    setText("current-operation-heading", "No simulated Manager operation recorded");
    setText("current-operation-copy", "The page keeps temporary fictional operation state in memory only.");
    setText("current-operation-time", "Not recorded");
    setChip("current-operation-chip", "Idle", "neutral");
    return;
  }
  const summary = operationSummary(operation);
  setText("current-operation-heading", summary.heading);
  setText("current-operation-copy", summary.copy);
  const duration = operation.durationMs ? ` · ${formatDuration(operation.durationMs)}` : "";
  setText("current-operation-time", operation.finishedAtUtc ? `Finished ${formatDate(operation.finishedAtUtc)}${duration}` : `Started ${formatDate(operation.startedAtUtc)}`);
  setChip("current-operation-chip", titleCase(operation.state), operationTone(operation));
}

function renderDashboardOperation(operation) {
  if (!operation) {
    setText("dashboard-operation-heading", "No simulated Manager operation recorded");
    setText("dashboard-operation-copy", "Refresh bundled previews or explore fictional test and all-recipient delivery flows from the Preview center.");
    setChip("dashboard-operation-chip", "Idle", "neutral");
    return;
  }
  const summary = operationSummary(operation);
  setText("dashboard-operation-heading", summary.heading);
  setText("dashboard-operation-copy", `${summary.copy} ${operation.finishedAtUtc ? formatDate(operation.finishedAtUtc) : formatDate(operation.startedAtUtc)}.`);
  setChip("dashboard-operation-chip", titleCase(operation.state), operationTone(operation));
}

function renderOperationHistory() {
  const container = byId("operation-history");
  container.replaceChildren();
  if (!state.history.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No completed fictional Manager operation has been recorded in this tab.";
    container.append(empty);
    return;
  }
  for (const operation of state.history) {
    const row = document.createElement("article");
    row.className = "operation-history-row";
    const copy = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = operationSummary(operation).heading;
    const detail = document.createElement("p");
    const version = operation.packageVersion ? `Package ${operation.packageVersion}` : "Package version unavailable";
    detail.textContent = `${formatDate(operation.startedAtUtc)} · ${version}${operation.durationMs ? ` · ${formatDuration(operation.durationMs)}` : ""}${operation.supportCode ? ` · Support ${operation.supportCode}` : ""}`;
    copy.append(heading, detail);
    if (operation.generatedPreviewIds?.length) {
      const links = document.createElement("div");
      links.className = "operation-history-links";
      for (const id of operation.generatedPreviewIds) {
        const preview = state.previews.find((candidate) => candidate.id === id);
        if (!preview) continue;
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = previewDisplayName(preview);
        button.addEventListener("click", () => {
          const previewButton = document.querySelector(`[data-preview-id="${CSS.escape(id)}"]`);
          if (previewButton) openPreview(id, previewButton);
        });
        links.append(button);
      }
      if (links.childElementCount) copy.append(links);
    }
    const meta = document.createElement("div");
    meta.className = "operation-history-meta";
    const chip = document.createElement("span");
    chip.className = `state-chip ${operationTone(operation)}`;
    chip.textContent = titleCase(operation.outcome || operation.state);
    const count = document.createElement("small");
    count.textContent = operation.type === "send-test-all" || operation.type === "send-welcome"
      ? `${operation.smtpAcceptedCount || 0} fictional SMTP accepts`
      : operation.type === "send-all"
        ? `${operation.smtpAcceptedCount || 0} fictional accepts · ${operation.skippedCount || 0} skipped · ${operation.failedCount || 0} failed`
        : `${Math.max(0, (operation.generatedPreviewIds?.length || 0) - 1)} states + index`;
    meta.append(chip, count);
    row.append(copy, meta);
    container.append(row);
  }
}

function operationSummary(operation) {
  const count = operation.generatedPreviewIds?.length || 0;
  if (operation.type === "send-welcome") {
    switch (operation.state) {
    case "queued": return { heading: "Manual Welcome simulation queued", copy: "One fictional welcome workflow is waiting to start in memory." };
    case "running": return { heading: "Modeling one Manual Welcome", copy: "One fictional user is being processed in memory; no message exists." };
    case "succeeded": return { heading: "Manual Welcome simulation passed", copy: "One fictional SMTP accept was modeled. No welcome state or inbox changed." };
    case "failed": return { heading: "Manual Welcome simulation failed", copy: operation.supportCode ? `The mock renderer failed. Demo code: ${operation.supportCode}.` : "The mock renderer failed without exposing a fictional recipient." };
    default: return { heading: "Manual Welcome simulation recorded", copy: "Review fictional aggregate evidence without exposing the selected demo user." };
    }
  }
  if (operation.type === "send-all") {
    const accepted = operation.smtpAcceptedCount || 0;
    const skipped = operation.skippedCount || 0;
    const failed = operation.failedCount || 0;
    switch (operation.state) {
    case "queued": return { heading: "All-recipient simulation queued", copy: "The fictional delivery workflow is waiting to start in memory." };
    case "running": return { heading: "Modeling all-recipient delivery", copy: "Fictional eligible recipients are being processed in memory." };
    case "succeeded": return { heading: "All-recipient simulation passed", copy: `${accepted} fictional SMTP accept${accepted === 1 ? " was" : "s were"} modeled and ${skipped} fictional recipient${skipped === 1 ? " was" : "s were"} skipped. No inbox exists.` };
    case "partial": return { heading: "All-recipient simulation completed with failures", copy: `${accepted} fictional accepts, ${skipped} skipped, and ${failed} failed${operation.supportCode ? `; demo code: ${operation.supportCode}` : ""}.` };
    case "failed": return { heading: "All-recipient simulation failed", copy: operation.supportCode ? `${accepted} fictional accepts were modeled before failure. Demo code: ${operation.supportCode}.` : "The mock renderer failed without exposing fictional recipients." };
    default: return { heading: "All-recipient simulation recorded", copy: `${accepted} fictional accepts, ${skipped} skipped, and ${failed} failed. No inbox exists.` };
    }
  }
  if (operation.type === "send-test-all") {
    switch (operation.state) {
    case "queued": return { heading: "Test-delivery simulation queued", copy: "The fictional six-message workflow is waiting to start in memory." };
    case "running": return { heading: "Modeling six test messages", copy: "Fictional TestEmail results are being modeled; no message or mailbox exists." };
    case "succeeded": return { heading: "Test-delivery simulation passed", copy: `${operation.smtpAcceptedCount || 0} fictional SMTP accepts were modeled. No inbox exists.` };
    case "failed": return { heading: "Test-delivery simulation failed", copy: operation.supportCode ? `${operation.smtpAcceptedCount || 0} fictional accepts were modeled before failure. Demo code: ${operation.supportCode}.` : "The mock renderer failed without contacting a destination." };
    default: return { heading: "Test-delivery simulation recorded", copy: "Review fictional aggregate counts." };
    }
  }
  switch (operation.state) {
  case "queued": return { heading: "Preview simulation queued", copy: "The in-memory preview operation is waiting to start." };
  case "running": return { heading: "Refreshing fictional newsletter previews", copy: "Bundled HTML is being prepared in memory; no file or email is created." };
  case "cancelling": return { heading: "Cancelling preview simulation", copy: "The mock Manager is stopping the in-memory operation." };
  case "succeeded": return { heading: "Preview simulation completed", copy: `${Math.max(0, count - 1)} fictional states plus the index are available in the sandboxed frame.` };
  case "cancelled": return { heading: "Preview simulation cancelled", copy: "The in-memory operation stopped before normal completion." };
  case "failed": return { heading: "Preview simulation failed", copy: operation.supportCode ? `A fictional demo code is available: ${operation.supportCode}.` : "The mock renderer exited without exposing any private output." };
  default: return { heading: "Preview simulation recorded", copy: "Review the temporary state and bundled preview list." };
  }
}

function operationTone(operation) {
  if (operation?.state === "succeeded") return "good";
  if (operation?.state === "failed") return "bad";
  if (operation?.state === "partial") return "neutral";
  if (operationIsActive(operation)) return "pending";
  return "neutral";
}

function operationIsActive(operation) {
  return ["queued", "running", "cancelling"].includes(operation?.state);
}

function validPreviewUserID(value) {
  if (!/^[0-9]{1,20}$/.test(value)) return false;
  const parsed = BigInt(value);
  return parsed <= 18446744073709551615n;
}

async function startPreviewOperation() {
  const userID = byId("preview-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("preview-confirm").checked || !validPreviewUserID(userID)) return;
  state.operationStarting = true;
  state.operationStartingType = "preview-all";
  renderOperations();
  setGlobalStatus("Starting the in-memory preview simulation...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "preview-all", expectedRevision: state.editor.revision, userId: userID, confirmNoSend: true }),
    });
    byId("preview-user-id").value = "";
    byId("preview-confirm").checked = false;
    setGlobalStatus("Preview simulation started. No service, file, or email is contacted.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // Operation polling will refresh the retained setup result at completion.
    }
    renderOperations();
    manageOperationPolling();
  }
}

async function startTestSendOperation() {
  const userID = byId("test-send-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("test-send-confirm").checked || !validPreviewUserID(userID)) return;
  state.operationStarting = true;
  state.operationStartingType = "send-test-all";
  renderOperations();
  setGlobalStatus("Starting the fictional six-message test-delivery simulation...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "send-test-all", expectedRevision: state.editor.revision, userId: userID, confirmTestSend: true }),
    });
    byId("test-send-user-id").value = "";
    byId("test-send-confirm").checked = false;
    setGlobalStatus("Test-delivery simulation started. No message or SMTP request exists.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    renderOperations();
    manageOperationPolling();
  }
}

async function startManualSendOperation() {
  const type = byId("manual-send-mode").value === "send-welcome" ? "send-welcome" : "send-all";
  const userID = byId("manual-send-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("manual-send-confirm").checked || (type === "send-welcome" && !validPreviewUserID(userID))) return;
  state.operationStarting = true;
  state.operationStartingType = type;
  renderOperations();
  setGlobalStatus(type === "send-welcome" ? "Starting the fictional Manual Welcome simulation..." : "Starting the fictional all-recipient delivery simulation...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type, expectedRevision: state.editor.revision, userId: type === "send-welcome" ? userID : "", confirmProductionSend: true }),
    });
    if (type === "send-welcome") byId("manual-send-user-id").value = "";
    byId("manual-send-confirm").checked = false;
    setGlobalStatus(type === "send-welcome" ? "Manual Welcome simulation started. The fictional user ID is not retained." : "All-recipient simulation started. Aggregate fictional evidence exists only in memory.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    renderOperations();
    manageOperationPolling();
  }
}

async function cancelPreviewOperation() {
  if (!operationIsActive(state.operation) || !state.operation?.cancellable) return;
  state.operationCancelling = true;
  renderOperations();
  setGlobalStatus("Cancelling the in-memory preview simulation...");
  try {
    state.operation = await request(`/api/v1/operations/${encodeURIComponent(state.operation.id)}/cancel`, { method: "POST" });
    setGlobalStatus("Cancellation requested.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationCancelling = false;
    renderOperations();
    manageOperationPolling();
  }
}

let operationPollTimer;
function manageOperationPolling() {
  clearTimeout(operationPollTimer);
  if (!operationIsActive(state.operation)) return;
  operationPollTimer = setTimeout(pollOperation, 1000);
}

async function pollOperation() {
  const priorState = state.operation?.state;
  try {
    const response = await request("/api/v1/operations/current");
    state.operation = response.current || null;
    if (operationIsActive(state.operation)) {
      renderOperations();
      manageOperationPolling();
      return;
    }
    const [previews, history, status, configurationStatus] = await Promise.all([
      request("/api/v1/previews"),
      request("/api/v1/history"),
      request("/api/v1/status"),
      request("/api/v1/config/status"),
    ]);
    state.previews = previews.previews || [];
    state.history = history.operations || [];
    state.status = status;
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
    renderPreviews();
    renderOperations();
    renderStatus();
    renderSetupWorkflow();
    if (["queued", "running", "cancelling"].includes(priorState)) {
      const summary = state.operation ? operationSummary(state.operation) : { heading: "Manager operation ended" };
      setGlobalStatus(summary.heading + ".", true);
    }
  } catch (error) {
    if (error.status === 401) showAuthentication();
    else {
      setGlobalStatus(error.message, true);
      operationPollTimer = setTimeout(pollOperation, 2500);
    }
  }
}

function chooseScheduleAction(action) {
  if (!validScheduleAction(action)) return;
  const button = document.querySelector(`[data-schedule-action="${action}"]`);
  if (!button || button.disabled) return;
  state.schedulePendingAction = action;
  byId("schedule-confirm").checked = false;
  renderSchedule();
  byId("schedule-confirmation").scrollIntoView({ behavior: "smooth", block: "center" });
  byId("schedule-confirm").focus({ preventScroll: true });
}

function cancelScheduleConfirmation() {
  state.schedulePendingAction = "";
  byId("schedule-confirm").checked = false;
  renderSchedule();
}

async function startScheduleOperation() {
  const action = state.schedulePendingAction;
  if (!validScheduleAction(action) || !byId("schedule-confirm").checked || state.editor?.state !== "ready") return;
  state.scheduleStarting = true;
  renderSchedule();
  setGlobalStatus("Starting the in-memory schedule simulation...");
  try {
    state.scheduleOperation = await request(`/api/v1/schedule/${encodeURIComponent(action)}`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirm: true }),
    });
    state.schedulePendingAction = "";
    byId("schedule-confirm").checked = false;
    setGlobalStatus("Schedule simulation started. No host approval prompt or mutation occurs.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.scheduleStarting = false;
    renderSchedule();
    renderOperations();
    manageSchedulePolling();
  }
}

function validScheduleAction(action) {
  return ["install", "enable", "disable", "remove"].includes(action);
}

let schedulePollTimer;
function manageSchedulePolling() {
  clearTimeout(schedulePollTimer);
  if (!scheduleOperationIsActive(state.scheduleOperation)) return;
  schedulePollTimer = setTimeout(pollScheduleOperation, 1000);
}

async function pollScheduleOperation() {
  const priorState = state.scheduleOperation?.state;
  try {
    const response = await request("/api/v1/schedule/operation");
    state.scheduleOperation = response.current || null;
    if (scheduleOperationIsActive(state.scheduleOperation)) {
      renderSchedule();
      renderOperations();
      manageSchedulePolling();
      return;
    }
    state.status = await request("/api/v1/status");
    renderStatus();
    renderSchedule();
    renderOperations();
    if (["queued", "running"].includes(priorState)) {
      const action = titleCase(state.scheduleOperation?.action || "Schedule");
      const outcome = state.scheduleOperation?.state === "succeeded" ? "completed" : "was not completed";
      setGlobalStatus(`${action} schedule ${outcome}.`, true);
    }
  } catch (error) {
    if (error.status === 401) showAuthentication();
    else {
      setGlobalStatus(error.message, true);
      schedulePollTimer = setTimeout(pollScheduleOperation, 2500);
    }
  }
}

function renderAccessSettings() {
  const access = state.authAccess || {};
  const locked = Boolean(access.authenticationRequired);
  const localLock = Boolean(access.passwordLockEnabled);
  const runtimeRequired = Boolean(access.runtimeRequired);
  const passwordLockActive = localLock || runtimeRequired;
  setChip("access-settings-chip", locked ? "Locked" : "Unlocked", locked ? "good" : "neutral", locked ? "lock" : "lock-open");
  const accessChip = byId("access-settings-chip");
  accessChip.classList.add("access-lock-chip", locked ? "locked" : "unlocked");
  const accessButton = byId("access-status-button");
  const accessLabel = `${accessSurfaceLabel()} ${locked ? "locked" : "unlocked"}`;
  accessButton.className = `access-status-button ${locked ? "locked" : "unlocked"}`;
  accessButton.dataset.tooltip = accessLabel;
  accessButton.setAttribute("aria-label", `${accessLabel}. Open password settings.`);
  accessButton.replaceChildren(createMaterialIcon(locked ? "lock" : "lock-open"));
  setText("access-settings-copy", runtimeRequired
    ? "This fictional Manager mode requires a demo password. Reloading clears the temporary state."
    : localLock
      ? "The optional demo lock is enabled in memory. Sign out to preview the fictional login screen, or reload to reset it."
      : `${accessSurfaceLabel()} is unlocked. Enable the optional demo lock to explore the workflow; no value will be stored.`);
  setText("access-password-label", passwordLockActive ? "New demo password" : "Create demo password");
  setSwappingButtonText("access-password-submit", passwordLockActive ? "Change demo password" : "Enable demo lock");
  byId("access-disable-button").hidden = !localLock || !access.canDisable;
  byId("logout-button").hidden = !locked;
  const policy = byId("config-secret-policy");
  if (policy) policy.textContent = locked
    ? "Fictional values only: edits live in memory for this tab and reset on reload. The temporary demo password gates a fixed non-secret placeholder reveal; no credential is stored."
    : "Fictional values only: edits live in memory for this tab and reset on reload. Secret controls reveal a fixed non-secret placeholder; no credential is stored.";
}

function accessSurfaceLabel() {
  return "GUI Preview access";
}

function openAccessSettings() {
  selectView("about");
  requestAnimationFrame(() => {
    byId("access-settings-panel").scrollIntoView({ block: "center", behavior: "smooth" });
    byId("access-password").focus({ preventScroll: true });
  });
}

async function submitAccessPassword(event) {
  event.preventDefault();
  const password = byId("access-password").value;
  const confirmation = byId("access-password-confirm").value;
  const message = byId("access-settings-message");
  if (password !== confirmation) {
    message.textContent = "The password confirmation does not match.";
    byId("access-password-confirm").focus();
    return;
  }
  const button = byId("access-password-submit");
  button.disabled = true;
  setSwappingButtonText("access-password-submit", state.authAccess?.passwordLockEnabled ? "Changing password..." : "Enabling lock...");
  message.textContent = state.authAccess?.passwordLockEnabled ? "Changing the temporary demo password..." : "Enabling the in-memory demo lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/password", { method: "POST", body: JSON.stringify({ password }) });
    byId("access-password").value = "";
    byId("access-password-confirm").value = "";
    concealMaskedInputs(byId("access-password-form"));
    renderAccessSettings();
    message.textContent = "Demo lock state updated in memory. This browser remains signed in.";
    setGlobalStatus("Temporary Manager lock updated.", true);
  } catch (error) {
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    renderAccessSettings();
  }
}

async function disableAccessPassword() {
  const button = byId("access-disable-button");
  const message = byId("access-settings-message");
  button.disabled = true;
  setSwappingButtonText("access-disable-button", "Disabling lock...");
  message.textContent = "Disabling the temporary demo lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/disable", { method: "POST", body: "{}" });
    renderAccessSettings();
    message.textContent = "Demo lock disabled. No value was persisted.";
    setGlobalStatus("Manager preview returned to unlocked demo access.", true);
  } catch (error) {
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    setSwappingButtonText("access-disable-button", "Disable password lock");
  }
}

function renderAbout() {
  setText("about-version", state.about.version || "Version unavailable");
  setText("about-package", state.about.packageVersion || "Package version unavailable");
  const events = state.diagnostics?.events || [];
  setText("diagnostics-count", events.length ? `${events.length} fictional` : "No events");
  setText("diagnostics-retention", "Bundled demo events; reset on reload.");
  const container = byId("diagnostics-list");
  container.replaceChildren();
  if (!events.length) {
    const empty = document.createElement("p");
    empty.className = "diagnostics-empty";
    empty.textContent = "No setup or verification events have been recorded.";
    container.append(empty);
    return;
  }
  for (const event of events) {
    const row = document.createElement("article");
    row.className = "diagnostic-row";
    const copy = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = event.summary;
    const metadata = document.createElement("p");
    metadata.textContent = `${diagnosticAreaLabel(event.area)} · Demo code ${event.code}`;
    copy.append(heading, metadata);
    const evidence = document.createElement("div");
    evidence.className = "diagnostic-evidence";
    const chip = document.createElement("span");
    chip.className = `state-chip ${event.outcome === "passed" ? "good" : event.outcome === "failed" ? "bad" : "neutral"}`;
    chip.textContent = titleCase(event.outcome);
    const timestamp = document.createElement("small");
    timestamp.textContent = formatDate(event.recordedAtUtc);
    evidence.append(chip, timestamp);
    row.append(copy, evidence);
    container.append(row);
  }
}

function diagnosticAreaLabel(area) {
  return area === "lan-verification" ? "Connection Verification" : titleCase(area);
}

function openPreview(id, button) {
  state.selectedPreviewID = id;
  document.querySelectorAll(".preview-button").forEach((element) => element.classList.remove("active"));
  button.classList.add("active");
  byId("preview-placeholder").hidden = true;
  const frame = byId("preview-frame");
  if (frame.dataset.previewId !== id) {
    frame.srcdoc = window.TautWeeklyPreviewDemo?.html
      ? window.TautWeeklyPreviewDemo.html(id)
      : "<!doctype html><html><body><p>Synthetic preview content is unavailable. No request was made.</p></body></html>";
    frame.dataset.previewId = id;
  }
  frame.hidden = false;
}

function initializePreviewIndexNavigation() {
  const frame = byId("preview-frame");
  const documentRoot = frame.contentDocument;
  const selected = state.previews.find((preview) => preview.id === state.selectedPreviewID);
  if (!documentRoot || !/-00-index(?:\.html)?$/i.test(selected?.name || "")) return;
  documentRoot.querySelectorAll("a[href]").forEach((link) => {
    let fileName = "";
    try {
      const target = new URL(link.getAttribute("href"), documentRoot.baseURI);
      fileName = decodeURIComponent(target.pathname.split("/").pop() || "").toLowerCase();
    } catch (_) {
      return;
    }
    const preview = state.previews.find((candidate) => `${candidate.name}.html`.toLowerCase() === fileName);
    if (!preview) return;
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const button = byId("preview-list").querySelector(`[data-preview-id="${CSS.escape(preview.id)}"]`);
      if (button) openPreview(preview.id, button);
    });
  });
}

function selectView(name) {
  if (name !== "configuration") clearAllRevealedSecrets();
  document.querySelectorAll("[data-user-combobox].open").forEach((container) => setUserComboboxOpen(container, false));
  document.querySelectorAll("[data-panel]").forEach((panel) => { panel.hidden = panel.dataset.panel !== name; });
  document.querySelectorAll("[data-view]").forEach((button) => {
    const active = button.dataset.view === name;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  window.scrollTo({ top: 0, behavior: "auto" });
  byId("main-content").focus({ preventScroll: true });
}

async function submitPair(event) {
  event.preventDefault();
  const password = byId("pair-password").value;
  if (password !== byId("pair-password-confirm").value) {
    setAuthMessage("The password confirmation does not match.");
    return;
  }
  setAuthMessage("Pairing this browser…", false);
  try {
    const session = await request("/api/v1/auth/pair", { method: "POST", body: JSON.stringify({ token: byId("pair-token").value, password }) });
    state.csrfToken = session.csrfToken;
    concealMaskedInputs(byId("pair-form"));
    await enterApplication();
  } catch (error) {
    setAuthMessage(error.message);
  }
}

async function submitLogin(event) {
  event.preventDefault();
  setAuthMessage("Signing in…", false);
  try {
    const session = await request("/api/v1/auth/login", { method: "POST", body: JSON.stringify({ password: byId("login-password").value }) });
    state.csrfToken = session.csrfToken;
    byId("login-password").value = "";
    concealMaskedInputs(byId("login-form"));
    await enterApplication();
  } catch (error) {
    setAuthMessage(error.message);
  }
}

async function logout() {
  clearAllRevealedSecrets();
  try { await request("/api/v1/auth/logout", { method: "POST" }); }
  finally { state.csrfToken = ""; showAuthentication(); }
}

function showAuthentication() {
  clearAllRevealedSecrets();
  closeSecretRevealDialog();
  concealMaskedInputs(byId("auth-shell"));
  state.discovery = null;
  byId("discovery-libraries").replaceChildren();
  byId("discovery-users").replaceChildren();
  renderUserComboboxes();
  clearTimeout(operationPollTimer);
  clearTimeout(schedulePollTimer);
  byId("app-shell").hidden = true;
  byId("auth-shell").hidden = false;
  byId("pair-form").hidden = true;
  byId("login-form").hidden = false;
  byId("login-password").focus();
}

function createMaterialIcon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.classList.add("ui-icon");
  svg.setAttribute("viewBox", "0 -960 960 960");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#icon-${name}`);
  svg.append(use);
  return materializeMaterialIcon(svg);
}

function setChip(id, text, tone, iconName = "") {
  const chip = byId(id);
  const resolvedTone = tone || "neutral";
  if (iconName) chip.replaceChildren(createMaterialIcon(iconName), document.createTextNode(text));
  else chip.textContent = text;
  chip.className = `state-chip ${resolvedTone}`;
  const card = chip.closest(".health-card,.operation-strip,.current-operation,.setup-workflow-steps article,.setup-workflow");
  if (card) {
    card.classList.remove("state-card-good", "state-card-bad", "state-card-pending", "state-card-neutral");
    card.classList.add(`state-card-${resolvedTone}`);
  }
}
function setText(id, value) { byId(id).textContent = value || "Not recorded"; }
function setSwappingText(id, value) {
  setSwappingElementText(byId(id), value);
}
function setSwappingButtonText(id, value) {
  setSwappingButtonElementText(byId(id), value);
}
function setSwappingButtonElementText(button, value) {
  let label = button.querySelector(".button-state-label");
  if (!label) {
    label = document.createElement("span");
    label.className = "button-state-label";
    label.textContent = button.textContent;
    button.replaceChildren(label);
  }
  setSwappingElementText(label, value);
}
function setSwappingElementText(element, value) {
  const next = value || "Not recorded";
  if (element.textContent === next) return;
  element.classList.remove("schedule-state-swap");
  element.textContent = next;
  void element.offsetWidth;
  element.classList.add("schedule-state-swap");
}
function setAuthMessage(message, isError = true) { const element = byId("auth-message"); element.textContent = message; element.classList.toggle("error", isError); }

let statusTimer;
function setGlobalStatus(message, dismiss = false) {
  const element = byId("global-status");
  clearTimeout(statusTimer);
  element.textContent = message;
  element.classList.add("visible");
  if (dismiss) statusTimer = setTimeout(() => element.classList.remove("visible"), 2600);
}

function overallHeading(overall) {
  switch (overall) {
  case "healthy": return "The synthetic management surface is ready.";
  case "unconfigured": return "The GUI Preview is ready for guided setup.";
  case "blocked": return "The fictional configuration needs attention.";
  default: return "The GUI Preview is showing a degraded synthetic signal.";
  }
}
function overallCopy(overall) {
  switch (overall) {
  case "healthy": return "Fictional status is generated in memory. No host setting, service, file, credential, message, or scheduler is touched.";
  case "unconfigured": return "No fictional configuration is loaded. Complete the demo setup to explore the remaining workflows.";
  case "blocked": return "The synthetic configuration cannot be interpreted safely. Reload the page to restore the fixed demo values.";
  default: return "One or more synthetic probes could not be completed. Review the health cards below.";
  }
}
function formatDate(value) {
  if (!value) return "Not recorded";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Not recorded";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}
function formatBytes(value) {
  if (!Number.isFinite(value) || value < 1024) return `${value || 0} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}
function formatDuration(value) {
  if (!Number.isFinite(value) || value < 0) return "Duration unavailable";
  if (value < 1000) return `${Math.round(value)} ms`;
  if (value < 60000) return `${(value / 1000).toFixed(value < 10000 ? 1 : 0)} s`;
  return `${Math.floor(value / 60000)}m ${Math.round((value % 60000) / 1000)}s`;
}
function yesNo(value) { return value ? "Yes" : "No"; }
function displayValue(value) {
  if (value === null || value === undefined || value === "") return "Not set";
  if (Array.isArray(value)) return value.length ? value.join(", ") : "None selected";
  if (typeof value === "object") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "Enabled" : "Disabled";
  return String(value);
}

byId("pair-form").addEventListener("submit", submitPair);
byId("login-form").addEventListener("submit", submitLogin);
byId("access-password-form").addEventListener("submit", submitAccessPassword);
byId("access-disable-button").addEventListener("click", disableAccessPassword);
byId("secret-reveal-form").addEventListener("submit", submitSecretReveal);
byId("secret-reveal-cancel").addEventListener("click", closeSecretRevealDialog);
byId("secret-reveal-dialog").addEventListener("close", () => {
  byId("secret-reveal-password").value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  byId("secret-reveal-message").textContent = "";
  pendingSecretReveal = null;
});
document.addEventListener("visibilitychange", () => { if (document.hidden) clearAllRevealedSecrets(); });
materializeMaterialIcons();
initializeMaskedInputToggles();
document.querySelectorAll("[data-user-combobox]").forEach(initializeUserCombobox);
byId("preview-frame").addEventListener("load", initializePreviewIndexNavigation);
document.addEventListener("pointerdown", (event) => {
  document.querySelectorAll("[data-user-combobox].open").forEach((container) => {
    if (!container.contains(event.target)) setUserComboboxOpen(container, false);
  });
});
byId("config-form").addEventListener("submit", submitConfig);
byId("config-reset-button").addEventListener("click", renderConfigEditor);
byId("direct-plex-review-button").addEventListener("click", reviewDirectPlexFields);
byId("discovery-confirm").addEventListener("change", renderDiscovery);
byId("discovery-run-button").addEventListener("click", runTautulliDiscovery);
byId("verification-confirm").addEventListener("change", renderVerification);
byId("verification-run-button").addEventListener("click", runVerification);
byId("smtp-verification-confirm").addEventListener("change", renderVerification);
byId("smtp-verification-run-button").addEventListener("click", runSMTPVerification);
byId("preview-user-id").addEventListener("input", renderOperations);
byId("preview-confirm").addEventListener("change", renderOperations);
byId("preview-run-button").addEventListener("click", startPreviewOperation);
byId("preview-cancel-button").addEventListener("click", cancelPreviewOperation);
byId("test-send-user-id").addEventListener("input", renderOperations);
byId("test-send-confirm").addEventListener("change", renderOperations);
byId("test-send-run-button").addEventListener("click", startTestSendOperation);
byId("manual-send-mode").addEventListener("change", () => {
  byId("manual-send-confirm").checked = false;
  renderOperations();
});
byId("manual-send-user-id").addEventListener("input", renderOperations);
byId("manual-send-confirm").addEventListener("change", renderOperations);
byId("manual-send-run-button").addEventListener("click", startManualSendOperation);
byId("schedule-confirm").addEventListener("change", renderSchedule);
byId("schedule-confirm-cancel").addEventListener("click", cancelScheduleConfirmation);
byId("schedule-confirm-run").addEventListener("click", startScheduleOperation);
document.querySelectorAll("[data-schedule-action]").forEach((button) => button.addEventListener("click", () => chooseScheduleAction(button.dataset.scheduleAction)));
byId("logout-button").addEventListener("click", logout);
byId("refresh-button").addEventListener("click", loadAll);
byId("access-status-button").addEventListener("click", openAccessSettings);
document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.view)));
document.querySelectorAll("[data-open-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.openView)));
initialize().catch((error) => setAuthMessage(`Manager initialization failed: ${error.message}`));
