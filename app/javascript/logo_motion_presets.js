// THE MOTION PRESETS (task logo-motion-presets; epic logo-motion, phase 1): the eight motions Alex McRitchie picked on
// Logo Motion Lab II, ported from the Lab's one-brand sketches (.agents/epics/logo-motion-ideas/mock-2/films) to play
// on ANY brand's kit logo. Nothing here names a brand: every position is measured from the mounted SVG at runtime.
// Logos::MotionPreset (lib/logos/motion_preset.rb) is the list the page offers; each key there is a builder here.
//
// A builder is build(ctx, tl): it adds tweens to the GSAP timeline `tl` (which starts at 0); everything is timeline
// driven, so the scrubber can step through it. ctx (app/javascript/logo_motion.js) carries:
//   gsap, E (the house eases), stage (the stage div), svg, bg (the stage's ground div), parts { icon, inner, layers,
//   name, small } (the SVG's parts, each wrapped in its own <g>), layout ("navbar" or "stacked"), accent (the brand's
//   accent hex), dark (true on a dark ground), rect(el) (a box in stage px), box(els) (a union box in the svg's own
//   units), toRoot({x,y}) (stage px to svg units), fx(css) (an absolutely placed div), canvas() ({ g, w, h }),
//   draw(fn) (a canvas redraw driven by tl's time), svgEl(tag, attrs, parent), rnd(a, b) (seeded), thin (Weight flick).
//
// The house rules (the Lab's): each step ends on the shape the next begins with; one ease family (E.out to arrive,
// E.in to gather before a cut, E.inOut between holds, E.back for a small pop); colour changes are hard sets; only a
// dot scales up from nothing.
import { clamp01, lerp, segment, subpaths, tint, withAlpha } from "logo_motion_parts";

const HOLD = 1.2;   // every preset ends holding the finished logo this long

// A clip group in the svg's own units: the clip stays put while `inner` moves. Returns { outer, inner, rect }.
function clipGroup(ctx, nodes, box) {
  const id = `motion-clip-${Math.round(ctx.rnd(0, 1e9))}`;
  const defs = ctx.svgEl("defs");
  const clip = ctx.svgEl("clipPath", { id, clipPathUnits: "userSpaceOnUse" }, defs);
  const rect = ctx.svgEl("rect", box, clip);
  const outer = ctx.svgEl("g", { "clip-path": `url(#${id})` });
  const inner = ctx.svgEl("g", {}, outer);
  nodes.forEach((node) => inner.appendChild(node));
  return { outer, inner, rect };
}

// The icon's focal point in stage px: its last layer where it has more than one (a spark, a highlight), else its centre.
function focalOf(ctx) {
  const { layers, icon } = ctx.parts;
  const r = ctx.rect(layers.length > 1 ? layers[layers.length - 1] : icon);
  return { x: r.cx, y: r.cy };
}

// The last icon layer, popped in on the beat (a spark, a highlight), or null for a one-layer icon.
const popLayer = (ctx) => (ctx.parts.layers.length > 1 ? ctx.parts.layers[ctx.parts.layers.length - 1] : null);

// The name rising into place, then the small line, from `at`.
function riseWords(ctx, tl, at, { rise = 0.05, stagger = 0.025 } = {}) {
  const { parts: p, E } = ctx;
  const vb = ctx.svg.viewBox.baseVal;
  if (p.name.length) tl.fromTo(p.name, { autoAlpha: 0, y: vb.height * rise }, { autoAlpha: 1, y: 0, duration: 0.6, ease: E.out, stagger }, at);
  if (p.small.length) tl.fromTo(p.small, { autoAlpha: 0, y: vb.height * rise * 0.5 }, { autoAlpha: 1, y: 0, duration: 0.5, ease: E.out, stagger: 0.008 }, at + 0.4);
}

// Each small-line letter's start, pushed away from (k > 0) or toward (k < 0) the line's centre: its letter spacing.
function spread(ctx, letters, k) {
  if (!letters.length) return [];
  const all = ctx.box(letters);
  return letters.map((letter) => { const b = ctx.box([letter]); return (b.cx - all.cx) * k; });
}

