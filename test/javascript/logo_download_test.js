// [unit] logo_download: the brand page's Download card (task logo-download-card). The custom PNG size keeps the
// drawing's aspect and rounds the other side as Logos::PngSizes does (halves up, never below 1); an icon preset fits
// the icon inside its square; the PNG is named after the SVG; the SVG is sized before it is drawn; and the rasteriser
// fetches, sizes, draws and encodes in that order.
import { test } from "node:test";
import assert from "node:assert/strict";

import { MAX_SIDE, pngSize, drawRect, pngFilename, sizedSvg, rasterise } from "../../app/javascript/logo_download.js";

const NAVBAR = [2560.42, 300.0];

test("a custom width keeps the aspect, the height rounded as the server rounds it", () => {
  assert.deepEqual(pngSize("width", 1000, ...NAVBAR), { width: 1000, height: 117 });
  assert.deepEqual(pngSize("width", "800", ...NAVBAR), { width: 800, height: 94 }, "the w800 preset's size");
  assert.deepEqual(pngSize("height", 500, ...NAVBAR), { width: 4267, height: 500 });
  assert.deepEqual(pngSize("width", 3, 2, 1), { width: 3, height: 2 }, "1.5 rounds up");
  assert.deepEqual(pngSize("width", 1, ...NAVBAR), { width: 1, height: 1 }, "never below one pixel");
});

test("a custom side out of range, not whole, or pushing the other past the limit is refused", () => {
  for (const bad of [0, -1, 12.5, "", "abc", MAX_SIDE + 1]) assert.equal(pngSize("width", bad, ...NAVBAR), null, String(bad));
  assert.equal(pngSize("height", 1200, ...NAVBAR), null, "10242 wide is past 8192");
});

test("an icon preset fits the icon inside its square, centred; a wide preset fills its canvas", () => {
  const rect = drawRect("contain", 512, 512, 662.45, 538.14);
  assert.equal(rect.width, 512);
  assert.ok(Math.abs(rect.height - (512 * 538.14) / 662.45) < 1e-9);
  assert.equal(rect.x, 0);
  assert.ok(Math.abs(rect.y - (512 - rect.height) / 2) < 1e-9);
  assert.deepEqual(drawRect("fill", 800, 94, ...NAVBAR), { x: 0, y: 0, width: 800, height: 94 });
});

test("the PNG is named after the SVG with its size", () => {
  assert.equal(pngFilename("studio-icon-light.svg", 512, 512), "studio-icon-light-512x512.png");
  assert.equal(pngFilename("turf-navbar-rule4-second-dark-custom.svg", 800, 94), "turf-navbar-rule4-second-dark-custom-800x94.png");
});

test("the SVG's root is sized to the drawing, and only its root", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 5" width="10" height="5"><svg width="1" height="1"/></svg>';
  assert.equal(sizedSvg(svg, 800, 400), '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 5" width="800" height="400"><svg width="1" height="1"/></svg>');
  assert.equal(sizedSvg('<svg viewBox="0 0 10 5"><g/></svg>', 20, 10), '<svg height="10" width="20" viewBox="0 0 10 5"><g/></svg>');
});

function fakeDeps(svgText, { ok = true, type = "image/svg+xml" } = {}) {
  const log = [];
  const blobs = [];
  const context = {
    set fillStyle(value) { log.push(["fillStyle", value]); },
    fillRect: (...args) => log.push(["fillRect", ...args]),
    drawImage: (image, ...args) => log.push(["drawImage", image.src, ...args]),
  };
  return {
    log,
    blobs,
    fetchFn: async (url) => { log.push(["fetch", url]); return { ok, status: ok ? 200 : 404, headers: { get: () => type }, text: async () => svgText }; },
    URL: { createObjectURL: (blob) => { blobs.push(blob); log.push(["createObjectURL"]); return "blob:svg"; }, revokeObjectURL: (url) => log.push(["revoke", url]) },
    createImage: () => ({ src: null, decode: async () => log.push(["decode"]) }),
    createCanvas: (width, height) => { log.push(["canvas", width, height]); return { getContext: () => context, toBlob: (cb, type) => { log.push(["toBlob", type]); cb({ type }); } }; },
  };
}

test("rasterise draws the sized SVG onto a canvas of exactly the asked pixels, on its background", async () => {
  const deps = fakeDeps('<svg viewBox="0 0 2 1" width="2" height="1"></svg>');
  const blob = await rasterise("/logos/studio/navbar?tone=light", { size: { width: 800, height: 400, fit: "fill" }, naturalWidth: 2, naturalHeight: 1, background: "#FFFFFF" }, deps);
  assert.deepEqual(blob, { type: "image/png" });
  assert.deepEqual(deps.log, [
    ["fetch", "/logos/studio/navbar?tone=light"], ["createObjectURL"], ["decode"], ["canvas", 800, 400],
    ["fillStyle", "#FFFFFF"], ["fillRect", 0, 0, 800, 400], ["drawImage", "blob:svg", 0, 0, 800, 400], ["toBlob", "image/png"], ["revoke", "blob:svg"],
  ]);
  assert.match(await deps.blobs[0].text(), /width="800" height="400"/);
});

test("rasterise leaves a transparent PNG unpainted, and refuses an answer that is not an SVG", async () => {
  const deps = fakeDeps('<svg viewBox="0 0 1 1"></svg>');
  await rasterise("/x", { size: { width: 16, height: 16, fit: "contain" }, naturalWidth: 1, naturalHeight: 1, background: null }, deps);
  assert.ok(!deps.log.some(([step]) => step === "fillRect"));
  await assert.rejects(rasterise("/x", { size: { width: 16, height: 16, fit: "fill" }, naturalWidth: 1, naturalHeight: 1 }, fakeDeps("<html>", { type: "text/html" })), /no SVG/);
});
