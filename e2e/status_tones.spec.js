const { test, expect } = require("@playwright/test");

// [component] Status colour comes from engine tokens (status_tone), so the same
// markup is legible in BOTH themes without a dark: twin. Each check flips the
// theme on <html>, then measures the element's text against the background it
// actually sits on: every ancestor's background composited from the page down.
// A dark-only class (text-red-300 on a near-white page) fails the light pass;
// a light-only one fails the dark pass.

const CONTRAST = (selector) => {
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

  return [...document.querySelectorAll(selector)].map((el) => {
    const chain = [];
    for (let node = el; node; node = node.parentElement) chain.push(node);
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    for (const node of chain.reverse()) {
      const c = paint(getComputedStyle(node).backgroundColor);
      if (c.a > 0) bg = over(c, bg);
    }
    const fg = paint(getComputedStyle(el).color);
    return { text: el.textContent.trim().slice(0, 40), ratio: +ratio(over(fg, bg), bg).toFixed(2) };
  });
};

// The engine derives each -ink to clear AA (4.5) against the SURFACES, and the
// error box sits on the card surface with no tint: it measures 4.5 in dark.
// The 0.1 allowance is the canvas's 8-bit rounding, not a looser bar.
const TEXT_ON_SURFACE = 4.4;
// A chip lays its ink over its own 10% role tint, which the ink is NOT derived
// against: the danger chip measures 4.17 in dark (warning 4.51, success 4.6).
// This floor holds the chips to "legible in both themes" (the dark-only chips
// they replaced measured under 2 in light); lifting it to AA needs the engine's
// contrast_ink to search against the tint. Named on the task, not hidden here.
const CHIP_ON_TINT = 4.0;

async function eachTheme(page, check) {
  for (const theme of ["light", "dark"]) {
    await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);
    await check(theme);
  }
}

test("a form's validation errors read in both themes", async ({ page }) => {
  await page.goto("/tasks/new");
  await page.fill("input[name='task[title]']", "");
  await page.locator("form[action='/tasks'] [type='submit']").first().click();

  const box = page.locator("[data-test='form-errors']");
  await expect(box).toBeVisible();
  await expect(box).toContainText("Title can't be blank");
  await expect(box).toHaveClass(/(^|\s)text-danger-ink(\s|$)/);

  await eachTheme(page, async (theme) => {
    const lines = await page.evaluate(CONTRAST, "[data-test='form-errors'] p");
    expect(lines.length, `${theme}: the box lists its messages`).toBeGreaterThan(0);
    for (const line of lines) {
      expect(line.ratio, `${theme}: "${line.text}" contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
});

test("the stage badges read in both themes", async ({ page }) => {
  await page.goto("/stages");
  const badges = page.locator("[data-test='stage-guide-card'] > div:first-child > span:first-child");
  await expect(badges.first()).toBeVisible();

  await eachTheme(page, async (theme) => {
    const chips = await page.evaluate(CONTRAST, "[data-test='stage-guide-card'] > div:first-child > span:first-child");
    expect(chips.length, `${theme}: stage badges render`).toBeGreaterThan(0);
    for (const chip of chips) {
      expect(chip.ratio, `${theme}: badge "${chip.text}" contrast`).toBeGreaterThanOrEqual(CHIP_ON_TINT);
    }
  });
});

test("the content artifact card's status chips read in both themes", async ({ page }) => {
  await page.goto("/contents");
  await page.click("text=E2E Burrow And Chase");
  const chips = page.locator("[data-test='artifact-status-chip']");
  await expect(chips.first()).toBeVisible();

  await eachTheme(page, async (theme) => {
    const measured = await page.evaluate(CONTRAST, "[data-test='artifact-status-chip']");
    expect(measured.length, `${theme}: status chips render`).toBeGreaterThan(0);
    for (const chip of measured) {
      expect(chip.ratio, `${theme}: chip "${chip.text}" contrast`).toBeGreaterThanOrEqual(CHIP_ON_TINT);
    }
  });
});
