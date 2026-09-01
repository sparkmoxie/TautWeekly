import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const rendererPath = path.join(root, "docs", "gui-preview", "rich-preview.js");
const source = fs.readFileSync(rendererPath, "utf8");
const context = vm.createContext({
  window: {},
  document: { getElementById: () => null },
});
vm.runInContext(source.replace("  function showCard(item) {", "  window.fixtureShowCard = showCard;\n  function showCard(item) {"), context, { filename: rendererPath });

const preview = context.window.TautWeeklyPreviewDemo;
assert.ok(preview && typeof preview.html === "function", "synthetic preview renderer was not registered");

const occurrences = (value, marker) => value.split(marker).length - 1;
const titleSegment = (html, title) => {
  const start = html.indexOf(title);
  assert.notEqual(start, -1, `missing synthetic personal row: ${title}`);
  const next = html.indexOf('class="watched-row"', start);
  return html.slice(start, next === -1 ? html.length : next);
};

const normal = preview.html("demo-normal");
assert.equal(occurrences(normal, 'class="watched-row"'), 23, "normal preview did not render all 12 movie and 11 TV rows");
assert.ok(normal.includes("Uncapped") === false, "production-test labels leaked into the GUI preview");
assert.ok(normal.includes("The Last Comet") && normal.includes("Deep Atlas"), "normal preview lost rows beyond the former four-row cap");
assert.ok(normal.indexOf("MOVIES WATCHED") < normal.indexOf("TV SHOWS WATCHED"), "movie and TV cards are not separate full-width sections in order");
assert.ok(normal.includes('class="stats-media-stack"') && normal.includes('class="stats-summary-grid"'), "normal preview lost the full-width media stack or compact summary row");
assert.ok(normal.includes(".stats-media-card .watched-list{display:grid;grid-template-columns:repeat(2"), "desktop preview does not render two personal titles per row");
assert.ok(normal.includes('class="stats-media-card stats-movie-media-card"') && normal.includes('class="stats-media-card stats-tv-media-card"'), "preview does not distinguish responsive movie and TV cards");
assert.ok(normal.includes(".stats-media-card .watched-list,.stats-summary-grid{grid-template-columns:1fr}"), "mobile preview does not stack movie titles and compact summary cards");
assert.ok(normal.includes(".stats-tv-media-card .watched-list{grid-template-columns:repeat(2"), "mobile preview does not preserve two TV titles per row");
assert.ok(normal.includes("YOU CLOCKED") && normal.includes("total watch time"), "normal preview lost the personal-time eyebrow or renamed label");
assert.ok(normal.includes("51h 18m") && normal.includes("6h 4m watched"), "personal and qualifying Binge Champion durations were incorrectly forced to match");
assert.ok(normal.includes("YOU WON") && normal.includes('metric compact gold'), "winner preview lost its gold Binge Champion treatment");
assert.ok(normal.includes("2 TV shows: 7 episodes"), "winner preview lost the cumulative Binge episode count");
assert.ok(normal.includes("Rotten Tomatoes critic score") && normal.includes("Rotten Tomatoes audience score"), "personal movie rows lost eligible Rotten Tomatoes ratings");
assert.ok(normal.includes('alt="IMDb">8.2') && normal.includes('alt="IMDb">8.0'), "personal TV rows lost eligible IMDb ratings");
assert.ok(normal.includes(".watched-row>img{width:38px;height:56px;object-fit:cover") && !normal.includes(".watched-row img{"), "preview poster sizing can still override nested rating images");
assert.ok(normal.includes(".imdb img{width:28px;height:14px;object-fit:contain}"), "preview IMDb badge lost its production-equivalent dimensions");
assert.ok(!titleSegment(normal, "Signal Nine").includes("personal-ratings"), "unrated movie row received an invented rating");
assert.ok(!titleSegment(normal, "Copper District").includes("personal-ratings"), "unrated TV row received an invented rating");
assert.ok(!normal.includes("Ratings unavailable") && !normal.includes("IMDb unavailable"), "preview rendered an unavailable-rating placeholder");
assert.ok(!/\b\d+h (?:6\d|[7-9]\d)m watched\b/.test(normal), "preview rendered a non-normalized TV watch duration");
assert.ok(normal.includes(".stats-summary-grid{grid-template-columns:1fr}"), "mobile preview does not stack the compact summary cards");

