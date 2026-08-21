const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// THE UPSTREAM LANES ONLY RENDER WIDE — call this in a spec that waits on a card in
// designed / building / submitted.
//
// _deploy_board.html.erb collapses the three upstream lanes of the six-lane
// Deployments board below 1400px unless "All Stages" is on:
//   :class="showAllCols ? '' : 'max-[1399px]:hidden'"
// Playwright configures no viewport, so Chromium's 1280x720 default hid every card
// these specs wait on. The card is in the DOM the whole time and `toBeVisible` reports
// "hidden", which reads like a broken spec rather than a layout rule — that is why
// this cluster was quarantined instead of fixed.
//
// PER-SPEC, NOT `test.use` AT FILE SCOPE. A file-wide viewport was written first and it
// BROKE TWO PASSING SPECS: the release-ring tone tests (`#current-release
// [data-test='release-phase-fill']`) pass at 1280 and fail at 1600. Measured both ways.
// A fix that repairs three specs by breaking two is not a repair, so the widening is
// scoped to the specs that actually need the lane.
async function showUpstreamLanes(page) {
  await page.setViewportSize({ width: 1600, height: 900 });
}


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
  await showUpstreamLanes(page);
  // The original miss was an UNCAUGHT TypeError in the broadcast handler (a wrong
  // method name) that fired after the DOM mutation — guard against any such throw.
  const { pageErrors, report } = watchPageErrors(page);

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
  expect(pageErrors, report()).toHaveLength(0);
});

// Re-review live updates: a resubmitted task already has a historical completed
// review duration. Recording a fresh review intent after the rebuild must turn
// that same review lane into the current live ticker, not leave the old static
// duration badge in place.
test("a resubmitted card replaces the old review duration with a live review ticker @quarantine", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

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

  expect(pageErrors, report()).toHaveLength(0);
});

test("a direct-blocked card ignores stale review intent until a fresh one starts", async ({ page }) => {
  await showUpstreamLanes(page);
  const { pageErrors, report } = watchPageErrors(page);

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

  expect(pageErrors, report()).toHaveLength(0);
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
  const { pageErrors, report } = watchPageErrors(page);

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
  expect(pageErrors, report()).toHaveLength(0);
});

// A live STAGE CHANGE moves the card to its new column AND updates the per-column
// count badges — the regression guard for the updateCounts() call in
// applyLiveUpdate (a wrong method name left the badges stale on every broadcast).
test("a live stage change FLIPs the card to its new column and updates the count badges", async ({ page }) => {
  await showUpstreamLanes(page);
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
  await showUpstreamLanes(page);
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");

  const card = page.locator("#dropzone-building #card-live-blocked-demo");
  await expect(card).toBeVisible();
  await card.evaluate((node) => node.remove());
  await expect(page.locator("#card-live-blocked-demo")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  // BLOCKING IS AN ATTRIBUTE, NOT A STAGE MOVE — and that is why these specs rotted.
  // They were written when `blocked` was a stage you could PATCH to. It no longer is:
  // app/models/task.rb states outright "There is NO →blocked transition", and the block
  // columns (blocked_at / blocked_from / blocked_by / block_kind) are stamped
  // server-side by Task#block! so blocked_from is DERIVED, never caller-supplied. The
  // old payload `{ stage: "blocked" }` is now simply invalid, so res.ok() was false and
  // the live-update assertions below never got their chance to run.
  const res = await page.request.patch("/api/v1/tasks/live-blocked-demo/block", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { by: "avi", kind: "rework" },
  });
  expect(res.ok()).toBeTruthy();

  const blockedCard = page.locator("#dropzone-building #card-live-blocked-demo");
  await expect(blockedCard).toBeVisible({ timeout: 10_000 });
  // A blocked task STAYS ON `building` — Task#block! stamps the block columns and
  // leaves the stage alone, so data-stage never becomes "blocked". The card marks
  // the block with data-stage-glow instead (_task_card.html.erb line 140, from
  // card_glow_kind). NOT data-glow — that is the MASCOT'S signature colour (line 142),
  // and asserting it was a bug in the first cut of this repair: the specs stay
  // @quarantine so CI never ran them and nothing caught it. Verified against the real
  // rendered card while proving /tasks/broadcast-block-to-board.
  // the attribute that actually tracks Task#block_state.
  await expect(blockedCard).toHaveAttribute("data-stage", "building");
  await expect(blockedCard).toHaveAttribute("data-stage-glow", "blocked");
  await expect(blockedCard).toHaveAttribute("class", /bg-red/);

  expect(pageErrors, report()).toHaveLength(0);
});

