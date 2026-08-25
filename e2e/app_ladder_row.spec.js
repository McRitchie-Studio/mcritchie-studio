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
test("only a green rung wears the verified fill", async ({ page }) => {
  await page.goto("/deployments");

  const rungs = page.locator("[data-test='app-ladder-row'] [data-test='app-ladder-rung']");
  const count = await rungs.count();
  expect(count).toBeGreaterThan(0);

  for (let i = 0; i < count; i += 1) {
    const rung = rungs.nth(i);
    const state = await rung.getAttribute("data-state");
    const fillClass =
      (await rung.locator("[data-test='app-ladder-rung-fill']").getAttribute("class")) || "";

    if (fillClass.includes("bg-emerald-500")) {
      expect(state, "the verified fill may only appear on a green rung").toBe("green");
    }
  }
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
