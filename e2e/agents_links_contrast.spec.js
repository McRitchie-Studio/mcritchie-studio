const { test, expect } = require("@playwright/test");

// [component] The /agents header links (Dreams, Activities feed) sit on theme
// tokens, so they read in BOTH themes. They used white-alpha pills
// (border-white/10 bg-white/5 text-secondary) that all but vanished on the light
// page. Each pass flips the theme on <html> and measures the label against the
// ground it sits on, and the pill's border against the page, so a faint outline
// fails as well as faint text.

const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");

const LINKS = "[data-test='agents-dreams-link'], [data-test='agents-activities-link']";
// A visible outline, not text: WCAG's 3:1 is for UI parts that convey state; an
// outline that only frames a labelled link needs to be SEEN, so 1.3 is the floor.
const BORDER_FLOOR = 1.3;

const BORDERS = (selector) => {
  const cv = document.createElement("canvas");
  cv.width = cv.height = 1;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  const paint = (s) => {
    cx.clearRect(0, 0, 1, 1);
    cx.fillStyle = "#000";
    cx.fillStyle = s;
    cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data;
    return { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
  };
  const over = (fg, bg) => ({ r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a),
                              b: fg.b * fg.a + bg.b * (1 - fg.a), a: 1 });
  const lum = (c) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  return [...document.querySelectorAll(selector)].map((el) => {
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    const chain = [];
    for (let node = el.parentElement; node; node = node.parentElement) chain.push(node);
    for (const node of chain.reverse()) {
      const c = paint(getComputedStyle(node).backgroundColor);
      if (c.a > 0) bg = over(c, bg);
    }
    const border = over(paint(getComputedStyle(el).borderTopColor), bg);
    const [hi, lo] = [lum(border), lum(bg)].sort((x, y) => y - x);
    return { text: el.textContent.trim(), ratio: +((hi + 0.05) / (lo + 0.05)).toFixed(2) };
  });
};

test("the /agents header links read in both themes", async ({ page }) => {
  await page.goto("/agents");
  await expect(page.locator("[data-test='agents-dreams-link']")).toBeVisible();

  await eachTheme(page, async (theme) => {
    const labels = await page.evaluate(CONTRAST, LINKS);
    expect(labels.length, `${theme}: both links render`).toBe(2);
    for (const label of labels) {
      expect(label.ratio, `${theme}: "${label.text}" text contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
    for (const outline of await page.evaluate(BORDERS, LINKS)) {
      expect(outline.ratio, `${theme}: "${outline.text}" outline against the page`).toBeGreaterThanOrEqual(BORDER_FLOOR);
    }
  });
});
