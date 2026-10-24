// [e2e] A refused Build My App (task build-launch-chat-growth). Alex's production
// run, 2026-10-18: a free-plan account that already owned an app pressed Build My
// App four times; each press was refused (then by the one-app limit) with a 422
// page, and the page showed no reason, jumped to its footer and opened the Links
// drawer.
//
// The promise: a refusal lands ON the summary card, as a reason and a next step,
// by a Turbo Stream, so the page is not re-rendered, the address and scroll stay,
// and no drawer opens. The plan-limit refusal's own next steps (the app they
// have, the plans) are pinned in test/controllers/build_controller_test.rb, with
// the limit stubbed: every tier is unlimited in the data today.
//
// The seed (e2e/seed.rb, "A refused Build My App") gives refused-launch@test.com a
// finished draft whose address another app took meanwhile; its last turn is the
// summary card.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors } = require("./helpers");

test("a refused Build My App shows its reason and next step on the summary card, with no reload, jump or drawer", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await loginWithMagicLink(page, "refused-launch@test.com");
  await page.goto("/build/e2e-refused-launch-draft");
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });
  if (await onboarding.isVisible().catch(() => false)) {
    await onboarding.getByRole("button", { name: "Skip for now" }).click();
    await expect(onboarding).toBeHidden();
  }

  const summary = page.locator("[data-test='build-card-summary']");
  await expect(summary).toHaveAttribute("data-ready", "true");
  // The production failure was a 422 PAGE, which Turbo rendered as a same-URL
  // refresh: this page morphs (turbo_refreshes_with :morph), and the morph
  // stripped Alpine's display:none off the Links panel. Every render is recorded.
  await page.evaluate(() => {
    window.__marker = "kept";
    window.__renders = [];
    document.addEventListener("turbo:before-render", (e) => window.__renders.push(e.detail.renderMethod || "replace"));
  });
  const before = await page.evaluate(() => ({ footers: document.querySelectorAll("footer").length, bodies: document.querySelectorAll("body").length }));

  const [response] = await Promise.all([
    page.waitForResponse((r) => ["POST", "PATCH"].includes(r.request().method()) && r.url().endsWith("/build/e2e-refused-launch-draft")),
    summary.locator("[data-test='build-summary-build']").click(),
  ]);
  expect(response.status()).toBe(422);
  expect(response.headers()["content-type"], "the refusal is a Turbo Stream, never a page").toContain("text/vnd.turbo-stream.html");

  const refusal = page.locator("[data-test='build-card-summary'] [data-test='build-summary-refusal']");
  await expect(refusal).toContainText("That name is taken.");
  await expect(refusal.locator("[data-test='build-summary-next']")).toContainText("Ask Ritch for another address");
  await expect(refusal).toBeInViewport();

  // The same page: no reload, the address kept, nothing appended outside the body,
  // and the Links drawer still shut.
  expect(await page.evaluate(() => window.__marker), "no reload").toBe("kept");
  await expect(page).toHaveURL(/\/build\/e2e-refused-launch-draft$/);
  const after = await page.evaluate(() => ({ footers: document.querySelectorAll("footer").length, bodies: document.querySelectorAll("body").length }));
  expect(after, "no second page appended").toEqual(before);
  expect(await page.evaluate(() => window.__renders), "no page render (no morph)").toEqual([]);
  await expect(page.locator("#studio-link-sidebar")).toBeHidden();
  expect(await page.evaluate(() => window.Alpine.store("sidebars")?.linkTreeOpen ?? false), "the drawer's flag stays shut").toBe(false);

  // A second press refuses the same way: still one card, one reason.
  await summary.locator("[data-test='build-summary-build']").click();
  await expect(page.locator("[data-test='build-summary-refusal']")).toHaveCount(1);
  await expect(page.locator("#studio-link-sidebar")).toBeHidden();
  // The browser logs each 422 it was answered with; that is the refusal, by design.
  const unexpected = pageErrors.filter((line) => !/status of 422/.test(line));
  expect(unexpected, report()).toHaveLength(0);
});
