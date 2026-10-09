const { test, expect } = require("@playwright/test");
const { watchPageErrors, openDeploySidebar } = require("./helpers");

// [e2e] THE RELEASE LANE ON THE NEXT RELEASE CARD. The card says, in sentences, who
// is assembling the release, who is shipping it, and what the production grant
// covers (tasks/_release_lane_lease, Release::LaneLease). A conductor claim taken
// or released reaches an open /deployments with no reload.
//
// THE SPEC OWNS ITS CLAIM. It takes the assembler claim on the seeded Next Release
// through the board's own API, as a second `bin/release prepare` session would, and
// releases it in a `finally`, so the card is back to "Nobody is assembling" for
// every other spec. It records no ship request and no grant: those cannot be taken
// back through the API, and other specs read this release's production window.
const SESSION = "e2e-lane-lease-session-7f3a";
const NONCE = "e2e-lane-lease-nonce";

async function claim(page, slug, action, body) {
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const suffix = action === "acquire" ? "" : `/${action}`;
  return page.request.post(`/api/v1/releases/${slug}/conductor_claim${suffix}`, {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: { role: "assembler", session: SESSION, nonce: NONCE, ...body },
  });
}

test("the Next Release card names the assembler live, and a second session is handed the same sentence", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await page.goto("/deployments");
  await openDeploySidebar(page, "releases");

  const card = page.locator("#current-release");
  const slug = (await card.locator("code").first().textContent()).trim();
  const lane = card.locator("[data-test='release-lane-lease']");
  const sentence = (key) => lane.locator(`[data-test='release-lane-row'][data-lane='${key}'] [data-test='release-lane-sentence']`);

  // Empty state: nobody holds either role, and no approval has been asked for.
  await expect(lane).toBeVisible();
  await expect(sentence("assembler")).toHaveText(`Nobody is assembling ${slug}.`);
  await expect(sentence("deployer")).toHaveText(`Nobody is shipping ${slug}.`);
  await expect(sentence("grant")).toHaveText("No production approval has been asked for.");

  try {
    // A session takes the assembler claim. The open board is never reloaded.
    const taken = await claim(page, slug, "acquire", { label: "Snorlax" });
    expect(taken.ok()).toBeTruthy();
    expect((await taken.json()).data.acquired).toBe(true);

    await expect(sentence("assembler")).toContainText(`Snorlax (session …7f3a) is assembling ${slug} since`, { timeout: 10_000 });
    await expect(sentence("assembler")).toHaveAttribute("data-tone", "primary");
    // The time slot is the reader's clock; the title keeps the CLI's own text.
    await expect(sentence("assembler").locator("time[data-at-stamp]")).toBeVisible();
    const cardText = await sentence("assembler").getAttribute("title");
    expect(cardText).toMatch(new RegExp(`^Snorlax \\(session …7f3a\\) is assembling ${slug} since \\w{3} \\d+, \\d{2}:\\d{2} UTC\\.$`));
    // Only the session's tail is on the page.
    expect(await card.innerHTML()).not.toContain(SESSION);
    expect(await card.innerHTML()).not.toContain(NONCE);

    // A second session asks for the same claim: refused, and handed that sentence.
    const second = await claim(page, slug, "acquire", { session: "e2e-second-session-0b1c", nonce: "second" });
    const refusal = (await second.json()).data;
    expect(refusal.acquired).toBe(false);
    expect(refusal.holder.sentence).toBe(cardText);

    // The lane fits a phone: no sentence pushes the card wider than the viewport.
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(sentence("assembler")).toBeVisible();
    const overflow = await lane.evaluate((el) => ({
      lane: el.scrollWidth - el.clientWidth,
      right: el.getBoundingClientRect().right,
      viewport: document.documentElement.clientWidth,
    }));
    expect(overflow.lane).toBeLessThanOrEqual(1);
    expect(overflow.right).toBeLessThanOrEqual(overflow.viewport + 1);
  } finally {
    const released = await claim(page, slug, "release", {});
    expect([200, 204]).toContain(released.status());
  }

  // Released: the open board says so, again with no reload.
  await expect(sentence("assembler")).toHaveText(`Nobody is assembling ${slug}.`, { timeout: 10_000 });
  expect(pageErrors, report()).toHaveLength(0);
});
