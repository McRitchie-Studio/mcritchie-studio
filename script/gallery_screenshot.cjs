// Capture a live site for the /build "Built with McRitchie Studio" gallery.
//
//   node script/gallery_screenshot.cjs <url> <slug>
//   node script/gallery_screenshot.cjs https://cyvasse.mcritchie.studio cyvasse
//
// Writes app/assets/images/build_gallery/<slug>.jpg: the page's first screen at
// 1280x800, JPEG quality 72 (a card shows it ~300px wide, so this is plenty and
// stays small). Production cannot run a browser, so an agent runs this locally
// and commits the image — see the launch-build-queue SOP, "Deliver it".
const path = require("path");
const { chromium } = require("playwright");

(async () => {
  const [url, slug] = process.argv.slice(2);
  if (!url || !/^https:\/\//.test(url) || !/^[a-z0-9][a-z0-9-]*$/.test(slug || "")) {
    console.error("usage: node script/gallery_screenshot.cjs <https-url> <slug>  (slug: a-z, 0-9, hyphens)");
    process.exit(2);
  }
  const out = path.join(__dirname, "..", "app/assets/images/build_gallery", `${slug}.jpg`);
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
    const response = await page.goto(url, { waitUntil: "load", timeout: 30000 });
    if (!response || !response.ok()) throw new Error(`${url} answered ${response && response.status()}`);
    await page.waitForTimeout(1200); // let fonts, images and entrance animations settle
    await page.screenshot({ path: out, type: "jpeg", quality: 72 });
    console.log(`wrote ${path.relative(process.cwd(), out)}`);
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(`gallery_screenshot: ${e.message}`); process.exit(1); });
