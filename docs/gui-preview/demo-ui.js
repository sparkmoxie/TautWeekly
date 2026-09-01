// Included in generated app.js before startup; no production frontend is changed.
(() => {
  const wrap = (original, after) => (...args) => { original(...args); after(...args); };
  renderAuthenticationBoundary = () => {
    setText("auth-runtime-eyebrow", "Fictional access simulation");
    setText("auth-runtime-copy", "Explore the current interface using fictional values only. Reload resets this demo.");
    document.querySelector(".auth-boundary p").textContent = "Static by design. No authentication service or host is contacted.";
    document.querySelector("#login-form .field-hint").textContent = "Enter any fictional value or reload to reset the simulation.";
  };
  renderCapabilities = wrap(renderCapabilities, () => {
    setText("mode-pill-label", "GUI Preview v" + window.TautWeeklyDemoControls.version);
    setText("sidebar-connection-label", "Static preview");
    setText("preview-runner-copy", "Renders fictional local newsletter states only. No Plex, Tautulli, SMTP, or host process is contacted.");
    setText("about-secret-copy", "All displayed credentials are fictional. Entered values exist only in this page and reset on reload.");
    setText("access-recovery-copy", "Reload this page to reset the fictional access settings. No host credential is changed.");
  });
  renderStartupSettings = wrap(renderStartupSettings, () => {
    if (!byId("startup-settings-panel").hidden) byId("startup-settings-message").textContent += " Simulation only; no sign-in entry is changed.";
  });
  renderTailscaleSettings = wrap(renderTailscaleSettings, () => {
    if (byId("tailscale-settings-panel").hidden) return;
    const remote = state.tailscale || {};
    const link = byId("tailscale-url");
    link.removeAttribute("href");
    link.hidden = !remote.enabled;
    link.textContent = remote.enabled ? "https://manager.demo.invalid (fictional)" : "";
    byId("tailscale-url-empty").hidden = Boolean(remote.enabled);
    byId("tailscale-copy-button").hidden = true;
    byId("tailscale-settings-message").textContent = "Simulation only. Enabling, disabling, or verifying changes fictional page state; no Tailscale account, command, or network is contacted.";
    byId("tailscale-refresh-button").textContent = "Simulate verification";
  });
  renderUpdates = wrap(renderUpdates, () => {
    byId("update-install-button").textContent = "Simulate install";
    byId("update-release-notes").href = "../releases/v" + window.TautWeeklyDemoControls.version + ".md";
    byId("update-release-notes").hidden = false;
    if (!state.updateChecking) byId("update-settings-message").textContent = "Fictional release metadata only. No GitHub request, download, installer, or host update runs.";
  });
  const funnelFixture = new URLSearchParams(window.location.search).get("funnel") || "off";
  if (["off", "active", "pending", "blocked", "not-configured", "unsupported"].includes(funnelFixture)) {
    window.TautWeeklyDemoControls.setFunnelScenario(funnelFixture);
    byId("demo-funnel-scenario").value = funnelFixture;
  }
  byId("demo-profile").addEventListener("change", async (event) => {
    window.TautWeeklyDemoControls.setProfile(event.target.value);
    byId("demo-funnel-scenario").value = "off";
    await loadAll();
  });
  byId("demo-funnel-scenario").addEventListener("change", async (event) => {
    window.TautWeeklyDemoControls.setFunnelScenario(event.target.value);
    await loadAll();
    selectView("dashboard");
  });
  byId("demo-release-scenario").addEventListener("change", (event) => {
    window.TautWeeklyPreviewDemo.setReleaseScenario(event.target.value);
    const button = byId("preview-list").querySelector(`[data-preview-id="${CSS.escape(state.selectedPreviewID)}"]`);
    if (button) openPreview(state.selectedPreviewID, button, { reloadKey: "scenario-" + Date.now() });
  });
  byId("demo-update-scenario").addEventListener("click", async () => {
    window.TautWeeklyDemoControls.offerUpdate();
    await loadAll();
    openUpdateSettings();
  });
})();
