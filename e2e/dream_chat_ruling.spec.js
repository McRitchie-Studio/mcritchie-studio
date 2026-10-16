const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams shows Alex's ruling given in chat (docs/agents/modules/dream.md, Act 3,
// "In chat"). A session records it with `bin/dream retire <slug> --clearance "<his
// words>"`, which posts POST /api/v1/dream_rulings; here the spec posts it directly.
// The fixture bank's `wait-for-the-light` is approved and tagged for carl and xan, so
// its card shows under both souls; the first is enough. No other spec rules on it.
test("a chat retirement shows Alex's quoted words beside the retirement", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  const words = "Retire the light one, the merge gate does it now";

  await loginWithMagicLink(page, "alex@mcritchie.studio");
  await page.goto("/agents/activities");
  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  const short = await page.request.post("/api/v1/dream_rulings", {
    headers: auth,
    data: { ruling: "retire", dream_home: "carl", dream_slug: "wait-for-the-light", clearance: "ok", session_id: "e2e-chat" },
  });
  expect(short.status()).toBe(422);

  const ruled = await page.request.post("/api/v1/dream_rulings", {
    headers: auth,
    data: { ruling: "retire", dream_home: "carl", dream_slug: "wait-for-the-light", clearance: words, session_id: "e2e-chat" },
  });
  expect([200, 201]).toContain(ruled.status());

  await page.goto("/dreams");
  const card = page.locator("[data-test='dream-card'][data-dream='wait-for-the-light']").first();
  await expect(card.locator("[data-test='dream-retiring-badge']")).toHaveText("Retired, drops after the next release");
  await card.locator("summary").click();
  await expect(card.locator("[data-test='dream-retirement-note']")).toContainText("in chat");
  await expect(card.locator("[data-test='dream-clearance-quote']")).toHaveText(words);
  await expect(card.locator("[data-test='dream-retire']")).toHaveCount(0);

  expect(pageErrors, report()).toHaveLength(0);
});
