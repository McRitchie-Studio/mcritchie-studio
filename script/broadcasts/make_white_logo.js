const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const svg = 'file://' + path.resolve(__dirname, '..', '..', 'public', 'studio-logo.svg');
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 200, height: 200 }, deviceScaleFactor: 3 });
  await page.goto(svg, { waitUntil: 'networkidle' });
  await page.screenshot({
    path: path.resolve(__dirname, '..', '..', 'public', 'email', 'studio-logo-white.png'),
    omitBackground: true,
  });
  await browser.close();
  console.log('wrote public/email/studio-logo-white.png');
})();
