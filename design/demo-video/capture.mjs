import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const [mode, ...rest] = process.argv.slice(2); // stills t1 t2 ... | frames fps dur outdir
const browser = await chromium.launch({ executablePath: process.env.CHROME });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(process.cwd() + '/index.html').href);
await page.evaluate(() => window.assetsReady);
await page.waitForTimeout(300);
if (mode === 'stills') {
  for (const t of rest) {
    await page.evaluate(t => window.render(t), parseFloat(t));
    await page.screenshot({ path: `stills/t${t}.png` });
  }
} else {
  const [fps, dur, out] = [parseFloat(rest[0]), parseFloat(rest[1]), rest[2]];
  const n = Math.round(fps * dur);
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.render(t), i / fps);
    await page.screenshot({ path: `${out}/f${String(i).padStart(5, '0')}.png` });
  }
}
await browser.close();
