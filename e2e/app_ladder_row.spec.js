const { test, expect } = require("@playwright/test");

// The /deployments app-ladder row: one card per reportable repo, each showing where
// that application sits on `accepted → release → main`.
//
// WHY A BROWSER-LEVEL CHECK EARNS ITS PLACE HERE. The model and integration tiers
// already prove the state machine and the rendered markup. What they cannot prove is
// that the row survives a real page load on the live board — this row is injected
// into `_deploy_board`, a 580-line partial that also carries inline <script> blocks
// and an Alpine-driven filter row directly beneath it. An ERB comment that terminates
// early leaks prose whose literal tag can swallow the real script in every browser
// while every server-side test still passes (the propagate-at-format-gem defect).
// So this spec asserts the row renders AND that the board beneath it still works.

test("the deployments app-ladder row renders a card per repo with three rungs each", async ({ page }) => {
  await page.goto("/deployments");

  const row = page.locator("[data-test='app-ladder-row']");
  await expect(row).toBeVisible();

  const cards = row.locator("[data-test='app-ladder-card']");
  const cardCount = await cards.count();
  expect(cardCount).toBeGreaterThan(0);

  // Every card carries exactly the three ladder rungs, in order.
  for (let i = 0; i < cardCount; i += 1) {
    const card = cards.nth(i);
    const repo = await card.getAttribute("data-repo");
    expect(repo, "each card names its repo").toBeTruthy();

    const branches = await card
      .locator("[data-test='app-ladder-rung']")
      .evaluateAll((els) => els.map((el) => el.getAttribute("data-branch")));

    expect(branches, `${repo} must show the full ladder`).toEqual([
      "accepted",
      "release",
      "main",
    ]);
  }
});

// The honesty contract, asserted in a real browser: a rung may only read "green"
// when there is a live verdict for it. `stale` (a verdict that predates work parked
// on the branch) and `not_built` (nothing ingested at all) must render as themselves.
// A rung state outside the known set means the model grew a state the view does not
// render, which would fall through to a silent default.
test("every rung renders a known state and never invents a pass", async ({ page }) => {
  await page.goto("/deployments");

  const states = await page
    .locator("[data-test='app-ladder-row'] [data-test='app-ladder-rung']")
    .evaluateAll((els) => els.map((el) => el.getAttribute("data-state")));

  expect(states.length).toBeGreaterThan(0);

  const known = ["green", "red", "pending", "conflicted", "stale", "not_built"];
  const unknown = states.filter((s) => !known.includes(s));
  expect(unknown, "a rung rendered a state the view does not know").toEqual([]);
});

// The row sits directly above the app filter row inside the same partial. If the
// injection broke ERB or leaked a tag, the filter below it is the first thing to
// disappear — so this is the cheap regression guard on the surgery itself.
test("the board beneath the ladder row still renders", async ({ page }) => {
  await page.goto("/deployments");

  await expect(page.locator("[data-test='app-ladder-row']")).toBeVisible();
  await expect(page.locator("[data-test='kanban-board']")).toBeVisible();
  await expect(page.locator("[data-test='release-dashboard-grid']")).toBeVisible();
});

// The colour vocabulary, asserted in a real browser: the verified fill (emerald) may
// appear ONLY on a rung whose state is green. This is the honesty contract at the
// pixel layer — a stale or never-built rung wearing the verified tint would read as a
// pass the suite never performed, and no server-side tier can see the class landed.
test("the fill colours mean what progress says, never what CI says", async ({ page }) => {
  await page.goto("/deployments");

  const nodes = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-rung']");
  const count = await nodes.count();
  expect(count).toBeGreaterThan(0);

  // READ VIA evaluateAll, NOT getAttribute. An UNFILLED node draws no fill element at
  // all, and `locator.getAttribute()` on an empty locator AUTO-WAITS for the element
  // to appear rather than resolving to null — so the obvious spelling hangs for the
  // full 30s timeout on the first unfilled rung. evaluateAll returns [] instead, which
  // is the correct reading: no work reached that rung, so there is no tint to check.
  const pairs = await nodes.evaluateAll((els) =>
    els.map((el) => ({
      state: el.getAttribute("data-state"),
      progress: el.getAttribute("data-progress"),
      fill: el.querySelector("[data-test='app-ladder-rung-fill']")?.getAttribute("class") || "",
    }))
  );

  for (const { state, progress, fill } of pairs) {
    if (fill.includes("bg-emerald-500")) {
      // Emerald is now a PROGRESS claim ("the work moved through here"), so it may
      // only sit on a rung the work reached — and never on a failing one, because a
      // red rung takes the colour back off progress.
      expect(progress, "emerald claims the work moved through this rung").toBe("passed");
      expect(["red", "conflicted"], "a failing rung must never wear emerald").not.toContain(state);
    }
    if (fill.includes("bg-amber-500")) {
      expect(progress, "amber claims work is sitting on this rung").toBe("here");
    }
  }
});

