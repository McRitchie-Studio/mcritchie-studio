const { test, expect } = require("@playwright/test");

// A deploy, live. Seeded (e2e/seed.rb): an ACTIVE Next Release (Snorlax, in
// progress) and a prior SHIPPED Last Release (Dragonite). Shipping the active
// release via the local-only dev trigger fires a real DeploymentsBroadcaster
// Turbo Stream — the OPEN board (never reloaded) glows the just-shipped release
// into the Last Release slot and resets Next Release to its "none active" card.
// Plus: the in-progress timer ticks the seconds up while a release is active.
test("a deploy animates Last Release in, resets Next Release, and the timer ticks", async ({ page }) => {
  test.setTimeout(45_000);
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  // Seeded starting state.
  await expect(page.locator("#current-release [data-test='release-mascot']")).toContainText("Snorlax");
  await expect(page.locator("#last-release [data-test='release-mascot']")).toContainText("Dragonite");

  // The Next Release in-progress timer ticks down to the second — read it twice a
  // little over a second apart and confirm it advanced (the seconds are climbing).
  const timing = page.locator("#current-release [data-test='release-timing']");
  await expect(timing).toContainText("in progress");
  const before = await timing.textContent();
  await page.waitForTimeout(1200);
  const after = await timing.textContent();
  expect(after).not.toEqual(before);

  const stageTiming = page.locator("#current-release [data-test='release-tracker-duration'][data-release-ticker]").first();
  await expect(stageTiming).toBeVisible();
  await expect(stageTiming).toHaveAttribute("data-mode", "ago");
  await expect(stageTiming).toContainText(/ago/);

  // Ship the active release (local-only dev trigger → real in-process broadcast).
  const res = await page.request.post("/dev/board/ship_release");
  expect(res.ok()).toBeTruthy();

  // The board (no reload) resets Next Release to its fresh empty card…
  await expect(page.locator("#current-release")).toContainText("none active", { timeout: 10_000 });
  // …and the just-shipped release (Snorlax) takes over the Last Release slot, frozen.
  await expect(page.locator("#last-release [data-test='release-mascot']")).toContainText("Snorlax", { timeout: 10_000 });
  await expect(page.locator("#last-release [data-test='release-timing']")).toContainText("took");
  await expect(page.locator("#last-release")).toHaveAttribute("data-fresh-deploy", "true");
  await expect(page.locator("#last-release")).toHaveClass(/lbfx-fresh-deploy/);
  await expect(page.locator("#last-release")).toHaveClass(/studio-border-glow/);
  await expect(page.locator("#last-release")).toHaveClass(/release-fresh-glow/);

  await expect(page.locator("#dropzone-shipped #card-release-stack-current-c")).toBeVisible({ timeout: 10_000 });
  let shippedCardIds = await page.locator("#dropzone-shipped .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  expect(shippedCardIds.indexOf("card-release-stack-current-c")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-b"));
  expect(shippedCardIds.indexOf("card-release-stack-current-b")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-a"));

  await page.reload();
  await expect(page.locator("#last-release [data-test='release-mascot']")).toContainText("Snorlax", { timeout: 10_000 });
  await expect(page.locator("#last-release")).toHaveAttribute("data-fresh-deploy", "true");
  await expect(page.locator("#last-release")).toHaveClass(/release-fresh-glow/);
  await expect(page.locator("#last-release")).not.toHaveClass(/lbfx-fresh-deploy/, { timeout: 9_500 });
  await expect(page.locator("#last-release")).not.toHaveClass(/release-fresh-glow/);
  await expect(page.locator("#last-release")).toHaveClass(/opacity-75/);
  await expect(page.locator("#last-release")).toHaveAttribute("data-fresh-deploy", "false");
  expect(await page.locator("#last-release").getAttribute("style")).toBeNull();

  shippedCardIds = await page.locator("#dropzone-shipped .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  expect(shippedCardIds.indexOf("card-release-stack-current-c")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-b"));
  expect(shippedCardIds.indexOf("card-release-stack-current-b")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-a"));

  // No uncaught error from the broadcast/animation handlers.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
