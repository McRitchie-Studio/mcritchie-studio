const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// /agents/activities filter refresh — clicking a session in the sidebar fetches the
// filtered feed through the turbo-frame (background), NOT a full page reload: the sidebar
// stays open, the URL advances, and the frame swaps in place.
//
// The feed REQUIRES a session: #activities/#activities_filter were auth-gated to close the
// combinatorial ?sessions= crawl trap. Unauthenticated, the goto lands on the login page and
// meta[name='e2e-api-token'] never renders, so sign in first.
test("clicking a session filter refreshes the feed in the background, no full reload", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/agents/activities");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const session = `e2e-filter-${Date.now()}`;
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  // Seed one session so the sidebar has something to filter to.
  const created = await page.request.post("/api/v1/agent_activities", {
    headers: auth,
    data: { session_id: session, category: "Explore", reason: "a session to filter by", mascot: "pikachu" },
  });
  expect(created.ok()).toBeTruthy();

  // Reload so the server-rendered sidebar includes the new session.
  await page.goto("/agents/activities");
  // A marker that a FULL page reload would wipe — proves the filter click doesn't reload.
  await page.evaluate(() => { window.__noFullReload = "kept"; });

  await page.click("[data-test='aa-filter-toggle']");
  const row = page.locator(`[data-test='aa-filter-session'][data-session-id='${session}']`);
  await expect(row).toBeVisible();
  await row.click();

  // The URL advances to carry the filter…
  await expect(page).toHaveURL(new RegExp(`sessions=${session}`), { timeout: 10_000 });
  // …the active-filter chip appears (the frame re-rendered)…
  await expect(page.locator("[data-test='aa-active-filter']")).toHaveCount(1);
  // …the clicked session shows as selected…
  await expect(row).toHaveAttribute("data-selected", "true");
  // …the sidebar stayed open…
  await expect(page.locator("[data-test='aa-filter']")).toBeVisible();
  // …and it was a BACKGROUND swap, not a full reload (the window marker survived).
  expect(await page.evaluate(() => window.__noFullReload)).toBe("kept");

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
