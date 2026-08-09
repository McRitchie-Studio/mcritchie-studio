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
test("the deployments board updates a card live when an intent is recorded @quarantine", async ({ page }) => {
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

// Re-review live updates: a resubmitted task already has a historical completed
// review duration. Recording a fresh review intent after the rebuild must turn
// that same review lane into the current live ticker, not leave the old static
// duration badge in place.
test("a resubmitted card replaces the old review duration with a live review ticker @quarantine", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#card-live-rereview-demo");
  await expect(card).toBeVisible();
  const reviewLane = card.locator("[data-test='crew-cluster'][data-lane='review']");
  await expect(reviewLane.locator("[data-test='crew-duration']")).toHaveCount(1);
  await expect(reviewLane.locator("[data-test='crew-live']")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.post("/api/v1/tasks/live-rereview-demo/intent", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: {
      to_stage: "reviewed",
      reviewers: [{ slug: "shannon", weight: "primary" }, { slug: "carl", weight: "light" }],
      event: { source: "cli" },
    },
  });
  expect(res.ok()).toBeTruthy();

  await expect(reviewLane.locator("[data-test='crew-live']")).toHaveCount(1, { timeout: 10_000 });
  await expect(reviewLane.locator("[data-test='crew-duration']")).toHaveCount(0);
  await expect(page.locator("#dropzone-submitted #card-live-rereview-demo")).toBeVisible();

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("a direct-blocked card ignores stale review intent until a fresh one starts @quarantine", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#card-live-direct-block-demo");
  await expect(card).toBeVisible();
  const reviewLive = card.locator("[data-test='crew-cluster'][data-lane='review'] [data-test='crew-live']");
  await expect(reviewLive).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const res = await page.request.post("/api/v1/tasks/live-direct-block-demo/intent", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: {
      to_stage: "reviewed",
      reviewers: [{ slug: "shannon", weight: "primary" }, { slug: "carl", weight: "light" }],
      event: { source: "cli" },
    },
  });
  expect(res.ok()).toBeTruthy();

  await expect(reviewLive).toHaveCount(1, { timeout: 10_000 });
  await expect(page.locator("#dropzone-submitted #card-live-direct-block-demo")).toBeVisible();

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
test("a live stage change FLIPs the card to its new column and updates the count badges @quarantine", async ({ page }) => {
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
test("a live block transition inserts a missing card into the Building column @quarantine", async ({ page }) => {
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

test("a live block transition keeps an already-visible Building card visible @quarantine", async ({ page }) => {
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

test("the tasks board updates a blocked card live in the Building column @quarantine", async ({ page }) => {
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

// ── Next Release live FX: only what MOVED lights up ──────────────────────────
// The board replaces the WHOLE #current-release slot on every CI upsert, and the
// ingest upserts a CiCheckJob row on queued, in_progress AND completed while
// Ci::CheckProgress.bucket_for folds both pre-completion states to :pending — so a
// queued→in_progress delivery re-renders this card BYTE-IDENTICALLY, ~8 times per
// run. The fx must stay silent for those and still flash for a real card change.
//
// This is the only tier that can see it: the live-fx tests in test/views are
// source-string assertions, and a two-way branch that flashed on every identical
// re-render passed all of them. The replay below is byte-identical to what the
// server sends in that case and runs through the real turbo:before-stream-render
// handler, so the branch is exercised, not described.
async function replayCurrentRelease(page, mutate) {
  return page.evaluate(async (mutation) => {
    const seen = { card: 0, meters: [] };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        const el = record.target;
        if (!el.matches) continue;
        if (el.id === "current-release" && el.classList.contains("lbfx-glow")) seen.card += 1;
        if (el.matches("[data-test='release-phase-glow-host'].studio-team-glow")) {
          const meter = el.closest("[data-test='release-phase-meter']");
          if (meter) seen.meters.push(meter.dataset.phase);
        }
      }
    });
    observer.observe(document.body, { subtree: true, attributes: true, attributeFilter: ["class"] });

    let markup = document.getElementById("current-release").outerHTML;
    if (mutation) markup = markup.replace(/data-card-signature="[^"]*"/, `data-card-signature="${mutation}"`);

    const stream = document.createElement("turbo-stream");
    stream.setAttribute("action", "replace");
    stream.setAttribute("target", "current-release");
    const template = document.createElement("template");
    template.innerHTML = markup;
    stream.appendChild(template);
    document.body.appendChild(stream);

    await new Promise((resolve) => setTimeout(resolve, 600));
    observer.disconnect();
    stream.remove();
    return seen;
  }, mutate || null);
}

test("a byte-identical Next Release re-render flashes nothing", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));

  await page.goto("/deployments");
  await expect(page.locator("#current-release")).toBeVisible();
  await expect(page.locator("#current-release [data-test='release-phase-meter']").first()).toBeVisible();
  // The card must carry its own signature, or the fx has nothing to branch on and
  // silently falls back to flashing every re-render.
  await expect(page.locator("#current-release")).toHaveAttribute("data-card-signature", /.+/);

  const seen = await replayCurrentRelease(page, null);

  expect(seen.card, "an unchanged card must not flash").toBe(0);
  expect(seen.meters, "and no meter may ring when no meter moved").toEqual([]);
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("a Next Release card whose own signature moved still flashes", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));

  await page.goto("/deployments");
  await expect(page.locator("#current-release")).toBeVisible();

  // The other half of the property: silence must come from "nothing moved", not from a
  // dead branch. A moved card signature — a new release, a stage advance, a member
  // joining — still earns the card-wide flash.
  const seen = await replayCurrentRelease(page, "moved-card-signature");

  expect(seen.card, "a genuinely changed card must still flash").toBeGreaterThan(0);
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
