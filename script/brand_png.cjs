// Rasterize a kit SVG to a square PNG: the favicon and app icon an app draws
// from its kit (task studio-adopts-its-kit). The SVG comes from public/brand/,
// written by `bin/rails logos:install BRAND=<brand>`; never draw from a copy.
//
//   node script/brand_png.cjs <svg> <out.png> <size> [background]
//
//   node script/brand_png.cjs public/brand/icon-dark.svg public/favicon.png 256
//   node script/brand_png.cjs public/brand/icon-dark.svg public/icon.png 512 '#1A1535'
//
// The artwork is centred and contained in the square with NO margin: the kit
// icon's box is its ink (Logos::IconInk, task stacked-rule-of-three), so the
// ink touches two opposite edges and this script has no padding of its own
// to tune. With no background the PNG is
// transparent; with one (a CSS colour) it is opaque, as an app icon must be.
// Chromium draws it, the engine a browser shows the SVG with (vips is absent
// here), so an agent runs this locally and commits the PNG.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

(async () => {
  const [svgPath, out, sizeArg, background] = process.argv.slice(2);
  const size = Number(sizeArg);
  if (!svgPath || !out || !Number.isInteger(size) || size < 16 || size > 2048) {
    console.error("usage: node script/brand_png.cjs <svg> <out.png> <size 16-2048> [background]");
    process.exit(2);
  }
  const svg = fs.readFileSync(svgPath, "utf8");
  if (!/^<svg[\s>]/.test(svg.trimStart())) throw new Error(`${svgPath} is not an SVG`);

  const html = `<!doctype html><html><body style="margin:0;background:${background || "transparent"}">
    <img id="art" src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}"
         style="display:block;width:${size}px;height:${size}px;object-fit:contain">
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