// THE BAR'S OWN CONTRACT, at the pixel layer: colour says WHERE THE WORK IS and the
// glyph says what CI thought of that rung. This is the assertion that keeps the two
// from collapsing back into one channel — a reached rung behind an unreached one would
// mean the bar drew a gap, which the frontier rule makes impossible.
test("the coloured run is contiguous from the first rung to the frontier", async ({ page }) => {
  await page.goto("/deployments");

  const cards = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']");
  const cardCount = await cards.count();
  expect(cardCount).toBeGreaterThan(0);

  for (let i = 0; i < cardCount; i += 1) {
    const card = cards.nth(i);
    const repo = await card.getAttribute("data-repo");
    const furthest = await card.getAttribute("data-furthest");
    expect(["accepted", "release", "main"], `${repo} must name its frontier`).toContain(furthest);

    const progress = await card
      .locator("[data-test='app-ladder-rung']")
      .evaluateAll((els) => els.map((el) => el.getAttribute("data-progress")));

    const known = ["passed", "here", "unreached"];
    expect(progress.filter((p) => !known.includes(p)), `${repo} drew an unknown progress`).toEqual([]);

    // Contiguous from the left: once a rung is unreached, none after it is reached.
    const reached = progress.map((p) => p !== "unreached");
    const firstGap = reached.indexOf(false);
    if (firstGap !== -1) {
      expect(
        reached.slice(firstGap).some(Boolean),
        `${repo} drew a gap in the bar — the frontier rule makes that impossible`
      ).toBe(false);
    }

    expect(
      reached.filter(Boolean).length,
      `${repo} colours up to its frontier`
    ).toBe(["accepted", "release", "main"].indexOf(furthest) + 1);

    // `main` IS ARRIVAL, NEVER WAITING — nothing parks there, so it must not read
    // amber; a drained app would otherwise end on "still going" over shipped work.
    expect(progress[2], `${repo} must not draw main as work waiting`).not.toBe("here");
  }
});

