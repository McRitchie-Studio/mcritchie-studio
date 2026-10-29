// THE MOTION TAB'S PLAYER (task logo-motion-presets; app/views/logos/motion.html.erb). It fetches the kit's own logo
// SVG for the tone the hub theme shows, mounts it inline in the stage, splits it into parts (logo_motion_parts.js),
// and plays the chosen preset (logo_motion_presets.js) on a GSAP timeline, with Play / Pause, a scrubber, Replay
// and a speed control. GSAP and its plugins (vendor/javascript, pinned in config/importmap.rb with no preload) load
// only when a Motion tab is on the page, as classic scripts (loadGsap).
//
// Usage: <div data-logo-motion data-preset="pop_slide" data-sources='{"light": {"url": …, "thin_url": …,
//        "accent": "#…"}, …}'> with [data-motion-stage], [data-motion-still], [data-motion-toggle],
//        [data-motion-scrub], [data-motion-replay], [data-motion-clock] and [data-motion-speed] inside.
//
// Under prefers-reduced-motion the stage shows the finished logo, paused at its end, and Play runs it once. The
// still pictures (the server's <img>s) stay until the stage is mounted, so the logo shows with JavaScript off. A
// change of hub theme mounts the other tone's logo at the same point. Delegated from turbo:load and torn down on
// turbo:before-cache, so it is inert on every other page.
import { centreOffset, chooseTone, fitBox, layoutOf, letterDeltas, partRole, scrubTime, scrubValue, seeded, translateOf } from "logo_motion_parts";

const NS = "http://www.w3.org/2000/svg";
const ROOT = "[data-logo-motion]";

let gsapReady = null;

// GSAP 3.13 with MorphSVGPlugin and CustomEase. They are UMD builds, which assign window.window as they start: legal
// in a classic script, a TypeError in a module (strict mode). So each is loaded as a classic <script>, from the URL
// the page's import map gives its pin (its digested asset path, so the CSP's script-src 'self' covers it).
export function pinnedUrl(name, doc = document) {
  const map = doc.querySelector("script[type='importmap']");
  const url = map && JSON.parse(map.textContent).imports[name];
  if (!url) throw new Error(`no import map pin for ${name}`);
  return url;
}