const uneven = preview.html("demo-history");
assert.equal(occurrences(uneven, 'class="watched-row"'), 6, "uneven preview did not render five movie rows and one TV row");
assert.ok(uneven.includes(">5</div><div class=\"stats-heading-label\">MOVIES WATCHED") && uneven.includes(">1</div><div class=\"stats-heading-label\">TV SHOWS WATCHED"), "uneven preview reported the wrong unique-title counts");
assert.ok(uneven.includes("THIS WEEK'S") && !uneven.includes('metric compact gold'), "non-winner preview retained the winner treatment");
assert.ok(uneven.includes("2 TV shows: 7 episodes"), "non-winner preview lost the cumulative Binge episode count");

const quiet = preview.html("demo-quiet");
assert.ok(!quiet.includes('class="stats-summary-grid"') && !quiet.includes("YOU CLOCKED"), "zero-activity preview rendered populated personal summary cards");
assert.ok(!source.match(/https?:\/\//i), "synthetic preview renderer contains an external URL");

console.log("[PASS] GUI preview personal stats are uncapped, rated when eligible, responsively paired, and network-local.");


// Current-release feature parity: use the existing synthetic renderer fixture.
assert.equal(occurrences(normal, 'alt="Watched"'), 3, "history fixture lost its hero/title movie markers");
assert.equal(occurrences(preview.html("demo-new"), 'alt="Watched"'), 0, "no-history fixture invented watched movies");
const recap = normal.slice(normal.indexOf('<section class="stats-media-stack">'));
assert.ok(!recap.includes('alt="Watched"'), "watched marks leaked into footer statistics");
assert.ok(normal.includes('width="16" height="16" alt="Watched"') && normal.includes("margin-left:8px"), "title marker no longer matches accepted sizing");
assert.ok(normal.includes('width="26" height="26" alt="Watched"'), "desktop shield size drifted");
assert.ok(normal.includes(".imdb{font-size:12px;font-weight:700}") && normal.includes("font-size:27px;font-weight:800;line-height:1.1"), "current type scale is missing");
assert.ok(normal.includes('class="recipient-platform-icon"') && normal.includes('width="21" height="21"'), "white platform glyph is missing");
preview.setReleaseScenario("tv-only");
const tvOnly = preview.html("demo-normal");
assert.ok(tvOnly.includes("0 NEW MOVIES &middot; 4 TV TITLES") && tvOnly.includes("TOP GENRE THIS WEEK"), "TV-only release scenario drifted");
preview.setReleaseScenario("quiet");
const noAdditions = preview.html("demo-normal");
assert.ok(noAdditions.includes("1 TRENDING MOVIE &middot; 4 RECENT MOVIE RELEASES"), "quiet release header/shelf count drifted");
preview.setReleaseScenario("new");

for (const episodes of [[], [["S01 EP01", "Episode", null]]]) {
  const card = context.window.fixtureShowCard({title:"Fictional fallback", art:"local.jpg", genre:"Drama", imdb:"8.1", episodes});
  assert.ok(card.includes('alt="IMDb">8.1'), "GUI lost show-level IMDb fallback");
  assert.ok(!context.window.fixtureShowCard({title:"Unrated", art:"local.jpg", episodes, imdb:null}).includes('alt="IMDb"'), "GUI invented an unavailable rating");
}

const gallerySource = fs.readFileSync(path.join(root, "docs/examples/preview-all-00-INDEX.html"), "utf8");
const galleryScript = gallerySource.match(/<script>([\s\S]*?)<\/script>/)[1];
const galleryContext = vm.createContext({ window: {} });
vm.runInContext(galleryScript.slice(0, galleryScript.indexOf("    function nav(){")) +
  "window.gallery = { states, email, statsBlock, heroBlock, tvCard, asset };})();", galleryContext);
const gallery = galleryContext.window.gallery;
const galleryNormal = gallery.email(gallery.states[3]);
assert.ok(galleryNormal.includes('width="26" height="26" alt="Watched"') && galleryNormal.includes('width="16" height="16" alt="Watched"'), "gallery watched markers are stale");
assert.ok(!gallery.statsBlock(gallery.states[3]).includes('alt="Watched"'), "gallery footer contains a watched mark");
assert.ok(gallery.statsBlock(gallery.states[3]).includes("font-size:27px;line-height:1.1;font-weight:800"), "gallery Binge value is stale");
assert.ok(gallery.statsBlock(gallery.states[3]).includes("2 TV shows: 7 episodes"), "gallery winner lost the cumulative Binge episode count");
assert.ok(gallery.statsBlock(gallery.states[2]).includes("2 TV shows: 7 episodes"), "gallery non-winner lost the cumulative Binge episode count");
assert.ok(gallery.tvCard({title:"Fictional fallback",poster:"local.jpg",episodes:[["S01 EP01","Episode",null]],imdb:"8.1"}).includes(">8.1</span>"), "gallery lost show-level IMDb fallback");
assert.ok(gallery.tvCard({title:"Fictional fallback",poster:"local.jpg",episodes:[],imdb:"8.1"}).includes(">8.1</span>"), "gallery lost no-episode IMDb fallback");
assert.equal(gallery.asset("movies.gif"), "../gui-preview/media/movies.gif", "gallery uses remote or stale stock artwork");
assert.ok(!gallerySource.includes("raw.githubusercontent.com"), "gallery still fetches bundled art from a separate source revision");

let clock = Date.now();
class FixtureDate extends Date {
  constructor(...args) { super(...(args.length ? args : [clock])); }
  static now() { return clock; }
}
const mockContext = vm.createContext({
  window: { location: { href: "https://preview.demo.invalid/TautWeekly/gui-preview/" } },
  URL, Response, Date: FixtureDate, setTimeout: (callback) => { callback(); return 1; },
});
const mockSource = fs.readFileSync(path.join(root, "docs/gui-preview/mock-api.js"), "utf8");
vm.runInContext(mockSource, mockContext);
const controls = mockContext.window.TautWeeklyDemoControls;
for (const [scenario, expected] of Object.entries({
  off: { state: "inactive", enabled: false, active: false, supported: true },
  active: { state: "active", enabled: true, active: true, supported: true },
  pending: { state: "starting", enabled: true, active: false, supported: true },
  blocked: { state: "needs-attention", enabled: true, active: false, supported: true },
  "not-configured": { state: "tailscale-required", enabled: false, active: false, supported: true },
  unsupported: { state: "unsupported", enabled: false, active: false, supported: false },
})) {
  controls.setFunnelScenario(scenario);
  const remote = (await (async () => {
    const response = await mockContext.window.fetch("/api/v1/remote-access/tailscale");
    return response.json();
  })());
  for (const [field, value] of Object.entries(expected)) {
    assert.equal(remote[field], value, scenario + " Funnel visual fixture drifted at " + field);
  }
  assert.equal(Boolean(remote.url && remote.url.includes("token")), false, scenario + " Funnel fixture disclosed a token");
}
controls.setProfile("windows");
const expectedVersion = fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8").match(/^## \[(\d+\.\d+\.\d+)\]/m)[1];
assert.equal(controls.version, expectedVersion, "GUI preview represents an old release");
const api = async (route, method = "GET", body = {}) => {
  const response = await mockContext.window.fetch(route, { method, body: JSON.stringify(body) });
  return { status: response.status, data: await response.json() };
};
assert.equal((await api("/api/v1/updates/check", "POST")).data.state, "current", "initial demo advertises an outdated upgrade");
controls.offerUpdate();
assert.equal((await api("/api/v1/updates")).data.latestStableVersion, expectedVersion);
assert.equal((await api("/api/v1/updates/install", "POST")).status, 202);
clock += 1000;
assert.equal((await api("/api/v1/updates")).data.applicationVersion, expectedVersion, "simulated upgrade never completes");
for (const name of ["windows", "nas", "mac", "linux", "freebsd"]) {
  controls.setProfile(name);
  assert.equal((await api("/api/v1/capabilities")).data.supportsStartup, name === "windows");
  assert.equal((await api("/api/v1/auth/access")).data.runtimeRequired, name !== "windows");
  controls.offerUpdate();
  assert.equal((await api("/api/v1/updates")).data.installSupported, name === "windows", "demo grants a host-owned updater to the browser");
  assert.equal((await api("/api/v1/remote-access/tailscale", "PUT", { enabled: true })).status, 400,
    "Funnel preview accepted the obsolete boolean/private-Serve operation");
  if (name === "windows") {
    await api("/api/v1/auth/access/password", "POST", { password: "synthetic preview password" });
  }
  const remote = await api("/api/v1/remote-access/tailscale", "PUT", { operation: "enable" });
  assert.equal(remote.data.active, false);
  assert.equal(remote.data.state, "starting", `${name} preview skipped the public-publication pending state`);
  const verified = await api("/api/v1/remote-access/tailscale/verify", "POST");
  assert.equal(verified.data.active, true, `${name} preview Verify did not promote a published Funnel to active`);
  assert.equal(remote.data.url, "https://manager.demo.invalid");
}
assert.equal((await api("/api/v1/updates/install", "POST")).status, 409, "service profile offered browser-owned installation");
assert.equal((await api("https://unrelated.demo.invalid/no-route")).status, 404, "unmatched request escaped the mock boundary");
console.log("[PASS] Current release/package simulations, watched markers, type scale, weekly scenarios, and gallery parity.");