// THE BLUE-BOX ASK, in a browser. A resting card dims, drops its meter, and still
// says one thing — a dimmed card saying nothing is indistinguishable from a broken one.
//
// ASSERTED AS A BICONDITIONAL OVER EVERY CARD, not by finding one resting card and
// checking it. The first draft did the latter and skipped when the live board had none,
// which the e2e ratchet rightly refuses: a selection modifier silently changes which
// specs the lane runs while the shard matrix stays byte-identical. Sweeping every card
// and asserting rest ⟺ dimmed ⟺ collapsed is strictly STRONGER anyway — it also catches
// the opposite defect, an ACTIVE card that dims or loses its meter — and it can never go
// vacuous, because the board always has cards.
test("every card dims and collapses if and only if it is at rest", async ({ page }) => {
  await page.goto("/deployments");

  const cards = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']");
  const count = await cards.count();
  expect(count, "the row must have cards for this sweep to mean anything").toBeGreaterThan(0);

  const seen = await cards.evaluateAll((els) =>
    els.map((el) => ({
      repo: el.getAttribute("data-repo"),
      resting: el.getAttribute("data-at-rest") === "true",
      position: el.getAttribute("data-position"),
      dimmed: el.className.includes("opacity-60"),
      meters: el.querySelectorAll("[data-test='app-ladder-ci']").length,
      restLines: el.querySelectorAll("[data-test='app-ladder-at-rest']").length,
      stamp: (
        el.querySelector("[data-test='app-ladder-main-merge-label']")?.textContent || ""
      ).trim(),
      progress: Array.from(el.querySelectorAll("[data-test='app-ladder-rung']")).map((r) =>
        r.getAttribute("data-progress")
      ),
    }))
  );

  for (const card of seen) {
    if (card.resting) {
      expect(card.position, `${card.repo} rests, so it must say so`).toBe("at_rest");
      expect(card.dimmed, `${card.repo} rests but is not dimmed`).toBe(true);
      expect(card.meters, `${card.repo} rests but kept its meter`).toBe(0);
      expect(card.restLines, `${card.repo} rests but says nothing`).toBe(1);
      // The ship fact moved off the quiet line and onto the stamp line every card
      // carries — one line down and sharper, rather than said twice on one card.
      expect(card.stamp, `${card.repo} rests but never names its ship`).toMatch(/^main merged/);
      // Resting means drained, so every rung has been passed through.
      expect(card.progress, `${card.repo} rests with work still on a rung`).toEqual([
        "passed",
        "passed",
        "passed",
      ]);
    } else {
      expect(card.position, `${card.repo} is active but labelled at rest`).not.toBe("at_rest");
      expect(card.dimmed, `${card.repo} is active but dimmed`).toBe(false);
      expect(card.restLines, `${card.repo} is active but carries the resting line`).toBe(0);
    }
  }
});

// Resting cards sink. The row is sorted worst-first, and rest is the far end of that
// order — so no resting card may appear before a card still holding work.
test("resting cards sort behind every card that still holds work", async ({ page }) => {
  await page.goto("/deployments");

  const flags = await page
    .locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']")
    .evaluateAll((els) => els.map((el) => el.getAttribute("data-at-rest") === "true"));

  const firstResting = flags.indexOf(true);
  if (firstResting !== -1) {
    expect(
      flags.slice(firstResting).every(Boolean),
      "an active card sorted behind a resting one"
    ).toBe(true);
  }
});

// Every card states its position in words, not only as a diagram.
test("every card names where it sits in the devops process", async ({ page }) => {
  await page.goto("/deployments");

  const positions = await page
    .locator("[data-test='app-ladder-row'] [data-test='app-ladder-position']")
    .evaluateAll((els) => els.map((el) => el.getAttribute("data-position")));

  expect(positions.length).toBeGreaterThan(0);
  // Every key of ApplicationHelper::APP_LADDER_POSITION_LABELS. `verifying` is in the
  // list because Card#position RETURNS it — drained, unclaimed, suite still running is
  // the state a repo sits in for the minutes after every merge. Omitting it did not
  // make the sweep stricter, it made it RED on a live board that happened to be
  // verifying, on whatever PR the lane ran against.
  const known = ["attention", "in_release", "queued", "verifying", "at_rest"];
  expect(positions.filter((p) => !known.includes(p))).toEqual([]);
});

// A rung being verified right now is the one moving part on the card.
test("a running rung carries a spinner and a settled one does not", async ({ page }) => {
  await page.goto("/deployments");

  const pending = page.locator(
    "[data-test='app-ladder-row'] [data-test='app-ladder-rung'][data-state='pending']"
  );
  const settled = page.locator(
    "[data-test='app-ladder-row'] [data-test='app-ladder-rung'][data-state='green']"
  );

  for (let i = 0; i < (await pending.count()); i += 1) {
    await expect(pending.nth(i).locator("svg.animate-spin")).toHaveCount(1);
  }
  for (let i = 0; i < (await settled.count()); i += 1) {
    await expect(settled.nth(i).locator("svg.animate-spin")).toHaveCount(0);
  }
});

