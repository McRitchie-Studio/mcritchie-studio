// The Motion tab's pure helpers (task logo-motion-presets): how a kit logo's SVG splits into the parts a motion
// preset moves, and the arithmetic the presets share. No DOM and no GSAP here, so test/javascript can drive it.
//
// A kit logo (Logos::NavbarLogo / StackedLogo #svg) is <svg> [<defs>] <g icon…> <path letter>…: the first child that
// is not <defs> is the icon; each letter is a top-level <path transform="translate(x,y) scale(s)">, and a letter
// drawn at scale 90 or more is the NAME (a Navbar Logo's 150, a Stacked Logo's 120), the rest the SMALL line (the
// Stacked Logo's 40: its second line or tagline).

export const NAME_SCALE = 90;

// "name" or "small", from a letter's transform attribute.
export function partRole(transform) {
  const match = /scale\(\s*([\d.]+)/.exec(transform || "");
  return match && Number(match[1]) >= NAME_SCALE ? "name" : "small";
}

// The translate of a transform attribute, { x, y }; 0, 0 when it has none.
export function translateOf(transform) {
  const match = /translate\(\s*([-\d.eE]+)(?:[\s,]+([-\d.eE]+))?\s*\)/.exec(transform || "");
  return match ? { x: Number(match[1]), y: Number(match[2] || 0) } : { x: 0, y: 0 };
}

// A path's subpaths, each starting at an absolute moveto (the icon data writes every subpath with M).
export function subpaths(d) {
  return String(d || "").split(/(?=M)/).map((part) => part.trim()).filter(Boolean);
}

// The tone to play in: the watermark when that is all the page carries, else the hub theme's.
export function chooseTone(tones, dark) {
  if (tones.includes("watermark")) return "watermark";
  if (dark && tones.includes("dark")) return "dark";
  return tones.includes("light") ? "light" : tones[0];
}

// The logo's size inside a stage, in px: as large as fits `widthShare` of its width and `heightShare` of its height.
export function fitBox(stage, viewBox, { widthShare = 0.76, heightShare = 0.62 } = {}) {
  const aspect = viewBox.width / viewBox.height;
  const width = Math.min(stage.width * widthShare, stage.height * heightShare * aspect);
  return { width, height: width / aspect };
}

// Whether the icon sits beside the name (a Navbar Logo) or above it (a Stacked Logo), from their boxes.
export function layoutOf(icon, name) {
  if (!name) return "stacked";
  return icon.x + icon.width <= name.x + 1 ? "navbar" : "stacked";
}

// Each letter's move from where the thin layout draws it to where the kit's draws it, in the kit's viewBox units:
// the thin layout is centred in the kit's viewBox (`offset`), then each letter's translate is compared. Null when
// the two layouts do not have the same letters (the presets then fade instead of morphing).
export function letterDeltas(thin, heavy, offset) {
  if (thin.length !== heavy.length) return null;
  return thin.map((from, i) => ({ x: from.x + offset.x - heavy[i].x, y: from.y + offset.y - heavy[i].y }));
}

// The offset that centres a `from` viewBox inside a `to` one.
export function centreOffset(from, to) {
  return { x: (to.x + to.width / 2) - (from.x + from.width / 2), y: (to.y + to.height / 2) - (from.y + from.height / 2) };
}

// A hex colour mixed toward white by `amount` (0 to 1): a particle's hot core.
export function tint(hex, amount) {
  const value = String(hex).replace("#", "");
  const channels = [0, 2, 4].map((i) => parseInt(value.slice(i, i + 2), 16));
  const mixed = channels.map((channel) => Math.round(channel + (255 - channel) * amount));
  return `#${mixed.map((channel) => channel.toString(16).padStart(2, "0")).join("").toUpperCase()}`;
}

// A hex colour as rgb(r g b / a), the hub's colour form for a translucent fill.
export function withAlpha(hex, alpha) {
  const value = String(hex).replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(value.slice(i, i + 2), 16));
  return `rgb(${r} ${g} ${b} / ${alpha})`;
}

// A seeded random source (Park and Miller), so a preset draws the same shower on every replay and every brand.
export function seeded(seed = 7) {
  let state = seed;
  return (a = 0, b = 1) => {
    state = (state * 16807) % 2147483647;
    return a + (state / 2147483647) * (b - a);
  };
}

export const clamp01 = (value) => Math.max(0, Math.min(1, value));
export const lerp = (a, b, t) => a + (b - a) * t;
// How far t is through [a, b], 0 to 1.
export const segment = (t, a, b) => clamp01((t - a) / (b - a));

// The scrubber's value (0 to 1000) for a timeline's time, and back.
export const SCRUB_STEPS = 1000;
export const scrubValue = (time, duration) => (duration > 0 ? Math.round((time / duration) * SCRUB_STEPS) : 0);
export const scrubTime = (value, duration) => (Number(value) / SCRUB_STEPS) * duration;
