// Loads each built page in headless Chromium and fails on script errors, quirks mode or a missing title.
// Usage: node scripts/smoke-pages.mjs [_site]   (needs the `playwright` package and its Chromium)
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = process.argv[2] ?? '_site';
const types = { '.html': 'text/html; charset=utf-8', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  let p = normalize(decodeURIComponent(req.url.split('?')[0]));
  if (p.endsWith('/')) p += 'index.html';
  try {
    const body = await readFile(join(root, p));
    res.writeHead(200, { 'content-type': types[extname(p)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise(r => server.listen(0, r));
const base = `http://localhost:${server.address().port}`;

// PW_CHANNEL=chrome uses an installed Chrome instead of Playwright's download.
const browser = await chromium.launch(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {});
let failed = false;
for (const path of ['/', '/v1/', '/v2/']) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('response', r => { if (r.url().startsWith(base) && r.status() >= 400) errors.push(`${r.status()} ${r.url()}`); });
  await page.goto(base + path, { waitUntil: 'load' });
  await page.waitForTimeout(1500); // let the game loop run a few frames
  const mode = await page.evaluate(() => document.compatMode);
  const title = await page.title();
  const ok = !errors.length && mode === 'CSS1Compat' && title;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${path}  "${title}"  ${mode}`);
  errors.forEach(e => console.log('     ' + e));
  failed ||= !ok;
  await page.close();
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