function classicScript(url) {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[data-motion-lib][src="${url}"]`);
    if (existing && existing.dataset.loaded) { resolve(); return; }
    const script = existing || Object.assign(document.createElement("script"), { src: url, async: false });
    script.dataset.motionLib = "true";
    script.addEventListener("load", () => { script.dataset.loaded = "true"; resolve(); }, { once: true });
    script.addEventListener("error", () => reject(new Error(`${url} did not load`)), { once: true });
    if (!existing) document.head.appendChild(script);
  });
}

function loadGsap() {
  gsapReady ||= (async () => {
    if (!window.gsap) await classicScript(pinnedUrl("gsap"));
    await Promise.all([window.MorphSVGPlugin || classicScript(pinnedUrl("gsap_morph_svg")), window.CustomEase || classicScript(pinnedUrl("gsap_custom_ease"))]);
    const { gsap, MorphSVGPlugin, CustomEase } = window;
    gsap.registerPlugin(MorphSVGPlugin, CustomEase);
    CustomEase.create("house", "M0,0 C0.12,0.82 0.24,1 1,1");        // fast out, long settle
    CustomEase.create("houseIn", "M0,0 C0.7,0 0.84,0.2 1,1");        // gather before a cut
    CustomEase.create("houseInOut", "M0,0 C0.76,0 0.12,1 1,1");      // snap between two holds
    const { PRESETS } = await import("logo_motion_presets");
    return { gsap, PRESETS };
  })().catch((error) => { gsapReady = null; throw error; });
  return gsapReady;
}

const E = { out: "house", in: "houseIn", inOut: "houseInOut", back: "back.out(1.7)", soft: "power2.out" };

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const darkTheme = () => document.documentElement.classList.contains("dark");

const svgCache = new Map();
async function fetchSvg(url) {
  if (!svgCache.has(url)) {
    svgCache.set(url, fetch(url, { credentials: "same-origin" }).then((response) => {
      if (!response.ok) throw new Error(`logo ${response.status}`);
      return response.text();
    }));
  }
  return svgCache.get(url);
}

function parseSvg(text) {
  const doc = new DOMParser().parseFromString(text, "image/svg+xml");
  const svg = doc.documentElement;
  if (svg.nodeName !== "svg") throw new Error("not an SVG");
  return document.importNode(svg, true);
}

// Wraps every part in its own <g>, so a part moves without touching the logo's own transforms (the Lab's harness).
function splitParts(svg, gsap) {
  const wrap = (node) => { const g = document.createElementNS(NS, "g"); node.parentNode.insertBefore(g, node); g.appendChild(node); return g; };
  const kids = [...svg.children].filter((node) => node.tagName !== "defs");
  const iconNode = kids[0];
  const layers = [...iconNode.querySelectorAll("path")].map(wrap);
  const inner = wrap(iconNode);
  const icon = wrap(inner);
  const name = [];
  const small = [];
  kids.slice(1).forEach((node) => (partRole(node.getAttribute("transform")) === "name" ? name : small).push(wrap(node)));
  [icon, inner, ...layers, ...name, ...small].forEach((g) => gsap.set(g, { transformOrigin: "50% 50%" }));
  return { icon, inner, layers, name, small };
}

// The union box of top-level part wrappers, in the svg's own units.
function unionBox(els) {
  let x0 = Infinity; let y0 = Infinity; let x1 = -Infinity; let y1 = -Infinity;
  els.forEach((el) => { const b = el.getBBox(); x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.width); y1 = Math.max(y1, b.y + b.height); });
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
}

// Weight flick's first frame, measured: the thin logo mounted out of sight, its letters' translates and paths and its
// icon's place, against the kit logo's. The thin logo is gone before the kit logo is mounted (their ids may match).
function measureThin(text, host, gsap) {
  const svg = parseSvg(text);
  Object.assign(svg.style, { position: "absolute", visibility: "hidden", left: "0", top: "0", width: "400px", height: "auto" });
  host.appendChild(svg);
  const parts = splitParts(svg, gsap);
  const letters = [...parts.name, ...parts.small].map((g) => g.firstElementChild);
  const thin = {
    viewBox: { x: svg.viewBox.baseVal.x, y: svg.viewBox.baseVal.y, width: svg.viewBox.baseVal.width, height: svg.viewBox.baseVal.height },
    icon: unionBox([parts.icon]),
    at: letters.map((path) => translateOf(path.getAttribute("transform"))),
    d: letters.map((path) => path.getAttribute("d"))
  };
  svg.remove();
  return thin;
}

class MotionPlayer {
  constructor(root) {
    this.root = root;
    this.preset = root.dataset.preset;
    this.sources = JSON.parse(root.dataset.sources || "{}");
    this.stage = root.querySelector("[data-motion-stage]");
    this.still = root.querySelector("[data-motion-still]");
    this.toggle = root.querySelector("[data-motion-toggle]");
    this.scrub = root.querySelector("[data-motion-scrub]");
    this.replay = root.querySelector("[data-motion-replay]");
    this.clock = root.querySelector("[data-motion-clock]");
    this.speed = 1;
    this.listen();
    this.themeWatch = new MutationObserver(() => {
      if (this.tone !== this.wantedTone()) this.mount({ at: this.tl ? this.tl.time() : 0, playing: this.tl && !this.tl.paused() });
    });
    this.themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    this.mount({ at: 0, playing: !reducedMotion() });
  }

  wantedTone() { return chooseTone(Object.keys(this.sources), darkTheme()); }

  listen() {
    this.toggle?.addEventListener("click", () => {
      if (!this.tl) return;
      if (this.tl.paused()) {
        if (this.tl.progress() >= 1) this.tl.restart(); else this.tl.play();
      } else this.tl.pause();
      this.sync();
    });
    this.replay?.addEventListener("click", () => { if (this.tl) { this.tl.restart(); this.sync(); } });
    this.scrub?.addEventListener("input", () => {
      if (!this.tl) return;
      this.tl.pause();
      this.tl.seek(scrubTime(this.scrub.value, this.tl.duration()));
      this.drawAll();
      this.sync();
    });
    this.root.querySelectorAll("[data-motion-speed]").forEach((button) => button.addEventListener("click", () => {
      this.speed = Number(button.dataset.motionSpeed) || 1;
      if (this.tl) this.tl.timeScale(this.speed);
      // The chosen speed looks chosen, as the page's other controls do (btn-primary; the rest btn-neutral).
      this.root.querySelectorAll("[data-motion-speed]").forEach((other) => {
        const on = other === button;
        other.setAttribute("aria-pressed", String(on));
        other.classList.toggle("btn-primary", on);
        other.classList.toggle("border", on);
        other.classList.toggle("border-transparent", on);
        other.classList.toggle("btn-neutral", !on);
      });
    }));
  }

  // The Play / Pause label, the scrubber and the clock, from the timeline.
  sync() {
    if (!this.tl) return;
    const playing = !this.tl.paused() && this.tl.progress() < 1;
    if (this.toggle) {
      this.toggle.textContent = playing ? "Pause" : "Play";
      this.toggle.setAttribute("aria-pressed", String(playing));
    }
    if (this.scrub) this.scrub.value = scrubValue(this.tl.time(), this.tl.duration());
    if (this.clock) this.clock.textContent = `${this.tl.time().toFixed(2)}s`;
    this.root.dataset.motionState = playing ? "playing" : (this.tl.progress() >= 1 ? "done" : "paused");
  }

  drawAll() { (this.drawers || []).forEach((fn) => fn(this.tl.time())); }

  teardown() {
    if (this.tl) this.tl.kill();
    this.tl = null;
    this.drawers = [];
    if (this.stage) this.stage.replaceChildren();
  }

  destroy() {
    this.themeWatch.disconnect();
    this.teardown();
    if (this.stage) this.stage.hidden = true;
    if (this.still) this.still.hidden = false;
    delete this.root.dataset.motionState;
  }

  async mount({ at, playing }) {
    const token = (this.token = {});
    let gsap;
    let PRESETS;
    try {
      ({ gsap, PRESETS } = await loadGsap());
    } catch (error) {
      this.fail(`The motion library did not load (${error.message}).`);
      return;
    }
    const tone = this.wantedTone();
    const source = this.sources[tone];
    const build = PRESETS[this.preset];
    if (!source || !build) { this.fail("This preset cannot play here."); return; }
    let text;
    let thinText;
    try {
      [text, thinText] = await Promise.all([fetchSvg(source.url), source.thin_url ? fetchSvg(source.thin_url) : null]);
    } catch (error) {
      this.fail(`The logo did not load (${error.message}).`);
      return;
    }
    if (token !== this.token) return;   // a newer mount started while this one waited

    this.teardown();
    this.tone = tone;
    this.stage.hidden = false;
    const box = this.stage.getBoundingClientRect();
    const thin = thinText ? measureThin(thinText, this.stage, gsap) : null;

    const bg = document.createElement("div");
    Object.assign(bg.style, { position: "absolute", inset: "0", borderRadius: "inherit" });
    const holder = document.createElement("div");
    Object.assign(holder.style, { position: "absolute", inset: "0", display: "grid", placeItems: "center" });
    this.stage.append(bg, holder);
    const svg = parseSvg(text);
    svg.removeAttribute("width");
    svg.removeAttribute("height");
    const fit = fitBox({ width: box.width, height: box.height }, svg.viewBox.baseVal);
    Object.assign(svg.style, { width: `${fit.width}px`, height: `${fit.height}px`, overflow: "visible", display: "block" });
    svg.setAttribute("data-test", "motion-svg");
    svg.setAttribute("aria-hidden", "true");
    holder.appendChild(svg);
    if (this.still) this.still.hidden = true;

    const parts = splitParts(svg, gsap);
    const stage = this.stage;
    const rect = (el) => {
      const a = el.getBoundingClientRect(); const s = stage.getBoundingClientRect();
      return { x: a.left - s.left, y: a.top - s.top, w: a.width, h: a.height, cx: a.left - s.left + a.width / 2, cy: a.top - s.top + a.height / 2, W: s.width, H: s.height };
    };
    const svgRect = rect(svg);
    const vb = svg.viewBox.baseVal;
    const k = vb.width / svgRect.w;   // svg units per stage px
    const tl = gsap.timeline({ paused: true, onUpdate: () => { this.drawAll(); this.sync(); }, onComplete: () => this.sync() });
    this.tl = tl;
    this.drawers = [];
    const rnd = seeded(7);
    const ctx = {
      gsap, E, stage, svg, bg, parts, rect, rnd, k,
      accent: source.accent,
      dark: tone !== "light",
      layout: layoutOf(unionBox([parts.icon]), parts.name.length ? unionBox(parts.name) : null),
      box: unionBox,
      toRoot: (point) => ({ x: (point.x - svgRect.x) * k + vb.x, y: (point.y - svgRect.y) * k + vb.y }),
      fx: (css = {}) => { const d = document.createElement("div"); d.style.position = "absolute"; d.style.pointerEvents = "none"; Object.assign(d.style, css); stage.appendChild(d); return d; },
      canvas: () => {
        const c = document.createElement("canvas");
        const dpr = window.devicePixelRatio || 1;
        Object.assign(c.style, { position: "absolute", inset: "0", width: "100%", height: "100%", pointerEvents: "none" });
        c.width = Math.round(box.width * dpr); c.height = Math.round(box.height * dpr);
        stage.appendChild(c);
        const g = c.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0);
        return { g, w: box.width, h: box.height };
      },
      draw: (fn) => this.drawers.push(fn),
      svgEl: (tag, attrs = {}, parent = svg) => { const el = document.createElementNS(NS, tag); Object.entries(attrs).forEach(([key, value]) => el.setAttribute(key, value)); parent.appendChild(el); return el; },
      thin: null
    };
    if (thin) {
      const heavy = [...parts.name, ...parts.small].map((g) => translateOf(g.firstElementChild.getAttribute("transform")));
      const offset = centreOffset(thin.viewBox, { x: vb.x, y: vb.y, width: vb.width, height: vb.height });
      const icon = unionBox([parts.icon]);
      ctx.thin = { d: thin.d, deltas: letterDeltas(thin.at, heavy, offset), icon: { x: thin.icon.x + offset.x - icon.x, y: thin.icon.y + offset.y - icon.y } };
    }
    try {
      build(ctx, tl);
    } catch (error) {
      this.fail(`This preset could not be built for this logo (${error.message}).`);
      return;
    }
    tl.timeScale(this.speed);
    this.root.dataset.motionReady = "true";
    this.root.dataset.motionTone = tone;
    tl.seek(Math.min(at || 0, tl.duration()));
    if (reducedMotion() && !at) tl.progress(1);   // the finished logo; Play runs it from the start
    this.drawAll();
    if (playing) tl.play();
    this.sync();
  }

  fail(message) {
    this.teardown();
    if (this.stage) this.stage.hidden = true;
    if (this.still) this.still.hidden = false;
    const note = this.root.querySelector("[data-motion-error]");
    if (note) { note.textContent = message; note.hidden = false; }
    this.root.dataset.motionReady = "failed";
  }
}

const players = new Set();

function start() {
  document.querySelectorAll(ROOT).forEach((root) => {
    if (root.motionPlayer) return;
    root.motionPlayer = new MotionPlayer(root);
    players.add(root.motionPlayer);
  });
}

function stop() {
  players.forEach((player) => { player.destroy(); delete player.root.motionPlayer; });
  players.clear();
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:load", start);
  document.addEventListener("turbo:before-cache", stop);
  if (document.readyState !== "loading") start(); else document.addEventListener("DOMContentLoaded", start);
}