// I1 POP AND SLIDE: a dot opens into the icon through a circle mask at the centre of the frame; the icon slides home
// and the name emerges from its edge (a Navbar Logo's right edge, a Stacked Logo's bottom).
function popSlide(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const vb = ctx.svg.viewBox.baseVal;
  const icon = ctx.box([p.icon]);
  const words = [...p.name, ...p.small];
  const across = ctx.layout === "navbar";
  const off = across ? { x: vb.x + vb.width / 2 - icon.cx, y: 0 } : { x: 0, y: vb.y + vb.height / 2 - icon.cy };
  const reach = Math.hypot(icon.width, icon.height) / 2 + 4;
  const dotR = Math.max(icon.width, icon.height) * 0.06;

  const id = `motion-mask-${Math.round(ctx.rnd(0, 1e9))}`;
  const clip = ctx.svgEl("clipPath", { id, clipPathUnits: "userSpaceOnUse" }, ctx.svgEl("defs"));
  const mask = ctx.svgEl("circle", { cx: icon.cx, cy: icon.cy, r: 0 }, clip);
  p.inner.setAttribute("clip-path", `url(#${id})`);
  const dot = ctx.svgEl("circle", { cx: icon.cx, cy: icon.cy, r: dotR, fill: ctx.accent }, p.icon);
  gsap.set(dot, { transformOrigin: "50% 50%" });

  // The words wait behind the icon's edge, clipped there, and come out of it as the icon slides home.
  const words_ = words.length ? ctx.box(words) : null;
  let name = null;
  if (words_) {
    const pad = vb.width + vb.height;
    const edge = across ? icon.x + icon.width : icon.y + icon.height;
    const box = across ? { x: edge, y: vb.y - pad, width: pad * 2, height: pad * 2 } : { x: vb.x - pad, y: edge, width: pad * 2, height: pad * 2 };
    name = clipGroup(ctx, words, box);
    const hidden = across ? -(words_.x + words_.width - edge) : -(words_.y + words_.height - edge);
    const axis = across ? "x" : "y";
    tl.fromTo(name.inner, { [axis]: hidden }, { [axis]: hidden, duration: 0.01 }, 0)
      .fromTo(name.rect, { attr: { [axis]: edge + off[axis] } }, { attr: { [axis]: edge + off[axis] }, duration: 0.01 }, 0)
      .to(name.inner, { [axis]: 0, duration: 0.85, ease: E.inOut }, 1.3)
      .to(name.rect, { attr: { [axis]: edge }, duration: 0.85, ease: E.inOut }, 1.3);
    ctx.svg.appendChild(p.icon);   // the icon paints over the words' clip edge
  }
  tl.fromTo(p.icon, { x: off.x, y: off.y }, { x: off.x, y: off.y, duration: 0.01 }, 0)
    .fromTo(dot, { scale: 0, autoAlpha: 1 }, { scale: 1, duration: 0.3, ease: E.out }, 0.1)
    .fromTo(mask, { attr: { r: dotR } }, { attr: { r: reach }, duration: 0.6, ease: E.out }, 0.45)
    .fromTo(p.icon, { scale: 0.9 }, { scale: 1, duration: 0.6, ease: E.out }, 0.45)
    .to(dot, { autoAlpha: 0, duration: 0.25, ease: E.out }, 0.55)
    .to(p.icon, { x: 0, y: 0, duration: 0.85, ease: E.inOut }, 1.3)
    .to({}, { duration: HOLD });
}

// I2 STACK BUILD: the icon drops in, the name rises letter by letter out of its baseline, and the small line tracks out
// to its true spacing.
function stackBuild(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const vb = ctx.svg.viewBox.baseVal;
  gsap.set([p.icon, ...p.name, ...p.small], { autoAlpha: 0 });
  const drop = vb.height * (ctx.layout === "navbar" ? 0.3 : 0.1);
  tl.fromTo(p.icon, { autoAlpha: 0, y: -drop }, { autoAlpha: 1, y: 0, duration: 0.6, ease: E.out }, 0.1);
  if (p.name.length) {
    const name = ctx.box(p.name);
    const pad = vb.width;
    clipGroup(ctx, p.name, { x: vb.x - pad, y: name.y - pad, width: vb.width + pad * 2, height: name.height + pad + 2 });   // the floor at the baseline
    tl.fromTo(p.name, { autoAlpha: 1, y: name.height + 10 }, { y: 0, duration: 0.55, ease: E.out, stagger: 0.04 }, 0.5);
  }
  if (p.small.length) {
    const from = spread(ctx, p.small, -0.35);
    tl.fromTo(p.small, { autoAlpha: 0, x: (i) => from[i] }, { autoAlpha: 1, x: 0, duration: 0.9, ease: E.out }, 0.95);
  }
  tl.to({}, { duration: HOLD });
}

