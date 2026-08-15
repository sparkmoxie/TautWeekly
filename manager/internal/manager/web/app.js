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
  startup: null,
  startupDirty: false,
  startupSaving: false,
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
  setGlobalStatus("Refreshing local status…");
  try {
    const [status, config, editor, configurationStatus, backups, verification, discovery, previews, operation, history, scheduleOperation, startup, authAccess, about, diagnostics] = await Promise.all([
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
      request("/api/v1/startup"),
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
    state.startup = startup;
    state.startupDirty = false;
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
    renderStartupSettings();
    renderAccessSettings();
    renderAbout();
    manageOperationPolling();
    manageSchedulePolling();
    setGlobalStatus("Local status refreshed.", true);
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
  if (active) return { label: "Running", tone: "pending", summary: "Safe setup checks are running and each result is retained as it completes." };
  if (states.includes("failed")) return { label: "Needs review", tone: "bad", summary: "One or more saved setup checks need review before live delivery." };
  if (states.every((stepState) => stepState === "not-run")) return { label: "Not run", tone: "neutral", summary: "Validate and save to run the four safe setup checks." };
  if (states.includes("waiting")) return { label: "Pending", tone: "pending", summary: "One or more setup checks are waiting to run for this configuration." };
  if (states.some((stepState) => ["warning", "skipped"].includes(stepState))) return { label: "Completed with notes", tone: "neutral", summary: "The saved configuration was checked; review the noted result before live delivery." };
  if (states.length === setupWorkflowSteps.length && states.every((stepState) => stepState === "passed")) return { label: "Passed", tone: "good", summary: "All four safe setup checks passed for the saved configuration." };
  return { label: "Incomplete", tone: "neutral", summary: "Some setup checks have not completed for the saved configuration." };
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
    ? "Latest checks from validation or a targeted retest are retained for this saved configuration."
    : "Safe real checks run after a successful save or when you start a manual retest.");
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
  setText("runtime-copy", `${titleCase(snapshot.readiness.configuration)} configuration · ${titleCase(snapshot.readiness.privateData)} private state.`);
  setText("schedule-installed", yesNo(snapshot.schedule.installed));
  setText("schedule-enabled", yesNo(snapshot.schedule.enabled));
  setText("schedule-ownership", titleCase(snapshot.schedule.ownership));
  setText("schedule-state", titleCase(snapshot.schedule.state));
  const scheduleOwned = !snapshot.schedule.installed || snapshot.schedule.owned;
  const scheduleProbeFailed = snapshot.schedule.state === "probe-failed";
  const scheduleHealthy = snapshot.schedule.installed && snapshot.schedule.enabled && scheduleOwned;
  setChip("schedule-chip", scheduleProbeFailed ? "Status unavailable" : !scheduleOwned ? "Ownership warning" : scheduleHealthy ? "Active" : snapshot.schedule.installed ? "Disabled" : "Not installed", scheduleProbeFailed || !scheduleOwned ? "bad" : scheduleHealthy ? "good" : "neutral");
  setText("schedule-copy", scheduleProbeFailed ? "Windows Task Scheduler status could not be verified." : !scheduleOwned ? "A same-named task exists but does not match this installation." : snapshot.schedule.supported ? "Read directly from Windows Task Scheduler." : "Schedule management is unavailable on this platform.");
  setText("last-attempt", formatDate(snapshot.delivery.lastAttemptUtc));
  setText("last-result", titleCase(snapshot.delivery.result));
  setText("last-success", formatDate(snapshot.delivery.lastSuccessUtc));
  setText("timeline-last-attempt", formatDate(snapshot.delivery.lastAttemptUtc));
  const rendererEvidence = snapshot.delivery.evidence === "renderer-result";
  setText("last-accepted-count", rendererEvidence ? String(snapshot.delivery.smtpAcceptedCount || 0) : "Not recorded");
  setText("delivery-copy", rendererEvidence
    ? "Application evidence records SMTP acceptance, not inbox delivery."
    : "Task execution is not presented as SMTP acceptance or inbox delivery.");
  setText("timeline-last-copy", rendererEvidence
    ? `${snapshot.delivery.smtpAcceptedCount || 0} accepted by SMTP · ${snapshot.delivery.skippedCount || 0} skipped · ${snapshot.delivery.failedCount || 0} failed.`
    : "No sanitized renderer result has been recorded.");
  const deliveryTone = snapshot.delivery.result === "smtp-accepted" ? "good" : snapshot.delivery.result === "failed" ? "bad" : "neutral";
  setChip("delivery-chip", snapshot.delivery.result === "not-recorded" ? "No history" : titleCase(snapshot.delivery.result), deliveryTone);
  renderIntegrationStatus();
  renderDashboardConfigStatus();
  setText("next-run", formatDate(snapshot.schedule.nextRunLocal));
  setText("next-run-utc", snapshot.schedule.nextRunUtc ? `UTC: ${formatDate(snapshot.schedule.nextRunUtc)}` : "Task Scheduler has not reported an upcoming run.");
  setText("preview-count", snapshot.previewSummary);
  setText("sidebar-platform", `${titleCase(snapshot.platform)} · local only`);
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
  setText("schedule-configured-window", ready ? `${day} at ${time} local Windows time` : "Complete configuration first");
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
    warning.textContent = "Task Scheduler status could not be verified. The Manager will not request a schedule mutation until the local probe succeeds.";
    warning.classList.add("bad");
  }
  else if (!ready) warning.textContent = "Complete and save configuration before requesting a schedule change.";
  else if (!owned) {
    warning.textContent = "Safety stop: a same-named task exists but its action, working directory, or SYSTEM principal does not match this TautWeekly installation. The Manager will not modify it.";
    warning.classList.add("bad");
  } else if (managerActive) warning.textContent = "Wait for the active preview or test-delivery operation before changing the schedule.";
  else if (scheduleActive) warning.textContent = "A fixed schedule operation is waiting for UAC approval or completing. No second change can start.";
  else warning.textContent = "Task execution is distinct from SMTP acceptance. The dashboard reports both signals separately.";

  const installLabel = schedule.installed ? "Refresh" : "Install";
  setSwappingText("schedule-install-heading", installLabel);
  setSwappingText("schedule-install-button-label", installLabel);
  setText("schedule-install-copy", schedule.installed
    ? "Safely refresh the verified SYSTEM task after configuration changes."
    : "Create the verified SYSTEM task from the configured day and local time.");

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
    setSwappingButtonText("schedule-confirm-run", state.scheduleStarting ? "Starting fixed helper..." : "Request administrator approval");
  }
  renderScheduleOperation(operation);
}