// THE REGRESSION GUARD for the wiring bug this row shipped with. The board takes live
// updates over Turbo Streams, and a stream can only replace a target it can NAME. The
// row originally had no stable slot and no broadcast, so the dev deploy tools moved
// every other card and left it stale until a manual reload. Worse, the first fix
// looked correct and still did nothing: rendered standalone by DeploymentsBroadcaster
// the partial resolved `app_ladder_card` against application/ instead of tasks/ and
// raised Missing partial — which Studio::Cable.safe_broadcast SWALLOWS, so the
// broadcast failed silently with nothing in the log.
//
// Neither failure is visible to any server-side tier: the page renders correctly on a
// full load in both. Only driving the real button and watching the DOM catches them.
test("the ladder row re-renders from a broadcast when the dev tools fire", async ({ page }) => {
  await page.goto("/deployments");

  // The RELEASE toys. This is the operator's own way to exercise the live board, and
  // the row must move with everything else — that gap is the bug this spec guards.
  // The push is a call of its own from each release event source, NOT folded into
  // DeploymentsBroadcaster.release_modules: that method is the Next + Last cards and
  // its tests assert the exact slots it sends, so nesting a third surface there broke
  // them (and double-pushed on a CI tick).
  const tools = page.locator("[data-test='dev-deploy-tools']");
  await expect(tools).toBeVisible();

  const row = page.locator("#app-ladder-row");
  await expect(row).toBeVisible();

  // Assert on the RENDER STAMP, not on content. Opening a fixture release need not
  // move any rung verdict or parked count, so an identical re-render is a legitimate
  // outcome and a content diff would fail on a wiring that works. The stamp changes
  // every render, so it proves the mechanism: a broadcast arrived and replaced this
  // slot, with no reload.
  const before = await row.getAttribute("data-rendered-at");
  expect(before, "the row must carry a render stamp").toBeTruthy();

  // REDRAW, not Open. Redraw (dev/board#rebroadcast_release_modules) re-broadcasts
  // unconditionally with nothing changed, so it fires the same push on every run and
  // in every environment. Open is state-dependent — against an already-open fixture
  // release it can return early having written nothing, which is a legitimate no-op
  // that reads as a wiring failure. That is exactly how this spec passed locally and
  // failed in CI, where the seeded board already had a release open.
  await tools.getByRole("button", { name: "Redraw" }).click();

  await expect
    .poll(async () => page.locator("#app-ladder-row").getAttribute("data-rendered-at"), {
      timeout: 20000,
      message: "the ladder row never re-rendered after the dev tool fired",
    })
    .not.toBe(before);
});

// --- the review roll --------------------------------------------------------

// HOW LONG REVIEW TAKES on this app lately, drawn on every card.
//
// ENV-AGNOSTIC BY CONSTRUCTION. This spec asserts the SHAPE, never a value: the seeded
// board, a dev database and production all carry different review histories, and four
// of the five live cards had fewer than ten usable reviews the day this shipped. A
// spec that pinned "12m avg" would be red everywhere but the one machine it was
// written on. What must hold in every environment is that the block exists, that its
// value is one of the two legal forms, and that the count of what was excluded is
// always beside it.
test("every application card carries a review average or admits it has none", async ({ page }) => {
  await page.goto("/deployments");

  const cards = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']");
  const count = await cards.count();
  expect(count).toBeGreaterThan(0);

  for (let i = 0; i < count; i += 1) {
    const card = cards.nth(i);
    const repo = await card.getAttribute("data-repo");
    const block = card.locator("[data-test='app-ladder-review']");

    await expect(block, `${repo} must carry a review block`).toHaveCount(1);

    const value = ((await block.locator("[data-test='app-ladder-review-value']").textContent()) || "").trim();
    const note = ((await block.locator("[data-test='app-ladder-review-note']").textContent()) || "").trim();

    // Either a measured average, or the words that stand in for one. Never a blank,
    // never "NaN" — a quiet repo saying nothing reads as "reviews here take no time".
    expect(value, `${repo} rendered "${value}"`).toMatch(/^(\d+[smh]( \d+m)? avg|not enough data)$/);
    expect(note, `${repo} must always say what the rules dropped`).toMatch(
      /^(no reviews measured yet|(over \d+ reviews? · )?\d+ of \d+ excluded)$/
    );
  }
});