// I16 MATCH-CUT BUILD: a dot stretches into a line across the frame, flares into light (the ground cuts to the accent
// under it), the light narrows to the icon's seam, the icon opens from it, its last layer pops in, the name follows.
function matchCut(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const icon = ctx.rect(p.icon);
  const spark = popLayer(ctx);
  const glow = withAlpha(ctx.accent, 0.7);
  const dot = ctx.fx({ width: "12px", height: "12px", borderRadius: "50%", background: ctx.accent, left: `${icon.cx - 6}px`, top: `${icon.cy - 6}px`,
                       boxShadow: `0 0 18px 4px ${glow}` });
  const flash = ctx.fx({ inset: "0", background: tint(ctx.accent, 0.85), opacity: 0 });
  gsap.set([p.inner, ...p.name, ...p.small], { autoAlpha: 0 });
  if (spark) gsap.set(spark, { autoAlpha: 0 });
  tl.set(ctx.bg, { background: "transparent" }, 0)
    .fromTo(dot, { scale: 0 }, { scale: 1, duration: 0.35, ease: E.out }, 0.1)
    // match: dot -> line
    .to(dot, { width: icon.W * 1.1, left: -icon.W * 0.05, height: 3, top: icon.cy - 1.5, borderRadius: 2, duration: 0.45, ease: E.inOut }, 0.5)
    // match: line -> light, and the ground cuts to the accent under it
    .to(flash, { opacity: 1, duration: 0.12, ease: E.in }, 0.95)
    .set(ctx.bg, { background: ctx.accent }, 1.07)
    .set(dot, { width: 3, height: icon.h, left: icon.cx - 1.5, top: icon.y, background: "#FFFFFF", boxShadow: "0 0 14px 2px rgb(255 255 255 / 0.8)" }, 1.07)
    .to(flash, { opacity: 0, duration: 0.35, ease: E.out }, 1.07)
    // match: light -> seam; the ground cuts back as the icon opens
    .set(ctx.bg, { background: "transparent" }, 1.5)
    .set(p.inner, { autoAlpha: 1 }, 1.5)
    .fromTo(p.inner, { scaleX: 0.02 }, { scaleX: 1, duration: 0.6, ease: E.out }, 1.5)
    .to(dot, { autoAlpha: 0, duration: 0.2 }, 1.55);
  if (spark) tl.fromTo(spark, { autoAlpha: 0, scale: 0.4, rotation: -30 }, { autoAlpha: 1, scale: 1, rotation: 0, duration: 0.55, ease: E.back }, 1.95);
  riseWords(ctx, tl, 2.15);
  tl.to({}, { duration: HOLD });
}

// I22 SHAPE MORPH: a plain circle morphs into the icon's first layer; the swap to the real layer is invisible (same
// shape), the other layers open from it, the last pops in, and the name rises.
function shapeMorph(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const [first, ...rest] = p.layers;
  const spark = popLayer(ctx);
  const opening = rest.filter((layer) => layer !== spark);
  const src = first.querySelector("path");
  const clone = src.cloneNode(false);
  src.parentNode.insertBefore(clone, src);
  const target = src.getAttribute("d");
  const b = src.getBBox();
  const cx = b.x + b.width / 2;
  const cy = b.y + b.height / 2;
  const r = Math.max(b.width, b.height) * 0.46;
  const k = 0.5523 * r;
  const circle = `M${cx},${cy - r}C${cx + k},${cy - r} ${cx + r},${cy - k} ${cx + r},${cy}C${cx + r},${cy + k} ${cx + k},${cy + r} ${cx},${cy + r}` +
                 `C${cx - k},${cy + r} ${cx - r},${cy + k} ${cx - r},${cy}C${cx - r},${cy - k} ${cx - k},${cy - r} ${cx},${cy - r}Z`;
  gsap.set(clone, { transformOrigin: "50% 50%" });
  gsap.set([src, ...rest, ...p.name, ...p.small], { autoAlpha: 0 });
  tl.set(src, { autoAlpha: 0 }, 0)
    .set(clone, { autoAlpha: 1, attr: { d: circle } }, 0)
    .fromTo(clone, { scale: 0.6, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.45, ease: E.out }, 0.1)
    .to(clone, { morphSVG: { shape: target, shapeIndex: "auto" }, duration: 0.85, ease: E.inOut }, 0.75)
    .set(src, { autoAlpha: 1 }, 1.6)
    .set(clone, { autoAlpha: 0 }, 1.6);
  if (opening.length) {
    tl.set(opening, { autoAlpha: 0 }, 0)
      .set(opening, { autoAlpha: 1 }, 1.6)
      .fromTo(opening, { scaleX: 0.02 }, { scaleX: 1, duration: 0.5, ease: E.out, immediateRender: false }, 1.6);
  }
  if (spark) tl.fromTo(spark, { autoAlpha: 0, scale: 0.4, rotation: -30 }, { autoAlpha: 1, scale: 1, rotation: 0, duration: 0.5, ease: E.back }, 1.95);
  riseWords(ctx, tl, 2.15);
  tl.to({}, { duration: HOLD });
}

