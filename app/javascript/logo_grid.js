// The logo grid backdrop (app/views/shared/_logo_grid.html.erb; task
// logo-grid-backdrop). A brick grid of agent portraits and app logos sits dim
// behind a band. Tiles near the pointer light up, and the light trails behind
// it and fades. Away from the pointer a slow wandering light keeps the band
// alive, so a phone (no hover) sees the effect too. Reduced motion gets a still
// grid and no loop. The look follows Alex McRitchie's 2026-11-07 reference:
// Cloudflare's /domains hero grid.
//
// The math is pure (layout, tileIndex, intensity, settle, wander), so
// test/javascript/logo_grid_test.js runs it without a browser. The rest mounts
// one grid per [data-logo-grid] and lets go of it before Turbo caches the page.

export const CELL = 92;          // tile pitch in px; --logo-grid-cell overrides
export const RADIUS = 210;       // how far the light reaches, in px
export const RISE_MS = 70;       // how fast a tile lights toward its target
export const FADE_MS = 650;      // how long the trail takes to fade (time constant)
export const WANDER_MS = 16000;  // one loop of the wandering light
const EPSILON = 0.004;

// Columns and rows that cover a width x height box. Odd rows sit half a cell
// to the right (the brick offset), so each row takes one spare column.
export function layout(width, height, cell = CELL) {
  if (!(width > 0) || !(height > 0) || !(cell > 0)) return { cols: 0, rows: 0, cell };
  return { cols: Math.ceil(width / cell) + 1, rows: Math.ceil(height / cell) + 1, cell };
}

// The step between rows. A tile's neighbours are the tiles beside it (column
// +/-1) and, in a brick grid, three in the row above (step-1, step, step+1).
// None may land on the same tile, so step-1, step and step+1 must all be
// non-zero mod count. A step near a third of the count spreads repeats out.
export function rowStep(count) {
  if (count < 4) return 1;
  const ok = (s) => [s - 1, s, s + 1].every((v) => ((v % count) + count) % count !== 0);
  const near = Math.max(2, Math.round(count * 0.38));
  for (let d = 0; d < count; d += 1) {
    if (ok(near + d)) return near + d;
    if (near - d >= 2 && ok(near - d)) return near - d;
  }
  return 2;
}

// Which tile sits at row r, column c.
export function tileIndex(row, col, count, step = rowStep(count)) {
  if (count <= 0) return -1;
  return (((col + row * step) % count) + count) % count;
}

// The centre of cell (row, col), in px from the grid's top left. The first
// row and column bleed half a cell past the edge, so the grid has no margin.
export function cellCentre(row, col, cell = CELL) {
  const shift = row % 2 === 1 ? cell / 2 : 0;
  return { x: col * cell + shift - cell / 2, y: row * cell };
}

// Light from a point at distance d: 1 at the point, 0 at the radius, a smooth
// step in between.
export function intensity(distance, radius = RADIUS) {
  if (!(radius > 0) || distance >= radius) return 0;
  const t = 1 - Math.max(0, distance) / radius;
  return t * t * (3 - 2 * t);
}

// One frame of a tile's light: it rises quickly toward a brighter target and
// fades slowly toward a dimmer one (the trail). Below EPSILON it rests at the
// target, so the loop can stop.
export function settle(current, target, dtMs, riseMs = RISE_MS, fadeMs = FADE_MS) {
  const dt = Math.max(0, dtMs);
  let next;
  if (target >= current) next = current + (target - current) * (1 - Math.exp(-dt / riseMs));
  else next = target + (current - target) * Math.exp(-dt / fadeMs);
  return Math.abs(next - target) < EPSILON ? target : next;
}

// Where the wandering light is at time t: a slow figure that stays inside the
// box, away from its edges.
export function wander(tMs, width, height, periodMs = WANDER_MS) {
  const a = (2 * Math.PI * tMs) / periodMs;
  return {
    x: width * (0.5 + 0.38 * Math.sin(a)),
    y: height * (0.5 + 0.32 * Math.sin(2 * a + Math.PI / 3)),
  };
}

