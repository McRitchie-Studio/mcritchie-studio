// [e2e] Compare two kits and word edits in Original (task logo-compare-and-original-edits; Alex McRitchie
// 2026-10-11 23:06: "comparing two marketing kits ... Commercial Welding V1 vs V2", "I also want a
// grid to be showable", and the Navbar/Stacked word colours in Original). The Compare button opens
// v1 against v2; Show grid draws both sides' construction guides at one scale, bottoms aligned;
// at 375 the sides stack; and on welding_v2's Stacked tab in Original an orange first word keeps
// the Original helmet.
const { test, expect } = require("@playwright/test");

const sideImages = (page, side) => page.locator(`[data-test='compare-side'][data-side='${side}'] img[data-test='logo-image']:visible`);

async function loaded(page) {
  await page.waitForFunction(() =>
    [...document.querySelectorAll("img[data-test='logo-image']")].every((img) => !img.offsetParent || (img.complete && img.naturalWidth > 0))
  );
}

async function params(locator) {
  return locator.evaluateAll((els) => els.map((el) => Object.fromEntries(new URL(el.getAttribute("src"), location.href).searchParams)));
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("compare welding v1 and v2 with the grid on: one scale, rows lined up", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto("/logos");
  await page.locator("[data-test='compare-link']").click();
  await page.waitForURL(/\/logos\/compare\?left=welding&right=welding_v2$/);
  await expect(page.locator("[data-test='compare-side']")).toHaveCount(2);
  await expect(page.locator("[data-test='compare-side'][data-side='left'] [data-test='compare-brand-link']")).toHaveText("Commercial Welding v1");
  await expect(page.locator("[data-test='compare-side'][data-side='right'] [data-test='compare-brand-link']")).toHaveText("Commercial Welding v2");

  await page.locator("[data-test='grid-toggle']").click();
  await page.waitForURL(/grid=1/);
  await expect(page.locator("[data-test='grid-toggle']")).toHaveText("Hide grid");
  await loaded(page);
  for (const side of ["left", "right"]) {
    for (const p of await params(sideImages(page, side))) expect(p.guides).toBe("1");
  }
  // Every Navbar guide drawing is one height in design units, so at one scale the two are one height,
  // side by side, with their feet on one line.
  const left = await sideImages(page, "left").boundingBox();
  const right = await sideImages(page, "right").boundingBox();
  expect(Math.abs(left.height - right.height)).toBeLessThan(1);
  expect(Math.abs(left.y + left.height - (right.y + right.height))).toBeLessThan(1);
  expect(right.x).toBeGreaterThan(left.x + left.width);

  // The Stacked tab keeps the grid, and the feet still line up.
  await page.locator("[data-test='logo-tab'][data-type='stacked']").click();
  await page.waitForURL(/type=stacked/);
  await expect(page).toHaveURL(/grid=1/);
  await loaded(page);
  const leftStacked = await sideImages(page, "left").boundingBox();
  const rightStacked = await sideImages(page, "right").boundingBox();
  expect(Math.abs(leftStacked.y + leftStacked.height - (rightStacked.y + rightStacked.height))).toBeLessThan(1);
});

test("at 375 the two sides stack and the page never scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 800 });
  await page.goto("/logos/compare?left=welding&right=welding_v2&type=stacked&grid=1");
  await loaded(page);
  const left = await page.locator("[data-test='compare-side'][data-side='left']").boundingBox();
  const right = await page.locator("[data-test='compare-side'][data-side='right']").boundingBox();
  expect(right.y).toBeGreaterThanOrEqual(left.y + left.height);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});

test("the brand dropdowns pick any two brands and keep the other controls", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto("/logos/compare?left=welding&right=welding_v2&rule=3");
  await page.locator("[data-test='compare-brand'][data-side='left']").selectOption("studio");
  await page.locator("[data-test='compare-submit']").click();
  await page.waitForURL(/left=studio/);
  await expect(page).toHaveURL(/rule=3/);
  await expect(page.locator("[data-test='compare-side'][data-side='left']")).toHaveAttribute("data-brand", "studio");
  for (const p of await params(sideImages(page, "left"))) expect(p.rule).toBe("3");
});

test("welding v2 Stacked in Original takes an orange first word and keeps the Original helmet", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto("/logos/welding_v2?type=stacked");
  await expect(page.locator("a[data-test='colouring-option'][aria-current='true']")).toHaveText("Original");
  await page.locator("[data-test='edit-row'][data-part='first'] [data-test='edit-swatch'][data-hex='#D7602E']").click();
  await page.waitForURL(/first_colour=D7602E/);
  await loaded(page);
  const shown = await params(page.locator("[data-test='logo-type'] img[data-test='logo-image']"));
  expect(shown.length).toBe(2);
  for (const p of shown) {
    expect(p.colouring).toBe("original");
    expect(p.first_colour).toBe("D7602E");
    expect(p.icon_colouring).toBeUndefined();
  }
  await page.locator("[data-test='kit-save-default']").click();
  await expect(page.locator("[data-test='kit-default-state']")).toHaveText("Showing the kit default.");
  for (const p of await params(page.locator("[data-test='logo-type'] img[data-test='logo-image']"))) {
    expect(p.colouring).toBe("original");
    expect(p.first_colour).toBe("D7602E");
  }
});
