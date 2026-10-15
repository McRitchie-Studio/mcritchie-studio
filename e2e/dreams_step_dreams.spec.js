const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// /dreams shows each step dream under its SOP and step (app/views/dreams/_sops.html.erb):
// a step group sits inside the SOP's row, its card opens to the answer, the SOP's
// count includes it, and the status filter hides a step group with no dream of
// that status. The page reads the tracked bank, so the spec reads statuses from
// the page rather than naming a dream a later sign-off could flip.
test("step dreams render under their SOP and step, open, and follow the status filter", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/dreams");

  const step = page.locator("[data-test='sop-row'][data-sop='building-sop'] [data-test='sop-step'][data-step='begin']");
  await expect(step).toBeVisible();
  await expect(step).toContainText("step: begin");

  const card = step.locator("[data-test='dream-card']").first();
  await card.locator("summary").click();
  await expect(card).toHaveJSProperty("open", true);
  await expect(card.locator("[data-test='dream-answer']")).toBeVisible();
  await expect(card.locator("[data-test='dream-tags']")).toContainText("sop: building-sop");

  // A step dream is not also a platform dream card.
  const slug = await card.getAttribute("data-dream");
  await expect(page.locator(`[data-test='stage-group'] [data-dream='${slug}']`)).toHaveCount(0);

  // The filter that matches none of the group's statuses hides it in place.
  const statuses = (await step.getAttribute("data-statuses")).split(" ");
  const other = statuses.includes("approved") ? (statuses.includes("proposed") ? null : "proposed") : "approved";
  if (other) {
    await page.click(`[data-test='dream-filter-${other}']`);
    await expect(step).toBeHidden();
    await page.click("[data-test='dream-filter-all']");
    await expect(step).toBeVisible();
  }

  expect(pageErrors, report()).toEqual([]);
});