// I23 TRACKING BREATH: the name draws in from a very wide spread to its true spacing while the small line spreads
// out from tight; the icon fades in last with a 6 px rise.
function trackingBreath(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const wide = spread(ctx, p.name, 1.1);
  const tight = spread(ctx, p.small, -0.6);
  const rise = 6 * ctx.k;
  gsap.set([p.icon, ...p.name, ...p.small], { autoAlpha: 0 });
  if (p.name.length) {
    tl.fromTo(p.name, { autoAlpha: 0.15, x: (i) => wide[i] }, { x: 0, duration: 2.0, ease: E.out }, 0.1)
      .to(p.name, { autoAlpha: 1, duration: 1.2, ease: E.out }, 0.1);
  }
  if (p.small.length) tl.fromTo(p.small, { autoAlpha: 0, x: (i) => tight[i] }, { autoAlpha: 1, x: 0, duration: 1.6, ease: E.out }, 0.6);
  tl.fromTo(p.icon, { autoAlpha: 0, y: rise }, { autoAlpha: 1, y: 0, duration: 1.0, ease: E.out }, 1.6)
    .to({}, { duration: HOLD });
}

// I18 DOTS TO MARK: an accent circle splits into six dots that orbit and drift, merge back into one, and that dot flies
// to the icon's focal point; the icon opens around it and its last layer takes over from the dot.
function dotsToMark(ctx, tl) {
  const { parts: p, E, gsap } = ctx;
  const icon = ctx.rect(p.icon);
  const W = icon.W;
  const H = icon.H;
  const S = Math.min(W, H);
  const spark = popLayer(ctx);
  const C0 = { x: W * 0.5, y: H * 0.5 };
  const C1 = { x: lerp(C0.x, icon.x, 0.4), y: lerp(C0.y, icon.y + icon.h, 0.4) };
  const L = focalOf(ctx);
  const { g } = ctx.canvas();
  const eo = gsap.parseEase(E.out);
  const ei = gsap.parseEase(E.in);
  const eio = gsap.parseEase(E.inOut);
  const T = { pop: 0.1, gather: 0.55, split: 0.72, merge: 1.4, one: 1.75, land: 2.2, gone: 2.45 };
  const N = 6;
  const Rmax = S * 0.15;
  const big = S * 0.045;
  const dotR = S * 0.016;
  const oneR = S * 0.02;
  const dot = (x, y, r, a = 1) => { if (r <= 0 || a <= 0) return; g.globalAlpha = a; g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill(); };
  ctx.draw((t) => {
    g.clearRect(0, 0, W, H);
    g.fillStyle = ctx.accent;
    g.shadowColor = withAlpha(ctx.accent, 0.75);
    g.shadowBlur = S * 0.045;
    if (t < T.split) {   // one soft circle: pops in, holds, gathers before the split
      const r = t < T.gather ? big * eo(segment(t, T.pop, T.pop + 0.4)) : lerp(big, big * 0.7, ei(segment(t, T.gather, T.split)));
      if (t >= T.pop) dot(C0.x, C0.y, r);
    } else if (t < T.one) {   // six dots orbit, drift, and merge back
      const out = eo(segment(t, T.split, T.split + 0.5));
      const back = ei(segment(t, T.merge, T.one));
      const move = eio(segment(t, T.split, T.one));
      const c = { x: lerp(C0.x, C1.x, move), y: lerp(C0.y, C1.y, move) };
      const rad = Rmax * out * (1 - back);
      const ang = 3.4 * (t - T.split);
      for (let i = 0; i < N; i++) {
        const a = ang + (i * Math.PI * 2) / N;
        const w = 1 + 0.2 * Math.sin(2.6 * t + i * 1.7);
        dot(c.x + Math.cos(a) * rad * w, c.y + Math.sin(a) * rad * w, lerp(dotR, oneR, back));
      }
    } else {   // one dot flies to the focal point on an arc, then hands over
      const u = eio(segment(t, T.one, T.land));
      const q = { x: C1.x, y: L.y };
      const x = (1 - u) * (1 - u) * C1.x + 2 * (1 - u) * u * q.x + u * u * L.x;
      const y = (1 - u) * (1 - u) * C1.y + 2 * (1 - u) * u * q.y + u * u * L.y;
      const fade = segment(t, T.land, T.gone);
      dot(x, y, oneR * (1 + 0.5 * eo(fade)), 1 - fade);
    }
    g.globalAlpha = 1;
  });
  const opening = p.layers.filter((layer) => layer !== spark);
  gsap.set([...p.layers, ...p.name, ...p.small], { autoAlpha: 0 });
  gsap.set(p.inner, { transformOrigin: "50% 50%" });
  tl.to({}, { duration: T.land }, 0)
    .set(opening, { autoAlpha: 1 }, T.land - 0.05)
    .fromTo(p.inner, { scaleX: 0.02 }, { scaleX: 1, duration: 0.6, ease: E.out }, T.land - 0.05);
  if (spark) tl.fromTo(spark, { autoAlpha: 0, scale: 0.4, rotation: -30 }, { autoAlpha: 1, scale: 1, rotation: 0, duration: 0.5, ease: E.back }, T.land);
  riseWords(ctx, tl, T.land + 0.3);
  tl.to({}, { duration: HOLD });
}

