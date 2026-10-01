const { test, expect } = require("@playwright/test");

// The site footer, on this app's own pages.
//
// studio-engine renders the footer and ships its script and Leaflet (task
// hub-adopts-engine-footer; before that this app carried its own copy, task
// professional-site-footer). The engine's browser lane proves the script on lab
// pages. What only THIS app can prove, and what this spec is for:
//
//   * this app's asset pipeline serves the engine's Leaflet, so the map mounts
//     on a real page of this site (a 404 there leaves the fallback link, and
//     no Rails test would notice);
//   * the map is centred on the address in config/initializers/studio.rb;
//   * nothing still asks for the copy of Leaflet this app used to vendor;
//   * the layout's one footer line survives a Turbo visit between two of this
//     app's pages.
//
// No sign-in: the footer is the public site's. Tile images come from
// OpenStreetMap and are deliberately NOT asserted; the mount does not need them.

const map = (page) => page.locator("footer[data-site-footer] [data-footer-map]");

test("the footer map mounts, survives a Turbo visit, and follows the theme", async ({ page }) => {
  const asked = [];
  page.on("request", (request) => asked.push(new URL(request.url()).pathname));
  const leaflet = () => asked.filter((path) => /leaflet/i.test(path));

  await page.goto("/privacy");

  // Nothing is fetched for a map nobody has scrolled to: the footer is far
  // below the fold on this page, and `load` has fired (goto waits for it).
  await expect(map(page)).toHaveCount(1);
  expect(leaflet()).toEqual([]);
  await expect(map(page).locator(".ftr-map-fallback")).toHaveCount(1);

  await map(page).scrollIntoViewIfNeeded();

  // Mounted: Leaflet's container class lands on the element, with the pin on it,
  // and the no-script fallback link is gone.
  await expect(map(page)).toHaveClass(/leaflet-container/);
  await expect(map(page).locator(".ftr-pin")).toHaveCount(1);
  await expect(map(page).locator(".ftr-map-fallback")).toHaveCount(0);

  // Leaflet is the engine's, through this app's asset pipeline, script and
  // stylesheet both. The vendored copy is gone and nothing asks for it.
  expect(leaflet().some((path) => /^\/assets\/studio\/leaflet-[0-9a-f]+\.js$/.test(path))).toBe(true);
  expect(leaflet().some((path) => /^\/assets\/studio\/leaflet-[0-9a-f]+\.css$/.test(path))).toBe(true);
  expect(asked.filter((path) => path.startsWith("/vendor/"))).toEqual([]);
  // The stylesheet arrived: Leaflet's own rule positions its panes.
  expect(await map(page).locator(".leaflet-pane").first().evaluate((el) => getComputedStyle(el).position)).toBe("absolute");

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

  // A Turbo visit swaps the body. The new page's footer must mount its own map
  // once it, too, is scrolled to.
  await page.locator("footer[data-site-footer] a[href='/terms']").first().click();
  await expect(page).toHaveURL(/\/terms$/);
  await map(page).scrollIntoViewIfNeeded();
  await expect(map(page)).toHaveClass(/leaflet-container/);
  await expect(map(page).locator(".ftr-pin")).toHaveCount(1);
});
