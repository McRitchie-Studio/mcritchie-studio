// Rasterize a kit SVG to a square PNG: the favicon and app icon an app draws
// from its kit (task studio-adopts-its-kit). The SVG comes from public/brand/,
// written by `bin/rails logos:install BRAND=<brand>`; never draw from a copy.
//
//   node script/brand_png.cjs <svg> <out.png> <size> [background] [padding]
//
//   node script/brand_png.cjs public/brand/icon-dark.svg public/favicon.png 256
//   node script/brand_png.cjs public/brand/icon-dark.svg public/icon.png 512 '#1A1535' 0.16
//
// The artwork is centred and contained in the square, `padding` (a fraction of
// the side, default 0.04) clear on every edge. With no background the PNG is
// transparent; with one (a CSS colour) it is opaque, as an app icon must be.
// Chromium draws it, the engine a browser shows the SVG with (vips is absent
// here), so an agent runs this locally and commits the PNG.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

(async () => {
  const [svgPath, out, sizeArg, background, paddingArg] = process.argv.slice(2);
  const size = Number(sizeArg);
  const padding = paddingArg === undefined ? 0.04 : Number(paddingArg);
  if (!svgPath || !out || !Number.isInteger(size) || size < 16 || size > 2048 || !(padding >= 0 && padding < 0.5)) {
    console.error("usage: node script/brand_png.cjs <svg> <out.png> <size 16-2048> [background] [padding 0-0.5]");
    process.exit(2);
  }
  const svg = fs.readFileSync(svgPath, "utf8");
  if (!/^<svg[\s>]/.test(svg.trimStart())) throw new Error(`${svgPath} is not an SVG`);

  const inset = Math.round(size * padding);
  const html = `<!doctype html><html><body style="margin:0;background:${background || "transparent"}">
    <img id="art" src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}"
         style="display:block;box-sizing:border-box;width:${size}px;height:${size}px;padding:${inset}px;object-fit:contain">
  </body></html>`;

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
    await page.setContent(html);
    await page.waitForFunction(() => document.getElementById("art").complete);
    await page.screenshot({ path: out, type: "png", omitBackground: !background });
    console.log(`wrote ${path.relative(process.cwd(), path.resolve(out))} (${size}x${size}${background ? `, on ${background}` : ", transparent"})`);
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
