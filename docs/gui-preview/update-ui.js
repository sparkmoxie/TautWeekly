"use strict";

(function exposeUpdateUI(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.TautWeeklyUpdateUI = api;
})(typeof globalThis === "object" ? globalThis : window, () => {
  const hiddenIndicator = Object.freeze({ visible: false, label: "", version: "" });
  const routedViews = new Set(["dashboard", "configuration", "schedule", "verification", "previews", "about"]);

  function parseVersion(value, stableOnly = false) {
    const normalized = String(value || "").trim().replace(/^v/, "");
    const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(normalized);
    if (!match || (stableOnly && (match[4] || match[5]))) return null;
    const numbers = match.slice(1, 4).map(Number);
    if (numbers.some((number) => !Number.isSafeInteger(number) || number > 1_000_000)) return null;
    const prerelease = match[4] ? match[4].split(".") : [];
    if (prerelease.some((identifier) => /^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith("0"))) return null;
    return { numbers, prerelease, normalized: `${numbers.join(".")}${match[4] ? `-${match[4]}` : ""}` };
  }

  function compareVersions(left, right) {
    for (let index = 0; index < 3; index += 1) {
      if (left.numbers[index] !== right.numbers[index]) return left.numbers[index] < right.numbers[index] ? -1 : 1;
    }
    if (!left.prerelease.length && !right.prerelease.length) return 0;
    if (!left.prerelease.length) return 1;
    if (!right.prerelease.length) return -1;
    const length = Math.max(left.prerelease.length, right.prerelease.length);
    for (let index = 0; index < length; index += 1) {
      const leftValue = left.prerelease[index];
      const rightValue = right.prerelease[index];
      if (leftValue === undefined) return -1;
      if (rightValue === undefined) return 1;
      if (leftValue === rightValue) continue;
      const leftNumeric = /^\d+$/.test(leftValue);
      const rightNumeric = /^\d+$/.test(rightValue);
      if (leftNumeric && rightNumeric) return Number(leftValue) < Number(rightValue) ? -1 : 1;
      if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
      return leftValue < rightValue ? -1 : 1;
    }
    return 0;
  }

  function updateIndicator(update) {
    if (!update || update.state !== "update-available" || update.updateAvailable !== true || update.updateChannel !== "stable") return hiddenIndicator;
    if (update.hostAdapterState === "legacy" || !update.lastSuccessfulCheckUtc || Number.isNaN(Date.parse(update.lastSuccessfulCheckUtc))) return hiddenIndicator;
    const running = parseVersion(update.applicationVersion || update.managerVersion);
    const manager = parseVersion(update.managerVersion || update.applicationVersion);
    const latest = parseVersion(update.latestStableVersion, true);
    if (!running || !manager || !latest || compareVersions(running, manager) !== 0 || compareVersions(running, latest) >= 0) return hiddenIndicator;
    for (const layer of [update.packageVersion, update.imageVersion]) {
      if (!layer) continue;
      const parsed = parseVersion(layer);
      if (!parsed || compareVersions(parsed, running) !== 0) return hiddenIndicator;
    }
    const version = `v${latest.normalized}`;
    return { visible: true, version, label: `Update available — Version ${version}` };
  }

  function updateCheckCooldown(update, nowMilliseconds = Date.now()) {
    const retryAt = Date.parse(String(update?.nextCheckAllowedAtUtc || ""));
    if (!Number.isFinite(retryAt) || !Number.isFinite(nowMilliseconds)) {
      return { active: false, delayMilliseconds: 0 };
    }
    const delayMilliseconds = Math.max(0, retryAt - nowMilliseconds);
    return { active: delayMilliseconds > 0, delayMilliseconds };
  }

  function routeFromHash(hash) {
    let value = String(hash || "").replace(/^#/, "");
    try { value = decodeURIComponent(value); } catch (_) { return { view: "dashboard", section: "" }; }
    value = value.toLowerCase();
    if (value === "settings/application-and-package-status") return { view: "about", section: "updates" };
    if (value === "settings/tailscale-funnel") return { view: "about", section: "tailscale" };
    if (value === "settings") return { view: "about", section: "" };
    if (routedViews.has(value)) return { view: value, section: "" };
    return { view: "dashboard", section: "" };
  }

  function hashForRoute(view, section = "") {
    if (view === "about" && section === "updates") return "#settings/application-and-package-status";
    if (view === "about" && section === "tailscale") return "#settings/tailscale-funnel";
    if (view === "about") return "#settings";
    return routedViews.has(view) ? `#${view}` : "#dashboard";
  }

  return Object.freeze({ updateIndicator, updateCheckCooldown, routeFromHash, hashForRoute });
});
