// [e2e] The logo gallery's edit panel (task logo-part-editor, app/javascript/logo_editor.js): picking a
// swatch submits the panel by itself, every logo on the tab is redrawn with the colour, the
// download carries it, the URL names only what was picked, the scroll stays where it was, and a
// colour under 3:1 against the page is warned about in the theme it is shown in.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const PAGE = "/logos/studio?type=stacked&form=tagline";

async function open(page, path = PAGE, width = 1280) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

// Runs `action` (a change that submits the panel) and waits for the NEXT page: the URL alone moves before Turbo has
// rendered it, so the old body is marked and the wait is for a wired panel in a body without the mark.
async function reloads(page, action, url) {
  await page.evaluate(() => { document.body.dataset.e2eOld = "1"; });
  await action();
  await page.waitForURL(url);
  await page.waitForFunction(() => !document.body.dataset.e2eOld && document.querySelector("form[data-logo-edit][data-logo-edit-wired]"));
}

const row = (page, part) => page.locator(`[data-test='edit-row'][data-part='${part}']`);
const swatch = (page, part, hex) => row(page, part).locator(`[data-test='edit-swatch'][data-hex='${hex}']`);

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("picking a colour redraws every logo on the tab, and the download carries it", async ({ page }) => {
  await open(page);
  await page.evaluate(() => window.scrollTo(0, document.querySelector("[data-test='edit-panel']").offsetTop - 100));
  const before = await page.evaluate(() => window.scrollY);

  // force: the swatch is in view and hit-testable, but Playwright's own actionability scroll can still move the page
  // before the click (seen once the brand page grew the kit cards below the panel), and that is not the scroll
  // the editor is meant to keep. The click itself is the user's.
  await reloads(page, () => swatch(page, "first", "#635BB2").click({ force: true }), /first_colour=635BB2/);
  const url = new URL(page.url());
  expect([...url.searchParams.keys()].sort()).toEqual(["first_colour", "form", "type"]);
  await expect(row(page, "first").locator("input[type=radio][value='635BB2']")).toBeChecked();

  const srcs = await page.locator("img[data-test='logo-image']").evaluateAll((imgs) => imgs.map((img) => img.getAttribute("src")));
  expect(srcs.length).toBe(6);
  for (const src of srcs) expect(src).toContain("first_colour=635BB2");

  const download = page.locator("a[data-test='logo-download']:visible").first();
  const href = await download.getAttribute("href");
  expect(href).toContain("first_colour=635BB2");
  const response = await page.request.get(href);
  expect(response.headers()["content-disposition"]).toMatch(/studio-stacked-tagline-homogeneous-(light|dark)-custom\.svg/);
  expect(await response.text()).toContain('fill="#635BB2"');

  await page.waitForFunction(() => [...document.querySelectorAll("img[data-test='logo-image']")].every((img) => img.complete));
  await page.waitForTimeout(100);
  const after = await page.evaluate(() => window.scrollY);
  expect(Math.abs(after - before), "the scroll stays where it was").toBeLessThan(40);
});

test("hiding the tagline and changing a weight keep the other edits, and Reset clears them", async ({ page }) => {
  await open(page, `${PAGE}&first_colour=635BB2`);
  await reloads(page, () => row(page, "tagline").locator("[data-test='edit-visible'] label", { hasText: "Hidden" }).click(), /tagline_visible=0/);
  await expect(row(page, "tagline").locator("input[type=radio][value='0']")).toBeChecked();
  await reloads(page, () => row(page, "ending").locator("select[data-test='edit-weight']").selectOption("300"), /ending_weight=300/);
  await expect(row(page, "ending").locator("select[data-test='edit-weight']")).toHaveValue("300");
  expect(page.url()).toContain("first_colour=635BB2");
  expect(page.url()).toContain("tagline_visible=0");

  // Copy SVG fetches its logo from its own URL (task logo-gallery-polish-pass): read what it would copy.
  const copyUrl = await page.locator("button[data-test='logo-copy']:visible").first().getAttribute("data-copy-svg");
  const copy = await (await page.request.get(copyUrl)).text();
  expect(copy).toContain('fill="#635BB2"');
  expect(copy).not.toContain("BUILD");

  await page.locator("[data-test='edit-reset']").click();
  await page.waitForURL((url) => !url.search.includes("_colour") && !url.search.includes("_weight") && !url.search.includes("tagline_visible"));
  await expect(row(page, "first").locator("input[type=radio][value='']")).toBeChecked();
});

test("a colour under 3:1 against the page is warned about, and the warning follows the theme", async ({ page }) => {
  await open(page, "/logos/studio?first_colour=EEECFF");
  await page.evaluate(() => {
    document.documentElement.classList.remove("dark");
  });
  const warning = row(page, "first").locator("[data-test='edit-contrast']");
  await expect(warning).toBeVisible();
  await expect(warning).toContainText("Violet Mist measures");

  await page.evaluate(() => document.documentElement.classList.add("dark"));
  await expect(warning).toBeHidden();
});

test("at 375 the edit panel fits without the page scrolling sideways", async ({ page }) => {
  await open(page, `${PAGE}&tagline_visible=0`, 375);
  await expect(page.locator("[data-test='edit-panel']")).toBeVisible();
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);
});