// I8 PARTICLE RESOLVE (the welding "Spark resolve", in any brand's accent): a shower of particles sweeps in from the
// upper left and settles on the icon's outline, left side first; the icon wipes in behind them, and the last particle
// lands on the icon's focal point, which pops in with a flash.
function particleResolve(ctx, tl) {
  const { parts: p, E, gsap, rnd } = ctx;
  const vb = ctx.svg.viewBox.baseVal;
  const outlineOf = p.layers[0].querySelector("path");
  const outline = ctx.svgEl("path", { d: subpaths(outlineOf.getAttribute("d"))[0], fill: "none", stroke: "none" }, outlineOf.parentNode);
  if (outlineOf.getAttribute("transform")) outline.setAttribute("transform", outlineOf.getAttribute("transform"));
  const total = outline.getTotalLength();
  const stageBox = ctx.stage.getBoundingClientRect();
  const points = [];
  const n = 400;
  const m = outline.getScreenCTM();
  for (let i = 0; i <= n; i++) {
    const q = outline.getPointAtLength((i / n) * total);
    points.push({ x: m.a * q.x + m.c * q.y + m.e - stageBox.left, y: m.b * q.x + m.d * q.y + m.f - stageBox.top });
  }
  outline.remove();
  const at = (f) => { const x = clamp01(f) * n; const i = Math.floor(x); const k = x - i; const a = points[i]; const b = points[Math.min(n, i + 1)]; return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k }; };
  const icon = ctx.rect(p.icon);
  const W = icon.W;
  const H = icon.H;
  const spark = popLayer(ctx);
  const focal = focalOf(ctx);
  const hot = tint(ctx.accent, 0.6);
  const ease = gsap.parseEase(E.out);

  const sparks = [];
  for (let i = 0; i < 170; i++) {
    const end = at(rnd(0, 1));
    const nx = clamp01((end.x - icon.x) / icon.w);
    const tA = 0.75 + 0.7 * nx + rnd(0, 0.16);
    const t0 = tA - rnd(0.5, 0.8);
    const s = { x: rnd(-0.35, 0) * W, y: rnd(-0.2, 0.75) * H };
    const c = { x: (s.x + end.x) / 2 + rnd(-0.1, 0.25) * W, y: Math.min(s.y, end.y) - rnd(0.05, 0.3) * H };
    sparks.push({ s, c, e: end, t0, tA, hot: rnd(0, 1) < 0.3 });
  }
  const last = { s: { x: W * 1.1, y: H * 0.05 }, c: { x: W * 0.85, y: focal.y - H * 0.25 }, e: focal, t0: 1.45, tA: 2.0, hot: true, last: true };
  sparks.push(last);
  const bez = (k, sp) => { const u = 1 - k; return { x: u * u * sp.s.x + 2 * u * k * sp.c.x + k * k * sp.e.x, y: u * u * sp.s.y + 2 * u * k * sp.c.y + k * k * sp.e.y }; };
  const burst = Array.from({ length: 16 }, (_, i) => ({ a: (i / 16) * Math.PI * 2 + rnd(-0.2, 0.2), v: rnd(50, 110) }));
  const { g, w, h } = ctx.canvas();
  // Additive light reads on a dark ground; on a light one it would vanish, so the particles paint over it there.
  const blend = ctx.dark ? "lighter" : "source-over";
  ctx.draw((t) => {
    g.clearRect(0, 0, w, h);
    g.globalCompositeOperation = blend;
    g.lineCap = "round";
    for (const sp of sparks) {
      if (t < sp.t0) continue;
      const k = (t - sp.t0) / (sp.tA - sp.t0);
      if (k < 1) {
        const a = bez(ease(k), sp);
        const b = bez(ease(Math.max(0, k - 0.1)), sp);
        g.strokeStyle = sp.hot ? hot : ctx.accent;
        g.lineWidth = sp.last ? 3 : 1.6;
        g.globalAlpha = 1;
        g.beginPath(); g.moveTo(b.x, b.y); g.lineTo(a.x, a.y); g.stroke();
      } else if (!sp.last) {
        const life = 1 - (t - sp.tA) / 0.45;
        if (life <= 0) continue;
        g.globalAlpha = life;
        g.fillStyle = sp.hot ? hot : ctx.accent;
        g.beginPath(); g.arc(sp.e.x, sp.e.y, 1.6, 0, Math.PI * 2); g.fill();
      }
    }
    const bt = t - last.tA;   // the landing burst
    if (bt > 0 && bt < 0.45) {
      const life = 1 - bt / 0.45;
      const d = ease(bt / 0.45);
      g.globalAlpha = life;
      g.strokeStyle = hot;
      g.lineWidth = 1.4;
      for (const b of burst) {
        const r1 = d * b.v * 0.45;
        const r0 = Math.max(0, r1 - 8);
        g.beginPath(); g.moveTo(focal.x + Math.cos(b.a) * r0, focal.y + Math.sin(b.a) * r0); g.lineTo(focal.x + Math.cos(b.a) * r1, focal.y + Math.sin(b.a) * r1); g.stroke();
      }
    }
    g.globalAlpha = 1;
    g.globalCompositeOperation = "source-over";
  });

  // A left-to-right soft wipe over the icon, in the svg's own units, following the arrivals.
  const box = ctx.box([p.icon]);
  const id = `motion-wipe-${Math.round(rnd(0, 1e9))}`;
  const defs = ctx.svgEl("defs");
  const feather = ctx.svgEl("linearGradient", { id: `${id}-f`, x1: "0", x2: "1", y1: "0", y2: "0" }, defs);
  [[0, 1], [0.82, 1], [1, 0]].forEach(([offset, opacity]) => ctx.svgEl("stop", { offset, "stop-color": "#fff", "stop-opacity": opacity }, feather));
  const mask = ctx.svgEl("mask", { id, maskUnits: "userSpaceOnUse", x: vb.x - vb.width, y: vb.y - vb.height, width: vb.width * 3, height: vb.height * 3 }, defs);
  const span = box.width * 2;
  const wipe = ctx.svgEl("rect", { x: box.x - span, y: box.y - 10, width: span, height: box.height + 20, fill: `url(#${id}-f)` }, mask);
  p.inner.setAttribute("mask", `url(#${id})`);
  const flash = spark ? spark.querySelector("path").cloneNode(false) : null;
  if (flash) { flash.setAttribute("fill", tint(ctx.accent, 0.9)); spark.querySelector("path").after(flash); gsap.set(flash, { opacity: 0 }); }

  gsap.set([...p.name, ...p.small], { autoAlpha: 0 });
  if (spark) gsap.set(spark, { autoAlpha: 0 });
  const from = spread(ctx, p.small, 0.6);
  tl.fromTo(wipe, { attr: { x: box.x - span } }, { attr: { x: box.x + box.width - span * 0.82 + 10 }, duration: 1.05, ease: E.inOut }, 1.0);
  if (spark) {
    tl.set(spark, { autoAlpha: 1 }, 2.0)
      .fromTo(spark, { scale: 1.3 }, { scale: 1, duration: 0.45, ease: E.out }, 2.0)
      .fromTo(flash, { opacity: 1 }, { opacity: 0, duration: 0.4, ease: E.out }, 2.0);
  }
  if (p.name.length) tl.fromTo(p.name, { autoAlpha: 0, y: vb.height * 0.08 }, { autoAlpha: 1, y: 0, duration: 0.6, ease: E.out, stagger: 0.03 }, 2.2);
  if (p.small.length) tl.fromTo(p.small, { autoAlpha: 0, x: (i) => from[i] }, { autoAlpha: 1, x: 0, duration: 0.8, ease: E.out }, 2.6);
  tl.to({}, { duration: HOLD });
}

