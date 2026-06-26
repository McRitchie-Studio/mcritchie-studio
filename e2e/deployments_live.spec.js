const { test, expect } = require("@playwright/test");

async function releaseMemberMetrics(locator) {
  return locator.evaluateAll((els) => els.map((el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      className: el.className,
      boxShadow: style.boxShadow,
      borderLeftColor: style.borderLeftColor,
    };
  }));
}

async function assertLastReleaseStack(page) {
  const stack = page.locator("#last-release [data-test='release-member-stack']");
  await expect(stack).toBeVisible();
  await expect(stack).toHaveCSS("flex-wrap", "nowrap");
  await expect(stack).toHaveCSS("overflow-x", "hidden");

  const pills = page.locator("#last-release [data-test='release-member-pill']");
  await expect(pills).toHaveCount(3);
  const metrics = await releaseMemberMetrics(pills);
  const rowSpread = Math.max(...metrics.map((m) => m.y)) - Math.min(...metrics.map((m) => m.y));
  expect(rowSpread).toBeLessThanOrEqual(1);

  for (let index = 1; index < metrics.length; index += 1) {
    const exposedLeft = metrics[index].x - metrics[index - 1].x;
    expect(exposedLeft).toBeGreaterThan(24);
    expect(exposedLeft).toBeLessThan(metrics[index - 1].width);
    expect(metrics[index].className).toContain("-ml-20");
    expect(metrics[index].className).toContain("border-l");
    expect(metrics[index].boxShadow).not.toBe("none");
    expect(metrics[index].borderLeftColor).not.toBe("rgba(0, 0, 0, 0)");
  }
}

// /deployments live updates (DeploymentsChannel). The seeded `live-cable-demo`
// task starts in `submitted` with a crew but NO intent — so its card shows no
// live ticker. Recording a review intent against it (as if another session began
// the review) fires a real ActionCable broadcast; the already-open board swaps the
// card IN PLACE and the in-progress ticker appears — with NO page reload.
test("the deployments board updates a card live when an intent is recorded", async ({ page }) => {
  // The original miss was an UNCAUGHT TypeError in the broadcast handler (a wrong
  // method name) that fired after the DOM mutation — guard against any such throw.
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#card-live-cable-demo");
  await expect(card).toBeVisible();
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.post("/api/v1/tasks/live-cable-demo/intent", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: {
      to_stage: "reviewed",
      reviewers: [{ slug: "carl", weight: "heavy" }, { slug: "shannon", weight: "light" }],
      event: { source: "cli" },
    },
  });
  expect(res.ok()).toBeTruthy();

  // The board (never reloaded) receives the broadcast and replaces the card in
  // place; the in-progress review ticker now renders.
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(1, { timeout: 10_000 });
  await expect(page.locator("#dropzone-submitted #card-live-cable-demo")).toBeVisible();

  // …with no uncaught error from the broadcast handler.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("Last Release stacks member pills while Current Release keeps readable wrapping", async ({ page }) => {
  await page.goto("/deployments");

  const currentStack = page.locator("#current-release [data-test='release-member-stack']");
  await expect(currentStack).toHaveCount(0);
  const currentList = page.locator("#current-release [data-test='release-member-list']");
  await expect(currentList).toBeVisible();
  await expect(currentList).toHaveCSS("flex-wrap", "wrap");

  const currentPills = page.locator("#current-release [data-test='release-member-pill']");
  await expect(currentPills).toHaveCount(3);
  const currentClasses = await currentPills.evaluateAll((els) => els.map((el) => el.className));
  expect(currentClasses.every((className) => !className.includes("-ml-20"))).toBeTruthy();
  expect(currentClasses.every((className) => !className.includes("border-l"))).toBeTruthy();

  await assertLastReleaseStack(page);

  const html = page.locator("html");
  await expect(html).toHaveClass(/dark/);
  await page.click('button[title="Toggle theme"]');
  await expect(html).not.toHaveClass(/dark/);
  await assertLastReleaseStack(page);
});