test("a live block transition keeps an already-visible Building card visible", async ({ page }) => {
  await showUpstreamLanes(page);
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");

  const card = page.locator("#dropzone-building #card-live-blocked-visible-demo");
  await expect(card).toBeVisible();

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  // Blocking is an ATTRIBUTE toggle, not a stage move — see the note above.
  const res = await page.request.patch("/api/v1/tasks/live-blocked-visible-demo/block", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { by: "avi", kind: "rework" },
  });
  expect(res.ok()).toBeTruthy();

  await expect(card).toBeVisible({ timeout: 10_000 });
  // Blocked stays on `building`; the block shows through data-stage-glow. See above.
  await expect(card).toHaveAttribute("data-stage", "building");
  await expect(card).toHaveAttribute("data-stage-glow", "blocked");
  await expect(card).toHaveAttribute("class", /bg-red/);
  await page.waitForTimeout(1_500);
  await expect(card).toBeVisible();

  expect(pageErrors, report()).toHaveLength(0);
});

test("the tasks board updates a blocked card live in the Building column", async ({ page }) => {
  await showUpstreamLanes(page);
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/tasks");

  const card = page.locator("#dropzone-building #card-tasks-live-blocked-demo");
  await expect(card).toBeVisible();
  await card.evaluate((node) => node.remove());
  await expect(page.locator("#card-tasks-live-blocked-demo")).toHaveCount(0);

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  // Blocking is an ATTRIBUTE toggle, not a stage move — see the note above.
  const res = await page.request.patch("/api/v1/tasks/tasks-live-blocked-demo/block", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { by: "avi", kind: "rework" },
  });
  expect(res.ok()).toBeTruthy();

  const blockedCard = page.locator("#dropzone-building #card-tasks-live-blocked-demo");
  await expect(blockedCard).toBeVisible({ timeout: 10_000 });
  // A blocked task STAYS ON `building` — Task#block! stamps the block columns and
  // leaves the stage alone, so data-stage never becomes "blocked". The card marks
  // the block with data-stage-glow instead (_task_card.html.erb line 140, from
  // card_glow_kind). NOT data-glow — that is the MASCOT'S signature colour (line 142),
  // and asserting it was a bug in the first cut of this repair: the specs stay
  // @quarantine so CI never ran them and nothing caught it. Verified against the real
  // rendered card while proving /tasks/broadcast-block-to-board.
  // the attribute that actually tracks Task#block_state.
  await expect(blockedCard).toHaveAttribute("data-stage", "building");
  await expect(blockedCard).toHaveAttribute("data-stage-glow", "blocked");
  await expect(blockedCard).toHaveAttribute("class", /bg-red/);

  expect(pageErrors, report()).toHaveLength(0);
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

// The ring is tinted from the bar's OWN computed background-colour, so the only question
// that matters is "will this colour actually paint". Answering it by PATTERN-MATCHING the
// serialized string is a spelling assertion wearing a guard's clothes: Chromium serializes
// a computed colour back in the colour space it was authored in, so a modern-syntax
// transparent tone — `oklch(... / 0)`, or Tailwind v4's `color-mix(... 0%, transparent)` —
// never looks like `rgba(..., 0)`. It sails through, a fully transparent colour is written
// to --studio-team-glow-color, and the ring runs its full 2s painting NOTHING: no error, no
// red test, no visible glow.
//
// Only a browser can answer it, so this is the lowest tier that can hold the property. The
// two tests are a pair on purpose: the first forbids painting an invisible tone, the second
// forbids "fixing" it by never tinting at all.
async function ringKnobForFill(page, fillColor) {
  return page.evaluate(async (color) => {
    const root = document.getElementById("current-release");
    const liveFill = root.querySelector("[data-test='release-phase-fill']");
    if (!liveFill) return { error: "no meter in the Next Release card renders a fill to read a tone from" };

    // Record what the browser ACTUALLY reports for this tone, so a failure names the
    // serialization that defeated the guard instead of only saying the knob was set.
    liveFill.style.backgroundColor = color;
    const computed = getComputedStyle(liveFill).backgroundColor;

    // Replace the slot with a copy in which exactly ONE meter's signature moved, so exactly
    // one meter rings and the reading below is unambiguous.
    const clone = root.cloneNode(true);
    const cloneFill = clone.querySelectorAll("[data-test='release-phase-fill']")[0];
    cloneFill.style.backgroundColor = color;
    cloneFill.closest("[data-test='release-phase-meter']").dataset.signature = "e2e-colour-space-probe";

    const stream = document.createElement("turbo-stream");
    stream.setAttribute("action", "replace");
    stream.setAttribute("target", "current-release");
    const template = document.createElement("template");
    template.innerHTML = clone.outerHTML;
    stream.appendChild(template);
    document.body.appendChild(stream);

    // Read inside the 2s ring, before the class and the knob are cleaned up.
    await new Promise((resolve) => setTimeout(resolve, 600));
    stream.remove();

    const rung = Array.from(
      document.getElementById("current-release")
        .querySelectorAll("[data-test='release-phase-glow-host'].studio-team-glow")
    );
    return {
      computed,
      rung: rung.length,
      knob: rung.length ? rung[0].style.getPropertyValue("--studio-team-glow-color").trim() : "",
    };
  }, fillColor);
}

test("a transparent modern-syntax tone leaves the ring its default colour", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));

  // Both modern spellings a tone could plausibly be rewritten in. Neither serializes to
  // rgba(), which is exactly why a string-shaped guard misses them.
  //
  // Each tone gets a server-fresh page. The probe replaces #current-release with a clone
  // of the CURRENT DOM, so without the goto, iteration 2 clones iteration 1's aftermath:
  // the glow class and knob ride along, and the probe signature is already
  // "e2e-colour-space-probe" so nothing moves and meterGlow never even fires — the
  // assertions then read iteration 1's stale state and pass regardless of the tone.
  // Measured: an opaque tone in second position slipped through before this reset.
  for (const tone of [
    "oklch(0.7 0.15 160 / 0)",
    "color-mix(in oklch, oklch(0.7 0.15 160) 0%, transparent)",
  ]) {
    await page.goto("/deployments");
    await expect(page.locator("#current-release")).toBeVisible();
    await expect(page.locator("#current-release [data-test='release-phase-fill']").first()).toBeAttached();

    const seen = await ringKnobForFill(page, tone);

    expect(seen.error, seen.error || "").toBeUndefined();
    expect(seen.rung, `the meter whose signature moved must still ring (${tone})`).toBe(1);
    expect(
      seen.knob,
      `an invisible tone must leave the knob unset so the primitive's own colour paints — ${tone} was reported by the browser as "${seen.computed}"`
    ).toBe("");
  }
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("an opaque modern-syntax tone still tints the ring", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));

  await page.goto("/deployments");
  await expect(page.locator("#current-release")).toBeVisible();
  await expect(page.locator("#current-release [data-test='release-phase-fill']").first()).toBeAttached();

  // The other half: refusing every non-sRGB tone would pass the test above and quietly
  // strip the ring of its meaning, since the tint is what ties it to the bar it traces.
  const seen = await ringKnobForFill(page, "oklch(0.7 0.15 160)");

  expect(seen.error, seen.error || "").toBeUndefined();
  expect(seen.rung, "the meter whose signature moved must still ring").toBe(1);
  expect(
    seen.knob,
    `a visible tone must tint the ring — the browser reported this fill as "${seen.computed}"`
  ).not.toBe("");
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
