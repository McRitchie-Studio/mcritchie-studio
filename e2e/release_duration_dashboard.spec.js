const { test, expect } = require("@playwright/test");

test("deployments analytics card navigates to release history and detail", async ({ page }) => {
  const pageErrors = [];
  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

  await page.goto("/deployments");

  const card = page.locator("#release-duration-card");
  await expect(card).toBeVisible();
  await expect(card.locator("[data-test='release-duration-stage']")).toHaveCount(4);
  await expect(card.locator("[data-test='release-duration-deployment']")).toContainText("Deployment");

  await card.getByRole("link", { name: "All Deployments" }).click();
  await expect(page).toHaveURL(/\/deployments\/all$/);
  await expect(page.getByRole("heading", { name: "All Deployments" })).toBeVisible();

  const releaseLink = page.locator("table tbody a[href^='/deployments/']").first();
  const releaseSlug = (await releaseLink.textContent()).trim();
  await releaseLink.click();

  await expect(page).toHaveURL(new RegExp(`/deployments/${releaseSlug}$`));
  await expect(page.getByRole("heading", { name: releaseSlug })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Stage Averages" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Member Tasks" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Release Events" })).toBeVisible();

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