function renderScheduleOperation(operation) {
  if (!operation) {
    setText("schedule-current-heading", "No schedule change recorded");
    setText("schedule-current-copy", "No UAC request has been started by this Manager.");
    setText("schedule-current-time", "Not recorded");
    setChip("schedule-current-chip", "Idle", "neutral");
    return;
  }
  const action = titleCase(operation.action);
  let heading = `${action} schedule ${titleCase(operation.state)}`;
  let copy = "The fixed helper is waiting to report a sanitized result.";
  if (operation.state === "queued") {
    heading = `${action} schedule queued`;
    copy = "Windows may be preparing the UAC approval prompt.";
  } else if (operation.state === "running") {
    heading = `${action} schedule in progress`;
    copy = "Approve the Windows UAC prompt if it is visible. This operation cannot be changed from browser input.";
  } else if (operation.state === "succeeded") {
    heading = `${action} schedule completed`;
    copy = "The helper completed and the Manager observed the expected Task Scheduler state.";
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
    ? { heading: "Refresh the weekly task", copy: `Update the verified SYSTEM task for ${day} at ${time} local Windows time.`, label: "Refresh this owned TautWeekly schedule", help: "Windows will request administrator approval. An unrelated same-named task will be left untouched." }
    : { heading: "Install the weekly task", copy: `Create the verified SYSTEM task for ${day} at ${time} local Windows time.`, label: "Install this TautWeekly schedule", help: "Windows will request administrator approval. An unrelated same-named task will be left untouched." };
  case "enable": return { heading: "Enable future scheduled delivery", copy: "Allow the installed and ownership-verified task to start on its configured weekly window.", label: "Enable this verified schedule", help: "This does not send a newsletter immediately." };
  case "disable": return { heading: "Disable future scheduled starts", copy: "Keep the verified task definition but prevent it from starting future newsletter runs.", label: "Disable this verified schedule", help: "A newsletter process already running will not be cancelled." };
  case "remove": return { heading: "Remove the verified schedule", copy: "Delete only the ownership-verified Windows task while preserving configuration, state, history, previews, and logs.", label: "Remove this verified schedule", help: "This cannot be undone from operation history, but it can be installed again later." };
  default: return { heading: "Confirm schedule change", copy: "Review this typed operation.", label: "Confirm this schedule change", help: "Windows will request administrator approval." };
  }
}

function scheduleFailureCopy(category, supportCode) {
  const suffix = supportCode ? ` Support code: ${supportCode}.` : "";
  switch (category) {
  case "elevation-declined": return "Windows administrator approval was declined or closed." + suffix;
  case "configuration-changed": return "Configuration changed while Windows approval was pending. Refresh and review before retrying." + suffix;
  case "task-not-found": return "The expected verified task was not found. Refresh local status before retrying." + suffix;
  case "task-ownership-mismatch": return "The same-named task did not match this installation and was left untouched." + suffix;
  case "schedule-invalid": return "The saved day or time could not be interpreted safely." + suffix;
  case "renderer-missing": return "The packaged newsletter renderer is unavailable, so the schedule was not enabled." + suffix;
  case "postcondition-failed": return "The helper returned, but the expected Task Scheduler state could not be verified." + suffix;
  case "schedule-configuration-read-failed": return "Windows approval succeeded, but the helper could not validate the saved schedule configuration." + suffix;
  case "task-definition-failed": return "Windows approval succeeded, but Task Scheduler rejected the requested schedule definition." + suffix;
  case "task-mutation-failed": return "Windows approval succeeded, but Task Scheduler could not apply the requested change." + suffix;
  case "task-verification-failed": return "Task Scheduler accepted the request, but the helper could not verify the resulting owned task state." + suffix;
  case "task-read-access-failed": return "Task Scheduler accepted the request, but Windows could not grant this signed-in user read-only status access to the task." + suffix;
  case "manager-restarted": return "The Manager restarted while elevation was pending, so the final result is unknown. Refresh Task Scheduler status." + suffix;
  default: return "The schedule helper did not complete successfully. No raw PowerShell output was retained." + suffix;
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
    empty.textContent = config.exists ? "The configuration could not be displayed safely." : "No private config.json exists yet. Complete guided setup to create it.";
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
  byId("config-save-copy").textContent = editor.exists
    ? "A private timestamped backup is created before config.json is replaced, then safe discovery, connection checks, and six non-sending local previews run."
    : "A new private config.json is created only after validation, then safe discovery, connection checks, and six non-sending local previews run.";
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
    ? "This older config.json never contained one or both direct Plex fields; the updater preserved it instead of guessing. "
    : "Direct Plex is optional, but one part of the connection is not available. ";
  if (!status.urlConfigured) copy += "For Plex on this computer, use http://127.0.0.1:32400; otherwise enter the Plex URL reachable from this runtime. ";
  if (!status.tokenConfigured && status.runtimeTokenAvailable) copy += "A trusted runtime Plex token is available and will be used without copying it into config.json. ";
  else if (!status.tokenConfigured) copy += "Paste the Plex administrator token to enable authenticated direct-Plex checks. ";
  copy += "Validate, save, and verify to normalize the legacy fields and re-run the safe checks.";
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
  setSwappingButtonText("discovery-run-button", state.discoveryRunning ? "Loading choices..." : "Refresh Tautulli choices");
  if (!state.discovery) {
    byId("discovery-results").hidden = true;
    byId("discovery-message").textContent = ready
      ? "A successful save loads these choices automatically. Confirm above to repeat the saved service lookup now."
      : "Save a complete configuration before loading choices.";
    renderUserComboboxes();
    return;
  }
  byId("discovery-results").hidden = false;
  byId("discovery-message").textContent = `Choices loaded ${formatDate(state.discovery.completedAtUtc)} and retained locally for this saved configuration.`;
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

function savedListField(name) {
  const field = (state.editor?.fields || []).find((candidate) => candidate.name === name);
  return Array.isArray(field?.value) ? field.value.map((value) => String(value).trim()).filter(Boolean) : [];
}

function renderDiscoveredLibraries() {
  const container = byId("discovery-libraries");
  container.replaceChildren();
  const libraries = state.discovery?.libraries || [];
  setText("discovery-library-count", `${libraries.length} active`);
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
  const configured = new Set(currentListField("ExcludedUserIds"));
  renderDiscoveryUserCount(users);
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
      renderDiscoveryUserCount(users);
    });
    label.append(input, copy);
    container.append(label);
  }
}

