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
vm.runInContext(source, context, { filename: rendererPath });

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

const quiet = preview.html("demo-quiet");
assert.ok(!quiet.includes('class="stats-summary-grid"') && !quiet.includes("YOU CLOCKED"), "zero-activity preview rendered populated personal summary cards");
assert.ok(!source.match(/https?:\/\//i), "synthetic preview renderer contains an external URL");

console.log("[PASS] GUI preview personal stats are uncapped, rated when eligible, responsively paired, and network-local.");
