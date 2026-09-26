const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e] THE CHARACTER-MODEL PAGE, in a browser — the operator's acceptance test:
// "I want to see the images found on the internet and the output on the same UI."
//
// WHAT ONLY A BROWSER CAN ANSWER, and therefore all this tier asserts:
//   · the two halves and the arrow are laid out side by side at desktop width and
//     stack at phone width — a request test sees the classes, not the geometry;
//   · the operator can REACH the page by clicking from the person page;
//   · a URL the SSRF guard refused is never requested by the browser, which is a
//     claim about network traffic that no render assertion can make.
//
// NOTHING HERE SPENDS MONEY. The seeded identity and candidates are fixtures written
// straight onto the rows (e2e/seed.rb), so no Higgsfield call and no search query
// happens; the Search button is not even rendered, because no provider is configured
// in the test environment.
//
// The person is "Drew Lockfixture" rather than a real seeded athlete so this spec's
// failures can never be confused with the artifact-gate specs that read Burrow.

const PERSON = "/people/drew-lockfixture";

async function openModelPage(page) {
  await page.goto(PERSON);
  const link = page.locator("[data-test='character-model-link']").first();
  await expect(link).toBeVisible();
  await link.click();
  await expect(page.locator("[data-test='reference-input-panel']")).toBeVisible();
}

test("both halves render on one page, side by side at desktop and stacked on a phone", async ({ page }) => {
  // REACHED BY CLICKING. A page an operator can only get to by typing a URL is a
  // page that does not exist for the person it was built for, so the route in is
  // part of the feature rather than a convenience.
  await page.setViewportSize({ width: 1440, height: 1000 });
  await openModelPage(page);

  const input = page.locator("[data-test='reference-input-panel']");
  const output = page.locator("[data-test='model-output-panel']");
  const arrow = page.locator("[data-test='pipeline-arrow']");
  await expect(output).toBeVisible();
  await expect(arrow).toBeVisible();

  // BOTH HALVES AND THE DIRECTION, measured as geometry rather than as classes.
  const [inputBox, arrowBox, outputBox] = await Promise.all([
    input.boundingBox(), arrow.boundingBox(), output.boundingBox(),
  ]);
  expect(inputBox.x + inputBox.width).toBeLessThanOrEqual(outputBox.x + 1);
  expect(arrowBox.x).toBeGreaterThanOrEqual(inputBox.x + inputBox.width - 1);
  expect(arrowBox.x + arrowBox.width).toBeLessThanOrEqual(outputBox.x + 1);

  // THE INPUT HALF: chosen photographs AND the rejects, which is the pair that lets
  // the operator judge the search rather than only its result.
  await expect(page.locator("[data-test='chosen-gallery'] [data-test='reference-photo']"))
    .toHaveCount(4);
  await expect(page.locator("[data-test='rejected-gallery'] [data-test='reference-photo']"))
    .toHaveCount(3);
  await expect(page.locator("[data-source='operator']")).toHaveCount(1);
  await expect(page.locator("[data-source='search']")).toHaveCount(6);

  // THE OUTPUT HALF: the identity, and an image generated against it.
  await expect(page.locator("[data-test='identity-status'][data-state='ready']")).toHaveCount(1);
  await expect(page.locator("[data-test='generated-images'] figure")).toHaveCount(1);

  // NO PROVIDER IS CONFIGURED in the test environment, so the page must degrade to
  // the note rather than offering a purchase it cannot make.
  await expect(page.locator("[data-test='search-unconfigured']")).toHaveCount(1);
  await expect(page.locator("[data-test='search-button']")).toHaveCount(0);

  // STACKS ON A PHONE, and nothing spills sideways. The horizontal-overflow check is
  // the one that catches a long unbroken URL widening a grid track — the identity
  // UUID and the refused address are both in that shape.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(150);
  const [mobileInput, mobileOutput] = await Promise.all([
    input.boundingBox(), output.boundingBox(),
  ]);
  expect(mobileOutput.y).toBeGreaterThan(mobileInput.y + mobileInput.height - 1);
  const [scrollW, clientW] = await page.evaluate(() => [
    document.documentElement.scrollWidth, document.documentElement.clientWidth,
  ]);
  expect(scrollW).toBeLessThanOrEqual(clientW + 1);
});

test("a candidate refused as unsafe is displayed but never requested by the browser", async ({ page }) => {
  // THE CLAIM NO RENDER TEST CAN MAKE. Appearances::FetchableUrl refused this URL as
  // unsafe to hand a REMOTE fetcher — and an img tag would hand it to the operator's
  // own browser instead, which is a machine INSIDE our network. So the tile shows the
  // address as text, and this spec watches the wire to prove the browser agrees.
  //
  // Signing in installs blockThirdPartyRequests, which aborts cross-origin
  // subresources — so the seeded Wikimedia URLs never leave the machine either, and
  // the only traffic this assertion could catch is traffic the page itself asked for.
  await loginWithMagicLink(page, "alex@test.com");

  const requested = [];
  page.on("request", (req) => requested.push(req.url()));

  await openModelPage(page);

  const refused = page.locator("[data-rejection='unfetchable']");
  await expect(refused).toHaveCount(1);
  await expect(refused).toBeVisible();
  // The operator can SEE what the search offered...
  await expect(refused).toContainText("127.0.0.1:9999");
  // ...and the page carries no way to fetch it.
  await expect(refused.locator("img")).toHaveCount(0);
  await expect(refused.locator("a")).toHaveCount(0);
  expect(requested.filter((url) => url.includes("127.0.0.1:9999"))).toEqual([]);
});