// THE TWO MINUTE-FIGURES. This card already carries a duration — the CI meter's run
// clock — and the operator must never read one as the other. The guard is structural:
// the review value lives in its own labelled block below the ladder badges, and it
// says "avg" out loud whenever it is a number.
test("the review average is never confusable with the CI run clock", async ({ page }) => {
  await page.goto("/deployments");

  const card = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']").first();
  const review = card.locator("[data-test='app-ladder-review']");
  await expect(review).toBeVisible();

  // The CI clock, when the card has one, is inside the meter — a different element.
  const clock = card.locator("[data-test='app-ladder-ci-bar-clock']");
  await expect(review.locator("[data-test='app-ladder-ci-bar-clock']")).toHaveCount(0);
  if ((await clock.count()) > 0) {
    const clockText = ((await clock.textContent()) || "").trim();
    expect(clockText, "the CI clock must not wear the average's label").not.toContain("avg");
  }

  const value = ((await review.locator("[data-test='app-ladder-review-value']").textContent()) || "").trim();
  if (value !== "not enough data") {
    expect(value, "a measured average must name itself an average").toContain("avg");
  }
});

// --- one scrolling row, a measured fade, and the pinned strip -----------------
//
// The operator's three asks for this section, and the two of them that ONLY a browser
// can settle. A server-side tier can prove the markup is there; it cannot prove the
// cards ended up on ONE LINE, that the fade clears when you reach the end of the
// scroll, or that the strip pins itself under a header whose height it had to measure.
//
// A WIDE VIEWPORT, like the other Deployments specs in this suite: the six-lane board
// collapses its upstream lanes below 1400px, and a spec that scrolls this page should
// be scrolling the page the operator actually looks at.
test.describe("the applications row", () => {
  test.use({ viewport: { width: 1600, height: 900 } });

  test("every application sits on one horizontal line", async ({ page }) => {
    await page.goto("/deployments");

    const scroller = page.locator("[data-test='app-ladder-scroller']");
    await expect(scroller).toBeVisible();

    // ONE LINE means one top edge. A wrapping grid puts the fifth card on a second
    // row, which is the exact shape this replaced — and the only reading that proves
    // it is the painted geometry, not the classes.
    const tops = await page
      .locator("[data-test='app-ladder-card']")
      .evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));

    expect(tops.length, "the live board must have cards").toBeGreaterThan(0);
    expect(new Set(tops).size, "every card shares one top edge").toBe(1);
  });

  test("the row fades at its right edge and clears when you reach the end", async ({ page }) => {
    await page.goto("/deployments");

    const scroller = page.locator("[data-test='app-ladder-scroller']");
    const room = await scroller.evaluate((el) => el.scrollWidth - el.clientWidth);

    if (room <= 8) {
      // Every repo fits, so there is nothing off-screen — and then the fade must be
      // ABSENT. Asserted rather than skipped: a skip would leave the honest half of
      // this contract uncovered on exactly the board that can prove it.
      await expect(scroller).not.toHaveAttribute("data-faded", "true");
      return;
    }

    await expect(scroller).toHaveAttribute("data-faded", "true");
    await expect(scroller).toHaveAttribute("style", /mask-image/);

    // Scroll to the end: there is nothing more to the right, so the promise must stop.
    await scroller.evaluate((el) => {
      el.scrollLeft = el.scrollWidth;
      el.dispatchEvent(new Event("scroll"));
    });

    await expect(scroller).not.toHaveAttribute("data-faded", "true");
  });

  test("scrolling past the applications pins them to the top of the page", async ({ page }) => {
    await page.goto("/deployments");

    const strip = page.locator("[data-test='app-ladder-pinned']");
    await expect(strip, "nothing is pinned while the row itself is on screen").toBeHidden();

    // Past the row: the board below it is long, so this lands mid-tasks — the position
    // the strip exists for.
    await page.evaluate(() => window.scrollTo(0, 1200));
    await expect(strip).toBeVisible();

    // IT SITS UNDER THE HEADER, NOT OVER IT — at a top it MEASURED, and it must still
    // be flush AFTER the header finishes moving.
    //
    // POLLED, and that is the assertion rather than a nicety. The header TRANSITIONS its
    // height over 300ms as it shrinks (`transition-all duration-300` in
    // layouts/application), so the last scroll event fires while it is still animating.
    // A one-shot reading here measured an 8px gap and passed on nothing; what the row's
    // ResizeObserver promises is that the strip CONVERGES on the header's own bottom
    // edge once it settles — so poll until it does, and fail if it never does.
    await expect
      .poll(
        async () =>
          page.evaluate(() => {
            const header = document.querySelector(".vt-pinned-header").getBoundingClientRect();
            const pinned = document
              .querySelector("[data-test='app-ladder-pinned']")
              .getBoundingClientRect();
            return Math.abs(Math.round(pinned.top - header.bottom));
          }),
        { message: "the strip settles flush against the header's own bottom edge" }
      )
      .toBeLessThanOrEqual(2);

    const pinnedTop = await page.evaluate(() =>
      Math.round(document.querySelector("[data-test='app-ladder-pinned']").getBoundingClientRect().top)
    );
    expect(pinnedTop, "and stays on screen").toBeLessThan(200);

    // THREE ROWS AND NO FOURTH — the condensed form the operator asked for.
    const tiles = page.locator("[data-test='app-ladder-pinned-card']");
    const count = await tiles.count();
    expect(count).toBeGreaterThan(0);

    const shape = await tiles.evaluateAll((els) =>
      els.map((el) => ({
        repo: el.getAttribute("data-repo"),
        name: (el.querySelector("[data-test='app-ladder-pinned-name']")?.textContent || "").trim(),
        ci: el.querySelectorAll("[data-test='app-ladder-pinned-ci']").length,
        rungs: Array.from(el.querySelectorAll("[data-test='app-ladder-rung']")).map((r) =>
          r.getAttribute("data-branch")
        ),
        review: el.querySelectorAll("[data-test='app-ladder-review']").length,
      }))
    );

    for (const tile of shape) {
      expect(tile.name, `${tile.repo} must name itself`).toBe(tile.repo);
      expect(tile.ci, `${tile.repo} keeps its CI row`).toBe(1);
      expect(tile.rungs, `${tile.repo} keeps the whole ladder`).toEqual([
        "accepted",
        "release",
        "main",
      ]);
      expect(tile.review, `${tile.repo} drops everything below those three rows`).toBe(0);
    }

    // Back to the top and the strip stands down — it is a substitute for the row, not
    // a second copy of it.
    await page.evaluate(() => window.scrollTo(0, 0));
    await expect(strip).toBeHidden();
  });
});

