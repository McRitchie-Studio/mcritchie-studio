// [e2e] Turf Monster's two-line Stacked Logo and Commercial Welding's blue helmet on dark (task
// turf-two-lines-and-welding-blue). Alex McRitchie 2026-10-28 picked Option A for Turf ("Turf" big, "Monster"
// beneath at its own width) and "Lets add the blue to both" for the welding helmets on a dark page.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const images = (page) => page.locator("img[data-test='logo-image']");

async function loaded(page) {
  await page.waitForFunction(() =>
    [...document.querySelectorAll("img[data-test='logo-image']")].every((img) => img.complete && img.naturalWidth > 0)
  );
}

test("Turf Monster's Stacked tab: Two lines draws a taller logo than One line, and comes back", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/turf?type=stacked");
  await loaded(page);
  await expect(page.locator("a[data-test='form-option']")).toHaveText(["One line", "Two lines"]);
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("One line");
  const ratio = () => images(page).first().evaluate((img) => img.naturalHeight / img.naturalWidth);
  const oneLine = await ratio();

  await page.locator("a[data-test='form-option'][data-form='two_line']").click();
  await page.waitForURL(/form=two_line/);
  await loaded(page);
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("Two lines");
  for (const src of await images(page).evaluateAll((els) => els.map((el) => el.getAttribute("src")))) expect(src).toContain("form=two_line");
  expect(await ratio(), "the name on two lines is narrower and taller").toBeGreaterThan(oneLine);

  await page.locator("a[data-test='form-option'][data-form='one_line']").click();
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("One line");
});

test("Commercial Welding's Alt helmet on a dark page keeps its blue half, v1 and v2", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  for (const brand of ["welding", "welding_v2"]) {
    const svg = await page.evaluate(async (path) => (await fetch(path)).text(), `/logos/${brand}/icon?tone=dark&colouring=alt`);
    expect(svg, `${brand}: blue half`).toContain('fill="#2D5E8E"');
    expect(svg, `${brand}: white half`).toContain('fill="#FFFFFF"');
    const watermark = await page.evaluate(async (path) => (await fetch(path)).text(), `/logos/${brand}/icon?tone=watermark`);
    expect(watermark, `${brand}: the watermark stays one colour`).not.toContain("#2D5E8E");
  }
});
