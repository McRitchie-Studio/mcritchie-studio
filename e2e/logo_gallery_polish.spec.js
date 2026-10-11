// [e2e] The logo gallery's polish pass (task logo-gallery-polish-pass): the edit panel's Reset is a
// full-size touch target on a phone, a kit original's Delete asks first, the Kit card's button rows
// line up, a Copy SVG fetches the logo from its own URL and says Copied, and a shared context link
// opens in its theme from the first paint.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function open(page, path, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("the edit panel's Reset is at least 40 px tall at 375 px", async ({ page }) => {
  await open(page, "/logos/studio?first_colour=635BB2", 375);
  const box = await page.locator("[data-test='edit-reset']").boundingBox();
  expect(box.height).toBeGreaterThanOrEqual(40);
  expect(box.width).toBeGreaterThanOrEqual(40);
});

test("deleting a kit original asks first: Delete opens the question, Cancel closes it, and the named button deletes", async ({ page }) => {
  await open(page, "/logos/turf?type=icon");
  const card = page.locator("[data-test='kit-originals']");
  await card.locator("input[type='file']").setInputFiles([
    { name: "turf-polish.svg", mimeType: "image/svg+xml", buffer: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>') }
  ]);
  await card.locator("[data-test='kit-original-upload']").click();
  await page.waitForURL(/#kit-originals/);
  const item = page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" });
  const confirm = item.locator("[data-test='kit-original-delete-confirm']");
  await expect(confirm).toBeHidden();

  // By keyboard: the first step is a focusable control, and Enter opens it.
  await item.locator("[data-test='kit-original-delete']").focus();
  await page.keyboard.press("Enter");
  await expect(confirm).toBeVisible();
  await expect(confirm).toHaveText("Delete turf-polish.svg");
  await expect(item.locator("[data-test='kit-original-delete']")).toContainText("Cancel");
  await page.keyboard.press("Enter");
  await expect(confirm).toBeHidden();
  await expect(item).toHaveCount(1);

  await item.locator("[data-test='kit-original-delete']").click();
  await confirm.click();
  await expect(page.getByText("Removed turf-polish.svg.")).toBeVisible();
  await expect(page.locator("[data-test='kit-original']").filter({ hasText: "turf-polish.svg" })).toHaveCount(0);
});

test("saving and clearing a kit choice return to the same tab, scrolled to the Kit choice card", async ({ page }) => {
  await open(page, "/logos/studio?type=stacked&form=tagline");
  // Scrolled to the card, and the card's heading clear of the sticky navbar.
  const inView = () => page.evaluate(() => {
    const top = document.querySelector("[data-test='kit-choice']").getBoundingClientRect().top;
    const navBottom = document.querySelector("header").getBoundingClientRect().bottom;
    return window.scrollY > 0 && top >= navBottom - 1 && top < window.innerHeight / 2;
  });

  await page.locator("[data-test='kit-save']").click();
  await page.waitForURL(/\/logos\/studio\?(?=.*type=stacked)(?=.*form=tagline).*#kit-choice$/);
  await expect(page.getByText(/Saved the Stacked Logo kit choice/)).toBeAttached();
  await expect.poll(inView).toBe(true);

  await page.locator("[data-test='kit-clear']").click();
  await page.waitForURL(/\/logos\/studio\?(?=.*type=stacked)(?=.*form=tagline).*#kit-choice$/);
  await expect(page.getByText("Cleared the Stacked Logo kit choice. The brand shows its default again.")).toBeAttached();
  await expect.poll(inView).toBe(true);
});

test("at 1280 a saved kit's status stays on one line and no brand's logo tiles wrap", async ({ page }) => {
  await open(page, "/logos/industries?type=stacked");
  await page.locator("[data-test='kit-save']").click();
  await page.waitForURL(/#kit-choice$/);
  try {
    await page.goto("/logos");
    const status = page.locator("[data-brand='industries'] [data-test='logo-kit-status']");
    await expect(status).toHaveText(/^Kit: saved \w{3} \d+, \d{4} by Alex Test$/);
    await expect(status).toHaveAttribute("title", /by Alex Test \(alex@test\.com\)$/);
    const rows = await page.evaluate(() => Array.from(document.querySelectorAll("[data-test='logo-cluster']")).map((cluster) => {
      const top = (type) => cluster.querySelector(`[data-test='logo-sample'][data-type='${type}']`).getBoundingClientRect().top;
      const line = cluster.closest("tr").querySelector("[data-test='logo-kit-status']");
      return { brand: cluster.dataset.brand, sameLine: Math.abs(top("stacked") - top("navbar")) < 1, oneLine: line.getClientRects().length === 1 && line.offsetHeight < 20 };
    }));
    for (const row of rows) expect(row, row.brand).toEqual({ brand: row.brand, sameLine: true, oneLine: true });
  } finally {
    await page.goto("/logos/industries?type=stacked");
    await page.locator("[data-test='kit-clear']").click();
    await page.waitForURL(/#kit-choice$/);
  }
});