// Assembled-column deploy crew: an assembled card carries a fixed FOUR-lane crew with
// the fourth (deploy) slot RESERVED but empty (nobody deploying). Recording a ship
// intent (Avi starting the deploy) fires a real broadcast; the already-open board swaps
// the card IN PLACE and the reserved deploy slot fills with Avi + a live ticker — the
// Deploy mirror of the build-lane live counter, with NO page reload.
test("an assembled card fills its reserved deploy slot live when a ship intent is recorded", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#card-live-deploy-crew-demo");
  await expect(card).toBeVisible();
  // Four fixed lanes before the ship, with the deploy slot reserved but EMPTY.
  await expect(card.locator("[data-test='stage-agent-avatars'].grid-cols-4")).toHaveCount(1);
  await expect(card.locator("[data-test='crew-empty'][data-lane='shipped']")).toHaveCount(1);
  await expect(card.locator("[data-test='crew-live']")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.post("/api/v1/tasks/live-deploy-crew-demo/intent", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { to_stage: "shipped", actor: "avi", event: { source: "cli" } },
  });
  expect(res.ok()).toBeTruthy();

  // The board (never reloaded) receives the broadcast and replaces the card in place:
  // the reserved deploy slot now carries Avi's avatar + a live ticker.
  const shipSlot = card.locator("[data-test='crew-cluster'][data-lane='shipped']");
  await expect(shipSlot).toHaveCount(1, { timeout: 10_000 });
  await expect(shipSlot.locator("[data-test='crew-live']")).toHaveCount(1);
  await expect(shipSlot.locator("div[title^='Avi']")).toHaveCount(1);
  await expect(card.locator("[data-test='crew-empty'][data-lane='shipped']")).toHaveCount(0);

  // …with no uncaught error from the broadcast handler.
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

// A live STAGE CHANGE moves the card to its new column AND updates the per-column
// count badges — the regression guard for the updateCounts() call in
// applyLiveUpdate (a wrong method name left the badges stale on every broadcast).
test("a live stage change FLIPs the card to its new column and updates the count badges", async ({ page }) => {
  await page.goto("/deployments");

  await expect(page.locator("#dropzone-submitted #card-live-cable-move-demo")).toBeVisible();

  const reviewedBadge = page.locator("[data-stage-count='reviewed']");
  const before = Number(((await reviewedBadge.textContent()) || "0").trim());

  // Move submitted→reviewed via the API → a real stage_change broadcast.
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch("/api/v1/tasks/live-cable-move-demo", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "reviewed", event: { source: "cli", actor: "avi" } },
  });
  expect(res.ok()).toBeTruthy();

  // The board (no reload) FLIPs the card into the Reviewed column…
  await expect(page.locator("#dropzone-reviewed #card-live-cable-move-demo")).toBeVisible({ timeout: 10_000 });
  // …and the Reviewed count badge updates (a stale badge means the handler threw).
  await expect(reviewedBadge).toHaveText(String(before + 1));
});

// Blocked has no standalone column; a blocked task rides the visual Building
// dropzone. A building→blocked broadcast must therefore INSERT the blocked card
// into Building, not only replace an existing DOM target. This test removes the
// stale visible card first to match the bug: a page reload would show it, but a
// replace-only websocket update leaves the open board empty.
test("a live block transition inserts a missing card into the Building column", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#dropzone-building #card-live-blocked-demo");
  await expect(card).toBeVisible();
  await card.evaluate((node) => node.remove());
  await expect(page.locator("#card-live-blocked-demo")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch("/api/v1/tasks/live-blocked-demo", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "blocked", event: { source: "cli", actor: "avi" } },
  });
  expect(res.ok()).toBeTruthy();

  const blockedCard = page.locator("#dropzone-building #card-live-blocked-demo");
  await expect(blockedCard).toBeVisible({ timeout: 10_000 });
  await expect(blockedCard).toHaveAttribute("data-stage", "blocked");
  await expect(blockedCard).toHaveAttribute("class", /bg-red/);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("a live block transition keeps an already-visible Building card visible", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#dropzone-building #card-live-blocked-visible-demo");
  await expect(card).toBeVisible();

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch("/api/v1/tasks/live-blocked-visible-demo", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "blocked", event: { source: "cli", actor: "avi" } },
  });
  expect(res.ok()).toBeTruthy();

  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(card).toHaveAttribute("data-stage", "blocked");
  await expect(card).toHaveAttribute("class", /bg-red/);
  await page.waitForTimeout(1_500);
  await expect(card).toBeVisible();

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("the tasks board updates a blocked card live in the Building column", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/tasks");

  const card = page.locator("#dropzone-building #card-tasks-live-blocked-demo");
  await expect(card).toBeVisible();
  await card.evaluate((node) => node.remove());
  await expect(page.locator("#card-tasks-live-blocked-demo")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.patch("/api/v1/tasks/tasks-live-blocked-demo", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { stage: "blocked", event: { source: "cli", actor: "avi" } },
  });
  expect(res.ok()).toBeTruthy();

  const blockedCard = page.locator("#dropzone-building #card-tasks-live-blocked-demo");
  await expect(blockedCard).toBeVisible({ timeout: 10_000 });
  await expect(blockedCard).toHaveAttribute("data-stage", "blocked");
  await expect(blockedCard).toHaveAttribute("class", /bg-red/);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
