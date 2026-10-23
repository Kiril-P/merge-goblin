import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const [mode, ...rest] = process.argv.slice(2); // stills t1 t2 ... | frames fps dur outdir
const browser = await chromium.launch({ executablePath: process.env.CHROME || process.env.HOME + '/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(process.cwd() + '/index.html').href);
await page.evaluate(() => window.assetsReady);
await page.waitForTimeout(300);
if (mode === 'stills') {
  for (const t of rest) {
    await page.evaluate(async t => { window.render(t); await Promise.all([...document.images].map(i => i.decode().catch(() => {}))); }, parseFloat(t));
    await page.screenshot({ path: `stills/t${t}.png` });
  }
} else {
  const [fps, dur, out] = [parseFloat(rest[0]), parseFloat(rest[1]), rest[2]];
  const n = Math.round(fps * dur);
  const from = parseInt(rest[3] || '0'), to = parseInt(rest[4] || String(n));
  for (let i = from; i < Math.min(n, to); i++) {
    await page.evaluate(async t => { window.render(t); await Promise.all([...document.images].map(i => i.decode().catch(() => {}))); }, i / fps);
    await page.screenshot({ path: `${out}/f${String(i).padStart(5, '0')}.png` });
  }
}
await browser.close();
