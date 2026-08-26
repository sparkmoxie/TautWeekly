#!/usr/bin/env node
// Local-only visual acceptance for retained synthetic integration fixtures.
// Usage: node scripts/test-recipient-watched-visuals.mjs FIXTURE_APP OUTPUT_DIR PLAYWRIGHT_MODULE BROWSER_EXE [PREVIEW_FILTER] [WIDTHS]
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [fixtureArg, outputArg, playwrightArg, executablePath, previewFilter, widthArg] = process.argv.slice(2);
const widths = widthArg ? widthArg.split(',').map(Number) : [1280, 390, 320];
assert(widths.length && widths.every(width => Number.isInteger(width) && width >= 320), 'Invalid viewport widths.');
assert(fixtureArg && outputArg && playwrightArg && executablePath, 'Provide all four paths; use only synthetic integration fixtures.');
const fixtureRoot = path.resolve(fixtureArg);
const outputRoot = path.resolve(outputArg);
const { chromium } = await import(pathToFileURL(path.resolve(playwrightArg)).href);
let names = (await fs.readdir(path.join(fixtureRoot, 'output'))).filter(name => /^preview-all-.*\.html$/.test(name)).sort();
assert.equal(names.length, 7, 'Expected the Index and all six lifecycle previews.');
if (previewFilter) names = names.filter(name => previewFilter.split(',').some(part => name.includes(part)));
assert(names.length > 0, 'Preview filter selected no pages.');
await fs.mkdir(outputRoot, { recursive: true });
const types = { '.html':'text/html', '.css':'text/css', '.js':'text/javascript', '.png':'image/png', '.gif':'image/gif', '.svg':'image/svg+xml' };
const server = http.createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
    const target = path.resolve(fixtureRoot, '.' + pathname);
    assert(target.startsWith(fixtureRoot + path.sep), 'Path outside synthetic fixture root.');
    await fs.access(target); // Never conceal a missing asset with a surrogate.
    const extension = path.extname(target).toLowerCase();
    if ((extension === '.jpg' || extension === '.jpeg') && /[/\\](posters|media)[/\\]/.test(target)) {
      // The API double deliberately uses signature-only JPEG probes. Serve a
      // code-native synthetic poster for browser layout, never real artwork.
      const backdrop = target.includes('backdrop');
      const width = backdrop ? 960 : 360;
      const height = 540;
      response.writeHead(200, { 'Content-Type':'image/svg+xml' });
      response.end('<svg xmlns="http://www.w3.org/2000/svg" width="' + width + '" height="' + height + '" viewBox="0 0 ' + width + ' ' + height + '"><rect width="100%" height="100%" fill="#243447"/><path d="M0 0L' + width + ' ' + height + 'H0Z" fill="#365268"/><circle cx="' + (width / 2) + '" cy="200" r="80" fill="#e5a00d"/><text x="50%" y="360" text-anchor="middle" fill="white" font-family="Arial" font-size="24">SYNTHETIC MOVIE</text></svg>');
      return;
    }
    assert(types[extension], 'Only preview HTML and public visual assets are served.');
    response.writeHead(200, { 'Content-Type':types[extension] });
    response.end(await fs.readFile(target));
  } catch {
    response.writeHead(404);
    response.end('Not found');
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = 'http://127.0.0.1:' + server.address().port;
const browser = await chromium.launch({ executablePath, headless: true });
const context = await browser.newContext();
await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
const page = await context.newPage();
const errors = [];
page.on('pageerror', error => errors.push(error.message));
const results = [];
try {
  for (const width of widths) {
    await page.setViewportSize({ width, height: 1000 });
    for (const name of names) {
      await page.goto(origin + '/output/' + encodeURIComponent(name), { waitUntil:'networkidle' });
      await page.waitForFunction(() => [...document.images].every(image => image.complete));
      const geometry = await page.evaluate(() => {
        const rect = element => {
          const box = element.getBoundingClientRect();
          return { left:box.left, top:box.top, right:box.right, width:box.width, height:box.height, centerY:box.top + box.height / 2 };
        };
        const visible = element => element.getBoundingClientRect().width > 0 && element.getBoundingClientRect().height > 0;
        const circles = [...document.querySelectorAll('.recipient-watched-title-icon')].filter(visible).map(icon => {
          let previous = icon.previousSibling;
          while (previous && previous.nodeType !== Node.TEXT_NODE) previous = previous.lastChild || previous.previousSibling;
          const range = document.createRange();
          range.setStart(previous, previous.textContent.length - 1);
          range.setEnd(previous, previous.textContent.length);
          const title = range.getBoundingClientRect();
          const box = rect(icon);
          return { title:previous.textContent, ...box, gap:box.left-title.right, centerDelta:box.centerY-(title.top+title.height/2), margin:getComputedStyle(icon).marginLeft, align:getComputedStyle(icon).verticalAlign, alt:icon.alt, tooltip:icon.title };
        });
        const badges = [...document.querySelectorAll('.recipient-watched-desktop-badge')].filter(visible).map(badge => {
          const poster = badge.closest('.recipient-watched-desktop-poster').querySelector('img');
          const box = rect(badge);
          const posterBox = rect(poster);
          return { ...box, inset:posterBox.right-box.right, raised:posterBox.top-box.top, posterWidth:posterBox.width, alt:badge.alt, tooltip:badge.title };
        });
        const typography = element => {
          const style = getComputedStyle(element);
          return { text:element.textContent.trim(), size:style.fontSize, weight:style.fontWeight, lineHeight:style.lineHeight, letterSpacing:style.letterSpacing, marginBottom:style.marginBottom };
        };
        const footerHeading = [...document.querySelectorAll('td')].find(element => element.textContent.trim() === 'YOUR WEEK ON PLEX');
        const inFooter = element => footerHeading && (footerHeading.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING);
        const summaries = [...document.querySelectorAll('div')].filter(element => visible(element) && inFooter(element) && /^(YOU CLOCKED|.*BINGE CHAMPION|TOP GENRE THIS WEEK|TRENDING THIS WEEK)$/.test(element.textContent.trim())).map(heading => {
          let value = heading.nextElementSibling;
          if (value?.tagName === 'IMG') value = value.nextElementSibling;
          return { heading:typography(heading), value:typography(value), support:value.nextElementSibling ? typography(value.nextElementSibling) : null };
        });
        const recap = [...document.querySelectorAll('.stats-title-cell div')].filter(visible).map(typography);
        const imdbRatings = [...document.querySelectorAll('img[alt="IMDb"]')].filter(visible).map(icon => typography(icon.parentElement));
        const labels = [...document.querySelectorAll('div')].filter(element => /^(MOVIES WATCHED|TV SHOWS WATCHED)$/.test(element.textContent.trim())).map(element => ({ ...typography(element), count:typography(element.previousElementSibling) }));
        const rtIcons = [...document.querySelectorAll('.stats-title-cell img[alt^="Rotten Tomatoes"]')].filter(visible).map(rect);
        const statsGrid = document.querySelector('.stats-summary-cell')?.closest('td.pad');
        const statsPadding = statsGrid ? getComputedStyle(statsGrid).paddingBottom : null;
        return {
          circles, badges, summaries, recap, imdbRatings, labels, rtIcons, statsPadding,
          footerMarkers:[...document.querySelectorAll('.recipient-watched-title-icon,.recipient-watched-desktop-badge')].filter(inFooter).length,
          broken:[...document.images].filter(image => !image.naturalWidth).map(image => image.getAttribute('src')),
          overflow:document.documentElement.scrollWidth > innerWidth,
          overflowElements:[...document.querySelectorAll('td,div,img')].filter(element => visible(element) && element.getBoundingClientRect().right > innerWidth + 1).slice(-12).map(element => ({ tag:element.tagName, text:element.textContent.trim().slice(0,70), ...rect(element) })),
        };
      });
      assert.equal(geometry.broken.length, 0, name + ': broken image reference');
      if (geometry.overflow) {
        await page.screenshot({ path:path.join(outputRoot, width + '-overflow.png'), fullPage:true });
        console.error(JSON.stringify(geometry.overflowElements));
      }
      assert.equal(geometry.overflow, false, name + ': horizontal overflow at ' + width);
      assert.equal(geometry.footerMarkers, 0, name + ': footer watched marker');
      for (const summary of geometry.summaries) {
        assert.equal(summary.heading.size, '12px');
        assert.equal(summary.heading.weight, '900');
        assert.equal(summary.heading.letterSpacing, '1.1px');
        assert.equal(summary.value.size, '27px');
        assert.equal(summary.value.weight, '800');
        assert(Math.abs(parseFloat(summary.value.lineHeight) - 29.7) < 0.01);
        if (summary.support) {
          assert.equal(summary.support.size, '12px');
          assert.equal(summary.support.weight, '400');
          assert(Math.abs(parseFloat(summary.support.lineHeight) - 16.2) < 0.01);
        }
      }
      for (const text of geometry.recap) assert.equal(text.size, '12px', 'Recap/IMDb text size: ' + text.text);
      for (const rating of geometry.imdbRatings) {
        assert.equal(rating.size, '12px', 'Main/footer IMDb number: ' + rating.text);
        assert.equal(rating.weight, '700');
      }
      for (const label of geometry.labels) {
        assert.equal(label.size, '12px');
        assert.equal(label.count.size, '18px');
        assert.equal(label.count.weight, '800');
        assert.equal(label.count.lineHeight, '18px');
        if (label.text === 'TV SHOWS WATCHED') assert.equal(label.marginBottom, '-7px');
      }
      for (const icon of geometry.rtIcons) {
        assert.equal(icon.width, 16);
        assert.equal(icon.height, 16);
      }
      if (geometry.statsPadding !== null) {
        assert.equal(geometry.statsPadding, '0px');
        assert(geometry.summaries.length >= 2, 'Missing footer summary measurements.');
      }
      for (const badge of geometry.badges) {
        assert.equal(width, 1280, 'Desktop badge leaked into mobile.');
        assert.equal(badge.width, 26);
        assert.equal(badge.height, 26);
        assert(Math.abs(badge.inset-7) < 0.5 && Math.abs(badge.raised-5) < 0.5, 'Desktop badge drifted from intended placement.');
        assert.equal(badge.posterWidth, 180);
        assert.equal(badge.alt, 'Watched');
        assert.equal(badge.tooltip, 'Watched');
      }
      for (const circle of geometry.circles) {
        assert.equal(circle.width, 16);
        assert.equal(circle.height, 16);
        assert.equal(circle.margin, '8px');
        assert.equal(circle.align, 'middle');
        assert.equal(circle.alt, 'Watched');
        assert.equal(circle.tooltip, 'Watched');
        assert(Math.abs(circle.gap-8) < 0.1, 'A wrapped title orphaned its icon or changed the 8px gap.');
        assert(Math.abs(circle.centerDelta) <= 1, 'The watched icon is not vertically centered with its title.');
      }
      results.push({ name, width, ...geometry });
      const statsHeading = page.getByText('YOUR WEEK ON PLEX', { exact:true }).first();
      if (await statsHeading.count()) {
        const y = await statsHeading.evaluate(element => element.getBoundingClientRect().top + scrollY);
        await page.screenshot({ path:path.join(outputRoot, width + '-' + name.replace('.html', '') + '-footer.png'), fullPage:true, clip:{ x:0, y, width, height:Math.min(1000, await page.evaluate(() => document.documentElement.scrollHeight) - y) } });
      }
      if (name.includes('04-normal')) {
        await page.screenshot({ path:path.join(outputRoot, width + '-normal.png'), fullPage:true });
        await page.locator(width === 1280 ? '.design-hot-desktop' : '.design-hot-mobile').last().screenshot({ path:path.join(outputRoot, width + '-hero.png') });
        const movieCard = page.locator('td[height="170"]').first();
        if (await movieCard.count()) await movieCard.locator('xpath=ancestor::table[1]').screenshot({ path:path.join(outputRoot, width + '-movie-card.png') });
      }
    }
  }
  assert.equal(errors.length, 0, 'Browser errors: ' + errors.join('; '));
  await fs.writeFile(path.join(outputRoot, 'geometry.json'), JSON.stringify(results, null, 2));
  console.log(JSON.stringify({ fixtures:names.length, viewports:widths.length, pages:results.length, screenshots:outputRoot, circles:results.flatMap(result => result.circles.map(circle => ({ width:result.width, title:circle.title, gap:circle.gap, centerDelta:circle.centerDelta }))) }));
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