// I17 WEIGHT FLICK: the icon lands and the name rises in its thinnest weight (the kit logo with both words at the
// library's lightest, laid out by the server: ctx.thin); on the beat every letter flicks to the kit's own weight and
// position, and the icon moves with the wider word. Only for lettering with weights (Logos::MotionPreset).
function weightFlick(ctx, tl) {
  const { parts: p, E, gsap, thin } = ctx;
  const letters = [...p.name, ...p.small];
  gsap.set([p.icon, ...letters], { autoAlpha: 0 });
  const beat = 1.85;
  const moves = thin && thin.deltas;
  if (!moves) {   // the two layouts differ letter for letter: fall back to a plain rise
    tl.fromTo(p.icon, { autoAlpha: 0, scale: 0.6 }, { autoAlpha: 1, scale: 1, duration: 0.5, ease: E.back }, 0.1);
    riseWords(ctx, tl, 0.45);
    tl.to({}, { duration: HOLD });
    return;
  }
  const paths = letters.map((letter) => letter.querySelector("path"));
  const heavyD = paths.map((path) => path.getAttribute("d"));
  paths.forEach((path, i) => { if (thin.d[i] && thin.d[i] !== heavyD[i]) path.setAttribute("d", thin.d[i]); });
  tl.fromTo(p.icon, { x: thin.icon.x, y: thin.icon.y, autoAlpha: 0, scale: 0.6 }, { x: thin.icon.x, y: thin.icon.y, autoAlpha: 1, scale: 1, duration: 0.5, ease: E.back }, 0.1)
    .fromTo(letters, { x: (i) => moves[i].x, y: (i) => moves[i].y + ctx.svg.viewBox.baseVal.height * 0.04, autoAlpha: 0 },
                     { x: (i) => moves[i].x, y: (i) => moves[i].y, autoAlpha: 1, duration: 0.55, ease: E.out, stagger: 0.03 }, 0.45);
  // gather before the cut, then the flick: thin to the kit's weights, every letter to its own place
  tl.fromTo(p.name, { scaleY: 1 }, { scaleY: 0.94, duration: 0.22, ease: E.in }, beat - 0.22)
    .to(p.name, { scaleY: 1, duration: 0.3, ease: E.out }, beat)
    .to(p.icon, { x: 0, y: 0, duration: 0.3, ease: E.inOut }, beat)
    .to(letters, { x: 0, y: 0, duration: 0.3, ease: E.inOut, stagger: 0.015 }, beat);
  paths.forEach((path, i) => {
    if (path.getAttribute("d") !== heavyD[i]) tl.to(path, { morphSVG: { shape: heavyD[i] }, duration: 0.3, ease: E.inOut }, beat + i * 0.015);
  });
  tl.to({}, { duration: HOLD });
}

export const PRESETS = {
  pop_slide: popSlide,
  stack_build: stackBuild,
  match_cut: matchCut,
  shape_morph: shapeMorph,
  tracking_breath: trackingBreath,
  dots_to_mark: dotsToMark,
  particle_resolve: particleResolve,
  weight_flick: weightFlick
};