// Whether the grid animates. Reduced motion gets a still grid; everyone else,
// phones included, gets the loop (the wandering light is the phone's version,
// since a phone has no hover). Takes matchMedia, so a test can stand it in.
export function animates(match) {
  if (typeof match !== "function") return true;
  try {
    return !match("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return true;
  }
}

// ---- the browser side ------------------------------------------------------

const grids = new Map();

function readTiles(el) {
  try {
    const tiles = JSON.parse(el.dataset.tiles || "[]");
    return Array.isArray(tiles) ? tiles.filter((t) => t && typeof t.src === "string") : [];
  } catch {
    return [];
  }
}

class LogoGrid {
  constructor(el) {
    this.el = el;
    this.host = el.closest("[data-logo-grid-host]") || el.parentElement;
    this.tiles = readTiles(el);
    this.cells = [];
    this.pointer = null;
    this.visible = false;
    this.frame = 0;
    this.last = 0;
    this.still = !animates(typeof matchMedia === "function" ? matchMedia.bind(window) : null);
    this.onMove = (e) => this.move(e);
    this.onLeave = () => { this.pointer = null; this.wake(); };
    this.build();
    this.host.addEventListener("pointermove", this.onMove, { passive: true });
    this.host.addEventListener("pointerleave", this.onLeave, { passive: true });
    if (typeof ResizeObserver !== "undefined") {
      let pending = 0;
      this.resize = new ResizeObserver(() => {
        clearTimeout(pending);
        pending = setTimeout(() => this.build(), 150);
      });
      this.resize.observe(el);
    }
    if (typeof IntersectionObserver !== "undefined") {
      this.seen = new IntersectionObserver(([entry]) => {
        this.visible = entry.isIntersecting;
        if (this.visible) this.wake();
      });
      this.seen.observe(el);
    } else {
      this.visible = true;
      this.wake();
    }
  }

  build() {
    const cell = parseFloat(getComputedStyle(this.el).getPropertyValue("--logo-grid-cell")) || CELL;
    const { cols, rows } = layout(this.el.clientWidth, this.el.clientHeight, cell);
    const count = this.tiles.length;
    const step = rowStep(count);
    const fragment = document.createDocumentFragment();
    this.cells = [];
    for (let r = 0; r < rows && count; r += 1) {
      for (let c = 0; c < cols; c += 1) {
        const tile = this.tiles[tileIndex(r, c, count, step)];
        const { x, y } = cellCentre(r, c, cell);
        const node = document.createElement("span");
        node.className = "logo-grid-cell";
        node.style.left = `${x}px`;
        node.style.top = `${y}px`;
        const img = document.createElement("img");
        img.src = tile.src;
        img.alt = "";
        img.decoding = "async";
        img.loading = "lazy";
        img.draggable = false;
        img.width = 160;
        img.height = 160;
        node.append(img);
        fragment.append(node);
        this.cells.push({ node, x, y, lit: 0 });
      }
    }
    this.el.replaceChildren(fragment);
    this.el.dataset.logoGridCells = String(this.cells.length);
    this.wake();
  }

  move(e) {
    const box = this.el.getBoundingClientRect();
    this.pointer = { x: e.clientX - box.left, y: e.clientY - box.top };
    this.wake();
  }

  wake() {
    if (this.still || this.frame || !this.visible) return;
    this.last = performance.now();
    this.frame = requestAnimationFrame((t) => this.tick(t));
  }

  tick(now) {
    this.frame = 0;
    const dt = Math.min(64, now - this.last);
    this.last = now;
    const light = this.pointer || wander(now, this.el.clientWidth, this.el.clientHeight);
    for (const cell of this.cells) {
      const target = intensity(Math.hypot(cell.x - light.x, cell.y - light.y));
      const lit = settle(cell.lit, target, dt);
      if (Math.abs(lit - cell.lit) > 0.002 || (lit === 0 && cell.lit !== 0)) {
        cell.node.style.setProperty("--lit", lit.toFixed(3));
      }
      cell.lit = lit;
    }
    if (this.visible) this.frame = requestAnimationFrame((t) => this.tick(t));
  }

  release() {
    cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.host.removeEventListener("pointermove", this.onMove);
    this.host.removeEventListener("pointerleave", this.onLeave);
    this.resize?.disconnect();
    this.seen?.disconnect();
    this.el.replaceChildren();
    delete this.el.dataset.logoGridCells;
  }
}

export function mountLogoGrids(root = document) {
  grids.forEach((grid, el) => {
    if (el.isConnected) return;
    grid.release();
    grids.delete(el);
  });
  root.querySelectorAll("[data-logo-grid]").forEach((el) => {
    if (!grids.has(el)) grids.set(el, new LogoGrid(el));
  });
}

export function releaseLogoGrids() {
  grids.forEach((grid) => grid.release());
  grids.clear();
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  document.addEventListener("turbo:load", () => mountLogoGrids());
  document.addEventListener("turbo:before-cache", () => releaseLogoGrids());
}
