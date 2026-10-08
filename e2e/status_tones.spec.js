const { test, expect } = require("@playwright/test");

// [component] Status colour comes from engine tokens (status_tone), so the same
// markup is legible in BOTH themes without a dark: twin. Each check flips the
// theme on <html>, then measures the element's text against the background it
// actually sits on: every ancestor's background composited from the page down.
// A dark-only class (text-red-300 on a near-white page) fails the light pass;
// a light-only one fails the dark pass.

const { CONTRAST, eachTheme, TEXT_ON_SURFACE, CHIP_ON_TINT } = require("./contrast");

// The stage ladder's solid rungs (StatusToneHelper::STAGE_TONES).
const SOLID_STAGES = ["Assembled", "Shipped"];
const SOLID_AA = 4.5;

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
    for (const stage of SOLID_STAGES) {
      expect(chips.map((c) => c.text), `${theme}: the ${stage} rung renders`).toContain(stage);
    }
    for (const chip of chips) {
      // A solid rung (Assembled, Shipped) has no tint to excuse: AA, 4.5.
      const floor = SOLID_STAGES.includes(chip.text) ? SOLID_AA : CHIP_ON_TINT;
      expect(chip.ratio, `${theme}: badge "${chip.text}" contrast`).toBeGreaterThanOrEqual(floor);
    }
  });
});

// The content artifact card's chips are measured inside artifact_gate.spec.js,
// before that spec approves the artifacts and the card leaves the page.

// The blocker's ✕ on a blocked card's crew avatars sits on the card's own
// danger tint, so it carries an opaque surface ground under the danger ink.
test("the blocked crew badge reads in both themes", async ({ page }) => {
  await page.goto("/tasks");
  const badge = page.locator("#card-task-ea8541e4b5b6 [data-test='crew-blocked']");
  await expect(badge).toBeVisible();

  await eachTheme(page, async (theme) => {
    const measured = await page.evaluate(CONTRAST, "#card-task-ea8541e4b5b6 [data-test='crew-blocked']");
    expect(measured.length, `${theme}: the badge renders`).toBe(1);
    expect(measured[0].ratio, `${theme}: ✕ contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
  });
});

// The card's Delete action turns to the danger ink on its own hover tint. The
// blocked card is the worst case: its hovered ground is already danger-tinted.
test("the card's delete action reads on its hover tint in both themes", async ({ page }) => {
  await page.goto("/tasks");
  const selector = "#card-task-ea8541e4b5b6 [data-test='task-card-delete']";
  const action = page.locator(selector);
  await expect(action).toBeVisible();
  await expect(action).toHaveClass(/(^|\s)hover:bg-danger\/10(\s|$)/);

  await eachTheme(page, async (theme) => {
    await action.hover();
    // The ink and the tint arrive over a colour transition, so poll the measure.
    await expect
      .poll(async () => (await page.evaluate(CONTRAST, selector))[0].ratio, { message: `${theme}: Delete on hover` })
      .toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    await page.mouse.move(0, 0);
  });
});