function renderDiscoveryUserCount(users = state.discovery?.users || []) {
  const current = new Set(currentListField("ExcludedUserIds"));
  const saved = new Set(savedListField("ExcludedUserIds"));
  const changed = users.some((item) => current.has(item.id) !== saved.has(item.id));
  const effective = users.filter((item) => current.has(item.id) || item.legacyRuleExcluded === true).length;
  const count = byId("discovery-user-count");
  count.replaceChildren(document.createTextNode(`${users.length} found`));
  if (effective === 0) return;
  count.append(document.createTextNode(" ● "));
  const status = document.createElement("span");
  status.className = changed ? "discovery-selected-count" : "discovery-excluded-count";
  status.textContent = `${effective} ${changed ? "selected" : "excluded"}`;
  count.append(status);
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
    empty.textContent = state.discovery ? "No matching Tautulli user." : "Load Tautulli choices from Config to browse users.";
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
  setGlobalStatus("Loading private Tautulli choices...");
  try {
    state.discovery = await request("/api/v1/discovery/tautulli", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
    byId("discovery-confirm").checked = false;
    setGlobalStatus("Tautulli choices loaded and retained locally.", true);
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
      ? "Stored value will be preserved"
      : field.type === "secret" && field.secret?.availableFromRuntime
        ? "Runtime value available · paste only to store a copy"
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
      ? "Configured - hidden by default"
      : field.secret?.availableFromRuntime
        ? "Available from this runtime - not copied"
        : "Not configured";
    stateText.id = `config-secret-state-${field.name}`;
    secretLine.append(stateText);
    if (field.secret?.configured) {
      const clearLabel = document.createElement("label");
      clearLabel.className = "secret-clear";
      const clear = document.createElement("input");
      clear.type = "checkbox";
      clear.id = `config-clear-${field.name}`;
      clearLabel.append(clear, " Clear stored value");
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
  else button.setAttribute("aria-label", `Reveal saved ${field.label}`);
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
  byId("secret-reveal-title").textContent = `Reveal ${field.label}`;
  byId("secret-reveal-eyebrow").textContent = passwordRequired ? "Administrator confirmation" : "Explicit local reveal";
  byId("secret-reveal-copy").textContent = passwordRequired
    ? "Re-enter your Manager administrator password. Only this value will be returned, and it will clear automatically after 30 seconds."
    : "Confirm this one local reveal. Only the selected value will be returned, and it will clear automatically after 30 seconds.";
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
    setGlobalStatus(`${target.field.label} revealed temporarily.`, true);
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
  if (stateText) stateText.textContent = "Configured - hidden by default";
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
    steps: Object.fromEntries(setupWorkflowSteps.map((name) => [name, { state: "waiting", summary: "Waiting for the saved configuration." }])),
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
  updateSetupWorkflowStep("choices", "running", "Loading active libraries, users, and any explicit owner or administrator role...");
  renderDiscovery();
  renderVerification();
  try {
    discovered = await request("/api/v1/discovery/tautulli", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
    });
    state.discovery = discovered;
    if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
    updateSetupWorkflowStep("choices", "passed", `${discovered.libraries?.length || 0} active libraries and ${discovered.users?.length || 0} users loaded and retained locally.`);
  } catch (error) {
    updateSetupWorkflowStep("choices", "failed", error.message);
  } finally {
    state.discoveryRunning = false;
    renderDiscovery();
    renderVerification();
  }

  state.verificationRunning = true;
  updateSetupWorkflowStep("lan", "running", "Testing the saved Tautulli and direct Plex endpoints...");
  renderDiscovery();
  renderVerification();
  try {
    const result = await request("/api/v1/checks/integrations", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, last: result };
    updateSetupWorkflowStep("lan", result.overall, result.overall === "passed"
      ? "Tautulli and direct Plex verification passed. Detailed evidence is available under Verify."
      : "The connection checks completed with a result that needs review under Verify.");
  } catch (error) {
    updateSetupWorkflowStep("lan", "failed", error.message);
  } finally {
    state.verificationRunning = false;
    renderDiscovery();
    renderVerification();
  }

  state.smtpVerificationRunning = true;
  updateSetupWorkflowStep("smtp", "running", "Checking SMTP reachability and STARTTLS without authenticating or sending...");
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
    updateSetupWorkflowStep("previews", "skipped", "Tautulli did not expose one unambiguous owner or administrator ID. Choose a user under Previews to generate the six local states manually.");
    await retainSkippedPreviewStatus(revision, "owner-not-found");
  } else if (operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation)) {
    updateSetupWorkflowStep("previews", "skipped", "Another Manager or schedule operation is active. Generate previews manually after it finishes.");
    await retainSkippedPreviewStatus(revision, "operation-active");
  } else {
    state.operationStarting = true;
    state.operationStartingType = "preview-all";
    updateSetupWorkflowStep("previews", "running", "Starting six local newsletter previews for the verified owner or administrator...");
    renderOperations();
    try {
      state.operation = await request("/api/v1/operations", {
        method: "POST",
        body: JSON.stringify({ type: "preview-all", expectedRevision: revision, userId: suggestedUserID, confirmNoSend: true }),
      });
      updateSetupWorkflowStep("previews", "running", "Six-state local preview generation started. No email will be sent; progress is available under Previews.");
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
  setGlobalStatus("Validating local configuration...");
  try {
    const result = await request("/api/v1/config", { method: "PUT", body: JSON.stringify(collectConfigSaveRequest()) });
    state.editor = result.editor;
    beginSetupWorkflow();
    await loadAll();
    selectView("configuration");
    setGlobalStatus(result.backup ? "Configuration saved and backed up. Running safe checks..." : "Configuration saved. Running safe checks...");
    await runPostSaveSetup(result.editor.revision);
    setGlobalStatus("Save verification finished. Review the results above.", true);
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
  setText("backup-count", state.backups.length ? `${state.backups.length} available` : "None created");
  if (!state.backups.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No backup exists yet. The first update to an existing config.json creates one automatically.";
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
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button button-secondary";
    button.textContent = "Restore";
    button.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button button-secondary";
    cancel.textContent = "Cancel";
    cancel.hidden = true;
    const actions = document.createElement("div");
    actions.className = "backup-actions";
    const resetConfirmation = () => {
      delete row.dataset.restoreArmed;
      row.classList.remove("armed");
      button.className = "button button-secondary";
      setSwappingButtonElementText(button, "Restore");
      button.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = true;
    };
    button.addEventListener("click", () => {
      if (row.dataset.restoreArmed === "true") {
        restoreBackup(backup, button, cancel);
        return;
      }
      row.dataset.restoreArmed = "true";
      row.classList.add("armed");
      button.className = "button button-danger";
      setSwappingButtonElementText(button, "Confirm restore");
      button.setAttribute("aria-label", `Confirm restore of configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = false;
    });
    cancel.addEventListener("click", resetConfirmation);
    actions.append(cancel, button);
    row.append(copy, actions);
    list.append(row);
  }
}

async function restoreBackup(backup, button, cancel) {
  button.disabled = true;
  cancel.disabled = true;
  setSwappingButtonElementText(button, "Restoring...");
  setGlobalStatus("Validating and restoring the selected backup...");
  try {
    const result = await request(`/api/v1/config/backups/${encodeURIComponent(backup.id)}/restore`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision }),
    });
    await loadAll();
    selectView("configuration");
    setGlobalStatus(result.safetyBackup ? "Backup restored. The replaced configuration was saved as a new safety backup." : "Backup restored.", true);
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
  setSwappingButtonText("verification-run-button", state.verificationRunning ? "Testing saved services..." : "Run connection test");
  setSwappingButtonText("smtp-verification-run-button", state.smtpVerificationRunning ? "Testing SMTP..." : "Run SMTP preflight");

  if (!ready) {
    byId("verification-message").textContent = "Complete and save configuration before running a connection test.";
    byId("smtp-verification-message").textContent = "Complete and save configuration before running SMTP preflight.";
  } else {
    byId("verification-message").textContent = state.verificationRunning
      ? "Contacting the saved Tautulli and direct Plex services. This may take up to 45 seconds."
      : "No service request occurs until the confirmation is checked and the button is pressed.";
    byId("smtp-verification-message").textContent = state.smtpVerificationRunning
      ? "Contacting the saved SMTP endpoint without authenticating or sending. This may take up to 45 seconds."
      : "No SMTP request occurs until the confirmation is checked and the button is pressed.";
  }

  const retainedLANState = retainedSetupCheckState("lan");
  const retainedSMTPState = retainedSetupCheckState("smtp");
  if (last) {
    setText("verification-observed", `Completed ${formatDate(last.completedAtUtc)} · ${titleCase(last.networkBoundary)}.`);
    for (const step of last.steps || []) {
      appendVerificationResult(results, step.service === "plex" ? "Direct Plex" : titleCase(step.service), step.state, step.summary);
    }
  } else if (retainedLANState) {
    setText("verification-observed", "Retained from the latest safe setup validation for this configuration.");
    appendVerificationResult(results, "Tautulli and direct Plex", retainedLANState, state.setupWorkflow.steps.lan.summary);
  } else {
    setText("verification-observed", "No integration result is retained for this saved configuration.");
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "Validate and save to run every safe setup check, or repeat this targeted connection test.";
    results.append(empty);
  }

  if (smtp) {
    setText("smtp-verification-observed", `Completed ${formatDate(smtp.completedAtUtc)} · ${titleCase(smtp.security)}.`);
    appendVerificationResult(smtpResults, "SMTP preflight", smtp.state, smtp.summary);
  } else if (retainedSMTPState) {
    setText("smtp-verification-observed", "Retained from the latest safe setup validation for this configuration.");
    appendVerificationResult(smtpResults, "SMTP preflight", retainedSMTPState, state.setupWorkflow.steps.smtp.summary);
  } else {
    setText("smtp-verification-observed", "No SMTP preflight is retained for this saved configuration.");
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "Validate and save to run every safe setup check, or repeat this targeted SMTP preflight.";
    smtpResults.append(empty);
  }

  const { overallLabel, overallTone } = renderIntegrationStatus();
  setChip("verification-chip", overallLabel, overallTone);
}

async function runVerification() {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || !byId("verification-confirm").checked || state.editor?.state !== "ready") return;
  state.verificationRunning = true;
  const button = byId("verification-run-button");
  setSwappingButtonText("verification-run-button", "Testing saved services...");
  renderVerification();
  renderDiscovery();
  setGlobalStatus("Running Tautulli and direct Plex connection checks...");
  try {
    const result = await request("/api/v1/checks/integrations", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, last: result };
    byId("verification-confirm").checked = false;
    setGlobalStatus(result.overall === "failed" ? "Connection test completed with failures." : "Connection test completed.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.verificationRunning = false;
    setSwappingButtonText("verification-run-button", "Run connection test");
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
  setGlobalStatus("Running the non-sending SMTP reachability and STARTTLS preflight...");
  try {
    const result = await request("/api/v1/checks/smtp-network", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, smtp: result };
    byId("smtp-verification-confirm").checked = false;
    const message = result.overall === "failed"
      ? "SMTP preflight completed with a failure. No credentials or message data were sent."
      : result.overall === "warning"
        ? "SMTP is reachable, but the saved configuration has STARTTLS disabled."
        : "SMTP reachability and certificate-validated STARTTLS passed. Authentication still requires TestEmail.";
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
  setChip("preview-chip", state.previews.length ? `${state.previews.length} available` : "None generated", state.previews.length ? "good" : "neutral");
  if (!state.previews.length) {
    state.selectedPreviewID = "";
    byId("preview-placeholder").hidden = false;
    const frame = byId("preview-frame");
    frame.hidden = true;
    frame.removeAttribute("data-preview-id");
    frame.src = "about:blank";
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No generated HTML previews were found in the package output folder.";
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
    || previews.find((preview) => generated.has(preview.id) && /-00-index(?:\.html)?$/i.test(preview.name))
    || previews.find((preview) => generated.has(preview.id))
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

  let message = "Enter a numeric Tautulli user ID, then confirm this preview-only run.";
  if (!ready) message = "Complete and save configuration before generating previews.";
  else if (active) message = operation.type === "preview-all" ? (operation.state === "cancelling" ? "Stopping the local preview process safely..." : "Generating previews. You can leave this page while the Manager tracks the operation.") : "An email delivery is active. Wait for its aggregate SMTP result before starting another operation.";
  else if (scheduleActive) message = "Wait for the active Windows schedule change before generating previews.";
  else if (state.operationStarting) message = "Starting a fixed Manager operation...";
  else if (!userIDValid && userID) message = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (userIDValid && confirmed) message = "Ready to generate six local previews without sending email.";
  setText("preview-operation-message", message);

  const testButton = byId("test-send-run-button");
  testButton.disabled = state.operationStarting || active || scheduleActive || !ready || !testUserIDValid || !testConfirmed;
  setSwappingButtonText("test-send-run-button", state.operationStarting && state.operationStartingType === "send-test-all" ? "Starting test delivery..." : active || scheduleActive ? "Another operation is active" : "Send six test messages");
  let testMessage = "Enter a numeric Tautulli user ID, then confirm the six-message test delivery.";
  if (!ready) testMessage = "Complete and save configuration before sending a test delivery.";
  else if (active) testMessage = operation.type === "send-test-all" ? "Sending to the configured TestEmail. Cancellation is disabled because some messages may already be accepted by SMTP." : "Another Manager operation is active. Wait for it to finish before starting a test delivery.";
  else if (scheduleActive) testMessage = "Wait for the active Windows schedule change before starting a test delivery.";
  else if (state.operationStarting) testMessage = "Starting a fixed Manager operation...";
  else if (!testUserIDValid && testUserID) testMessage = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (testUserIDValid && testConfirmed) testMessage = "Ready to send six real messages only to the configured TestEmail.";
  setText("test-send-operation-message", testMessage);

  const manualSendButton = byId("manual-send-run-button");
  manualSendButton.disabled = state.operationStarting || active || scheduleActive || !ready || !manualSendConfirmed || !manualSendUserValid;
  const manualSendButtonLabel = manualWelcome ? "Send Manual Welcome" : "Send newsletter to all";
  setSwappingButtonText("manual-send-run-button", state.operationStarting && state.operationStartingType === manualSendType ? "Starting manual delivery..." : active || scheduleActive ? "Another operation is active" : manualSendButtonLabel);
  let manualSendMessage = manualWelcome ? "Choose a Tautulli user, then explicitly confirm the one-message Manual Welcome delivery." : "Explicitly confirm the all-recipient production delivery to enable this action.";
  if (!ready) manualSendMessage = "Complete and save configuration before sending a production newsletter.";
  else if (active) manualSendMessage = ["send-welcome", "send-all"].includes(operation.type) ? "A production delivery is running. Cancellation is disabled because a message may already be accepted by SMTP." : "Another Manager operation is active. Wait for it to finish before sending a production newsletter.";
  else if (scheduleActive) manualSendMessage = "Wait for the active Windows schedule change before sending a production newsletter.";
  else if (state.operationStarting) manualSendMessage = "Starting a fixed Manager operation...";
  else if (manualWelcome && manualSendUserID && !manualSendUserValid) manualSendMessage = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (manualSendConfirmed && manualSendUserValid) manualSendMessage = manualWelcome ? "Ready to send one real Manual Welcome message to the selected user." : "Ready to send real email to every currently eligible recipient.";
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
  setSwappingText("manual-send-runner-heading", manualWelcome ? "Send one Manual Welcome" : "Send this week's newsletter now");
  setText("manual-send-runner-copy", manualWelcome
    ? "Sends the renderer's Manual Welcome state to one selected Tautulli user, then updates that recipient's welcome and history state. It does not contact other Plex users."
    : "Runs the same fixed production delivery used by the schedule, applies saved library and user exclusions, and updates recipient welcome and history state for every eligible recipient.");
  setText("manual-send-confirm-heading", manualWelcome ? "Send one Manual Welcome newsletter" : "Send the production newsletter to all eligible recipients");
  setText("manual-send-confirm-copy", manualWelcome
    ? "I understand this sends one real email to the selected Plex user and updates that user's welcome state. The operation cannot be cancelled after it starts."
    : "I understand this may send real email to every eligible recipient and updates recipient state. The operation cannot be cancelled after it starts.");
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
  const card = byId("current-operation");
  const cancel = byId("preview-cancel-button");
  const manualSend = ["send-welcome", "send-all"].includes(operation?.type);
  card.hidden = manualSend;
  if (manualSend) {
    cancel.hidden = true;
    return;
  }
  cancel.hidden = !operation?.cancellable || !operationIsActive(operation);
  cancel.disabled = state.operationCancelling;
  setSwappingButtonText("preview-cancel-button", state.operationCancelling ? "Cancelling..." : "Cancel preview generation");
  if (!operation) {
    setText("current-operation-heading", "No Manager operation recorded");
    setText("current-operation-copy", "The Manager keeps sanitized operation state locally.");
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
    setText("dashboard-operation-heading", "No Manager operation recorded");
    setText("dashboard-operation-copy", "Generate local previews, send a guarded six-message test, or start a confirmed production delivery from the Preview center.");
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
    empty.textContent = "No completed Manager operation has been recorded yet.";
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
      ? `${operation.smtpAcceptedCount || 0} accepted by SMTP`
      : operation.type === "send-all"
        ? `${operation.smtpAcceptedCount || 0} accepted · ${operation.skippedCount || 0} skipped · ${operation.failedCount || 0} failed`
        : `${operation.generatedPreviewIds?.length || 0} preview${operation.generatedPreviewIds?.length === 1 ? "" : "s"}`;
    meta.append(chip, count);
    row.append(copy, meta);
    container.append(row);
  }
}

function operationSummary(operation) {
  const count = operation.generatedPreviewIds?.length || 0;
  if (operation.type === "send-welcome") {
    switch (operation.state) {
    case "queued": return { heading: "Manual Welcome queued", copy: "One selected-user welcome newsletter is waiting to start." };
    case "running": return { heading: "Sending one Manual Welcome", copy: "One selected Plex user is being processed. Cancellation is disabled once delivery begins." };
    case "succeeded": return { heading: "Manual Welcome accepted by SMTP", copy: "One welcome message was accepted by SMTP. The selected user's welcome state was updated; inbox delivery is not asserted." };
    case "failed": return { heading: "Manual Welcome delivery failed", copy: operation.supportCode ? `The welcome renderer failed. Support code: ${operation.supportCode}.` : "The welcome renderer failed without exposing its recipient or raw output." };
    default: return { heading: "Manual Welcome delivery recorded", copy: "Review aggregate SMTP acceptance without exposing the selected recipient." };
    }
  }
  if (operation.type === "send-all") {
    const accepted = operation.smtpAcceptedCount || 0;
    const skipped = operation.skippedCount || 0;
    const failed = operation.failedCount || 0;
    switch (operation.state) {
    case "queued": return { heading: "Manual newsletter delivery queued", copy: "The fixed production delivery is waiting to start." };
    case "running": return { heading: "Sending the production newsletter", copy: "Eligible recipients are being processed. Cancellation is disabled once delivery begins." };
    case "succeeded": return { heading: "Manual newsletter accepted by SMTP", copy: `${accepted} message${accepted === 1 ? " was" : "s were"} accepted by SMTP and ${skipped} recipient${skipped === 1 ? " was" : "s were"} skipped. Inbox delivery is not asserted.` };
    case "partial": return { heading: "Manual newsletter completed with delivery failures", copy: `${accepted} accepted by SMTP, ${skipped} skipped, and ${failed} failed. Inbox delivery is not asserted${operation.supportCode ? `; support code: ${operation.supportCode}` : ""}.` };
    case "failed": return { heading: "Manual newsletter delivery failed", copy: operation.supportCode ? `${accepted} messages were accepted before failure. Support code: ${operation.supportCode}.` : "The production renderer failed without exposing recipients or raw output." };
    default: return { heading: "Manual newsletter delivery recorded", copy: `${accepted} accepted by SMTP, ${skipped} skipped, and ${failed} failed. Inbox delivery is not asserted.` };
    }
  }
  if (operation.type === "send-test-all") {
    switch (operation.state) {
    case "queued": return { heading: "Test delivery queued", copy: "The fixed six-message TestEmail operation is waiting to start." };
    case "running": return { heading: "Sending six test messages", copy: "Messages go only to the configured TestEmail; cancellation is disabled once sending begins." };
    case "succeeded": return { heading: "Test delivery accepted by SMTP", copy: `${operation.smtpAcceptedCount || 0} test messages were accepted by SMTP. Inbox delivery is not asserted.` };
    case "failed": return { heading: "Test delivery failed", copy: operation.supportCode ? `${operation.smtpAcceptedCount || 0} messages were accepted before failure. Support code: ${operation.supportCode}.` : "The test renderer failed without exposing its destination or raw output." };
    default: return { heading: "Test delivery recorded", copy: "Review aggregate SMTP acceptance and failure counts." };
    }
  }
  switch (operation.state) {
  case "queued": return { heading: "Preview generation queued", copy: "The fixed Windows preview operation is waiting to start." };
  case "running": return { heading: "Generating newsletter previews", copy: "The package renderer is creating local HTML; no email is sent." };
  case "cancelling": return { heading: "Cancelling preview generation", copy: "The Manager is stopping the local renderer and retaining a sanitized result." };
  case "succeeded": return { heading: "Preview generation completed", copy: `${count} generated preview${count === 1 ? " is" : "s are"} available for authenticated review.` };
  case "cancelled": return { heading: "Preview generation cancelled", copy: "The local renderer was stopped before normal completion; no email was sent." };
  case "failed": return { heading: "Preview generation failed", copy: operation.supportCode ? `A sanitized support code is available: ${operation.supportCode}.` : "The renderer exited without exposing private output to the browser." };
  default: return { heading: "Preview operation recorded", copy: "Review the sanitized state and generated preview list." };
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
  setGlobalStatus("Starting the fixed local preview operation...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "preview-all", expectedRevision: state.editor.revision, userId: userID, confirmNoSend: true }),
    });
    byId("preview-user-id").value = "";
    byId("preview-confirm").checked = false;
    setGlobalStatus("Preview generation started. No email will be sent.", true);
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
  setGlobalStatus("Starting the guarded six-message test delivery...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "send-test-all", expectedRevision: state.editor.revision, userId: userID, confirmTestSend: true }),
    });
    byId("test-send-user-id").value = "";
    byId("test-send-confirm").checked = false;
    setGlobalStatus("Test delivery started. Messages go only to the configured TestEmail.", true);
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
  setGlobalStatus(type === "send-welcome" ? "Starting the confirmed Manual Welcome delivery..." : "Starting the confirmed all-recipient newsletter delivery...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type, expectedRevision: state.editor.revision, userId: type === "send-welcome" ? userID : "", confirmProductionSend: true }),
    });
    if (type === "send-welcome") byId("manual-send-user-id").value = "";
    byId("manual-send-confirm").checked = false;
    setGlobalStatus(type === "send-welcome" ? "Manual Welcome delivery started. The selected user is not retained in Manager history." : "All-recipient production delivery started. Aggregate SMTP evidence will be retained locally.", true);
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
  setGlobalStatus("Cancelling local preview generation...");
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
  setGlobalStatus("Starting the fixed Windows schedule helper...");
  try {
    state.scheduleOperation = await request(`/api/v1/schedule/${encodeURIComponent(action)}`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirm: true }),
    });
    state.schedulePendingAction = "";
    byId("schedule-confirm").checked = false;
    setGlobalStatus("Schedule operation started. Review the Windows UAC prompt.", true);
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

function renderStartupSettings() {
  const startup = state.startup || { supported: false, state: "unsupported" };
  const panel = byId("startup-settings-panel");
  panel.hidden = !startup.supported;
  if (!startup.supported) return;
  const managerToggle = byId("startup-manager");
  const dashboardToggle = byId("startup-dashboard");
  const unavailable = ["conflict", "unavailable"].includes(startup.state);
  if (!state.startupDirty) {
    managerToggle.checked = Boolean(startup.startManager);
    dashboardToggle.checked = Boolean(startup.openDashboard && startup.startManager);
  }
  if (!managerToggle.checked) dashboardToggle.checked = false;
  managerToggle.disabled = state.startupSaving || unavailable;
  dashboardToggle.disabled = state.startupSaving || unavailable || !managerToggle.checked;
  managerToggle.closest(".config-toggle").querySelector("em").textContent = managerToggle.checked ? "On" : "Off";
  dashboardToggle.closest(".config-toggle").querySelector("em").textContent = dashboardToggle.checked ? "On" : "Off";
  const dependent = dashboardToggle.closest(".startup-setting");
  dependent.classList.toggle("disabled", dashboardToggle.disabled);
  const label = startup.state === "conflict" ? "Needs review" : startup.state === "unavailable" ? "Unavailable" : managerToggle.checked ? "Enabled" : "Disabled";
  const tone = startup.state === "conflict" || startup.state === "unavailable" ? "bad" : managerToggle.checked ? "good" : "neutral";
  setChip("startup-settings-chip", label, tone);
  const save = byId("startup-settings-save");
  save.disabled = state.startupSaving || unavailable || !state.startupDirty;
  setSwappingButtonText("startup-settings-save", state.startupSaving ? "Saving startup settings..." : "Save startup settings");
  if (!state.startupDirty && !state.startupSaving) {
    const message = byId("startup-settings-message");
    if (startup.state === "conflict") message.textContent = "A same-named Windows sign-in entry does not match this installation. It was left unchanged.";
    else if (startup.state === "unavailable") message.textContent = "Windows sign-in startup status could not be read safely.";
    else if (startup.startManager && startup.openDashboard) message.textContent = "The Manager starts silently at sign-in, then opens the Dashboard once it is ready.";
    else if (startup.startManager) message.textContent = "The Manager starts silently in the notification area at sign-in.";
    else message.textContent = "The Manager starts only when you open it.";
  }
}

function startupSettingsChanged() {
  const managerToggle = byId("startup-manager");
  const dashboardToggle = byId("startup-dashboard");
  if (!managerToggle.checked) dashboardToggle.checked = false;
  state.startupDirty = managerToggle.checked !== Boolean(state.startup?.startManager)
    || dashboardToggle.checked !== Boolean(state.startup?.openDashboard);
  byId("startup-settings-message").textContent = state.startupDirty ? "Review and save this sign-in behavior." : "Startup settings are unchanged.";
  renderStartupSettings();
}

async function submitStartupSettings(event) {
  event.preventDefault();
  if (!state.startupDirty || state.startupSaving) return;
  state.startupSaving = true;
  renderStartupSettings();
  try {
    state.startup = await request("/api/v1/startup", {
      method: "PUT",
      body: JSON.stringify({
        startManager: byId("startup-manager").checked,
        openDashboard: byId("startup-dashboard").checked,
      }),
    });
    state.startupDirty = false;
    setGlobalStatus("Windows sign-in settings saved.", true);
  } catch (error) {
    byId("startup-settings-message").textContent = error.message;
  } finally {
    state.startupSaving = false;
    renderStartupSettings();
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
    ? "This Manager mode requires authentication. A password can be changed here, but the lock cannot be disabled while this mode is active."
    : localLock
      ? "The optional password lock is enabled. Existing sessions remain active; a password is required after sign-out or restart."
      : `${accessSurfaceLabel()} is currently trusted without a password. Enable the optional lock when other people can reach this Manager.`);
  setText("access-password-label", passwordLockActive ? "New password" : "Create password");
  setSwappingButtonText("access-password-submit", passwordLockActive ? "Change password" : "Enable password lock");
  byId("access-disable-button").hidden = !localLock || !access.canDisable;
  byId("logout-button").hidden = !locked;
  const policy = byId("config-secret-policy");
  if (policy) policy.textContent = locked
    ? "Secrets stay hidden by default. Saving preserves stored credentials unless you replace or clear them. Revealing one value requires your Manager password, returns only that field, and clears it from the page after 30 seconds. Existing configurations receive a private timestamped backup."
    : "Secrets stay hidden by default. Saving preserves stored credentials unless you replace or clear them. An explicit reveal returns only the selected field and clears it from the page after 30 seconds. Existing configurations receive a private timestamped backup.";
}

function accessSurfaceLabel() {
  const platform = String(state.status?.platform || "").toLowerCase();
  if (platform === "windows") return "Browser access";
  if (platform === "linux" || platform === "freebsd") return "Container access";
  return "Manager access";
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
  message.textContent = state.authAccess?.passwordLockEnabled ? "Changing the local Manager password..." : "Enabling the local Manager password lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/password", { method: "POST", body: JSON.stringify({ password }) });
    byId("access-password").value = "";
    byId("access-password-confirm").value = "";
    concealMaskedInputs(byId("access-password-form"));
    renderAccessSettings();
    message.textContent = "Manager access settings saved. This browser remains signed in.";
    setGlobalStatus("Manager password lock updated.", true);
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
  message.textContent = "Disabling the optional Manager password lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/disable", { method: "POST", body: "{}" });
    renderAccessSettings();
    message.textContent = "Password lock disabled. The Manager remains limited to this computer.";
    setGlobalStatus("Manager returned to trusted-local access.", true);
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
  setText("diagnostics-count", events.length ? `${events.length} retained` : "No events");
  setText("diagnostics-retention", `Up to ${state.diagnostics?.maximumEntries || 200} events for ${state.diagnostics?.retentionDays || 30} days.`);
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
    metadata.textContent = `${diagnosticAreaLabel(event.area)} · Support code ${event.code}`;
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
    frame.src = `/preview/${encodeURIComponent(id)}`;
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
  case "healthy": return "The local management surface is responding.";
  case "unconfigured": return "TautWeekly is ready for guided setup.";
  case "blocked": return "Configuration needs attention before delivery.";
  default: return "The manager is online with a degraded signal.";
  }
}
function overallCopy(overall) {
  switch (overall) {
  case "healthy": return "Status is read from this host. No settings were changed and no external connection tests were run.";
  case "unconfigured": return "No private configuration was found. Automatic delivery remains unavailable until setup is completed.";
  case "blocked": return "A configuration file exists but cannot be interpreted safely. The manager will not guess or coerce its values.";
  default: return "One or more optional status probes could not be completed. Review the health cards below.";
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
byId("startup-settings-form").addEventListener("submit", submitStartupSettings);
byId("startup-manager").addEventListener("change", startupSettingsChanged);
byId("startup-dashboard").addEventListener("change", startupSettingsChanged);
byId("logout-button").addEventListener("click", logout);
byId("refresh-button").addEventListener("click", loadAll);
byId("access-status-button").addEventListener("click", openAccessSettings);
document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.view)));
document.querySelectorAll("[data-open-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.openView)));
initialize().catch((error) => setAuthMessage(`Manager initialization failed: ${error.message}`));
