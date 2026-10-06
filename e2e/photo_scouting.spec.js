const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

// [e2e] THE PHOTO SCOUTING PAGE, in a browser — the operator's acceptance test:
// "I should have a good idea of what the raw found images look like and which ones your
// taste is picking up to use into the model build."
//
// WHAT ONLY A BROWSER CAN ANSWER, and therefore all this tier asserts:
//   · the CALIBRATION ROUND TRIP. Clicking keep must store a verdict and move the
//     agreement figures WITHOUT a reload — that is Alpine, a fetch, and the server's
//     recomputed tally, and a request test cannot see any of it;
//   · the operator can REACH the page by clicking from the person page;
//   · the sections stack on a phone and the galleries widen at desktop — geometry, not
//     the class strings a render assertion sees;
//   · the promotion callout appears only once a rejected photograph is promoted.
//
// NOTHING HERE SPENDS MONEY. Every candidate is a fixture written straight onto the rows
// (e2e/seed.rb), so no search query and no classifier call happens. The Search button is
// rendered — the keyless provider makes `available?` true everywhere now — and this spec
// never clicks it, because clicking it would issue a real query to Wikimedia Commons.
//
// The person is "Drew Lockfixture" rather than a real seeded athlete so this spec's
// failures can never be confused with the artifact-gate specs that read Burrow.

const PERSON = "/people/drew-lockfixture";

async function openScouting(page) {
  await page.goto(PERSON);
  const link = page.locator("[data-test='photo-scouting-link']");
  await expect(link).toBeVisible();
  await link.click();
  await expect(page.locator("[data-test='photo-scouting']")).toBeVisible();
}

test("the raw set, the picks and the honesty panel render, and reflow on a phone", async ({ page }) => {
  // REACHED BY CLICKING. A page an operator can only get to by typing a URL is a page
  // that does not exist for the person it was built for.
  await page.setViewportSize({ width: 1440, height: 1000 });
  await openScouting(page);

  await expect(page.locator("[data-test='picks-section']")).toBeVisible();
  await expect(page.locator("[data-test='found-section']")).toBeVisible();

  // THE DEFECTS ARE ON THE PAGE. A calibration surface that hid its own model's worst
  // failures would have the operator tune his judgement against a machine that does not
  // behave the way the page implied.
  await expect(page.locator("[data-test='scouting-honesty']")).toBeVisible();
  await expect(page.locator("[data-test='defect-wrong-person']")).toBeVisible();
  await expect(page.locator("[data-test='defect-cannot-mint']")).toBeVisible();

  // EVERY RAW CANDIDATE, INCLUDING THE REJECTS. The seed files six search hits.
  const found = page.locator("[data-test='found-gallery'] [data-test='reference-photo']");
  await expect(found).toHaveCount(6);
  await expect(page.locator("[data-test='rejection-breakdown']")).toBeVisible();

  // THE GALLERY IS A MULTI-COLUMN GRID AT DESKTOP — measured as geometry, because the
  // class string is what a render test already saw.
  const firstTwo = await Promise.all([
    found.nth(0).boundingBox(),
    found.nth(1).boundingBox(),
  ]);
  expect(firstTwo[1].x).toBeGreaterThan(firstTwo[0].x);
  expect(Math.abs(firstTwo[1].y - firstTwo[0].y)).toBeLessThan(4);

  // ON A PHONE the page must not scroll sideways, which is the failure a class-only
  // assertion never catches.
  await page.setViewportSize({ width: 375, height: 780 });
  await expect(page.locator("[data-test='calibration-panel']")).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(1);
});

test.describe("a visitor", () => {
  test.use({ storageState: VISITOR });

  test("a visitor with no session is sent to sign-in before any spending button", async ({ page }) => {
    // HUB SIGNUP IS OPEN, so a session is not a cost control: the page sits behind the
    // admin wall, and a visitor never sees a control at all.
    await page.goto(PERSON);
    await expect(page).toHaveURL(/\/(login|signin)$/);
  });
});

test("an admin records a verdict and the agreement figures move without a reload", async ({ page }) => {
  await loginWithMagicLink(page, "alex@mcritchie.studio");
  await openScouting(page);

  // SELECTED BY HAVING A CONTROL, not by being first. The picks gallery leads with the
  // FLOOR rows — our mirrored headshot and the operator's own URL — which
  // Appearances::ReferenceSet builds in memory, so they carry no row to write a verdict
  // to and render "not from the search" instead of buttons. `.first()` therefore lands on
  // a tile with nothing to click, which is how this spec found that seam.
  await expect(page.locator("[data-test='not-calibratable']").first()).toBeVisible();

  const pick = page
    .locator("[data-test='picks-gallery'] [data-test='reference-photo']")
    .filter({ has: page.locator("[data-test='verdict-keep']") })
    .first();

  // SELF-CLEANING AND ORDER-INDEPENDENT. Every spec in this file shares one database, and
  // a verdict left behind would change the global agreement rate for whichever spec ran
  // next — and would TOGGLE OFF on a second run of this one, since re-sending the same
  // verdict clears it. So this asserts its own tile and its own cell, then puts the row
  // back the way it found it.
  await pick.locator("[data-test='verdict-keep']").click();

  // THE FIGURE CHANGED WITHOUT A NAVIGATION. This is the whole reason this tier exists:
  // the count comes back from the server and Alpine paints it, and nothing short of a
  // browser can observe that.
  await expect(pick.locator("[data-test='verdict-state']")).toContainText("agree");
  await expect(page.locator("[data-test='tally-agreed_keep'] p").first()).toHaveText("1");

  // AND IT SURVIVES A RELOAD, which is what separates a stored verdict from a class
  // toggled in the DOM.
  await page.reload();
  await expect(page.locator("[data-test='tally-agreed_keep'] p").first()).toHaveText("1");

  const again = page
    .locator("[data-test='picks-gallery'] [data-test='reference-photo']")
    .filter({ has: page.locator("[data-test='verdict-keep']") })
    .first();
  await again.locator("[data-test='verdict-keep']").click();
  await expect(page.locator("[data-test='tally-agreed_keep'] p").first()).toHaveText("0");
});

test("promoting a rejected photo raises the callout, and clicking again clears it", async ({ page }) => {
  await loginWithMagicLink(page, "alex@mcritchie.studio");
  await openScouting(page);

  // THE SHARPEST SIGNAL. A keep on a photograph the ranking REJECTED says the ranking
  // threw away something it should have kept — the only cell that can teach it something
  // it does not already believe.
  const callout = page.locator("[data-test='promotion-callout']");
  await expect(callout).toBeHidden();

  const rejected = page
    .locator("[data-test='found-gallery'] [data-chosen='false']")
    .filter({ has: page.locator("[data-test='verdict-keep']") })
    .first();
  await rejected.locator("[data-test='verdict-keep']").click();

  await expect(callout).toBeVisible();
  await expect(page.locator("[data-test='tally-operator_promoted'] p").first()).toHaveText("1");
  await expect(rejected.locator("[data-test='verdict-state']")).toContainText("PROMOTE");

  // RE-SENDING THE SAME VERDICT CLEARS IT — the fastest correction for a misclick is the
  // button you just pressed, so "no opinion" has to stay reachable. It also leaves the
  // database as this spec found it.
  await rejected.locator("[data-test='verdict-keep']").click();
  await expect(callout).toBeHidden();
  await expect(page.locator("[data-test='tally-operator_promoted'] p").first()).toHaveText("0");
});
