// Colour helpers shared by the board effects (board/live_fx_dom, board/release_fx_dom).
// Pure: no DOM access. paintableColor takes the canvas context it paints on, so a
// test can hand it a stand-in and the page hands it a real 1x1 canvas.

// "#78C850" -> "120 200 80" (for `rgb(var() / a)`); null if unparseable.
export function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return ((n >> 16) & 255) + " " + ((n >> 8) & 255) + " " + (n & 255);
}

// Is this computed colour actually paintable, whatever colour space it arrived in?
// PAINT it on a 1x1 canvas and read the alpha out of the pixel. That is the only
// question the meter ring cares about, and the pixel answers it directly.
//
// Do NOT go back to matching the serialized string, in any spelling. Canvas fillStyle
// does NOT normalize to "#rrggbb" / "rgba(r, g, b, a)": Chromium serializes a colour
// back in the space it was authored in, so `oklch(0.7 0.15 160 / 0)` stays spelled
// `oklch(...)` and every rgba()-shaped test misses it. The e2e pair in
// deployments_live.spec.js drives a real oklch tone through this function and reads
// the ring's colour knob.
//
// Every computed background-colour Chromium/WebKit/Firefox emits today is parseable
// by their canvas fillStyle (rgba/hsl/hwb/lab/lch/oklab/oklch/color()/color-mix/
// relative colour). If a future colour space outruns the canvas parser, fillStyle
// stays on the opaque sentinel and this returns the value, so the knob may take a
// transparent colour and the ring goes invisible. Re-measure before trusting a new
// colour space.
export function paintableColor(value, ctx) {
  if (!value) return null;
  ctx.fillStyle = "#000000";
  ctx.fillStyle = value;
  ctx.clearRect(0, 0, 1, 1);
  ctx.fillRect(0, 0, 1, 1);
  return ctx.getImageData(0, 0, 1, 1).data[3] === 0 ? null : value;
}