// THE STAMP THE OPERATOR ASKED FOR: every card says when `main` last took its code.
// `release → main` IS that merge here (`bin/release ship` fast-forwards it), so the
// value is the release's own shipped_at — a real date and time, or an em dash when the
// last ship predates the scanned window. Never a guess, and never blank.
test("every card stamps when main last took its code", async ({ page }) => {
  await page.goto("/deployments");

  const cards = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-card']");
  const count = await cards.count();
  expect(count).toBeGreaterThan(0);

  const stamps = await cards.evaluateAll((els) =>
    els.map((el) => ({
      repo: el.getAttribute("data-repo"),
      at: el.querySelector("[data-test='app-ladder-main-merge']")?.getAttribute("data-at") || "",
      text: (
        el.querySelector("[data-test='app-ladder-main-merge-value']")?.textContent || ""
      ).trim(),
    }))
  );

  for (const stamp of stamps) {
    expect(stamp.text, `${stamp.repo} must say something about main`).not.toBe("");
    if (stamp.at) {
      // A recorded ship prints its own minute — "Aug 21 3:12p".
      expect(stamp.text, `${stamp.repo} has a ship but printed no stamp`).toMatch(
        /^[A-Z][a-z]{2} \d{1,2} \d{1,2}:\d{2}[ap]$/
      );
    } else {
      expect(stamp.text, `${stamp.repo} has no ship, so it must admit the gap`).toBe("—");
    }
  }
});
