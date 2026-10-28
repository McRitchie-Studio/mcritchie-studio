// [e2e] /logos/welding_v2?type=stacked (task stacked-rule-of-three): the Stacked tab's
// Proportion control switches Commercial Welding v2's Stacked Logo from 3-2-1 to the rule
// of three, the URL says so, and the drawing changes: the icon is a third of the name's
// width, so its box is narrower and sits further in from the name's left edge.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// The first stacked logo shown, read from its own SVG: the name's width (the viewBox) and
// the icon's left edge (its translate; it is centred, so a narrower icon sits further in).
async function drawing(page) {
  const src = await page.locator("[data-test='logo-themed'][data-tone='light'] img[data-test='logo-image']").first().getAttribute("src");
  return page.evaluate(async (url) => {
    const svg = await (await fetch(url)).text();
    const [, , width, height] = svg.match(/viewBox="([^"]+)"/)[1].split(" ").map(Number);
    const iconLeft = Number(svg.match(/<g transform="translate\(([\d.]+),0\)">/)[1]);
    return { src: url, width, height, iconLeft, iconWidth: width - 2 * iconLeft };
  }, src);
}

test("welding_v2 stacked: Rule of three draws a narrower icon, a third of the name", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos/welding_v2?type=stacked");

  const current = page.locator("a[data-test='proportion-option'][aria-current='true']");
  await expect(current).toHaveText("3-2-1");
  const before = await drawing(page);
  expect(before.src).not.toContain("proportion=");

  await page.locator("a[data-test='proportion-option'][data-proportion='rule_of_three']").click();
  await expect(page).toHaveURL(/proportion=rule_of_three/);
  await expect(current).toHaveText("Rule of three");

  const after = await drawing(page);
  expect(after.src).toContain("proportion=rule_of_three");
  expect(after.width, "the name is as wide").toBeCloseTo(before.width, 1);
  expect(after.iconWidth, "the icon's box is narrower").toBeLessThan(0.7 * before.iconWidth);
  expect(after.iconWidth, "a third of the name's width").toBeCloseTo(after.width / 3, 0);
  expect(after.height, "a smaller icon makes a shorter logo").toBeLessThan(before.height);
});
