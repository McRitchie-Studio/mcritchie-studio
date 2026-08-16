const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// A deploy, live. Seeded (e2e/seed.rb): an ACTIVE Next Release (Snorlax, in
// progress) and a prior SHIPPED Last Release (Dragonite, shipped minutes ago so
// it never glows). Shipping the active release via the local-only dev trigger
// fires a real DeploymentsBroadcaster Turbo Stream — the OPEN board (never
// reloaded) glows the just-shipped release into the Last Release slot and resets
// Next Release to its "none active" card. Plus: the in-progress timer ticks while
// a release is active.
//
// FRESHNESS IS A CLOSING WINDOW, NOT A STATE. data-fresh-deploy flips true at
// ship and the client (LiveBoardFx) flips it back false when the glow window
// ends — measured from shipped_at by WALL CLOCK. Under the production 8s window
// this spec's own arrival waits could eat the window on a loaded machine, and
// the fresh assertions then sampled a glow that had ALREADY expired — a state no
// timeout can wait back into (reproduced identically on the base seed under
// 8-way load; task stabilize-release-ship-spec). So the e2e server widens the
// window (playwright.config.js webServer env → FRESH_DEPLOY_WINDOW_MS, 20s),
// this spec reads the live value back from data-fresh-window-ms, asserts the
// fresh phase with real headroom, then WAITS for the expiry as a state change
// budgeted from that same window. No retries, no sampling, one spelling.
test("a deploy animates Last Release in, resets Next Release, and the timer ticks", async ({ page }) => {
  // The back half deliberately rides out the FULL widened glow window
  // (~20s + the pre-ship ticks), so the ceiling is 60s, not the default 30s.
  test.setTimeout(60_000);
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");

  const lastRelease = page.locator("#last-release");

  // Seeded starting state.
  await expect(page.locator("#current-release [data-test='release-mascot']")).toContainText("Snorlax");
  await expect(lastRelease.locator("[data-test='release-mascot']")).toContainText("Dragonite");

  // The Next Release in-progress timer ticks down to the second — read it twice a
  // little over a second apart and confirm it advanced (the seconds are climbing).
  const timing = page.locator("#current-release [data-test='release-timing']");
  await expect(timing).toContainText("in progress");
  const before = await timing.textContent();
  await page.waitForTimeout(1200);
  const after = await timing.textContent();
  expect(after).not.toEqual(before);

  // The Next Release card now shows the per-repo lanes tracker; the pizza-tracker
  // active-stage countdown was retired in the lanes redesign.
  await expect(page.locator("#current-release [data-test='release-lanes']")).toBeAttached();

  // Ship the active release (local-only dev trigger → real in-process broadcast).
  // The glow window opens HERE — everything fresh must be asserted well inside it.
  const res = await page.request.post("/dev/board/ship_release");
  expect(res.ok()).toBeTruthy();

  // The board (no reload) resets Next Release to its fresh empty card…
  await expect(page.locator("#current-release")).toContainText("none active", { timeout: 10_000 });
  // …and the just-shipped release (Snorlax) takes over the Last Release slot,
  // glowing: the stream card arrives fresh, and LiveBoardFx keeps it that way
  // until the window closes. Fresh-phase assertions run FIRST, right on the
  // arrival they gate on — the auto-waiting expects land while the widened
  // window still has ≥ half its width left even on a loaded machine.
  await expect(lastRelease.locator("[data-test='release-mascot']")).toContainText("Snorlax", { timeout: 10_000 });
  await expect(lastRelease).toHaveAttribute("data-fresh-deploy", "true", { timeout: 10_000 });
  await expect(lastRelease).toHaveClass(/lbfx-fresh-deploy/);
  await expect(lastRelease).toHaveClass(/studio-border-glow/);
  await expect(lastRelease).toHaveClass(/release-fresh-glow/);
  await expect(lastRelease.locator("[data-test='release-timing']")).toContainText("took");

  // The page self-describes its window; every later budget derives from it. The
  // floor guard fails LOUD if the e2e server ever loses the widened-window env
  // (playwright.config.js) — without it the spec silently reverts to racing the
  // production 8s window and flakes only under load.
  const windowMs = Number(await lastRelease.getAttribute("data-fresh-window-ms"));
  expect(windowMs).toBeGreaterThanOrEqual(15_000);

  // THE BATCH LANDS IN THE ORDER IT LEFT, WHICH REVERSES IT. Members flip from the
  // TOP of Assembled down (Release#ship! iterates Task.ordered, so an operator
  // watches the column peel from the top), and every arrival is a prepend — so the
  // FIRST card to leave ends up at the BOTTOM of Shipped. Seeded a, b, c ⇒ pre-ship
  // column c, b, a top-down ⇒ shipped column a, b, c.
  //
  // This spec used to assert the opposite (c above b above a): the batch keeping its
  // shape across the move. That invariant and a top-down departure cannot both hold
  // while arrivals prepend, and the operator chose the top-down departure
  // (/tasks/stagger-board-exit-animations). What IS still guaranteed — and asserted
  // by test/integration/board_task_rank_test.rb — is that the live order and a
  // reload agree, which is why the same assertion runs again after the reload below.
  await expect(page.locator("#dropzone-shipped #card-release-stack-current-c")).toBeVisible({ timeout: 10_000 });
  let shippedCardIds = await page.locator("#dropzone-shipped .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  expect(shippedCardIds.indexOf("card-release-stack-current-a")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-b"));
  expect(shippedCardIds.indexOf("card-release-stack-current-b")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-c"));

  // Reload while still inside the window: the SERVER now renders the fresh
  // state (glow classes + phase style), and turbo:load re-arms the client
  // expiry timer for the remainder.
  await page.reload();
  await expect(lastRelease.locator("[data-test='release-mascot']")).toContainText("Snorlax", { timeout: 10_000 });
  await expect(lastRelease).toHaveAttribute("data-fresh-deploy", "true");
  await expect(lastRelease).toHaveClass(/release-fresh-glow/);

  // …then the glow EXPIRES. Wait for the state flip itself — clearFreshDeployGlow
  // strips classes + style and stamps data-fresh-deploy=false in one synchronous
  // call — with a budget derived from the window (remaining time is at most
  // windowMs; +5s absorbs timer slack and load jank). Everything after the flip
  // is stable, so the remaining assertions need no special budgets.
  await expect(lastRelease).toHaveAttribute("data-fresh-deploy", "false", { timeout: windowMs + 5_000 });
  await expect(lastRelease).not.toHaveClass(/lbfx-fresh-deploy/);
  await expect(lastRelease).not.toHaveClass(/release-fresh-glow/);
  await expect(lastRelease).not.toHaveClass(/studio-border-glow/);
  await expect(lastRelease).toHaveClass(/opacity-75/);
  expect(await lastRelease.getAttribute("style")).toBeNull();

  // Same order after a full server render as the live board showed: the rank each
  // flip stamps and the prepend the board performs must never disagree.
  shippedCardIds = await page.locator("#dropzone-shipped .kanban-card").evaluateAll((cards) => cards.map((card) => card.id));
  expect(shippedCardIds.indexOf("card-release-stack-current-a")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-b"));
  expect(shippedCardIds.indexOf("card-release-stack-current-b")).toBeLessThan(shippedCardIds.indexOf("card-release-stack-current-c"));

  // No uncaught error from the broadcast/animation handlers.
  expect(pageErrors, report()).toHaveLength(0);
});
