// [e2e] /credentials — the software-by-entity matrix, as an admin sees it.
//
// e2e/seed.rb loads db/seeds/59_credentials.rb (the census) and registers
// mcritchie.studio as an ACTIVE workspace, so the Google row has a proven grant
// to show. What only a browser proves: the icons actually load (a broken asset
// path still renders an <img>), and the tooltip that replaced the text carries
// the domain and the items.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

test("admin reads the credential matrix: config row order, loaded icons, tooltips", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/credentials");

  await expect(page.getByRole("heading", { name: "Software by entity" })).toBeVisible();

  // Headline accounts first, by config order: 1Password, Google, TikTok, X.
  const rows = page.locator("[data-test='matrix-software']");
  await expect(rows.nth(0)).toHaveAttribute("data-service", "1password");
  await expect(rows.nth(1)).toHaveAttribute("data-service", "google");
  await expect(rows.nth(2)).toHaveAttribute("data-service", "tiktok");
  await expect(rows.nth(3)).toHaveAttribute("data-service", "x");

  // The Studio vault icon in the header LOADED — naturalWidth is 0 for a 404.
  const header = page.locator("[data-test='matrix-entity'][data-entity='studio'] img");
  await expect(header).toBeVisible();
  expect(await header.evaluate((img) => img.naturalWidth)).toBeGreaterThan(0);

  // Google x Studio: the badged G, delegation active, items in the tooltip.
  const google = page.locator(
    "[data-service='google'] [data-test='matrix-cell'][data-entity='studio'] [data-test='matrix-icon']"
  );
  await expect(google).toHaveAttribute("data-delegation", "active");
  await expect(google).toHaveAttribute("title", /mcritchie\.studio/);
  await expect(google).toHaveAttribute("title", /gmail\.studio\.agents/);
  expect(await google.locator("img").evaluate((img) => img.naturalWidth)).toBeGreaterThan(0);

  // A Turf Monster key filed in the Studio vault sits under Turf Monster.
  await expect(
    page.locator("[data-service='squads'] [data-test='matrix-cell'][data-entity='turf-monster'] [data-test='matrix-icon']")
  ).toBeVisible();
});
