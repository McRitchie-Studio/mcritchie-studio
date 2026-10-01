const { test, expect } = require("@playwright/test");

// The site footer (task professional-site-footer).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The component tier proves the footer's
// markup: the address, the phone, the legal links, the element the map mounts on.
// It cannot prove the map: that is an inline script that fetches Leaflet, mounts it
// on [data-footer-map], and replaces the fallback link. Only a browser shows that
// it ran, that it runs again after a Turbo visit (which replaces the body but not
// the script's state), and that dark mode restyles the tiles.
//
// No sign-in: the footer is the public site's. Tile images come from
// OpenStreetMap and are deliberately NOT asserted; the mount does not need them.

const map = (page) => page.locator("footer[data-site-footer] [data-footer-map]");

test("the footer map mounts, survives a Turbo visit, and follows the theme", async ({ page }) => {
  await page.goto("/privacy");

  // Mounted: Leaflet's container class lands on the element, with the pin on it,
  // and the no-script fallback link is gone.
  await expect(map(page)).toHaveClass(/leaflet-container/);
  await expect(map(page).locator(".ftr-pin")).toHaveCount(1);
  await expect(map(page).locator(".ftr-map-fallback")).toHaveCount(0);

  // The map runs edge to edge: as wide as the viewport, not the centred column.
  const widths = await map(page).evaluate((el) => [el.getBoundingClientRect().width, document.documentElement.clientWidth]);
  expect(widths[0]).toBe(widths[1]);

  // The map is centred on the address the footer prints.
  const centre = await map(page).evaluate((el) => {
    const c = el.__footerMap.getCenter();
    return [c.lat.toFixed(3), c.lng.toFixed(3)];
  });
  expect(centre).toEqual(["39.761", "-104.979"]);

  // Page scroll stays page scroll until the visitor clicks into the map.
  expect(await map(page).evaluate((el) => el.__footerMap.scrollWheelZoom.enabled())).toBe(false);

  // Dark mode restyles the same tiles in CSS.
  const tileFilter = () =>
    map(page).locator(".leaflet-tile-pane").evaluate((el) => getComputedStyle(el).filter);
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  expect(await tileFilter()).toBe("none");
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  expect(await tileFilter()).toContain("invert(1)");

  // A Turbo visit swaps the body. The new page's footer must mount its own map.
  await page.locator("footer[data-site-footer] a[href='/terms']").first().click();
  await expect(page).toHaveURL(/\/terms$/);
  await expect(map(page)).toHaveClass(/leaflet-container/);
  await expect(map(page).locator(".ftr-pin")).toHaveCount(1);
});
