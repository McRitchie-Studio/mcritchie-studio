// [e2e] The app page's tabs (task app-page-tabs, Alex McRitchie 2026-11-07): one page,
// Overview | Pipeline | Chat, under one header, each tab its own URL. The seeded admin
// switches tabs on Turf Monster by clicking them: each click lands on the tab's URL with
// that tab current, the header the same, and the chat's shell and composer working in
// its tab. An app with no CTO (taken-meanwhile, e2e/seed.rb) answers its Chat tab with
// the no-CTO state, not a 404. At 390px each tab fits, with nothing off the side.
//
// Read-only: it sends nothing and reads rows only e2e/seed.rb creates.
const { test, expect } = require("@playwright/test");

const TABS = [
  { key: "pipeline", path: "/applications/turf-monster/pipeline", body: "[data-test='pipeline-page']" },
  { key: "chat", path: "/applications/turf-monster/chat", body: "[data-test='cto-chat-page'] [data-test='agent-shell']" },
  { key: "overview", path: "/applications/turf-monster", body: "[data-test='application-page']" },
];

async function expectOpen(page, key) {
  const header = page.locator("[data-test='app-page-header']");
  await expect(header).toHaveAttribute("data-tab", key);
  await expect(header.getByRole("heading", { level: 1, name: "Turf Monster" })).toBeVisible();
  await expect(header.locator("a[data-test='app-tab'][aria-current='page']")).toHaveCount(1);
  await expect(header.locator(`a[data-test='app-tab'][data-tab='${key}']`)).toHaveAttribute("aria-current", "page");
}

test("the admin switches Overview, Pipeline and Chat on one app, each at its own URL", async ({ page }) => {
  await page.goto("/applications/turf-monster");
  await expectOpen(page, "overview");
  await expect(page.locator("[data-test='app-page-header'] a[data-test='app-tab']")).toHaveText(["Overview", "Pipeline", "Chat"]);

  for (const tab of TABS) {
    await page.locator(`[data-test='app-page-header'] a[data-test='app-tab'][data-tab='${tab.key}']`).click();
    await expect(page).toHaveURL(new RegExp(`${tab.path.replace(/\//g, "\\/")}$`));
    await expectOpen(page, tab.key);
    await expect(page.locator(tab.body)).toBeVisible();
    if (tab.key === "chat") {
      await expect(page.locator("[data-test='cto-chat-input']")).toBeEditable();
      await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");
    }
  }
});

test("an app with no CTO answers its Chat tab with the no-CTO state", async ({ page }) => {
  const response = await page.goto("/applications/taken-meanwhile/chat");
  expect(response.status(), "the no-CTO chat is a page, not a 404").toBe(200);
  await expect(page.locator("[data-test='app-page-header'] a[data-test='app-tab'][data-tab='chat']")).toHaveAttribute("aria-current", "page");
  await expect(page.locator("[data-test='cto-chat-no-cto'] [data-test='application-no-cto']")).toHaveText("This app has no CTO yet.");
});

test("each tab fits a 390px phone, with all three tabs in sight", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  for (const tab of TABS) {
    await page.goto(tab.path);
    await expectOpen(page, tab.key);
    // On a phone the tabs take their own line, so all three stay in sight.
    for (const key of ["overview", "pipeline", "chat"]) {
      await expect(page.locator(`[data-test='app-page-header'] a[data-test='app-tab'][data-tab='${key}']`)).toBeInViewport({ ratio: 1 });
    }
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, `${tab.key}: nothing runs off the side at 390px`).toBeLessThanOrEqual(0);
  }
});
