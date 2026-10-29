// [e2e] The /deployments DevOps SIDEBAR goes live with its card (task
// devops-card-live-sidebar). The card was already a broadcast slot
// (devops-card-goes-live); the sidebar beside it kept its page-load numbers, so an open
// sidebar could disagree with the card mid-release. Now DeploymentsBroadcaster.devops_card
// replaces #devops-sidebar-detail in the same push, both from one Devops::Snapshot.
//
// The proof: open the sidebar, add a task (a task write does not push the DevOps slots,
// so nothing moves yet), then turn QA green with the local-only dev trigger. The open
// sidebar, never reloaded, now counts the new task, agrees with the card, and stays open.
// The cleanup reopens the release (the seeded release must stay assembling for the specs
// after this one) and deletes the fixture task.
//
// NOT @qa-readonly: it writes a task and the release e2e/seed.rb leaves in flight.
const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

const CARD = "#devops-summary-card";
const SIDEBAR = "#deploy-sidebar-devops";
const SLOT = `${SIDEBAR} #devops-sidebar-detail`;
const IN_FLIGHT = `${SLOT} [data-test='devops-detail-wip'] .text-lg`;
const TOGGLE = "button[data-test='summary-card-toggle'][aria-controls='deploy-sidebar-devops']";

test("QA green re-renders the open DevOps sidebar live, in step with the card", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await page.goto("/deployments");
  await expect(page.locator("[data-test='deploy-summary'][data-alpine-ready='true']")).toBeAttached();
  await expect(page.locator(`${CARD} [data-test='devops-qa-countdown']`), "the seeded release is short of QA green").toBeVisible();

  await page.locator(TOGGLE).click();
  await expect(page.locator(SIDEBAR)).toBeVisible();
  await expect(page.locator(SLOT)).toBeVisible();
  const before = Number(await page.locator(IN_FLIGHT).innerText());
  expect(Number.isInteger(before), "the sidebar shows a WIP count").toBe(true);
  await expect(page.locator(`${CARD} [data-test='summary-card-meta']`)).toHaveText(`${before} in flight`);

  // Subscribed before the writes, so the broadcast cannot outrun the stream.
  await expect(page.locator("turbo-cable-stream-source[connected]").first()).toBeAttached();
  // Markers a reload or a missed replace would leave behind.
  await page.evaluate((slot) => {
    window.__devopsSidebarNoReload = true;
    document.querySelector(slot).dataset.stale = "page-load";
  }, SLOT);

  let generated = false;
  let greened = false;
  try {
    const gen = await page.request.post("/dev/board/generate");
    expect(gen.status()).toBe(204);
    generated = true;

    const green = await page.request.post("/dev/board/qa_green_release");
    expect(green.status()).toBe(204);
    greened = true;

    await expect(page.locator(IN_FLIGHT), "the sidebar now counts the new task").toHaveText(String(before + 1), { timeout: 10_000 });
    await expect(page.locator(`${SLOT}[data-stale]`), "the slot was replaced, not patched").toHaveCount(0);
    await expect(page.locator(`${CARD} [data-test='summary-card-meta']`), "the card agrees")
      .toHaveText(`${before + 1} in flight`);
    await expect(page.locator(`${CARD} [data-test='devops-qa-countdown']`), "QA is green on the card too").toHaveCount(0);
    await expect(page.locator(SIDEBAR), "the replace lands inside the open sidebar and keeps it open").toBeVisible();
    await expect(page.locator(`${SLOT} #release-duration-card`), "the stage averages ride inside the slot").toBeVisible();
    expect(await page.evaluate(() => window.__devopsSidebarNoReload), "no reload happened").toBe(true);
    expect(pageErrors, report()).toEqual([]);
  } finally {
    if (greened) await page.request.post("/dev/board/qa_green_release", { form: { undo: "1" } });
    if (generated) await page.request.post("/dev/board/delete");
  }
});
