// [e2e] An app owner reads their app's pipeline (docs/agents/system/client-pipeline.md).
// owner@turf.test owns Turf Monster, which e2e/seed.rb puts on the Builder tier (2
// building lanes). From the app page they open the pipeline: six lanes, the lane
// meter, and the seeded reviewed Turf task under Ready for QA, with no agent name, PR
// link or task link anywhere on the page. Another app's pipeline is a 404. At phone
// width nothing runs off the side. The seeded admin sees the same card with its PR.
//
// Read-only: it writes nothing and reads rows only e2e/seed.rb creates.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, VISITOR } = require("./helpers");

const READY_TITLE = "Release inclusion IN demo";
const SEEDED_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/8501";

test.describe("as the owner", () => {
  test.use({ storageState: VISITOR });

  test("an owner opens Turf's pipeline from the app page and sees lanes with nothing internal", async ({ page }) => {
    await loginWithMagicLink(page, "owner@turf.test");

    await page.goto("/applications/turf-monster");
    await page.locator("[data-test='application-pipeline-link']").click();
    await expect(page).toHaveURL(/\/applications\/turf-monster\/pipeline$/);
    await expect(page.getByRole("heading", { name: "Turf Monster pipeline", level: 1 })).toBeVisible();
    await expect(page.locator("#studio-link-sidebar a[href='/applications/turf-monster/pipeline']")).toHaveCount(1);

    const pipeline = page.locator("[data-test='pipeline-page']");
    await expect(pipeline.locator("[data-test='pipeline-lane']")).toHaveCount(6);
    await expect(pipeline.locator("[data-test='pipeline-lanes-label']")).toHaveText(/^\d+ of 2 lanes in use$/);
    await expect(pipeline.locator("[data-test='pipeline-lane'][data-lane='ready']")).toContainText(READY_TITLE);

    const html = await pipeline.innerHTML();
    for (const internal of [SEEDED_PR, "pull/8501", "Carl", "localhost", "e2e-release-inclusion-in-demo"]) {
      expect(html, `${internal} must not reach an owner`).not.toContain(internal);
    }
    await expect(pipeline.locator("a[href^='/tasks/']")).toHaveCount(0);
    await expect(pipeline.locator("[data-test='pipeline-card-pr']")).toHaveCount(0);

    await page.setViewportSize({ width: 390, height: 844 });
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, "nothing runs off the side at 390px").toBeLessThanOrEqual(0);

    const other = await page.request.get("/applications/cyvasse/pipeline", { maxRedirects: 0 });
    expect(other.status(), "another app's pipeline does not exist for this owner").toBe(404);
  });
});

test("the admin sees the same card with its PR link", async ({ page }) => {
  await page.goto("/applications/turf-monster/pipeline");
  const ready = page.locator("[data-test='pipeline-lane'][data-lane='ready']");
  await expect(ready).toContainText(READY_TITLE);
  await expect(ready.locator(`[data-test='pipeline-card-pr'][href='${SEEDED_PR}']`)).toHaveCount(1);
});
