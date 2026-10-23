import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const b = await chromium.launch({ executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
const p = await b.newPage({ viewport: { width: 1920, height: 1080 } });
await p.goto(pathToFileURL(process.cwd() + '/index.html').href);
await p.evaluate(() => window.assetsReady);
for (const [t, name] of [[11.3, 'cover'], [4.9, 'quick'], [9.9, 'menu-bar'], [14.5, 'review'], [18.6, 'github']]) {
  await p.evaluate(async t => { window.render(t); document.querySelectorAll('.cap,#keys').forEach(e => e.style.display = 'none');
    await Promise.all([...document.images].map(i => i.decode().catch(() => {}))); }, t);
  await p.screenshot({ path: `clean-${name}.png` });
}
await b.close();
