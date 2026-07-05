const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function createTask(page, token, attrs) {
  const res = await page.request.post("/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: attrs,
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}

test("task card archive and delete buttons persist and use distinct exits", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/tasks");

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const suffix = Date.now();
  const archiveSlug = `e2e-archive-action-${suffix}`;
  const deleteSlug = `e2e-delete-action-${suffix}`;

  await createTask(page, token, {
    slug: archiveSlug,
    title: "E2E archive action card",
    stage: "building",
    priority: 1,
    agent_slug: "alex",
  });
  await createTask(page, token, {
    slug: deleteSlug,
    title: "E2E delete action card",
    stage: "building",
    priority: 1,
    agent_slug: "alex",
  });

  await page.reload();

  const archiveCard = page.locator(`#card-${archiveSlug}`);
  await expect(archiveCard).toBeVisible();
  const archiveRespPromise = page.waitForResponse((response) =>
    response.url().includes(`/tasks/${archiveSlug}.json`) && response.request().method() === "PATCH"
  );
  await archiveCard.locator("[data-test='task-card-archive']").click();
  await expect(archiveCard).toHaveAttribute("data-exit-action", "archive");
  const archiveResp = await archiveRespPromise;
  expect(archiveResp.ok(), await archiveResp.text()).toBeTruthy();
  await expect(page.locator(`#dropzone-archived #card-${archiveSlug}`)).toHaveAttribute("data-stage", "archived");
  await expect(archiveCard).toBeHidden();

  const deleteCard = page.locator(`#card-${deleteSlug}`);
  await expect(deleteCard).toBeVisible();
  page.once("dialog", (dialog) => dialog.accept());
  const deleteRespPromise = page.waitForResponse((response) =>
    response.url().includes(`/tasks/${deleteSlug}.json`) && response.request().method() === "DELETE"
  );
  await deleteCard.locator("[data-test='task-card-delete']").click();
  await expect(deleteCard).toHaveAttribute("data-exit-action", "delete");
  const deleteResp = await deleteRespPromise;
  expect(deleteResp.status()).toBe(204);
  await expect(deleteCard).toHaveCount(0);
});
