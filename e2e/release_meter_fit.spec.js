const { test, expect } = require("@playwright/test");

// The release phase meter's LAYOUT, at the tier that can see it. The meter draws one mark
// per CI check inside its bar (tasks/_release_phase_meter), and both of the defects this
// file guards were invisible to every other tier:
//
//   · The marks overflowed the bar and `overflow-hidden` ate them SILENTLY — no error, no
//     missing element, nothing a component test asserting mark COUNT could see. The bar is
//     174px wide at a 1024px viewport but 80px at 1280px, because the dashboard's
//     `xl:grid-cols-2` halves the lane; a component test has no width at all, and the only
//     browser-tier spec pinned 1600px, one of the widths where it happens not to reproduce.
//   · The marks sit ON the fill, so a same-hue pair (mint ✓ on a mint fill) measured
//     1.73:1 while looking fine in dark mode.
//
// So: measure the real thing, at the widths that break it, in both themes. `data-state` is
// whatever the seeded release is — these assertions are about geometry and colour, not
// about any particular CI outcome, so they hold for any seed.
//
// The colour maths mirrors WCAG 2.1; colours are normalized by painting them to a canvas
// because Tailwind v4's palette computes to oklch(), which string-parsing drops.

const NARROW = 1280; // xl: the dashboard splits into two columns and the bar halves
const WIDE = 1920; // the bar's roomiest case

const MEASURE = () => {
  const cv = document.createElement("canvas");
  cv.width = cv.height = 1;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  const paint = (s) => {
    if (!s || s === "transparent") return { r: 0, g: 0, b: 0, a: 0 };
    cx.clearRect(0, 0, 1, 1);
    cx.fillStyle = "#000";
    cx.fillStyle = s;
    cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data;
    return { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
  };
  const over = (fg, bg) => ({
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a),
    a: 1,
  });
  const lum = (c) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const shown = (el) => !!el && getComputedStyle(el).display !== "none";

  return [...document.querySelectorAll("[data-test='release-phase-meter']")].map((meter) => {
    const bar = meter.querySelector("[data-test='release-phase-bar']");
    const row = meter.querySelector("[data-test='release-phase-checks']");
    const compact = meter.querySelector("[data-test='release-phase-compact-value']");
    const strip = bar.lastElementChild;
    const fill = bar.querySelector("div[style*='width']");

    // Composite the WHOLE ancestor chain, outermost first. Naming two ancestors by hand
    // skipped the card that actually paints the surface, which only shows up on a
    // TRANSLUCENT bar (the n/a phase is bg-inset/40) — where the backdrop is precisely
    // what the number depends on. An instrument that is right for opaque cases and quietly
    // wrong for translucent ones is how a bogus figure gets recorded as "measured".
    const chain = [];
    for (let el = bar; el; el = el.parentElement) chain.push(el);
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    for (const el of chain.reverse()) {
      const c = paint(getComputedStyle(el).backgroundColor);
      if (c.a > 0) bg = over(c, bg);
    }
    if (fill) {
      const c = paint(getComputedStyle(fill).backgroundColor);
      const op = parseFloat(getComputedStyle(fill).opacity);
      if (c.a > 0) bg = over({ ...c, a: c.a * op }, bg);
    }
    const painted = (shown(row) && row.firstElementChild) || (shown(compact) && compact) || strip;
    const contrast = ratio(paint(getComputedStyle(painted).color), bg);

    return {
      repo: meter.closest("[data-test='release-lane']").dataset.repo,
      phase: meter.dataset.phase,
      hasMarks: !!row,
      marksShown: shown(row),
      compactShown: shown(compact),
      // The clip that shipped: content wider than the box it is drawn in.
      rowOverflows: shown(row) && row.scrollWidth > row.clientWidth,
      stripOverflows: strip.scrollWidth > strip.clientWidth,
      contrast: +contrast.toFixed(2),
    };
  });
};

// Two explicit declarations, not a loop over themes: config/e2e_lane.yml's ratchet counts
// `test(...)` declarations in the SOURCE and cross-checks that count against playwright's own
// --list, so a loop that expands to two runtime tests from one source line would make the two
// halves of that gate certify different suites.
async function assertMetersFitAndAreLegible(page, theme) {
    for (const width of [NARROW, WIDE]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.goto("/deployments");
      await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);
      await expect(page.locator("#current-release [data-test='release-lane']").first()).toBeVisible();

      const meters = await page.evaluate(MEASURE);
      expect(meters.length, `${width}px: the release card must render meters to measure`).toBeGreaterThan(0);

      for (const m of meters) {
        const where = `${theme} ${width}px ${m.repo}/${m.phase}`;
        expect(m.rowOverflows, `${where}: marks must not overflow the bar`).toBe(false);
        expect(m.stripOverflows, `${where}: the bar's content must not overflow it`).toBe(false);
        // 4.5:1 is the WCAG AA floor for text this size. The marks are the text here.
        expect(m.contrast, `${where}: contrast ${m.contrast}:1 against the fill`).toBeGreaterThanOrEqual(4.5);

        if (m.hasMarks) {
          // Exactly one of the two representations is on screen — never both, never neither.
          expect(m.marksShown !== m.compactShown, `${where}: marks XOR the compact fraction`).toBe(true);
          // The narrow column cannot hold the marks, so it must fall back rather than clip.
          if (width === NARROW) expect(m.compactShown, `${where}: narrow bar shows the fraction`).toBe(true);
          if (width === WIDE) expect(m.marksShown, `${where}: wide bar shows the marks`).toBe(true);
        }
      }
    }
}

test("release meters fit their bar and stay legible in light mode", async ({ page }) => {
  await assertMetersFitAndAreLegible(page, "light");
});

test("release meters fit their bar and stay legible in dark mode", async ({ page }) => {
  await assertMetersFitAndAreLegible(page, "dark");
});
