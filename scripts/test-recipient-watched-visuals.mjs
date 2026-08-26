#!/usr/bin/env node
// Local-only visual acceptance for retained synthetic integration fixtures.
// Usage: node scripts/test-recipient-watched-visuals.mjs FIXTURE_APP OUTPUT_DIR PLAYWRIGHT_MODULE BROWSER_EXE
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [fixtureArg, outputArg, playwrightArg, executablePath] = process.argv.slice(2);
assert(fixtureArg && outputArg && playwrightArg && executablePath, 'Provide all four paths; use only synthetic integration fixtures.');
const fixtureRoot = path.resolve(fixtureArg);
const outputRoot = path.resolve(outputArg);
const { chromium } = await import(pathToFileURL(path.resolve(playwrightArg)).href);
const names = (await fs.readdir(path.join(fixtureRoot, 'output'))).filter(name => /^preview-all-.*\.html$/.test(name)).sort();
assert.equal(names.length, 7, 'Expected the Index and all six lifecycle previews.');
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
  for (const width of [1280, 390, 320]) {
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
        return {
          circles, badges,
          broken:[...document.images].filter(image => !image.naturalWidth).map(image => image.getAttribute('src')),
          overflow:document.documentElement.scrollWidth > innerWidth,
        };
      });
      assert.equal(geometry.broken.length, 0, name + ': broken image reference');
      assert.equal(geometry.overflow, false, name + ': horizontal overflow at ' + width);
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
        assert.equal(circle.width, 20);
        assert.equal(circle.height, 20);
        assert.equal(circle.margin, '6px');
        assert.equal(circle.align, 'middle');
        assert.equal(circle.alt, 'Watched');
        assert.equal(circle.tooltip, 'Watched');
        assert(Math.abs(circle.gap-6) < 0.1, 'A wrapped title orphaned its icon or changed the 6px gap.');
        assert(Math.abs(circle.centerDelta) <= 1, 'The watched icon is not vertically centered with its title.');
      }
      results.push({ name, width, ...geometry });
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
  console.log(JSON.stringify({ fixtures:names.length, viewports:3, pages:results.length, screenshots:outputRoot, circles:results.flatMap(result => result.circles.map(circle => ({ width:result.width, title:circle.title, gap:circle.gap, centerDelta:circle.centerDelta }))) }));
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
