const { test, expect } = require("@playwright/test");

// The TASK CARD's CI meter, measured in a real browser — the tier that can see the one
// defect this component keeps producing. The meter draws a mark per CI check INSIDE its
// rail (components/_ci_progress_meter), and a mark cap CANNOT keep that row inside the
// bar on reasoning alone: the first draft of ApplicationHelper::CI_METER_MARK_CAP was
// computed from the card's ~230px width, and the rail measures 168px. Fourteen marks
// spanned 166px in a 158px content box and the last one was clipped by 4px, SILENTLY,
// while the row still reported data-overflowed="false" — no error, no missing element,
// nothing a component test asserting mark COUNT could see. Same defect class as
// e2e/release_meter_fit.spec.js, one component over.
//
// Marks also ride ON the fill, so contrast is measured here too — a same-hue mark on a
// heavier fill is how the release meter once measured 1.73:1 while looking fine.
//
// The card is minted through the LOCAL-ONLY dev board toys rather than the seed, so the
// spec owns its own state: generate a fixture, advance it to the CI beat with beat=0 (the
// scripted 10-check run, played instantly), measure, then delete it.

const NARROW = 1280;
const WIDE = 1920;

const MEASURE = (slug) => {
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

  const row = document.querySelector(`#card-${slug} [data-test='task-ci-progress-marks']`);
  if (!row) return null;
  const rail = row.parentElement;
  const fill = rail.querySelector("[data-test='task-ci-progress-fill']");

  // Composite the WHOLE ancestor chain, outermost first, then the tint fill on top —
  // naming a couple of ancestors by hand gets a translucent panel (the meter card is
  // bg-inset/50) wrong in exactly the case the number depends on.
  const chain = [];
  for (let el = rail; el; el = el.parentElement) chain.push(el);
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

  const marks = [...row.children];
  const contrasts = marks.map((m) => +ratio(paint(getComputedStyle(m).color), bg).toFixed(2));
  // Per-state, so a failure names WHICH mark is illegible instead of just a number.
  const byState = {};
  marks.forEach((m, i) => { byState[m.dataset.ciCheckState] = contrasts[i]; });
  return {
    count: marks.length,
    states: marks.map((m) => m.dataset.ciCheckState),
    // The clip that shipped: content wider than the box it is drawn in.
    rowOverflows: row.scrollWidth > row.clientWidth,
    railWidth: Math.round(rail.getBoundingClientRect().width),
    overflowed: row.dataset.overflowed === "true",
    faded: (row.getAttribute("style") || "").includes("mask-image"),
    label: document.querySelector(`#card-${slug} [data-test='task-ci-progress-label']`)?.textContent.trim(),
    clockMode: document.querySelector(`#card-${slug} [data-test='task-ci-progress-clock']`)?.dataset.ciClock,
    lowestContrast: Math.min(...contrasts),
    contrastByState: byState,
    // Diagnostics: a contrast number alone cannot say WHICH background it was measured
    // against, and that is exactly what goes wrong when a theme or a fill is not what the
    // spec assumed.
    bg: `rgb(${Math.round(bg.r)},${Math.round(bg.g)},${Math.round(bg.b)})`,
    theme: document.documentElement.classList.contains("dark") ? "dark" : "light",
    markColors: [...new Set(marks.map((m) => getComputedStyle(m).color))],
    fill: fill ? `${getComputedStyle(fill).backgroundColor} @${getComputedStyle(fill).opacity}` : null,
  };
};

const post = (page, action) =>
  page.evaluate(async (a) => {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
    const res = await fetch("/dev/board/" + a, { method: "POST", headers: { "X-CSRF-Token": csrf } });
    return res.status;
  }, action);

test("the card CI meter fits its rail and stays legible in both themes", async ({ page }) => {
  await page.goto("/deployments");
  await post(page, "generate");
  // RELOAD rather than waiting on the live stream: this spec is about geometry, and
  // making it depend on the cable would buy it an unrelated flake.
  await page.goto("/deployments");
  const card = page.locator("[id^='card-dev-fixture-']").first();
  await expect(card).toBeAttached();
  const slug = await card.evaluate((el) => el.id.replace("card-", ""));

  // designed -> building -> waiting approval -> the scripted CI run (beat=0: instant).
  await post(page, "move");
  await post(page, "move");
  await post(page, "move?beat=0");

  try {
    for (const theme of ["light", "dark"]) {
      for (const width of [NARROW, WIDE]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.goto("/deployments");
        await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);
        await expect(page.locator(`#card-${slug} [data-test='task-ci-progress-marks']`)).toBeAttached();

        const m = await page.evaluate(MEASURE, slug);
        const where = `${theme} ${width}px`;
        expect(m, `${where}: the meter must render to be measured`).not.toBeNull();
        expect(m.rowOverflows, `${where}: marks must not overflow the rail (${m.railWidth}px)`).toBe(false);
        // The cap is what keeps them inside it, so a suite AT the cap is the case to pin.
        expect(m.count, `${where}: the scripted run draws all ten of its checks`).toBe(10);
        expect(m.overflowed, `${where}: ten checks is inside the cap, so nothing fades`).toBe(false);
        expect(m.faded, `${where}: and no mask is applied`).toBe(false);
        // Severity order: the ONE failing check sits leftmost, the nine passes right of it.
        expect(m.states[0], `${where}: the failure is pushed left`).toBe("failed");
        expect(new Set(m.states.slice(1)), `${where}: passes are pushed right`).toEqual(new Set(["passed"]));
        // 4.5:1 is the WCAG AA floor for text this size. The marks are the text here.
        expect(m.lowestContrast,
          `${where}: mark contrast ${JSON.stringify(m.contrastByState)} — theme=${m.theme} bg=${m.bg} fill=${m.fill} marks=${m.markColors}`
        ).toBeGreaterThanOrEqual(4.5);
        // The header the operator reads the run by.
        expect(m.label, `${where}: the label names the PR`).toMatch(/^PR: \d+$/);
        expect(m.clockMode, `${where}: a finished run freezes its clock`).toBe("settled");
      }
    }
  } finally {
    await page.setViewportSize({ width: WIDE, height: 1000 });
    await page.goto("/deployments");
    await post(page, "delete");
  }
});
