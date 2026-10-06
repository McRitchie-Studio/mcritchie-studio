const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

// The /model_pipeline swim-lane board — every character model in flight, five lanes, drag
// to move. Rendered through the studio/board ENGINE PRIMITIVE, so these specs assert the
// EFFECT in a real browser: the board boots, the card/dropzone identity contract holds, a
// real drag persists, and a drag behind a model's evidence is REFUSED out loud instead of
// being accepted and silently corrected on the next load.
//
// The rows come from e2e/seed.rb (the "Lanefixture" people), which Playwright's own
// webServer runs — NOT db/seeds/61_appearances.rb, which is the development desk's copy.

const BOARD = "section[data-test='studio-board'][data-alpine-ready='true']";
const LANES = ["designed", "defined", "source", "model", "generation"];

test("the model pipeline board renders five lanes through the studio/board primitive", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await page.goto("/model_pipeline");
  await expect(page.locator(BOARD)).toHaveCount(1);

  // ZONE half of the contract — one #dropzone-<lane>.kanban-dropzone per lane.
  for (const lane of LANES) {
    await expect(page.locator(`#dropzone-${lane}.kanban-dropzone`)).toHaveAttribute("data-stage", lane);
  }

  // CARD half — id=card-<slug>, .kanban-card, data-slug, data-stage. The seeded Designed
  // look is the one card guaranteed to be in a known lane.
  const card = page.locator("#dropzone-designed .kanban-card").first();
  await expect(card).toHaveAttribute("data-slug", /^look-/);
  await expect(card).toHaveAttribute("data-stage", "designed");

  // Every card answers "why is it here" without a click.
  await expect(card.locator("[data-test='look-card-blocker']")).not.toHaveText("");

  expect(errors, errors.join("\n")).toHaveLength(0);
});

test("the board tells the operator that a drag triggers nothing", async ({ page }) => {
  await page.goto("/model_pipeline");

  const legend = page.locator("[data-test='pipeline-legend']");
  await expect(legend).toContainText("Dragging a card triggers nothing");
  await expect(legend).toContainText("forward, never back");
  await expect(page.locator("[data-test='pipeline-definition-gap']")).toContainText("fills per athlete on demand");

  // THE NUMBER CELL, BOTH WAYS, in a real browser. e2e/seed.rb gives the Designed athlete
  // a jersey number and leaves the Defined one without, because `athletes.jersey_number`
  // fills per athlete on demand and both states are ordinary. Located BY NAME, not by
  // position: other seeded people land in these lanes too, so `.first()` would not be
  // the card this asserts about.
  const numberOf = (lane, who) =>
    page.locator(`#dropzone-${lane} .kanban-card`, { hasText: who })
        .locator("[data-test='look-card-sports-number']");
  await expect(numberOf("designed", "Designed Lanefixture")).toHaveText("#12");
  await expect(numberOf("defined", "Defined Lanefixture")).toHaveText("no #");
});

test.describe("a visitor", () => {
  test.use({ storageState: VISITOR });

  test("a visitor is sent to sign-in instead of the board", async ({ page }) => {
    await page.goto("/model_pipeline");
    await expect(page).toHaveURL(/\/(login|signin)$/);
    await expect(page.locator(BOARD)).toHaveCount(0);
  });
});

test("an admin drag forward persists and the card says the data has not caught up", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/model_pipeline");
  await expect(page.locator(BOARD)).toHaveCount(1);

  // The seeded Source look with only a cached headshot — its evidence supports Source, so
  // Generation is ahead of it and the placement must stick.
  const slug = await page.locator("#dropzone-source .kanban-card").first().getAttribute("data-slug");
  expect(slug).toBeTruthy();

  // Drive the same endpoint the drag does (the studioBoard factory's cross-lane PATCH);
  // the logged-in admin session cookie rides page.request.
  const resp = await page.request.patch(`/model_pipeline/${slug}.json`, {
    headers: { "Content-Type": "application/json" },
    data: { appearance: { stage: "generation" } },
  });
  expect(resp.ok(), await resp.text()).toBeTruthy();

  await page.reload();
  const moved = page.locator(`#dropzone-generation #card-${slug}`);
  await expect(moved).toHaveCount(1);
  await expect(moved.locator("[data-test='look-card-hand-placed']")).toContainText("data says Source");
});

test("a drag behind a model's evidence is refused with the reason", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/model_pipeline");
  await expect(page.locator(BOARD)).toHaveCount(1);

  // A seeded Generation card whose evidence is a delivered image (not the hand-placed one,
  // which the previous spec may have created and whose evidence is only Source).
  const delivered = page.locator("#dropzone-generation .kanban-card", {
    has: page.locator("[data-test='look-card-generator']"),
  }).first();
  const slug = await delivered.getAttribute("data-slug");
  expect(slug).toBeTruthy();

  const resp = await page.request.patch(`/model_pipeline/${slug}.json`, {
    headers: { "Content-Type": "application/json" },
    data: { appearance: { stage: "defined" } },
  });
  expect(resp.status()).toBe(422);
  const body = await resp.json();
  expect(body.error).toContain("moves forward of its evidence, never behind it");

  // Refused means nothing moved.
  await page.reload();
  await expect(page.locator(`#dropzone-generation #card-${slug}`)).toHaveCount(1);
});

test("a reorder persists and the lane re-renders in the new order", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/model_pipeline");
  await expect(page.locator(BOARD)).toHaveCount(1);

  const readOrder = () =>
    page.locator("#dropzone-generation .kanban-card").evaluateAll((els) => els.map((e) => e.getAttribute("data-slug")));

  const before = await readOrder();
  expect(before.length).toBeGreaterThanOrEqual(2);
  const reversed = [...before].reverse();

  const resp = await page.request.post("/model_pipeline/reorder.json", {
    headers: { "Content-Type": "application/json" },
    data: { slugs: reversed, zone: "generation" },
  });
  expect(resp.ok(), await resp.text()).toBeTruthy();

  await page.reload();
  await expect(page.locator(BOARD)).toHaveCount(1);
  expect(await readOrder()).toEqual(reversed);
});
