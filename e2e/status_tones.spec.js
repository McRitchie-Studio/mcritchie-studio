const { test, expect } = require("@playwright/test");

// [component] Status colour comes from engine tokens (status_tone), so the same
// markup is legible in BOTH themes without a dark: twin. Each check flips the
// theme on <html>, then measures the element's text against the background it
// actually sits on: every ancestor's background composited from the page down.
// A dark-only class (text-red-300 on a near-white page) fails the light pass;
// a light-only one fails the dark pass.

const { CONTRAST, eachTheme, TEXT_ON_SURFACE, CHIP_ON_TINT } = require("./contrast");

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

// The content artifact card's chips are measured inside artifact_gate.spec.js,
// before that spec approves the artifacts and the card leaves the page.
